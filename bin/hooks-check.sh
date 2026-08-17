#!/usr/bin/env bash
# hooks-check.sh — audits git hooks across a directory of repos and hunts the bug family
# "works fine on one platform, fails silently on the other." Twin of bin/hooks-check.ps1.
#
# WHY THIS EXISTS
# ----------------
# A pre-commit hook can be broken on one platform and nobody notices, because the machine
# where it was written never sees the failure. A classic example: `new URL('..',
# import.meta.url).pathname` returns a path with a leading slash on Windows; joining that
# with other path segments produces a path with a duplicated drive letter, and Node fails
# to open it. On macOS/Linux the exact same line works perfectly. Every commit from the
# broken machine either fails outright or gets pushed through with `--no-verify`, and
# nothing about the failure is visible from the platform where the code was written.
#
# A guard that silently doesn't protect anything is worse than no guard: it creates false
# confidence. This script exists to catch that failure mode before it costs months.
#
# WHAT IT CHECKS
#   1. CONFIGURATION. `core.hooksPath` is a per-machine git setting — it does NOT travel
#      with the repo. Every fresh clone of a repo with versioned hooks starts with those
#      hooks turned OFF until someone points `core.hooksPath` at them.
#   2. CROSS-PLATFORM LANDMINES. Node/JS idioms that behave differently depending on the
#      operating system (see README.md for the full list and why each one bites).
#   3. --run (optional): actually executes the pre-commit hooks. Not the default, because a
#      hook can have side effects.
#
# Usage:  hooks-check.sh [--dev-root DIR] [--run]
set -uo pipefail

DEV_ROOT="${HOME}/dev"
RUN_HOOKS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev-root) DEV_ROOT="$2"; shift 2 ;;
    --run)      RUN_HOOKS=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          echo "unknown option: $1"; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINDINGS=0

# Each landmine: an ERE pattern and the text explaining what happens when it matches. That
# text is printed as-is — it has to be enough to understand the problem without opening the
# file.
# The separator is '|@|' because the patterns themselves contain slashes and pipes.
MINES=(
  'import\.meta\.url[[:space:]]*\)[[:space:]]*\.pathname|@|0|@|duplicated drive letter on Windows -> the script dies with ENOENT. Use fileURLToPath() instead'
  'import\.meta\.url[[:space:]]*===[[:space:]]*`file://\$\{process\.argv\[1\]\}`|@|0|@|ALWAYS false on Windows -> the "run as main module" block never executes and the script exits 0 without doing anything. Compare fileURLToPath(import.meta.url) with resolve(process.argv[1]) instead'
  "process\.argv\[1\]\.split\('/'\)|@|0|@|on Windows the path separator is \\\\, not / -> this split never splits anything, the comparison is always false and the script silently does nothing"
  '/Users/[a-z]+/|@|1|@|absolute macOS home path: does not exist on Windows/Linux'
  'C:\\\\Users\\\\|@|1|@|absolute Windows path: does not exist on macOS/Linux'
)

# An absolute path is only a landmine if the script actually USES it to open something.
# There are two cases where it appears and is perfectly fine:
#   - inside a comment (a reference to a document, a provenance note)
#   - as a search PATTERN: `grep -cE "/Users/..."` doesn't open that path, it searches for
#     that text inside another file. "Fixing" it breaks the script.
# The first version of this checker flagged 57 findings and 10 were false positives. A
# checker that cries wolf gets ignored, and an ignored checker stops doing its job.
USE_RX='(readFile|writeFile|readdir|existsSync|createReadStream|require\(|from[[:space:]]+["'"'"']|import[[:space:]]+["'"'"']|NODE_PATH|[[:space:]]cd[[:space:]]|[[:space:]]source[[:space:]]|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*["'"'"'])'
PATTERN_RX='(grep|egrep|rg|awk|sed|match|test\(|RegExp)'

