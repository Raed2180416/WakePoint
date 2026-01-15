# Prioritized Fix Plan (Surgical)

## Rules

- Every fix item must reference exact Findings and Certainty Matrix rows.
- Order by user safety + reliability first, then correctness, then perf/battery.

## Phase 0 — STOP_SHIP reliability fixes

- **STOP_SHIP: Harden geowake-server auth to prevent proxy abuse**
	- **Resolves**: `SECURITY_PRIVACY.md` STOP_SHIP (bundleId-only token + permissive CORS)
	- **Certainty Matrix**: “Server proxy auth prevents 3rd-party abuse” (currently LOW)
	- **Fix direction**:
		- Require Play Integrity/device attestation or per-install secret provisioned securely
		- Remove `'*'` from default allowed origins and explicitly deny browser origins unless intended
		- Bind JWT to device identifier and add revocation/rotation

- **HIGH: Remove hardcoded Google Maps API key fallback from Android build**
	- **Resolves**: `SECURITY_PRIVACY.md` “hardcoded fallback `AIza...`”
	- **Certainty Matrix**: “Android build embeds fallback Google Maps API key when key.properties missing” (CERTAIN)
	- **Fix direction**: fail build if missing; enforce key restriction by package + SHA-1

## Phase 1 — Correctness fixes

- **MEDIUM: Unify alarm notification channel IDs across Kotlin + Dart**
	- **Resolves**: `ALARM_DELIVERY_RELIABILITY.md` channel mismatch finding
	- **Certainty Matrix**: “Alarm notification channel configuration consistent” (MEDIUM)
	- **Fix direction**: single channel id (remove Kotlin alarm channel if Dart is authoritative)

- **HIGH: Make restore UX explicit when snapshot is missing/corrupt**
	- **Resolves**: `CRITICAL_USER_FLOWS.md` Flow 3 finding (restore terminates tracking if snapshot invalid)
	- **Certainty Matrix**: “Process death restore gate … snapshot required” (HIGH)
	- **Fix direction**: show a recovery dialog/toast explaining why tracking stopped and what to do next

- **HIGH: Make snapshot persistence size-bounded + verifiable**
	- **Resolves**: `EDGE_CASES_AND_LOGICAL_GAPS.md` “Snapshot persistence failure can cause restore ends tracking”
	- **Certainty Matrix**: “Wake Me starts tracking and persists snapshot” (CERTAIN for intent) + “Process death restore gate … snapshot required” (HIGH)
	- **Fix direction**:
		- Persist a minimal, fixed-size snapshot required for safety (destination + alarm params + minimal polyline/legs), with schema version + checksum
		- If directions cannot be persisted, fail the start flow (or warn user) instead of silently starting a non-restorable session

## Phase 2 — Performance/battery optimizations

- **MEDIUM: Back off / gate the 200ms alarm-action polling timer**
	- **Resolves**: `ALARM_DELIVERY_RELIABILITY.md` polling timer finding; `PERFORMANCE_BOTTLENECKS.md` alarm polling bottleneck
	- **Certainty Matrix**: “Alarm stop/mute/end action consumption uses 200ms polling” (HIGH)
	- **Fix direction**: stop timer when alarm not visible; add backoff; rely more on event-based processing where possible

- **LOW: Reduce heartbeat frequency when stable**
	- **Resolves**: `PERFORMANCE_BOTTLENECKS.md` heartbeat bottleneck
	- **Certainty Matrix**: “Foreground service heartbeat emits every 1s” (CERTAIN)
	- **Fix direction**: 5–15s cadence when stable; keep 1s only during transition periods

- **MEDIUM: Define an explicit offline cache policy (TTL/origin drift) + user messaging**
	- **Resolves**: `CRITICAL_USER_FLOWS.md` Flow 4 finding; `EDGE_CASES_AND_LOGICAL_GAPS.md` offline TTL/origin drift constraints
	- **Certainty Matrix**: “Offline cached-route availability (TTL/origin drift constraints)” (MEDIUM)
	- **Fix direction**:
		- Consider separate TTL for offline use (e.g. hours, not minutes) or a user-selectable “offline session” mode
		- Allow larger origin tolerance when offline (or cache multiple origins)
		- Ensure UI makes the failure mode explicit (“offline route unavailable; tracking not started”)

## Phase 3 — UX polish + resilience

- **LOW: Avoid duplicate notification permission prompts**
	- **Resolves**: `ALARM_DELIVERY_RELIABILITY.md` duplicate permission prompt finding
	- **Certainty Matrix**: (add row if kept as finding)
