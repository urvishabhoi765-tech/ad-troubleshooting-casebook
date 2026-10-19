#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Checks whether a domain-joined Windows computer still trusts its domain,
    and can optionally repair a broken secure channel.

.DESCRIPTION
    Runs the same checks a help desk technician uses for the error
    "The trust relationship between this workstation and the primary domain failed":

      1. Computer and domain information
      2. DNS: configured DNS servers and whether the domain name resolves
      3. Domain controller discovery (nltest /dsgetdc)
      4. Network reachability of the domain controller (ping + key ports)
      5. Secure channel status (Test-ComputerSecureChannel and nltest /sc_verify)
      6. Recent NETLOGON trust errors in the System log (Events 3210 and 5719)

    It then prints a verdict. With -Repair, it repairs a broken secure channel
    using Test-ComputerSecureChannel -Repair and checks again.

    Part of the "Trust Relationship Failure" lab by Urvisha Bhoi (October 2026).

.PARAMETER Domain
    Domain to test. Default: the domain this computer is joined to.

.PARAMETER Hours
    How many hours of System log history to search for NETLOGON errors. Default: 24.

.PARAMETER Repair
    If the secure channel is broken (and the network and DNS checks pass),
    repair it with Test-ComputerSecureChannel -Repair.

.PARAMETER Credential
    Domain account allowed to reset the computer account (for example TESTUSER\Administrator).
    Needed with -Repair when you are signed in with a local account. You are prompted if omitted.

.EXAMPLE
    .\Test-DomainTrust.ps1
    Runs all checks and reports the result. Makes no changes.

.EXAMPLE
    .\Test-DomainTrust.ps1 -Repair -Credential TESTUSER\Administrator
    Runs all checks and repairs the secure channel if it is broken.

.NOTES
    Use Windows PowerShell 5.1 (the built-in "Windows PowerShell"), because
    Test-ComputerSecureChannel is not available in PowerShell 7.
    Run on the affected workstation, in PowerShell as Administrator
    (for example signed in with a local admin account such as .\Urvisha).
    Without -Repair the script only reads information and changes nothing.
#>

[CmdletBinding()]
param(
    [string]$Domain,
    [int]$Hours = 24,
    [switch]$Repair,
    [System.Management.Automation.PSCredential]$Credential
)

