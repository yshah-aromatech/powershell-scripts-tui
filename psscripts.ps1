#!/usr/bin/env pwsh
# psscripts.ps1 — compatibility shim: the app is now called Scriptorium.
# Keeps pre-rename launchers, crontab lines, and systemd units working after a
# `git pull`. Re-run ./install.sh to get the `scriptorium` launcher, or point
# your launcher at scriptorium.ps1 directly.
& (Join-Path $PSScriptRoot 'scriptorium.ps1') @args
exit $LASTEXITCODE
