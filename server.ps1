<#
Gift Dispatch QC - local dashboard server.
Run with:  pwsh .\server.ps1
Then open: http://localhost:8765/
Stop with Ctrl+C.
Needs PowerShell 7+. All data (accounts, sessions, client records, courier
tracking) lives in PostgreSQL - see db.ps1 and .env. Nothing is written to
local files.

All screening (name/phone/pincode/RM/duplicate checks) runs HERE on the
server. The browser only displays what this file computes and sends back -
it does not decide pass/fail on its own.

There is no manual approval step. Where a record lives is decided purely by
its live computed status: anything with zero flags (status "clean") is
Stored Data; anything with one or more flags - a name/phone/pincode/RM
problem, or a same-name-in-another-category duplicate - is Review Upload,
automatically, for every category at once. Editing a flagged record so it
has no flags left moves it into Stored Data on its own, with no click
required. A record can also be moved to Stored Data directly, flags and all,
via manualClean (see Attach-Computed) - for a record a human has looked at
and judged fine despite what the automated checks say. Old records may still
carry a leftover "stage" field from before this existed - it's simply
ignored now.
#>
param(
  [int]$Port = 8765
)

Add-Type -AssemblyName System.Web

$root = $PSScriptRoot
$publicDir = Join-Path $root "public"
$indexFile = Join-Path $publicDir "index.html"

if (-not (Test-Path $indexFile)) {
  Write-Error "Can't find $indexFile - run this script from the project folder."
  exit 1
}

. (Join-Path $root "db.ps1")
try {
  $dbLocation = Initialize-Db
} catch {
  Write-Error "Could not connect to the database: $($_.Exception.Message)"
  exit 1
}

# TRUST_PROXY=true only when running behind a reverse proxy (nginx, a load
# balancer) that sets X-Forwarded-For/-Proto/-Host - otherwise those headers
# are client-controlled and ignored. COOKIE_SECURE=true forces the Secure
# cookie flag (always set it when the site is served over HTTPS).
$TrustProxy = (Get-AppSetting "TRUST_PROXY" "false") -eq "true"
$ForceSecureCookies = (Get-AppSetting "COOKIE_SECURE" "false") -eq "true"
$MaxBodyBytes = 25MB
$MinPasswordLength = 8

# Third-party scripts are served from here (public/vendor), never a CDN, and
# only these exact files.
$VendorFiles = @{}
foreach ($f in @("xlsx.full.min.js", "qrcode.min.js")) {
  $VendorFiles[$f] = [System.IO.File]::ReadAllBytes((Join-Path $publicDir "vendor/$f"))
}

# ---------------------------------------------------------------------------
# Accounts - anyone can create a username/password, but a brand-new account
# sits in "pending" until an admin approves it (User Approvals tab). Logging
# in sets ONE session cookie for the whole dashboard - no per-page prompts.
# Every route needs a valid session except /dispatch/<token> (QR scans must not
# require a login), and /login, /signup, /logout themselves.
# ---------------------------------------------------------------------------
function New-RandomPassword($length = 14) {
  $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
  $bytes = New-Object byte[] $length
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $result = ""
  foreach ($b in $bytes) { $result += $chars[$b % $chars.Length] }
  return $result
}

function New-PasswordHash($password) {
  $salt = New-Object byte[] 16
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
  $iterations = 100000
  $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password, $salt, $iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
  $hash = $pbkdf2.GetBytes(32)
  return @{ salt = [Convert]::ToBase64String($salt); hash = [Convert]::ToBase64String($hash); iterations = $iterations }
}

function Test-PasswordAgainst($password, $stored) {
  if (-not $password -or -not $stored.hash -or -not $stored.salt) { return $false }
  $salt = [Convert]::FromBase64String($stored.salt)
  $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password, $salt, [int]$stored.iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
  $computed = $pbkdf2.GetBytes(32)
  try { $expected = [Convert]::FromBase64String($stored.hash) } catch { return $false }
  return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($computed, $expected)
}

# Admin credentials come from the environment, never hardcoded, so they can
# be set/changed from the host's environment variables alone (e.g. Render's
# "Environment" tab) and take effect on the next restart - no code or .env
# file edit needed. ADMIN_USERNAME defaults to "admin" if unset.
#
# - ADMIN_PASSWORD set: that account's password is (re)set to it on every
#   start - the account is created first if it doesn't exist yet. This also
#   doubles as a password-reset tool: point ADMIN_USERNAME at any existing
#   locked-out account and restart.
# - ADMIN_PASSWORD unset: falls back to the original behavior - on the very
#   first start against an empty users table, a random password is generated
#   and printed once to the console.
$AdminUsername = Get-AppSetting "ADMIN_USERNAME" "admin"
$AdminPasswordOverride = Get-AppSetting "ADMIN_PASSWORD" $null

