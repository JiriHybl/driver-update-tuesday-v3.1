<#
    Test-LogAnalyticsIngestion.ps1
    ------------------------------------------------------------------
    Sends ONE test row to the DriverApprovals_CL table via the CURRENT
    Logs Ingestion API (Entra/OAuth + DCR-scoped RBAC) - NOT the
    deprecated HTTP Data Collector API.

    Fill in the three values printed by New-DriverApprovalLogSink.ps1:
    DCR immutable ID, ingestion endpoint, stream name.

    PREREQUISITE: your account has 'Monitoring Metrics Publisher' on
    the DCR (see step 4 of the creation script).

    NOTE ON TIMING: a successful POST (200/204) means the row was
    ACCEPTED, not that it's queryable yet. Ingestion latency is
    typically a few minutes. The script waits, then queries.
    ------------------------------------------------------------------
#>

# ========================= CONFIG ==========================
$LabTenantId       = "<tenant-id>"
$IngestionEndpoint = "<dcr-logs-ingestion-endpoint>"
$DcrImmutableId    = "<dcr-immutable-id>"
$StreamName        = "Custom-DriverApprovals_CL"

# For the follow-up KQL check
$WorkspaceId       = "<workspace-id>"   # <workspace-name> customerId
# ===========================================================

$ctx = Get-AzContext
if (-not $ctx -or $ctx.Tenant.Id -ne $LabTenantId) {
    Connect-AzAccount -Tenant $LabTenantId | Out-Null
}
Write-Host "Account: $((Get-AzContext).Account)  Tenant: $((Get-AzContext).Tenant.Id)" -ForegroundColor DarkCyan

# ---- Token for the Monitor ingestion resource ----
$tr = Get-AzAccessToken -ResourceUrl "https://monitor.azure.com/"
$mToken = if ($tr.Token -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $tr.Token).Password
} else { $tr.Token }
$headers = @{ Authorization = "Bearer $mToken"; "Content-Type" = "application/json" }

Write-Host "`n=== LOG ANALYTICS INGESTION TEST (current Logs Ingestion API) ===" -ForegroundColor Green

$testChangeId = "TEST-" + [guid]::NewGuid().ToString()
$row = @(
    @{
        TimeGenerated = (Get-Date).ToUniversalTime().ToString("o")
        Ring          = "Ring3"
        PolicyId      = "<ring-policy-id>"
        CatalogId     = "cba5c02e-test"
        DriverName    = "TEST ROW - safe to ignore/delete"
        Version       = "0.0.0.0"
        Action        = "test"
        StartDateTime = (Get-Date).ToUniversalTime().ToString("o")
        ChangeId      = $testChangeId
        RecordedUtc   = (Get-Date).ToUniversalTime().ToString("o")
    }
) | ConvertTo-Json -AsArray -Depth 5

$ingestUri = "$IngestionEndpoint/dataCollectionRules/$DcrImmutableId/streams/$($StreamName)?api-version=2023-01-01"

Write-Host "[1] POST test row (ChangeId=$testChangeId)..." -ForegroundColor Cyan
try {
    Invoke-RestMethod -Method POST -Uri $ingestUri -Headers $headers -Body $row | Out-Null
    Write-Host "    Accepted (2xx). Row is NOT necessarily queryable yet - ingestion latency applies." -ForegroundColor Green
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    Write-Host "    FAILED ($code): $($_.ErrorDetails.Message)" -ForegroundColor Red
    if ($code -eq 403) {
        Write-Host "    Check 'Monitoring Metrics Publisher' role on the DCR for your account." -ForegroundColor Red
    }
    return
}

Write-Host "`n[2] Waiting 90s for ingestion latency..." -ForegroundColor Cyan
Start-Sleep -Seconds 90

Write-Host "`n[3] Query DriverApprovals_CL for the test row..." -ForegroundColor Cyan
if ($WorkspaceId -like '<*') {
    Write-Host "    WorkspaceId not filled in - skipping automated query." -ForegroundColor Yellow
    Write-Host "    Run this KQL manually in the workspace's Logs blade:" -ForegroundColor Yellow
    Write-Host "    DriverApprovals_CL | where ChangeId == `"$testChangeId`" | order by TimeGenerated desc" -ForegroundColor DarkGray
    return
}

# Query via the Log Analytics query API (needs a token for that resource)
$qtr = Get-AzAccessToken -ResourceUrl "https://api.loganalytics.io/"
$qToken = if ($qtr.Token -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $qtr.Token).Password
} else { $qtr.Token }
$qHeaders = @{ Authorization = "Bearer $qToken"; "Content-Type" = "application/json" }
$kql = "DriverApprovals_CL | where ChangeId == `"$testChangeId`" | order by TimeGenerated desc"
$queryBody = @{ query = $kql } | ConvertTo-Json

try {
    $result = Invoke-RestMethod -Method POST -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" -Headers $qHeaders -Body $queryBody
    $rows = $result.tables[0].rows
    if ($rows.Count -gt 0) {
        Write-Host "    FOUND - ingestion confirmed end to end." -ForegroundColor Green
        Write-Host "    $($rows[0] -join ' | ')"
    } else {
        Write-Host "    Not found yet. Ingestion can occasionally take longer than 90s - wait a bit and re-query," -ForegroundColor Yellow
        Write-Host "    or check for a schema mismatch (most common silent-drop cause)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "    Query failed: $($_.ErrorDetails.Message)" -ForegroundColor Red
}

Write-Host "`n=== TEST COMPLETE ===" -ForegroundColor Green
