#!/bin/sh
# Starts the web server as this container's main process (PID 1), so
# `docker stop` / an orchestrator's stop signal reaches it directly.
# server.ps1 itself launches the courier-tracking poller as a child process
# and restarts it if it ever exits, so one container (or one plain
# `pwsh ./server.ps1` anywhere else) runs both - no separate background
# worker to deploy or forget.
exec pwsh -NoProfile -File /app/server.ps1
