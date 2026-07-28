# Driver Update Tuesday — Setup Guide

**Autopatch-Managed Design (Lab-Verified)** · Version 3.1 · Windows Autopatch driver policies + Intune Remediations

> [!TIP]
> This is the detailed, step-by-step build guide. For the big picture, start with the [architecture overview](architecture.md) or the [repo README](../README.md).

---

> [!TIP]
> **Lab-verified:** The Graph API sequence in this guide (enumerate policies, read applicable content, filter by recommendation, approve with a scheduled date, revoke) was validated end-to-end in a live Autopatch lab tenant against the documented /beta deployment-service endpoints. Items proven in that lab are marked LAB-VERIFIED. The client-side Remediation (Part 3) is unchanged from earlier versions.

> [!WARNING]
> All Graph endpoints used here are /beta and Microsoft documents them against Graph-created deployment policies. This design drives the Autopatch-group-created driver policies, which was proven to work in-lab but is not an explicitly Microsoft-supported pattern. Confirm supportability with Microsoft (FastTrack/support) before production rollout for a customer.


## Overview

This solution delivers Windows driver updates on a Patch Tuesday cadence, fully automated with no per-driver human approval, with installation pinned to a maintenance hour in device local time, staged across Autopatch deployment rings. Example parameter values (22:00 maintenance hour, T / T+7 / T+14 stagger, 5-day install deadline) are set per environment.

| Component | Role |
| --- | --- |
| Autopatch group, driver policies (manual mode) | Controls when drivers are offered. Autopatch owns ring composition and audience membership. |
| Azure Automation Runbook + Logic App | Runs on Patch Tuesday. Approves Microsoft-recommended drivers per ring with staggered deployment dates. Makes manual mode fully automated. |
| Intune Remediation | Client-side installation gate: daily at the maintenance hour, session-aware with an install deadline, user notification, restart handling. |
| Log Analytics (custom table + DCR) | Truthful approval log written by the runbook (the Autopatch portal does not reflect API approvals — see Part 6). |


### Three timing mechanisms — do not confuse them

1. Autopatch ring deferral/deadline settings — server-side, in days. Govern the ring's quality/feature rollout, NOT driver installation timing.
2. Approval deploymentDate (T / T+7 / T+14) — server-side, per ring. Sets when a driver is OFFERED to each ring. This is the ring stagger and the primary risk control.
3. installDeadlineDays (client script) — client-side, per device, in calendar days. Bounds how long one busy device may postpone INSTALLATION before it is forced. NOT an Autopatch deferral.

---


## Prerequisites

| Requirement | Details |
| --- | --- |
| Autopatch driver management | Windows Enterprise E3/E5, Microsoft 365 E3/E5/A3/A5, or Business Premium |
| Intune Remediations | Microsoft 365 E3/E5, Intune Plan 2, or Intune Suite (NOT Business Premium) |
| Device state | Intune-managed, Entra joined or hybrid joined (Autopatch does not support on-prem-only domain-joined). Diagnostic data at Required or higher. |
| Runbook Graph permission | WindowsUpdates.ReadWrite.All + Device.Read.All (application permissions on the runbook managed identity) |
| Runbook Log Analytics permission | Monitoring Metrics Publisher, scoped to the DCR (data-plane role, DCR-scoped not workspace-scoped) |
| Admin roles for setup | Autopatch Administrator + Policy and Profile Manager (Device Configuration) |

> [!NOTE]
> The Graph permission set is per Microsoft's driver programmatic-controls documentation: WindowsUpdates.ReadWrite.All for Autopatch operations, Device.Read.All to read device info. Do NOT use DeviceManagementConfiguration.ReadWrite.All — it is broader and not what this API requires.


---


## Part 1: Autopatch Group and Driver Policies

> [!NOTE]
> Ring count is NOT fixed at three. Autopatch creates exactly one driver policy (and one audience) per deployment ring configured in your Autopatch group — automatically, not something you create yourself. This guide's Test/Pilot/Broad example is illustrative, chosen for simplicity. A real Autopatch group commonly has more rings (e.g. separate Fast rings per region or device type), and the number of driver policies you see in GET /updatePolicies will match however many rings you actually configured — it could be 3, 6, or more. Wherever this guide says 'three rings' or shows a $rings array with three entries, treat it as an example to extend to however many rings your own Autopatch group has, not a platform limit.


### Step 1.1 — Hardware Coverage Planning

