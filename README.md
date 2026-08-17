# silent-pass

Audit your git hooks for guards that are silently off, and for cross-platform landmines that
make a hook (or any script it calls) fail — or worse, quietly do nothing — on one platform
while working perfectly on another.

## Why this exists

On 2026-08-14, a pre-commit hook in a production repository turned out to have been broken
on Windows since the day it was written. The cause was one line:

```js
const here = new URL('..', import.meta.url).pathname;
```

On Windows, `pathname` returns something like `/C:/Users/.../project/`, with a leading
slash. Joined with the rest of the path, that produces a path with a duplicated drive
letter, and Node fails to open it. On macOS and Linux the exact same line works perfectly.
Every commit made from the Windows machine either failed outright or got pushed through
with `--no-verify` — and because the failure never happened on the machine (or in CI) where
the code was written, nobody saw it. It shipped, and stayed broken, for months.

The same codebase also had scripts that looked like they had a standard "run this file
directly" guard:

```js
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
```

On Windows this comparison is **always false** — `import.meta.url` yields
`file:///C:/Users/.../script.mjs` while `process.argv[1]` yields `C:\Users\...\script.mjs`,
and the two never match. The script runs, exits 0, and does nothing. That's worse than
crashing: a crash gets noticed.

Neither bug is exotic. Both are common Node/JS idioms that happen to encode a POSIX
assumption. `silent-pass` exists to catch this specific failure mode — a guard, or any
script a guard depends on, that doesn't do what it's supposed to do on some platform, and
fails silently enough that nobody notices.

There's a second, unrelated way guards go silently missing: `core.hooksPath` is a
**per-machine** git setting. It is not stored in the repository, does not travel with a
clone, and is not synced by anything. Every fresh clone of a repository that ships its own
hooks under version control (typically `.githooks/`) starts with those hooks **turned off**
until someone runs `git config core.hooksPath .githooks` on that specific machine. A repo
can look fully protected in its own tree and be running with zero enforcement on a second
machine, a CI runner, or after a fresh clone — and nothing about that is visible unless you
go looking.

## What it checks

1. **Configuration.** Does a repository have a versioned hooks directory (`.githooks/` by
   default) without `core.hooksPath` pointing at it? Does `core.hooksPath` point at a
   directory that doesn't exist? Both mean the repo's hooks are not actually running.
