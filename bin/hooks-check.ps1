# hooks-check.ps1 — audits git hooks across a directory of repos and hunts the bug family
# "works fine on one platform, fails silently on the other." Twin of bin/hooks-check.sh.
#
# WHY THIS EXISTS
# ----------------
# A pre-commit hook can be broken on one platform and nobody notices, because the machine
# where it was written never sees the failure. A classic example: `new URL('..',
# import.meta.url).pathname` returns `/C:/Users/...` with a leading slash on Windows;
# joining that with other path segments produces a path with a duplicated drive letter, and
# Node fails to open it. On macOS/Linux the exact same line works perfectly. Every commit
# from the broken machine either fails outright or gets pushed through with `--no-verify`,
# and nothing about the failure is visible from the platform where the code was written.
#
# A guard that silently doesn't protect anything is worse than no guard: it creates false
# confidence. This script exists to catch that failure mode before it costs months.
#
# WHAT IT CHECKS
# ---------------
# 1. CONFIGURATION. `core.hooksPath` is a per-machine git setting — it does NOT travel with
#    the repo. Every fresh clone of a repo with versioned hooks starts with those hooks
#    turned OFF until someone points `core.hooksPath` at them. Flags: repos with a versioned
#    `.githooks/` and no `core.hooksPath`, and a `hooksPath` that points at a directory that
#    doesn't exist.
#
# 2. CROSS-PLATFORM LANDMINES. Scans the hooks and the scripts they invoke for idioms that
#    behave differently depending on the operating system:
#      a) `new URL(..., import.meta.url).pathname`  -> invalid path on Windows
#      b) `import.meta.url === \`file://${process.argv[1]}\`` -> ALWAYS false on Windows
#         (import.meta.url yields `file:///C:/...`, argv[1] yields `C:\...`), so the "run as
#         main module" block never executes: the script exits 0 without doing anything. This
#         is worse than crashing, because it looks like it worked.
#      c) `process.argv[1].split('/')` -> on Windows the separator is `\`, this never splits
#         anything.
#    Plus absolute paths belonging to a single machine (a home directory under `/Users/`, or
#    a hardcoded `C:\Users\...`).
#
# 3. -Run (optional): actually executes the pre-commit hooks. NOT the default, because a hook
#    can have side effects; with -Run it's an explicit decision. It's the only thing here
#    that catches a hook broken for a reason this script doesn't know about yet.
[CmdletBinding()]
param(
    [string]$DevRoot = (Join-Path $env:USERPROFILE "dev"),
    [switch]$Run
)
$ErrorActionPreference = "Continue"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$findings = 0

# Pattern, and what happens when it matches. The "what" text is printed as-is: it has to be
# enough to understand the problem without opening the file.
$Mines = @(
    @{ rx = 'import\.meta\.url\s*\)\s*\.pathname'
       what = 'duplicated drive letter on Windows -> the script dies with ENOENT. Use fileURLToPath() instead' }
    @{ rx = 'import\.meta\.url\s*===\s*`file://\$\{process\.argv\[1\]\}`'
       what = 'ALWAYS false on Windows -> the "run as main module" block never executes and the script exits 0 without doing anything. Compare fileURLToPath(import.meta.url) with resolve(process.argv[1]) instead' }
    @{ rx = "process\.argv\[1\]\.split\('/'\)"
       what = 'on Windows the path separator is \, this never splits anything -> the comparison is always false and the script silently does nothing' }
    @{ rx = '/Users/[a-z]+/'
       what = 'absolute macOS home path: does not exist on Windows/Linux'
       requiresUse = $true }
    @{ rx = 'C:\\\\Users\\\\'
       what = 'absolute Windows path: does not exist on macOS/Linux'
       requiresUse = $true }
)

# An absolute path is only a landmine if the script actually USES it to open something.
# There are two cases where it appears and is perfectly fine:
#   - inside a comment (a reference to a document, a provenance note)
#   - as a search PATTERN: `grep -cE "/Users/name/dev/..."` doesn't open that path, it
#     searches for that text inside another file. "Fixing" it breaks the script.
# The first version of this checker flagged a batch of absolute-path hits and every single
# one turned out to be a false positive. A checker that cries wolf gets ignored, and an
# ignored checker stops doing its job. Hence this heuristic.
$UseRx = '(readFile|writeFile|readdir|existsSync|createReadStream|require\(|from\s+[''"]|import\s+[''"]|NODE_PATH|\bcd\s|\bsource\s|^\s*[\w_]+\s*=\s*[''"])'
$PatternRx = '\b(grep|egrep|rg|awk|sed|match|test\(|RegExp)\b'

function Scan-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { return }
    $lines = Get-Content $Path -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        # Comments don't execute. The `*` covers /** */ block continuation lines — without
        # it, a documentation reference inside a JSDoc comment gets reported as a bug.
        if ($l -match '^\s*(#|//|\*|/\*)') { continue }
        foreach ($m in $Mines) {
            if ($l -match $m.rx) {
                if ($m.requiresUse) {
                    if ($l -match $PatternRx) { continue }        # it's a search pattern
                    if ($l -notmatch $UseRx) { continue }         # it doesn't open anything with that path
                }
                Write-Host ("    MINE {0}:{1}" -f $Label, ($i + 1)) -ForegroundColor Yellow
                Write-Host ("         {0}" -f $m.what) -ForegroundColor DarkYellow
                $script:findings++
            }
        }
    }
}

Write-Host "hooks-check — git guards and cross-platform landmines"
Write-Host ""

$repos = @(Get-ChildItem $DevRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName ".git") } | Select-Object -ExpandProperty FullName)
if (Test-Path (Join-Path $RepoRoot ".git")) { $repos += $RepoRoot }