1. Export the device model inventory (Intune > Devices > All devices > Export, or Graph managedDevices with model).
2. Identify representative devices of each major model line of every OEM vendor (plus dock and discrete-GPU variants) for the Test and Pilot rings. Prefer non-critical devices.
3. Where the only representative of a rare model is business-critical, place it in Pilot rather than Test.
> [!WARNING]
> A device assigned to an Autopatch ring receives ALL update workloads Autopatch manages for that ring (quality, feature, driver) on that ring's schedule. Autopatch rings are not per-workload. Choose representatives accordingly.


### Step 1.2 — Create the Autopatch Group with Driver Updates in Manual Mode

1. Intune portal > Tenant administration > Windows Autopatch > Autopatch groups > Create.
2. Configure deployment rings — as many as your environment needs (this guide's examples use three: Test, Pilot, Broad, but your group may have more). Assign your Entra groups to each ring; use dynamic distribution or an assigned group for the last/broad ring. Test and Last support assigned-group distribution only.
3. On the update types page, SELECT driver updates.
4. Set the driver approval method to MANUAL (per ring, or same for all rings). Manual mode is required so the runbook controls approval timing.
> [!WARNING]
> Switching a driver policy between Automatic and Manual approval mode regenerates the policies and DISCARDS all approvals, paused, and declined drivers. Set Manual at creation and never toggle in production.

> [!TIP]
> **Lab-verified:** Autopatch-created per-ring driver policies are enumerable via GET /beta/admin/windows/updates/updatePolicies, each with autoEnrollmentUpdateCategories = ['driver'] and its own audience. Their audiences are populated by Autopatch via updatableAssetGroup references, not individual devices — so the runbook must never manage audience membership.

5. Count your actual rings before moving on: run the GET /updatePolicies call above and count the entries with autoEnrollmentUpdateCategories = ['driver'] — that count IS your ring count. In one lab run of this guide, an Autopatch group configured with more granular rings than the Test/Pilot/Broad example returned SIX driver policies, not three. There is no ring-name field in the response, so matching each returned policy/audience pair to a specific ring name is done via the Intune portal (open each ring's driver policy and note its policy id) — see Appendix A for the exact calls, and the note in Step 2.3 for how this feeds the runbook's $rings array.

---


## Part 2: Monthly Approval Automation


### Step 2.1 — Automation Account and Permissions

1. Create an Azure Automation Account with a System-assigned Managed Identity.
2. Grant the managed identity the Graph application permissions WindowsUpdates.ReadWrite.All and Device.Read.All (one-time, via PowerShell):
```powershell
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
$mi      = "<managed-identity-object-id>"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
foreach ($perm in 'WindowsUpdates.ReadWrite.All','Device.Read.All') {
    $role = $graphSp.AppRoles | Where-Object { $_.Value -eq $perm }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi -PrincipalId $mi `
        -ResourceId $graphSp.Id -AppRoleId $role.Id
}
```

3. Create the Log Analytics reporting sink (custom table + DCR) — see Step 2.1a below. If you already operate a Log Analytics workspace, reuse it; the DCR can live in a different resource group than the workspace.

### Step 2.1a — Log Analytics Reporting Sink (custom table + DCR)

Reporting uses the CURRENT Log Analytics Logs Ingestion API — a Data Collection Rule (DCR) with kind=Direct (no separate Data Collection Endpoint needed) and a custom table, both created programmatically. This is NOT the deprecated HTTP Data Collector API (shared-key, ods.opinsights.azure.com), which retires 14 September 2026 and would in any case be blocked by a DisableLocalAuth-type policy in a hardened tenant.

> [!TIP]
> **Lab-verified:** Lab-verified end to end: table and DCR created via ARM REST, one test row POSTed to the DCR ingestion endpoint, and successfully queried back from the workspace after ingestion latency. Confirms the full write and read path on the documented, non-deprecated API.

> [!WARNING]
> An earlier design used an Azure Storage Table for this reporting sink. It was abandoned after a tenant policy (a 'modify' effect policy forcing PublicNetworkAccess=Disabled on all storage accounts) silently reverted every attempt to open the account to traffic — blocking both a local test machine and the Azure Automation shared sandbox equally. If your target tenant has a similar storage-hardening policy, expect the same result; Log Analytics ingestion tends to be less commonly network-restricted in these tenants, but verify reachability in your own environment before committing to either sink (see Appendix C).

1. If you don't already have one, create a Log Analytics workspace (any resource group/region; the DCR does not need to share either).
2. Run the script below once to create the custom table DriverApprovals_CL and a DCR (kind=Direct) pointing at it. Fill in the CONFIG block at the top. This is the full script — nothing is abbreviated — as run and confirmed working in the lab.
```powershell
# New-DriverApprovalLogSink.ps1
# One-time: creates the DriverApprovals_CL custom table + a Direct-kind DCR.
# Delegated admin auth (Connect-AzAccount) — this is a one-time setup script,
# not the runbook. Requires: Az.Accounts module.

# ========================= CONFIG ==========================
$SubscriptionId         = "<subscription-id>"
$ResourceGroup          = "<rg-for-the-dcr>"            # can differ from the workspace RG
$WorkspaceResourceGroup = "<rg-of-existing-workspace>"
$WorkspaceName          = "<workspace-name>"
$Location               = "<region, matching the workspace>"
$TableName              = "DriverApprovals_CL"           # _CL suffix mandatory
$DcrName                = "dcr-driverapprovals"
# ===========================================================

Import-Module Az.Accounts
$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount | Out-Null; $ctx = Get-AzContext }
Write-Host "Account: $($ctx.Account)  Tenant: $($ctx.Tenant.Id)"

