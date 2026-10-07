# Gift Dispatch QC

Internal dashboard for screening Diwali gift-dispatch records (name, phone,
pincode/state/city, RM and duplicate checks), generating QR codes that
couriers scan to mark a gift dispatched, and tracking Shree Anjani courier
AWBs. All data is stored in PostgreSQL.

## Requirements

- PowerShell 7 or newer (`pwsh`) on Windows, macOS or Linux
- A PostgreSQL database (tested on PostgreSQL 17)
- Internet access on first start. It downloads the Npgsql database driver
  from nuget.org into `lib/`.

## Setup

1. Copy `.env.example` to `.env` and fill in the database connection. The
   tables are created in `DB_SCHEMA` automatically on first start. Real
   environment variables with the same names override `.env`.
2. Start the dashboard: `pwsh ./server.ps1` (on Windows, double-click
   `Start Dashboard.bat`). It listens on port 8765 (`-Port` to change).
3. On the very first start against an empty database, an `admin` login is
   created and its password is printed once in the console. Change it after
   logging in. To set (or reset) the admin login yourself instead - handy on
   a host like Render where you can't see a one-time console message, or to
   recover a locked-out account - set `ADMIN_USERNAME` and `ADMIN_PASSWORD`
   as environment variables and restart; see `.env.example`.
4. Courier tracking runs automatically: `server.ps1` launches
   `tracking-poller.ps1` as a child process on startup and restarts it if it
   ever exits. Don't start the poller separately as well - that would just
   run two of them.

Moving from the old file-based version? Run `pwsh ./migrate-json-to-postgres.ps1`
once in the folder that holds the old `data.json`, `users.json` and
`tracking.json`. QR codes printed before the move must be regenerated.

## Files

| File | Purpose |
|---|---|
| `server.ps1` | Web server, API and all screening rules |
| `db.ps1` | PostgreSQL access (shared by the server, poller and migration) |
| `tracking-poller.ps1` | Re-checks undelivered AWBs about every 30 minutes (started by `server.ps1`) |
| `migrate-json-to-postgres.ps1` | One-time import of the old JSON data files |
| `public/` | Dashboard and login pages, plus self-hosted scripts in `public/vendor/` |
| `Dockerfile` | Container image (pwsh + the pre-downloaded Npgsql driver) |
| `docker-entrypoint.sh` | Starts the web server as the container's main process (the server starts the poller itself) |
| `docker-compose.yml` | Full stack: PostgreSQL plus the app container |

## Docker deployment

Needs Docker and Docker Compose (`docker compose version`). A single `app`
container runs the web server, which starts and supervises the
courier-tracking poller itself - no separate background-worker deployment
needed, on Render or anywhere else (if you created one earlier, delete it so
two pollers don't run side by side). This stack adds PostgreSQL alongside it as a
second container.

1. Copy `.env.example` to `.env` and set `DB_USER`, `DB_PASS` and
   `DB_DATABASE` (these also become the PostgreSQL container's own
   credentials). Leave `DB_HOST` and `DB_SSLMODE` unset - `docker-compose.yml`
   points those at the `postgres` service for you.
2. Build and start everything:
   ```
   docker compose up -d --build
   ```
3. Watch the console for the one-time `admin` password, and the poller's
   startup line, in the same log stream:
   ```
   docker compose logs -f app
   ```
4. Open `http://localhost:8765/` (or the host's address, for QR-code
   scanning from a phone on the same network).

Data lives in the `pgdata` Docker volume, so it survives
`docker compose down` (use `docker compose down -v` to also wipe the
database). To rebuild after pulling code changes: `docker compose up -d --build`.

Running the image directly (no compose - e.g. a VM with its own PostgreSQL)
works the same way: `docker run` the image built from this `Dockerfile`, with
`DB_HOST`/`DB_PORT`/`DB_DATABASE`/`DB_USER`/`DB_PASS`/`DB_SCHEMA` pointed at
that database and port 8765 published - both processes start automatically,
no extra command needed.

In production, put this behind a reverse proxy that terminates HTTPS, then
set `TRUST_PROXY=true` and `COOKIE_SECURE=true` in `.env` before starting the
stack (see "Production deployment" below).

## Security

- **SQL injection:** every query uses bound parameters. No input is ever
  concatenated into SQL.
- **URLs carry no guessable IDs.** Records have random IDs. A QR link
  (`/dispatch/<token>`) carries a separate random 256-bit token and never a
  record ID. Tokens are only given to users with dispatch access.
- **Passwords:** stored as PBKDF2-SHA256 hashes (100,000 iterations) and
  compared in constant time. The minimum length is 8.
- **Sessions:** stored in the database as SHA-256 hashes. Cookies are
  `HttpOnly` and `SameSite=Lax`, and `Secure` over HTTPS. A password change
  signs out every other session.
- **Brute force:** 5 failed logins for one username from one address, or 30
  from one address, locks that address out for 15 minutes. Sign-ups and
  password changes are limited too.
- **Pre-authorized accounts** can only be claimed with the one-time invite
  code the admin receives. Only the code's hash is stored.
- **CSRF:** requests that change data are refused when they come from another
  site (Origin check). They must also use `Content-Type: application/json`.
- **XSS:** a strict Content-Security-Policy allows only the pages' own scripts,
  matched by hash. User data is inserted as text, never as HTML.
- **Other headers:** clickjacking is blocked, along with MIME sniffing and
  cross-site referrers. Responses are never cached.
- **Limits:** request bodies are capped at 25 MB. Errors never reveal server
  details to the browser; they are logged to the console instead.

## Production deployment

- Run behind a reverse proxy (nginx, a cloud load balancer) that terminates
  HTTPS. Set `TRUST_PROXY=true` and `COOKIE_SECURE=true` in `.env`.
- Connect to the database as a dedicated role limited to the app's schema.
  Don't use the database master user.
- Never commit `.env`. It is listed in `.gitignore`.
