<#
Background poller for the Live Tracking Status tab. Runs independently of
server.ps1 so tracking keeps updating even if the dashboard's web server
isn't running at that moment. Reads and writes the same PostgreSQL tracking
table as the server (see db.ps1 / .env). Needs PowerShell 7+:
  pwsh .\tracking-poller.ps1

For every AWB in the tracking table that isn't yet marked delivered, and hasn't
been checked in the last 30 minutes (or has never been checked), it looks the
AWB up with its courier - Shree Anjani or Delhivery (their public JSON APIs)
or Shree Tirupati (their website's own AWB lookup) - and records the latest
status. The courier normally comes from the dropdown chosen at import. An AWB
whose courier isn't known is tried against each supported courier; the one
with a real booking is saved as its courier. Once an AWB's status name
contains "DELIVER", it is never checked again - that's the explicit,
permanent stopping point.

Checked in batches with a short pause between each call so a large list
doesn't fire dozens of requests at once; the loop interval below means a
shipment that's still pending/in-progress gets picked up again within
about 10 seconds of becoming due, not several minutes late - while any one
AWB still only gets actually re-checked roughly every 30 minutes based on
ITS OWN last-checked time, never faster than that once it's already been
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

# Lowered from 2 hours - each AWB now gets re-checked roughly every 30
# minutes instead.
$CheckIntervalHours = 0.5
# Raised from 40/60s/800ms: the fixed sleep between cycles was the real
# bottleneck whenever there's a backlog (e.g. right after importing a few
# hundred new AWBs) - it's paid once per cycle no matter the batch size, so
# a bigger batch and shorter sleep both directly cut how long a fresh
# import sits as "Not yet checked" before it's actually been checked.
$BatchSizePerCycle = 120
# Short, so a "Refresh now" click is picked up within ~10 seconds. An idle
# cycle is just one SELECT on the tracking table.
$LoopSleepSeconds = 10
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
  # Shree Anjani's actual format: "OUT FOR DELIVERY ON 6/10/2026" - day/month/year.
  $n = [regex]::Match($statusName, '(?i)\bon\s+(\d{1,2})/(\d{1,2})/(\d{4})\b')
  if ($n.Success) {
    try {
      $d = [DateTime]::new([int]$n.Groups[3].Value, [int]$n.Groups[2].Value, [int]$n.Groups[1].Value)
    } catch { return $null }
    $nd = [math]::Floor(((Get-Date).Date - $d.Date).TotalDays)
    if ($nd -lt 0) { return $null }
    return [int]$nd
  }
  # Shree Tirupati's format: "Return To SURAT-VESU On Dated 14-10-26" - dd-mm-yy.
  $t = [regex]::Match($statusName, '(?i)\bon\s+dated\s+(\d{1,2})-(\d{1,2})-(\d{2}|\d{4})\b')
  if ($t.Success) {
    $yr = [int]$t.Groups[3].Value
    if ($yr -lt 100) { $yr += 2000 }
    try {
      $d = [DateTime]::new($yr, [int]$t.Groups[2].Value, [int]$t.Groups[1].Value)
    } catch { return $null }
    $td = [math]::Floor(((Get-Date).Date - $d.Date).TotalDays)
    if ($td -lt 0) { return $null }
    return [int]$td
  }
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

# ---------------------------------------------------------------------------
# One lookup function per courier. Each returns @{ ok; courier; statusName;
# reasonName; fromCenter; toCenter; lastCenterName; lastCenterContact;
# lastCenterMobile } on success, or @{ ok = $false; notFound; error }.
# notFound = the courier answered but has no booking for this AWB, which is
# what lets Get-AwbStatus fall through to the next courier.
# ---------------------------------------------------------------------------

# Shree Anjani: public JSON API, the same one shreeanjani.co.in/tracking uses.
function Get-ShreeAnjaniStatus($awb) {
  $uri = "https://api-customer.shreeanjani.co.in/public/awb/$([System.Uri]::EscapeDataString($awb))"
  try {
    $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
    if (-not $resp.success -or -not $resp.data.booking) { return @{ ok = $false; notFound = $true; error = "No booking at Shree Anjani." } }
    $b = $resp.data.booking
    # For an AWB it has never seen, the API still answers success:true with
    # an all-blank booking (no status, no booking date).
    if (-not $b.status_name -and -not $b.booking_date) { return @{ ok = $false; notFound = $true; error = "No booking at Shree Anjani." } }
    $lc = $resp.data.last_center_details
    return @{
      ok = $true
      courier = "shreeanjani"
      statusName = $b.status_name
      reasonName = $b.reason_name
      fromCenter = $b.from_center_name
      toCenter = $b.to_center_name
      lastCenterName = $(if ($lc) { $lc.center_name } else { "" })
      lastCenterContact = $(if ($lc) { Format-CenterContact $lc.owner_name $lc.manager_name } else { "" })
      lastCenterMobile = $(if ($lc) { $(if ($lc.mobile) { $lc.mobile } else { $lc.phone_number }) } else { "" })
    }
  } catch {
    # A malformed AWB (not 10-15 digits) comes back as HTTP 400.
    if ($_.ErrorDetails.Message -match 'AWB must be') { return @{ ok = $false; notFound = $true; error = "Not a valid Shree Anjani AWB (must be 10-15 digits)." } }
    return @{ ok = $false; error = "Shree Anjani: $($_.Exception.Message)" }
  }
}

# Shree Tirupati (shreetirupaticourier.net): an ASP.NET site, no API. Exactly
# what the "Enter AWB No. -> GO" box does: POST the docket number to
# TopHeader.aspx, which redirects to Frm_DocList.aspx?docnos=<token> - the
# token is the AWB encrypted by their server, so it can only be had this way.
# Frm_DocTrackWeb.aspx?docno=<token> is the page with the actual details.
# The form's hidden __VIEWSTATE/__EVENTVALIDATION are fetched once and
# reused; they're refetched if a POST stops yielding a token.
$TirupatiBase = "https://www.shreetirupaticourier.net"
$TirupatiUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
$script:TirupatiForm = $null

function Get-TirupatiFormFields {
  $page = Invoke-WebRequest -Uri "$TirupatiBase/TopHeader.aspx" -UserAgent $TirupatiUA -UseBasicParsing -TimeoutSec 20
  $f = ""
  foreach ($n in "__VIEWSTATE", "__VIEWSTATEGENERATOR", "__EVENTVALIDATION") {
    $v = [regex]::Match($page.Content, "id=""$n"" value=""([^""]*)""").Groups[1].Value
    $f += "$n=$([uri]::EscapeDataString($v))&"
  }
  return $f
}

function Get-TirupatiToken($awb) {
  foreach ($attempt in 1, 2) {
    if (-not $script:TirupatiForm -or $attempt -eq 2) { $script:TirupatiForm = Get-TirupatiFormFields }
    $body = $script:TirupatiForm + "trackingno=$awb&btnTrack=Go&networksearch="
    $r = Invoke-WebRequest -Uri "$TirupatiBase/TopHeader.aspx" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" `
      -UserAgent $TirupatiUA -Headers @{ Referer = "$TirupatiBase/"; Origin = $TirupatiBase } `
      -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue -UseBasicParsing -TimeoutSec 20
    $tok = [regex]::Match("$($r.Headers.Location)", "docnos=([^&]+)").Groups[1].Value
    if ($tok) { return $tok }
  }
  return $null
}

function Get-TirupatiField($html, $id) {
  $m = [regex]::Match($html, "id=""$id""[^>]*>(.*?)</(span|td|div)>", "Singleline,IgnoreCase")
  if (-not $m.Success) { return "" }
  $t = [regex]::Replace($m.Groups[1].Value, "<[^>]+>", " ")
  return ([System.Net.WebUtility]::HtmlDecode($t) -replace "\s+", " ").Trim()
}

function Get-TirupatiStatus($awb) {
  # The site itself only accepts 12-digit docket numbers.
  if ($awb -notmatch '^\d{12}$') { return @{ ok = $false; notFound = $true; error = "Not a valid Shree Tirupati AWB (must be 12 digits)." } }
  try {
    $tok = Get-TirupatiToken $awb
    if (-not $tok) { return @{ ok = $false; error = "Shree Tirupati: their site didn't return a tracking page for this AWB." } }
    $d = Invoke-WebRequest -Uri "$TirupatiBase/Frm_DocTrackWeb.aspx?docno=$tok" -UserAgent $TirupatiUA `
      -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue -UseBasicParsing -TimeoutSec 20
    $h = "$($d.Content)"
    $from = Get-TirupatiField $h "txtFromCenter"
    $to = Get-TirupatiField $h "txtToCenter"
    $bookedOn = Get-TirupatiField $h "txtDate"
    $rawStatus = Get-TirupatiField $h "lblStatus"
    # For an AWB it doesn't know, the site still shows a status line (it has
    # been seen saying "Delivered"), but every booking field is blank - so a
    # blank booking means not found, whatever the status line says.
    if (-not $from -and -not $to -and -not $bookedOn) { return @{ ok = $false; notFound = $true; error = "No booking at Shree Tirupati." } }
    # Status looks like "Delivered On Dated 05-10-26 By DELHI-RAJORI GARDEN (27)
    # For Any Query, Contact To -- 9810907996 -- 011-45589978 -- ..." - split
    # the contact tail off into its own field.
    $parts = $rawStatus -split '\s*For Any Query,?\s*Contact To\s*', 2
    $status = $parts[0].Trim()
    $phones = if ($parts.Count -gt 1) { @(($parts[1] -split '--') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) -join ", " } else { "" }
    $byCenter = [regex]::Match($status, '(?i)\bBy\s+(.+)$').Groups[1].Value.Trim()
    return @{
      ok = $true
      courier = "tirupati"
      statusName = $status
      reasonName = ""
      fromCenter = $from
      toCenter = $to
      lastCenterName = $(if ($byCenter) { $byCenter } else { $to })
      lastCenterContact = ""
      lastCenterMobile = $phones
    }
  } catch {
    return @{ ok = $false; error = "Shree Tirupati: $($_.Exception.Message)" }
  }
}

# Delhivery: the same public JSON endpoint www.delhivery.com/tracking calls
# (no login). It refuses requests without the site's Origin header. An AWB it
# doesn't know comes back as data:[] with "invalid AWB or very old package".
function Get-DelhiveryStatus($awb) {
  $uri = "https://dlv-api.delhivery.com/v3/unified-tracking-new?wbn=$([System.Uri]::EscapeDataString($awb))"
  try {
    $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20 -UserAgent $TirupatiUA `
      -Headers @{ Origin = "https://www.delhivery.com"; Referer = "https://www.delhivery.com/" }
    $p = @($resp.data)[0]
    if (-not $p -or -not $p.status -or -not $p.status.status) { return @{ ok = $false; notFound = $true; error = "No booking at Delhivery ($($resp.message))." } }
    # Shown the same way as the other couriers ("DELIVERED ON 7/10/2026"), so
    # the delivered rule and the stuck-shipment date priority work unchanged.
    $status = "$($p.status.status)".ToUpperInvariant()
    $when = [DateTime]::MinValue
    if ([DateTime]::TryParse("$($p.status.statusDateTime)", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$when)) {
      $status = "$status ON $($when.Day)/$($when.Month)/$($when.Year)"
    }
    $scans = @($p.trackingStates | ForEach-Object { $_.scans } | Where-Object { $_ })
    $last = if ($scans.Count) { $scans[-1] } else { $null }
    $dest = @($p.addressInfo.city, $p.addressInfo.state) | Where-Object { $_ }
    return @{
      ok = $true
      courier = "delhivery"
      statusName = $status
      reasonName = "$($p.status.instructions)"
      fromCenter = ""
      toCenter = ($dest -join ", ")
      lastCenterName = $(if ($last -and $last.scannedLocation) { "$($last.scannedLocation)" } elseif ($last) { "$($last.cityLocation)" } else { "" })
      lastCenterContact = ""
      lastCenterMobile = ""
    }
  } catch {
    if ($_.ErrorDetails.Message -match 'valid waybill') { return @{ ok = $false; notFound = $true; error = "Not a valid Delhivery AWB." } }
    return @{ ok = $false; error = "Delhivery: $($_.Exception.Message)" }
  }
}

$CourierLookups = [ordered]@{
  shreeanjani = { param($a) Get-ShreeAnjaniStatus $a }
  tirupati    = { param($a) Get-TirupatiStatus $a }
  delhivery   = { param($a) Get-DelhiveryStatus $a }
}

# Uses the AWB's own courier when the upload said which one it is (or an
# earlier check already found it). Otherwise asks each supported courier in
# turn and keeps the first one that has a real booking - the result carries
# .courier, which is saved, so later checks go straight there. A network
# error from a courier stops the search for this cycle rather than wrongly
# falling through to "not found".
function Get-AwbStatus($awb, $courier) {
  if ($courier -and $CourierLookups.Contains($courier)) { return (& $CourierLookups[$courier] $awb) }
  # Most likely courier first, by AWB length: Tirupati dockets are 12 digits,
  # Delhivery AWBs 13-14, Shree Anjani's usually 10.
  $order = if ($awb -match '^\d{12}$') { @("tirupati", "shreeanjani", "delhivery") }
           elseif ($awb -match '^\d{13,14}$') { @("delhivery", "shreeanjani", "tirupati") }
           else { @("shreeanjani", "delhivery", "tirupati") }
  foreach ($c in $order) {
    $r = & $CourierLookups[$c] $awb
    if ($r.ok -or -not $r.notFound) { return $r }
  }
  return @{ ok = $false; notFound = $true; error = "Not found at any supported courier (Anjani, Shree Tirupati, Delhivery) - wrong AWB, or a courier the dashboard doesn't track yet." }
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
    #   0. Never-checked, explicitly requested from the dashboard ("Refresh
    #      now" / right after an import - checkRequested, which overrides the
    #      30-minute cutoff), or a delivered AWB still missing its center/POC
    #      gap-fill - always due immediately.
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
      $requested = [bool]$rec.checkRequested
      if (-not ($requested -or $isDelivered -or -not $last -or [long]$last -le $cutoff)) { continue }
      if ($requested -or $isDelivered -or -not $last) {
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
     # One AWB failing (e.g. a save error) must not abort the rest of the batch.
     try {
      $rec = $tracking[$awb]
      $wasAlreadyDelivered = Test-Delivered $rec.statusName
      $result = Get-AwbStatus $awb $rec.courier
      $rec.lastCheckedAt = $now
      if ($result.ok) {
        $rec.courier = $result.courier
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
     } catch {
      Write-Host "  $awb -> error while checking/saving: $($_.Exception.Message)"
     }
      Start-Sleep -Milliseconds $PerCallDelayMs
    }
  } catch {
    Write-Host "Poller cycle error: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds $LoopSleepSeconds
}