function Write-Section($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok($Text)      { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Bad($Text)     { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info($Text)    { Write-Host "  [INFO] $Text" -ForegroundColor Gray }

$result = [ordered]@{ Domain = $false; Dns = $false; DcFound = $false; Network = $false; SecureChannel = $false }

# ---------------------------------------------------------------------------
Write-Section "1. Computer and domain"
$cs = Get-CimInstance Win32_ComputerSystem
Write-Info "Computer name : $($cs.Name)"
if (-not $cs.PartOfDomain) {
    Write-Bad "This computer is not joined to a domain. Nothing to test."
    return
}
if (-not $Domain) { $Domain = $cs.Domain }
Write-Ok "Joined to domain: $Domain"
$result.Domain = $true

# ---------------------------------------------------------------------------
Write-Section "2. DNS"
$dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 |
    Where-Object { $_.ServerAddresses } |
    ForEach-Object { "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" }
foreach ($line in $dnsServers) { Write-Info "DNS servers -> $line" }

try {
    $ips = Resolve-DnsName -Name $Domain -Type A -ErrorAction Stop |
        Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
    if ($ips) { Write-Ok "$Domain resolves to: $($ips -join ', ')"; $result.Dns = $true }
    else      { Write-Bad "$Domain returned no addresses." }
} catch {
    Write-Bad "DNS cannot resolve $Domain. Check that this PC's DNS points to a domain controller."
}

# ---------------------------------------------------------------------------
Write-Section "3. Find a domain controller"
$dc = $null
$dsget = & nltest.exe "/dsgetdc:$Domain" 2>&1
$dcLine = $dsget | Where-Object { $_ -match '^\s*DC:\s*\\\\(\S+)' } | Select-Object -First 1
if ($dcLine -and ($dcLine -match '\\\\(\S+)')) {
    $dc = $Matches[1]
    Write-Ok "Domain controller found: $dc"
    $result.DcFound = $true
} else {
    Write-Bad "No domain controller found for $Domain (nltest /dsgetdc failed)."
    $dsget | ForEach-Object { Write-Info $_ }
}

# ---------------------------------------------------------------------------
Write-Section "4. Network reachability"
if ($dc) {
    if (Test-Connection -ComputerName $dc -Count 2 -Quiet) { Write-Ok "$dc replies to ping." }
    else { Write-Info "$dc does not reply to ping (ICMP may be blocked by a firewall; checking ports)." }

    $ports = [ordered]@{ 53 = 'DNS'; 88 = 'Kerberos'; 389 = 'LDAP'; 445 = 'SMB' }
    $portsOk = $true
    foreach ($p in $ports.Keys) {
        $ok = Test-NetConnection -ComputerName $dc -Port $p -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($ok) { Write-Ok "Port $p ($($ports[$p])) is open on $dc" }
        else     { Write-Bad "Port $p ($($ports[$p])) is NOT reachable on $dc"; $portsOk = $false }
    }
    $result.Network = $portsOk
} else {
    Write-Info "Skipped: no domain controller to test."
}

# ---------------------------------------------------------------------------
Write-Section "5. Secure channel (computer account trust)"
$scArgs = @{ ErrorAction = 'Stop' }
if ($dc) { $scArgs.Server = $dc }
$scOk = $false
try { $scOk = Test-ComputerSecureChannel @scArgs } catch { $scOk = $false }
if ($scOk) { Write-Ok "Test-ComputerSecureChannel: True" } else { Write-Bad "Test-ComputerSecureChannel: False" }

$verify = & nltest.exe "/sc_verify:$Domain" 2>&1
$trustLine = $verify | Where-Object { $_ -match 'Trust Verification Status' } | Select-Object -First 1
if ($trustLine) { Write-Info ("nltest " + $trustLine.Trim()) }
$nltestOk = [bool]($trustLine -and $trustLine -match 'NERR_Success')
if ($nltestOk) { Write-Ok "nltest /sc_verify: NERR_Success" } else { Write-Bad "nltest /sc_verify did not report NERR_Success" }

# The two tools can briefly disagree when a connection has gone stale.
# nltest /sc_verify re-establishes the channel, so test once more before deciding.
if (-not $scOk -and $nltestOk) {
    Write-Info "Results disagree (often a stale connection). Re-testing..."
    try { $scOk = Test-ComputerSecureChannel @scArgs } catch { $scOk = $false }
    if ($scOk) { Write-Ok "Test-ComputerSecureChannel is now True: the channel was only stale." }
}
$result.SecureChannel = ($scOk -and $nltestOk)

# ---------------------------------------------------------------------------
Write-Section "6. Recent NETLOGON trust errors (last $Hours hours)"
$events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'NETLOGON'; Id = 3210, 5719; StartTime = (Get-Date).AddHours(-$Hours) } -ErrorAction SilentlyContinue
if ($events) {
    $events | Group-Object Id | ForEach-Object {
        $meaning = if ($_.Name -eq '3210') { 'could not authenticate with a DC (computer password not recognized)' } else { 'no domain controller was available' }
        Write-Info ("Event {0} x{1}: {2}. Latest: {3}" -f $_.Name, $_.Count, $meaning, ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated)
    }
} else {
    Write-Ok "No Event 3210 or 5719 found."
}

# ---------------------------------------------------------------------------
Write-Section "Verdict"
if ($result.SecureChannel) {
    Write-Ok "The trust between this computer and $Domain is healthy."
}
elseif (-not $result.Dns -or -not $result.DcFound) {
    Write-Bad "Cause looks like DNS / DC discovery, not the computer password."
    Write-Info "Fix DNS first (this PC's DNS must point to a domain controller), then run the script again."
}
elseif (-not $result.Network) {
    Write-Bad "Cause looks like network or firewall: the domain controller's ports are not reachable."
    Write-Info "Fix connectivity first, then run the script again."
}
else {
    Write-Bad "Network and DNS are fine, but the secure channel is broken."
    Write-Info "Most likely cause: the computer account password no longer matches Active Directory"
    Write-Info "(for example after restoring a snapshot or backup). On the DC, look for Event 5722."

    if ($Repair) {
        Write-Section "Repair"
        if (-not $Credential) { $Credential = Get-Credential -Message "Domain account allowed to reset the computer account (e.g. DOMAIN\Administrator)" }
        try {
            $fixed = Test-ComputerSecureChannel @scArgs -Repair -Credential $Credential
        } catch {
            $fixed = $false
            Write-Bad "Repair failed: $($_.Exception.Message)"
        }
        if ($fixed) {
            Write-Ok "Repair succeeded. Re-checking..."
            $after = & nltest.exe "/sc_verify:$Domain" 2>&1 | Where-Object { $_ -match 'Trust Verification Status' }
            if ($after) { Write-Info ("nltest " + ($after | Select-Object -First 1).Trim()) }
            Write-Ok "Ask the user to sign in again. A restart is usually not needed."
        } else {
            Write-Bad "The trust is still broken. As a last resort, remove the computer from the domain and rejoin it."
        }
    } else {
        Write-Info "To repair, run:  .\Test-DomainTrust.ps1 -Repair -Credential DOMAIN\Administrator"
    }
}
