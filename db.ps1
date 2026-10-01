<#
Shared PostgreSQL storage for server.ps1 and tracking-poller.ps1 - dot-source
this file, then call Initialize-Db once before anything else.

Every piece of state the dashboard keeps lives in Postgres, in the schema
named by DB_SCHEMA - nothing is written to local files:

  users          - dashboard accounts (PBKDF2 password hashes, role, approval,
                   dispatch access, hashed one-time invite codes)
  sessions       - login sessions (only a SHA-256 of each cookie token is stored)
  clients        - gift-dispatch records, one JSONB document per record, with a
                   random id and a random QR dispatch token
  tracking       - courier AWBs and their latest Shree Anjani status
  auth_throttle  - failed login/sign-up counters (brute-force lockout)

Every query uses bound parameters - no value is ever concatenated into SQL.

Connection settings come from .env in this folder (DB_HOST, DB_PORT,
DB_DATABASE, DB_USER, DB_PASS, DB_SCHEMA, optional DB_SSLMODE). Real
environment variables with the same names override .env, so a production
host can inject credentials without any file on disk.

Needs PowerShell 7+. The Npgsql driver is downloaded from nuget.org into
.\lib on first run (pinned versions below) and loaded from there afterwards.
#>

$script:DbRoot = $PSScriptRoot
$script:Db = $null
$script:DbSchema = $null

$script:NpgsqlPackages = @(
  @{ id = "microsoft.extensions.dependencyinjection.abstractions"; version = "8.0.2"; dll = "Microsoft.Extensions.DependencyInjection.Abstractions.dll" },
  @{ id = "microsoft.extensions.logging.abstractions"; version = "8.0.3"; dll = "Microsoft.Extensions.Logging.Abstractions.dll" },
  @{ id = "npgsql"; version = "8.0.8"; dll = "Npgsql.dll" }
)

