# Driver Update Tuesday — Solution Architecture

**Autopatch-Managed Design** · Reference architecture for scheduled Windows driver updates via Microsoft Intune + Windows Autopatch

> [!TIP]
> This is the conceptual overview. For step-by-step build instructions, see the [setup guide](setup-guide.md).

---

## 1. Background and Problem Statement


Windows driver updates — particularly for display adapters, network adapters, and audio devices — are inherently disruptive to install. Driver installation replaces live kernel and user-mode device stack components, causing screen flashes, temporary network disconnects, and audio interruptions, regardless of whether the device is in active use. Because the disruption occurs during the installation phase rather than at restart, the restart-focused controls that make quality updates non-disruptive (Active Hours, scheduled install time) do not address it.


Native Windows Update for Business policy provides no mechanism to schedule the installation of driver updates to a specific day or time. The goal of this reference architecture is to deliver driver updates on a monthly Patch Tuesday cadence, fully automated (no per-driver human approval), and ensure installation occurs outside of working hours. It is written for medium-to-large managed Windows fleets, including globally distributed, multi-time-zone, multi-vendor environments. Values such as ring composition, the maintenance hour, and deferral limits are parameters to be set per environment.


## 2. Technology Overview


### 2.1 Windows Autopatch Driver Update Management


Windows Autopatch is a cloud service that manages Windows update deployment through deployment rings. An Autopatch group is a logical container that groups Entra device groups and the update policies for each ring — including driver update policies. For each content type, including drivers, updates can be set to deploy automatically or require approval, and this choice can be made per deployment ring and per Autopatch group.


In this architecture, driver updates are managed by Autopatch in manual approval mode. Manual mode does not imply a human approves each driver: it means approval is controlled explicitly (by automation, via the Graph API) rather than happening automatically on driver release. Approvals carry a deployment date that controls when the approved driver is made available to devices in the ring. This is the mechanism that delivers the Patch Tuesday cadence.


> [!NOTE]
> Choosing Autopatch-managed driver policies (rather than standalone Intune driver profiles) provides native driver update reporting through Windows Update for Business Reports, native per-driver pause as an incident lever, and deterministic ring assignment — all without a custom device-synchronisation engine.


> [!WARNING]
> Switching a driver policy between Automatic and Manual approval mode regenerates the underlying policies and discards all existing approvals, paused drivers, and declined drivers. The approval mode must be set correctly at creation and not toggled casually in production.


### 2.2 Deterministic Deployment Rings


Autopatch deployment rings can be populated deterministically by assigning your own Entra device groups to each ring, rather than relying on automatic percentage-based distribution. The Test and Last rings support assigned-group distribution only. This allows the Test and Pilot rings to be composed to guarantee hardware model coverage — essential because driver defects are hardware-specific, so a ring is only a valid test if it contains representative devices of each OEM model in the fleet.


A device assigned to an Autopatch ring receives all update workloads that the Autopatch group manages for that ring on that ring's schedule. There is no per-workload ring membership: a device placed in the Test ring for driver hardware coverage also receives quality and feature updates on the Test schedule. This is acceptable for well-chosen representative devices but requires care when the only representative of a rare hardware model is a business-critical device (see section 5).


### 2.3 Approval Automation (Runbook)


An Azure Automation PowerShell Runbook, authenticating with a system-assigned Managed Identity, performs the monthly driver approvals via the Windows Autopatch programmatic controls in the Microsoft Graph API. On Patch Tuesday it approves all pending recommended drivers per ring with the ring-appropriate deployment date. An Azure Logic App provides the second-Tuesday recurrence trigger; Azure Monitor alerts operations if a run fails. The runbook is what makes manual approval mode fully automated — it is a required component of this design, not optional.


Risk from indiscriminate automated approval (a defective driver being approved before human review) is mitigated by the ring stagger: a bad driver surfacing in the Test or Pilot ring is paused in the remaining rings — using the native driver pause capability — before it reaches the broad population.


### 2.4 Intune Remediations (client-side installation gate)


Autopatch approval controls when a driver is offered to a device; it does not control when the Windows Update Agent installs it. After the deployment date passes, an unmanaged device installs at an arbitrary point in its scan cycle — potentially during working hours. Intune Remediations provide the client-side installation gate: paired detection and remediation scripts run in SYSTEM context at the maintenance hour in device local time, install pending drivers via the Windows Update Agent COM API only when no interactive session is present (with a deferral deadline), notify the user, and handle any required restart. This is the only component that pins installation to a defined time.


> [!NOTE]
> Intune Remediations require Microsoft 365 E3/E5, Intune Plan 2, or the Microsoft Intune Suite. Not available with Microsoft 365 Business Premium.


## 3. Solution Architecture


### 3.1 Ring Structure


Because automated approval deploys drivers without per-driver human review, the ring stagger is the primary risk control. Three rings are used; composition and stagger are parameters to tune to fleet size and risk tolerance:


