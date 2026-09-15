#!/usr/bin/env bash
#
# audit.sh — check a project against pnpm supply-chain hardening practices.
#
# Read-only: it inspects files and reports; it never installs, writes or deletes.
#
# Usage:
#   ./audit.sh [PROJECT_DIR] [--strict]
#
# Exit codes:
#   0  no failures
#   1  at least one check failed (or a warning, with --strict)
#   2  bad invocation / unusable target
#
set -uo pipefail

VERSION="1.0.0"
strict=0
target=""

usage() {
  cat <<EOF
audit.sh $VERSION — audit a project against pnpm supply-chain hardening practices.

Usage:
  audit.sh [PROJECT_DIR] [--strict]

Options:
  --strict      also exit non-zero on warnings
  -h, --help    show this help
  --version     print version
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) printf 'audit.sh %s\n' "$VERSION"; exit 0 ;;
    --strict) strict=1; shift ;;
    --) shift; break ;;
    -*) printf 'audit.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) target="$1"; shift ;;
  esac
done

[ -n "$target" ] || target="."
[ -d "$target" ] || { printf 'audit.sh: not a directory: %s\n' "$target" >&2; exit 2; }
cd "$target" || exit 2

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_BAD=""; C_DIM=""; C_OFF=""
fi

fails=0
warns=0

section() { printf '\n%s\n' "$1"; }
ok()      { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$1"; }
warn()    { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$1"; warns=$((warns + 1)); }
bad()     { printf '  %s✗%s %s\n' "$C_BAD" "$C_OFF" "$1"; fails=$((fails + 1)); }
info()    { printf '  %s·%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
hint()    { printf '      %s↳ %s%s\n' "$C_DIM" "$1" "$C_OFF"; }

# File owner, GNU stat then BSD stat.
file_owner() {
  stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null
}

# Read the few package.json facts we need.
# Sets: PKG_PM (packageManager field), PKG_PNPM_FIELD (yes/no), PKG_OVERRIDES (yes/no)
read_package_json() {
  PKG_PM=""
  PKG_PNPM_FIELD="no"
  PKG_OVERRIDES="no"
  [ -f package.json ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    eval "$(python3 -c '
import json, sys
d = json.load(open("package.json"))
pm = d.get("packageManager") or ""
pn = d.get("pnpm") or {}
ov = "yes" if (isinstance(pn, dict) and pn.get("overrides")) else "no"
import shlex
print("PKG_PM=" + shlex.quote(pm if isinstance(pm, str) else ""))
print("PKG_PNPM_FIELD=" + ("yes" if pn else "no"))
print("PKG_OVERRIDES=" + ov)
' 2>/dev/null)"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    eval "$(node -e '
const d = require("./package.json");
const pm = typeof d.packageManager === "string" ? d.packageManager : "";
const pn = d.pnpm || {};
const q = s => "'"'"'" + String(s).replace(/'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'";
console.log("PKG_PM=" + q(pm));
console.log("PKG_PNPM_FIELD=" + (Object.keys(pn).length ? "yes" : "no"));
console.log("PKG_OVERRIDES=" + (pn.overrides ? "yes" : "no"));
' 2>/dev/null)"
    return 0
  fi
  # Last resort: textual scan. Top-level keys are indented by two spaces.
  if grep -qE '^[[:space:]]{2}"pnpm"[[:space:]]*:' package.json 2>/dev/null; then
    PKG_PNPM_FIELD="yes"
  fi
  PKG_PM="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -1)"
  info "no python3/node available: package.json read textually, results approximate"
}

printf 'pnpm supply-chain audit — %s\n' "$(pwd)"
printf '%s\n' "──────────────────────────────────────────────"

# ── 1. Project ────────────────────────────────────────────────────────────────
section "Project"
if [ -f package.json ]; then
  name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -1)"
  ok "package.json found${name:+ (${name})}"
else
  bad "no package.json here — is this the project root?"
fi
for f in pnpm-lock.yaml package-lock.json yarn.lock; do
  [ -f "$f" ] && info "lockfile: $f"
done
if [ -f pnpm-lock.yaml ]; then
  lv="$(grep -m1 'lockfileVersion' pnpm-lock.yaml | sed 's/.*: *//; s/["'"'"']//g')"
  info "lockfileVersion: ${lv:-unknown}"
fi

read_package_json

# ── 2. pnpm version in use ────────────────────────────────────────────────────
section "pnpm version"
if ! command -v pnpm >/dev/null 2>&1; then
  bad "pnpm not on PATH"
else
  project_v="$(pnpm --version 2>/dev/null | head -1)"
  global_v="$( (cd "${TMPDIR:-/tmp}" && pnpm --version 2>/dev/null | head -1) )"
  info "resolved in this project: ${project_v:-unknown}"
  info "resolved in a neutral dir: ${global_v:-unknown}"
  if ! printf '%s' "$project_v" | grep -qE '^[0-9]+\.'; then
    pv_err="$(pnpm --version 2>&1 | head -1)"
    bad "could not read the pnpm version here: ${pv_err:-no output}"
    hint "pnpm may be refusing this project's configuration; run \`pnpm --version\` by hand"
    project_v=""
  fi
  major="$(printf '%s' "$project_v" | cut -d. -f1)"
  case "$major" in
    ''|*[!0-9]*)
      ;;
    *)
      if [ "$major" -lt 10 ]; then
        bad "pnpm $project_v is on an unpatched line — no 9.x release fixes the published advisories"
        hint "patched floors: 10.34.5 (10.x) / 11.11.0 (11.x) / 12.x"
      else
        ok "pnpm $project_v is on a patched line"
      fi
      ;;
  esac
  if [ -n "$PKG_PM" ] && [ -n "$project_v" ] && [ "$project_v" != "${PKG_PM#pnpm@}" ]; then
    info "package.json pins ${PKG_PM}; pnpm resolved $project_v from it"
  fi
fi

# ── 3. packageManager pin ─────────────────────────────────────────────────────
section "Version pin"
if [ -n "$PKG_PM" ]; then
  pin="${PKG_PM#pnpm@}"
  pin_major="$(printf '%s' "$pin" | cut -d. -f1)"
  case "$pin_major" in
    ''|*[!0-9]*) warn "packageManager \"$PKG_PM\" is not a plain semver pin" ;;
    *)
      if [ "$pin_major" -lt 10 ]; then
        bad "packageManager pins an unpatched pnpm ($pin)"
        hint "pnpm honours this field and will download that exact version regardless of what is installed globally"
        hint "bump it, then run a plain \`pnpm install\` to refresh the lockfile"
      else
        ok "packageManager pins pnpm $pin"
      fi
      ;;
  esac
