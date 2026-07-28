<#
    Test-DriverApproval-DryRun.ps1
    ------------------------------------------------------------------
    LOCAL / VS CODE TEST VERSION of the Driver Update Tuesday runbook.

    PURPOSE: exercise the exact READ + FILTER logic of the real runbook,
    and show what it WOULD approve - WITHOUT changing anything.

    SAFETY:
      * $DryRun = $true  -> NO writes at all. No approvals, no revokes,
        no storage rows. There is nothing to revert.
      * Only GET calls are ever sent to Graph in dry-run mode.
      * The POST body that WOULD be sent is printed for inspection.

    AUTH (local): uses interactive sign-in as YOUR admin account, not a
    managed identity. You need the same permissions the runbook uses:
    WindowsUpdates.ReadWrite.All + Device.Read.All. Read-only here, but
    consent covers the later live test too.

    PREREQUISITES:
      Install-Module Az.Accounts -Scope CurrentUser
      (Microsoft.Graph module NOT required - we call Graph via REST with
       an Az token, exactly like the runbook does.)
    ------------------------------------------------------------------
#>

# ========================= CONFIG ==========================
# HARD SAFETY SWITCH. Leave $true for testing. Only set $false when you
# deliberately want the live test (and read the "GOING LIVE" note below).
$DryRun = $true

# Ring -> Autopatch driver policy id + its audience id.
# Fill these from: GET /beta/admin/windows/updates/updatePolicies
# For a first test you can include just ONE ring.
$rings = @(
    @{ Ring = 'Test';  PolicyId = '<test-policy-id>';  AudienceId = '<test-audience-id>';  OffsetDays = 0  }
    # @{ Ring = 'Pilot'; PolicyId = '<pilot-policy-id>'; AudienceId = '<pilot-audience-id>'; OffsetDays = 7  }
    # @{ Ring = 'Broad'; PolicyId = '<broad-policy-id>'; AudienceId = '<broad-audience-id>'; OffsetDays = 14 }
)

$MaintenanceHour = 22   # local maintenance hour used to build the (would-be) startDateTime
# ===========================================================


# ---- Sign in (interactive, local) ----
if (-not (Get-AzContext)) {
    Write-Host "Signing in interactively (use an admin account)..." -ForegroundColor Cyan
    Connect-AzAccount | Out-Null
}

$token = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
$gHead = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$base  = "https://graph.microsoft.com/beta/admin/windows/updates"

# ---- Helper: Graph GET with paging + 429 backoff (identical to runbook) ----
function Get-GraphPaged($Uri) {
    $items = @()
    while ($Uri) {
        $r = $null; $try = 0
        do {
            try { $r = Invoke-RestMethod -Uri $Uri -Headers $gHead; break }
            catch {
                if ($_.Exception.Response.StatusCode.value__ -eq 429 -and $try -lt 5) {
                    $wait = [int]($_.Exception.Response.Headers['Retry-After'] ?? 30)
                    Write-Host "  429 throttled, waiting $wait s..." -ForegroundColor DarkYellow
                    Start-Sleep $wait; $try++
                } else { throw }
            }
        } while ($true)
        $items += $r.value
        $Uri = $r.'@odata.nextLink'
    }
    return $items
}

# ---- Dry-run summary collectors ----
$wouldApprove = New-Object System.Collections.Generic.List[object]
$wouldSkip    = New-Object System.Collections.Generic.List[object]

Write-Host "`n=== DRY RUN: $DryRun (no changes will be made) ===`n" -ForegroundColor Green