$firstRunPassword = $null
if ($AdminPasswordOverride) {
  if ($AdminPasswordOverride.Length -lt $MinPasswordLength) {
    Write-Error "ADMIN_PASSWORD must be at least $MinPasswordLength characters."
    exit 1
  }
  $h = New-PasswordHash $AdminPasswordOverride
  $existingAdmin = Get-DbUser $AdminUsername
  if ($existingAdmin) {
    Set-DbUserPassword $AdminUsername $h
  } else {
    $admin = @{ username = $AdminUsername; salt = $h.salt; hash = $h.hash; iterations = $h.iterations; role = "admin"; status = "approved"; canDispatch = $false; createdAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
    [void](Add-DbUser $admin)
  }
  Write-Host "  Admin password for '$AdminUsername' was set from the ADMIN_PASSWORD environment variable." -ForegroundColor DarkGray
} elseif ((Get-DbUserCount) -eq 0) {
  # The insert is conflict-safe, so two instances starting at once can't both
  # create (and print) one.
  $candidatePassword = New-RandomPassword
  $h = New-PasswordHash $candidatePassword
  $admin = @{ username = $AdminUsername; salt = $h.salt; hash = $h.hash; iterations = $h.iterations; role = "admin"; status = "approved"; canDispatch = $false; createdAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
  if (Add-DbUser $admin) { $firstRunPassword = $candidatePassword }
}

function Test-ValidUsername($username) {
  if (-not $username -or $username.Length -lt 3) { return "Username must be at least 3 characters." }
  if ($username -notmatch '^[a-zA-Z0-9_.-]+$') { return "Username can only contain letters, numbers, and . _ -" }
  return $null
}

function New-InviteCode { return (New-RandomPassword 12) }

# A username an admin has pre-authorized (via /api/users/preauthorize) is
# saved with no password yet, plus a one-time invite code the admin hands to
# that person. Signing up with that username AND the matching invite code
# "claims" it: the password is set on that same record and its existing
# status/role/canDispatch (set by the admin) are left untouched. Without the
# right code it's treated as taken - knowing (or guessing) a pre-authorized
# username alone is not enough to take over the account.
function Try-CreateUser($username, $password, $inviteCode) {
  $username = ([string]$username).Trim()
  $password = [string]$password
  $err = Test-ValidUsername $username
  if ($err) { return @{ ok = $false; error = $err } }
  if ($password.Length -lt $MinPasswordLength) { return @{ ok = $false; error = "Password must be at least $MinPasswordLength characters." } }
  $existing = Get-DbUser $username
  if ($existing) {
    $codeOk = $false
    if (-not $existing.hash -and $existing.inviteHash -and $inviteCode) {
      $codeOk = [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [System.Text.Encoding]::ASCII.GetBytes((Get-DbTokenHash ([string]$inviteCode).Trim())),
        [System.Text.Encoding]::ASCII.GetBytes($existing.inviteHash))
    }
    if (-not $codeOk) { return @{ ok = $false; error = "That username is already taken." } }
    Set-DbUserPassword $existing.username (New-PasswordHash $password)
    return @{ ok = $true; preAuthorized = $true }
  }
  $h = New-PasswordHash $password
  $newUser = @{ username = $username; salt = $h.salt; hash = $h.hash; iterations = $h.iterations; role = "user"; status = "pending"; canDispatch = $false; createdAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
  if (-not (Add-DbUser $newUser)) { return @{ ok = $false; error = "That username is already taken." } }
  return @{ ok = $true; preAuthorized = $false }
}

function Try-Login($username, $password) {
  $username = ([string]$username).Trim()
  $password = [string]$password
  $u = Get-DbUser $username
  if (-not $u -or -not (Test-PasswordAgainst $password $u)) { return @{ ok = $false; error = "Incorrect username or password." } }
  if ($u.status -ne "approved") { return @{ ok = $false; error = "Your account is waiting for admin approval." } }
  return @{ ok = $true; user = $u }
}

# Sessions live in the database (only a hash of each token is stored), so a
# server restart or a second server instance doesn't sign anyone out.
$SessionHours = 12

function New-SessionToken($username, $role) {
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $token = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
  Add-DbSession $token $username $role $SessionHours
  return $token
}

function Get-CookieValue($request, $name) {
  $cookieHeader = $request.Headers["Cookie"]
  if (-not $cookieHeader) { return $null }
  foreach ($part in $cookieHeader -split ';') {
    $kv = $part.Trim() -split '=', 2
    if ($kv.Length -eq 2 -and $kv[0] -eq $name) { return $kv[1] }
  }
  return $null
}

function Get-SessionToken($request) {
  return Get-CookieValue $request "session"
}

function Get-SessionUser($request) {
  return (Get-DbSession (Get-SessionToken $request))
}

function Remove-SessionFromRequest($request) {
  Remove-DbSession (Get-SessionToken $request)
}

# Only role/canDispatch matter for authorization checks against fresh data;
# username changes and admin-toggled dispatch access must take effect on the
# very next request, not just after the next login.
function Test-CanDispatch($user) {
  if ($user.role -eq "admin") { return $true }
  return $user.canDispatch -eq $true
}

# ---------------------------------------------------------------------------
# Courier tracking. AWB records live in their own table (tracking), completely
# separate from the gift-dispatch records in clients - they're a different
# kind of thing (an AWB and its delivery status, not a client's gift
# screening record) and mixing them would confuse every place that assumes
# every client record is a gift record with a category/flags/status.
# ---------------------------------------------------------------------------

# "Delivered" is the last stop for an AWB - once true, the poller (see
# tracking-poller.ps1) never checks that AWB again, per the explicit
# requirement not to keep tracking something already delivered. Must match
# only an ACTUAL "DELIVERED" status, not "OUT FOR DELIVERY" - that status
# still contains the substring "DELIVER" (it's the start of "DELIVERY"),
# so a plain -match "DELIVER" wrongly treats "still being attempted today"
# as "already done" and would stop checking before delivery is confirmed.
function Test-AwbDelivered($statusName) {
  if (-not $statusName) { return $false }
  return $statusName -match "^\s*DELIVERED\b"
}

# A delivered AWB is skipped by the poller/refresh from then on - EXCEPT if
# its last-center/POC details are still missing (e.g. it was delivered
# before that field existed, or a check that set delivered=true happened to
# fail partway through). In that one case it still needs exactly one more
# check to fill that gap in - after which, with lastCenterName populated,
# it's truly frozen. This is what makes "capture the center/POC even for
# delivered ones" self-healing instead of a one-off manual fix.
function Test-NeedsCheck($rec) {
  if (-not (Test-AwbDelivered $rec.statusName)) { return $true }
  return -not $rec.lastCenterName
}

# Shree Anjani's own public tracking page (shreeanjani.co.in/tracking) calls
# this exact endpoint client-side to look up an AWB - no login, no key.
# Same endpoint, called from here instead of a browser.
# The center currently holding the shipment - and its owner/manager, the
# actual people to call about a delivery - not just the from/to booking
# centers. owner_name and manager_name are often the same person filled in
# twice, sometimes two different people; shown as one combined name so
# nothing real gets dropped either way.
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
      bookingDate = $b.booking_date
      lastCenterName = $(if ($lc) { $lc.center_name } else { "" })
      lastCenterContact = $(if ($lc) { Format-CenterContact $lc.owner_name $lc.manager_name } else { "" })
      lastCenterMobile = $(if ($lc) { $(if ($lc.mobile) { $lc.mobile } else { $lc.phone_number }) } else { "" })
    }
  } catch {
    return @{ ok = $false; error = $_.Exception.Message }
  }
}


# ---------------------------------------------------------------------------
# Screening rules (ported from the browser - this is the single source of truth)
# ---------------------------------------------------------------------------
$HONORIFICS = @("mr","mrs","ms","dr","shri","smt","m/s","messrs","miss","kum","kumari","mstr","mast")

function NormSpace($s) {
  if ($null -eq $s) { return "" }
  return ([regex]::Replace($s.ToString().Trim(), '\s+', ' '))
}
function ExtractDigits($s) {
  if ($null -eq $s) { return "" }
  return ([regex]::Replace($s.ToString(), '\D', ''))
}
function NameTokens($name) {
  $n = NormSpace $name
  if (-not $n) { return ,@() }
  $parts = @($n -split ' ' | Where-Object { $_ -ne '' } | ForEach-Object { $_ -replace '[.,]+$', '' })
  while ($parts.Count -gt 0) {
    $first = ($parts[0].ToLower() -replace '\.$', '')
    if ($HONORIFICS -contains $first) { $parts = $parts[1..($parts.Count - 1)] } else { break }
  }
  return ,@($parts | Where-Object { $_ -ne '' })
}

function Validate-Name($name) {
  $t = NameTokens $name
  if (-not (NormSpace $name)) { return @{ ok = $false; msg = "Name missing" } }
  if ($t.Count -lt 2) {
    $msg = if ($t.Count -eq 0) { "Name missing" } else { "Only one name found - first or last name missing" }
    return @{ ok = $false; msg = $msg }
  }
  return @{ ok = $true }
}

function Validate-Mobile($raw) {
  if (-not (NormSpace $raw)) { return @{ ok = $false; msg = "Mobile number missing" } }
  $d = ExtractDigits $raw
  if ($d.Length -eq 12 -and $d.Substring(0, 2) -eq "91") { $d = $d.Substring(2) }
  elseif ($d.Length -eq 11 -and $d.Substring(0, 1) -eq "0") { $d = $d.Substring(1) }
  if ($d.Length -ne 10) { return @{ ok = $false; msg = "Mobile has $($d.Length) digits, expected 10" } }
  if ($d -notmatch '^[6-9]') { return @{ ok = $false; msg = "Mobile should start with 6-9" } }
  return @{ ok = $true; cleaned = $d }
}

function Validate-Landline($raw) {
  if (-not (NormSpace $raw)) { return @{ ok = $true; skip = $true } }
  $d = ExtractDigits $raw
  if ($d.Length -ge 12 -and $d.Substring(0, 2) -eq "91") { $d = $d.Substring(2) }
  if ($d.Length -gt 0 -and $d.Substring(0, 1) -eq "0") { $d = $d.Substring(1) }
  if ($d.Length -ne 10) { return @{ ok = $false; msg = "Landline (STD + number) has $($d.Length) digits, expected 10 excluding the leading 0" } }
  return @{ ok = $true; cleaned = $d }
}

function Validate-ContactNumber($raw) {
  if (-not (NormSpace $raw)) { return @{ ok = $false; msg = "Contact number missing" } }
  # A sheet sometimes lists more than one number for the same contact,
  # separated by "/" (e.g. "2029970077/9004827272"). Extracting digits from
  # the whole string at once would run both numbers together into one
  # too-long, invalid number - split on "/" first and check each candidate
  # on its own. Only one of them needs to be valid for the field to pass.
  $parts = @(($raw -split '/') | ForEach-Object { NormSpace $_ } | Where-Object { $_ -ne '' })
  if ($parts.Count -eq 0) { $parts = @((NormSpace $raw)) }
  foreach ($part in $parts) {
    $m = Validate-Mobile $part
    if ($m.ok) { return @{ ok = $true; kind = "mobile"; cleaned = $m.cleaned } }
    $l = Validate-Landline $part
    if ($l.ok -and -not $l.skip) { return @{ ok = $true; kind = "landline"; cleaned = $l.cleaned } }
  }
  $d = ExtractDigits $raw
  $nr = NormSpace $raw
  return @{ ok = $false; msg = "'$nr' ($($d.Length) digits) doesn't match a valid 10-digit mobile or STD+landline number" }
}