else
  info "no packageManager pin — the globally installed pnpm is used"
fi

# ── 4. package.json \"pnpm\" field ───────────────────────────────────────────────
section "Ignored settings in package.json"
if [ "$PKG_PNPM_FIELD" = "yes" ]; then
  bad "a \"pnpm\" field is present in package.json — pnpm >= 10 does not read it"
  hint "it is silently ignored; overrides parked there stop applying"
  if [ "$PKG_OVERRIDES" = "yes" ]; then
    hint "this project HAS overrides in that field — they are NOT in effect"
  fi
  hint "move them to pnpm-workspace.yaml, then delete the field"
else
  ok "no \"pnpm\" field in package.json"
fi

# ── 5. pnpm-workspace.yaml ────────────────────────────────────────────────────
section "pnpm-workspace.yaml"
if [ -f pnpm-workspace.yaml ]; then
  ok "present"
  if grep -qE '^[[:space:]]*overrides:' pnpm-workspace.yaml; then
    ok "declares overrides"
  fi
  if grep -qE '^[[:space:]]*allowBuilds:' pnpm-workspace.yaml; then
    ok "declares allowBuilds (dependency scripts are opt-in)"
  fi
  if grep -qE '^[[:space:]]*onlyBuiltDependencies:' pnpm-workspace.yaml; then
    info "uses the older onlyBuiltDependencies key; allowBuilds supersedes it"
  fi
  if grep -qE 'dangerouslyAllowAllBuilds:[[:space:]]*true' pnpm-workspace.yaml; then
    bad "dangerouslyAllowAllBuilds: true — every dependency, including transitive ones, may run install scripts"
  fi
  if grep -qE 'minimumReleaseAge:[[:space:]]*0' pnpm-workspace.yaml; then
    warn "minimumReleaseAge: 0 disables the delay that protects against freshly published malware"
  fi
  if grep -qE '^[[:space:]]*trustPolicy:[[:space:]]*off' pnpm-workspace.yaml; then
    info "trustPolicy explicitly off (that is the default)"
  fi