$tr = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
$armToken = if ($tr.Token -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $tr.Token).Password
} else { $tr.Token }
$armHead = @{ Authorization = "Bearer $armToken"; "Content-Type" = "application/json" }

$mgmtBase   = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$wsMgmtBase = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$WorkspaceResourceGroup"
$wsResourceId     = "$wsMgmtBase/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
$wsResourceIdBare = "/subscriptions/$SubscriptionId/resourceGroups/$WorkspaceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
# NOTE: $wsResourceIdBare (no https://management.azure.com/ prefix) is what the DCR needs — see the note below.

# ---- 1. Create the custom table ----
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
                @{ name = "ChangeId";      type = "string" }   # GUID -> string (documented constraint)
                @{ name = "RecordedUtc";   type = "datetime" }
            )
        }
    }
} | ConvertTo-Json -Depth 10

$tableUri = "$wsResourceId/tables/$($TableName)?api-version=2022-10-01"
Invoke-RestMethod -Method PUT -Uri $tableUri -Headers $armHead -Body $tableBody | Out-Null
Write-Host "Table create/update submitted."
Start-Sleep -Seconds 20   # allow provisioning before the DCR references it

# ---- 2. Create the DCR (kind=Direct — no separate DCE resource needed) ----
$streamName = "Custom-$TableName"   # STREAM name (DCR-internal, ingestion URL only) - NOT the table name you query
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
$dcr = Invoke-RestMethod -Method PUT -Uri $dcrUri -Headers $armHead -Body $dcrBody
Write-Host "DCR created."

# ---- 3. Values needed by the runbook and by the RBAC grant below ----
Write-Host "DCR immutable ID:   $($dcr.properties.immutableId)"
Write-Host "Ingestion endpoint: $($dcr.properties.endpoints.logsIngestion)"
Write-Host "Stream name:        $streamName"
Write-Host "DCR resource ID:    $($dcr.id)"     # needed for the role assignment below
```

> [!NOTE]
> The DCR's destinations.logAnalytics.workspaceResourceId must be the BARE resource ID (/subscriptions/.../workspaces/{name}), not the full https://management.azure.com/... URL — the full URL is rejected with LinkedInvalidPropertyId. This is easy to get wrong; New-DriverApprovalLogSink.ps1 builds the bare ID explicitly.

3. Grant the Automation Account's managed identity the 'Monitoring Metrics Publisher' role, scoped to the DCR (not the workspace):
```powershell
az role assignment create --assignee <managed-identity-object-id> `
    --role "Monitoring Metrics Publisher" --scope "<DCR resource ID from the creation script output>"
```

> [!WARNING]
> This is a DCR-scoped role assignment, not a workspace-level one — scope it to the DCR resource ID, not the workspace. Like other data-plane roles, allow several minutes for propagation before the first runbook run.

> [!NOTE]
> If you run New-DriverApprovalLogSink.ps1 locally (delegated admin auth, not the runbook's managed identity) and hit 'AADSTS50076 / RequestDisallowedByAzure ... authenticating through MFA', your cached token satisfied password auth only (amr: pwd). Azure Resource Manager write operations increasingly require a token that actually completed MFA (amr should include mfa, or a strong factor like fido). Register an MFA method, then force a fresh interactive or device-code sign-in — do not reuse a cached session. This does not affect the deployed runbook, which authenticates via managed identity and is not subject to interactive MFA.


### Step 2.2 — The Proven Approval Sequence

The runbook performs this exact sequence per ring. Every call below was lab-verified against the documented /beta endpoints:

| Step | Call |
| --- | --- |
| 1. Find the ring's driver policy | GET /updatePolicies (match by the ring's audience/policy id) |
| 2. List applicable drivers for the audience | GET /deploymentAudiences/{audienceId}/applicableContent |
| 3. Per driver, read recommendation | GET /deploymentAudiences/{audienceId}/applicableContent/{catalogEntryId}/matchedDevices |
| 4. Approve if recommended | POST /updatePolicies/{policyId}/complianceChanges with a scheduled startDateTime |
| 5. (Incident) revoke | PATCH the complianceChange with isRevoked=true |

