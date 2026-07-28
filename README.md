# Driver Update Tuesday

Schedule Windows driver updates to a Patch Tuesday cadence, fully automated, with installation pinned outside working hours — via Windows Autopatch-managed driver policies and Intune Remediations.

> [!WARNING]
> This is a **reference architecture**, not a packaged product. Several key API calls used here are on Microsoft's `/beta` Graph endpoint and are demonstrated working against **Autopatch-group-created** driver policies in one lab tenant — a pattern Microsoft documents against Graph-created policies, not explicitly against Autopatch-group ones. Read [Architecture § 5](docs/architecture.md#5-key-constraints-and-limitations) and confirm supportability with Microsoft (FastTrack/support) before relying on this in production. Test everything in your own lab first — see [docs/setup-guide.md](docs/setup-guide.md).

## The problem this solves

Driver updates (display, network, audio) are disruptive to install — screen flashes, dropped connections, audio glitches — regardless of whether someone is actively working. Unlike quality updates, **Windows Update for Business has no native way to schedule driver installation to a specific day or time**, and Active Hours only protects the *restart*, not the *install* — which is where the disruption actually happens.

This repo delivers drivers on a Patch Tuesday cadence, staged across deployment rings, with installation pinned to a maintenance hour outside working hours — fully automated, with no per-driver human approval required.

## How it works

Two independent control layers, because neither alone is sufficient:

| Layer | Controls | Component |
|---|---|---|
| **Server-side** | *When a driver is offered* | Windows Autopatch driver policies (manual mode) + an Azure Automation runbook that approves recommended drivers per ring with staggered dates (T / T+7 / T+14) |
| **Client-side** | *When it actually installs* | An Intune Remediation running daily at a maintenance hour, session-aware, that performs the install and handles restart |

The approval only controls when a driver becomes *available*; Windows Update Agent would otherwise install it at an arbitrary point in its own scan cycle — including mid-morning. The Remediation is what pins the disruptive moment to a chosen, off-hours time.

See [**docs/architecture.md**](docs/architecture.md) for the full design and rationale, including why earlier design alternatives (standalone Intune driver profiles, policy-level auto-approval, Azure Storage Table reporting) were tried and superseded.

## Repository contents

```
docs/
  setup-guide.md          Step-by-step build guide (start here to implement)
  architecture.md         Design, rationale, constraints, and licensing
  operations-plan.md      Monthly operating calendar, RACI, incident response, KPIs
  word/                   The same three documents as polished .docx files
    reference-v2-standalone/   An earlier, superseded design (standalone Intune
                                driver profiles instead of Autopatch-managed).
                                Kept for environments that cannot use Autopatch.

scripts/
  DriverUpdateTuesday-ApprovalRunbook.ps1   The production Azure Automation runbook
  New-DriverApprovalLogSink.ps1             One-time: creates the Log Analytics table + DCR
  Test-DriverApproval-DryRun-MgGraph.ps1    Local test: read-only, exercises the filter logic
  Test-DriverApproval-LiveSingle.ps1        Local test: approve → verify → revoke, one driver
  Test-LogAnalyticsIngestion.ps1            Local test: confirms the reporting sink works
  superseded-or-abandoned/                  Kept for reference; do not use — see the file headers
```

## Quick start

1. Read [**docs/setup-guide.md**](docs/setup-guide.md) in full before touching a tenant — it front-loads the things most likely to trip you up (permission scopes, a ring-count assumption to verify, timing behavior when a device is off or a user is logged in).
2. Test locally first, against a lab tenant, using the scripts in `scripts/` — `Test-DriverApproval-DryRun-MgGraph.ps1` makes **zero changes** and is the safest starting point.
3. Once the dry run looks right, follow the setup guide's Parts 1–4 to configure the Autopatch group, the reporting sink, and the runbook, and Part 3/5 for the client-side Remediation.
4. Deploy `DriverUpdateTuesday-ApprovalRunbook.ps1` to Azure Automation with a system-assigned managed identity — **and validate that managed-identity path once in Azure**; every test script here uses delegated admin auth, which is not the same code path (see the warning in the setup guide's Step 2.4).

## What's proven vs. what to verify yourself

This project was built with a "no assumptions, verify against documentation and in a real lab" discipline throughout. The setup guide marks lab-verified findings explicitly. A few load-bearing ones, condensed:

- ✅ Autopatch-created driver policies are readable and **writable** (approve, revoke) via the documented `/beta` deployment-service Graph API, even though Microsoft's examples show this against Graph-created policies rather than Autopatch-owned ones.
- ✅ The recommendation signal used to filter "approve this driver" is **per-device**, on a dedicated `matchedDevices` sub-endpoint — the inline `$expand=matchedDevices` on the collection returns empty (a known behavior), which cost real debugging time.
- ⚠️ **The Autopatch portal does not reflect API-made approvals** — a driver approved via the runbook still shows "Needs review" in the portal, indefinitely. This is not a bug or lag; it was confirmed with both scheduled and immediate approvals. The API + the Log Analytics sink are the actual source of truth; do not point admins at the portal for this.
- ⚠️ **The managed-identity ingestion/approval path was never separately tested.** All lab validation used delegated admin authentication. Test the real managed identity once in Azure before trusting it in production.
- ⚠️ Storage account network hardening (a common tenant policy) can silently block a Storage Table reporting sink for both local testing and the Azure Automation shared sandbox — this is why the design uses Log Analytics instead. If you adapt this for your own tenant, verify reachability of whatever sink you choose before committing to it (see Architecture § 5 and the setup guide's Appendix C).

## Parameters you must set for your environment

Nothing here is a fixed constant — these are worked examples to replace:

- **Maintenance hour** (example: 22:00 device local time)
- **Ring count and stagger** (example: Test/Pilot/Broad at T/T+7/T+14 — your Autopatch group may have more rings than three; see the setup guide's ring-count note)
- **Install deadline** for never-idle devices (example: 5 calendar days)
- **Notification languages** (script ships with English only)
- **24/7 / kiosk device exclusions** and their alternative maintenance procedure

## Licensing requirements

Windows Autopatch driver management (Windows/Microsoft 365 E3/E5/A3/A5 or Business Premium) and Intune Remediations (Microsoft 365 E3/E5, Intune Plan 2, or Intune Suite — **not** included in Business Premium). Full detail in [docs/architecture.md](docs/architecture.md#6-licensing-requirements).

## Contributing

Issues and PRs welcome — especially reports of what happens when you run this against a real Autopatch group with more than three rings, or against a tenant with different network-hardening policies than the one this was built against. If you find the managed-identity path behaves differently than the delegated-auth testing here suggests, that's exactly the kind of thing worth opening an issue for.

## License

[MIT](LICENSE) — see the license file for full terms. This is provided as-is, reference material; you are responsible for validating it in your own environment before production use.
