# PermissionService (lib/services/permission_service.dart)

Purpose: Orchestrates friendly permission flow for Location (foreground+background), Notifications, and Activity Recognition (Android).

- Class: line 6 — holds `BuildContext`.
- `requestEssentialPermissions()`: line 13 — sequentially requests location -> notifications -> activity recognition; returns true only if critical perms are granted.
- `_requestLocationPermission()`: line 30 — rationale dialog then request; on grant, requests background location via `_requestBackgroundLocation()`.
- `_requestBackgroundLocation()`: line 59 — rationale then `locationAlways`.
- `_requestNotificationPermission()`: line 74 — Android-only; handles permanentlyDenied via settings dialog.
- `_requestActivityRecognitionPermission()`: line 87 — Android-only, non-critical.
- Dialog helpers: `_showRationaleDialog`, `_showSettingsDialog` — consistent UI prompts.

Tests: UI/permission flow verified manually; no unit tests.
