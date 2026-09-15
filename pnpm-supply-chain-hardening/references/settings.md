# pnpm security settings reference

Since pnpm 10, `.npmrc` is read **only** for auth and registry settings. Everything else
lives in `$XDG_CONFIG_HOME/pnpm/config.yaml` (usually `~/.config/pnpm/config.yaml`), in a
project's `pnpm-workspace.yaml`, or as a `PNPM_CONFIG_*` environment variable.

Read and write the global file with:

```bash
pnpm config set --global <key> <value>
pnpm config list --global
```

`pnpm config get <key>` prints only what the config files declare — it does **not** show
built-in defaults, so `undefined` means "not written down", not "not in effect".

## Worth setting

| Key | Default | Set it to | Why |
|---|---|---|---|
| `trustPolicy` | `off` | `no-downgrade` | Fails the install when a package's trust evidence has *decreased* versus any earlier-published version — the signature of a takeover. Trust is judged by publish date, not semver. |
| `trustPolicyIgnoreAfter` | unset | `43200` (30 days) | Exempts packages older than the window from the trust check. Without it, long-lived packages released before provenance existed trip false positives. |
| `minimumReleaseAge` | `1440` since v11 (`0` before) | `1440` | Refuses to install a version published fewer than N minutes ago. Malicious releases are usually found and pulled within hours, so a one-day delay sidesteps most of the exposure. Useful to raise to `10080` (a week) on a high-value machine. |
| `minimumReleaseAgeStrict` | `true` if `minimumReleaseAge` is set explicitly, else `false` | leave implied | With strict mode on, resolution *fails* when no version satisfies the age constraint instead of quietly falling back to a too-new one. Setting `minimumReleaseAge` yourself turns this on — that is usually what you want. |
| `verifyStoreIntegrity` | `true` | `true` | Checks content-addressable store files before linking them into `node_modules`. Detects corruption; it is not a defence against an attacker who can write to the store. |

## Already safe by default — do not "fix" these

| Key | Default | Note |
|---|---|---|
| `blockExoticSubdeps` | `true` since v10.26 | Transitive dependencies cannot come from git repositories or direct tarball URLs. Only direct dependencies may. |
| dependency install scripts | blocked | `postinstall` and friends from *dependencies* do not run unless approved. |
| `dangerouslyAllowAllBuilds` | `false` | Setting it `true` lets every dependency, including transitive ones, run install scripts now and forever. Avoid; prefer `allowBuilds`. |
| `strictDepBuilds` | `true` | Makes the install fail loudly when a dependency wants a blocked build script, rather than skipping it in silence. |

## Approving build scripts

Dependency scripts are opt-in. When `strictDepBuilds` is on, an unapproved script fails the
install with `ERR_PNPM_IGNORED_BUILDS` and names the package.

```yaml
allowBuilds:
  msw: true
  esbuild: true
```

Two rules that matter:

- **Allow by name only packages that genuinely had scripts before.** Adding an entry is a
  standing permission for all future versions of that package too.
- **A package name never approves a git or tarball dependency.** For those, approve the
  exact resolved path or the repository URL instead, because a name alone does not identify
  the artifact.

`onlyBuiltDependencies` is the older list-shaped key; `allowBuilds` (v10.26+) supersedes it.

## Registry pinning

If you install from more than one registry, pin the packages that must come from a specific
one with named registries. From v11.20.0 pnpm records them in the lockfile under
registry-qualified keys, so the same name and version cannot be quietly substituted by a
different registry.

Because `pnpm-workspace.yaml` is committed to the repository, environment variables are not
expanded in registry URLs there — a malicious repository could otherwise use a placeholder
to leak environment secrets to an attacker-controlled registry. Configure dynamic registry
URLs in the global config or on the command line.

## Reading advisories

```bash
curl -s "https://api.github.com/advisories?ecosystem=npm&affects=pnpm&per_page=30" \
  -H "Accept: application/vnd.github+json" | \
  python3 -c "import sys,json
for a in json.load(sys.stdin):
    print(a['ghsa_id'], a['severity'], '|', a['summary'][:70])
    for v in a.get('vulnerabilities', []):
        print('   ', v['package']['name'], v.get('vulnerable_version_range'), '-> patched', v.get('first_patched_version'))"
```

Read the `first_patched_version` fields, not the top-level summary: a range like
`< 10.34.5` with no 9.x entry is telling you the 9.x line was abandoned, not that it is fine.
