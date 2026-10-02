#!/bin/sh
# Runs both of this dashboard's long-running processes in a single
# container - the web server and the courier-tracking poller - so one
# VM/host running this image handles everything; no separate "background
# worker" deployment is needed.
#
# The poller runs in the background. The web server runs in the foreground
# as this container's main process (PID 1), so `docker stop` / an
# orchestrator's stop signal reaches it directly. If the poller's process
# dies, the container keeps serving the dashboard rather than restarting
# everything - check `docker logs` for its output if tracking stops updating.
pwsh -NoProfile -File /app/tracking-poller.ps1 &
exec pwsh -NoProfile -File /app/server.ps1
