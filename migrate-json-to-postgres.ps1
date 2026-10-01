<#
One-time import of the old local data files (data.json, users.json,
tracking.json) into PostgreSQL, for a machine that ran the dashboard before
it moved to the database. Run once, from the project folder:

  pwsh .\migrate-json-to-postgres.ps1
  pwsh .\migrate-json-to-postgres.ps1 -SourceDir "C:\path\to\old\folder"

Safe to re-run: anything already in the database (same username, record id
or AWB) is left exactly as it is, never overwritten by the file copy. The
JSON files themselves are not modified or deleted - remove them by hand once
you've checked the dashboard shows everything.
#>
param(
  [string]$SourceDir = $PSScriptRoot
)

. (Join-Path $PSScriptRoot "db.ps1")
$dbLocation = Initialize-Db
Write-Host "Importing from $SourceDir into $dbLocation"

function Read-JsonFile($name) {
  $path = Join-Path $SourceDir $name
  if (-not (Test-Path $path)) { Write-Host "  $name - not found, skipped"; return $null }
  $raw = Get-Content -Path $path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { Write-Host "  $name - empty, skipped"; return $null }
  return (ConvertFrom-JsonText $raw)
}

# --- users.json: an array of accounts (or, on very old installs, one object) ---
$users = Read-JsonFile "users.json"
if ($null -ne $users) {
  $added = 0; $skipped = 0
  foreach ($u in @($users)) {
    if (-not $u.username) { continue }
    $role = if ($u.PSObject.Properties["role"]) { $u.role } else { "admin" }
    if ($role -notin @("admin", "user")) { $role = "user" }
    $status = if ($u.PSObject.Properties["status"]) { $u.status } else { "approved" }
    if ($status -notin @("pending", "approved")) { $status = "pending" }
    $row = @{
      username = $u.username; salt = $u.salt; hash = $u.hash; iterations = $u.iterations
      role = $role; status = $status; canDispatch = ($u.canDispatch -eq $true)
      createdAt = $(if ($u.createdAt) { [long]$u.createdAt } else { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) })
    }
    if (Add-DbUser $row) { $added++ } else { $skipped++ }
  }
  Write-Host "  users.json - $added imported, $skipped already in the database"
}

# --- data.json: an object of record id -> record ---
$data = Read-JsonFile "data.json"
if ($null -ne $data) {
  $all = @($data.PSObject.Properties)
  $added = 0
  # The old record key becomes the import de-duplication key (source_key);
  # each record gets a new random id and QR token, so QR codes printed
  # before the move need regenerating from the Courier Dispatch Checks tab.
  for ($i = 0; $i -lt $all.Count; $i += 500) {
    $chunk = @{}
    foreach ($p in $all[$i..([Math]::Min($i + 499, $all.Count - 1))]) { $chunk[$p.Name] = $p.Value }
    $added += Invoke-DbNonQuery @"
INSERT INTO clients (source_key, doc)
SELECT key, value - 'id' - 'dispatchToken' FROM jsonb_each(@payload::jsonb)
ON CONFLICT (source_key) DO NOTHING
"@ @{ payload = (ConvertTo-Json -InputObject $chunk -Depth 14 -Compress) }
  }
  Write-Host "  data.json - $added of $($all.Count) records imported (the rest were already in the database)"
}

# --- tracking.json: an object of AWB -> tracking record ---
$tracking = Read-JsonFile "tracking.json"
if ($null -ne $tracking) {
  $rows = @($tracking.PSObject.Properties | ForEach-Object {
    $r = $_.Value
    @{
      awb = $_.Name; name = $r.name; state = $r.state; statusName = $r.statusName; reasonName = $r.reasonName
      fromCenter = $r.fromCenter; toCenter = $r.toCenter; lastCenterName = $r.lastCenterName
      lastCenterContact = $r.lastCenterContact; lastCenterMobile = (ConvertTo-DbText $r.lastCenterMobile)
      delivered = ($r.delivered -eq $true); lastCheckedAt = $r.lastCheckedAt; lastError = $r.lastError
      centerCheckAttempted = ($r.centerCheckAttempted -eq $true)
    }
  })
  $added = 0
  if ($rows.Count -gt 0) {
    $added = Invoke-DbNonQuery @"
INSERT INTO tracking (awb, name, state, status_name, reason_name, from_center, to_center, last_center_name,
                      last_center_contact, last_center_mobile, delivered, last_checked_at, last_error, center_check_attempted)
SELECT r.awb, r.name, r.state, r."statusName", r."reasonName", r."fromCenter", r."toCenter", r."lastCenterName",
       r."lastCenterContact", r."lastCenterMobile", coalesce(r.delivered, false), r."lastCheckedAt", r."lastError",
       coalesce(r."centerCheckAttempted", false)
FROM jsonb_to_recordset(@rows::jsonb) AS r(
  awb text, name text, state text, "statusName" text, "reasonName" text, "fromCenter" text, "toCenter" text,
  "lastCenterName" text, "lastCenterContact" text, "lastCenterMobile" text, delivered boolean,
  "lastCheckedAt" bigint, "lastError" text, "centerCheckAttempted" boolean)
ON CONFLICT (awb) DO NOTHING
"@ @{ rows = (ConvertTo-Json -InputObject $rows -Depth 4 -Compress) }
  }
  Write-Host "  tracking.json - $added of $($rows.Count) AWBs imported (the rest were already in the database)"
}

Write-Host "Done. Check the dashboard, then delete the old JSON files and the 'Niveshaay TDV Dashboard - Backup' folder."
