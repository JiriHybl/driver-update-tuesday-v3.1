# detect-pending-drivers.ps1
# Intune Remediation - Detection Script
# Part 3, Step 3.1 of docs/setup-guide.md
#
# Exit 1 = pending drivers found (triggers remediation); Exit 0 = compliant
# Run as: SYSTEM, 64-bit PowerShell
# Schedule: Daily at the maintenance hour (example 22:00) in device LOCAL time

try {
    $reg = 'HKLM:\SOFTWARE\DriverUpdateTuesday'
    if ((Get-ItemProperty $reg -Name OptOut -ErrorAction SilentlyContinue).OptOut -eq 1) { exit 0 }
    $s = New-Object -ComObject Microsoft.Update.Session
    $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    if ($r.Updates.Count -gt 0) { Write-Output "Pending: $($r.Updates.Count)"; exit 1 }
    exit 0
} catch { Write-Output "Detection error: $_"; exit 0 }
