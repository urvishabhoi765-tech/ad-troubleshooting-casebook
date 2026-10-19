# AD Troubleshooting Casebook

Hands-on Windows Server and Active Directory troubleshooting labs, built in a VMware home lab.
Each lab recreates a real help desk ticket, investigates it, fixes it, and documents every step.

## Labs

### Part 1: Recurring Account Lockout
- **Ticket:** "My account keeps getting locked, even after you unlock it."
- **Cause:** A scheduled task was still using the user's old password.
- **Key evidence:** Events 4740, 4771 and 4625 (Logon Type 4)
- **Fix:** Stopped the task first, then unlocked the account and updated the task's password.
- **Tool:** Find-LockoutSource.ps1

### Part 2: Trust Relationship Failure
- **Ticket:** "The trust relationship between this workstation and the primary domain failed."
- **Cause:** The PC was restored from an old snapshot, so its computer password no longer matched Active Directory.
- **Key evidence:** Event 3210 (PC) and Event 5722 (DC)
- **Fix:** Test-ComputerSecureChannel -Repair, without rejoining the domain.
- **Tool:** Test-DomainTrust.ps1

## What's in each folder
- **Report (PDF):** every step and command explained, with screenshots
- **PowerShell script:** a tool that automates the investigation
- **README:** a short summary of the lab

## Lab environment
- **Domain:** testuser.local
- **Domain controller:** DC01 (Windows Server 2022)
- **Workstation:** WIN11-WS01 (Windows 11 Pro)
- **Platform:** VMware Workstation

## Skills
Active Directory, Group Policy, security auditing, event log analysis, PowerShell,
Task Scheduler, secure channel troubleshooting, technical documentation

## About me
Urvisha Bhoi, Computer Security and Investigations graduate (Fleming College),
building hands-on IT support and cybersecurity skills.

## About me
Urvisha Bhoi, Computer Security and Investigations graduate (Fleming College),
building hands-on IT support and cybersecurity skills.
