---
name: pnpm-supply-chain-hardening
description: "Harden pnpm installs and migrate projects off pnpm 9."
version: 1.0.0
author: vstrofago, Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  author: vstrofago
  version: "1.0.0"
  hermes:
    tags: [pnpm, supply-chain, security, node, dependencies, migration]
    category: devops
    related_skills: []
---

# pnpm Supply Chain Hardening

Makes pnpm installations resistant to compromised-package attacks, and moves projects off
the pnpm 9 line — which has no patched release. Ships `scripts/audit.sh`, a read-only
checker that grades a project against the practices below.

This skill changes configuration, not application code. It does not upgrade your
dependencies for you, and it does not decide which of your packages deserve to run install
scripts — it tells you which ones are asking.

## When to Use

- Hardening a machine or CI runner that installs npm dependencies with pnpm
- A project pins `packageManager: pnpm@9.x`, or anything below 10
- `pnpm install` fails with `ERR_PNPM_IGNORED_BUILDS` or `ERR_PNPM_FROZEN_LOCKFILE_WITH_OUTDATED_LOCKFILE`
- A security override that lives in `package.json`'s `pnpm` field seems to have stopped applying
- Auditing one project — or a whole directory of them — before trusting it

Don't use for: picking a package manager from scratch; npm or yarn projects; routine
dependency bumps that do not cross the pnpm 10 boundary.

## Prerequisites

- `bash` 4+ and `pnpm` on `PATH` for the audit
- Write access to the global pnpm config for the hardening step (`pnpm config set --global`)

## Quick Reference

| Goal | Command |
|---|---|
| Audit the current directory | `scripts/audit.sh` |
| Audit a specific project | `scripts/audit.sh /path/to/project` |
| Make warnings fail too (for CI) | `scripts/audit.sh --strict` |
| Audit a whole workspace | `for p in */; do scripts/audit.sh "$p"; done` |
| List pnpm advisories | `curl -s "https://api.github.com/advisories?ecosystem=npm&affects=pnpm&per_page=30" -H "Accept: application/vnd.github+json"` |

The auditor is read-only: it inspects files and reports, and never installs, writes, or
deletes anything. Exit code 0 means no failures, 1 means at least one failure (or a
warning, under `--strict`), 2 means bad invocation.

## Procedure

### 1. Establish the state of the project

Run `scripts/audit.sh /path/to/project`. Read failures before warnings — the failures are
the ones that are actively leaving you exposed.

**Done when:** every section of the report has been read and you can name which checks failed.

### 2. Upgrade pnpm itself

A pnpm below 10 cannot be fixed by configuration. Every published pnpm advisory was
patched in the 10.x or 11.x lines; **nothing was ever backported to 9.x**, so 9.15.9 is
simultaneously the newest and the permanently vulnerable release. Patched floors are
`10.34.5`, `11.11.0`, and the current 12.x — take the newest stable.

Pick whichever installation route fits the machine:

| Route | Command | Trade-off |
|---|---|---|
| mise | `mise use -g pnpm@latest` | Standalone binary with verified GitHub artifact attestations; independent of the node version, so a node upgrade does not remove it |
| corepack | `corepack enable pnpm` | Ships with node; pinned by each project's `packageManager` field |
| npm global | `npm i -g pnpm@latest` | Simplest, but lives under the node version's prefix and disappears when node is upgraded |

**Done when:** `pnpm --version` in a neutral directory reports the new major.

### 3. Apply the global hardening settings

Since pnpm 10, `.npmrc` is read only for auth and registry settings. Everything else lives
in `$XDG_CONFIG_HOME/pnpm/config.yaml` (usually `~/.config/pnpm/config.yaml`):

```bash
pnpm config set --global trustPolicy no-downgrade
pnpm config set --global trustPolicyIgnoreAfter 43200   # 30 days, in minutes
pnpm config set --global minimumReleaseAge 1440
pnpm config set --global verifyStoreIntegrity true
```

`trustPolicyIgnoreAfter` is not optional in practice — see Pitfalls. Full explanation of
each key, and the ones that are already safe by default, in `references/settings.md`.

**Done when:** `scripts/audit.sh` reports no failures under *Global configuration*.

### 4. Check every project for a pin

pnpm honours `packageManager` in `package.json` and will download and re-execute that
exact version. A project pinned to 9.x keeps running the vulnerable build no matter what
you installed globally.

```bash
grep -rn '"packageManager"' --include=package.json . | grep -v node_modules
```

Bump any pin below 10, then run a plain `pnpm install` (not `--frozen-lockfile`) so the
lockfile picks up the new package manager. Details in `references/migration-pitfalls.md`.

**Done when:** no project pins a pnpm below 10.

### 5. Move overrides out of `package.json`

pnpm ≥ 10 ignores the `pnpm` field in `package.json` and warns about it. Security overrides
parked there silently stop applying. Move them to `pnpm-workspace.yaml`:

```yaml
packages:
  - '.'

overrides:
  hono: 4.12.25
```

Then delete the `pnpm` field. Keep `packages` present even for a single-package repo —
older pnpm versions reject a workspace file without it.

**Done when:** the audit reports no `"pnpm"` field, and `pnpm why <overridden-package>`
shows a single resolved version.

### 6. Approve build scripts explicitly

Dependency install scripts are blocked by default, and `strictDepBuilds` defaults to true,
so any package that wants one fails the install with `ERR_PNPM_IGNORED_BUILDS`. Allow only
what was already running before the upgrade:

```yaml
allowBuilds:
  msw: true
```

**Done when:** `pnpm install` exits 0 and `pnpm build` succeeds.

## Pitfalls

- **`trustPolicy: no-downgrade` produces false positives on old packages.** It compares
  publish dates, not semver, so a legitimate years-old release with no provenance can be
  flagged as a takeover. Verify the tarball's shasum against the public registry before
  believing it, then widen `trustPolicyIgnoreAfter` rather than maintaining a
  `trustPolicyExclude` list.
- **`pnpm config get` does not show defaults.** It reads the config files only, so an
  unset key prints `undefined` even when pnpm has a working built-in default. Absence of
  output is not absence of protection.
- **A stale `PATH` can silently undo all of this.** If an older pnpm sits earlier on
  `PATH` than the new one, every command in this skill tests the wrong binary. Confirm
  with `pnpm --version` from a neutral directory before drawing conclusions.
- **Empty foreign-owned directories block installs.** A past `sudo pnpm install` leaves
  `node_modules` or `.next` owned by root. Deleting an entry needs write permission on its
  *parent*, so an empty root-owned directory is removable without sudo: `rmdir node_modules`.
  One with root-owned *contents* still needs `sudo`.
- **`packageManagerDependencies` broke `--frozen-lockfile`.** pnpm ≥ 10 records its own
  version in the lockfile. After bumping a pin, a frozen install fails until one plain
  `pnpm install` rewrites it. Expect the lockfile diff.

## Verification

Prove the hardening is actually in effect rather than merely configured:

```bash
pnpm --version                                     # the new major, from a neutral dir
scripts/audit.sh /path/to/project                  # exit 0
cd /path/to/project && pnpm install                # "Lockfile passes supply-chain policies"
pnpm why <overridden-package>                      # one version, the pinned one
pnpm build                                         # the real end-to-end check
```

A green `pnpm install` alone is not proof: the override check and the build are what show
the project still works with the tightened rules.
