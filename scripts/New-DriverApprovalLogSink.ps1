<#
    New-DriverApprovalLogSink.ps1
    ------------------------------------------------------------------
    Creates, PROGRAMMATICALLY, the Log Analytics custom table and the
    Data Collection Rule (DCR, kind=Direct, no separate DCE needed)
    used for Driver Update Tuesday approval reporting.

    Uses the CURRENT Logs Ingestion API model (Entra/OAuth, DCR-scoped
    RBAC) - NOT the deprecated HTTP Data Collector API / shared key.

    Schema (all columns besides TimeGenerated/StartDateTime/RecordedUtc
    are 'string' - including GUID-like columns, per documented
    constraint that GUID columns must be typed as string in the DCR
    stream):
        TimeGenerated   datetime  (required by Log Analytics)
        Ring            string
        PolicyId        string
        CatalogId       string
        DriverName      string
        Version         string
        Action          string
        StartDateTime   datetime
        ChangeId        string
        RecordedUtc     datetime

    PREREQUISITE:
        Install-Module Az.Accounts, Az.OperationalInsights -Scope CurrentUser
        An existing Log Analytics workspace (you said you already have one).

    OUTPUT: prints the three values the runbook / test script needs:
        - DCE-less logs ingestion endpoint (from the DCR)
        - DCR immutable ID
        - Stream name
    ------------------------------------------------------------------
#>

# ========================= CONFIG ==========================
$SubscriptionId        = "<subscription-id>"
$ResourceGroup         = "<resource-group-name>"   # DCR is created here (project RG)
$WorkspaceResourceGroup = "<workspace-resource-group>"         # existing workspace lives here
$WorkspaceName         = "<workspace-name>"
$Location              = "eastus"                    # match workspace region
$TableName             = "DriverApprovals_CL"        # _CL suffix mandatory
$DcrName               = "dcr-driverapprovals"
# ===========================================================

Import-Module Az.Accounts
$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount | Out-Null; $ctx = Get-AzContext }
Write-Host "Account: $($ctx.Account)  Tenant: $($ctx.Tenant.Id)" -ForegroundColor DarkCyan

$tr = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
$armToken = if ($tr.Token -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $tr.Token).Password
} else { $tr.Token }
$armHead = @{ Authorization = "Bearer $armToken"; "Content-Type" = "application/json" }

$mgmtBase = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$wsMgmtBase = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$WorkspaceResourceGroup"
$wsResourceId = "$wsMgmtBase/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
$wsResourceIdBare = "/subscriptions/$SubscriptionId/resourceGroups/$WorkspaceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"

Write-Host "`n=== 1. Create custom table '$TableName' ===" -ForegroundColor Green

$tableBody = @{
    properties = @{
        schema = @{
            name = $TableName
            columns = @(
                @{ name = "TimeGenerated"; type = "datetime" }
                @{ name = "Ring";          type = "string" }
                @{ name = "PolicyId";      type = "string" }
                @{ name = "CatalogId";     type = "string" }
                @{ name = "DriverName";    type = "string" }
                @{ name = "Version";       type = "string" }
                @{ name = "Action";        type = "string" }
                @{ name = "StartDateTime"; type = "datetime" }
                @{ name = "ChangeId";      type = "string" }   # GUID -> string, per documented constraint
                @{ name = "RecordedUtc";   type = "datetime" }
            )
        }
    }
} | ConvertTo-Json -Depth 10

$tableUri = "$wsResourceId/tables/$($TableName)?api-version=2022-10-01"
try {
    Invoke-RestMethod -Method PUT -Uri $tableUri -Headers $armHead -Body $tableBody | Out-Null
    Write-Host "  Table create/update submitted." -ForegroundColor Green
} catch {
    Write-Host "  FAILED: $($_.ErrorDetails.Message)" -ForegroundColor Red
    return
}

Write-Host "  Waiting for table provisioning..." -ForegroundColor DarkGray
Start-Sleep -Seconds 20

Write-Host "`n=== 2. Create Data Collection Rule (kind=Direct, no DCE) ===" -ForegroundColor Green

$streamName = "Custom-$TableName"
$dcrBody = @{
    location = $Location
    kind     = "Direct"
    properties = @{
        streamDeclarations = @{
            "$streamName" = @{
                columns = @(
                    @{ name = "TimeGenerated"; type = "datetime" }
                    @{ name = "Ring";          type = "string" }
                    @{ name = "PolicyId";      type = "string" }
                    @{ name = "CatalogId";     type = "string" }
                    @{ name = "DriverName";    type = "string" }
                    @{ name = "Version";       type = "string" }
                    @{ name = "Action";        type = "string" }
                    @{ name = "StartDateTime"; type = "datetime" }
                    @{ name = "ChangeId";      type = "string" }
                    @{ name = "RecordedUtc";   type = "datetime" }
                )
            }
        }
        destinations = @{
            logAnalytics = @(
                @{ workspaceResourceId = $wsResourceIdBare; name = "driverApprovalsWorkspace" }
            )
        }
        dataFlows = @(
            @{
                streams      = @($streamName)
                destinations = @("driverApprovalsWorkspace")
                outputStream = $streamName
            }
        )
    }
} | ConvertTo-Json -Depth 12

$dcrUri = "$mgmtBase/providers/Microsoft.Insights/dataCollectionRules/$($DcrName)?api-version=2023-03-11"
try {
    $dcr = Invoke-RestMethod -Method PUT -Uri $dcrUri -Headers $armHead -Body $dcrBody
    Write-Host "  DCR created." -ForegroundColor Green
} catch {
    Write-Host "  FAILED: $($_.ErrorDetails.Message)" -ForegroundColor Red
    return
}

Write-Host "`n=== 3. Values needed for ingestion / RBAC ===" -ForegroundColor Green
Write-Host "  DCR immutable ID:  $($dcr.properties.immutableId)"
Write-Host "  Ingestion endpoint: $($dcr.properties.endpoints.logsIngestion)"
Write-Host "  Stream name:        $streamName"
Write-Host "  DCR resource ID:    $($dcr.id)"

Write-Host "`n=== 4. Grant YOUR account 'Monitoring Metrics Publisher' on the DCR (for local testing) ===" -ForegroundColor Cyan
Write-Host "  az role assignment create --assignee `"$($ctx.Account.Id)`" --role `"Monitoring Metrics Publisher`" --scope `"$($dcr.id)`"" -ForegroundColor DarkGray
Write-Host "  (Repeat later for the runbook's managed identity object id.)" -ForegroundColor DarkGray

Write-Host "`nSave the DCR immutable ID, ingestion endpoint, and stream name - the test script needs them." -ForegroundColor Yellow
