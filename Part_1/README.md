# Recurring Domain Account Lockout: Tracing a Stale Saved Credential

A hands-on Windows Server / Active Directory troubleshooting lab. I recreated one of the most common help desk tickets, a user who keeps getting locked out, then investigated it with Active Directory, Event Viewer and PowerShell, fixed it in the right order, and wrote a script that automates the investigation.

**Author:** Urvisha Bhoi
**Lab dates:** October 16 to 18, 2026

---

## The problem

> "IT User01 keeps getting locked out every few minutes, even right after the help desk unlocks the account. The user says they have not typed a wrong password."

The real cause: a scheduled task on the user's PC was still signing in with the user's **old password**. Every run counted as a bad attempt on the domain controller, and after 5 attempts the account locked again, even after being unlocked.

## Files in this folder

| File | Description |
|---|---|
| `Account_Lockout_Troubleshooting_Report.docx` | Full report: lab build, every command with an explanation, 29 screenshots, the investigation, the fix, timeline and lessons learned |
| `Find-LockoutSource.ps1` | PowerShell script that finds where an account lockout is coming from in one command |
| `README.md` | This file |

## Lab environment

| Item | Value |
|---|---|
| Virtualization | VMware Workstation, NAT network 192.168.76.0/24 |
| Domain | `testuser.local` (NetBIOS `TESTUSER`) |
| Domain controller | `DC01`, Windows Server 2022, 192.168.76.138, AD DS + DNS |
| Workstation | `WIN11-WS01`, Windows 11 Pro, 192.168.76.137 |
| Test user | `IT User01` (`ituser01`), OU `Lab Users` |
| Lockout policy | 5 attempts, 15-minute lockout, 15-minute reset window |

## How the project was done

### 1. Build the lab
- Gave DC01 a static IP and pointed its DNS at itself (`netsh`), renamed it (`Rename-Computer`).
- Installed **Active Directory Domain Services** and created the forest `testuser.local` with Server Manager.
- Created the OU `Lab Users` and the user `IT User01`.
- Installed Windows 11 Pro, set a static IP with DNS pointing to DC01, renamed it `WIN11-WS01` and joined the domain.

### 2. Prepare for the investigation
- **Lockout policy** in the Default Domain Policy: threshold 5, duration 15 min, reset counter 15 min (`net accounts /domain` to confirm).
- **Auditing** in the Default Domain Controllers Policy: User Account Management (Event **4740**), Kerberos Authentication Service (**4771**), Credential Validation (**4776**), all Success and Failure (`auditpol /get` to confirm).
- **Logon auditing** on the workstation for Event **4625** (`auditpol /set /subcategory:"Logon" ...`).
- **Task Scheduler history** enabled on the workstation.

### 3. Plant the problem
- Created a scheduled task, "OneDrive Backup Sync", that runs every minute **as IT User01 with a saved password** (`Register-ScheduledTask -User -Password`).
- Granted IT User01 the **"Log on as a batch job"** right (required for the task to start).
- Reset IT User01's password **three times** in ADUC. Active Directory forgives the two most recent previous passwords (the "n-2" rule), so three changes are needed before the stale password starts counting.
- The account locked at 1:00 PM.

### 4. Investigate
| Step | Tool / command | Finding |
|---|---|---|
| Confirm symptom | Sign-in screen, `Get-ADUser -Properties LockedOut, BadLogonCount` | Account locked, 5 bad attempts |
| Unlock only | ADUC > Unlock account | Locked again at 1:11 PM, so unlocking is not a fix |
| Which computer? | Event **4740** on the PDC Emulator | Caller Computer Name: **WIN11-WS01** |
| Confirm source IP | Event **4771** | Client 192.168.76.137, code 0x18 (wrong password) then 0x12 (locked) |
| What on that PC? | Event **4625** on WIN11-WS01 | **Logon Type 4** (batch = scheduled task), process svchost.exe |
| Rule out others | `Get-CimInstance Win32_Service`, `cmdkey /list`, `net use` | No services, saved credentials or mapped drives |
| Which task? | `Get-ScheduledTask` with `Principal.LogonType` | Only "OneDrive Backup Sync" stores a password |

### 5. Fix, in the right order
1. `Disable-ScheduledTask` to stop the source.
2. Unlock the account in ADUC.
3. `Set-ADUser ituser01 -ChangePasswordAtLogon $false` (the "must change password" flag was blocking the task with error 0x80070773).
4. `Set-ScheduledTask -User -Password` to save the current password in the task.
5. `Enable-ScheduledTask`, `Start-ScheduledTask`, and confirm `LastTaskResult 0`.

**Result:** no new bad attempts or lockouts after the fix, the task runs every minute, and the user signs in normally.

## Using the script

`Find-LockoutSource.ps1` runs on a domain controller and reports:
1. The account's lockout status and bad password count (read from the PDC Emulator).
2. Every lockout (Event 4740) with the **source computer**.
3. Failed Kerberos sign-ins (Event 4771) grouped by **client IP** and **failure code**.

```powershell
# On a domain controller, PowerShell as Administrator
Set-ExecutionPolicy RemoteSigned -Scope Process -Force   # allows scripts in this window only
.\Find-LockoutSource.ps1 -User ituser01 -Hours 24
```

Example output from this lab: 3 lockouts, all from WIN11-WS01, and 46 failed sign-ins from 192.168.76.137 (24 wrong password, 22 already locked).

**Requirements:** ActiveDirectory PowerShell module (installed with AD DS / RSAT), audit policies for Events 4740 and 4771 enabled, administrator rights.

## Key lessons

- **Unlocking is not a fix.** Find and fix the source first, then unlock.
- **Event 4740** on the PDC Emulator gives the source computer; **Event 4625 Logon Type** on that computer tells you what kind of thing failed (4 task, 5 service, 3 network, 10 RDP).
- Active Directory forgives the **two most recent previous passwords**, so stale credentials can start causing lockouts long after the real mistake.
- Task Scheduler's "Last Run Result" can show success while the task fails to sign in every minute; check the event logs.
- Scheduled tasks and services cannot answer **"must change password at next logon"**.
- Keep **time zones consistent** across systems when comparing logs.

## Recommendations

- Run scheduled tasks and services under **dedicated service accounts** or **group Managed Service Accounts (gMSA)**, never personal accounts.
- Remind users to update saved passwords on phones, other devices and apps after a password change.
- Keep lockout and logon auditing enabled and forward security events to a central log system (SIEM).
- Many lockouts across many users at the same time suggests a **password-spray attack**, not a stale credential; escalate to security.

## Skills demonstrated

Active Directory administration · Group Policy · Windows security auditing · Event log analysis (4740, 4771, 4625) · Task Scheduler · PowerShell scripting · Structured troubleshooting and documentation
