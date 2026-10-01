# Gift Dispatch QC - container image.
# Runs both long-running processes this app has (server.ps1 and
# tracking-poller.ps1); which one a container runs is picked by the command
# docker-compose.yml passes, not by this file.
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

# curl: used only by the HEALTHCHECK below.
# ca-certificates: needed for the HTTPS calls this app makes itself (the
# Npgsql driver download below, and the courier tracking API at runtime).
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .

# Pre-download the Npgsql driver at build time (see Import-NpgsqlDriver in
# db.ps1) so the container never needs internet access just to start, and
# every container built from this image already has it cached in ./lib.
RUN pwsh -NoProfile -Command ". ./db.ps1; Import-NpgsqlDriver"

EXPOSE 8765

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:8765/login -o /dev/null || exit 1

CMD ["pwsh", "-NoProfile", "-File", "/app/server.ps1"]
