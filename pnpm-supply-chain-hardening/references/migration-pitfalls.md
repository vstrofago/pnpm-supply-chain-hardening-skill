# Migration pitfalls: pnpm 9 → 10/11/12

Everything below was observed while migrating real projects. Each item is a failure you
will hit, the exact error text, and the fix.

## 1. `ERR_PNPM_FROZEN_LOCKFILE_WITH_OUTDATED_LOCKFILE` after bumping a pin

```
× resolve package manager dependencies
╰─▶ Cannot update packageManagerDependencies with "frozen-lockfile" because
    the lockfile is not up to date
```

pnpm ≥ 10 records its own version in the lockfile, in a second document alongside the
dependency graph. Bumping `packageManager` therefore makes the lockfile stale, and any
frozen install (CI, Docker, `pnpm install --frozen-lockfile`) fails until it is rewritten.

**Fix:** run one plain `pnpm install` in the project. The lockfile diff is unavoidable and
should be committed. Do this deliberately, on a branch, not as a side effect of a CI run.

## 2. `pnpm.overrides` in `package.json` is silently ignored

```
[WARN] The "pnpm" field in package.json is no longer read by pnpm.
       The following keys were ignored: "pnpm.overrides".
```

This is the dangerous one, because **the install still succeeds**. Any security override
kept in that field — the usual reason it is there — simply stops applying, and nothing
fails to tell you.

**Fix:** move the contents to `pnpm-workspace.yaml` and delete the field.

```yaml
# pnpm-workspace.yaml
packages:
  - '.'

overrides:
  hono: 4.12.25
```

Keep `packages` present even for a single-package repository: pnpm 9 rejects a workspace
file without it (`ERROR packages field missing or empty`), so omitting it breaks anyone
still on the older major.

**Verify the override is real**, do not assume:

```bash
pnpm why hono     # must resolve to exactly one version — the overridden one
```

## 3. `ERR_PNPM_IGNORED_BUILDS`

```
× installing dependencies
╰─▶ Ignored build scripts: msw@2.14.6
  help: Run "pnpm approve-builds" to pick which dependencies should be allowed to run scripts
```

pnpm 10 stopped running dependency `postinstall` scripts, and `strictDepBuilds` defaults to
true, so a package that wants one fails the whole install.

**Fix:** declare the ones that legitimately need it, by name:

```yaml
allowBuilds:
  msw: true
```

`pnpm approve-builds` does the same thing interactively. Approving a name is a permanent
permission for future versions of that package, so approve the minimum.

## 4. `trustPolicy: no-downgrade` false positives

```
× Failed to resolve dependency: High-risk trust downgrade for
  "semver@6.3.1" (possible package takeover)
```

The trust check compares publish dates, not semver, so an old release without provenance
can be flagged when the package's newer releases have it. `semver@6.3.1` is a legitimate
2023 backport and trips it.

**Before believing the alarm**, check the artifact against the public registry:

```bash
curl -s https://registry.npmjs.org/semver | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('published:', d['time']['6.3.1'])
print('shasum   :', d['versions']['6.3.1']['dist']['shasum'])"
```

Compare that shasum with a known-good source. If it matches, it is a false positive.

**Fix:** widen `trustPolicyIgnoreAfter` (minutes) so packages older than the window skip the
check. `43200` is 30 days. Prefer this over a growing `trustPolicyExclude` list of
individual versions.

## 5. A project pin overrides the global install

pnpm's `manage-package-manager-versions` (on by default) downloads and re-executes the
exact version named in `package.json`'s `packageManager` field. So a project pinned to
`pnpm@9.15.9` keeps running the vulnerable build no matter what you installed globally —
and `pnpm --version` inside that project reports the *pinned* version, not yours.

Audit every project for the field:

```bash
grep -rn '"packageManager"' --include=package.json . | grep -v node_modules
```

Then bump the pin and follow pitfall 1 to refresh the lockfile.

Related trap: a stale `PATH` entry pointing at an older pnpm installation can sit ahead of
the new one and quietly make every command test the wrong binary. Confirm with
`pnpm --version` from a neutral directory such as `/tmp`.

## 6. Leftovers from a privileged install block everything

Symptoms vary by tool and all trace back to files owned by `root` inside a user-owned
project:

```
ERR_PNPM_PACKAGE_MANAGER_CREATE_SLOT_DIR: Failed to create virtual store slot directory
  ... Permission denied (os error 13)
EACCES: permission denied, open '.../.next/trace'
```

A past `sudo pnpm install` (or a root-run build) leaves `node_modules`, `.next`,
`.pnpm-store`, `dist` or `next-env.d.ts` owned by root. Find them:

```bash
find . -maxdepth 2 ! -user "$(id -un)" -printf '%u:%g %m %y %p\n'
```

**Key permission detail:** deleting an entry requires write permission on its *parent*
directory, not on the entry itself. So an **empty** root-owned directory is removable
without sudo:

```bash
rmdir node_modules
rmdir .next
```

A root-owned file inside a user-owned directory is likewise removable — `rm next-env.d.ts`
— because the parent is writable. Next.js regenerates it on the next build.

A root-owned directory that still contains root-owned content does need `sudo`. Adding the
stray paths to `.gitignore` keeps them out of the repository in the meantime.

## Known-good migration sequence

```bash
# 1. bump the pin, if any
#    "packageManager": "pnpm@12.4.2"

# 2. move overrides out of package.json into pnpm-workspace.yaml

# 3. install once, unfrozen, to rewrite the lockfile
pnpm install

# 4. let it tell you which build scripts it wants, then approve the real ones
#    -> ERR_PNPM_IGNORED_BUILDS: msw@2.14.6
#    add: allowBuilds: { msw: true }
pnpm install

# 5. prove it works
pnpm why <overridden-package>
pnpm build
```

Step 4 usually needs two passes: the install fails once to report the packages, then
succeeds after you approve them.
