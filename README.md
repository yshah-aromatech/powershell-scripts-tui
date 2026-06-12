# PowerShell Scripts TUI

A terminal UI (pure PowerShell 7, zero other runtime dependencies) for running PowerShell scripts on an Ubuntu server. Scripts live in a private GitHub repo, each gets its own isolated module directory, and every run is reported to an n8n webhook with logs and resource usage.

Styled with the [Night Owl (dark)](https://terminalcolors.com/themes/night-owl/dark/) color scheme.

## Features

- **Script list with status badges** — synced from your private GitHub scripts repo (✓ success, ✗ failure, ⊘ killed, ◷ timeout on last run; `@` marks scheduled scripts)
- **One module dir per script** — the PowerShell analog of a venv: each script gets its own folder prepended to `PSModulePath`, created automatically
- **Automatic dependency detection** — no manifest needed: the script's source is scanned with the PowerShell AST (`#Requires -Modules`, `using module`, `Import-Module` calls; built-in and local modules excluded), compared against what's installed, and you're prompted to install whatever is missing from the PowerShell Gallery (`y` install & run / `n` run anyway / `esc` cancel). Common name mismatches are mapped.
- **Live output** — stdout/stderr streamed into the TUI (word-wrapped to the panel, keyboard-scrollable with a scrollbar, sticky-follow) and saved to a timestamped log file per run; `y` copies the whole buffer to your clipboard (wl-copy/xclip/xsel or OSC 52 over SSH)
- **Resource monitoring** — CPU % and RSS memory sampled across the whole process tree every second via `/proc`; average and peak reported
- **n8n webhook reporting** — success/failure, exit code, duration, avg/max CPU & memory, host, and a log tail POSTed after every run
- **Cron scheduling** — press `e` on any script to set a cron expression (`*/15 * * * *`, `@daily`, …) or plain English. Schedules are written into your user crontab (in a managed block that leaves your other entries alone) and scheduled runs go through the exact same pipeline: own module dir, auto-installed deps, logging, resource stats, and n8n webhook (payload carries `"trigger": "cron"`)
- **System maintenance** — update PowerShell via apt and upgrade all modules in every script's module dir, from inside the TUI
- **Extras** — run history viewer, kill running script, webhook test event, configurable run timeout, output scrollback, token redaction in all output, script filtering, run with ad-hoc arguments

## Keybindings

| Key | Action |
| --- | --- |
| `↑`/`↓` or `k`/`j` | navigate scripts |
| `Enter` / `r` | run selected script (deps checked first, prompt if missing) |
| `a` | run selected script with extra arguments |
| `e` | set/edit/remove the cron schedule for the selected script |
| `v` | edit the selected script's `.env` file (`ctrl+s` save, `esc` cancel) |
| `s` | sync scripts repo (clone or hard-reset to origin) |
| `i` | scan the selected script's imports and install missing modules |
| `u` | update PowerShell (apt) + upgrade all script module dirs |
| `h` | show run history |
| `t` | send a test event to the n8n webhook |
| `x` | kill the running script |
| `y` | copy the whole output to the clipboard |
| `c` | clear output panel |
| `/` | filter the script list |
| `PgUp` / `PgDn` / `Home` / `End` | scroll output (scrollbar shows position; auto-follows new output until you scroll up, `End` re-engages follow) |
| `q` / `Ctrl+C` | quit |

## Installation (private repo)

This app itself lives in a private repo, so the server needs credentials to clone it. With HTTPS + a Personal Access Token (PAT):

1. Create a fine-grained PAT (github.com → Settings → Developer settings → Fine-grained tokens):
   - Repository access: select this repo and your PowerShell scripts repo
   - Permissions: **Contents: Read-only**

2. Clone and install (one command):

```bash
git clone https://YOUR_PAT@github.com/armtch-dev/powershell-scripts-tui.git && cd powershell-scripts-tui && ./install.sh
```

To avoid the token appearing in the remote URL / shell history, use the git credential store instead:

```bash
git config --global credential.helper store
git clone https://github.com/YOUR_ORG/powershell-scripts-tui.git   # username: your GH username, password: the PAT
cd powershell-scripts-tui && ./install.sh
```

`install.sh` installs missing prerequisites (git, PowerShell 7 via the Microsoft apt repo), creates `config.json` + `.env` from the examples, and adds a `psscripts` launcher to `~/.local/bin`.

3. Configure:
   - `config.json` — set `scriptsRepo` (HTTPS URL of your private scripts repo) and `n8nWebhookUrl`
   - `.env` — set `GITHUB_TOKEN=` to the PAT (used to clone/pull the scripts repo; redacted in all TUI output)

4. Run: `psscripts`

## Updating the app

```bash
cd powershell-scripts-tui && git pull
```

## Scripts repo layout

One folder per script:

```
your-scripts-repo/
├── backup-db/
│   ├── main.ps1        # entry point (main.ps1, <folder>.ps1, run.ps1, or set in script.json)
│   └── script.json     # optional: {"entry": "...", "description": "...", "args": ["-Flag"]}
└── cleanup-tmp/
    └── main.ps1
```

Loose `.ps1` files in the repo root also work. No module manifest needed — dependencies are detected from `#Requires -Modules`, `using module`, and `Import-Module` statements in your code and installed on demand into the script's module dir.

## Per-script .env files

Each script folder can have a `.env` file (`KEY=VALUE` lines, `#` comments). Press `v` in the TUI to edit it in place. The vars are injected into the script's environment on every run (manual and cron) — read them in your script with `$env:MY_VAR`.

Keep `.env` gitignored in the scripts repo and commit a `.env.example` instead — when a script has no `.env` yet, the editor opens pre-filled from `.env.example`. Local `.env` files survive repo syncs (the hard-reset/clean excludes them), but a tracked `.env` would be overwritten by sync on every change from the repo.

Module dirs, the scripts clone, logs, and history are stored under `~/.psscripts/` (configurable via `dataDir`).

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
    "samples": 204
  },
  "logFile": "/home/user/.psscripts/logs/backup-db-2026-06-10T12-00-00-000Z.log",
  "log": "...last 64KB of output..."
}
```

`status` is one of `success`, `failure`, `killed`, `timeout`.

## Scheduling

Press `e` on a script and type either a 5-field cron expression (or `@hourly` / `@daily` / `@weekly` / `@monthly` / `@reboot`) or plain English — "every 5 minutes", "8pm on saturdays". Natural language is converted to cron by `google/gemini-3.1-flash-lite` via OpenRouter (set `OPENROUTER_API_KEY` in `.env`; model configurable via `openRouterModel` in `config.json`). The generated expression is shown for confirmation before saving. Enter on an empty field removes the schedule.

The app maintains a marked block in your user crontab; everything outside the block is untouched. Each scheduled entry runs:

```
cd <app-dir> && pwsh -NoProfile -File psscripts.ps1 --run <script> --cron >> ~/.psscripts/logs/cron-<script>.log 2>&1
```

Headless mode also works manually: `psscripts --run <script>` (runs one script with full dep-check/webhook pipeline, missing modules auto-installed without prompting) and `psscripts --list` (list discovered scripts with last status and schedule).

## System updates without a sudo password

The `u` key runs `sudo -n apt-get ...` (non-interactive). To allow it without a password prompt, add a sudoers rule:

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/apt-get" | sudo tee /etc/sudoers.d/psscripts-apt
```

