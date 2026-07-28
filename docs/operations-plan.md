# Driver Update Tuesday — Operations Plan

**Autopatch-Managed Design** · Reference operations plan for scheduled Windows driver updates via Microsoft Intune

> [!TIP]
> This defines the recurring operational activities once the solution (see [setup guide](setup-guide.md)) is live.

---

## 1. Purpose


This plan defines the recurring operational activities, roles, monitoring, and incident procedures required to run the Driver Update Tuesday solution in production. It complements the Architecture and Setup documents and is written as a template — role names, thresholds, and cadences should be adapted per environment. Automation performs the monthly approvals; this plan defines what humans do around it: review, monitor, respond, and improve.


## 2. Monthly Operations Calendar


All activities are anchored to Patch Tuesday (T) of each month.


| When | Activity | Owner |
| --- | --- | --- |
| T−2 to T | Review new drivers in Needs review state across the three ring profiles in the Intune portal. Cross-check OEM release notes and known-issue lists for each fleet vendor. Decline or pause any driver with known problems — the automation will then skip it. | Driver Update Owner |
| T (Patch Tuesday) | Runbook runs automatically: approves Recommended drivers, availability T (Test ring), T+7 (Pilot), T+14 (Broad). Verify the success notification arrived and approval counts are plausible (a zero-approval month for all rings is suspicious and must be investigated). | Driver Update Owner |
| T+1 to T+6 | Monitor Test ring: install success rate, remediation results, incident tickets mentioning display/audio/network symptoms on Test devices. Decision gate: any driver causing issues is paused in ALL THREE profiles before T+7. | Driver Update Owner + Service Desk |
| T+7 to T+13 | Monitor Pilot ring (same criteria, larger population). Decision gate before T+14: pause problem drivers in the Broad profile. | Driver Update Owner |
| T+14 onward | Broad ring deployment. Monitor fleet-level dashboard for success rate and regional anomalies. | Operations |
| T+21 | Monthly review: KPIs (section 6), stuck-device report (deferral deadline exceeded, install failures), canary API validation result, lessons learned. Output: short written status. | Driver Update Owner |


> [!NOTE]
> The T+7 and T+14 gates are passive by default — deployment proceeds automatically unless someone pauses a driver. This is a deliberate trade-off (no bottleneck on manual sign-off), which makes the monitoring duties in this calendar mandatory rather than optional.


## 3. Roles and Responsibilities


| Role | Responsibilities |
| --- | --- |
| Driver Update Owner (named person + deputy) | Monthly review and gates, pause/decline decisions, monthly report. Primary contact for driver-related escalations. |
| Operations / Monitoring | Watches runbook alerts and dashboard; first response to automation failures; maintains the exclusion (24/7 device) list and augmentation groups. |
| Service Desk | Tags incoming tickets with a driver-update category during ring windows; escalation path to Driver Update Owner defined and communicated. |
| Security / RBAC Owner | Annual review of the Managed Identity permission (DeviceManagementConfiguration.ReadWrite.All) and runbook code changes. |
| Engineering (this solution) | Script and runbook maintenance, beta API change response, quarterly hardware-coverage audit of Test/Pilot rings. |


## 4. Monitoring and Alerting


### 4.1 Automated Alerts


| Alert | Source | Response |
| --- | --- | --- |
| Runbook job Failed / Suspended | Azure Monitor on Automation job status | Same-day investigation; if not fixable before end of Patch Tuesday, perform manual approval via the Intune portal (documented fallback — approvals in the portal are functionally identical to runbook approvals) |
| Runbook success summary absent | Logic App success notification missing | Verify Logic App trigger fired; check Azure service health |
| Install failure rate above threshold per driver | WUfB Reports / Log Analytics scheduled query | Driver Update Owner assesses; candidate for pause |


### 4.2 Dashboard (native reporting)


Because drivers are Autopatch-managed, driver reporting is native — no custom workbook required:

