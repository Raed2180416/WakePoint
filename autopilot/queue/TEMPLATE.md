---
id: REPLACE-unique-id
max_minutes: 30
model: opencode/big-pickle
test_cmd: flutter test test/PATH_TO_RELEVANT_test.dart
---
Describe ONE focused task here. The worker injects repo context and hard
guardrails automatically (invariants, protected paths, style rules).

Good tasks: fix a specific failing test, remove dead code found by analyze,
add a missing test for file X, update a dependency and fix fallout, draft a
Play Store description in docs/store/.

Bad tasks: anything touching monetization gates, reachability physics, consent
logic, or CI config — those are human/Claude-session work by policy.
