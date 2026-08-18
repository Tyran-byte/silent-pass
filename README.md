# silent-pass

Audit your git hooks for guards that are silently off, and for cross-platform landmines that
make a hook (or any script it calls) fail — or worse, quietly do nothing — on one platform
while working perfectly on another.

## Usage

```bash
# POSIX (macOS/Linux, or Git Bash on Windows)
bin/hooks-check.sh --dev-root ~/dev
bin/hooks-check.sh --dev-root ~/dev --run

# Windows (PowerShell 7+)
pwsh bin/hooks-check.ps1 -DevRoot ~/dev
pwsh bin/hooks-check.ps1 -DevRoot ~/dev -Run
```

`--dev-root` / `-DevRoot` sets the directory of repos to scan — defaults to `~/dev`
(`$HOME/dev` on POSIX, `%USERPROFILE%\dev` on Windows); only immediate subdirectories that
are git repos get scanned. `--run` / `-Run` additionally executes each repo's `pre-commit`
hook and reports pass/fail — opt-in, since a hook can have side effects.

Exit code `0` = nothing found, `1` = at least one finding, so it's safe to wire into CI as a
gate.

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

## Why this exists

A pre-commit hook in a real project turned out to have been broken on Windows since the day
it was written. The cause was one line:

```js
const here = new URL('..', import.meta.url).pathname;
```

On Windows, `pathname` returns something like `/C:/Users/.../project/`, with a leading
slash — joined with the rest of the path, that produces a duplicated drive letter, and Node
fails to open it. The exact same line works perfectly on macOS and Linux. Every commit made
from the Windows machine either failed outright or got pushed through with `--no-verify`,
and because the failure never happened where the code was written, nobody saw it. The same
codebase also had a script with what looked like a standard "run this file directly" guard:

```js
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
```

On Windows this comparison is **always false** — `import.meta.url` yields
`file:///C:/Users/.../script.mjs` while `process.argv[1]` yields `C:\Users\...\script.mjs`,
and the two never match. The script runs, exits 0, and does nothing — worse than crashing,
since a crash gets noticed. Neither bug is exotic: both are common Node/JS idioms that
happen to encode a POSIX assumption, and `silent-pass` exists to catch exactly this — a
guard, or a script it depends on, that fails silently enough that nobody notices.

There's a second, unrelated way guards go silently missing: `core.hooksPath` is a
**per-machine** git setting — not stored in the repository, not synced by anything. Every
fresh clone of a repo that ships its own hooks under version control (typically
`.githooks/`) starts with those hooks **turned off** until someone runs
`git config core.hooksPath .githooks` on that machine. A repo can look fully protected in
its own tree and be running with zero enforcement on a second machine, a CI runner, or
after a fresh clone — invisible unless you go looking.

## What it checks

- **Configuration.** A versioned `.githooks/` with `core.hooksPath` missing or pointing at a
  directory that doesn't exist — either way, the repo's hooks are not actually running.
- **Landmines in hooks.** Hook scripts, and any script they invoke via an npm script
  (`npm run <name>`, resolved through `package.json`), scanned for idioms known to behave
  differently across platforms — see [Built-in landmines](#built-in-landmines).
- **Landmines tree-wide.** Every `.mjs`/`.js`/`.ts`/`.sh`/`.ps1` file in each repo, since a
  landmine doesn't care whether a hook runs it or a person runs it by hand.

## Built-in landmines

| Pattern | What breaks | Fix |
|---|---|---|
| `new URL('..', import.meta.url).pathname` | Duplicated drive letter on Windows → `ENOENT` | Use `fileURLToPath(import.meta.url)` |
| `import.meta.url === \`file://${process.argv[1]}\`` | Always `false` on Windows → the "run as main module" block never fires, script exits 0 doing nothing | Compare `fileURLToPath(import.meta.url)` with `resolve(process.argv[1])` |
| `process.argv[1].split('/')` | Windows uses `\` as its separator, so this never splits anything | Use `path.sep`, or a cross-platform path library |
| A hardcoded machine-specific home path (`/Users/<name>/…`, `C:\Users\<name>\…`) | Doesn't exist on any other machine | Use an environment variable (`$HOME`, `%USERPROFILE%`) or a relative path |

A hardcoded path is only reported when the line actually **uses** it to open, read, `cd`
into, or `import`/`require` something — not when it appears in a comment or as a search
pattern passed to `grep`/`rg`/a regex. A checker that cries wolf gets ignored, and an ignored
checker stops doing its job, so this precision is treated as the actual feature.

## Adding a landmine

Landmines are a small list near the top of each script — a regex plus the explanation text
to print. Add an entry to `MINES` in `bin/hooks-check.sh` and the mirrored `$Mines` in
`bin/hooks-check.ps1`, keeping both in sync so POSIX and Windows agree on what counts as a
finding. For a hardcoded-path check rather than a guaranteed-bug idiom, set the "requires
use" flag so it only fires on lines that actually use the path (see
[Built-in landmines](#built-in-landmines)).

## License

MIT — see [LICENSE](LICENSE).
