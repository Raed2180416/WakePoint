# Test Coverage & Gaps

## Runtime evidence (executed)

- 2026-01-12: `flutter test --disable-dds` completed successfully: **All tests passed** (output shows `+452` total).
- Evidence snippets from the test run output indicate coverage of:
	- Alarm distance-mode trigger evaluation (route-progress and straight-line fallback paths)
	- TrackingService deviation/reroute decision flow and manager switching
	- Connectivity/GPS-dropout simulation triggering sensor fusion start/stop
	- Transfer detection logic for transit steps

## What these tests do NOT prove

- Android OS behavior: background execution limits, process death, OEM battery optimizations.
- Foreground service + notification behavior on real devices (lock screen, full-screen intent, DND, battery saver).
- Actual permission prompts and user-denial flows.

## What tests exist (what they *actually* prove)

- There is an actively exercised automated test suite (at least 452 tests as reported by `flutter test`) that hits:
	- Alarm evaluation logic (distance mode) and some fallback branches.
	- TrackingService route activation/switching/reroute-related flows.
	- Connectivity/GPS degradation handling behaviors (at least in simulation).
	- Transit/transfer utilities.

## Server tests (present, not executed as runtime evidence here)

- `geowake-server/test/auth.test.js`: token issuance happy-path and auth middleware behavior using Supertest.
- `geowake-server/test/maps.test.js`: proxy endpoints require auth; caching behavior assertions (where Google API responses may still error depending on environment).
- NOTE: These were read as code evidence only; no `npm test` run was recorded in this audit session.

## What’s missing for safety-critical flows

- Device validation runs that simulate:
	- Screen off + device locked + app backgrounded for extended time.
	- Process death (swipe-away / force-stop where applicable) and restore semantics.
	- Alarm delivery under DND, battery saver, and “restricted” battery mode.
- Tests specifically asserting end-to-end STOP_ALARM / END_TRACKING / MUTE_JOURNEY action consumption from persisted flags.

## Prioritized test plan (5–15 tests to add)

For each test:
- **Priority**: P0/P1/P2
- **Type**: unit/widget/integration
- **Where**: (folder + proposed filename)
- **What it asserts**:
- **Dependencies/mocks**:
- **Evidence it would upgrade**: (Certainty Matrix row)

- TBD