> [!TIP]
> **Lab-verified:** The recommendation signal is per-device, on the dedicated matchedDevices endpoint (NOT the inline $expand, which returns empty — a known behavior). In the lab, the current driver returned a device with recommendedBy=['Microsoft']; the superseded driver returned recommendedBy=[] for every device. Filter rule: approve a driver if ANY matched device has 'Microsoft' in recommendedBy; otherwise skip (superseded / not recommended).


### Step 2.3 — Approval Runbook (single script)

This is ONE runbook. It defines two helper functions (Graph paging, and the Log Analytics reporting write) at the top, then runs the per-ring approval loop that calls them. Replace the placeholder ring IDs and the three DCR values from Step 2.1a.

> [!NOTE]
> The Logs Ingestion API expects an array of rows (even for one row) and the token resource is https://monitor.azure.com/. A 2xx response means the row was ACCEPTED, not that it is immediately queryable — ingestion latency is typically a few minutes. A reporting failure must not abort the approval loop, so the write is wrapped and only warns on failure.

The $rings array below has three example entries (Test/Pilot/Broad). Replace this with one entry per ring your Autopatch group actually has — see the ring-count note in Part 1 if you haven't already counted them; it is common to have more than three. Before running this script, every {ring}-policy-id / {ring}-audience-id pair and the three Log Analytics values must be filled in. Where each comes from:

| Placeholder | How to obtain it |
| --- | --- |
| `<test-policy-id>`, `<pilot-policy-id>`, `<broad-policy-id>` | GET /beta/admin/windows/updates/updatePolicies (Appendix A). Each Autopatch-created driver policy has an id and an audience.id, but no friendly ring name in the response — match each policy to its ring either by opening the ring's driver policy in the Intune portal and reading the policy id from its properties/URL, or by querying each returned audience's /members and matching against known ring devices (see Appendix A for the exact calls). |
| `<test-audience-id>`, `<pilot-audience-id>`, `<broad-audience-id>` | The audience.id returned alongside each policy in the same GET /updatePolicies call above — each policy object embeds its audience id directly, so this is read from the same response as the policy id, not a separate lookup. |
| `<dcr-logs-ingestion-endpoint>` | Printed by New-DriverApprovalLogSink.ps1 (Step 2.1a) as 'Ingestion endpoint'. |
| `<dcr-immutable-id>` | Printed by the same script as 'DCR immutable ID'. |
| Custom-DriverApprovals_CL (stream name) | NOT the same as the table name, despite looking similar — this trips people up. The TABLE you query in KQL/the workbook is DriverApprovals_CL. The STREAM is a separate DCR-internal identifier, always Custom-{TableName} by Microsoft's naming convention, used only in the ingestion URL and never in a KQL query. If your table is named DriverApprovals_CL, the stream name is Custom-DriverApprovals_CL — both are correct simultaneously, for different purposes. |

> [!WARNING]
> Identifying which policy/audience pair belongs to which ring is the one manual step in this whole setup — the API response has no ring-name field. Get it wrong (e.g. swap Test and Broad) and drivers would deploy to the wrong population on the wrong date. Double-check the mapping against the Intune portal before the first production run.

