# PowerShell Scripts TUI — developer notes

A terminal UI (pure PowerShell 7, no runtime dependencies) for running PowerShell
scripts on an Ubuntu server. See README.md for user-facing docs.

## Module layout

Everything lives in `src/*.psm1`, imported globally by `psscripts.ps1` in this order:

| Module | Responsibility |
| --- | --- |
| `Core.psm1` | config + defaults + validation warnings, paths, `.env` parsing, secret redaction, Night Owl theme + truecolor/256 ANSI, display-width helpers (wide chars), quote-aware arg splitting, data retention |
| `Scripts.psm1` | scripts repo sync (clone / per-step-checked hard reset) and script discovery (`script.json`, entry resolution) |
| `Deps.psm1` | AST-based dependency detection (`#Requires` versions honored), per-script module dirs, install/upgrade command generation |
| `Runner.psm1` | non-blocking process execution, per-script locks, `/proc` resource sampling + series, timeouts, log files, history, webhook with retry + dead-letter queue |
| `Cron.psm1` | crontab managed block, cron validation, next-occurrence calculation, NL→cron via OpenRouter |
| `Tui.psm1` | the TUI: rendering, modes, key/mouse handling, run queue |

Rules of thumb:
- Lower modules never import higher ones. `Tui` may call everything; `Core` calls nothing else.
- Anything that pads, truncates, or wraps text for the terminal must go through
  `Format-PssCell` / `Get-PssDisplayWidth` (display cells, not `.Length`) or wide
  characters shear the panel borders.
- All function names use the `Pss` prefix (`Tui`-prefixed helpers are internal to Tui.psm1).

## The run-handle contract (Runner.psm1)

A "run handle" is a mutable hashtable returned by `Start-PssRun` (scripts; full
pipeline) or `Start-PssTask` (system tasks; streaming only, no history/webhook/lock).
The owner loop must:

1. Poll `Update-PssRun -Handle $h` every tick — returns new (secret-redacted) output
   lines and enforces the timeout.
2. Call `Measure-PssResources -Handle $h` about once per `monitorIntervalMs`
   (no-op without `/proc`, e.g. macOS dev machines).
3. When `Test-PssRunFinished -Handle $h` is true, call `Complete-PssRun -Handle $h`
   exactly once — it finalizes status, releases the per-script lock, writes history,
   and fires the webhook. It is idempotent via `$h.Completed`.

Handles that never started still satisfy the contract: `Start-PssRun` returns a
`Status='skipped'` handle when the per-script lock is held (already-running), and
`New-PssHandle` returns a `StartError` handle when process start throws. Both are
immediately "finished" and flow through `Complete-PssRun` normally.

`Stop-PssRun` TERM-then-KILLs the whole process tree via `/proc` walking (falls
back to `.Kill($true)` off-Linux) and pre-sets `Status` to `killed`/`timeout` so
`Complete-PssRun` won't overwrite it.

## Gotchas

- PowerShell function return values: never `return , $arr` here — callers use
  `@(...)` everywhere and the extra wrap nests the array (this bit us; see
  `Split-PssArguments`).
- The TUI reads keys with `[Console]::ReadKey`; unparsed escape sequences (SGR
  mouse) arrive as an Escape key **with more input pending** — that's how
  `Read-TuiEscapeSequence` distinguishes them from a bare Esc keypress.
- `Get-PssScriptDeps` returns dep *objects* (`Name`, `RequiredVersion`,
  `MinimumVersion`, `MaximumVersion`, `Display`), not strings. Use `.Display`
  for user-facing joins.
- Per-script `.env` values are registered as secrets with `-Force` (redacted
  regardless of the variable name). App-level `.env` values are only redacted
  when the name looks secret-ish.
- `history.jsonl` timestamps: `ConvertFrom-Json` parses ISO strings into
  `[datetime]` — stringify before regex-formatting.

## Testing

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"
```

Tests cover the pure logic (Core helpers, cron math, dep AST extraction,
discovery, retention, locks) with a temp `dataDir` via `Initialize-Pss` against a
scratch app dir — never the real `~/.psscripts`. CI (`.github/workflows/ci.yml`)
runs Pester + PSScriptAnalyzer on Ubuntu.
