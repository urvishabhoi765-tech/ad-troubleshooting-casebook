<#
.SYNOPSIS
    Finds where an Active Directory account lockout is coming from.

.DESCRIPTION
    Reads the account status from the PDC Emulator, lists every lockout (Event 4740)
    with the source computer, and groups failed Kerberos sign-ins (Event 4771)
    by client IP address and failure code.

    Part of the "Recurring Domain Account Lockout" lab by Urvisha Bhoi (October 2026).

.PARAMETER User
    The account name (sAMAccountName) to investigate, for example ituser01.

.PARAMETER Hours
    How many hours of event history to search. Default: 24.

.EXAMPLE
    Set-ExecutionPolicy RemoteSigned -Scope Process -Force
    .\Find-LockoutSource.ps1 -User ituser01 -Hours 24

.NOTES
    Run on a domain controller, in PowerShell as Administrator.
    Requires the ActiveDirectory module and auditing for Events 4740 and 4771.
    Failure codes: 0x18 = wrong password, 0x12 = account locked/disabled/expired.
#>

param(
    [Parameter(Mandatory)][string]$User,
    [int]$Hours = 24
)

$pdc   = (Get-ADDomain).PDCEmulator
$since = (Get-Date).AddHours(-$Hours)

Write-Host "`n=== 1. Account status for $User (from $pdc) ===" -ForegroundColor Cyan
Get-ADUser $User -Server $pdc -Properties LockedOut, BadLogonCount, LastBadPasswordAttempt, AccountLockoutTime, PasswordLastSet |
    Select-Object SamAccountName, LockedOut, BadLogonCount, LastBadPasswordAttempt, AccountLockoutTime, PasswordLastSet |
    Format-List

Write-Host "=== 2. Lockout events (4740) - Caller Computer = source machine ===" -ForegroundColor Cyan
$lockouts = Get-WinEvent -ComputerName $pdc -FilterHashtable @{LogName='Security'; Id=4740; StartTime=$since} -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[0].Value -eq $User }
if ($lockouts) {
    $lockouts | Select-Object TimeCreated, @{n='CallerComputer'; e={$_.Properties[1].Value}} | Format-Table -AutoSize
} else {
    Write-Host "No lockout events found in the last $Hours hours.`n" -ForegroundColor Yellow
}

Write-Host "=== 3. Failed Kerberos sign-ins (4771) - by source IP and failure code ===" -ForegroundColor Cyan
Write-Host "    0x18 = wrong password   0x12 = account locked/disabled" -ForegroundColor DarkGray
$failures = Get-WinEvent -ComputerName $pdc -FilterHashtable @{LogName='Security'; Id=4771; StartTime=$since} -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[0].Value -eq $User }
if ($failures) {
    $failures |
        Group-Object { "$($_.Properties[6].Value -replace '::ffff:','')|0x{0:X}" -f [int]$_.Properties[4].Value } |
        Select-Object @{n='ClientIP';    e={ ($_.Name -split '\|')[0] }},
                      @{n='FailureCode'; e={ ($_.Name -split '\|')[1] }},
                      Count |
        Sort-Object Count -Descending |
        Format-Table -AutoSize
} else {
    Write-Host "No failed Kerberos events found in the last $Hours hours.`n" -ForegroundColor Yellow
}

Write-Host "=== Next step ===" -ForegroundColor Green
Write-Host "On the source computer, check Event 4625 (Logon Type: 4=scheduled task, 5=service, 3=network/mapped drive, 10=RDP)."