else
  info "not present — fine for a single package, but settings have nowhere to live"
fi

# ── 6. Filesystem leftovers from a privileged install ─────────────────────────
section "Ownership"
me="$(id -un)"
# Paths that demonstrably break an install or a build when foreign-owned...
hard_paths="node_modules .next"
# ...and stray artifacts that are merely untidy, though they can break a build later.
soft_paths=".pnpm-store dist build next-env.d.ts"
found_stray=0
for p in $hard_paths; do
  [ -e "$p" ] || continue
  owner="$(file_owner "$p")"
  if [ -n "$owner" ] && [ "$owner" != "$me" ]; then
    found_stray=1
    bad "$p is owned by \"$owner\", not \"$me\" — this breaks installs and builds"
    hint "a past privileged run (sudo pnpm install) left it behind"
    hint "an EMPTY foreign-owned directory is removable without sudo: rmdir \"$p\""
  fi
done
for p in $soft_paths; do
  [ -e "$p" ] || continue
  owner="$(file_owner "$p")"
  if [ -n "$owner" ] && [ "$owner" != "$me" ]; then
    found_stray=1
    warn "$p is owned by \"$owner\", not \"$me\" — a leftover, not currently blocking"
    hint "remove it when convenient; root-owned content needs sudo"
  fi
done
[ "$found_stray" -eq 0 ] && ok "no foreign-owned build artifacts in the project root"

# ── 7. Global pnpm configuration ──────────────────────────────────────────────
section "Global configuration"
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pnpm/config.yaml"
if [ -f "$cfg" ]; then
  info "file: $cfg"
  if grep -qE 'trustPolicy:[[:space:]]*no-downgrade' "$cfg"; then
    ok "trustPolicy: no-downgrade"
  else
    warn "trustPolicy is not set to no-downgrade (default is off)"
    hint "catches a package whose trust evidence dropped — a common takeover signal"
  fi
  if grep -qE 'minimumReleaseAge:[[:space:]]*0([[:space:]]|$)' "$cfg"; then
    warn "minimumReleaseAge: 0 — no delay before installing freshly published versions"
    hint "that delay is what keeps a compromised release out of your tree"
  elif grep -qE 'minimumReleaseAge:' "$cfg"; then
    ok "minimumReleaseAge is set explicitly (this also enables strict mode)"
  else
    info "minimumReleaseAge not set; the built-in default of 1440 minutes still applies"
  fi
  if grep -qE 'verifyStoreIntegrity:[[:space:]]*false' "$cfg"; then
    warn "verifyStoreIntegrity: false — store contents are linked without checking"
  else
    ok "verifyStoreIntegrity is on (default)"
  fi
  if grep -qE 'blockExoticSubdeps:[[:space:]]*false' "$cfg"; then
    warn "blockExoticSubdeps: false — transitive deps may come from git or tarball URLs"
  else
    ok "blockExoticSubdeps is on (default since pnpm 10.26)"
  fi
  if grep -qE 'dangerouslyAllowAllBuilds:[[:space:]]*true' "$cfg"; then
    bad "dangerouslyAllowAllBuilds: true in the global config — dependency scripts run unchecked"
  fi
else
  warn "no global config at $cfg"
  hint "note: package.json and .npmrc are NOT read for these settings in pnpm >= 10"
  hint "create it with: pnpm config set --global trustPolicy no-downgrade"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%s\n' "──────────────────────────────────────────────"
printf 'failures: %s   warnings: %s\n' "$fails" "$warns"

status=0
if [ "$fails" -gt 0 ]; then
  status=1
elif [ "$strict" -eq 1 ] && [ "$warns" -gt 0 ]; then
  status=1
fi
if [ "$status" -eq 0 ]; then
  printf '%sno failures%s\n' "$C_OK" "$C_OFF"
else
  printf '%sreview the items above%s\n' "$C_BAD" "$C_OFF"
fi
exit "$status"
