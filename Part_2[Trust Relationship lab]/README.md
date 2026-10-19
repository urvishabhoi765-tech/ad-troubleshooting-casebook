# Trust Relationship Failure: Repairing a Broken Computer Account Secure Channel

A hands-on Windows Server / Active Directory troubleshooting lab. I recreated the classic help desk error **"The trust relationship between this workstation and the primary domain failed"**, investigated it from both the workstation and the domain controller, and repaired it in seconds **without removing the PC from the domain**.

**Author:** Urvisha Bhoi
**Lab date:** October 18, 2026

---

## The problem

> "I can't sign in to my PC. It says 'The trust relationship between this workstation and the primary domain failed.' It worked yesterday."

Every domain-joined computer has its own **computer account** (`WIN11-WS01$`) and a secret **computer account password** that it shares with the domain controller. Windows changes it automatically about every 30 days. If a PC ends up with an **older** password than Active Directory, for example after being **restored from a snapshot or backup**, the domain controller rejects it and no domain user can sign in.

## Files in this folder

| File | Description |
|---|---|
| `Trust_Relationship_Troubleshooting_Report.docx` | Full report: every step and command with an explanation, 15 screenshots, investigation, fix, timeline and lessons learned |
| `Test-DomainTrust.ps1` | PowerShell health-check tool for trust problems (see below) |
| `README.md` | This file |

## Lab environment

| Item | Value |
|---|---|
| Virtualization | VMware Workstation, NAT network 192.168.76.0/24 |
| Domain | `testuser.local` (NetBIOS `TESTUSER`) |
| Domain controller | `DC01`, Windows Server 2022, 192.168.76.138 |
| Workstation | `WIN11-WS01`, Windows 11 Pro, 192.168.76.137 |
| Test user | `IT User02` (`ituser02`), never signed in on WIN11-WS01 before (no cached sign-in) |

## How the project was done

### 1. Prepare
- Disabled the scheduled task from my previous lockout lab to keep the logs clean.
- Created **IT User02**, so there was no cached sign-in to hide the problem.
- Confirmed the secure channel was healthy (`Test-ComputerSecureChannel` = True) and recorded the computer password date with `Get-ADComputer WIN11-WS01 -Properties PasswordLastSet` (Oct 15, 11:44 PM, the domain join).
- **Lesson:** the first check returned False because the connection had gone stale. `nltest /sc_verify` showed NERR_Success and refreshed it, so no repair was needed. Always confirm with a second tool.

### 2. Plant the problem (simulate "restored from an old backup")
- Took a VMware snapshot, **Before-Trust-Break**.
- Changed the computer password with `nltest /sc_change_pwd:testuser.local` (run twice, because the DC still accepts the previous computer password). Windows normally does this automatically every 30 days; the command just fast-forwards it.
- `Reset-ComputerMachinePassword` failed first with "user name or password is incorrect", because I was signed in as a **local** account; nltest uses the computer's own account instead.
- Reverted the snapshot and restarted. The PC now held the **Oct 15** password while Active Directory held the **4:05 PM** one.

### 3. Investigate
| Step | Tool / command | Finding |
|---|---|---|
| Symptom | Sign in as `TESTUSER\ituser02` | "The trust relationship ... failed" |
| Is the PC OK? | Sign in as `.\Urvisha` (local) | Works, so the problem is between the PC and the domain |
| Network / DNS | `ping 192.168.76.138`, `nslookup testuser.local` | Both work, so not connectivity |
| Secure channel | `Test-ComputerSecureChannel -Verbose` | **False**, the channel is broken |
| PC evidence | System log, **Event 3210** (NETLOGON) | "Could not authenticate with DC01... computer password not recognized" |
| DC evidence | System log on DC01, **Event 5722** (NETLOGON) | "Session setup from WIN11-WS01 failed... WIN11-WS01$... Access is denied" |
| Confirm | `Get-ADComputer ... PasswordLastSet` | AD expects the 4:05 PM password; the PC has the Oct 15 one |