- Windows Update for Business Reports driver tab: update states, driver classes, per-policy deployment status, per-device compliance and alerts
- Intune Remediation device-status report: deferral counts and install/restart results (the client-side health WUfB data does not cover)
- Optional: UCClient / UCClientUpdateStatus Log Analytics tables for custom cross-region or trend views

### 4.3 Monthly Canary Validation (beta API)


Because all automation endpoints are Graph beta, a lightweight scheduled validation runs a read-only version of the runbook logic (list profiles, list inventories) weekly and alerts on schema errors — catching Microsoft-side API changes before Patch Tuesday rather than during it.


## 5. Incident Response and Rollback


### 5.1 Defective Driver Runbook

1. Confirm correlation: tickets/symptoms cluster on a hardware model and time-correlate with a ring availability date. The dashboard's per-driver failure view supports this.
2. Contain: in the Intune portal (Driver updates > Manage drivers for Autopatch groups), pause the driver for the not-yet-deployed rings using native per-driver pause. Pausing prevents further offers; it does not uninstall.
3. Assess spread: per-policy report shows how many devices already installed.
4. Remediate affected devices. Honest limits apply: Windows offers no clean fleet-wide driver rollback. Options, in order of preference: (a) OEM releases a fixed version — approve it as an expedited exception; (b) targeted rollback script deploying the previous driver package via pnputil to affected models (requires the previous package, per-model effort); (c) manual Device Manager roll back for small populations. Choose based on blast radius.
5. Communicate: template notification to affected users/regions via the agreed channel; entry in the monthly report.
6. Post-incident: record the driver version in a local blocklist note reviewed at T−2 in following months (a paused driver stays paused, but OEMs sometimes re-release under new versions).

### 5.2 Automation Failure on Patch Tuesday


Fallback is manual: approve drivers via the Intune portal (Manage drivers for Autopatch groups) per ring with the same staggered deployment dates. This takes minutes and is functionally identical to runbook approvals. The alerting in 4.1 exists to make this fallback invocable the same day.


## 6. KPIs


| KPI | Target (initial proposal) | Source |
| --- | --- | --- |
| Recommended drivers installed within 21 days of Broad availability | >= 90% of applicable devices | WUfB Reports |
| Driver-attributed disruption tickets during business hours | Trending to near zero after month 3 | Service Desk category |
| Devices past deferral deadline without installation | < 2% of fleet | Remediation output |
| Patch Tuesday automation success | 12/12 months (incl. manual fallback within same day) | Azure Monitor |
| Test+Pilot hardware model coverage | 100% of models with > 100 devices | Quarterly audit |


> [!NOTE]
> Targets are starting proposals to validate and adjust during the first quarter of operation in a given environment.


## 7. Device Lifecycle

- Onboarding: new devices inherit driver management automatically through Autopatch ring membership — no per-device action. Verify during onboarding QA that the device registers to exactly one Autopatch ring.
- Offboarding: retirement removes the device from Intune and thus from the profiles; no separate step.
- Hardware refresh / new models: adding a new model to the fleet triggers an out-of-cycle augmentation-group review so the model is represented in Test/Pilot before its population grows.
- 24/7 exclusion list: owned by Operations; reviewed quarterly; every entry must name its alternative maintenance procedure.

## 8. Environment-Specific Parameters


| Parameter | Example / Proposal | Notes |
| --- | --- | --- |
| Maintenance hour | 22:00 | Approvals + client install window |
| Maximum deferral count (never-idle deadline) | 5 working days | Set per policy |
| Notification languages | English + languages used in the fleet | Extend script message table |
| 24/7 / kiosk / shift device inventory + their maintenance window | Compiled by Operations | Excluded from remediation |
| Ring percentages and stagger | 1% / 9% / 90% at T / T+7 / T+14 | Tune to fleet size |
| KPI targets | Section 6 proposals | Ratify per environment |
| Hardware-coverage audit cadence | Quarterly | Set per environment |
