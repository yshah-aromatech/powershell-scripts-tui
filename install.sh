#!/usr/bin/env bash
# install.sh — installs prerequisites (git, PowerShell 7), clones/updates the
# app if needed, creates config.json and .env from the examples, and adds a
# `psscripts` launcher to ~/.local/bin.
#
# Works two ways:
#   curl -fsSL https://raw.githubusercontent.com/yshah-aromatech/powershell-scripts-tui/main/install.sh | bash
#   git clone ... && cd powershell-scripts-tui && ./install.sh
#
# Set PSSCRIPTS_APP_DIR to control where the one-liner clones the app
# (default: ~/powershell-scripts-tui).
set -euo pipefail

REPO_URL="https://github.com/yshah-aromatech/powershell-scripts-tui.git"

say() { printf '\033[38;2;130;170;255m==>\033[0m %s\n' "$*"; }

# --- prerequisites ----------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  say "installing git..."
  sudo apt-get update -y && sudo apt-get install -y git
fi

if ! command -v pwsh >/dev/null 2>&1; then
  say "installing PowerShell 7 (Microsoft apt repo)..."
  source /etc/os-release
  curl -fsSL -o /tmp/packages-microsoft-prod.deb \
    "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  sudo dpkg -i /tmp/packages-microsoft-prod.deb
  rm -f /tmp/packages-microsoft-prod.deb
  sudo apt-get update -y
  sudo apt-get install -y powershell
fi
say "pwsh: $(pwsh --version)"

# --- locate or fetch the app ------------------------------------------------
# When run from a checkout, install in place. When piped (curl | bash) there is
# no source file on disk, so clone (or update) the app first.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/psscripts.ps1" ]; then
  APP_DIR="$SCRIPT_DIR"
else
  APP_DIR="${PSSCRIPTS_APP_DIR:-$HOME/powershell-scripts-tui}"
  if [ -d "$APP_DIR/.git" ]; then
    say "existing install found at $APP_DIR — updating..."
    git -C "$APP_DIR" pull --ff-only
  else
    say "cloning app to $APP_DIR..."
    git clone "$REPO_URL" "$APP_DIR"
  fi
fi
cd "$APP_DIR"

# --- config -----------------------------------------------------------------
[ -f config.json ] || { cp config.json.example config.json; say "created config.json — set scriptsRepo and n8nWebhookUrl"; }
[ -f .env ]        || { cp .env.example .env;               say "created .env — set GITHUB_TOKEN"; }

# --- launcher ---------------------------------------------------------------
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/psscripts" <<EOF
#!/usr/bin/env bash
exec pwsh -NoProfile -File '$APP_DIR/psscripts.ps1' "\$@"
EOF
chmod +x "$HOME/.local/bin/psscripts"
say "launcher installed: ~/.local/bin/psscripts"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) say "NOTE: ~/.local/bin is not on your PATH — add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

say "done. Edit $APP_DIR/config.json + .env, then run: psscripts"