function Import-NpgsqlDriver {
  if ("Npgsql.NpgsqlDataSource" -as [type]) { return }
  if ($PSVersionTable.PSEdition -ne "Core") {
    throw "This dashboard needs PowerShell 7 or newer (run it with 'pwsh', not 'powershell'). Install: https://aka.ms/powershell"
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $libDir = Join-Path $script:DbRoot "lib"
  if (-not (Test-Path $libDir)) { New-Item -ItemType Directory -Path $libDir -Force | Out-Null }
  foreach ($pkg in $script:NpgsqlPackages) {
    $dllPath = Join-Path $libDir $pkg.dll
    if (-not (Test-Path $dllPath)) {
      Write-Host "  Downloading $($pkg.id) $($pkg.version) from nuget.org (first run only)..." -ForegroundColor DarkGray
      $nupkg = Join-Path ([System.IO.Path]::GetTempPath()) "$($pkg.id).$($pkg.version).nupkg"
      Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/$($pkg.id)/$($pkg.version)/$($pkg.id).$($pkg.version).nupkg" -OutFile $nupkg -UseBasicParsing
      $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
      try {
        $entry = $zip.GetEntry("lib/net8.0/$($pkg.dll)")
        if (-not $entry) { throw "lib/net8.0/$($pkg.dll) not found in $($pkg.id) $($pkg.version)" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dllPath, $true)
      } finally {
        $zip.Dispose()
        Remove-Item -Path $nupkg -Force -ErrorAction SilentlyContinue
      }
    }
    Add-Type -Path $dllPath
  }
}

$script:DotEnv = $null

# A setting from the environment, else from .env, else $default.
function Get-AppSetting($name, $default = $null) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ($v) { return $v }
  if ($null -eq $script:DotEnv) {
    $script:DotEnv = @{}
    $envFile = Join-Path $script:DbRoot ".env"
    if (Test-Path $envFile) {
      foreach ($line in Get-Content -Path $envFile -Encoding UTF8) {
        if ($line -match '^\s*#') { continue }
        if (-not ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$')) { continue }
        $key = $Matches[1]
        $val = $Matches[2].Trim()
        if ($val.Length -ge 2 -and (($val[0] -eq '"' -and $val[-1] -eq '"') -or ($val[0] -eq "'" -and $val[-1] -eq "'"))) {
          $val = $val.Substring(1, $val.Length - 2)
        }
        $script:DotEnv[$key] = $val
      }
    }
  }
  if ($script:DotEnv.ContainsKey($name) -and $script:DotEnv[$name]) { return $script:DotEnv[$name] }
  return $default
}

function Read-DbConfig {
  $cfg = @{}
  foreach ($k in @("DB_HOST", "DB_PORT", "DB_DATABASE", "DB_USER", "DB_PASS", "DB_SCHEMA", "DB_SSLMODE")) {
    $cfg[$k] = Get-AppSetting $k
  }
  $missing = @(@("DB_HOST", "DB_DATABASE", "DB_USER", "DB_PASS", "DB_SCHEMA") | Where-Object { -not $cfg[$_] })
  if ($missing.Count -gt 0) { throw "Missing database setting(s): $($missing -join ', '). Set them in .env (see .env.example) or as environment variables." }
  if ($cfg.DB_SCHEMA -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "DB_SCHEMA '$($cfg.DB_SCHEMA)' must be a plain identifier (letters, digits, underscore)." }
  return $cfg
}

# Creates every table this dashboard needs if it isn't there yet - safe to
# run on every start. __SCHEMA__ is swapped for the validated DB_SCHEMA (a
# single-quoted here-string so PowerShell leaves the $$ function body alone).
$script:DbSchemaSql = @'
CREATE SCHEMA IF NOT EXISTS "__SCHEMA__";

CREATE TABLE IF NOT EXISTS "__SCHEMA__".users (
  username      text    PRIMARY KEY,
  salt          text,
  hash          text,
  iterations    integer,
  role          text    NOT NULL DEFAULT 'user'    CHECK (role IN ('admin', 'user')),
  status        text    NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
  can_dispatch  boolean NOT NULL DEFAULT false,
  created_at    bigint  NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_idx ON "__SCHEMA__".users (lower(username));

CREATE TABLE IF NOT EXISTS "__SCHEMA__".sessions (
  token_hash  text        PRIMARY KEY,
  username    text        NOT NULL REFERENCES "__SCHEMA__".users (username) ON UPDATE CASCADE ON DELETE CASCADE,
  role        text        NOT NULL,
  expires_at  timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON "__SCHEMA__".sessions (expires_at);

ALTER TABLE "__SCHEMA__".users ADD COLUMN IF NOT EXISTS invite_hash text;

-- id: random, opaque - it's what appears in /api/clients/<id> URLs.
-- source_key: the import's de-duplication key (built from the sheet row);
--   never leaves the database, so no client detail ends up in a URL.
-- dispatch_token: random 256-bit secret in the public QR link /dispatch/<token>.
CREATE TABLE IF NOT EXISTS "__SCHEMA__".clients (
  id              text        PRIMARY KEY DEFAULT replace(gen_random_uuid()::text, '-', ''),
  source_key      text,
  doc             jsonb       NOT NULL,
  dispatch_token  text        NOT NULL DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE "__SCHEMA__".clients ALTER COLUMN id SET DEFAULT replace(gen_random_uuid()::text, '-', '');
ALTER TABLE "__SCHEMA__".clients ADD COLUMN IF NOT EXISTS source_key text;
ALTER TABLE "__SCHEMA__".clients ADD COLUMN IF NOT EXISTS dispatch_token text NOT NULL DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
CREATE UNIQUE INDEX IF NOT EXISTS clients_source_key_idx ON "__SCHEMA__".clients (source_key);
CREATE UNIQUE INDEX IF NOT EXISTS clients_dispatch_token_idx ON "__SCHEMA__".clients (dispatch_token);
CREATE INDEX IF NOT EXISTS clients_category_idx ON "__SCHEMA__".clients ((doc->>'category'));

-- Failed-login / signup counters for brute-force protection.
CREATE TABLE IF NOT EXISTS "__SCHEMA__".auth_throttle (
  key           text        PRIMARY KEY,
  failures      integer     NOT NULL DEFAULT 0,
  window_start  timestamptz NOT NULL DEFAULT now(),
  locked_until  timestamptz
);

CREATE TABLE IF NOT EXISTS "__SCHEMA__".clients_version (
  id       smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  version  bigint   NOT NULL DEFAULT 0
);
INSERT INTO "__SCHEMA__".clients_version (id, version) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION "__SCHEMA__".bump_clients_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE "__SCHEMA__".clients_version SET version = version + 1 WHERE id = 1;
  RETURN NULL;
END
$$;

CREATE OR REPLACE TRIGGER clients_version_bump
  AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON "__SCHEMA__".clients
  FOR EACH STATEMENT EXECUTE FUNCTION "__SCHEMA__".bump_clients_version();

CREATE TABLE IF NOT EXISTS "__SCHEMA__".tracking (
  awb                     text        PRIMARY KEY,
  name                    text        DEFAULT '',
  state                   text        DEFAULT '',
  status_name             text        DEFAULT '',
  reason_name             text        DEFAULT '',
  from_center             text        DEFAULT '',
  to_center               text        DEFAULT '',
  last_center_name        text        DEFAULT '',
  last_center_contact     text        DEFAULT '',
  last_center_mobile      text        DEFAULT '',
  delivered               boolean     NOT NULL DEFAULT false,
  last_checked_at         bigint,
  last_error              text        DEFAULT '',
  center_check_attempted  boolean     NOT NULL DEFAULT false,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);
'@

function Initialize-Db {
  Import-NpgsqlDriver
  $cfg = Read-DbConfig
  $b = [Npgsql.NpgsqlConnectionStringBuilder]::new()
  $b.Host = $cfg.DB_HOST
  $b.Port = if ($cfg.DB_PORT) { [int]$cfg.DB_PORT } else { 5432 }
  $b.Database = $cfg.DB_DATABASE
  $b.Username = $cfg.DB_USER
  $b.Password = $cfg.DB_PASS
  $b.SearchPath = $cfg.DB_SCHEMA
  $b.SslMode = if ($cfg.DB_SSLMODE) { [Npgsql.SslMode]$cfg.DB_SSLMODE } else { [Npgsql.SslMode]::Require }
  $b.ApplicationName = "gift-dispatch-qc"
  $b.Timeout = 15
  $script:Db = [Npgsql.NpgsqlDataSource]::Create($b.ConnectionString)
  $script:DbSchema = $cfg.DB_SCHEMA
  [void](Invoke-DbNonQuery ($script:DbSchemaSql -replace '__SCHEMA__', $cfg.DB_SCHEMA))
  return "$($cfg.DB_HOST)/$($cfg.DB_DATABASE) (schema $($cfg.DB_SCHEMA))"
}

# ---------------------------------------------------------------------------
# Low-level query helpers. Parameters are always passed as @name parameters,
# never concatenated into SQL.
# ---------------------------------------------------------------------------
function New-DbCommand($sql, $params) {
  $cmd = $script:Db.CreateCommand($sql)
  if ($params) {
    foreach ($k in $params.Keys) {
      $v = $params[$k]
      if ($null -eq $v) { $v = [DBNull]::Value } else { $v = $v.PSObject.BaseObject }
      [void]$cmd.Parameters.AddWithValue($k, $v)
    }
  }
  return $cmd
}

# Rows come back as hashtables keyed by column name (or alias), DB NULL as $null.
function Invoke-DbQuery($sql, $params = $null) {
  $cmd = New-DbCommand $sql $params
  $rows = New-Object System.Collections.ArrayList
  try {
    $reader = $cmd.ExecuteReader()
    try {
      while ($reader.Read()) {
        $row = @{}
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
          $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
        }
        [void]$rows.Add($row)
      }
    } finally { $reader.Dispose() }
  } finally { $cmd.Dispose() }
  return ,$rows.ToArray()
}

function Invoke-DbNonQuery($sql, $params = $null) {
  $cmd = New-DbCommand $sql $params
  try { return $cmd.ExecuteNonQuery() } finally { $cmd.Dispose() }
}

function Invoke-DbScalar($sql, $params = $null) {
  $cmd = New-DbCommand $sql $params
  try {
    $v = $cmd.ExecuteScalar()
    if ($v -is [DBNull]) { return $null }
    return $v
  } finally { $cmd.Dispose() }
}

function Test-DbUniqueViolation($errorRecord) {
  $ex = $errorRecord.Exception
  while ($ex) {
    if ($ex -is [Npgsql.PostgresException] -and $ex.SqlState -eq "23505") { return $true }
    $ex = $ex.InnerException
  }
  return $false
}

# PowerShell 7 turns date-looking JSON strings into DateTime objects by
# default, which would silently rewrite whatever date text a sheet had.
# -DateKind String (PowerShell 7.5+) keeps them exactly as sent.
$script:JsonHasDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")
function ConvertFrom-JsonText($text) {
  if ($script:JsonHasDateKind) { return (ConvertFrom-Json -InputObject $text -DateKind String) }
  return (ConvertFrom-Json -InputObject $text)
}

function ConvertTo-DbText($v) {
  if ($null -eq $v) { return $null }
  return [string]$v
}

# ---------------------------------------------------------------------------
# Users. Usernames are matched case-insensitively, same as before.
# ---------------------------------------------------------------------------
$script:UserColumns = 'username, salt, hash, iterations, role, status, can_dispatch AS "canDispatch", created_at AS "createdAt", invite_hash AS "inviteHash"'

# Writes each user to the pipeline - wrap calls in @() to get an array.
function Get-DbUsers {
  return (Invoke-DbQuery "SELECT $script:UserColumns FROM users ORDER BY created_at, username")
}

function Get-DbUser($username) {
  if (-not $username) { return $null }
  $rows = Invoke-DbQuery "SELECT $script:UserColumns FROM users WHERE lower(username) = lower(@u)" @{ u = [string]$username }
  if ($rows.Count -gt 0) { return $rows[0] }
  return $null
}

function Get-DbUserCount {
  return [long](Invoke-DbScalar "SELECT count(*) FROM users")
}

# Returns $true if inserted, $false if that username (any letter case) already exists.
function Add-DbUser($u) {
  $n = Invoke-DbNonQuery @"
INSERT INTO users (username, salt, hash, iterations, role, status, can_dispatch, created_at, invite_hash)
VALUES (@username, @salt, @hash, @iterations, @role, @status, @canDispatch, @createdAt, @inviteHash)
ON CONFLICT DO NOTHING
"@ @{
    username = [string]$u.username; salt = $u.salt; hash = $u.hash; inviteHash = $u.inviteHash
    iterations = $(if ($null -ne $u.iterations) { [int]$u.iterations } else { $null })
    role = [string]$u.role; status = [string]$u.status; canDispatch = [bool]$u.canDispatch; createdAt = [long]$u.createdAt
  }
  return $n -gt 0
}

# Setting a password also uses up any outstanding invite code.
function Set-DbUserPassword($username, $h) {
  [void](Invoke-DbNonQuery "UPDATE users SET salt = @salt, hash = @hash, iterations = @iterations, invite_hash = NULL WHERE lower(username) = lower(@u)" @{ u = [string]$username; salt = $h.salt; hash = $h.hash; iterations = [int]$h.iterations })
}

# A fresh invite code for a pre-authorized account that hasn't been claimed yet.
function Set-DbUserInvite($username, $inviteHash) {
  [void](Invoke-DbNonQuery "UPDATE users SET invite_hash = @h WHERE lower(username) = lower(@u) AND hash IS NULL" @{ u = [string]$username; h = $inviteHash })
}

function Set-DbUserCanDispatch($username, [bool]$flag) {
  [void](Invoke-DbNonQuery "UPDATE users SET can_dispatch = @flag WHERE lower(username) = lower(@u)" @{ u = [string]$username; flag = $flag })
}

function Set-DbUserStatus($username, $status) {
  [void](Invoke-DbNonQuery "UPDATE users SET status = @status WHERE lower(username) = lower(@u)" @{ u = [string]$username; status = [string]$status })
}

# Sessions follow the rename automatically (ON UPDATE CASCADE).
function Rename-DbUser($oldUsername, $newUsername) {
  [void](Invoke-DbNonQuery "UPDATE users SET username = @new WHERE lower(username) = lower(@old)" @{ old = [string]$oldUsername; new = [string]$newUsername })
}

# Their sessions go with them (ON DELETE CASCADE).
function Remove-DbUser($username) {
  [void](Invoke-DbNonQuery "DELETE FROM users WHERE lower(username) = lower(@u)" @{ u = [string]$username })
}

# ---------------------------------------------------------------------------
# Sessions. The cookie carries a random token; only its SHA-256 is stored, so
# a read of the sessions table can't be replayed as a login.
# ---------------------------------------------------------------------------
function Get-DbTokenHash($token) {
  $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($token))
  return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Add-DbSession($token, $username, $role, $hours) {
  [void](Invoke-DbNonQuery "DELETE FROM sessions WHERE expires_at < now()")
  [void](Invoke-DbNonQuery "INSERT INTO sessions (token_hash, username, role, expires_at) VALUES (@h, @u, @r, now() + make_interval(hours => @hours))" @{ h = (Get-DbTokenHash $token); u = [string]$username; r = [string]$role; hours = [int]$hours })
}

function Get-DbSession($token) {
  if (-not $token) { return $null }
  $rows = Invoke-DbQuery "SELECT username, role FROM sessions WHERE token_hash = @h AND expires_at > now()" @{ h = (Get-DbTokenHash $token) }
  if ($rows.Count -gt 0) { return $rows[0] }
  return $null
}

function Remove-DbSession($token) {
  if (-not $token) { return }
  [void](Invoke-DbNonQuery "DELETE FROM sessions WHERE token_hash = @h" @{ h = (Get-DbTokenHash $token) })
}

# Signs a user out everywhere except (optionally) the session making the request.
function Remove-DbUserSessions($username, $exceptToken = $null) {
  $keep = if ($exceptToken) { Get-DbTokenHash $exceptToken } else { "" }
  [void](Invoke-DbNonQuery "DELETE FROM sessions WHERE lower(username) = lower(@u) AND token_hash <> @keep" @{ u = [string]$username; keep = $keep })
}

# ---------------------------------------------------------------------------
# Brute-force throttle. Each key (e.g. "login:<ip>|<user>") counts failures
# within a rolling window; reaching the limit locks that key for a while.
# ---------------------------------------------------------------------------
function Test-DbThrottleLocked($key) {
  return [bool](Invoke-DbScalar "SELECT EXISTS (SELECT 1 FROM auth_throttle WHERE key = @k AND locked_until > now())" @{ k = [string]$key })
}

function Register-DbThrottleFailure($key, [int]$limit, [int]$windowMinutes, [int]$lockMinutes) {
  [void](Invoke-DbNonQuery "DELETE FROM auth_throttle WHERE window_start < now() - interval '1 day' AND (locked_until IS NULL OR locked_until < now())")
  $failures = [int](Invoke-DbScalar @"
INSERT INTO auth_throttle AS t (key, failures, window_start) VALUES (@k, 1, now())
ON CONFLICT (key) DO UPDATE SET
  failures     = CASE WHEN t.window_start < now() - make_interval(mins => @w) THEN 1 ELSE t.failures + 1 END,
  window_start = CASE WHEN t.window_start < now() - make_interval(mins => @w) THEN now() ELSE t.window_start END
RETURNING failures
"@ @{ k = [string]$key; w = $windowMinutes })
  if ($failures -ge $limit) {
    [void](Invoke-DbNonQuery "UPDATE auth_throttle SET locked_until = now() + make_interval(mins => @l), failures = 0, window_start = now() WHERE key = @k" @{ k = [string]$key; l = $lockMinutes })
  }
}

function Clear-DbThrottle($key) {
  [void](Invoke-DbNonQuery "DELETE FROM auth_throttle WHERE key = @k" @{ k = [string]$key })
}

# ---------------------------------------------------------------------------
# Gift-dispatch client records - free-form documents (whatever columns the
# uploaded sheet had), so each one is a JSONB document keyed by its id.
# ---------------------------------------------------------------------------
function ConvertTo-DocJson($doc) {
  if ($null -eq $doc) { return "{}" }
  return (ConvertTo-Json -InputObject $doc -Depth 12 -Compress)
}

# Formats of the two identifiers that appear in URLs - anything else is
# rejected before it reaches a query.
$script:ClientIdPattern = '^[0-9a-f]{32}$'
$script:DispatchTokenPattern = '^[0-9a-f]{64}$'

function Test-ClientId($id) { return ($id -is [string]) -and ($id -cmatch $script:ClientIdPattern) }
function Test-DispatchToken($token) { return ($token -is [string]) -and ($token -cmatch $script:DispatchTokenPattern) }

# The record behind a QR link: @{ id; doc } (doc as a PSCustomObject), or $null.
function Get-DbClientByDispatchToken($token) {
  if (-not (Test-DispatchToken $token)) { return $null }
  $rows = Invoke-DbQuery "SELECT id, doc::text AS doc FROM clients WHERE dispatch_token = @t" @{ t = $token }
  if ($rows.Count -eq 0) { return $null }
  return @{ id = $rows[0].id; doc = (ConvertFrom-JsonText $rows[0].doc) }
}

# Every record, each as a plain hashtable with "id" and "dispatchToken" set
# from their columns (never from the stored document).
function Get-DbClientRecords {
  $list = New-Object System.Collections.ArrayList
  foreach ($row in (Invoke-DbQuery "SELECT id, dispatch_token, doc::text AS doc FROM clients")) {
    $item = @{}
    $obj = ConvertFrom-JsonText $row.doc
    if ($null -ne $obj) { foreach ($p in $obj.PSObject.Properties) { $item[$p.Name] = $p.Value } }
    $item["id"] = $row.id
    $item["dispatchToken"] = $row.dispatch_token
    [void]$list.Add($item)
  }
  return ,$list.ToArray()
}

# Bumped by a trigger on every write to clients, from any process.
function Get-DbClientsVersion {
  return [long](Invoke-DbScalar "SELECT version FROM clients_version WHERE id = 1")
}

# Imports sheet rows - $docsByKey is a hashtable of import key -> doc. A row
# whose key was imported before replaces that record's document (keeping
# its id and QR token); a new key becomes a new record with a fresh random
# id and token.
function Save-DbClients($docsByKey) {
  if ($docsByKey.Count -eq 0) { return }
  [void](Invoke-DbNonQuery @"
INSERT INTO clients (source_key, doc)
SELECT key, value FROM jsonb_each(@payload::jsonb)
ON CONFLICT (source_key) DO UPDATE SET doc = EXCLUDED.doc, updated_at = now()
"@ @{ payload = (ConvertTo-Json -InputObject $docsByKey -Depth 14 -Compress) })
}

# A brand-new record (added by hand). Returns its new random id.
function Add-DbClient($doc) {
  return (Invoke-DbScalar "INSERT INTO clients (doc) VALUES (@doc::jsonb) RETURNING id" @{ doc = (ConvertTo-DocJson $doc) })
}

# Shallow-merges $patch's top-level fields into an existing record, in one
# atomic statement so two simultaneous edits can't drop each other's
# fields. Returns $false if there's no such record.
function Update-DbClient($id, $patch) {
  if (-not (Test-ClientId $id)) { return $false }
  $n = Invoke-DbNonQuery "UPDATE clients SET doc = doc || @patch::jsonb, updated_at = now() WHERE id = @id" @{ id = $id; patch = (ConvertTo-DocJson $patch) }
  return $n -gt 0
}

function Remove-DbClients($ids) {
  $arr = [string[]]@($ids | Where-Object { Test-ClientId $_ })
  if ($arr.Count -eq 0) { return 0 }
  return (Invoke-DbNonQuery "DELETE FROM clients WHERE id = ANY(@ids)" @{ ids = $arr })
}

# Category match is case-insensitive, same as PowerShell's -eq was.
function Remove-DbClientCategory($category) {
  return (Invoke-DbNonQuery "DELETE FROM clients WHERE (@cat::text IS NULL AND doc->>'category' IS NULL) OR lower(doc->>'category') = lower(@cat::text)" @{ cat = (ConvertTo-DbText $category) })
}

# ---------------------------------------------------------------------------
# Courier tracking (AWBs). Column aliases keep the same camelCase field names
# the dashboard's Live Tracking Status tab already reads.
# ---------------------------------------------------------------------------
$script:TrackingColumns = 'awb, name, state, status_name AS "statusName", reason_name AS "reasonName", from_center AS "fromCenter", to_center AS "toCenter", ' +
  'last_center_name AS "lastCenterName", last_center_contact AS "lastCenterContact", last_center_mobile AS "lastCenterMobile", ' +
  'delivered, last_checked_at AS "lastCheckedAt", last_error AS "lastError", center_check_attempted AS "centerCheckAttempted"'

# Writes each AWB record to the pipeline - wrap calls in @() to get an array.
function Get-DbTrackingRecords {
  return (Invoke-DbQuery "SELECT $script:TrackingColumns FROM tracking")
}

function Get-DbTrackingRecord($awb) {
  $rows = Invoke-DbQuery "SELECT $script:TrackingColumns FROM tracking WHERE awb = @awb" @{ awb = [string]$awb }
  if ($rows.Count -gt 0) { return $rows[0] }
  return $null
}

# Adds new AWBs and updates name/state on ones already there. Returns
# @{ added; updated } - a repeat of the same AWB later in the same file
# counts as an update, as it always has.
function Import-DbTrackingRows($rows) {
  $byAwb = [ordered]@{}
  $repeats = 0
  foreach ($r in $rows) {
    if ($byAwb.Contains($r.awb)) { $repeats++ }
    $byAwb[$r.awb] = @{ awb = $r.awb; name = $r.name; state = $r.state }
  }
  if ($byAwb.Count -eq 0) { return @{ added = 0; updated = 0 } }
  $result = Invoke-DbQuery @"
INSERT INTO tracking (awb, name, state)
SELECT r.awb, r.name, r.state FROM jsonb_to_recordset(@rows::jsonb) AS r(awb text, name text, state text)
ON CONFLICT (awb) DO UPDATE SET name = EXCLUDED.name, state = EXCLUDED.state, updated_at = now()
RETURNING (xmax = 0) AS inserted
"@ @{ rows = (ConvertTo-Json -InputObject @($byAwb.Values) -Depth 4 -Compress) }
  $added = @($result | Where-Object { $_.inserted }).Count
  return @{ added = $added; updated = ($result.Count - $added) + $repeats }
}

# Writes back the outcome of one courier check (all the fields a check can change).
function Save-DbTrackingCheck($rec) {
  [void](Invoke-DbNonQuery @"
UPDATE tracking SET
  status_name = @statusName, reason_name = @reasonName, from_center = @fromCenter, to_center = @toCenter,
  last_center_name = @lastCenterName, last_center_contact = @lastCenterContact, last_center_mobile = @lastCenterMobile,
  delivered = @delivered, last_checked_at = @lastCheckedAt, last_error = @lastError,
  center_check_attempted = @centerCheckAttempted, updated_at = now()
WHERE awb = @awb
"@ @{
    awb = [string]$rec.awb
    statusName = (ConvertTo-DbText $rec.statusName); reasonName = (ConvertTo-DbText $rec.reasonName)
    fromCenter = (ConvertTo-DbText $rec.fromCenter); toCenter = (ConvertTo-DbText $rec.toCenter)
    lastCenterName = (ConvertTo-DbText $rec.lastCenterName); lastCenterContact = (ConvertTo-DbText $rec.lastCenterContact)
    lastCenterMobile = (ConvertTo-DbText $rec.lastCenterMobile)
    delivered = [bool]$rec.delivered
    lastCheckedAt = $(if ($null -ne $rec.lastCheckedAt) { [long]$rec.lastCheckedAt } else { $null })
    lastError = (ConvertTo-DbText $rec.lastError)
    centerCheckAttempted = [bool]$rec.centerCheckAttempted
  })
}
