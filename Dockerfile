# Gift Dispatch QC - container image.
# Runs the web server via docker-entrypoint.sh; the server launches and
# supervises the courier-tracking poller itself, so one `docker run` on a VM
# handles everything with no separate "background worker" deployment needed.
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

# docker-entrypoint.sh is authored on Windows, so strip any CRLF line endings
# before making it executable - a stray \r in a shebang line breaks it on Linux.
RUN sed -i 's/\r$//' docker-entrypoint.sh && chmod +x docker-entrypoint.sh

EXPOSE 8765

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:8765/login -o /dev/null || exit 1

CMD ["/app/docker-entrypoint.sh"]