### 4. Fix
```powershell
Test-ComputerSecureChannel -Repair -Credential TESTUSER\Administrator
```
Sets a new computer password on **both** the PC and the domain controller. No restart and no domain rejoin.

### 5. Verify
- `Test-ComputerSecureChannel` = **True**, `nltest /sc_verify` = **NERR_Success**
- `PasswordLastSet` updated to **4:19:34 PM** (the repair time)
- IT User02 signed in successfully

## Test-DomainTrust.ps1

A health-check tool for the "trust relationship failed" ticket. It runs on the **affected workstation** and walks through the same checks used in this lab, then tells you where the problem is.

**What it checks:**
1. **Computer and domain:** confirms the PC is domain-joined and which domain.
2. **DNS:** shows the configured DNS servers and tests that the domain name resolves.
3. **Domain controller discovery:** finds a DC with `nltest /dsgetdc`.
4. **Network:** pings the DC and tests the key ports (53 DNS, 88 Kerberos, 389 LDAP, 445 SMB).
5. **Secure channel:** runs both `Test-ComputerSecureChannel` and `nltest /sc_verify`, and re-tests once if they disagree (a stale connection, as seen in this lab).
6. **Event log:** counts recent NETLOGON **3210** (cannot authenticate with a DC) and **5719** (no DC available) events.

**Verdict:** it reports whether the trust is healthy, or whether the cause looks like **DNS**, **network/firewall**, or a **computer password mismatch**. It only offers a repair for the last case, because repairing the trust does not fix DNS or network problems.

**Usage** (Windows PowerShell 5.1, run as Administrator, for example signed in as a local admin):
```powershell
Set-ExecutionPolicy RemoteSigned -Scope Process -Force   # allow scripts in this window only

# Check only (makes no changes)
.\Test-DomainTrust.ps1

# Check and repair if the secure channel is broken
.\Test-DomainTrust.ps1 -Repair -Credential TESTUSER\Administrator
```

| Parameter | Purpose |
|---|---|
| `-Domain` | Domain to test (default: the PC's own domain) |
| `-Hours` | How far back to search for NETLOGON events (default 24) |
| `-Repair` | Repair the secure channel if it is broken and network/DNS are fine |
| `-Credential` | Domain account allowed to reset the computer account (prompted if omitted) |

> Note: `Test-ComputerSecureChannel` is only available in Windows PowerShell 5.1, not PowerShell 7. The script was written after the lab, so test it in a lab before using it on real machines.

## Key lessons

- **Computers sign in to the domain too**, with their own account (`NAME$`) and an automatically rotated password.
- "Trust relationship failed" is **not** a user password problem; narrow it down with a local sign-in, ping and nslookup.
- Check **both sides**: Event **3210** on the PC and Event **5722** on the DC.
- **Confirm with two tools** before acting; a stale connection can look like a broken trust.
- The DC accepts the **previous** computer password, so one change is not enough to break the trust.
- **Repair, don't rejoin:** `Test-ComputerSecureChannel -Repair` fixes it in seconds without restarts.

## How this happens in real companies

- A PC or VM restored from an old **snapshot, image or backup** (the cause in this lab)
- An admin **resets** or **deletes and recreates** the computer account
- **Two PCs with the same name**, or a clone deployed without **sysprep**
- Not because a PC was switched off for a long time: the PC starts the password change itself when it comes back online

## Recommendations

- After reverting a snapshot of a domain-joined machine, check the secure channel immediately.
- Never restore a **domain controller** from a VM snapshot without a supported recovery process (risk of USN rollback).
- Use `-Repair` before rejoining the domain; it is faster and keeps the computer account intact.
- Monitor **Event 5722** on domain controllers to catch broken trusts before users call.
- Keep a managed local administrator account (for example with Windows LAPS) so technicians can sign in to repair a PC.

## Skills demonstrated

Active Directory computer accounts · Netlogon secure channel · Event log analysis (3210, 5722) · PowerShell (`Test-ComputerSecureChannel`, `Get-ADComputer`) · nltest · VMware snapshots · Structured troubleshooting and documentation
