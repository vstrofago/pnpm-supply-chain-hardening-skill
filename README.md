# pnpm Supply Chain Hardening

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-2ea44f)](https://github.com/vstrofago/pnpm-supply-chain-hardening-skill/releases)
[![pnpm](https://img.shields.io/badge/pnpm-10%20%7C%2011%20%7C%2012-F69220?logo=pnpm&logoColor=white)](#what-it-does)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-000000?logo=anthropic&logoColor=white)](#installation)
[![Hermes Agent](https://img.shields.io/badge/Hermes%20Agent-000000)](#installation)
[![OpenCode](https://img.shields.io/badge/OpenCode-8B5CF6)](#installation)
[![Codex](https://img.shields.io/badge/Codex-10A37F)](#installation)
[![Gemini CLI](https://img.shields.io/badge/Gemini%20CLI-4285F4)](#installation)

A portable skill that makes pnpm installs resistant to compromised-package supply-chain
attacks, and moves projects off the pnpm 9 line — which has no patched release.

It is not a checklist to read once. It carries an auditor you can run against any project,
and the configuration values with their defaults explained, so the agent can tell the
difference between "this looks hardened" and "this is hardened".

## What it does

| | |
|---|---|
| **Audits a project** | `scripts/audit.sh` grades a repository against every practice in the skill and exits non-zero on failures, so it works in CI |
| **Upgrades pnpm safely** | Three installation routes with their trade-offs, including the one that survives a node upgrade |
| **Hardens the global config** | The pnpm ≥ 10 settings that actually reduce exposure, and the ones that are already safe by default and should not be touched |
| **Migrates projects** | The six failures that break a pnpm 9 → 12 migration, each with its exact error text and fix |
| **Catches silent regressions** | Overrides parked in `package.json`'s `pnpm` field, which pnpm ≥ 10 ignores without failing the install |

## What the auditor checks

| Section | Looks for |
|---|---|
| Project | `package.json`, lockfile presence and format |
| pnpm version | The version actually resolved in the project *and* in a neutral directory — a stale `PATH` entry is a real failure mode |
| Version pin | `packageManager` pins to a pnpm below 10, which pnpm will happily download and run |
| Ignored settings | A `pnpm` field in `package.json`, including whether it still holds overrides that no longer apply |
| `pnpm-workspace.yaml` | `overrides`, `allowBuilds`, and settings that weaken the defaults |
| Ownership | Build artifacts owned by another user, left behind by a past `sudo pnpm install` |
| Global config | `trustPolicy`, `minimumReleaseAge`, `verifyStoreIntegrity`, `blockExoticSubdeps`, `dangerouslyAllowAllBuilds` |

The auditor is **read-only**. It inspects files and reports; it never installs, writes or
deletes anything.

## Installation

The folder `pnpm-supply-chain-hardening/` is self-contained — no dependencies, no build
step. Copy it to your agent's skills directory. The same folder works everywhere; the
frontmatter carries both the Anthropic agent-skills convention and the Hermes convention.

| Agent | Install command |
|---|---|
| **Claude Code** | `cp -r pnpm-supply-chain-hardening ~/.claude/skills/` |
| **Hermes Agent** | `cp -r pnpm-supply-chain-hardening ~/.hermes/skills/devops/` |
| **OpenCode** | `cp -r pnpm-supply-chain-hardening ~/.config/opencode/skills/` (global) or `.opencode/skills/` (project) |
| **OpenAI Codex** | `cp -r pnpm-supply-chain-hardening ~/.codex/skills/` (global) or `.codex/skills/` (project) |
| **Gemini CLI** | `cp -r pnpm-supply-chain-hardening .gemini/skills/` (workspace) |

`.agents/skills/` also works as a shared alias in OpenCode and Gemini CLI. After installing,
start a new session so the skill loader picks it up.

## Usage

Ask the agent to harden pnpm, migrate a project, or audit a repository — the skill's
triggers fire on their own. The auditor can also be run directly:

```bash
# audit the current project
pnpm-supply-chain-hardening/scripts/audit.sh

# audit somewhere else
pnpm-supply-chain-hardening/scripts/audit.sh ~/code/my-app

# fail CI on warnings as well, not only on failures
pnpm-supply-chain-hardening/scripts/audit.sh --strict

# sweep a directory of projects
for p in */; do pnpm-supply-chain-hardening/scripts/audit.sh "$p"; done
```

Exit codes: `0` no failures, `1` at least one failure (or a warning, under `--strict`),
`2` bad invocation.

## Sample output

```
$ scripts/audit.sh ~/code/my-app

pnpm supply-chain audit — /home/me/code/my-app
──────────────────────────────────────────────

Project
  ✓ package.json found (my-app)
  · lockfile: pnpm-lock.yaml
  · lockfileVersion: 9.0

pnpm version
  · resolved in this project: 12.4.2
  · resolved in a neutral dir: 12.4.2
  ✓ pnpm 12.4.2 is on a patched line

Version pin
  ✓ packageManager pins pnpm 12.4.2

Ignored settings in package.json
  ✓ no "pnpm" field in package.json

pnpm-workspace.yaml
  ✓ present
  ✓ declares overrides
  ✓ declares allowBuilds (dependency scripts are opt-in)

Ownership
  ✓ no foreign-owned build artifacts in the project root

Global configuration
  · file: /home/me/.config/pnpm/config.yaml
  ✓ trustPolicy: no-downgrade
  ✓ minimumReleaseAge is set explicitly (this also enables strict mode)
  ✓ verifyStoreIntegrity is on (default)
  ✓ blockExoticSubdeps is on (default since pnpm 10.26)

──────────────────────────────────────────────
failures: 0   warnings: 0
no failures
```

On a project that needs work, the same run names the problem and the fix:

```
Version pin
  ✗ packageManager pins an unpatched pnpm (9.15.9)
      ↳ pnpm honours this field and will download that exact version regardless of
        what is installed globally
      ↳ bump it, then run a plain `pnpm install` to refresh the lockfile

Ignored settings in package.json
  ✗ a "pnpm" field is present in package.json — pnpm >= 10 does not read it
      ↳ it is silently ignored; overrides parked there stop applying
      ↳ this project HAS overrides in that field — they are NOT in effect
```

## Layout

```
pnpm-supply-chain-hardening/
├── SKILL.md                              the procedure, ~150 lines
├── icon.svg
├── references/
│   ├── settings.md                       every setting, its default, and why
│   └── migration-pitfalls.md             the six migration failures with fixes
└── scripts/
    └── audit.sh                          the auditor
```

Detail lives in `references/` so it loads only when needed.

## Why the 9.x line cannot be kept

The GitHub Advisory Database carries roughly twenty high and medium advisories against
pnpm — virtual-store path traversal, arbitrary file writes from a lockfile, environment
secret exfiltration. Their patch ranges read `< 10.34.5`, `>= 11.0.0 < 11.11.0` and so on.
**Nothing was ever backported to 9.x**, so `9.15.9` is both the newest release of that line
and permanently vulnerable. There is no configuration that fixes it.

## Credits

Written by [vstrofago](https://github.com/vstrofago), with Hermes Agent.

## License

MIT — see [LICENSE](LICENSE).