function Validate-Pincode($pin) {
  if (-not (NormSpace $pin)) { return @{ ok = $false; msg = "Pincode missing" } }
  $d = ExtractDigits $pin
  if ($d.Length -ne 6) { return @{ ok = $false; msg = "Pincode has $($d.Length) digits, expected 6" } }
  if ($d.Substring(0, 1) -eq "0") { return @{ ok = $false; msg = "Pincode cannot start with 0" } }
  return @{ ok = $true; cleaned = $d }
}

# No separate Pincode column exists in most source sheets - pull it out of the
# free-text Address instead (e.g. "...Jhagadia - 393 110, Gujarat"). Take the
# last 6-digit run (allowing one internal space) since the pincode is
# conventionally the last number in an Indian postal address.
function Extract-PincodeFromAddress($addr) {
  $a = NormSpace $addr
  $ms = [regex]::Matches($a, '\d{3}\s?\d{3}(?!\d)')
  if ($ms.Count -eq 0) { return "" }
  return (($ms[$ms.Count - 1].Value) -replace '\s', '')
}

$REGION_KEYWORDS = @{
  "1" = @("delhi","haryana","punjab","chandigarh","himachal","shimla","jammu","kashmir","ludhiana","gurgaon","gurugram","faridabad")
  "2" = @("uttar pradesh","lucknow","kanpur","noida","ghaziabad","uttarakhand","dehradun","agra","varanasi","meerut")
  "3" = @("rajasthan","jaipur","jodhpur","udaipur","gujarat","ahmedabad","surat","vadodara","baroda","rajkot","gandhinagar","bhavnagar","daman","diu")
  "4" = @("maharashtra","mumbai","pune","nagpur","nashik","thane","aurangabad","madhya pradesh","bhopal","indore","chhattisgarh","raipur","goa","panaji")
  "5" = @("andhra pradesh","telangana","hyderabad","vijayawada","visakhapatnam","karnataka","bangalore","bengaluru","mysore")
  "6" = @("tamil nadu","chennai","coimbatore","madurai","kerala","kochi","cochin","trivandrum","thiruvananthapuram","puducherry","pondicherry")
  "7" = @("west bengal","kolkata","howrah","odisha","bhubaneswar","assam","guwahati","manipur","meghalaya","nagaland","tripura","sikkim","andaman")
  "8" = @("bihar","patna","jharkhand","ranchi","jamshedpur")
  "9" = @("army")
}

function Get-RegionFlags($pinDigits, $address, $category) {
  $flags = @()
  $addr = (NormSpace $address).ToLower()
  $first = $pinDigits.Substring(0, 1)
  # "surat" alone would also match "AIF Non Surat" / "Others-Non Surat" -
  # those categories mean people OUTSIDE Surat, so they must NOT be held to
  # the Gujarat/pincode-starts-with-3 rule. Only a category that says Surat
  # without also saying Non is actually Surat-based.
  $isSurat = $category -and ($category -match '(?i)surat') -and ($category -notmatch '(?i)non')
  if ($isSurat -and $first -ne "3") {
    $flags += @{ code = "PIN_SURAT"; severity = "error"; msg = "Category is Surat-based but pincode starts with $first, not 3 (Gujarat)" }
  }
  $ownMatch = $false
  if ($REGION_KEYWORDS.ContainsKey($first)) {
    foreach ($k in $REGION_KEYWORDS[$first]) { if ($addr.Contains($k)) { $ownMatch = $true; break } }
  }
  if (-not $ownMatch) {
    foreach ($digit in $REGION_KEYWORDS.Keys) {
      if ($digit -eq $first) { continue }
      $hit = $false
      foreach ($k in $REGION_KEYWORDS[$digit]) { if ($addr.Contains($k)) { $hit = $true; break } }
      if ($hit) {
        $flags += @{ code = "PIN_REGION"; severity = "warn"; msg = "Address mentions a place usually in PIN region $digit, but pincode starts with $first - verify" }
        break
      }
    }
  }
  return ,$flags
}

# The address itself is only checked for what it needs to produce a usable
# pincode, state and city match (PINCODE/PIN_SURAT/PIN_REGION below) - not
# for building numbers, landmarks, or how many comma-separated parts it has.
# That stricter checking flagged plenty of genuinely fine addresses, so it's
# gone; pincode/state/city are what actually matter for dispatch.

# Company names are never automatically flagged for review - there's no
# reliable way to verify one from the sheet data alone, and a noisy "unverified"
# flag on correct names just wastes reviewers' time. Company name correctness
# is checked manually instead.
function Compute-RecordFlags($rec) {
  $flags = @()
  $n = Validate-Name $rec.name
  if (-not $n.ok) { $flags += @{ code = "NAME"; severity = "error"; msg = $n.msg } }
  $ph = Validate-ContactNumber $rec.phone
  if (-not $ph.ok) { $flags += @{ code = "PHONE"; severity = "error"; msg = $ph.msg } }
  $pinRaw = Extract-PincodeFromAddress $rec.address
  if (-not $pinRaw) {
    $flags += @{ code = "PINCODE"; severity = "error"; msg = "No 6-digit pincode found in the address - add one if available" }
  } else {
    $p = Validate-Pincode $pinRaw
    if (-not $p.ok) { $flags += @{ code = "PINCODE"; severity = "error"; msg = $p.msg } }
    else { $flags += (Get-RegionFlags $p.cleaned $rec.address $rec.category) }
  }
  if (-not (NormSpace $rec.rm)) { $flags += @{ code = "RM_MISSING"; severity = "error"; msg = "POC / RM not specified" } }
  return ,$flags
}

function Get-Severity($flags) {
  $errCount = @($flags | Where-Object { $_.severity -eq "error" }).Count
  if ($errCount -gt 0) { return "err" }
  if ($flags.Count -gt 0) { return "warn" }
  return "clean"
}

function Normalized-NameKey($name) {
  $t = NameTokens $name
  return (($t -join ' ').ToLower())
}

# A name is a "duplicate" when it appears under more than one category,
# looking across BOTH pending and approved records - so it's caught even
# before something has been through Review Upload.
function Compute-DuplicateIds($records) {
  $byName = @{}
  foreach ($r in $records) {
    $key = Normalized-NameKey $r.name
    if (-not $key) { continue }
    if (-not $byName.ContainsKey($key)) { $byName[$key] = @() }
    $byName[$key] += , $r
  }
  $dupIds = @{}
  foreach ($key in $byName.Keys) {
    $arr = $byName[$key]
    $cats = @($arr | ForEach-Object { $_.category } | Select-Object -Unique)
    if ($cats.Count -gt 1) {
      foreach ($r in $arr) { $dupIds[$r.id] = $true }
    }
  }
  return $dupIds
}

function Attach-Computed($records, $dupIds) {
  $out = @()
  foreach ($r in $records) {
    $flags = Compute-RecordFlags $r
    if ($dupIds.ContainsKey($r.id)) {
      $flags += @{ code = "DUPLICATE"; severity = "error"; msg = "Same name also appears in another category" }
    }
    $item = @{}
    foreach ($k in $r.Keys) { $item[$k] = $r[$k] }
    $item["flags"] = $flags
    # manualClean: a human looked at this record (despite whatever flags are
    # still attached, kept for the record) and judged it fine - it goes to
    # Stored Data, QR code and all, the same as a record with zero flags.
    $item["status"] = if ($r.manualClean) { "clean" } else { Get-Severity $flags }
    $item["pincode"] = Extract-PincodeFromAddress $r.address
    $out += $item
  }
  return ,$out
}

# Recomputing every flag and duplicate check from a fresh database read, on
# every single request, would make the dashboard slow once several tabs are
# each polling every few seconds. This cache does that work once and reuses
# it for every request that arrives before the data actually changes again -
# correctness is never at risk because the check itself is the clients
# table's version counter, which a database trigger bumps on every write from
# any process, so any real write anywhere invalidates it immediately.
$script:computeCache = $null

function Get-ComputedSnapshot {
  $sig = Get-DbClientsVersion
  if ($script:computeCache -and $script:computeCache.signature -eq $sig) {
    return $script:computeCache
  }
  $all = Get-DbClientRecords
  $dupIds = Compute-DuplicateIds $all
  $flagged = Attach-Computed $all $dupIds
  $snap = @{ signature = $sig; flagged = $flagged }
  $script:computeCache = $snap
  return $snap
}

