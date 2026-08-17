#!/usr/bin/env bash
# tests/run.sh — builds a throwaway DEV_ROOT full of toy git repos and checks that
# bin/hooks-check.sh flags exactly what it should: real landmines and real misconfiguration,
# nothing else. Fixtures are generated here, not stored as static files, so both this script
# and tests/run.ps1 stay the single source of truth for "what counts as a finding."
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
CHECKER="${REPO_ROOT}/bin/hooks-check.sh"

WORK="$(mktemp -d)"
DEV_ROOT="${WORK}/dev"
mkdir -p "${DEV_ROOT}"
trap 'rm -rf "${WORK}"' EXIT

FAILED=0
assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    printf '  ok   %s\n' "${desc}"
  else
    printf '  FAIL %s\n       expected to find: %s\n' "${desc}" "${needle}"
    FAILED=$((FAILED + 1))
  fi
}
assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    printf '  FAIL %s\n       should NOT have found: %s\n' "${desc}" "${needle}"
    FAILED=$((FAILED + 1))
  else
    printf '  ok   %s\n' "${desc}"
  fi
}

mk_repo() { mkdir -p "${DEV_ROOT}/$1" && git -C "${DEV_ROOT}/$1" init -q; }

# 1. repo-clean: hooks configured correctly, no landmines anywhere.
mk_repo repo-clean
mkdir -p "${DEV_ROOT}/repo-clean/.githooks"
cat > "${DEV_ROOT}/repo-clean/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "clean hook, nothing to see here"
EOF
git -C "${DEV_ROOT}/repo-clean" config core.hooksPath .githooks

# 2. repo-hooks-off: .githooks/ versioned, core.hooksPath deliberately left unset.
mk_repo repo-hooks-off
mkdir -p "${DEV_ROOT}/repo-hooks-off/.githooks"
cat > "${DEV_ROOT}/repo-hooks-off/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "this hook is never installed"
EOF

# 3. repo-broken-path: core.hooksPath points at a directory that doesn't exist.
mk_repo repo-broken-path
git -C "${DEV_ROOT}/repo-broken-path" config core.hooksPath .hooks-that-do-not-exist

# 4. repo-landmine: correctly configured, but a script it calls via `npm run` uses a broken
# idiom. Routing through package.json scripts on purpose: that's the real-world shape (a
# thin hook that delegates to `npm run <script>`), and it's what the hook-chain scanner
# (step 2) is built to follow.
mk_repo repo-landmine
mkdir -p "${DEV_ROOT}/repo-landmine/.githooks"
cat > "${DEV_ROOT}/repo-landmine/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
npm run --silent check
EOF
git -C "${DEV_ROOT}/repo-landmine" config core.hooksPath .githooks
cat > "${DEV_ROOT}/repo-landmine/package.json" <<'EOF'
{ "scripts": { "check": "node scripts/check.mjs" } }
EOF
mkdir -p "${DEV_ROOT}/repo-landmine/scripts"
cat > "${DEV_ROOT}/repo-landmine/scripts/check.mjs" <<'EOF'
import { readFileSync } from "node:fs";
const here = new URL('..', import.meta.url).pathname;
const cfg = readFileSync(here + "/config.json");
console.log(cfg);
EOF
# a second landmine that lives OUTSIDE the hook chain — only the tree-wide scan (step 3)
# should catch this one, not the hook-chain scan (step 2).
cat > "${DEV_ROOT}/repo-landmine/scripts/standalone.mjs" <<'EOF'
if (import.meta.url === `file://${process.argv[1]}`) {
  console.log("running as main");
}
EOF

# 5. repo-false-positive: the same substrings appear, but never in a way that's actually used.
mk_repo repo-false-positive
mkdir -p "${DEV_ROOT}/repo-false-positive/.githooks"
cat > "${DEV_ROOT}/repo-false-positive/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
# see notes at /Users/example/docs/setup.md for background
grep -rE "/Users/[a-z]+/" "$1" && echo "found a home path reference in the diff"
EOF
git -C "${DEV_ROOT}/repo-false-positive" config core.hooksPath .githooks

echo "Running hooks-check.sh against synthetic fixtures..."
echo
OUTPUT="$("${CHECKER}" --dev-root "${DEV_ROOT}" 2>&1)"
CODE=$?
echo "${OUTPUT}"
echo
echo "Assertions:"

assert_contains   "${OUTPUT}" "repo-hooks-off: has a versioned .githooks/ but core.hooksPath is NOT set" \
  "flags a repo with versioned hooks and no core.hooksPath"

assert_contains   "${OUTPUT}" "repo-broken-path: core.hooksPath points at a directory that does not exist" \
  "flags a core.hooksPath pointing at a missing directory"

assert_contains   "${OUTPUT}" "repo-landmine/scripts/check.mjs (via check)" \
  "flags the landmine inside a script invoked by the hook (via its npm script)"
assert_contains   "${OUTPUT}" "duplicated drive letter on Windows" \
  "explains the import.meta.url landmine"

assert_contains   "${OUTPUT}" "repo-landmine/scripts/standalone.mjs" \
  "the tree-wide scan (step 3) catches landmines outside the hook chain"
assert_contains   "${OUTPUT}" "ALWAYS false on Windows" \
  "explains the file://argv[1] landmine"

assert_not_contains "${OUTPUT}" "repo-clean/" \
  "a clean repo produces no findings at all"

assert_not_contains "${OUTPUT}" "repo-false-positive/pre-commit:2" \
  "a comment reference to a home path is not flagged"
assert_not_contains "${OUTPUT}" "repo-false-positive/pre-commit:3" \
  "a grep search pattern for a home path is not flagged (it searches for the text, doesn't open it)"

if [[ "${CODE}" -eq 1 ]]; then
  printf '  ok   %s\n' "exit code is 1 (findings exist)"
else
  printf '  FAIL %s (got %s)\n' "exit code should be 1 when findings exist" "${CODE}"
  FAILED=$((FAILED + 1))
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
fi
printf '%s test(s) failed.\n' "${FAILED}"
exit 1
