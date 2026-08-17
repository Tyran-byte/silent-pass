# tests/run.ps1 — builds a throwaway DevRoot full of toy git repos and checks that
# bin/hooks-check.ps1 flags exactly what it should: real landmines and real
# misconfiguration, nothing else. Fixtures are generated here, not stored as static files,
# so both this script and tests/run.sh stay the single source of truth for "what counts as
# a finding."
$ErrorActionPreference = "Stop"

$Here = $PSScriptRoot
$RepoRoot = Split-Path $Here -Parent
$Checker = Join-Path $RepoRoot "bin\hooks-check.ps1"

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("silent-pass-tests-" + [System.Guid]::NewGuid().ToString("N"))
$DevRoot = Join-Path $Work "dev"
New-Item -ItemType Directory -Force -Path $DevRoot | Out-Null

$script:failed = 0

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Desc)
    if ($Haystack -like "*$Needle*") {
        Write-Host ("  ok   {0}" -f $Desc)
    } else {
        Write-Host ("  FAIL {0}" -f $Desc) -ForegroundColor Red
        Write-Host ("       expected to find: {0}" -f $Needle) -ForegroundColor Red
        $script:failed++
    }
}

function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Desc)
    if ($Haystack -like "*$Needle*") {
        Write-Host ("  FAIL {0}" -f $Desc) -ForegroundColor Red
        Write-Host ("       should NOT have found: {0}" -f $Needle) -ForegroundColor Red
        $script:failed++
    } else {
        Write-Host ("  ok   {0}" -f $Desc)
    }
}

function New-TestRepo {
    param([string]$Name)
    $p = Join-Path $DevRoot $Name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    git -C $p init -q
    return $p
}

try {
    # 1. repo-clean: hooks configured correctly, no landmines anywhere.
    $p = New-TestRepo "repo-clean"
    New-Item -ItemType Directory -Force -Path (Join-Path $p ".githooks") | Out-Null
    Set-Content -Path (Join-Path $p ".githooks\pre-commit") -Value "#!/usr/bin/env bash`necho `"clean hook, nothing to see here`""
    git -C $p config core.hooksPath .githooks

    # 2. repo-hooks-off: .githooks/ versioned, core.hooksPath deliberately left unset.
    $p = New-TestRepo "repo-hooks-off"
    New-Item -ItemType Directory -Force -Path (Join-Path $p ".githooks") | Out-Null
    Set-Content -Path (Join-Path $p ".githooks\pre-commit") -Value "#!/usr/bin/env bash`necho `"this hook is never installed`""

    # 3. repo-broken-path: core.hooksPath points at a directory that doesn't exist.
    $p = New-TestRepo "repo-broken-path"
    git -C $p config core.hooksPath .hooks-that-do-not-exist

    # 4. repo-landmine: correctly configured, but a script it calls via `npm run` uses a
    # broken idiom. Routing through package.json scripts on purpose: that's the real-world
    # shape (a thin hook that delegates to `npm run <script>`), and it's what the hook-chain
    # scanner (step 2) is built to follow.
    $p = New-TestRepo "repo-landmine"
    New-Item -ItemType Directory -Force -Path (Join-Path $p ".githooks") | Out-Null
    Set-Content -Path (Join-Path $p ".githooks\pre-commit") -Value "#!/usr/bin/env bash`nnpm run --silent check"
    git -C $p config core.hooksPath .githooks
    Set-Content -Path (Join-Path $p "package.json") -Value '{ "scripts": { "check": "node scripts/check.mjs" } }'
    New-Item -ItemType Directory -Force -Path (Join-Path $p "scripts") | Out-Null
    $checkMjs = @'
import { readFileSync } from "node:fs";
const here = new URL('..', import.meta.url).pathname;
const cfg = readFileSync(here + "/config.json");
console.log(cfg);
'@
    Set-Content -Path (Join-Path $p "scripts\check.mjs") -Value $checkMjs
    # a second landmine OUTSIDE the hook chain — only the tree-wide scan (step 3) should
    # catch this one, not the hook-chain scan (step 2).
    $standaloneMjs = @'
if (import.meta.url === `file://${process.argv[1]}`) {
  console.log("running as main");
}
'@
    Set-Content -Path (Join-Path $p "scripts\standalone.mjs") -Value $standaloneMjs

    # 5. repo-false-positive: same substrings appear, but never in a way that's actually used.
    $p = New-TestRepo "repo-false-positive"
    New-Item -ItemType Directory -Force -Path (Join-Path $p ".githooks") | Out-Null
    $fpHook = @'
#!/usr/bin/env bash
# see notes at /Users/example/docs/setup.md for background
grep -rE "/Users/[a-z]+/" "$1" && echo "found a home path reference in the diff"
'@
    Set-Content -Path (Join-Path $p ".githooks\pre-commit") -Value $fpHook
    git -C $p config core.hooksPath .githooks

    Write-Host "Running hooks-check.ps1 against synthetic fixtures..."
    Write-Host ""
    $output = & pwsh -NoProfile -File $Checker -DevRoot $DevRoot 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Host $output
    Write-Host ""
    Write-Host "Assertions:"

    Assert-Contains $output "repo-hooks-off: has a versioned .githooks/ but core.hooksPath is NOT set" `
        "flags a repo with versioned hooks and no core.hooksPath"

    Assert-Contains $output "repo-broken-path: core.hooksPath points at a directory that does not exist" `
        "flags a core.hooksPath pointing at a missing directory"

    Assert-Contains $output "repo-landmine/scripts/check.mjs (via check)" `
        "flags the landmine inside a script invoked by the hook (via its npm script)"
    Assert-Contains $output "duplicated drive letter on Windows" `
        "explains the import.meta.url landmine"

    Assert-Contains $output "repo-landmine/scripts" `
        "the tree-wide scan (step 3) catches landmines outside the hook chain"
    Assert-Contains $output "ALWAYS false on Windows" `
        "explains the file://argv[1] landmine"

    Assert-NotContains $output "repo-clean/" `
        "a clean repo produces no findings at all"

    Assert-NotContains $output "repo-false-positive/pre-commit:2" `
        "a comment reference to a home path is not flagged"
    Assert-NotContains $output "repo-false-positive/pre-commit:3" `
        "a grep search pattern for a home path is not flagged (it searches for the text, doesn't open it)"

    if ($code -eq 1) {
        Write-Host "  ok   exit code is 1 (findings exist)"
    } else {
        Write-Host ("  FAIL exit code should be 1 when findings exist (got {0})" -f $code) -ForegroundColor Red
        $script:failed++
    }

    Write-Host ""
    if ($script:failed -eq 0) {
        Write-Host "All tests passed." -ForegroundColor Green
        exit 0
    }
    Write-Host ("{0} test(s) failed." -f $script:failed) -ForegroundColor Yellow
    exit 1
}
finally {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
