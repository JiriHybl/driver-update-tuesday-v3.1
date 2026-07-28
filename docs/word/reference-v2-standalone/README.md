# Reference: v2 (Standalone) Design

This is an **earlier, superseded** version of the solution that used standalone
Intune driver update profiles instead of Windows Autopatch-managed driver
policies.

It is kept here for one reason: **if your environment cannot or does not use
Windows Autopatch**, this design still works — it just loses the native
Windows Update for Business Reports driver data (that reporting is scoped to
Autopatch-delivered drivers) and the native per-driver pause/resume incident
lever that the current design relies on.

For any environment that does have Autopatch available, use the current
design in `docs/architecture.md`, `docs/setup-guide.md`, and
`docs/operations-plan.md` instead — it was validated end-to-end in a lab
tenant; this v2 material was not re-validated against that same discipline
and should be treated as less current.