# ---------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------
function Send-Json($response, $obj, $status = 200) {
  if ($null -eq $obj) { $json = "null" } else { $json = ConvertTo-Json -InputObject $obj -Depth 14 -Compress }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $response.StatusCode = $status
  $response.ContentType = "application/json; charset=utf-8"
  $response.ContentLength64 = $bytes.Length
  $response.OutputStream.Write($bytes, 0, $bytes.Length)
  $response.OutputStream.Close()
}

function Send-Text($response, $text, $contentType = "text/plain; charset=utf-8", $status = 200) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $response.StatusCode = $status
  $response.ContentType = $contentType
  $response.ContentLength64 = $bytes.Length
  $response.OutputStream.Write($bytes, 0, $bytes.Length)
  $response.OutputStream.Close()
}

# Request problems the client caused - turned into a 4xx, never a 500.
function Stop-BadRequest($code) { throw [System.IO.InvalidDataException]::new($code) }

# Reads the body, refusing anything over $MaxBodyBytes so one huge upload
# can't exhaust the server's memory.
function Read-BodyText($request) {
  if ($request.ContentLength64 -gt $MaxBodyBytes) { Stop-BadRequest "BODY_TOO_LARGE" }
  $ms = New-Object System.IO.MemoryStream
  $buf = New-Object byte[] 65536
  while (($n = $request.InputStream.Read($buf, 0, $buf.Length)) -gt 0) {
    $ms.Write($buf, 0, $n)
    if ($ms.Length -gt $MaxBodyBytes) { Stop-BadRequest "BODY_TOO_LARGE" }
  }
  return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

# JSON bodies must say so in Content-Type - a cross-site HTML form can't
# send that, which (with SameSite cookies and the Origin check) blocks CSRF.
function Read-Body($request) {
  $text = Read-BodyText $request
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  if (-not ("" + $request.ContentType).ToLowerInvariant().StartsWith("application/json")) { Stop-BadRequest "BAD_CONTENT_TYPE" }
  try { return (ConvertFrom-JsonText $text) } catch { Stop-BadRequest "BAD_JSON" }
}

# A JSON object body as a hashtable of its top-level fields, minus fields the
# server owns. Anything that isn't a JSON object gives an empty hashtable.
function Get-BodyFields($body, $exclude) {
  $fields = @{}
  if ($body -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $body.PSObject.Properties) { if ($exclude -notcontains $p.Name) { $fields[$p.Name] = $p.Value } }
  }
  return $fields
}

# Fields computed by the server or held in their own columns - a client
# can't set them by sending them in a record.
$ServerOwnedFields = @("id", "dispatchToken", "flags", "status", "pincode")

# For the plain <form method="POST"> on the public QR dispatch page -
# application/x-www-form-urlencoded, not JSON.
function Read-FormBody($request) {
  $text = Read-BodyText $request
  $result = @{}
  if ([string]::IsNullOrWhiteSpace($text)) { return $result }
  foreach ($pair in $text -split '&') {
    if (-not $pair) { continue }
    $kv = $pair -split '=', 2
    $key = [System.Uri]::UnescapeDataString(($kv[0] -replace '\+', ' '))
    $val = if ($kv.Length -gt 1) { [System.Uri]::UnescapeDataString(($kv[1] -replace '\+', ' ')) } else { "" }
    $result[$key] = $val
  }
  return $result
}

function Test-HttpsRequest($request) {
  if ($ForceSecureCookies -or $request.IsSecureConnection) { return $true }
  return $TrustProxy -and ($request.Headers["X-Forwarded-Proto"] -eq "https")
}

# Every cookie is HttpOnly (no script access) and SameSite=Lax (not sent on
# cross-site POSTs); Secure whenever the site is reached over HTTPS.
function Set-ResponseCookie($response, $request, $name, $value, $maxAgeSeconds) {
  $cookie = "$name=$value; HttpOnly; Path=/; Max-Age=$maxAgeSeconds; SameSite=Lax"
  if (Test-HttpsRequest $request) { $cookie += "; Secure" }
  $response.AddHeader("Set-Cookie", $cookie)
}

function Get-ClientIp($request) {
  if ($TrustProxy) {
    $xff = $request.Headers["X-Forwarded-For"]
    if ($xff) {
      # The proxy appends the address it actually saw - the last entry is
      # the only one a client can't forge.
      $last = ($xff -split ',')[-1].Trim()
      if ($last) { return $last }
    }
  }
  return $request.RemoteEndPoint.Address.ToString()
}

# A state-changing request carrying an Origin header must come from this
# same site. (Browsers always send Origin on POST/PATCH/DELETE.)
function Test-SameOrigin($request) {
  $origin = $request.Headers["Origin"]
  if (-not $origin) { return $true }
  $originUri = $null
  if (-not [System.Uri]::TryCreate($origin, [System.UriKind]::Absolute, [ref]$originUri)) { return $false }
  $requestHost = if ($TrustProxy -and $request.Headers["X-Forwarded-Host"]) { $request.Headers["X-Forwarded-Host"] } else { $request.Headers["Host"] }
  return [string]::Equals($originUri.Authority, $requestHost, [System.StringComparison]::OrdinalIgnoreCase)
}

# Locked-down defaults for every response; HTML pages that need more get
# their own Content-Security-Policy (Get-PageCsp).
function Add-SecurityHeaders($response, $request) {
  $response.AddHeader("X-Content-Type-Options", "nosniff")
  $response.AddHeader("X-Frame-Options", "DENY")
  $response.AddHeader("Referrer-Policy", "same-origin")
  $response.AddHeader("Cross-Origin-Opener-Policy", "same-origin")
  $response.AddHeader("Cross-Origin-Resource-Policy", "same-origin")
  $response.AddHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()")
  $response.AddHeader("Cache-Control", "no-store")
  $response.AddHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
  if (Test-HttpsRequest $request) { $response.AddHeader("Strict-Transport-Security", "max-age=31536000") }
}

# Allows exactly the page's own inline <script> blocks (by SHA-256) plus
# same-origin script files - an injected script of any kind won't run.
# Hashed after the same CRLF -> LF normalization the browser's HTML parser does.
function Get-PageCsp($html) {
  $hashes = @(foreach ($m in [regex]::Matches($html, '<script>([\s\S]*?)</script>')) {
    $src = $m.Groups[1].Value -replace "`r`n", "`n" -replace "`r", "`n"
    "'sha256-" + [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($src))) + "'"
  })
  return "default-src 'none'; script-src 'self' $($hashes -join ' '); style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src https://fonts.gstatic.com; img-src 'self' data: blob:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
}

function Send-Page($response, $path) {
  $html = Get-Content -Path $path -Raw -Encoding UTF8
  $response.Headers.Set("Content-Security-Policy", (Get-PageCsp $html))
  Send-Text $response $html "text/html; charset=utf-8"
}

function Get-SafeScannerName($raw) {
  $name = ([string]$raw -replace '[\x00-\x1F\x7F]', '').Trim()
  if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
  return $name
}

function Remove-DispatchToken($records) {
  return ,@($records | ForEach-Object { $c = $_.Clone(); $c.Remove("dispatchToken"); $c })
}

function Get-LanIPAddress {
  try {
    $candidate = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*" -and $_.InterfaceAlias -notmatch "Loopback" } |
      Select-Object -First 1
    if ($candidate) { return $candidate.IPAddress }
  } catch {}
  return $null
}

$listener = New-Object System.Net.HttpListener
$lanEnabled = $false
$lanPrefix = "http://+:$Port/"
$localPrefix = "http://localhost:$Port/"

# Binding to "+" (all network interfaces) is what lets a phone on the same
# WiFi reach this for QR-code dispatch scanning. It needs a one-time admin
# step (URL ACL) the first time it's ever run on a machine - if that hasn't
# been done yet, fall back to localhost-only so the dashboard still works
# from this PC, and print the exact commands to enable phone scanning.
$listener.Prefixes.Add($lanPrefix)
try {
  $listener.Start()
  $lanEnabled = $true
} catch {
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add($localPrefix)
  try {
    $listener.Start()
  } catch {
    Write-Error "Could not start the server on $localPrefix - is another program already using port $Port? Try: .\server.ps1 -Port 8899"
    exit 1
  }
}