foreach ($p in $repos) {
    $name = Split-Path $p -Leaf
    # --local on purpose: a global core.hooksPath (e.g. a shared secrets-scanning guard) can
    # make `git config core.hooksPath` resolve to something even when THIS repo never wired
    # up its own .githooks. That fallback is exactly the kind of silent per-machine state
    # this tool exists to surface, not paper over — so the audit only trusts what the repo
    # itself configured.
    $hooksPath = (git -C $p config --local core.hooksPath 2>$null)
    $hasVersioned = Test-Path (Join-Path $p ".githooks")

    # --- 1. Configuration ---
    if ($hasVersioned -and -not $hooksPath) {
        Write-Host ("  [!] {0}: has a versioned .githooks/ but core.hooksPath is NOT set." -f $name) -ForegroundColor Red
        Write-Host ("      This repo's guards are OFF. Fix:") -ForegroundColor Red
        Write-Host ("      git -C '{0}' config core.hooksPath .githooks" -f $p)
        $findings++
    }
    if ($hooksPath) {
        $resolved = if ([System.IO.Path]::IsPathRooted($hooksPath)) { $hooksPath } else { Join-Path $p $hooksPath }
        if (-not (Test-Path $resolved)) {
            Write-Host ("  [!] {0}: core.hooksPath points at a directory that does not exist: {1}" -f $name, $hooksPath) -ForegroundColor Red
            Write-Host ("      It also shadows the global guard, so this repo ends up with NO hooks at all.") -ForegroundColor Red
            $findings++
            continue
        }
        # --- 2. Landmines in the hooks and what they invoke ---
        $hooks = Get-ChildItem $resolved -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.sample" }
        foreach ($h in $hooks) {
            Scan-File $h.FullName "$name/$($h.Name)"
            # The npm scripts a hook calls out to: that's where the real code usually lives.
            $pkg = Join-Path $p "package.json"
            if (-not (Test-Path $pkg)) { continue }
            $scripts = (Get-Content $pkg -Raw | ConvertFrom-Json).scripts
            if (-not $scripts) { continue }
            $hookContent = Get-Content $h.FullName -Raw
            foreach ($s in $scripts.PSObject.Properties) {
                if ($hookContent -notmatch [regex]::Escape("run --silent $($s.Name)") -and
                    $hookContent -notmatch [regex]::Escape("run $($s.Name)")) { continue }
                # Pull the file out of the command (node scripts/x.mjs ...)
                if ($s.Value -match '([\w\-/\\\.]+\.(mjs|js|ts))') {
                    Scan-File (Join-Path $p $Matches[1]) "$name/$($Matches[1]) (via $($s.Name))"
                }
            }
        }
    }
}

# --- 3. Landmines outside the hooks -------------------------------------------------
# An earlier version scanned ONLY what a hook invokes and reported "no findings" while
# several scripts had their "run as main module" check broken on Windows. They weren't
# misdetected: they were out of scope. A landmine doesn't care whether a hook runs it or a
# person runs it by hand — and the person running it by hand doesn't have CI backing them up
# either. So the sweep covers the whole repo.
Write-Host ""
Write-Host "Landmines outside the hooks (scripts run by hand):"
$withMines = 0
foreach ($p in $repos) {
    $name = Split-Path $p -Leaf
    # Two fixes, both found while writing the .sh twin:
    #
    # 1. The exclusion filter must use [\\/] and not just \: with the Windows separator
    #    hardcoded, macOS/Linux would NOT exclude node_modules and the script would scan tens
    #    of thousands of unrelated files. Same bug family this script exists to catch.
    # 2. node_modules and .git alone aren't enough to exclude. Bundler output directories
    #    (e.g. Cloudflare Workers' .wrangler/tmp/) embed absolute paths from the machine that
    #    built them, producing findings in a generated file nobody wrote or versions. A
    #    checker that reports on generated artifacts trains people to ignore it.
    $exclude = 'node_modules|\.git|\.wrangler|dist|build|out|coverage|\.next|\.venv|__pycache__|\.pytest_cache|_archive'
    $files = Get-ChildItem $p -Recurse -Include *.mjs, *.js, *.ts, *.sh, *.ps1 -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "[\\/]($exclude)[\\/]" }
    foreach ($f in $files) {
        $before = $findings
        Scan-File $f.FullName ("{0}/{1}" -f $name, $f.FullName.Replace("$p\", ""))
        if ($findings -gt $before) { $withMines++ }
    }
}
if ($withMines -eq 0) { Write-Host "  (none)" }

if ($Run) {
    Write-Host ""
    Write-Host "Running the pre-commit hooks for real (-Run)..."
    foreach ($p in $repos) {
        $name = Split-Path $p -Leaf
        $hooksPath = (git -C $p config --local core.hooksPath 2>$null)
        if (-not $hooksPath) { continue }
        $resolved = if ([System.IO.Path]::IsPathRooted($hooksPath)) { $hooksPath } else { Join-Path $p $hooksPath }
        $pc = Join-Path $resolved "pre-commit"
        if (-not (Test-Path $pc)) { continue }
        Push-Location $p
        $out = & bash $pc 2>&1
        $code = $LASTEXITCODE
        Pop-Location
        if ($code -eq 0) {
            Write-Host ("  ok  {0}/pre-commit -> exit 0" -f $name) -ForegroundColor Green
        } else {
            Write-Host ("  X   {0}/pre-commit -> exit {1}" -f $name, $code) -ForegroundColor Red
            ($out | Select-Object -Last 6) | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
            $findings++
        }
    }
}

Write-Host ""
if ($findings -eq 0) {
    Write-Host "No findings." -ForegroundColor Green
    exit 0
}
Write-Host ("{0} finding(s). See above for what each one means." -f $findings) -ForegroundColor Yellow
exit 1
