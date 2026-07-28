<#
    Driver Update Tuesday - Approval Runbook
    ------------------------------------------------------------------
    ONE runbook. Helpers first, then the per-ring approval loop at the
    bottom. Graph calls proven against /beta deployment-service
    endpoints in an Autopatch lab. Reporting now uses the CURRENT Log
    Analytics Logs Ingestion API (DCR, kind=Direct, Entra/OAuth) - NOT
    the deprecated HTTP Data Collector API.

    Runs as the Automation Account's system-assigned MANAGED IDENTITY.
    Two permission grants required on that identity (see setup guide):
      - Microsoft Graph app permissions: WindowsUpdates.ReadWrite.All,
        Device.Read.All
      - Azure RBAC: 'Monitoring Metrics Publisher' on the DCR created
        by New-DriverApprovalLogSink.ps1 (DCR-scoped, not workspace-wide)
    ------------------------------------------------------------------
#>

# ========================= CONFIG ==========================
# Ring -> Autopatch driver policy id + its audience id (resolve once, store as variables)
$rings = @(
    @{ Ring='Test';  PolicyId='<test-policy-id>';  AudienceId='<test-audience-id>';  OffsetDays=0  },
    @{ Ring='Pilot'; PolicyId='<pilot-policy-id>'; AudienceId='<pilot-audience-id>'; OffsetDays=7  },
    @{ Ring='Broad'; PolicyId='<broad-policy-id>'; AudienceId='<broad-audience-id>'; OffsetDays=14 }
)

$MaintenanceHour = 22   # local maintenance hour used to build the offer startDateTime

# Log Analytics DCR reporting sink (values printed by New-DriverApprovalLogSink.ps1)
$LogIngestionEndpoint = "<dcr-logs-ingestion-endpoint>"   # e.g. https://dcr-driverapprovals-xxxx.<region>.ingest.monitor.azure.com
$LogDcrImmutableId    = "<dcr-immutable-id>"              # e.g. dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxx
$LogStreamName        = "Custom-DriverApprovals_CL"
# ===========================================================

Connect-AzAccount -Identity | Out-Null

# ---- Graph token (app-only, via managed identity) ----
$gToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
if ($gToken -is [System.Security.SecureString]) { $gToken = [System.Net.NetworkCredential]::new('', $gToken).Password }
$gHead  = @{ Authorization = "Bearer $gToken"; "Content-Type" = "application/json" }
$base   = "https://graph.microsoft.com/beta/admin/windows/updates"

# ---- Helper 1: Graph GET with paging + 429 backoff ----
function Get-GraphPaged($Uri) {
    $items=@()
    while ($Uri) {
        $r=$null; $try=0
        do { try { $r=Invoke-RestMethod -Uri $Uri -Headers $gHead; break }
             catch { if ($_.Exception.Response.StatusCode.value__ -eq 429 -and $try -lt 5) {
                 Start-Sleep ([int]($_.Exception.Response.Headers['Retry-After'] ?? 30)); $try++ } else { throw } }
        } while ($true)
        $items += $r.value; $Uri = $r.'@odata.nextLink'
    }
    $items
}