```powershell
# ============================================================================
# Driver Update Tuesday - Autopatch approval runbook (runs on Patch Tuesday)
# ONE runbook: helpers first, then the main loop at the bottom.
# Graph calls proven against /beta deployment-service endpoints in an Autopatch lab.
# Reporting via the current Log Analytics Logs Ingestion API (DCR, kind=Direct).
# ============================================================================

# Ring -> Autopatch driver policy id + its audience id (resolve once, store as variables)
$rings = @(
    @{ Ring='Test';  PolicyId='<test-policy-id>';  AudienceId='<test-audience-id>';  OffsetDays=0  },
    @{ Ring='Pilot'; PolicyId='<pilot-policy-id>'; AudienceId='<pilot-audience-id>'; OffsetDays=7  },
    @{ Ring='Broad'; PolicyId='<broad-policy-id>'; AudienceId='<broad-audience-id>'; OffsetDays=14 }
)
$MaintenanceHour = 22

# Log Analytics DCR reporting sink (values from Step 2.1a)
$LogIngestionEndpoint = "<dcr-logs-ingestion-endpoint>"
$LogDcrImmutableId    = "<dcr-immutable-id>"
$LogStreamName        = "Custom-DriverApprovals_CL"

Connect-AzAccount -Identity | Out-Null
$gToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
if ($gToken -is [System.Security.SecureString]) { $gToken = [System.Net.NetworkCredential]::new('', $gToken).Password }
$gHead  = @{ Authorization="Bearer $gToken"; "Content-Type"="application/json" }
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
    $mToken = (Get-AzAccessToken -ResourceUrl "https://monitor.azure.com/").Token
    if ($mToken -is [System.Security.SecureString]) { $mToken = [System.Net.NetworkCredential]::new('', $mToken).Password }
    $mHead = @{ Authorization = "Bearer $mToken"; "Content-Type" = "application/json" }

    # Logs Ingestion API expects an ARRAY of rows, even for a single row.
    $row = @(
        @{
            TimeGenerated = (Get-Date).ToUniversalTime().ToString("o")
            Ring=$Ring; PolicyId=$PolicyId; CatalogId=$CatalogId
            DriverName=$DriverName; Version=$Version; Action=$Action; StartDateTime=$StartDateTime
            ChangeId=$ChangeId   # GUID typed as string on the DCR stream
            RecordedUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
    ) | ConvertTo-Json -AsArray -Depth 5

    $uri = "$LogIngestionEndpoint/dataCollectionRules/$LogDcrImmutableId/streams/$($LogStreamName)?api-version=2023-01-01"
    try {
        Invoke-RestMethod -Method POST -Uri $uri -Headers $mHead -Body $row | Out-Null
        # 2xx = accepted; ingestion latency of a few minutes before it's queryable. Not an error.
    } catch {
        # A reporting failure must not abort the approval loop - log and continue.
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

        # Skip if already approved and not revoked (portal is NOT the source of truth - see Part 6)
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
```

> [!WARNING]
> The runbook only approves drivers not already approved (unrevoked). A driver an admin has paused/declined must not be re-approved. Because the Autopatch portal does NOT reflect API approvals (Part 6), the runbook's own complianceChanges list is the source of truth for 'already approved', not the portal.

> [!NOTE]
> A workbook or dashboard over DriverApprovals_CL is a natural next step once rows are flowing — this guide stops at confirmed ingestion; building the workbook is an operations-plan item.


### Step 2.4 — Trigger and Alerting

1. Create a Logic App with a monthly recurrence (weekDays Tuesday, monthlyOccurrences second) that invokes the runbook.
2. Create an Azure Monitor alert on the Automation job status (Failed/Suspended) to operations — a silent failure means no drivers ship that month.
3. Emit a success summary (per-ring approval counts) for the operations record.
> [!WARNING]
> Every read, approve, verify, and revoke call in this guide was validated using DELEGATED admin authentication (Connect-MgGraph / Connect-AzAccount as a signed-in user), which is how local testing in VS Code or Graph Explorer works. The runbook's MANAGED IDENTITY path — Connect-AzAccount -Identity inside the actual Automation Account — has NOT been separately validated end to end. Delegated and managed-identity auth are different code paths in Azure AD; a working local test does not guarantee the managed identity run succeeds. Before relying on this in production, run the runbook once in Azure and confirm: (1) the Graph calls succeed with the MI's granted permissions, (2) the Log Analytics ingestion succeeds with the MI's DCR role. If either fails, the MI's app role / RBAC assignment is the first thing to check — not the script logic, which is already proven.


---


## Part 3: Intune Remediation (client-side installation gate)

Independent of how drivers are delivered. Pins installation to the maintenance hour, defers around active users up to a calendar-day deadline, handles restart.


### Step 3.1 — Detection Script (detect-pending-drivers.ps1)

```powershell
# Exit 1 = pending drivers found (triggers remediation); Exit 0 = compliant
try {
    $reg = 'HKLM:\SOFTWARE\DriverUpdateTuesday'
    if ((Get-ItemProperty $reg -Name OptOut -ErrorAction SilentlyContinue).OptOut -eq 1) { exit 0 }
    $s = New-Object -ComObject Microsoft.Update.Session
    $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    if ($r.Updates.Count -gt 0) { Write-Output "Pending: $($r.Updates.Count)"; exit 1 }
    exit 0
} catch { Write-Output "Detection error: $_"; exit 0 }
```