foreach ($ring in $rings) {

    if ($ring.PolicyId -like '<*') {
        Write-Warning "Ring '$($ring.Ring)' still has placeholder IDs - fill them in. Skipping."
        continue
    }

    $deployUtc = (Get-Date -Hour $MaintenanceHour -Minute 0 -Second 0).AddDays($ring.OffsetDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "Ring '$($ring.Ring)'  (would schedule for $deployUtc)" -ForegroundColor Cyan

    # 1. applicable content for the ring's audience
    $applicable = Get-GraphPaged "$base/deploymentAudiences/$($ring.AudienceId)/applicableContent"
    Write-Host "  applicableContent returned $($applicable.Count) driver(s)"

    # existing approvals (read-only) so we can show 'already approved'
    $existing = Get-GraphPaged "$base/updatePolicies/$($ring.PolicyId)/complianceChanges?`$orderby=createdDateTime desc"

    foreach ($item in $applicable) {
        $catId = $item.catalogEntry.id
        $name  = $item.catalogEntry.displayName
        $ver   = $item.catalogEntry.version

        # 2. per-driver recommendation via the dedicated endpoint (paged)
        $matched     = Get-GraphPaged "$base/deploymentAudiences/$($ring.AudienceId)/applicableContent/$catId/matchedDevices"
        $recommended = $matched | Where-Object { $_.recommendedBy -contains "Microsoft" }

        if (-not $recommended) {
            Write-Host "  SKIP (not recommended): $name $ver" -ForegroundColor DarkGray
            $wouldSkip.Add([pscustomobject]@{ Ring=$ring.Ring; Driver=$name; Version=$ver; Reason='not recommended (no matched device has Microsoft)' })
            continue
        }

        # already approved & not revoked?
        $already = $existing | Where-Object { $_.content.catalogEntry.id -eq $catId -and -not $_.isRevoked }
        if ($already) {
            Write-Host "  SKIP (already approved): $name $ver" -ForegroundColor DarkGray
            $wouldSkip.Add([pscustomobject]@{ Ring=$ring.Ring; Driver=$name; Version=$ver; Reason='already approved (unrevoked)' })
            continue
        }

        # This one WOULD be approved. Build the exact body, but do not send it.
        $body = @{
            "@odata.type" = "#microsoft.graph.windowsUpdates.contentApproval"
            content = @{
                "@odata.type" = "#microsoft.graph.windowsUpdates.catalogContent"
                catalogEntry  = @{ "@odata.type" = "#microsoft.graph.windowsUpdates.driverUpdateCatalogEntry"; id = $catId }
            }
            deploymentSettings = @{
                "@odata.type" = "microsoft.graph.windowsUpdates.deploymentSettings"
                schedule      = @{ startDateTime = $deployUtc }
            }
        } | ConvertTo-Json -Depth 8

        $recDevices = ($recommended | Select-Object -ExpandProperty deviceId) -join ', '
        Write-Host "  WOULD APPROVE: $name $ver" -ForegroundColor Yellow
        Write-Host "     recommended for device(s): $recDevices" -ForegroundColor DarkYellow

        $wouldApprove.Add([pscustomobject]@{ Ring=$ring.Ring; Driver=$name; Version=$ver; CatalogId=$catId; StartDateTime=$deployUtc })

        if ($DryRun) {
            Write-Host "     [DRY RUN] POST body that WOULD be sent to /updatePolicies/$($ring.PolicyId)/complianceChanges :" -ForegroundColor DarkYellow
            Write-Host $body -ForegroundColor DarkGray
        }
        else {
            # ===== LIVE PATH - only runs if you deliberately set $DryRun = $false =====
            $res = Invoke-RestMethod -Method POST -Uri "$base/updatePolicies/$($ring.PolicyId)/complianceChanges" -Headers $gHead -Body $body
            Write-Host "     APPROVED (change id $($res.id))" -ForegroundColor Green
            Write-Host "     To revert: PATCH .../complianceChanges/$($res.id)  { isRevoked: true }" -ForegroundColor Magenta
        }
    }
    Write-Host ""
}

# ---- Summary ----
Write-Host "===================== SUMMARY =====================" -ForegroundColor Green
Write-Host "WOULD APPROVE: $($wouldApprove.Count)" -ForegroundColor Yellow
$wouldApprove | Format-Table Ring, Driver, Version, StartDateTime -AutoSize
Write-Host "WOULD SKIP: $($wouldSkip.Count)" -ForegroundColor DarkGray
$wouldSkip | Format-Table Ring, Driver, Version, Reason -AutoSize

if ($DryRun) {
    Write-Host "`nDRY RUN complete. No changes were made. Nothing to revert.`n" -ForegroundColor Green
} else {
    Write-Host "`nLIVE run complete. Any approvals above can be reverted with the PATCH shown next to each.`n" -ForegroundColor Magenta
}
