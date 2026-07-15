# Scriptorium

A terminal UI (pure PowerShell 7, zero other runtime dependencies) for running **PowerShell and Python** scripts on an Ubuntu server. Scripts live in one or more private GitHub repos, each script gets its own isolated environment (a module directory for PowerShell, a venv for Python), and every run is reported to an n8n webhook with logs and resource usage.

Styled with the [Night Owl (dark)](https://terminalcolors.com/themes/night-owl/dark/) color scheme.

## Features

- **Script list with status badges** — synced from your private GitHub scripts repo (✓ success, ✗ failure, ⊘ killed, ◷ timeout, ◇ skipped on last run; `@` marks scheduled scripts; a muted column shows how long ago each script last ran)
- **Two runtimes, one pipeline** — folders with a `.ps1` entry run under pwsh with a per-script module dir prepended to `PSModulePath`; folders with a `.py` entry run under a per-script venv (created automatically, `PYTHONUNBUFFERED=1`, cwd = script folder so `python-dotenv` finds `.env` natively). Locks, logs, history, secret redaction, timeouts and the webhook are identical for both. A muted `ps`/`py` tag in the list shows each script's runtime
- **Multiple script repos** — the `repos` config key syncs any number of repos (e.g. `powershell-scripts` + `python-scripts`) side by side; the legacy single `scriptsRepo` key keeps working unchanged
- **Automatic dependency detection** — no manifest needed. PowerShell: the source is scanned with the AST (`#Requires -Modules` with version constraints honored, `using module`, `Import-Module` calls; built-in and local modules excluded) and missing modules are installed from the PowerShell Gallery. Python: imports are scanned with the Python AST inside the script's venv (stdlib and local modules excluded), missing packages are pip-installed with common import→pip name mismatches mapped (`cv2`→`opencv-python`, `PIL`→`pillow`, …); a `requirements.txt` in the script folder takes precedence over import scanning. Either way you're prompted (`y` install & run / `n` run anyway / `esc` cancel)
- **Live output** — stdout/stderr streamed into the TUI (word-wrapped to the panel, wide-character aware, keyboard- and mouse-wheel-scrollable with a scrollbar, sticky-follow) and saved to a timestamped log file per run; `y` copies the whole buffer to your clipboard (wl-copy/xclip/xsel or OSC 52 over SSH)
- **Resource monitoring** — CPU % and RSS memory sampled across the whole process tree every second via `/proc`; average and peak reported, plus a per-run series that renders as a sparkline in the history view. CPU is relative to the whole machine (all cores = 100%), so a multi-threaded script never reads as >100%
- **n8n webhook reporting** — success/failure, exit code, duration, avg/max CPU & memory, host, and a log tail POSTed after every run. Delivery is retried, and reports that still can't be delivered are queued on disk and re-sent after the next successful delivery — cron-run reports survive n8n downtime
- **Cron scheduling** — press `e` on any script to set a cron expression (`*/15 * * * *`, `@daily`, …) or plain English. Schedules are written into your user crontab (in a managed block that leaves your other entries alone) and scheduled runs go through the exact same pipeline: own module dir, auto-installed deps, logging, resource stats, and n8n webhook (payload carries `"trigger": "cron"`). The status bar shows when the selected script fires next
- **Overlap protection** — a per-script lock prevents a cron run and a manual run (or two stacked cron runs) from executing concurrently; the losing run is reported as `skipped`
- **Run queue** — starting a script while another is running queues it; runs drain in order (`X` clears the queue)
- **Linting** — `l` runs PSScriptAnalyzer against the selected script (installed automatically on first use)
- **System maintenance** — update PowerShell via apt, upgrade all modules in every script's module dir, and update this app itself (`U` = git pull), from inside the TUI
- **Activity & recent-runs cards** — two cards under the output panel: *activity* shows every script running right now (detected via the per-script locks, so cron/MCP/other-session runs appear too, live), and *recent runs* lists the app's latest runs (script, runtime, success/failure/stopped)
- **Extras** — per-script run history viewer (open any past run's log, `f` switches to all scripts), kill running script, webhook test event, global + per-script run timeout, output scrollback, secret redaction in all output, live script filtering, run with ad-hoc arguments (quote-aware), mouse support, log/history retention, 256-color fallback for terminals without truecolor

## Keybindings

| Key | Action |
| --- | --- |
| `↑`/`↓` or `k`/`j` | navigate scripts |
| `g` / `G` | jump to the top / bottom of the list |
| `Tab` | switch pane focus — with the output pane focused, `↑`/`↓`/`j`/`k`/`g`/`G` scroll it (focused pane's title is highlighted) |
| `Enter` / `r` | run selected script (deps checked first, prompt if missing; queued if something is already running) |
| `a` | run selected script with extra arguments (quotes group words: `-Msg "hello world"`) |
| `e` | set/edit/remove the cron schedule for the selected script |
| `v` | edit the selected script's `.env` file (`ctrl+s` save, `esc` cancel — warns about unsaved changes) |
| `s` | sync scripts repo (clone or hard-reset to origin; runs in the background) |
| `i` | scan the selected script's imports and install missing modules |
| `l` | lint the selected script (PSScriptAnalyzer for `.ps1`, pyflakes — auto-installed — for `.py`) |
| `u` | update PowerShell + Python (apt) + upgrade all module dirs and venvs |
| `U` | update this app (`git pull --ff-only`; restart to apply) |
| `h` | run history for the selected script: `↑`/`↓` select, `Enter` opens that run's log, `r` re-runs that script, `f` toggles all scripts |
| `t` | send a test event to the n8n webhook |
| `x` / `X` | kill the running script / clear the run queue |
| `y` | copy the whole output to the clipboard |
| `c` | clear output panel |
| `/` | filter the script list (live as you type; `esc` restores) |
| `Ctrl+F` | search the output panel (case-insensitive, matches highlighted); `n` / `N` jump to the next / previous match, empty search clears |
| `?` | help overlay with all keybindings |
| `PgUp` / `PgDn` / `Home` / `End` | scroll output (scrollbar shows position; auto-follows new output until you scroll up, `End` re-engages follow) |
| mouse | wheel scrolls the output panel, click selects a script (or a history row) and focuses the clicked pane; clicking a device-login code (e.g. Microsoft device sign-in) in the output copies it to the clipboard |
| `q` / `Ctrl+C` | quit |

## Installation

1. Install (one-liner — no credentials needed):

```bash
curl -fsSL https://raw.githubusercontent.com/yshah-aromatech/scriptorium/main/install.sh | bash
```

`install.sh` installs missing prerequisites (git, PowerShell 7 via the Microsoft apt repo), clones the app to `~/scriptorium` (override with `SCRIPTORIUM_APP_DIR`), creates `config.json` + `.env` from the examples, and adds a `scriptorium` launcher to `~/.local/bin`. Prefer to inspect first? Clone and run it from the checkout instead:

```bash
git clone https://github.com/yshah-aromatech/scriptorium.git && cd scriptorium && ./install.sh
```

2. If your *scripts* repo is private, create a fine-grained PAT for it (github.com → Settings → Developer settings → Fine-grained tokens):
   - Repository access: select your scripts repo(s)
   - Permissions: **Contents: Read-only**

3. Configure:
   - `config.json` — set `scriptsRepo` (HTTPS URL of your private scripts repo) and `n8nWebhookUrl`
   - `.env` — if the scripts repo is private, set `GITHUB_TOKEN=` to the PAT (used to clone/pull the scripts repo; redacted in all TUI output). `SCRIPTS_REPO=` can also be set here and overrides `scriptsRepo` in `config.json`

4. Run: `scriptorium`

## Updating

Everything updates from inside the TUI:

- **`U` — update this app**: `git pull --ff-only` on the install directory; restart `scriptorium` to apply.
- **`u` — update PowerShell + modules**: upgrades PowerShell via apt (needs passwordless sudo for `apt-get`, or it prints the command to run manually), then upgrades every script's module dir.

Or from the shell — rerunning the install one-liner is also safe (it pulls instead of recloning):

```bash
cd ~/scriptorium && git pull
```

### Upgrading from powershell-scripts-tui (the old name)

This app used to be called **powershell-scripts-tui** (command: `psscripts`). Existing installs migrate automatically — after a `git pull`:

- `psscripts.ps1` remains as a shim that forwards to `scriptorium.ps1`, so the old launcher, existing crontab entries, and an installed `psscripts-mcp` systemd service keep working untouched.
- On first launch, `~/.psscripts` is moved to `~/.scriptorium` (only if `dataDir` is the default). Data, history, module dirs, and venvs all carry over.
- Schedules written under the old crontab markers are still read, and are rewritten under the new markers the next time you save a schedule.
- Re-run `./install.sh` to get the `scriptorium` launcher (the old `psscripts` command is kept as a symlink), and re-run `scriptorium --install-mcp-service` to replace the `psscripts-mcp` unit with `scriptorium-mcp`.
- The old GitHub URL redirects to the renamed repo, so existing clones keep pulling without changes.

## Scripts repo layout

One folder per script; PowerShell and Python folders can live in the same repo or in separate repos:

```
your-scripts-repo/
├── backup-db/
│   ├── main.ps1        # PowerShell entry point (see resolution order below)
│   └── script.json     # optional: {"entry": "...", "description": "...", "args": ["-Flag"], "timeoutMinutes": 30}
└── pull-metrics/
    ├── main.py         # Python entry point — this folder runs in its own venv
    └── requirements.txt  # optional: takes precedence over import scanning
```

`script.json` keys (all optional, same for both runtimes): `entry` (relative path to the entry file — its extension decides the runtime), `description` (shown in the status bar), `args` (default arguments for every run), `timeoutMinutes` (per-script run timeout; overrides the global `runTimeoutMinutes`).

The entry point for each folder is resolved in this order: `script.json`'s `"entry"`; then the conventional PowerShell names `main.ps1`, `<folder>.ps1`, `run.ps1` (case-insensitive); then the conventional Python names `main.py`, `<folder>.py`, `run.py`, `__main__.py`; then the sole (or first alphabetical) `.ps1`, else `.py`, in the folder. A folder containing both runtimes with no `script.json` resolves to PowerShell — set `"entry"` to disambiguate. Loose `.ps1`/`.py` files in a repo root also work. `__pycache__`, `.venv`, and `node_modules` folders are ignored.

### Multiple repos

The quickest way to add a second (third, …) scripts repo:

```bash
scriptorium --add-repo https://github.com/YOUR_ORG/python-scripts --name python
scriptorium --sync
```

`--add-repo` updates `config.json` for you (a legacy `scriptsRepo` config is converted to a `repos` entry first, so the existing repo keeps syncing); `--name` and `--branch` are optional — the name defaults to the URL's basename, the branch to `main`. `scriptorium --repos` lists what's configured. Or edit the `repos` array in `config.json` directly:

```json
"repos": [
  { "name": "powershell", "url": "https://github.com/YOUR_ORG/powershell-scripts" },
  { "name": "python",     "url": "https://github.com/YOUR_ORG/python-scripts", "branch": "main" }
]
```

Each repo clones into `~/.scriptorium/scripts/<name>/` (an existing single-repo clone is migrated into its subfolder automatically on the next sync). One `GITHUB_TOKEN` covers all repos — the fine-grained PAT needs Contents:Read on each. Script names must be unique across repos; a duplicate folder name gets qualified as `<repoName>-<folder>` (with a verbose warning) — keep folder names unique to avoid it. With only the legacy `scriptsRepo` key set, everything works exactly as before.

## Per-script .env files

Each script folder can have a `.env` file (`KEY=VALUE` lines, `#` comments). Press `v` in the TUI to edit it in place. The vars are injected into the script's environment on every run (manual and cron) — read them in your script with `$env:MY_VAR`.

Every per-script `.env` value (8+ characters) is treated as a secret and replaced with `***` in TUI output, log files, and webhook payloads — these are exactly the values you chose to keep out of git, so they stay out of logs too.

Keep `.env` gitignored in the scripts repo and commit a `.env.example` instead — when a script has no `.env` yet, the editor opens pre-filled from `.env.example`. Local `.env` files survive repo syncs (the hard-reset/clean excludes them), but a tracked `.env` would be overwritten by sync on every change from the repo.

Module dirs, the scripts clone, logs, history, per-script locks, the webhook retry queue, and tools (PSScriptAnalyzer) are stored under `~/.scriptorium/` (configurable via `dataDir`). Logs older than `logRetentionDays` and history beyond `historyMaxLines` are pruned automatically at startup.

## n8n webhook payload

POSTed as JSON after every run (and `{"event":"test"}` for webhook tests):

```json
{
  "event": "script_run",
  "script": "backup-db",
  "runtime": "powershell",
  "repo": "powershell",
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
  "logFile": "/home/user/.scriptorium/logs/backup-db-2026-06-10T12-00-00-000Z.log",
  "log": "...last 64KB of output..."
}
```

`status` is one of `success`, `failure`, `killed`, `timeout`, `skipped` (a run that didn't start because the same script was already running). `cpuSeries`/`memSeries` are the per-second samples downsampled to at most 60 points.

Delivery is attempted twice; if both attempts fail the payload is appended to `~/.scriptorium/webhook-queue.jsonl` and re-sent (in order) right after the next successful delivery.

## Scheduling

Press `e` on a script and type either a 5-field cron expression (or `@hourly` / `@daily` / `@weekly` / `@monthly` / `@reboot`) or plain English — "every 5 minutes", "8pm on saturdays". Natural language is converted to cron by `google/gemini-3.1-flash-lite` via OpenRouter (set `OPENROUTER_API_KEY` in `.env`; model configurable via `openRouterModel` in `config.json`). The generated expression is shown for confirmation before saving. Enter on an empty field removes the schedule.

The app maintains a marked block in your user crontab; everything outside the block is untouched. Each scheduled entry runs:

```
cd <app-dir> && pwsh -NoProfile -File scriptorium.ps1 --run <script> --cron >> ~/.scriptorium/logs/cron-<script>.log 2>&1
```

Headless mode also works manually:

| Command | Effect |
| --- | --- |
| `scriptorium --run <script>` | run one script with the full dep-check/webhook pipeline, missing modules auto-installed without prompting (exit code: 0 success, 1 failure, 3 skipped/already running) |
| `scriptorium --run <script> --args "-Flag 'a b'"` | same, with extra arguments (quote-aware splitting) |
| `scriptorium --list` | list discovered scripts with last status and schedule |
| `scriptorium --sync` | sync all scripts repos and exit (useful from cron) |
| `scriptorium --repos` | list configured scripts repos |
| `scriptorium --add-repo <url> [--name <n>] [--branch <b>]` | add a scripts repo to config.json |
| `scriptorium --history [script]` | print recent runs, optionally for one script |
| `scriptorium --mcp [--port <n>]` | serve the built-in MCP server so AI agents (e.g. n8n) can list/run scripts — see below |

A cron or manual run of a script that is already running elsewhere is **skipped** (per-script lock under `~/.scriptorium/locks/`), recorded in history, and reported to the webhook with `"status": "skipped"` — long runs never stack.

## MCP server (AI agents / n8n)

`scriptorium --mcp` starts a built-in [MCP](https://modelcontextprotocol.io) server so an AI agent — e.g. an n8n **AI Agent** node with the built-in **MCP Client Tool** — can operate the app over the LAN. It speaks the streamable-HTTP transport (plain JSON responses, stateless, no SSE) on `POST /mcp`, with `GET /healthz` for liveness.

**Tools exposed:**

| Tool | What it does |
| --- | --- |
| `list_scripts` | every script with runtime (ps/py), repo, description, whether it's running now, last run status/duration and cron schedule |
| `get_script_details` | everything an agent needs to call a script correctly: README, documented `.env.example` variables, default args, and — for PowerShell — the parsed `param()` block (names, types, mandatory, defaults, `ValidateSet` values, per-parameter comment-based help) |
| `run_script` | run a script to completion — supports extra `args` (quote-aware string), per-run `env` vars (override the script's `.env`, values redacted like any secret), and a `timeout_minutes` override. Returns status, exit code, duration, redacted output tail and resource stats |
| `get_history` | recent runs, newest first, optionally filtered to one script; each row has a `logId` for `get_run_log` |
| `get_run_log` | fetch the redacted log of any past run by `logId` (default 64KB tail, up to 256KB) |
| `sync_repos` | git-sync all configured scripts repos |
| `get_schedules` / `set_schedule` / `remove_schedule` | read and manage cron schedules (5-field expressions or `@daily` etc., validated before writing to the crontab managed block) |
| `install_deps` | scan + install a script's missing PowerShell modules or python packages into its module dir / venv |
| `update_app` | `git pull --ff-only` this app (restart the MCP service afterwards) |
| `update_packages` | upgrade all module dirs + venvs (and apt packages when passwordless sudo is available) — can take minutes, raise the n8n tool timeout for it |

MCP-triggered runs go through the exact same pipeline as manual/cron runs: per-script lock (an already-running script returns `"status": "skipped"`), dep auto-install, log file, history, secret redaction, and the n8n run-report webhook (payload carries `"trigger": "mcp"`).

**Setup:**

1. Generate a token and put it in `.env` next to the app: `MCP_AUTH_TOKEN=$(openssl rand -hex 32)`. The server refuses to start without one; every request must send it as a Bearer token.
2. Optionally set `mcpPort` (default `8765`) and `mcpBind` (`all` = LAN-reachable, `localhost`) in `config.json`.
3. Install it as a systemd service so it runs at boot, with no terminal open:

```bash
scriptorium --install-mcp-service
```

Run as root this writes a system unit (`/etc/systemd/system/scriptorium-mcp.service`); as a normal user it writes a user unit + enables lingering, so it survives logout and reboots either way. Check with `systemctl status scriptorium-mcp` (add `--user` for the user variant); logs via `journalctl -u scriptorium-mcp -f`. Re-run the command after changing `mcpPort`/`mcpBind`. For a quick foreground session instead, `scriptorium --mcp` works too. (Don't put `--mcp` in the crontab managed block — that block is regenerated from schedules and foreign lines are dropped.)

4. In n8n: add an **AI Agent** node, attach an **MCP Client Tool** sub-node with Endpoint `http://<server-ip>:8765/mcp`, Server Transport **HTTP Streamable**, and a **Bearer** credential holding the token. The agent will discover the three tools automatically.

Smoke test with curl:

```bash
curl -s http://<server>:8765/mcp -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_script","arguments":{"script":"backup-db","args":"-DryRun"}}}'
```

Notes: tool calls execute one at a time (a long run blocks the next request — matching how an agent awaits a tool). If the client times out and disconnects mid-run, the run still completes and is recorded/webhooked. The server is LAN-only plain HTTP guarded by the token — keep it off untrusted networks, or set `mcpBind: "localhost"` if n8n runs on the same host.

## System updates without a sudo password

The `u` key runs `sudo -n apt-get ...` (non-interactive). To allow it without a password prompt, add a sudoers rule:

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/apt-get" | sudo tee /etc/sudoers.d/scriptorium-apt
```

Otherwise the TUI prints the exact commands to run manually (and still upgrades the script module dirs, which need no sudo).

## Configuration reference (config.json)

| Key | Description | Default |
| --- | --- | --- |
| `scriptsRepo` | HTTPS URL of the private scripts repo (or set `SCRIPTS_REPO` in `.env`) | — |
| `branch` | branch to sync | `main` |
| `dataDir` | where scripts/module dirs/logs/history live | `~/.scriptorium` |
| `n8nWebhookUrl` | n8n webhook endpoint (or set `N8N_WEBHOOK_URL` in `.env`) | — |
| `repos` | array of `{name, url, branch}` scripts repos (overrides `scriptsRepo`/`branch`) | `[]` |
| `pwshBin` | pwsh used to run PowerShell scripts | `pwsh` |
| `pythonBin` | python used to create venvs (scripts run on the venv's own python) | `python3` |
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
| `mcpPort` | MCP server port (`--mcp`; `--port` overrides per run) | `8765` |
| `mcpBind` | `all` (LAN-reachable) or `localhost` | `all` |

Unknown keys and non-numeric values for numeric keys are reported as warnings at startup instead of being silently ignored.

## Troubleshooting

- **clone/fetch fails** — check `GITHUB_TOKEN` in `.env`; the token needs Contents: Read on the scripts repo. Tokens expire — generate a new one and just rerun sync (`s`); the remote URL is refreshed automatically.
- **module install fails** — check the module name exists on the [PowerShell Gallery](https://www.powershellgallery.com); corporate networks may need a proxy (`$env:HTTPS_PROXY`).
- **webhook not firing** — press `t` to send a test event; check the n8n workflow is active and the URL is the production webhook URL, not the test one.
- **garbled UI** — the TUI needs UTF-8 and truecolor for best results; terminals without truecolor get an automatic 256-color fallback (`colorMode` forces either). Mouse reporting is enabled — hold Shift while dragging to select text in most terminals.
- **wrong duplicate-run skip** — if a run was killed hard (host reboot) a stale lock may linger in `~/.scriptorium/locks/`; it's reclaimed automatically when the owning PID is dead, or delete the file manually.

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