### Step 3.2 — Remediation Script (install-pending-drivers.ps1)

SYSTEM context, 64-bit. Locale-independent session detection, calendar-day install deadline, localized notification, restart handling.

```powershell
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
```


### Step 3.3 — Deploy the Remediation

| Setting | Value |
| --- | --- |
| Run as | SYSTEM (logged-on credentials: No) |
| 64-bit PowerShell | Yes |
| Schedule | Daily at the maintenance hour (example 22:00) — device LOCAL time (do NOT select UTC for a multi-time-zone fleet) |
| Assignment | In-scope devices, EXCLUDING the 24/7 / kiosk / shift exclusion group |

> [!WARNING]
> Excluded 24/7 devices receive drivers on the ring schedule but have no controlled install window — define a separate maintenance procedure (opt-out flag + coordinated window) before broad rollout.


---


## Part 4: Installation Timing — Detailed Walkthrough

Two independent gates control when a driver actually installs, as introduced in the timing-mechanisms note earlier: the Autopatch approval controls when a driver is OFFERED (server side), and the Remediation controls when it is actually INSTALLED (client side, at the maintenance hour). This section walks through what happens on the client side in each realistic scenario, because the two questions that come up most — a device being off, and a user being logged in — have different answers than people expect.


### Scenario 1 — Normal case: device on, no one logged in, at 22:00