# ---- Helper 2: write one approval row to Log Analytics via the DCR (MI + Logs Ingestion API) ----
function Write-ApprovalRecord {
    param($Ring,$PolicyId,$CatalogId,$DriverName,$Version,$ChangeId,$StartDateTime,$Action)

    # Token resource for Monitor ingestion is https://monitor.azure.com/ - separate from the ARM
    # and Graph tokens above; request it fresh here (managed identity, no secret).
    $mToken = (Get-AzAccessToken -ResourceUrl "https://monitor.azure.com/").Token
    if ($mToken -is [System.Security.SecureString]) { $mToken = [System.Net.NetworkCredential]::new('', $mToken).Password }
    $mHead = @{ Authorization = "Bearer $mToken"; "Content-Type" = "application/json" }

    # Logs Ingestion API expects an ARRAY of rows, even for a single row.
    $row = @(
        @{
            TimeGenerated = (Get-Date).ToUniversalTime().ToString("o")
            Ring          = $Ring
            PolicyId      = $PolicyId
            CatalogId     = $CatalogId
            DriverName    = $DriverName
            Version       = $Version
            Action        = $Action
            StartDateTime = $StartDateTime
            ChangeId      = $ChangeId          # GUID typed as string on the DCR stream
            RecordedUtc   = (Get-Date).ToUniversalTime().ToString("o")
        }
    ) | ConvertTo-Json -AsArray -Depth 5

    $uri = "$LogIngestionEndpoint/dataCollectionRules/$LogDcrImmutableId/streams/$($LogStreamName)?api-version=2023-01-01"
    try {
        Invoke-RestMethod -Method POST -Uri $uri -Headers $mHead -Body $row | Out-Null
        # 2xx = accepted; ingestion latency of a few minutes before it's queryable. Not an error.
    } catch {
        # Do not let a reporting failure abort the approval loop - log and continue.
        Write-Warning "Log Analytics ingestion failed for change $ChangeId : $($_.Exception.Message)"
    }
}

# ---- Main loop: approve recommended drivers per ring, then log each ----
foreach ($ring in $rings) {
    $deployUtc = (Get-Date -Hour $MaintenanceHour -Minute 0 -Second 0).AddDays($ring.OffsetDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $applicable = Get-GraphPaged "$base/deploymentAudiences/$($ring.AudienceId)/applicableContent"
    foreach ($item in $applicable) {
        $catId = $item.catalogEntry.id

        # Per-driver recommendation check (dedicated endpoint, paginated)
        $matched = Get-GraphPaged "$base/deploymentAudiences/$($ring.AudienceId)/applicableContent/$catId/matchedDevices"
        $recommended = $matched | Where-Object { $_.recommendedBy -contains "Microsoft" }
        if (-not $recommended) { Write-Output "$($ring.Ring): skip (not recommended) $($item.catalogEntry.displayName)"; continue }

        # Skip if already approved and not revoked (the PORTAL IS NOT the source of truth - see setup guide Part 6).
        # Source of truth is this Graph query itself.
        $existing = Get-GraphPaged "$base/updatePolicies/$($ring.PolicyId)/complianceChanges?`$orderby=createdDateTime desc"
        if ($existing | Where-Object { $_.content.catalogEntry.id -eq $catId -and -not $_.isRevoked }) {
            Write-Output "$($ring.Ring): already approved $($item.catalogEntry.displayName)"; continue }

        $body = @{
            "@odata.type" = "#microsoft.graph.windowsUpdates.contentApproval"
            content = @{
                "@odata.type" = "#microsoft.graph.windowsUpdates.catalogContent"
                catalogEntry = @{ "@odata.type"="#microsoft.graph.windowsUpdates.driverUpdateCatalogEntry"; id=$catId }
            }
            deploymentSettings = @{ "@odata.type"="microsoft.graph.windowsUpdates.deploymentSettings"; schedule=@{ startDateTime=$deployUtc } }
        } | ConvertTo-Json -Depth 8

        $res = Invoke-RestMethod -Method POST -Uri "$base/updatePolicies/$($ring.PolicyId)/complianceChanges" -Headers $gHead -Body $body
        Write-Output "$($ring.Ring): approved $($item.catalogEntry.displayName) for $deployUtc (change $($res.id))"

        # Log to Log Analytics (Helper 2, defined above)
        Write-ApprovalRecord -Ring $ring.Ring -PolicyId $ring.PolicyId -CatalogId $catId `
            -DriverName $item.catalogEntry.displayName -Version $item.catalogEntry.version `
            -ChangeId $res.id -StartDateTime $deployUtc -Action 'approved'
    }
}