| Ring | Composition and schedule |
| --- | --- |
| Test | Assigned Entra group composed for hardware model coverage across all fleet OEM vendors, including dock and discrete-GPU variants. Recommended drivers approved with deployment date = Patch Tuesday (T) at the maintenance hour. |
| Pilot | Assigned or dynamically distributed group, larger population, retaining model coverage. Deployment date T+7. |
| Broad | Remaining devices. Deployment date T+14. |


The T+7 and T+14 stagger provides a detection window: a driver causing issues in Test or Pilot is paused in the not-yet-deployed rings before it reaches them. This replaces per-driver human pre-approval as the safety mechanism.


### 3.2 Two-Layer Control Model


| Layer | Responsibility |
| --- | --- |
| Server side — Autopatch driver policies (manual mode) + runbook | Control when driver updates are offered. The runbook approves recommended drivers on Patch Tuesday with ring-staggered deployment dates, fully unattended. |
| Client side — Intune Remediation | Control when installation executes. Runs daily at the maintenance hour in device local time; installs only when no interactive session is present (with a deferral deadline), notifies the user, manages restarts. |


Neither layer alone satisfies the requirement. The deployment date controls when a device is offered a driver, not when it installs. The Remediation pins installation to the maintenance window. Without the server layer, drivers would arrive continuously as OEMs release them rather than on the monthly cadence.


### 3.3 End-to-End Flow


| Stage | Description |
| --- | --- |
| OEM releases driver | Driver published to the Windows Update catalog. Devices in manual-mode driver policies are not offered it; it appears in each ring policy's inventory as needs review. |
| T−2 days: optional review | Operations may review incoming drivers in the Intune portal and pause or decline any with a known issue before the runbook runs. This is optional — the design functions fully unattended. |
| Patch Tuesday: automated approval | Logic App triggers the runbook. For each ring, the runbook approves all pending recommended drivers with deployment date T / T+7 / T+14 at the maintenance hour. Approvals are immediately visible in the Intune portal. |
| Deployment date reached | Devices in the ring are offered approved drivers on their next Windows Update scan and download them in the background. |
| Remediation at maintenance hour (local) | Detection finds pending drivers. If no interactive session and on AC power, the user is notified and installation proceeds via the WUA COM API. If a session is present, installation defers up to a configurable deferral limit, then installs with advance notification (deadline policy). |
| Restart handling | If a restart is required and no session is active, the device restarts with a 60-second countdown. If a session is present, the restart is not forced; the user is notified, with Active Hours preventing automatic restart during business hours. |
| Incident response | If a driver causes issues in Test/Pilot, operations pauses it in the remaining rings via native driver pause before its deployment date there. |


### 3.4 Component Summary


| Component | Technology |
| --- | --- |
| Driver delivery control | Autopatch group with per-ring driver update policies in manual approval mode, deterministic ring assignment |
| Monthly approval trigger | Azure Logic App — second Tuesday recurrence |
| Approval execution | Azure Automation Runbook — PowerShell, Managed Identity, Autopatch Graph programmatic controls |
| Client-side installation + restart | Intune Remediation — daily at maintenance hour, device local time, SYSTEM context |
| Restart protection backstop | Intune Update Ring — Active Hours |
| Reporting | Native Windows Update for Business Reports driver data (Autopatch-scoped) + Intune driver report + Azure Monitor runbook alerts |


### 3.5 Intune Update Ring Configuration


| Setting | Value and rationale |
| --- | --- |
| Active Hours | Business hours or auto-detect — prevents forced restarts during working hours if a driver requiring a reboot is installed outside the expected window |


> [!WARNING]
> The 'Do not include drivers with Windows Update' policy must NOT be enabled for in-scope devices. Microsoft documents that it causes driver updates to be dropped at the device level regardless of source — including drivers approved through Autopatch. Delivery control is achieved by the Autopatch driver policy assignment itself.


## 4. Administrative Interface and Reporting


### 4.1 Intune Portal (native)


Driver management is performed in the Intune portal under Devices > Windows updates > Driver updates. Administrators see the Autopatch-created driver policies per ring and, via Manage drivers for Autopatch groups, can review incoming drivers, approve or decline for all policies or per policy with a deployment date, and pause or resume any driver. The runbook drives routine approvals; the portal is used for review and incident response.

- Pause/resume a specific driver per ring — the primary incident lever, no scripting
- Review recommended and other drivers, with device class and applicable device counts
- Inspect runbook-created approvals, which appear identically to portal approvals

> [!NOTE]
> The runbook only approves drivers in needs-review state. A driver an administrator has paused or declined is never re-approved by the runbook, so human incident decisions always take precedence over automation.


### 4.2 Windows Update for Business Reports (native driver data)


