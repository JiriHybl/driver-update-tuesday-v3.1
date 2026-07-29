# install-pending-drivers.ps1
# Intune Remediation - Remediation Script
# Part 3, Step 3.2 of docs/setup-guide.md
#
# SYSTEM context, 64-bit PowerShell.
# Locale-independent session detection, calendar-day install deadline,
# localized notification, restart handling.
#
# Run as: SYSTEM (logged-on credentials: No)
# 64-bit PowerShell: Yes
# Schedule: Daily at the maintenance hour (example 22:00) in device LOCAL time
#           (do NOT select UTC for a multi-time-zone fleet)
# Assignment: In-scope devices, EXCLUDING the 24/7 / kiosk / shift exclusion group

$reg = 'HKLM:\SOFTWARE\DriverUpdateTuesday'
$installDeadlineDays = 5   # PARAMETER: calendar days before install is forced despite a session
if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
if ((Get-ItemProperty $reg -Name OptOut -ErrorAction SilentlyContinue).OptOut -eq 1) { exit 0 }

# Locale-independent interactive session detection (explorer.exe = interactive session)
$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue

$lang = (Get-WinSystemLocale).TwoLetterISOLanguageName
$mInstall = @{ en='IT Notice: Driver updates are being installed. Screen flicker and brief audio/network interruption are expected.' }
$mRestart = @{ en='IT Notice: Driver updates were installed. Please restart your device at your earliest convenience.' }
$mi = $mInstall[$lang]; if (-not $mi) { $mi=$mInstall['en'] }
$mr = $mRestart[$lang]; if (-not $mr) { $mr=$mRestart['en'] }

# Calendar-day deadline: stamped on first detection. Bounds the ON-but-busy case only;
# a device never online at the maintenance hour is covered by Active Hours, not this.
$dl = (Get-ItemProperty $reg -Name InstallDeadline -ErrorAction SilentlyContinue).InstallDeadline
if (-not $dl) { $deadline=(Get-Date).AddDays($installDeadlineDays); Set-ItemProperty $reg -Name InstallDeadline -Value $deadline.ToString('o') }
else { $deadline=[datetime]::Parse($dl) }
$forced = $false
if ($explorer) {
    if ((Get-Date) -lt $deadline) { Write-Output "Session present - defer until $($deadline.ToString('yyyy-MM-dd'))"; exit 0 }
    $forced = $true
}
$batt = (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).BatteryStatus
if ($batt -and $batt -ne 2) { Write-Output 'On battery - deferring'; exit 0 }

try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    if ($r.Updates.Count -eq 0) { Remove-ItemProperty $reg -Name InstallDeadline -ErrorAction SilentlyContinue; exit 0 }
    if ($forced) { msg console /TIME:120 $mi 2>$null; Start-Sleep 120 } else { msg console /TIME:30 $mi 2>$null }
    $d=$s.CreateUpdateDownloader(); $d.Updates=$r.Updates; $null=$d.Download()
    $i=$s.CreateUpdateInstaller(); $i.Updates=$r.Updates; $ir=$i.Install()
    Write-Output "Install: $($ir.ResultCode); Reboot: $($ir.RebootRequired)"  # 2=OK 3=OKwErr 4=Fail
    if ($ir.ResultCode -eq 4) { exit 1 }
    Remove-ItemProperty $reg -Name InstallDeadline -ErrorAction SilentlyContinue
    if ($ir.RebootRequired) {
        $now = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue
        if ($now) { msg console /TIME:60 $mr 2>$null; Write-Output 'Reboot deferred - user present' }
        else { shutdown /r /t 60 /c 'Driver updates installed by IT. Restarting in 60 seconds.' }
    }
    exit 0
} catch { Write-Output "Remediation error: $_"; exit 1 }
