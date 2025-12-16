# Stop-Based Alarm Mode Analysis

## How It Works
The "Stops" alarm mode relies on mapping your physical location (meters along route) to a "virtual" number of stops passed.

1.  **Route Parsing (`TransferUtils`)**:
    *   The app breaks the route into "Steps" (Walk, Bus, Walk, Metro, etc.).
    *   It calculates two parallel lists:
        *   `bounds`: Cumulative distance at the *end* of each step (e.g., `[100m, 5000m, 5200m]`).
        *   `stops`: Cumulative transit stops at the *end* of each step (e.g., `[0, 12, 12]`).
    *   *Note*: Walking steps add 0 stops. Transit steps add `num_stops` from the API.

2.  **Progress Calculation (`TrackingService`)**:
    *   As you move, the app calculates `progressMeters` (distance from start).
    *   It determines `progressStops` by finding which step you are currently in.
    *   **Logic**: `progressStops = stops[current_step_index]`

3.  **Trigger Logic**:
    *   **Destination**: `RemainingStops = TotalStops - ProgressStops`.
    *   **Switch Points**: `StopsToEvent = EventStops - ProgressStops`.
    *   **Alarm**: Fires if `RemainingStops <= AlarmThreshold`.

## Identified Gaps & Edge Cases

### 1. The "End-of-Step" Estimation Gap (Critical)
**The Issue**: The current logic assumes that as soon as you enter a step, you have completed *all* stops in that step.
*   **Scenario**: You board a bus with 10 stops.
*   **Reality**: You have passed 0 stops.
*   **Code Behavior**: `progressStops` immediately jumps to include all 10 stops.
*   **Result**: The app thinks you are already at the end of the bus ride. `RemainingStops` drops drastically.
    *   If your threshold is 2 stops, the alarm might trigger **immediately upon boarding**, or it might behave erratically depending on the previous step's value.

### 2. The "Overshoot" Bug (Why alarms might not fire)
**The Issue**: If your GPS location drifts slightly *past* the destination or the defined route end (even by 1 meter):
*   **Code Behavior**: The loop finding the current step fails to find a match (`pm <= bound` is never true).
*   **Result**: `progressStops` defaults to `0.0`.
*   **Consequence**:
    *   `RemainingStops` becomes `TotalStops - 0` = `TotalStops`.
    *   If `TotalStops` (e.g., 15) is greater than your threshold (e.g., 2), the **alarm will NOT fire**.
    *   This is likely why alarms fail at the very end if GPS is imperfect.

### 3. The "Already Passed" Check
**The Issue**: For switch points (transfers), the code skips the check if `event.meters <= progressMeters`.
*   **Scenario**: You are approaching a transfer. GPS jitters forward and momentarily reports you are 1m past the transfer point.
*   **Result**: The event is discarded as "already passed" *before* the alarm logic can check if you are within the stop threshold. The alarm never fires.

### 4. Missing Data
**The Issue**: Some transit agencies do not provide `num_stops` in the Google Directions API response.
*   **Result**: `cumStops` never increases. `TotalStops` is 0.
*   **Consequence**: `RemainingStops` is always 0. Alarm triggers immediately/constantly.

## Summary of Failure at Switch Points & Destination
*   **At Destination**: The "Overshoot Bug" is the most likely culprit. If you are 1m past the mapped endpoint, the system resets your progress to 0 stops, causing the alarm condition to fail.
*   **At Switch Points**: The "Already Passed" check combined with the "End-of-Step" estimation makes timing very fragile. If the system thinks you've already finished the leg (due to estimation gap) or if GPS puts you slightly past the point, it fails.
