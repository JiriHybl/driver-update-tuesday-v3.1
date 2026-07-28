<#
    Test-StorageTableWrite.ps1
    ------------------------------------------------------------------
    Standalone test of the runbook's Azure Storage TABLE write path,
    using the REST Insert Entity API with an Entra (OAuth) token -
    the same method the runbook uses (just delegated as YOU locally,
    instead of the managed identity).

    WHAT IT PROVES (locally):
      * The REST call shape, headers, and body are correct.
      * The 2020-12-06 x-ms-version requirement for Table + Entra auth.
      * Table create, insert, read-back, (optional) delete.

    WHAT IT DOES NOT PROVE:
      * The MANAGED IDENTITY -> storage path. Locally you authenticate
        as yourself; the runbook uses the Automation Account's MI with
        the 'Storage Table Data Contributor' role. That role + its
        propagation can only be validated by running in Azure.
        BUT: your OWN account also needs that data role to run this
        test - see the RBAC note below.

    PREREQUISITE:
        Install-Module Az.Accounts -Scope CurrentUser

    RBAC (one-time, for THIS local test to work as you):
        Grant your admin account 'Storage Table Data Contributor' on
        the storage account. Being Owner/Contributor is NOT enough -
        those are control-plane; table data access needs the data role.
    ------------------------------------------------------------------
#>

# ========================= CONFIG ==========================
$StorageAccount = "<storage-account-name>"      # your storage account name
$TableName      = "DriverApprovals"
$LabTenantId    = "<tenant-id>"
$DeleteTestRow  = $true              # clean up the test row at the end
# ===========================================================

# ---- Sign in (delegated, local) ----
$ctx = Get-AzContext
if (-not $ctx -or $ctx.Tenant.Id -ne $LabTenantId) {
    Write-Host "Signing in to Azure (lab tenant)..." -ForegroundColor Cyan
    Connect-AzAccount -Tenant $LabTenantId | Out-Null
}
Write-Host "Account: $((Get-AzContext).Account)  Tenant: $((Get-AzContext).Tenant.Id)" -ForegroundColor DarkCyan

# ---- Storage token (SecureString-safe) ----
$tr = Get-AzAccessToken -ResourceUrl "https://storage.azure.com/"
$sToken = if ($tr.Token -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $tr.Token).Password
} else { $tr.Token }

$common = @{
    Authorization  = "Bearer $sToken"
    "x-ms-version" = "2020-12-06"      # REQUIRED >= 2020-12-06 for Entra auth on Table
    "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
    "Content-Type" = "application/json"
    Accept         = "application/json;odata=nometadata"
}
$acctUri = "https://$StorageAccount.table.core.windows.net"

Write-Host "`n=== STORAGE TABLE WRITE TEST ===" -ForegroundColor Green
Write-Host "Account: $StorageAccount   Table: $TableName`n"

# ---- 1. Create the table if it doesn't exist ----
Write-Host "[1] Ensure table '$TableName' exists..." -ForegroundColor Cyan
try {
    $createBody = @{ TableName = $TableName } | ConvertTo-Json
    Invoke-RestMethod -Method POST -Uri "$acctUri/Tables" -Headers $common -Body $createBody | Out-Null
    Write-Host "    Table created." -ForegroundColor Green
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 409) { Write-Host "    Table already exists (409) - fine." -ForegroundColor DarkGray }
    elseif ($code -eq 403) {
        Write-Host "    403 Forbidden. Your account likely lacks 'Storage Table Data Contributor'" -ForegroundColor Red
        Write-Host "    on this storage account (control-plane Owner is NOT enough). Grant it and retry." -ForegroundColor Red
        Write-Host "    $($_.ErrorDetails.Message)" -ForegroundColor DarkRed
        return
    }
    else { Write-Host "    Unexpected error ($code): $($_.ErrorDetails.Message)" -ForegroundColor Red; return }
}

# ---- 2. Insert a test entity ----
Write-Host "`n[2] Insert a test row..." -ForegroundColor Cyan
$pk = (Get-Date -Format "yyyy-MM-dd")
$rk = "TEST-" + [guid]::NewGuid().ToString()
$entity = @{
    PartitionKey  = $pk
    RowKey        = $rk
    Ring          = "Ring3"
    PolicyId      = "<ring-policy-id>"
    CatalogId     = "cba5c02e-test"
    DriverName    = "TEST ROW - safe to delete"
    Version       = "0.0.0.0"
    Action        = "test"
    StartDateTime = (Get-Date).ToUniversalTime().ToString("o")
    RecordedUtc   = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json
try {
    Invoke-RestMethod -Method POST -Uri "$acctUri/$TableName" -Headers $common -Body $entity | Out-Null
    Write-Host "    Inserted row PK=$pk RK=$rk (expect 204 No Content)." -ForegroundColor Green
} catch {
    Write-Host "    Insert failed ($($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)" -ForegroundColor Red
    return
}

# ---- 3. Read it back ----
Write-Host "`n[3] Read the row back..." -ForegroundColor Cyan
$readUri = "$acctUri/$TableName(PartitionKey='$pk',RowKey='$rk')"
try {
    $row = Invoke-RestMethod -Method GET -Uri $readUri -Headers $common
    Write-Host "    Read OK:" -ForegroundColor Green
    Write-Host "      DriverName: $($row.DriverName)"
    Write-Host "      Action:     $($row.Action)"
    Write-Host "      Recorded:   $($row.RecordedUtc)"
} catch {
    Write-Host "    Read failed: $($_.ErrorDetails.Message)" -ForegroundColor Red
}

# ---- 4. Delete the test row (cleanup) ----
if ($DeleteTestRow) {
    Write-Host "`n[4] Delete the test row (cleanup)..." -ForegroundColor Cyan
    $delHeaders = $common.Clone(); $delHeaders["If-Match"] = "*"
    try {
        Invoke-RestMethod -Method DELETE -Uri $readUri -Headers $delHeaders | Out-Null
        Write-Host "    Deleted. Table is clean." -ForegroundColor Green
    } catch {
        Write-Host "    Delete failed ($($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)" -ForegroundColor Yellow
        Write-Host "    (Row PK=$pk RK=$rk remains - remove manually if needed.)" -ForegroundColor Yellow
    }
} else {
    Write-Host "`n[4] Leaving the test row in place (PK=$pk RK=$rk)." -ForegroundColor Magenta
}

Write-Host "`n=== STORAGE TABLE TEST COMPLETE ===" -ForegroundColor Green
Write-Host "If all steps were green, the REST write path (headers, version, body) is correct." -ForegroundColor Green
Write-Host "Remember: this validated YOUR delegated access. The runbook's MANAGED IDENTITY" -ForegroundColor DarkYellow
Write-Host "still needs 'Storage Table Data Contributor' granted separately, verified in Azure." -ForegroundColor DarkYellow