$lanIP = Get-LanIPAddress

Write-Host ""
if ($lanEnabled) {
  Write-Host "  Gift Dispatch QC is running at $localPrefix" -ForegroundColor Green
  if ($lanIP) {
    Write-Host "  Also reachable on your office network at: http://$($lanIP):$Port/" -ForegroundColor Green
    Write-Host "  Open the dashboard using that network address (not localhost) so QR codes scan correctly from phones." -ForegroundColor Yellow
  } else {
    Write-Host "  Network access is enabled, but this machine's LAN IP could not be detected automatically." -ForegroundColor Yellow
  }
} else {
  Write-Host "  Gift Dispatch QC is running at $localPrefix (this PC only)" -ForegroundColor Green
  Write-Host "  Phone QR-code scanning needs a one-time setup. Run PowerShell AS ADMINISTRATOR once and paste:" -ForegroundColor Yellow
  Write-Host "    netsh http add urlacl url=http://+:$Port/ user=Everyone" -ForegroundColor Yellow
  Write-Host "    New-NetFirewallRule -DisplayName 'Gift Dispatch QC' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow" -ForegroundColor Yellow
  Write-Host "  Then restart this script - it will pick up network access automatically." -ForegroundColor Yellow
}
if ($firstRunPassword) {
  Write-Host "  FIRST-TIME SETUP - a login was just created for this dashboard:" -ForegroundColor Cyan
  Write-Host "    Username: $AdminUsername" -ForegroundColor Cyan
  Write-Host "    Password: $firstRunPassword" -ForegroundColor Cyan
  Write-Host "  Write this down now. Change it after logging in (Change Password, top right of the dashboard)." -ForegroundColor Yellow
}
Write-Host "  Data is stored in PostgreSQL: $dbLocation" -ForegroundColor DarkGray
Write-Host "  Press Ctrl+C here to stop the server." -ForegroundColor Yellow
Write-Host ""
# Open the network address when it's available, not localhost - QR codes are
# built from whichever address the dashboard is actually viewed through, so
# opening localhost here would silently break phone scanning again.
$openUrl = if ($lanEnabled -and $lanIP) { "http://$($lanIP):$Port/" } else { $localPrefix }
try { Start-Process $openUrl } catch {}