# ONE grep per mine and per FILE, not per line.
#
# An earlier version looped `while read line` and ran a grep per mine inside it: five
# subprocesses per line. On Git Bash, where spawning a process costs milliseconds, that's
# millions of spawns and the script never finishes — it hung for more than 10 minutes over
# a modest set of repos. With `grep -nE` over the whole file it's 5 processes per file, and
# the fine-grained filtering (comments, the "is it actually used" heuristic) happens in bash
# over the FEW lines that matched. Same result, three orders of magnitude less work.
scan_file() {
  local path="$1" label="$2"
  [[ -f "${path}" ]] || return 0
  local m rx requires_use what hit n line
  for m in "${MINES[@]}"; do
    rx="${m%%|@|*}"
    local rest="${m#*|@|}"
    requires_use="${rest%%|@|*}"
    what="${rest#*|@|}"
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] || continue
      n="${hit%%:*}"
      line="${hit#*:}"
      # Comments don't execute. The `*` covers /** */ block continuation lines — without it,
      # a documentation reference inside a JSDoc comment gets reported as a bug.
      [[ "${line}" =~ ^[[:space:]]*(#|//|\*|/\*) ]] && continue
      if [[ "${requires_use}" == "1" ]]; then
        printf '%s' "${line}" | grep -qE "${PATTERN_RX}" && continue   # it's a search pattern
        printf '%s' "${line}" | grep -qE "${USE_RX}"    || continue    # it doesn't open anything with that path
      fi
      printf '    MINE %s:%s\n' "${label}" "${n}"
      printf '         %s\n' "${what}"
      FINDINGS=$((FINDINGS + 1))
    done < <(grep -nE "${rx}" "${path}" 2>/dev/null || true)
  done
}

# Directories that aren't anyone's code: dependencies, build artifacts, caches.
EXCLUDE_DIRS=(node_modules .git .wrangler dist build out coverage .next .venv __pycache__ .pytest_cache _archive)

# ONE recursive grep per mine and per REPO — not one per file.
#
# An earlier version walked the tree with `find` and grepped file by file: over a couple of
# dozen repos that took 11 MINUTES. With `grep -r` it's 5 processes per repo and drops to
# seconds. A hygiene tool that takes 11 minutes doesn't get run, and one that doesn't get run
# is worthless.
scan_tree() {
  local root="$1" label="$2"
  local excl=() d
  for d in "${EXCLUDE_DIRS[@]}"; do excl+=(--exclude-dir="${d}"); done

  local m rx requires_use what hit file n line
  for m in "${MINES[@]}"; do
    rx="${m%%|@|*}"
    local rest="${m#*|@|}"
    requires_use="${rest%%|@|*}"
    what="${rest#*|@|}"
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] || continue
      file="${hit%%:*}"
      local r1="${hit#*:}"
      n="${r1%%:*}"
      line="${r1#*:}"
      [[ "${line}" =~ ^[[:space:]]*(#|//|\*|/\*) ]] && continue
      if [[ "${requires_use}" == "1" ]]; then
        printf '%s' "${line}" | grep -qE "${PATTERN_RX}" && continue
        printf '%s' "${line}" | grep -qE "${USE_RX}"    || continue
      fi
      printf '    MINE %s/%s:%s\n' "${label}" "${file#"${root}/"}" "${n}"
      printf '         %s\n' "${what}"
      FINDINGS=$((FINDINGS + 1))
    done < <(grep -rnE "${excl[@]}" \
                  --include='*.mjs' --include='*.js' --include='*.ts' \
                  --include='*.sh' --include='*.ps1' \
                  "${rx}" "${root}" 2>/dev/null || true)
  done
}

# A path is absolute if it starts with `/` (POSIX) OR with `C:/`, `D:\`, etc. (Windows).
#
# An earlier version of this script only recognized `/*`, so under Git Bash it treated
# `core.hooksPath = C:/Users/.../.config/git/hooks` as RELATIVE, glued it onto the repo path,
# and reported "directory does not exist" for a directory that did. That was exactly the bug
# family this script exists to catch — inside the script itself. It was found by running it,
# not by reading it.
resolve_hooks_path() {
  local repo="$1" hp="$2"
  if [[ "${hp}" = /* || "${hp}" =~ ^[A-Za-z]:[/\\] ]]; then
    printf '%s' "${hp}"
  else
    printf '%s/%s' "${repo}" "${hp}"
  fi
}

echo "hooks-check — git guards and cross-platform landmines"
echo

# Universe: the repos under DEV_ROOT, plus this tool's own repo if it happens to live there.
REPOS=()
for d in "${DEV_ROOT}"/*/; do
  [[ -d "${d}.git" ]] && REPOS+=("${d%/}")
done
[[ -d "${REPO_ROOT}/.git" ]] && REPOS+=("${REPO_ROOT}")

# ── 1. Configuration + 2. landmines in the hooks and what they invoke ──────────────────────
for p in "${REPOS[@]}"; do
  name="$(basename "${p}")"
  # --local on purpose: a global core.hooksPath (e.g. a shared secrets-scanning guard) can
  # make `git config core.hooksPath` resolve to something even when THIS repo never wired
  # up its own .githooks. That fallback is exactly the kind of silent per-machine state this
  # tool exists to surface, not paper over — so the audit only trusts what the repo itself
  # configured.
  hooks_path="$(git -C "${p}" config --local core.hooksPath 2>/dev/null || true)"

  if [[ -d "${p}/.githooks" && -z "${hooks_path}" ]]; then
    printf '  [!] %s: has a versioned .githooks/ but core.hooksPath is NOT set.\n' "${name}"
    printf '      This repo'"'"'s guards are OFF. Fix:\n'
    printf '      git -C "%s" config core.hooksPath .githooks\n' "${p}"
    FINDINGS=$((FINDINGS + 1))
  fi

  [[ -n "${hooks_path}" ]] || continue

  resolved="$(resolve_hooks_path "${p}" "${hooks_path}")"
  if [[ ! -d "${resolved}" ]]; then
    printf '  [!] %s: core.hooksPath points at a directory that does not exist: %s\n' "${name}" "${hooks_path}"
    printf '      It also shadows the global guard, so this repo ends up with NO hooks at all.\n'
    FINDINGS=$((FINDINGS + 1))
    continue
  fi

  for h in "${resolved}"/*; do
    [[ -f "${h}" ]] || continue
    [[ "${h}" == *.sample ]] && continue
    scan_file "${h}" "${name}/$(basename "${h}")"

    # The npm scripts a hook calls out to: that's where the real code usually lives.
    pkg="${p}/package.json"
    [[ -f "${pkg}" ]] || continue
    command -v node >/dev/null 2>&1 || continue
    while IFS=$'\t' read -r sname scmd; do
      [[ -n "${sname}" ]] || continue
      grep -qE "run (--silent )?${sname}( |$)" "${h}" || continue
      file="$(printf '%s' "${scmd}" | grep -oE '[A-Za-z0-9_./-]+\.(mjs|js|ts)' | head -1 || true)"
      [[ -n "${file}" ]] && scan_file "${p}/${file}" "${name}/${file} (via ${sname})"
    done < <(node -e '
      const p = require(process.argv[1]);
      for (const [k, v] of Object.entries(p.scripts ?? {})) console.log(k + "\t" + v);
    ' "${pkg}" 2>/dev/null || true)
  done
done

# ── 3. Landmines outside the hooks ──────────────────────────────────────────────────────────
# An earlier version scanned ONLY what a hook invokes and reported "no findings" while
# several scripts had their "run as main module" check broken. They weren't misdetected:
# they were out of scope. A landmine doesn't care whether a hook runs it or a person runs it
# by hand — and the person running it by hand doesn't have CI backing them up either.
echo
echo "Landmines outside the hooks (scripts run by hand):"
BEFORE=${FINDINGS}
for p in "${REPOS[@]}"; do
  scan_tree "${p}" "$(basename "${p}")"
done
[[ "${FINDINGS}" -eq "${BEFORE}" ]] && echo "  (none)"

# ── 4. Actually run the hooks (opt-in) ──────────────────────────────────────────────────────
if [[ "${RUN_HOOKS}" -eq 1 ]]; then
  echo
  echo "Running the pre-commit hooks for real (--run)..."
  for p in "${REPOS[@]}"; do
    name="$(basename "${p}")"
    hooks_path="$(git -C "${p}" config --local core.hooksPath 2>/dev/null || true)"
    [[ -n "${hooks_path}" ]] || continue
    resolved="$(resolve_hooks_path "${p}" "${hooks_path}")"
    pc="${resolved}/pre-commit"
    [[ -f "${pc}" ]] || continue
    if out="$(cd "${p}" && bash "${pc}" 2>&1)"; then
      printf '  ok  %s/pre-commit -> exit 0\n' "${name}"
    else
      printf '  X   %s/pre-commit -> exit %s\n' "${name}" "$?"
      printf '%s\n' "${out}" | tail -6 | sed 's/^/        /'
      FINDINGS=$((FINDINGS + 1))
    fi
  done
fi

echo
if [[ "${FINDINGS}" -eq 0 ]]; then
  echo "No findings."
  exit 0
fi
printf '%s finding(s). See above for what each one means.\n' "${FINDINGS}"
exit 1
