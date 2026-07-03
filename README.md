# PowerShell Scripts TUI

A terminal UI (pure PowerShell 7, zero other runtime dependencies) for running PowerShell scripts on an Ubuntu server. Scripts live in a private GitHub repo, each gets its own isolated module directory, and every run is reported to an n8n webhook with logs and resource usage.

Styled with the [Night Owl (dark)](https://terminalcolors.com/themes/night-owl/dark/) color scheme.

## Features

- **Script list with status badges** — synced from your private GitHub scripts repo (✓ success, ✗ failure, ⊘ killed, ◷ timeout, ◇ skipped on last run; `@` marks scheduled scripts; a muted column shows how long ago each script last ran)
- **One module dir per script** — the PowerShell analog of a venv: each script gets its own folder prepended to `PSModulePath`, created automatically
- **Automatic dependency detection** — no manifest needed: the script's source is scanned with the PowerShell AST (`#Requires -Modules`, `using module`, `Import-Module` calls; built-in and local modules excluded), compared against what's installed, and you're prompted to install whatever is missing from the PowerShell Gallery (`y` install & run / `n` run anyway / `esc` cancel). Version constraints in `#Requires -Modules @{ModuleName=...; ModuleVersion=...}` are honored at check and install time. Common name mismatches are mapped.
- **Live output** — stdout/stderr streamed into the TUI (word-wrapped to the panel, wide-character aware, keyboard- and mouse-wheel-scrollable with a scrollbar, sticky-follow) and saved to a timestamped log file per run; `y` copies the whole buffer to your clipboard (wl-copy/xclip/xsel or OSC 52 over SSH)
- **Resource monitoring** — CPU % and RSS memory sampled across the whole process tree every second via `/proc`; average and peak reported, plus a per-run series that renders as a sparkline in the history view
- **n8n webhook reporting** — success/failure, exit code, duration, avg/max CPU & memory, host, and a log tail POSTed after every run. Delivery is retried, and reports that still can't be delivered are queued on disk and re-sent after the next successful delivery — cron-run reports survive n8n downtime
- **Cron scheduling** — press `e` on any script to set a cron expression (`*/15 * * * *`, `@daily`, …) or plain English. Schedules are written into your user crontab (in a managed block that leaves your other entries alone) and scheduled runs go through the exact same pipeline: own module dir, auto-installed deps, logging, resource stats, and n8n webhook (payload carries `"trigger": "cron"`). The status bar shows when the selected script fires next
- **Overlap protection** — a per-script lock prevents a cron run and a manual run (or two stacked cron runs) from executing concurrently; the losing run is reported as `skipped`
- **Run queue** — starting a script while another is running queues it; runs drain in order (`X` clears the queue)
- **Linting** — `l` runs PSScriptAnalyzer against the selected script (installed automatically on first use)
- **System maintenance** — update PowerShell via apt, upgrade all modules in every script's module dir, and update this app itself (`U` = git pull), from inside the TUI
- **Extras** — run history viewer (open any past run's log, filter by script), kill running script, webhook test event, global + per-script run timeout, output scrollback, secret redaction in all output, live script filtering, run with ad-hoc arguments (quote-aware), mouse support, log/history retention, 256-color fallback for terminals without truecolor

## Keybindings

| Key | Action |
| --- | --- |
| `↑`/`↓` or `k`/`j` | navigate scripts |
| `g` / `G` | jump to the top / bottom of the list |
| `Enter` / `r` | run selected script (deps checked first, prompt if missing; queued if something is already running) |
| `a` | run selected script with extra arguments (quotes group words: `-Msg "hello world"`) |
| `e` | set/edit/remove the cron schedule for the selected script |
| `v` | edit the selected script's `.env` file (`ctrl+s` save, `esc` cancel — warns about unsaved changes) |
| `s` | sync scripts repo (clone or hard-reset to origin; runs in the background) |
| `i` | scan the selected script's imports and install missing modules |
| `l` | lint the selected script with PSScriptAnalyzer |
| `u` | update PowerShell (apt) + upgrade all script module dirs |
| `U` | update this app (`git pull --ff-only`; restart to apply) |
| `h` | run history: `↑`/`↓` select, `Enter` opens that run's log, `f` filters to the selected script |
| `t` | send a test event to the n8n webhook |
| `x` / `X` | kill the running script / clear the run queue |
| `y` | copy the whole output to the clipboard |
| `c` | clear output panel |
| `/` | filter the script list (live as you type; `esc` restores) |
| `?` | help overlay with all keybindings |
| `PgUp` / `PgDn` / `Home` / `End` | scroll output (scrollbar shows position; auto-follows new output until you scroll up, `End` re-engages follow) |
| mouse | wheel scrolls the output panel, click selects a script |
| `q` / `Ctrl+C` | quit |

## Installation

1. Install (one-liner — no credentials needed):

```bash
curl -fsSL https://raw.githubusercontent.com/yshah-aromatech/powershell-scripts-tui/main/install.sh | bash
```

`install.sh` installs missing prerequisites (git, PowerShell 7 via the Microsoft apt repo), clones the app to `~/powershell-scripts-tui` (override with `PSSCRIPTS_APP_DIR`), creates `config.json` + `.env` from the examples, and adds a `psscripts` launcher to `~/.local/bin`. Prefer to inspect first? Clone and run it from the checkout instead:

```bash
git clone https://github.com/yshah-aromatech/powershell-scripts-tui.git && cd powershell-scripts-tui && ./install.sh
```

2. If your *scripts* repo is private, create a fine-grained PAT for it (github.com → Settings → Developer settings → Fine-grained tokens):
   - Repository access: select your PowerShell scripts repo
   - Permissions: **Contents: Read-only**

3. Configure:
   - `config.json` — set `scriptsRepo` (HTTPS URL of your private scripts repo) and `n8nWebhookUrl`
   - `.env` — if the scripts repo is private, set `GITHUB_TOKEN=` to the PAT (used to clone/pull the scripts repo; redacted in all TUI output). `SCRIPTS_REPO=` can also be set here and overrides `scriptsRepo` in `config.json`

4. Run: `psscripts`

## Updating

Everything updates from inside the TUI:

- **`U` — update this app**: `git pull --ff-only` on the install directory; restart `psscripts` to apply.
- **`u` — update PowerShell + modules**: upgrades PowerShell via apt (needs passwordless sudo for `apt-get`, or it prints the command to run manually), then upgrades every script's module dir.

Or from the shell — rerunning the install one-liner is also safe (it pulls instead of recloning):

```bash
cd ~/powershell-scripts-tui && git pull
```

## Scripts repo layout

One folder per script:

```
your-scripts-repo/
├── backup-db/
│   ├── main.ps1        # entry point (see resolution order below)
│   └── script.json     # optional: {"entry": "...", "description": "...", "args": ["-Flag"], "timeoutMinutes": 30}
└── cleanup-tmp/
    └── main.ps1
```

`script.json` keys (all optional): `entry` (relative path to the entry `.ps1`), `description` (shown in the status bar), `args` (default arguments for every run), `timeoutMinutes` (per-script run timeout; overrides the global `runTimeoutMinutes`).

The entry point for each folder is resolved in this order: `script.json`'s `"entry"`, then `main.ps1`, `<folder>.ps1`, or `run.ps1` (matched case-insensitively), then — if none of those exist — the only `.ps1` in the folder (or the first alphabetically if there are several). So a folder containing a single arbitrarily-named `.ps1` is detected automatically; use `script.json` `"entry"` to pick a specific file when a folder has more than one. Loose `.ps1` files in the repo root also work. No module manifest needed — dependencies are detected from `#Requires -Modules`, `using module`, and `Import-Module` statements in your code and installed on demand into the script's module dir.

## Per-script .env files

Each script folder can have a `.env` file (`KEY=VALUE` lines, `#` comments). Press `v` in the TUI to edit it in place. The vars are injected into the script's environment on every run (manual and cron) — read them in your script with `$env:MY_VAR`.

Every per-script `.env` value (8+ characters) is treated as a secret and replaced with `***` in TUI output, log files, and webhook payloads — these are exactly the values you chose to keep out of git, so they stay out of logs too.

Keep `.env` gitignored in the scripts repo and commit a `.env.example` instead — when a script has no `.env` yet, the editor opens pre-filled from `.env.example`. Local `.env` files survive repo syncs (the hard-reset/clean excludes them), but a tracked `.env` would be overwritten by sync on every change from the repo.

Module dirs, the scripts clone, logs, history, per-script locks, the webhook retry queue, and tools (PSScriptAnalyzer) are stored under `~/.psscripts/` (configurable via `dataDir`). Logs older than `logRetentionDays` and history beyond `historyMaxLines` are pruned automatically at startup.

## n8n webhook payload

POSTed as JSON after every run (and `{"event":"test"}` for webhook tests):

```json
{
  "event": "script_run",
  "script": "backup-db",
  "trigger": "manual",
  "status": "success",
  "success": true,
  "exitCode": 0,
  "startedAt": "2026-06-10T12:00:00.000Z",
  "finishedAt": "2026-06-10T12:03:24.000Z",
  "durationSec": 204.1,
  "host": "ubuntu-vm-01",
  "resources": {
    "cpuAvgPercent": 23.4,
    "cpuMaxPercent": 87.1,
    "memAvgMb": 145.2,
    "memMaxMb": 312.8,
    "samples": 204,
    "cpuSeries": [12.1, 45.0, 87.1, "..."],
    "memSeries": [80.2, 145.0, 312.8, "..."]
  },
  "logFile": "/home/user/.psscripts/logs/backup-db-2026-06-10T12-00-00-000Z.log",
  "log": "...last 64KB of output..."
}
```

`status` is one of `success`, `failure`, `killed`, `timeout`, `skipped` (a run that didn't start because the same script was already running). `cpuSeries`/`memSeries` are the per-second samples downsampled to at most 60 points.

Delivery is attempted twice; if both attempts fail the payload is appended to `~/.psscripts/webhook-queue.jsonl` and re-sent (in order) right after the next successful delivery.

## Scheduling

Press `e` on a script and type either a 5-field cron expression (or `@hourly` / `@daily` / `@weekly` / `@monthly` / `@reboot`) or plain English — "every 5 minutes", "8pm on saturdays". Natural language is converted to cron by `google/gemini-3.1-flash-lite` via OpenRouter (set `OPENROUTER_API_KEY` in `.env`; model configurable via `openRouterModel` in `config.json`). The generated expression is shown for confirmation before saving. Enter on an empty field removes the schedule.

The app maintains a marked block in your user crontab; everything outside the block is untouched. Each scheduled entry runs:

```
cd <app-dir> && pwsh -NoProfile -File psscripts.ps1 --run <script> --cron >> ~/.psscripts/logs/cron-<script>.log 2>&1
```

Headless mode also works manually:

| Command | Effect |
| --- | --- |
| `psscripts --run <script>` | run one script with the full dep-check/webhook pipeline, missing modules auto-installed without prompting (exit code: 0 success, 1 failure, 3 skipped/already running) |
| `psscripts --run <script> --args "-Flag 'a b'"` | same, with extra arguments (quote-aware splitting) |
| `psscripts --list` | list discovered scripts with last status and schedule |
| `psscripts --sync` | sync the scripts repo and exit (useful from cron) |
| `psscripts --history [script]` | print recent runs, optionally for one script |

A cron or manual run of a script that is already running elsewhere is **skipped** (per-script lock under `~/.psscripts/locks/`), recorded in history, and reported to the webhook with `"status": "skipped"` — long runs never stack.

## System updates without a sudo password

The `u` key runs `sudo -n apt-get ...` (non-interactive). To allow it without a password prompt, add a sudoers rule:

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/apt-get" | sudo tee /etc/sudoers.d/psscripts-apt
```

Otherwise the TUI prints the exact commands to run manually (and still upgrades the script module dirs, which need no sudo).

## Configuration reference (config.json)

| Key | Description | Default |
| --- | --- | --- |
| `scriptsRepo` | HTTPS URL of the private scripts repo (or set `SCRIPTS_REPO` in `.env`) | — |
| `branch` | branch to sync | `main` |
| `dataDir` | where scripts/module dirs/logs/history live | `~/.psscripts` |
| `n8nWebhookUrl` | n8n webhook endpoint (or set `N8N_WEBHOOK_URL` in `.env`) | — |
| `pwshBin` | pwsh used to run scripts | `pwsh` |
| `monitorIntervalMs` | resource sampling interval | `1000` |
| `logTailKb` | how much log to include in the webhook | `64` |
| `runTimeoutMinutes` | kill runs longer than this (0 = no limit; per-script `timeoutMinutes` in `script.json` overrides) | `0` |
| `maxOutputLines` | TUI scrollback size | `5000` |
| `openRouterModel` | model for plain-English → cron | `google/gemini-3.1-flash-lite` |
| `syncOnLaunch` | sync the scripts repo automatically when the TUI starts | `false` |
| `logRetentionDays` | delete run logs older than this at startup (0 = keep forever) | `30` |
| `historyMaxLines` | cap `history.jsonl` at this many runs (0 = unlimited) | `5000` |
| `webhookTimeoutSec` | per-attempt webhook timeout | `15` |
| `colorMode` | `auto` (truecolor if `$COLORTERM` says so, else 256-color), `truecolor`, or `256` | `auto` |

Unknown keys and non-numeric values for numeric keys are reported as warnings at startup instead of being silently ignored.

## Troubleshooting

- **clone/fetch fails** — check `GITHUB_TOKEN` in `.env`; the token needs Contents: Read on the scripts repo. Tokens expire — generate a new one and just rerun sync (`s`); the remote URL is refreshed automatically.
- **module install fails** — check the module name exists on the [PowerShell Gallery](https://www.powershellgallery.com); corporate networks may need a proxy (`$env:HTTPS_PROXY`).
- **webhook not firing** — press `t` to send a test event; check the n8n workflow is active and the URL is the production webhook URL, not the test one.
- **garbled UI** — the TUI needs UTF-8 and truecolor for best results; terminals without truecolor get an automatic 256-color fallback (`colorMode` forces either). Mouse reporting is enabled — hold Shift while dragging to select text in most terminals.
- **wrong duplicate-run skip** — if a run was killed hard (host reboot) a stale lock may linger in `~/.psscripts/locks/`; it's reclaimed automatically when the owning PID is dead, or delete the file manually.

## Development

Run the test suite (Pester 5):

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"
```

CI (GitHub Actions) runs the tests plus PSScriptAnalyzer on every push. See `CLAUDE.md` for the module layout and the run-handle contract.

## Ideas / suggested future features

Not implemented yet — natural next steps:

- **Side-by-side diff on sync** — show what changed in each script since the last sync
- **Per-script default arguments UI** — edit `script.json` args from inside the TUI like the `.env` editor
- **Notifications** — optional ntfy/Slack/Telegram ping on failure (n8n can do this today from the webhook)
- **Windows support** — Task Scheduler instead of crontab, winget instead of apt (the rest is already cross-platform PowerShell; runs already work without `/proc`, just without resource stats)
- **Secret store integration** — pull per-script secrets from `Microsoft.PowerShell.SecretManagement` instead of plaintext `.env` files

## License

[AGPL-3.0](LICENSE)