while ($listener.IsListening) {
  $context = $null
  try { $context = $listener.GetContext() } catch { break }
  $request = $context.Request
  $response = $context.Response
  try {
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod
    Add-SecurityHeaders $response $request

    if ($method -ne "GET" -and -not (Test-SameOrigin $request)) {
      Send-Json $response @{ ok = $false; error = "Cross-site request refused." } 403
      continue
    }

    # /dispatch/<token> (the page a phone opens on a QR scan) is deliberately
    # public, not gated by the dashboard login - a camera app's "open link"
    # action often opens in a different browser/app context than wherever
    # someone is actually signed into the dashboard, so requiring a session
    # here just meant every single scan hit a login wall. Who's scanning is
    # instead captured once per device via a small remembered cookie (see
    # the /dispatch/ handler below), completely separate from dashboard
    # accounts. This does NOT affect who can see/manage the Courier Dispatch
    # Checks tab inside the dashboard itself - that's still gated by
    # Test-CanDispatch via /api/dispatch-clients.
    $publicPaths = @("/login", "/signup", "/logout")
    $isPublic = ($path -match "^/dispatch/") -or ($publicPaths -contains $path)
    $sessionUser = $null
    if (-not $isPublic) {
      $sessionUser = Get-SessionUser $request
      if (-not $sessionUser) {
        if ($path -like "/api/*") {
          Send-Json $response @{ ok = $false; error = "Not logged in." } 401
        } else {
          $next = [System.Uri]::EscapeDataString($request.Url.PathAndQuery)
          $response.StatusCode = 302
          $response.AddHeader("Location", "/login?next=$next")
          $response.OutputStream.Close()
        }
        continue
      }
    }

    if ($method -eq "GET" -and $path -eq "/login") {
      Send-Page $response (Join-Path $publicDir "login.html")
    }
    elseif ($method -eq "POST" -and $path -eq "/login") {
      # Brute-force protection: 5 wrong tries for one username from one
      # address, or 30 from one address overall, locks that for 15 minutes.
      $body = Read-Body $request
      $ip = Get-ClientIp $request
      $ipKey = "login-ip:$ip"
      $userKey = "login:$ip|" + ([string]$body.username).Trim().ToLowerInvariant()
      if ((Test-DbThrottleLocked $ipKey) -or (Test-DbThrottleLocked $userKey)) {
        Send-Json $response @{ ok = $false; error = "Too many failed attempts. Try again in 15 minutes." } 429
      } else {
        $result = Try-Login $body.username $body.password
        if (-not $result.ok) {
          Register-DbThrottleFailure $userKey 5 15 15
          Register-DbThrottleFailure $ipKey 30 15 15
          Send-Json $response @{ ok = $false; error = $result.error }
        } else {
          Clear-DbThrottle $userKey
          $token = New-SessionToken $result.user.username $result.user.role
          Set-ResponseCookie $response $request "session" $token ($SessionHours * 3600)
          Send-Json $response @{ ok = $true }
        }
      }
    }
    elseif ($method -eq "POST" -and $path -eq "/signup") {
      # At most 10 sign-up attempts per address per hour.
      $body = Read-Body $request
      $signupKey = "signup-ip:" + (Get-ClientIp $request)
      if (Test-DbThrottleLocked $signupKey) {
        Send-Json $response @{ ok = $false; error = "Too many sign-up attempts. Try again later." } 429
      } else {
        Register-DbThrottleFailure $signupKey 10 60 60
        Send-Json $response (Try-CreateUser $body.username $body.password $body.inviteCode)
      }
    }
    elseif ($method -eq "POST" -and $path -eq "/logout") {
      Remove-SessionFromRequest $request
      Set-ResponseCookie $response $request "session" "" 0
      Send-Json $response @{ ok = $true }
    }
    elseif ($method -eq "GET" -and $path -match '^/vendor/([a-z.]+\.js)$' -and $VendorFiles.ContainsKey($Matches[1])) {
      $bytes = $VendorFiles[$Matches[1]]
      $response.Headers.Set("Cache-Control", "private, max-age=86400")
      $response.StatusCode = 200
      $response.ContentType = "application/javascript; charset=utf-8"
      $response.ContentLength64 = $bytes.Length
      $response.OutputStream.Write($bytes, 0, $bytes.Length)
      $response.OutputStream.Close()
    }
    elseif ($method -eq "GET" -and $path -eq "/api/me") {
      # Looked up fresh (not from the session cache) so an admin toggling
      # canDispatch, or renaming this user, takes effect on this user's very
      # next request instead of waiting for them to log out and back in.
      $me = Get-DbUser $sessionUser.username
      if (-not $me) { Send-Json $response @{ username = $sessionUser.username; role = $sessionUser.role; canDispatch = $false } }
      else { Send-Json $response @{ username = $me.username; role = $me.role; canDispatch = (Test-CanDispatch $me) } }
    }
    elseif ($method -eq "GET" -and $path -eq "/api/users") {
      if ($sessionUser.role -ne "admin") { Send-Json $response @{ error = "Admin access required." } 403 }
      else {
        $users = @(Get-DbUsers | ForEach-Object { @{ username = $_.username; role = $_.role; status = $_.status; createdAt = $_.createdAt; canDispatch = ($_.canDispatch -eq $true); claimed = [bool]$_.hash } })
        Send-Json $response $users
      }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/users/preauthorize") {
      if ($sessionUser.role -ne "admin") { Send-Json $response @{ ok = $false; error = "Admin access required." } 403 }
      else {
        # Returns a one-time invite code the admin passes on to that person -
        # signing up as this username requires it. Doing this again for a
        # username that hasn't signed up yet issues a fresh code (and the
        # old one stops working).
        $body = Read-Body $request
        $uname = ([string]$body.username).Trim()
        $err = Test-ValidUsername $uname
        $existing = if ($err) { $null } else { Get-DbUser $uname }
        $inviteCode = New-InviteCode
        if ($err) { Send-Json $response @{ ok = $false; error = $err } }
        elseif ($existing -and $existing.hash) { Send-Json $response @{ ok = $false; error = "That username already exists." } }
        elseif ($existing) {
          Set-DbUserInvite $existing.username (Get-DbTokenHash $inviteCode)
          Send-Json $response @{ ok = $true; username = $existing.username; inviteCode = $inviteCode }
        }
        else {
          $newUser = @{ username = $uname; salt = $null; hash = $null; iterations = $null; role = "user"; status = "approved"; canDispatch = ($body.canDispatch -eq $true); createdAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); inviteHash = (Get-DbTokenHash $inviteCode) }
          if (Add-DbUser $newUser) { Send-Json $response @{ ok = $true; username = $uname; inviteCode = $inviteCode } }
          else { Send-Json $response @{ ok = $false; error = "That username already exists." } }
        }
      }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/users/set-dispatch-access") {
      if ($sessionUser.role -ne "admin") { Send-Json $response @{ ok = $false; error = "Admin access required." } 403 }
      else {
        $body = Read-Body $request
        if (-not (Get-DbUser $body.username)) { Send-Json $response @{ ok = $false; error = "No such user." } }
        else {
          Set-DbUserCanDispatch $body.username ($body.canDispatch -eq $true)
          Send-Json $response @{ ok = $true }
        }
      }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/change-username") {
      $body = Read-Body $request
      $newUsername = ([string]$body.newUsername).Trim()
      $err = Test-ValidUsername $newUsername
      if ($err) { Send-Json $response @{ ok = $false; error = $err } }
      elseif ($newUsername -eq $sessionUser.username) { Send-Json $response @{ ok = $false; error = "That's already your username." } }
      elseif (Get-DbUser $newUsername) { Send-Json $response @{ ok = $false; error = "That username is already taken." } }
      else {
        # The session row follows the rename via ON UPDATE CASCADE.
        try {
          Rename-DbUser $sessionUser.username $newUsername
          Send-Json $response @{ ok = $true; username = $newUsername }
        } catch {
          if (Test-DbUniqueViolation $_) { Send-Json $response @{ ok = $false; error = "That username is already taken." } }
          else { throw }
        }
      }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/users/approve") {
      if ($sessionUser.role -ne "admin") { Send-Json $response @{ ok = $false; error = "Admin access required." } 403 }
      else {
        $body = Read-Body $request
        if (-not (Get-DbUser $body.username)) { Send-Json $response @{ ok = $false; error = "No such user." } }
        else {
          Set-DbUserStatus $body.username "approved"
          Send-Json $response @{ ok = $true }
        }
      }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/users/reject") {
      if ($sessionUser.role -ne "admin") { Send-Json $response @{ ok = $false; error = "Admin access required." } 403 }
      else {
        # Admin accounts (including your own) can't be removed from here, so
        # the dashboard can never be left without an admin.
        $body = Read-Body $request
        $target = Get-DbUser ([string]$body.username)
        if ($target -and $target.role -eq "admin") { Send-Json $response @{ ok = $false; error = "Admin accounts can't be removed." } }
        else {
          if ($target) { Remove-DbUser $target.username }
          Send-Json $response @{ ok = $true }
        }
      }
    }
    elseif ($method -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html")) {
      Send-Page $response $indexFile
    }
    elseif ($method -eq "GET" -and $path -match "^/dispatch/([^/]+)$") {
      # The page a phone opens after scanning a client's QR code. Public - no
      # dashboard login. The first scan on a given device asks once who's
      # scanning and remembers it in a cookie on that device (scannerName,
      # set below and in the POST handler); every scan after that on the
      # same device is instant, no form, no login, nothing to open twice.
      # The link carries the record's random 256-bit dispatch token, never its
      # id, so QR links can't be guessed or enumerated.
      $token = [System.Uri]::UnescapeDataString($Matches[1])
      $found = Get-DbClientByDispatchToken $token
      $rec = if ($found) { $found.doc } else { $null }
      $dispatchPageStyle = "body{font-family:system-ui,sans-serif;background:#FAF7F2;color:#241C12;text-align:center;padding:50px 20px;}" +
        ".check{font-size:56px;color:#2E7D4F;}h1{font-size:20px;margin:14px 0 4px;}p{color:#6B6153;font-size:14px;}" +
        "form{max-width:280px;margin:22px auto 0;display:flex;flex-direction:column;gap:10px;text-align:left;}" +
        "label{font-size:12.5px;color:#6B6153;}input{font-size:16px;padding:11px 12px;border-radius:9px;border:1px solid #E4DCCB;}" +
        "button{font-size:15px;font-weight:600;padding:12px;border-radius:9px;border:1px solid #B5651D;background:#B5651D;color:#fff;}" +
        ".err{color:#B3382C;font-size:12.5px;}.hint2{font-size:11.5px;color:#B3A890;margin-top:2px;}"
      if ($null -eq $rec) {
        $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Not found</title>" +
          "<style>$dispatchPageStyle</style></head>" +
          "<body><h1>Record not found</h1><p>This QR code doesn't match anything in the dashboard - it may be old or the record was removed.</p></body></html>"
        Send-Text $response $page "text/html; charset=utf-8" 404
      } else {
        $name = if ($rec -is [System.Collections.IDictionary]) { $rec["name"] } else { $rec.name }
        $category = if ($rec -is [System.Collections.IDictionary]) { $rec["category"] } else { $rec.category }
        $dispatchedAt = if ($rec -is [System.Collections.IDictionary]) { $rec["dispatchedAt"] } else { $rec.dispatchedAt }
        $dispatchedBy = if ($rec -is [System.Collections.IDictionary]) { $rec["dispatchedBy"] } else { $rec.dispatchedBy }
        $safeName = [System.Web.HttpUtility]::HtmlEncode($name)
        $safeCat = [System.Web.HttpUtility]::HtmlEncode($category)
        $safeIdForUrl = [System.Web.HttpUtility]::HtmlEncode($token)
        if ($dispatchedAt) {
          $whenText = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$dispatchedAt).ToLocalTime().ToString("dd MMM yyyy, HH:mm")
          $safeBy = [System.Web.HttpUtility]::HtmlEncode($(if ($dispatchedBy) { $dispatchedBy } else { "(name not recorded)" }))
          $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Already dispatched</title>" +
            "<style>$dispatchPageStyle</style></head>" +
            "<body><div class='check'>&#10003;</div><h1>Already marked as dispatched</h1><p><strong>$safeName</strong> &middot; $safeCat</p>" +
            "<p>By $safeBy &middot; $whenText</p><p style='margin-top:24px;'>You can close this tab.</p></body></html>"
          Send-Text $response $page "text/html; charset=utf-8"
        } else {
          $scannerCookieRaw = Get-CookieValue $request "scannerName"
          $scannerName = if ($scannerCookieRaw) { Get-SafeScannerName ([System.Uri]::UnescapeDataString($scannerCookieRaw)) } else { "" }
          if ($scannerName) {
            $now = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            [void](Update-DbClient $found.id @{ dispatchedAt = $now; dispatchedBy = $scannerName })
            $whenText = (Get-Date).ToString("dd MMM yyyy, HH:mm")
            $safeBy = [System.Web.HttpUtility]::HtmlEncode($scannerName)
            # Refresh the cookie's expiry on every scan so a device in regular use never silently loses it.
            Set-ResponseCookie $response $request "scannerName" ([System.Uri]::EscapeDataString($scannerName)) 31536000
            $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Dispatched</title>" +
              "<style>$dispatchPageStyle</style></head>" +
              "<body><div class='check'>&#10003;</div><h1>Marked as dispatched</h1><p><strong>$safeName</strong> &middot; $safeCat</p><p>By $safeBy &middot; $whenText</p>" +
              "<p style='margin-top:24px;'>You can close this tab.</p></body></html>"
            Send-Text $response $page "text/html; charset=utf-8"
          } else {
            $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Confirm dispatch</title>" +
              "<style>$dispatchPageStyle</style></head>" +
              "<body><h1>$safeName</h1><p>$safeCat</p>" +
              "<form method='POST' action='/dispatch/$safeIdForUrl'>" +
              "<label for='courierName'>Your name (asked once per device)</label>" +
              "<input type='text' id='courierName' name='courierName' required autocomplete='off' placeholder='e.g. Ramesh'>" +
              "<div class='hint2'>Remembered on this device - you won't be asked again here.</div>" +
              "<button type='submit'>Confirm dispatch</button>" +
              "</form></body></html>"
            Send-Text $response $page "text/html; charset=utf-8"
          }
        }
      }
    }
    elseif ($method -eq "POST" -and $path -match "^/dispatch/([^/]+)$") {
      # Handles the one-time name form above. Sets the scannerName cookie so
      # every later scan on this same device skips straight to the GET
      # handler's auto-mark path above - asked once, never again.
      $token = [System.Uri]::UnescapeDataString($Matches[1])
      $found = Get-DbClientByDispatchToken $token
      $rec = if ($found) { $found.doc } else { $null }
      if ($null -eq $rec) {
        $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Not found</title>" +
          "<style>body{font-family:system-ui,sans-serif;background:#FAF7F2;color:#241C12;text-align:center;padding:60px 20px;}h1{font-size:22px;}p{color:#6B6153;}</style></head>" +
          "<body><h1>Record not found</h1><p>This QR code doesn't match anything in the dashboard - it may be old or the record was removed.</p></body></html>"
        Send-Text $response $page "text/html; charset=utf-8" 404
      } else {
        $name = if ($rec -is [System.Collections.IDictionary]) { $rec["name"] } else { $rec.name }
        $category = if ($rec -is [System.Collections.IDictionary]) { $rec["category"] } else { $rec.category }
        $alreadyDispatchedAt = if ($rec -is [System.Collections.IDictionary]) { $rec["dispatchedAt"] } else { $rec.dispatchedAt }
        $alreadyDispatchedBy = if ($rec -is [System.Collections.IDictionary]) { $rec["dispatchedBy"] } else { $rec.dispatchedBy }
        $form = Read-FormBody $request
        $courierName = ""
        if ($form -and $form.ContainsKey("courierName")) { $courierName = Get-SafeScannerName $form["courierName"] }
        $safeName = [System.Web.HttpUtility]::HtmlEncode($name)
        $safeCat = [System.Web.HttpUtility]::HtmlEncode($category)
        $safeIdForUrl = [System.Web.HttpUtility]::HtmlEncode($token)
        $formStyle = "body{font-family:system-ui,sans-serif;background:#FAF7F2;color:#241C12;text-align:center;padding:50px 20px;}" +
          ".check{font-size:56px;color:#2E7D4F;}h1{font-size:20px;margin:14px 0 4px;}p{color:#6B6153;font-size:14px;}" +
          "form{max-width:280px;margin:22px auto 0;display:flex;flex-direction:column;gap:10px;text-align:left;}" +
          "label{font-size:12.5px;color:#6B6153;}input{font-size:16px;padding:11px 12px;border-radius:9px;border:1px solid #E4DCCB;}" +
          "button{font-size:15px;font-weight:600;padding:12px;border-radius:9px;border:1px solid #B5651D;background:#B5651D;color:#fff;}" +
          ".err{color:#B3382C;font-size:12.5px;}"
        if ($alreadyDispatchedAt) {
          $whenText = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$alreadyDispatchedAt).ToLocalTime().ToString("dd MMM yyyy, HH:mm")
          $safeBy = [System.Web.HttpUtility]::HtmlEncode($(if ($alreadyDispatchedBy) { $alreadyDispatchedBy } else { "(name not recorded)" }))
          if ($courierName) { Set-ResponseCookie $response $request "scannerName" ([System.Uri]::EscapeDataString($courierName)) 31536000 }
          $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Already dispatched</title>" +
            "<style>$formStyle</style></head>" +
            "<body><div class='check'>&#10003;</div><h1>Already marked as dispatched</h1><p><strong>$safeName</strong> &middot; $safeCat</p><p>By $safeBy &middot; $whenText</p></body></html>"
          Send-Text $response $page "text/html; charset=utf-8"
        } elseif (-not $courierName) {
          $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Confirm dispatch</title>" +
            "<style>$formStyle</style></head>" +
            "<body><h1>$safeName</h1><p>$safeCat</p><p class='err'>Please enter your name to confirm dispatch.</p>" +
            "<form method='POST' action='/dispatch/$safeIdForUrl'>" +
            "<label for='courierName'>Your name (asked once per device)</label>" +
            "<input type='text' id='courierName' name='courierName' required autocomplete='off' placeholder='e.g. Ramesh'>" +
            "<button type='submit'>Confirm dispatch</button>" +
            "</form></body></html>"
          Send-Text $response $page "text/html; charset=utf-8" 400
        } else {
          $now = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
          [void](Update-DbClient $found.id @{ dispatchedAt = $now; dispatchedBy = $courierName })
          Set-ResponseCookie $response $request "scannerName" ([System.Uri]::EscapeDataString($courierName)) 31536000
          $whenText = (Get-Date).ToString("dd MMM yyyy, HH:mm")
          $safeBy = [System.Web.HttpUtility]::HtmlEncode($courierName)
          $page = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Dispatched</title>" +
            "<style>$formStyle</style></head>" +
            "<body><div class='check'>&#10003;</div><h1>Marked as dispatched</h1><p><strong>$safeName</strong> &middot; $safeCat</p><p>By $safeBy &middot; $whenText</p>" +
            "<p style='margin-top:24px;'>You can close this tab.</p></body></html>"
          Send-Text $response $page "text/html; charset=utf-8"
        }
      }
    }
    elseif ($method -eq "GET" -and $path -eq "/api/clients") {
      # Stored Data = every record with zero flags right now, across all
      # categories - purely computed, never a manually-set "approved" flag.
      # QR dispatch tokens are left out - only /api/dispatch-clients, which
      # checks dispatch access, hands those out.
      $snap = Get-ComputedSnapshot
      $clean = @($snap.flagged | Where-Object { $_.status -eq "clean" })
      Send-Json $response (Remove-DispatchToken $clean)
    }
    elseif ($method -eq "POST" -and $path -eq "/api/clients") {
      # A record added by hand. The server picks its id - never the browser.
      $doc = Get-BodyFields (Read-Body $request) $ServerOwnedFields
      $newId = Add-DbClient $doc
      Send-Json $response @{ ok = $true; id = $newId }
    }
    elseif ($method -eq "GET" -and $path -eq "/api/dispatch-clients") {
      # Separate, backend-gated read path for the Courier Dispatch Checks tab -
      # kept apart from /api/clients (which every approved user needs for the
      # other tabs) so dispatch access can be restricted to a specific set of
      # users without touching anyone else's access to the rest of the dashboard.
      $me = Get-DbUser $sessionUser.username
      if (-not $me -or -not (Test-CanDispatch $me)) { Send-Json $response @{ error = "You don't have access to the dispatch page. Ask an admin to grant it." } 403 }
      else {
        $snap = Get-ComputedSnapshot
        $clean = @($snap.flagged | Where-Object { $_.status -eq "clean" })
        Send-Json $response $clean
      }
    }
    elseif ($method -eq "GET" -and $path -eq "/api/tracking") {
      $list = @(Get-DbTrackingRecords)
      Send-Json $response @($list | Sort-Object -Property { $_.name })
    }
    elseif ($method -eq "POST" -and $path -eq "/api/tracking/import") {
      $body = Read-Body $request
      $rows = @()
      foreach ($row in @($body.rows)) {
        $awb = ("" + $row.awb).Trim()
        if (-not $awb) { continue }
        $rows += @{ awb = $awb; name = ("" + $row.name).Trim(); phone = ("" + $row.phone).Trim(); state = ("" + $row.state).Trim() }
      }
      $result = Import-DbTrackingRows $rows
      Send-Json $response @{ ok = $true; added = $result.added; updated = $result.updated }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/tracking/refresh") {
      # On-demand check, for a "Refresh now" button - the background poller
      # (tracking-poller.ps1) already does this automatically every 2 hours
      # per AWB and skips anything already delivered; this just doesn't make
      # someone wait for the next cycle. Capped so a big list can't turn one
      # click into dozens of outbound calls at once.
      $body = Read-Body $request
      $targets = if ($body -and $body.awb) {
        @(@($body.awb) | Select-Object -First 25 | ForEach-Object { Get-DbTrackingRecord ([string]$_) } | Where-Object { $_ })
      } else {
        @(Get-DbTrackingRecords | Where-Object { Test-NeedsCheck $_ } | Select-Object -First 25)
      }
      $checked = 0
      foreach ($rec in $targets) {
        $awb = $rec.awb
        if (-not (Test-NeedsCheck $rec)) { continue }
        $wasAlreadyDelivered = Test-AwbDelivered $rec.statusName
        $result = Get-AwbStatus $awb
        $rec.lastCheckedAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        if ($result.ok) {
          $rec.statusName = $result.statusName
          $rec.reasonName = $result.reasonName
          $rec.fromCenter = $result.fromCenter
          $rec.toCenter = $result.toCenter
          $rec.lastCenterName = $result.lastCenterName
          $rec.lastCenterContact = $result.lastCenterContact
          $rec.lastCenterMobile = $result.lastCenterMobile
          $rec.delivered = Test-AwbDelivered $result.statusName
          $rec.lastError = ""
          if ($wasAlreadyDelivered) { $rec.centerCheckAttempted = $true }
        } else {
          $rec.lastError = $result.error
        }
        Save-DbTrackingCheck $rec
        $checked++
      }
      Send-Json $response @{ ok = $true; checked = $checked }
    }
    elseif ($method -eq "GET" -and $path -eq "/api/staging") {
      # Review Upload = every record that currently has at least one flag -
      # a name/phone/pincode/RM problem, or a cross-category
      # duplicate - regardless of category, except one marked manualClean.
      # Fixing a record so it has zero flags left (or marking it manualClean)
      # is what moves it out of here; there is no separate approval step.
      $snap = Get-ComputedSnapshot
      $flaggedOnly = @($snap.flagged | Where-Object { $_.status -ne "clean" })
      $qCategory = $request.QueryString["category"]
      if ($qCategory) { $flaggedOnly = @($flaggedOnly | Where-Object { $_.category -eq $qCategory }) }
      Send-Json $response (Remove-DispatchToken $flaggedOnly)
    }
    elseif ($method -eq "GET" -and $path -eq "/api/staging-summary") {
      $snap = Get-ComputedSnapshot
      $flaggedOnly = @($snap.flagged | Where-Object { $_.status -ne "clean" })
      $summary = @{}
      foreach ($r in $flaggedOnly) {
        $cat = if ($r.category) { $r.category } else { "(no category)" }
        if (-not $summary.ContainsKey($cat)) { $summary[$cat] = 0 }
        $summary[$cat] = $summary[$cat] + 1
      }
      Send-Json $response $summary
    }
    elseif ($method -eq "GET" -and $path -eq "/api/duplicates") {
      # Duplicate names are checked across every record regardless of
      # whether it also has other flags - the point of this tab is purely
      # "same name in more than one category," independent of anything else.
      $snap = Get-ComputedSnapshot
      $all = @($snap.flagged)
      $byName = @{}
      foreach ($r in $all) {
        $key = Normalized-NameKey $r.name
        if (-not $key) { continue }
        if (-not $byName.ContainsKey($key)) { $byName[$key] = @() }
        $byName[$key] += , $r
      }
      $groups = @()
      foreach ($key in $byName.Keys) {
        $arr = $byName[$key]
        $cats = @($arr | ForEach-Object { $_.category } | Select-Object -Unique)
        if ($cats.Count -gt 1) {
          $items = @($arr | ForEach-Object { @{ id = $_.id; name = $_.name; category = $_.category; rm = $_.rm; phone = $_.phone } })
          $groups += @{ key = $key; items = $items }
        }
      }
      Send-Json $response $groups
    }
    elseif ($method -eq "POST" -and $path -eq "/api/import") {
      # No "stage" is set - a freshly-imported record with zero flags lands
      # straight in Stored Data, and one with flags lands in Review Upload,
      # purely because that's what its computed status already says.
      # The browser's per-row "id" is only used as the de-duplication key
      # (re-importing the same row updates it instead of adding a copy); the
      # record's real id is random and assigned by the database.
      $body = Read-Body $request
      $docs = @{}
      $count = 0
      foreach ($rec in @($body.records)) {
        $key = [string]$rec.id
        if ([string]::IsNullOrWhiteSpace($key) -or $key.Length -gt 500) { continue }
        $docs[$key] = Get-BodyFields $rec $ServerOwnedFields
        $count++
      }
      Save-DbClients $docs
      Send-Json $response @{ ok = $true; count = $count }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/delete-category") {
      # Removes every record for one category - Stored Data and Review
      # Upload rows alike, since there's no longer a separate "approved"
      # partition; this is "delete this whole uploaded sheet."
      $body = Read-Body $request
      $count = Remove-DbClientCategory $body.category
      Send-Json $response @{ ok = $true; count = $count }
    }
    elseif ($method -eq "PATCH" -and $path -match "^/api/clients/([^/]+)$") {
      $id = [System.Uri]::UnescapeDataString($Matches[1])
      $patch = Get-BodyFields (Read-Body $request) $ServerOwnedFields
      $touchesDispatch = $patch.ContainsKey("dispatchedAt") -or $patch.ContainsKey("dispatchedBy")
      if ($touchesDispatch -and -not (Test-CanDispatch (Get-DbUser $sessionUser.username))) {
        Send-Json $response @{ ok = $false; error = "You don't have dispatch access." } 403
      } elseif (Update-DbClient $id $patch) {
        Send-Json $response @{ ok = $true }
      } else {
        Send-Json $response @{ ok = $false; error = "No such record." } 404
      }
    }
    elseif ($method -eq "DELETE" -and $path -match "^/api/clients/([^/]+)$") {
      $id = [System.Uri]::UnescapeDataString($Matches[1])
      [void](Remove-DbClients @($id))
      Send-Json $response @{ ok = $true }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/bulk-delete") {
      $body = Read-Body $request
      [void](Remove-DbClients @($body.ids))
      Send-Json $response @{ ok = $true }
    }
    elseif ($method -eq "POST" -and $path -eq "/api/change-password") {
      # Wrong current passwords are throttled like logins; a successful
      # change signs this account out everywhere else.
      $body = Read-Body $request
      $me = Get-DbUser $sessionUser.username
      $pwKey = "password:" + $sessionUser.username.ToLowerInvariant()
      $newPassword = [string]$body.newPassword
      if (Test-DbThrottleLocked $pwKey) {
        Send-Json $response @{ ok = $false; error = "Too many failed attempts. Try again in 15 minutes." } 429
      } elseif (-not $me -or -not (Test-PasswordAgainst ([string]$body.currentPassword) $me)) {
        Register-DbThrottleFailure $pwKey 5 15 15
        Send-Json $response @{ ok = $false; error = "Current password is incorrect." }
      } elseif ($newPassword.Length -lt $MinPasswordLength) {
        Send-Json $response @{ ok = $false; error = "New password must be at least $MinPasswordLength characters." }
      } else {
        Set-DbUserPassword $me.username (New-PasswordHash $newPassword)
        Remove-DbUserSessions $me.username (Get-SessionToken $request)
        Clear-DbThrottle $pwKey
        Send-Json $response @{ ok = $true }
      }
    }
    else {
      Send-Text $response "Not found" "text/plain" 404
    }
  } catch {
    # Details go to the server console only - a client never sees internals
    # (SQL errors, file paths, stack traces).
    $ex = $_.Exception
    if ($ex -is [System.IO.InvalidDataException]) {
      $status = if ($ex.Message -eq "BODY_TOO_LARGE") { 413 } else { 400 }
      $msg = if ($status -eq 413) { "Request too large." } else { "Bad request." }
      try { Send-Json $response @{ ok = $false; error = $msg } $status } catch {}
    } else {
      Write-Host "  [$(Get-Date -Format u)] ERROR $($request.HttpMethod) $($request.Url.AbsolutePath): $($ex.Message)" -ForegroundColor Red
      try { Send-Json $response @{ ok = $false; error = "Something went wrong on the server." } 500 } catch {}
    }
  }
}

$listener.Stop()
