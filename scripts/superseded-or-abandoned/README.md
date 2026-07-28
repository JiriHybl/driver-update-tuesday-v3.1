# Superseded / Abandoned Scripts

These are kept for historical reference only. **Do not use them** — each was
replaced during development for a documented reason.

## `Test-DriverApproval-DryRun.ps1`

Early version that authenticated to Microsoft Graph using `Get-AzAccessToken`
(the Az PowerShell module's token). This fails with `403 Forbidden` /
`InvalidAuthenticationToken` because the Az client application's consented
scopes do not include `WindowsUpdates.ReadWrite.All`, even when the signed-in
account has that permission via other tools (e.g. Graph Explorer).

**Use instead:** `Test-DriverApproval-DryRun-MgGraph.ps1`, which authenticates
via `Connect-MgGraph -Scopes 'WindowsUpdates.ReadWrite.All','Device.Read.All'`
and requests the correct scopes explicitly.

## `Test-StorageTableWrite.ps1`

The original reporting sink design used an Azure Storage Table. It was
abandoned after discovering that a common tenant governance policy (a
`modify`-effect Azure Policy forcing `PublicNetworkAccess=Disabled` on all
storage accounts) silently reverts any attempt to open the account to public
traffic. This blocks **both** local testing and the Azure Automation shared
sandbox equally, since both are external to the storage account's network
from the platform's point of view — there is no quick fix short of a private
endpoint plus a hybrid runbook worker.

**Use instead:** the Log Analytics-based reporting sink (`New-DriverApprovalLogSink.ps1`
+ `Test-LogAnalyticsIngestion.ps1`), which was confirmed reachable in the same
tenant. See `docs/setup-guide.md`, Appendix C, for how to verify network
reachability of a reporting sink in your own environment before committing to
either approach — the same class of policy could equally affect Log
Analytics in a different tenant.
