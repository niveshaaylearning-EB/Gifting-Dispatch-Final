<#
Background poller for the Live Tracking Status tab. Runs independently of
server.ps1 so tracking keeps updating even if the dashboard's web server
isn't running at that moment. Reads and writes the same PostgreSQL tracking
table as the server (see db.ps1 / .env). Needs PowerShell 7+:
  pwsh .\tracking-poller.ps1

For every AWB in the tracking table that isn't yet marked delivered, and hasn't
been checked in the last 2 hours (or has never been checked), it calls Shree
Anjani's own public tracking API - the same one shreeanjani.co.in/tracking
itself calls - and records the latest status. Once an AWB's status name
contains "DELIVER", it is never checked again - that's the explicit,
permanent stopping point.

Checked in batches with a short pause between each call so a large list
doesn't fire dozens of requests at once; the loop interval below means a
shipment that's still pending/in-progress gets picked up again within
about 30 seconds of becoming due, not several minutes late - while any one
AWB still only gets actually re-checked roughly every 2 hours based on ITS
OWN last-checked time, never faster than that once it's already been
checked at least once. Within each cycle, AWBs that have never been checked
at all are processed before ones merely due for their next recheck, so a
brand-new import never waits behind the regular rotation. Among the rest, one
whose status text itself carries a days-old date (e.g. a stale "Out for
Delivery on 1st Oct 2026") is checked before routine rechecks, most stale
first - see Get-StatusStaleDays.

Meant to run continuously via the "Niveshaay TDV Dashboard Tracking Poller"
Startup entry, not by hand.
#>

$root = $PSScriptRoot
. (Join-Path $root "db.ps1")
try {
  $dbLocation = Initialize-Db
} catch {
  Write-Error "Could not connect to the database: $($_.Exception.Message)"
  exit 1
}

$CheckIntervalHours = 2
# Raised from 40/60s/800ms: the fixed sleep between cycles was the real
# bottleneck whenever there's a backlog (e.g. right after importing a few
# hundred new AWBs) - it's paid once per cycle no matter the batch size, so
# a bigger batch and shorter sleep both directly cut how long a fresh
# import sits as "Not yet checked" before it's actually been checked.
$BatchSizePerCycle = 120
$LoopSleepSeconds = 30
$PerCallDelayMs = 500

# Must match only an ACTUAL "DELIVERED" status, not "OUT FOR DELIVERY" -
# that status contains the substring "DELIVER" too (it's the start of
# "DELIVERY"), so a plain -match "DELIVER" would wrongly stop checking a
# shipment that's still only being attempted today, before delivery is
# actually confirmed.
function Test-Delivered($statusName) {
  if (-not $statusName) { return $false }
  return $statusName -match "^\s*DELIVERED\b"
}

# A delivered AWB is skipped from then on - EXCEPT if its last-center/POC
# details are still missing, in which case it gets exactly one more check
# to fill that gap in. centerCheckAttempted guards against retrying forever
# if the courier's API genuinely has no center details for some shipment -
# once that one gap-fill attempt has run (success or not), it's truly
# frozen either way, matching "at least try once, don't loop forever."
function Test-NeedsCheck($rec) {
  if (-not (Test-Delivered $rec.statusName)) { return $true }
  if ($rec.lastCenterName) { return $false }
  return -not $rec.centerCheckAttempted
}

# The courier's own status text sometimes carries a date, e.g. "Out for
# Delivery on 1st Oct 2026" or "Out for Delivery on 2nd October" (year
# omitted - assumed to be the current year, or last year if that would
# otherwise land in the future). Returns how many whole days old that date
# is as of right now, or $null if the status has no such date. A shipment
# still sitting on a days-old "out for delivery" (or similar) date despite
# being checked since is a stuck shipment - see its use below, where this
# bumps it ahead of routine rechecks instead of waiting its turn by
# lastCheckedAt alone.
function Get-StatusStaleDays($statusName) {
  if (-not $statusName) { return $null }
  $m = [regex]::Match($statusName, '(?i)\bon\s+(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)(?:\s+(\d{4}))?\b')
  if (-not $m.Success) { return $null }
  $day = [int]$m.Groups[1].Value
  $month = $m.Groups[2].Value
  $year = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { (Get-Date).Year }
  $parsed = $null
  foreach ($fmt in @("d MMMM yyyy", "d MMM yyyy")) {
    try {
      $parsed = [DateTime]::ParseExact("$day $month $year", $fmt, [System.Globalization.CultureInfo]::InvariantCulture)
      break
    } catch { }
  }
  if (-not $parsed) { return $null }
  # No year in the text and parsing with the current year lands in the
  # future (e.g. checking in January about a "28 December" status) - it
  # must have meant last year instead.
  if (-not $m.Groups[3].Success -and $parsed -gt (Get-Date)) { $parsed = $parsed.AddYears(-1) }
  $days = [math]::Floor(((Get-Date).Date - $parsed.Date).TotalDays)
  if ($days -lt 0) { return $null }
  return [int]$days
}

function Format-CenterContact($ownerName, $managerName) {
  $names = @()
  if ($ownerName) { $names += $ownerName.Trim() }
  if ($managerName -and $managerName.Trim() -ne $ownerName.Trim()) { $names += $managerName.Trim() }
  return ($names -join " / ")
}

function Get-AwbStatus($awb) {
  $uri = "https://api-customer.shreeanjani.co.in/public/awb/$([System.Uri]::EscapeDataString($awb))"
  try {
    $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
    if (-not $resp.success -or -not $resp.data.booking) { return @{ ok = $false; error = "No booking found for this AWB." } }
    $b = $resp.data.booking
    $lc = $resp.data.last_center_details
    return @{
      ok = $true
      statusName = $b.status_name
      reasonName = $b.reason_name
      fromCenter = $b.from_center_name
      toCenter = $b.to_center_name
      lastCenterName = $(if ($lc) { $lc.center_name } else { "" })
      lastCenterContact = $(if ($lc) { Format-CenterContact $lc.owner_name $lc.manager_name } else { "" })
      lastCenterMobile = $(if ($lc) { $(if ($lc.mobile) { $lc.mobile } else { $lc.phone_number }) } else { "" })
    }
  } catch {
    return @{ ok = $false; error = $_.Exception.Message }
  }
}

Write-Host "Tracking poller started. Watching the tracking table in $dbLocation every $LoopSleepSeconds seconds, refreshing each AWB roughly every $CheckIntervalHours hours until delivered."

while ($true) {
  try {
    $tracking = @{}
    foreach ($r in (Get-DbTrackingRecords)) { $tracking[$r.awb] = $r }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cutoff = $now - ($CheckIntervalHours * 60 * 60 * 1000)

    # Three priority tiers, checked in this order (never past the 2-hour
    # cutoff - this only reorders AWBs that are already due):
    #   0. Never-checked, or a delivered AWB still missing its center/POC
    #      gap-fill - as before, these are always due immediately.
    #   1. Due for a recheck AND the courier's own status text still carries
    #      a days-old date (e.g. a stale "Out for Delivery on 1st Oct 2026")
    #      despite us having already checked it since - a shipment stuck
    #      like that is worth seeing again before routine rechecks, most
    #      stale first.
    #   2. Everything else due for a routine recheck, oldest-checked-first.
    $due = @()
    foreach ($awb in $tracking.Keys) {
      $rec = $tracking[$awb]
      if (-not (Test-NeedsCheck $rec)) { continue }
      $last = $rec.lastCheckedAt
      $isDelivered = Test-Delivered $rec.statusName
      if (-not ($isDelivered -or -not $last -or [long]$last -le $cutoff)) { continue }
      if ($isDelivered -or -not $last) {
        $tier = 0; $secondary = 0
      } else {
        $staleDays = Get-StatusStaleDays $rec.statusName
        if ($staleDays -and $staleDays -ge 1) { $tier = 1; $secondary = -$staleDays }
        else { $tier = 2; $secondary = [long]$last }
      }
      $due += [PSCustomObject]@{ Awb = $awb; Tier = $tier; Secondary = $secondary }
    }
    $due = @($due | Sort-Object Tier, Secondary)

    $batch = @($due | Select-Object -First $BatchSizePerCycle -ExpandProperty Awb)
    if ($due.Count -gt 0) { Write-Host "$(Get-Date -Format 'u')  Checking $($batch.Count) of $($due.Count) due AWB(s)..." }

    foreach ($awb in $batch) {
      $rec = $tracking[$awb]
      $wasAlreadyDelivered = Test-Delivered $rec.statusName
      $result = Get-AwbStatus $awb
      $rec.lastCheckedAt = $now
      if ($result.ok) {
        $rec.statusName = $result.statusName
        $rec.reasonName = $result.reasonName
        $rec.fromCenter = $result.fromCenter
        $rec.toCenter = $result.toCenter
        $rec.lastCenterName = $result.lastCenterName
        $rec.lastCenterContact = $result.lastCenterContact
        $rec.lastCenterMobile = $result.lastCenterMobile
        $rec.delivered = Test-Delivered $result.statusName
        $rec.lastError = ""
        # Only a successful call that came back with no center details
        # permanently gives up - a network failure below is left eligible
        # to retry next cycle instead of being treated the same way.
        if ($wasAlreadyDelivered) { $rec.centerCheckAttempted = $true }
        if ($rec.delivered -and $rec.lastCenterName) { Write-Host "  $awb ($($rec.name)) -> DELIVERED, center/POC captured - will not be checked again." }
        elseif ($wasAlreadyDelivered) { Write-Host "  $awb ($($rec.name)) -> already delivered, no center/POC data available from the courier - will not retry." }
      } else {
        $rec.lastError = $result.error
        Write-Host "  $awb -> check failed: $($result.error)"
      }
      # Saved per AWB, not once at the end, so the dashboard sees each result
      # straight away and a crash mid-batch loses nothing already checked.
      Save-DbTrackingCheck $rec
      Start-Sleep -Milliseconds $PerCallDelayMs
    }
  } catch {
    Write-Host "Poller cycle error: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds $LoopSleepSeconds
}
