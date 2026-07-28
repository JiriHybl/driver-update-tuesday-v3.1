<#
    Test-DriverApproval-LiveSingle.ps1
    ------------------------------------------------------------------
    LIVE single-driver approval test (VS Code / local, Graph SDK auth).

    This WRITES to the tenant, but safely:
      * Approves exactly ONE driver you specify.
      * Uses a FAR-FUTURE startDateTime so NOTHING deploys to devices
        during the test (offer window hasn't opened).
      * Verifies the approval created a 'scheduled' deployment.
      * Then, unless you pass -KeepApproval, REVOKES it (deployment ->
        'archived'), leaving the tenant as it was.

    This mirrors the manual Graph Explorer test we ran earlier, but
    through the SDK so it exercises the runbook's write path.

    PREREQUISITE:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

    USAGE:
        # default: approve -> verify -> revoke (fully reversible)
        .\Test-DriverApproval-LiveSingle.ps1

        # approve and LEAVE it in place (still far-future; revoke later yourself)
        .\Test-DriverApproval-LiveSingle.ps1 -KeepApproval
    ------------------------------------------------------------------
#>

param(
    [switch]$KeepApproval   # if set, does NOT auto-revoke at the end
)

# ========================= CONFIG ==========================
$LabTenantId = "<tenant-id>"

# Ring 3 policy + audience (from the lab)
$PolicyId   = "<ring-policy-id>"
$AudienceId = "<ring-audience-id>"

# The driver to approve for the test. Default = the June recommended driver.
$CatalogEntryId = "cba5c02eaa06fbaca910c305b64396ba7372fd90c6c7efb1833e8d3449f81c54"

# FAR-FUTURE offer date so nothing deploys during the test.
# 30 days out; adjust if you like, but keep it comfortably in the future.
$StartDateTime = (Get-Date).AddDays(30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
# ===========================================================

$needed = @('WindowsUpdates.ReadWrite.All','Device.Read.All')
$ctx = Get-MgContext
if (-not $ctx -or ($needed | Where-Object { $_ -notin $ctx.Scopes })) {
    Connect-MgGraph -Scopes $needed -TenantId $LabTenantId -NoWelcome
}
$ctx = Get-MgContext
Write-Host "Connected. Tenant: $($ctx.TenantId)  Account: $($ctx.Account)" -ForegroundColor DarkCyan
if ($ctx.TenantId -ne $LabTenantId) {
    Write-Warning "Connected tenant does not match the lab tenant. Aborting for safety."
    return
}

$base = "https://graph.microsoft.com/beta/admin/windows/updates"

Write-Host "`n=== LIVE SINGLE-DRIVER APPROVAL TEST ===" -ForegroundColor Green
Write-Host "Policy:   $PolicyId"
Write-Host "Driver:   $CatalogEntryId"
Write-Host "Schedule: $StartDateTime  (far future - nothing deploys during test)" -ForegroundColor Yellow
Write-Host ""

# ---- 1. APPROVE ----
$body = @{
    "@odata.type" = "#microsoft.graph.windowsUpdates.contentApproval"
    content = @{
        "@odata.type" = "#microsoft.graph.windowsUpdates.catalogContent"
        catalogEntry  = @{ "@odata.type" = "#microsoft.graph.windowsUpdates.driverUpdateCatalogEntry"; id = $CatalogEntryId }
    }
    deploymentSettings = @{
        "@odata.type" = "microsoft.graph.windowsUpdates.deploymentSettings"
        schedule      = @{ startDateTime = $StartDateTime }
    }
} | ConvertTo-Json -Depth 8

Write-Host "[1] POST approval..." -ForegroundColor Cyan
try {
    $approval = Invoke-MgGraphRequest -Method POST -Uri "$base/updatePolicies/$PolicyId/complianceChanges" -Body $body -OutputType PSObject
} catch {
    Write-Host "    FAILED:" -ForegroundColor Red
    Write-Host "    $($_.ErrorDetails.Message)" -ForegroundColor Red
    return
}
$changeId = $approval.id
Write-Host "    OK - complianceChange id: $changeId" -ForegroundColor Green
Write-Host "    isRevoked: $($approval.isRevoked)"

# ---- 2. VERIFY the deployment was scheduled ----
Start-Sleep -Seconds 5   # give the service a moment to spin up the deployment
Write-Host "`n[2] Verify scheduled deployment..." -ForegroundColor Cyan
$verifyUri = "$base/updatePolicies/$PolicyId/complianceChanges/$changeId/microsoft.graph.windowsUpdates.contentApproval?`$expand=deployments"
$verify = Invoke-MgGraphRequest -Method GET -Uri $verifyUri -OutputType PSObject
$dep = $verify.deployments | Select-Object -First 1
if ($dep) {
    Write-Host "    deployment id:    $($dep.id)"
    Write-Host "    state:            $($dep.state.effectiveValue)" -ForegroundColor Yellow
    Write-Host "    scheduled for:    $($dep.settings.schedule.startDateTime)"
    Write-Host "    audience:         $($dep.audience.id)"
    if ($dep.state.effectiveValue -eq 'scheduled') {
        Write-Host "    -> CONFIRMED: approval created a scheduled deployment (write path works)." -ForegroundColor Green
    } else {
        Write-Host "    -> Unexpected state (expected 'scheduled')." -ForegroundColor Yellow
    }
} else {
    Write-Host "    No deployment object found yet (may need a few more seconds)." -ForegroundColor Yellow
}

# ---- 3. REVOKE (unless -KeepApproval) ----
if ($KeepApproval) {
    Write-Host "`n[3] -KeepApproval set: leaving the approval in place." -ForegroundColor Magenta
    Write-Host "    It is scheduled for $StartDateTime. To revoke later:" -ForegroundColor Magenta
    Write-Host "    PATCH $base/updatePolicies/$PolicyId/complianceChanges/$changeId  { isRevoked: true }" -ForegroundColor Magenta
    return
}

Write-Host "`n[3] Revoke (cleanup)..." -ForegroundColor Cyan
$revokeBody = @{ "@odata.type" = "#microsoft.graph.windowsUpdates.contentApproval"; isRevoked = $true } | ConvertTo-Json
Invoke-MgGraphRequest -Method PATCH -Uri "$base/updatePolicies/$PolicyId/complianceChanges/$changeId" -Body $revokeBody | Out-Null

Start-Sleep -Seconds 5
$after = Invoke-MgGraphRequest -Method GET -Uri $verifyUri -OutputType PSObject
$depAfter = $after.deployments | Select-Object -First 1
Write-Host "    isRevoked now: $($after.isRevoked)" -ForegroundColor Green
if ($depAfter) { Write-Host "    deployment state now: $($depAfter.state.effectiveValue)" -ForegroundColor Green }
if ($after.isRevoked -and $depAfter.state.effectiveValue -eq 'archived') {
    Write-Host "    -> CONFIRMED: revoke worked, deployment archived. Tenant is clean." -ForegroundColor Green
} else {
    Write-Host "    -> Check state manually; expected isRevoked=true and deployment 'archived'." -ForegroundColor Yellow
}

Write-Host "`n=== TEST COMPLETE ===" -ForegroundColor Green