Because drivers are Autopatch-managed, the native Windows Update for Business Reports driver data is populated — the driver update reporting is documented as available for devices receiving driver updates from Windows Autopatch. This provides the operations dashboard without custom telemetry: driver update states, distribution of driver classes, update alerts, per-policy deployment status, and per-device compliance and installation status. Data is available both in the prebuilt workbook driver tab and as queryable Log Analytics tables (UCClient / UCClientUpdateStatus) for custom views.


Remediation output (install result, deferral count, restart outcome) is surfaced through the native Intune Remediation device status report, which covers the client-side installation health that the WUfB driver data does not. Together these two native sources cover both halves of the solution with no custom data pipeline.


> [!NOTE]
> WUfB Reports requires devices to send Windows diagnostic data at Required level or higher, and a Log Analytics workspace in a supported region. It is not available for GCC High or DoD environments.


## 5. Key Constraints and Limitations


| Constraint | Detail |
| --- | --- |
| Approval-mode switch is destructive | Toggling a driver policy between Automatic and Manual regenerates policies and loses all approvals, pauses, and declines. Set once at creation. |
| Rings are not per-workload | A device placed in an early ring for driver hardware coverage also receives quality and feature updates on that ring's schedule. Choose non-critical representatives; place critical rare-model devices in Pilot rather than Test. |
| Automated approval has no pre-review | Recommended drivers are approved without human review each cycle. Risk is mitigated by ring stagger and native pause, not eliminated. Optional T−2 review can add a review step without changing the automation. |
| Installation gate depends on the Remediation | The deployment date controls offer timing only. A device offline at its maintenance hour may be installed autonomously by Windows before the next Remediation run. Active Hours limits restart impact; residual installation risk is accepted and documented. |
| Never-idle devices | Devices with a permanently present interactive session defer indefinitely without the deadline. The configurable deferral deadline bounds this. |
| 24/7 and shift-work devices | Kiosks, control-room, and shift devices must be excluded from the Remediation and handled with a separately agreed maintenance window. |
| Runbook permissions | The Managed Identity requires the permission scope for Autopatch programmatic controls; validate the exact scope and apply RBAC review. The Graph controls are beta and subject to change. |
| Reporting scope | Native driver reporting depends on Autopatch-managed delivery and on device diagnostic data; devices with telemetry disabled will not report fully. Not available in GCC High / DoD. |
| Localization | User notifications should cover the languages used in the fleet; the Remediation selects by system locale with English fallback. |


## 6. Licensing Requirements


| Requirement | Licensing |
| --- | --- |
| Windows Autopatch driver management | Windows Enterprise E3/E5, Microsoft 365 E3/E5/A3/A5, or Microsoft 365 Business Premium |
| Intune Remediations | Microsoft 365 E3/E5, Intune Plan 2, or Microsoft Intune Suite (NOT Business Premium) |
| Windows Update for Business Reports | Included; requires Azure subscription for the Log Analytics workspace (no ingestion charge for WUfB Reports data) |
| Azure Automation + Logic App | Azure subscription, consumption-based; minor monthly cost |


## 7. Environment-Specific Parameters

- Maintenance hour for the client-side installation window (example used throughout: 22:00)
- Ring composition and stagger interval (example: Test / Pilot / Broad at T / T+7 / T+14)
- Maximum deferral count before deadline-forced installation (example default: 5 working days)
- Notification languages beyond English
- Inventory of 24/7 / shift / kiosk devices to exclude, and their alternative maintenance window
- Test and Pilot ring hardware-coverage audit: owner and recurring cadence (example: quarterly)

## 8. Design Rationale — Autopatch-Managed vs Standalone Profiles


Version 2.0 of this solution used standalone Intune driver update profiles and deliberately excluded drivers from Autopatch. Version 3.0 reverses that decision. The determining factors:


| Factor | Outcome |
| --- | --- |
| Reporting | Native Windows Update for Business Reports driver data is scoped to Autopatch-delivered drivers. The standalone design could not guarantee populated driver reporting; the Autopatch design gets it natively. This was the decisive factor. |
| Deterministic rings | Autopatch supports assigning custom Entra groups to rings, so hardware-coverage composition is achievable without percentage-based randomness — removing the original argument for standalone augmentation groups. |
| Manual approval + deployment date | Autopatch driver policies support manual mode with a deployment date, drivable by the runbook — delivering the same automated Patch Tuesday cadence the standalone design provided. |
| Native incident lever | Autopatch provides native per-driver pause/resume; the standalone design relied on the same underlying capability but outside the supported Autopatch surface. |
| Trade-off accepted | Rings are not per-workload (early-ring devices get all update types early), and the runbook depends on the beta Autopatch Graph controls. Both are judged acceptable given the reporting and supportability gains. |


> [!NOTE]
> The standalone-profile design (version 2.0) remains valid for environments that cannot or do not use Autopatch. Its documents are retained for reference.