1. Detection script runs (Intune Remediation schedule, daily at 22:00 device local time). It searches for IsInstalled=0 Type=Driver updates. One is pending (the Autopatch approval's offer window has opened, so Windows Update Agent has it staged). Detection exits 1, which triggers Remediation.
2. Remediation checks for an interactive session via explorer.exe. None found.
3. Remediation checks power state (skips if on battery).
4. Remediation sends a brief console notification (msg console, 30-second timeout — harmless if no one is there to see it), then downloads and installs via the WUA COM API. This is the moment any screen flash / audio / network interruption happens.
5. If the driver requires a restart, Remediation re-checks for a session one more time (in case someone logged in during install), finds none, and restarts immediately with a 60-second countdown.
> [!NOTE]
> This is the intended path and the only one where nothing is deferred. Everything below describes what happens when reality doesn't cooperate.


### Scenario 2 — Device is OFF (or asleep) at 22:00

This is the one true gap in the design, and it is worth being explicit about it rather than implying the maintenance hour is a hard guarantee.

1. At 22:00, nothing happens — there is no device to run the Remediation on. Detection and Remediation are Intune Management Extension tasks; they simply don't execute on a powered-off machine.
2. The driver remains offered (the approval already opened the offer window) and staged by Windows Update Agent, waiting.
3. The device is switched on the next morning, say 08:00, during working hours. At this point WHO installs it is a race between two things: Windows Update Agent's own scan/install cycle (roughly every 22 hours, NOT synchronized to the maintenance hour) can pick up the already-offered driver and install it autonomously — with no session check, no notification, no timing control — because nothing in this design suppresses WUA's normal behaviour between maintenance-hour runs. The NEXT scheduled Remediation run, at 22:00 that same evening, would also find it pending and install it under full control — but only if the device is still on that evening.
4. In practice this means: an off-overnight device has a real chance of installing the driver at an uncontrolled moment during the day, before the Remediation ever gets a turn. This is NOT prevented by this design — it is a documented, accepted residual risk (see Part 7).
> [!WARNING]
> Active Hours does not close this gap. Active Hours only blocks the automatic RESTART, not the driver INSTALLATION — and installation is where the disruptive screen flash / audio / network interruption actually happens. A device that autonomously installs a driver at 09:00 the next morning will still show the disruptive behaviour at 09:00; Active Hours only stops it from also forcing a reboot at that moment (the reboot, if required, waits for an allowed window).

Mitigations, none of them complete: Wake-on-LAN to bring devices online for the maintenance window (needs network support, rarely reaches remote/home devices); accepting the residual risk as a known trade-off and documenting it to stakeholders (the approach this guide takes); or, for environments where this is unacceptable, excluding drivers from WU entirely and pushing them as required Win32 apps with a controlled deadline — a fundamentally different, heavier architecture not covered by this guide.


### Scenario 3 — User is logged in at 22:00 (within the deadline)

1. Detection finds the pending driver, triggers Remediation as usual.
2. Remediation's explorer.exe check finds an active session.
3. Remediation reads (or, on the first run for this driver, stamps) an InstallDeadline timestamp in the registry — now plus installDeadlineDays (default 5 calendar days, not working days; see the calendar-day-vs-working-day discussion earlier in this guide).
4. Because today's date is before that deadline, Remediation exits cleanly WITHOUT installing and WITHOUT notifying the user — a session being present on one particular evening is treated as entirely normal, not something to alert anyone about.
5. This repeats every night the user is logged in at 22:00, up to the deadline. No install, no disruption, no notification — completely invisible to the user.

### Scenario 4 — User is logged in at 22:00, PAST the deadline

This is the safeguard that stops an always-on device from deferring forever.

1. Same as Scenario 3 up through the deadline check, except now today's date is on or after the stamped deadline.
2. Remediation sets $forced = $true and proceeds anyway, despite the active session.
3. Before installing, it sends a longer, explicit notice (120-second console message) and sleeps 120 seconds to give the user genuine advance warning before the disruptive install begins — a materially different experience from the silent Scenario 1 install, deliberately so, since this time a real person is being interrupted.
4. Install proceeds. If a restart is required, Remediation checks ONE MORE TIME whether a session is present (the user may have logged off during the 120-second warning, or may still be there).
| If, at restart time... | What happens |
| --- | --- |
| No session present (user logged off during/after the warning) | Restarts immediately with the normal 60-second countdown, same as Scenario 1. |
| Session still present | Restart is NEVER forced. The user gets a notification asking them to restart at their convenience. Active Hours continues to prevent Windows from forcing a restart automatically during business hours regardless. |

> [!WARNING]
> The install itself is still forced past the deadline even with a user present — only the RESTART is never forced. This is a deliberate asymmetry: the disruptive install (screen flash etc.) is brief and, with 120 seconds of warning, tolerable; an unannounced forced reboot could cost unsaved work, which is treated as the worse outcome.


### Summary table

| Condition at 22:00 | Outcome |
| --- | --- |
| Device off | Nothing happens this cycle. Real risk of an uncontrolled WUA install before the device is next caught by Remediation — see Scenario 2. |
| Device on, no session, within deadline | Installs immediately and silently (Scenario 1). |
| Device on, session present, within deadline | Defers silently, no notification, tried again tomorrow (Scenario 3). |
| Device on, session present, past deadline | Installs anyway, with a 120-second advance warning; restart only proceeds automatically if the session has since ended (Scenario 4). |


---


## Part 5: Supporting Update Ring Setting

| Setting | Value |
| --- | --- |
| Active Hours | Business hours or auto-detect — restart backstop |

> [!WARNING]
> 'Do not include drivers with Windows Update' must NOT be enabled for in-scope devices. Microsoft documents that a device with this policy, enrolled and with content approved, WILL display the driver but WON'T install it (reporting shows 'pending'). Delivery control comes from the Autopatch driver policy, not this setting.


---


## Part 6: The Portal Is Not a Mirror — Operational Constraint

> [!TIP]
> **Lab-verified:** Proven in lab: a driver approved via the API — whether scheduled for a future date OR approved immediately with no schedule — continues to show 'Needs review' in the Autopatch portal driver tab. The deployment service, however, created a real deployment in the 'scheduled' state. Conclusion: the Autopatch portal does NOT reflect approvals made through the API, regardless of timing. It reflects only approvals made in the portal itself.

Consequences for operations, which this guide's design follows:

- Source of truth for what is approved = the deployment-service API (complianceChanges / deployments) and the runbook's Log Analytics log (DriverApprovals_CL) — NOT the portal driver tab.
- Install outcomes (did it reach devices) = native Windows Update for Business Reports.
- Incident lever = API PATCH isRevoked=true (lab-proven: the deployment moves to 'archived'). Do NOT rely on the portal pause for runbook-created approvals.
> [!NOTE]
> Because the portal cannot show what the runbook does, do not instruct admins to manage these approvals in the portal. DriverApprovals_CL in Log Analytics + WUfB Reports + the verification queries in the Appendix are the admin's view.


---


## Part 7: Known Limitations and Edge Cases

| Scenario | Behavior | Mitigation |
| --- | --- | --- |
| Device offline at maintenance hour | Installs at next run; in the gap WU may install autonomously | Active Hours restart backstop; accepted residual risk |
| Never-idle device | Defers to the calendar-day deadline, then installs with 2-min notice | installDeadlineDays = environment parameter |
| User logs in mid-install | Restart never forced with a user present; notified instead | Built into script; Active Hours backstop |
| Non-English OS | Locale-independent session detection; English notification fallback | Extend message table with fleet languages |
| matchedDevices inline $expand empty | Known behavior — inline expand returns [] | Use the dedicated matchedDevices endpoint (Step 2.2/2.3) |
| Approval-mode toggle | Switching Auto<->Manual wipes approvals/pauses/declines | Set Manual at creation; never toggle |
| Bad driver auto-approved | Approved without pre-review each cycle | Ring stagger + API revoke before later rings |
| Beta Graph API changes | Runbook may break on schema change | Monthly canary read; Azure Monitor alert |
| Portal shows 'Needs review' for approved drivers | Portal does not mirror API approvals | Use API + Log Analytics (DriverApprovals_CL) + WUfB Reports (Part 6) |
| Managed identity path unvalidated | All lab testing used delegated admin auth, not the Automation Account's MI | Run the runbook once in Azure before production; check MI role assignments first if it fails (Step 2.4) |


---


## Appendix A — Graph Explorer Verification Sequence (read-only)

Run these in Graph Explorer (sign in as an admin; consent WindowsUpdates.ReadWrite.All + Device.Read.All) to reproduce the lab validation in any tenant. All are read-only except where noted.

| Purpose | Request |
| --- | --- |
| List driver policies | GET /beta/admin/windows/updates/updatePolicies |
| List audience members (expect updatableAssetGroup refs) | GET /beta/admin/windows/updates/deploymentAudiences/{audienceId}/members |
| List applicable driver content | GET /beta/admin/windows/updates/deploymentAudiences/{audienceId}/applicableContent |
| Per-driver recommendation (the filter signal) | GET /beta/admin/windows/updates/deploymentAudiences/{audienceId}/applicableContent/{catalogEntryId}/matchedDevices |
| List approvals on a policy | GET /beta/admin/windows/updates/updatePolicies/{policyId}/complianceChanges?$orderby=createdDateTime desc |
| (Write) approve with schedule | POST /beta/admin/windows/updates/updatePolicies/{policyId}/complianceChanges |
| Confirm a scheduled deployment was created | GET .../complianceChanges/{id}/microsoft.graph.windowsUpdates.contentApproval?$expand=deployments |
| (Write) revoke | PATCH .../complianceChanges/{id} with { isRevoked: true } |

> [!NOTE]
> In the lab, the write tests used a harmless audio driver with a far-future startDateTime, verified the deployment reached 'scheduled', then revoked (deployment moved to 'archived'). Use a future date and revoke promptly so nothing deploys during verification.


---


## Appendix B — Documentation References

- Driver/firmware programmatic controls: learn.microsoft.com/windows/deployment/windows-autopatch/manage/windows-autopatch-driver-and-firmware-update-programmatic-controls
- Deploy a driver update (Graph): learn.microsoft.com/graph/windowsupdates-manage-driver-update
- applicableContentDeviceMatch (recommendedBy): learn.microsoft.com/graph/api/resources/windowsupdates-applicablecontentdevicematch
- Logs Ingestion API overview: learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
- Migrate from the HTTP Data Collector API (deprecated) to Logs Ingestion: learn.microsoft.com/azure/azure-monitor/logs/custom-logs-migrate
- Tutorial: Logs Ingestion API (Resource Manager templates): learn.microsoft.com/azure/azure-monitor/logs/tutorial-logs-ingestion-api

---


## Appendix C — Verifying Network Reachability Before Choosing a Reporting Sink

Both reporting sinks considered for this solution (Azure Storage Table, and the Log Analytics DCR used here) are reachable over the public internet by default. Either can be blocked by tenant-level network hardening — most commonly an Azure Policy with a 'modify' or 'deny' effect forcing public network access off for a resource type. This blocks both a local test machine AND the Azure Automation shared sandbox equally, since both are external to the resource's network from the platform's point of view.

Before committing to a reporting sink in a new environment, verify reachability rather than assuming it:

- Check for relevant policy assignments: Get-AzPolicyState filtered to the target resource, looking for PublicNetwork / DisableLocalAuth policies with a modify or deny effect.
- If a sink's public access is confirmed blocked by policy, do not attempt to override it — this is very likely an intentional guardrail. Either use a private endpoint + hybrid runbook worker (real infrastructure, not a quick fix), or choose a different sink that the tenant permits.
- Run a single, reversible write-and-verify test (as demonstrated in this guide's lab validation) BEFORE wiring the sink into the production runbook.
> [!NOTE]
> This solution originally used an Azure Storage Table for reporting. It was replaced with Log Analytics after a tenant policy silently reverted every attempt to enable public network access on the storage account. Log Analytics ingestion was confirmed reachable in the same tenant. This is not a guarantee that Log Analytics will be reachable in every environment — verify it in yours using the approach above before relying on it.