Otherwise the TUI prints the exact commands to run manually (and still upgrades the script module dirs, which need no sudo).

## Configuration reference (config.json)

| Key | Description | Default |
| --- | --- | --- |
| `scriptsRepo` | HTTPS URL of the private scripts repo | — |
| `branch` | branch to sync | `main` |
| `dataDir` | where scripts/module dirs/logs/history live | `~/.psscripts` |
| `n8nWebhookUrl` | n8n webhook endpoint (or set `N8N_WEBHOOK_URL` in `.env`) | — |
| `pwshBin` | pwsh used to run scripts | `pwsh` |
| `monitorIntervalMs` | resource sampling interval | `1000` |
| `logTailKb` | how much log to include in the webhook | `64` |
| `runTimeoutMinutes` | kill runs longer than this (0 = no limit) | `0` |
| `maxOutputLines` | TUI scrollback size | `5000` |
| `openRouterModel` | model for plain-English → cron | `google/gemini-3.1-flash-lite` |

## Troubleshooting

- **clone/fetch fails** — check `GITHUB_TOKEN` in `.env`; the token needs Contents: Read on the scripts repo. Tokens expire — generate a new one and just rerun sync (`s`); the remote URL is refreshed automatically.
- **module install fails** — check the module name exists on the [PowerShell Gallery](https://www.powershellgallery.com); corporate networks may need a proxy (`$env:HTTPS_PROXY`).
- **webhook not firing** — press `t` to send a test event; check the n8n workflow is active and the URL is the production webhook URL, not the test one.
- **garbled UI** — the TUI needs a terminal with truecolor + UTF-8 (any modern terminal over SSH is fine).

## Ideas / suggested future features

Not implemented yet — natural next steps:

- **PSScriptAnalyzer gate** — lint the selected script before running and surface warnings in the output panel
- **Side-by-side diff on sync** — show what changed in each script since the last sync
- **Run queue** — queue several scripts to run sequentially instead of one at a time
- **Per-script default arguments UI** — edit `script.json` args from inside the TUI like the `.env` editor
- **Notifications** — optional ntfy/Slack/Telegram ping on failure (n8n can do this today from the webhook)
- **Metrics retention** — keep per-run CPU/mem series on disk and render sparklines in the history view
- **Windows support** — Task Scheduler instead of crontab, winget instead of apt (the rest is already cross-platform PowerShell)
- **Secret store integration** — pull per-script secrets from `Microsoft.PowerShell.SecretManagement` instead of plaintext `.env` files