2. **Cross-platform landmines.** Scans hook scripts, and any script they invoke via an npm
   script (`npm run <name>` inside the hook, resolved through `package.json`), for idioms
   known to behave differently across operating systems — see [Built-in landmines](#built-in-landmines)
   below. A separate, tree-wide pass also scans every `.mjs`/`.js`/`.ts`/`.sh`/`.ps1` file in
   each repo, because a landmine doesn't care whether a git hook runs it or a person runs it
   by hand — and the person running it by hand usually doesn't have CI backing them up
   either.
3. **`--run` / `-Run` (opt-in).** Actually executes each repo's `pre-commit` hook and reports
   pass/fail. Not the default, since a hook can have side effects — with the flag it's an
   explicit choice.

## Usage

```bash
# POSIX (macOS/Linux, or Git Bash on Windows)
bin/hooks-check.sh --dev-root ~/dev
bin/hooks-check.sh --dev-root ~/dev --run

# Windows (PowerShell 7+)
pwsh bin/hooks-check.ps1 -DevRoot ~/dev
pwsh bin/hooks-check.ps1 -DevRoot ~/dev -Run
```

`--dev-root` / `-DevRoot` points at a directory containing your repositories as immediate
subdirectories (e.g. `~/dev/project-a`, `~/dev/project-b`, ...). It defaults to `~/dev`
(`$HOME/dev` on POSIX, `%USERPROFILE%\dev` on Windows). Only directories that are git
repositories (i.e. contain a `.git`) are scanned; everything else under `--dev-root` is
ignored.

Exit code is `0` when nothing was found, `1` when there's at least one finding — so it's
safe to wire into CI as a gate.

## Example output

**Findings (exit 1):**

```
hooks-check — git guards and cross-platform landmines

  [!] my-app: has a versioned .githooks/ but core.hooksPath is NOT set.
      This repo's guards are OFF. Fix:
      git -C "/home/me/dev/my-app" config core.hooksPath .githooks
    MINE other-app/scripts/build.mjs (via prebuild):14
         duplicated drive letter on Windows -> the script dies with ENOENT. Use fileURLToPath() instead

Landmines outside the hooks (scripts run by hand):
    MINE other-app/scripts/release.mjs:3
         ALWAYS false on Windows -> the "run as main module" block never executes and the
         script exits 0 without doing anything. Compare fileURLToPath(import.meta.url) with
         resolve(process.argv[1]) instead

2 finding(s). See above for what each one means.
```

**Clean (exit 0):**

```
hooks-check — git guards and cross-platform landmines

Landmines outside the hooks (scripts run by hand):
  (none)

No findings.
```

## Built-in landmines

| Pattern | What breaks | Fix |
|---|---|---|
| `new URL('..', import.meta.url).pathname` | Duplicated drive letter on Windows → `ENOENT` | Use `fileURLToPath(import.meta.url)` |
| `import.meta.url === \`file://${process.argv[1]}\`` | Always `false` on Windows → the "run as main module" block never fires, script exits 0 doing nothing | Compare `fileURLToPath(import.meta.url)` with `resolve(process.argv[1])` |
| `process.argv[1].split('/')` | Windows uses `\` as its separator, so this never splits anything | Use `path.sep`, or a cross-platform path library |
| A hardcoded machine-specific home path (`/Users/<name>/…`, `C:\Users\<name>\…`) | Doesn't exist on any other machine | Use an environment variable (`$HOME`, `%USERPROFILE%`) or a relative path |

A hardcoded path is only reported when the line actually **uses** it to open, read, `cd`
into, or `import`/`require` something. A path that appears inside a comment, or as a search
pattern passed to `grep`/`rg`/a regex (`grep -E "/Users/[a-z]+/" some-file`, which searches
*for* that text rather than opening that path), is not a landmine and is not flagged.

This distinction exists because the first version of this checker didn't make it, and threw
a wall of false positives that made the real findings easy to miss. **A checker that cries
wolf gets ignored, and an ignored checker stops doing its job** — so precision here is
treated as the actual feature, not a nice-to-have.

## Adding a landmine

Landmines live as a small list near the top of each script — a regex plus the explanation
text to print when it matches. Add a new entry to the `MINES` array in `bin/hooks-check.sh`
and the mirrored `$Mines` array in `bin/hooks-check.ps1`; keep the two lists in sync, since
one script covers POSIX and the other covers Windows and they're meant to agree on what
counts as a finding. If the new landmine is a hardcoded-path style check rather than a
guaranteed-bug idiom, set its "requires use" flag so it only fires on lines that actually use
the path (see [Built-in landmines](#built-in-landmines) above).

## Tests

`tests/run.sh` and `tests/run.ps1` build a disposable directory of toy git repositories —
some correctly configured, some with `core.hooksPath` missing or pointing nowhere, some with
real landmines, some with landmine-shaped text that should **not** be flagged (comments,
grep patterns) — run the checker against them, and assert on the output. No fixtures are
checked into the repo as static files; both test scripts generate their fixtures from
scratch on every run, so there's nothing to go stale.

```bash
bash tests/run.sh      # POSIX / Git Bash
pwsh tests/run.ps1      # Windows / PowerShell 7+
```

CI (`.github/workflows/ci.yml`) runs both across an `ubuntu-latest` + `windows-latest`
matrix, which is the whole point: a tool about cross-platform bugs that only tests itself on
one platform would be missing its own thesis.

## License

MIT — see [LICENSE](LICENSE).
