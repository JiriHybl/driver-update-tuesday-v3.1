<#
    Test-DriverApproval-DryRun-MgGraph.ps1
    ------------------------------------------------------------------
    LOCAL / VS CODE TEST VERSION - uses the Microsoft Graph PowerShell
    SDK so it can request the EXACT scopes (WindowsUpdates.ReadWrite.All
    + Device.Read.All), the same consent you used in Graph Explorer.

    Why not Get-AzAccessToken? That returns a token scoped to the Az
    client app, which does NOT include WindowsUpdates.ReadWrite.All ->
    the deployment-service calls return 403 Forbidden. Connect-MgGraph
    requests the right scopes explicitly.

    SAFETY: $DryRun = $true -> only GET calls are sent. No approvals,
    no revokes, no writes. Nothing to revert.

    PREREQUISITE (one-time):
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    (Authentication sub-module is enough - we use Invoke-MgGraphRequest
     for raw REST, so the full Microsoft.Graph meta-module isn't needed.)
    ------------------------------------------------------------------
#>

# ========================= CONFIG ==========================
$DryRun = $true    # HARD SAFETY SWITCH - leave $true for testing

$LabTenantId = "<lab-tenant-id>"   # optional but recommended - forces the correct tenant

$rings = @(
    @{ Ring = 'Ring3'; PolicyId = '<ring-policy-id>'; AudienceId = '<ring-audience-id>'; OffsetDays = 0 }
)

$MaintenanceHour = 22
# ===========================================================

# ---- Connect with explicit scopes (interactive) ----
$needed = @('WindowsUpdates.ReadWrite.All','Device.Read.All')
$ctx = Get-MgContext
if (-not $ctx -or ($needed | Where-Object { $_ -notin $ctx.Scopes })) {
    Write-Host "Signing in to Microsoft Graph with required scopes..." -ForegroundColor Cyan
    if ($LabTenantId -notlike '<*') {
        Connect-MgGraph -Scopes $needed -TenantId $LabTenantId -NoWelcome
    } else {
        Connect-MgGraph -Scopes $needed -NoWelcome
    }
}
$ctx = Get-MgContext
Write-Host "Connected. Tenant: $($ctx.TenantId)  Account: $($ctx.Account)" -ForegroundColor DarkCyan
Write-Host "Scopes: $($ctx.Scopes -join ', ')" -ForegroundColor DarkCyan

$base = "https://graph.microsoft.com/beta/admin/windows/updates"

# ---- Helper: Graph GET with paging, via the SDK (auth handled by SDK) ----
function Get-GraphPaged($Uri) {
    $items = @()
    while ($Uri) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        $items += $r.value
        $Uri = $r.'@odata.nextLink'
    }
    return $items
}

$wouldApprove = New-Object System.Collections.Generic.List[object]
$wouldSkip    = New-Object System.Collections.Generic.List[object]

Write-Host "`n=== DRY RUN: $DryRun (no changes will be made) ===`n" -ForegroundColor Green

foreach ($ring in $rings) {

    if ($ring.PolicyId -like '<*') { Write-Warning "Ring '$($ring.Ring)' has placeholder IDs. Skipping."; continue }

    $deployUtc = (Get-Date -Hour $MaintenanceHour -Minute 0 -Second 0).AddDays($ring.OffsetDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "Ring '$($ring.Ring)'  (would schedule for $deployUtc)" -ForegroundColor Cyan

    $applicable = Get-GraphPaged "$base/deploymentAudiences/$($ring.AudienceId)/applicableContent"
    Write-Host "  applicableContent returned $($applicable.Count) driver(s)"

    $existing = Get-GraphPaged "$base/updatePolicies/$($ring.PolicyId)/complianceChanges?`$orderby=createdDateTime desc"

    foreach ($item in $applicable) {
        $catId = $item.catalogEntry.id
        $name  = $item.catalogEntry.displayName
        $ver   = $item.catalogEntry.version

        $matched     = Get-GraphPaged "$base/deploymentAudiences/$($ring.AudienceId)/applicableContent/$catId/matchedDevices"
        $recommended = $matched | Where-Object { $_.recommendedBy -contains "Microsoft" }

        if (-not $recommended) {
            Write-Host "  SKIP (not recommended): $name $ver" -ForegroundColor DarkGray
            $wouldSkip.Add([pscustomobject]@{ Ring=$ring.Ring; Driver=$name; Version=$ver; Reason='not recommended' }); continue
        }

        $already = $existing | Where-Object { $_.content.catalogEntry.id -eq $catId -and -not $_.isRevoked }
        if ($already) {
            Write-Host "  SKIP (already approved): $name $ver" -ForegroundColor DarkGray
            $wouldSkip.Add([pscustomobject]@{ Ring=$ring.Ring; Driver=$name; Version=$ver; Reason='already approved' }); continue
        }

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
            $res = Invoke-MgGraphRequest -Method POST -Uri "$base/updatePolicies/$($ring.PolicyId)/complianceChanges" -Body $body -OutputType PSObject
            Write-Host "     APPROVED (change id $($res.id))" -ForegroundColor Green
            Write-Host "     To revert: PATCH .../complianceChanges/$($res.id)  { isRevoked: true }" -ForegroundColor Magenta
        }
    }
    Write-Host ""
}

Write-Host "===================== SUMMARY =====================" -ForegroundColor Green
Write-Host "WOULD APPROVE: $($wouldApprove.Count)" -ForegroundColor Yellow
$wouldApprove | Format-Table Ring, Driver, Version, StartDateTime -AutoSize
Write-Host "WOULD SKIP: $($wouldSkip.Count)" -ForegroundColor DarkGray
$wouldSkip | Format-Table Ring, Driver, Version, Reason -AutoSize

if ($DryRun) { Write-Host "`nDRY RUN complete. No changes were made. Nothing to revert.`n" -ForegroundColor Green }
else { Write-Host "`nLIVE run complete. Approvals above can be reverted with the PATCH shown.`n" -ForegroundColor Magenta }
