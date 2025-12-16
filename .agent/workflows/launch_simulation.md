---
description: How to launch the GeoWake Simulation Playground
---

The GeoWake Simulation Playground consists of three parts that must run simultaneously:
1.  **Relay Server**: Acts as a bridge, passing messages between the app and the dashboard.
2.  **Web Dashboard**: Visualizes the route, location, and ETA.
3.  **Mobile App**: The actual GeoWake app running on a device/emulator.

Follow these steps to launch everything:

1.  **Start the Relay Server**
    Open a terminal and run:
    ```powershell
    dart tools/relay_server.dart
    ```
    *You should see "Relay server listening on 0.0.0.0:8081"*

2.  **Start the Web Dashboard**
    Open a **new** terminal (keep the relay server running) and run:
    ```powershell
    flutter run -d chrome -t lib/main_dashboard.dart --web-port 3000
    ```
    *This launches the dashboard in Chrome. Note the `--web-port 3000` is optional but good for consistency.*

3.  **Start the Mobile App**
    Open a **third** terminal and run:
    ```powershell
    flutter run
    ```
    *Select your emulator or physical device.*

**Troubleshooting:**
*   **Connection Refused**: Ensure the Relay Server is running *before* the other two.
*   **No Data on Dashboard**: Ensure both the App and Dashboard show "Connected" status (check logs).
*   **Android Emulator**: If using an Android emulator, you might need to forward the port:
    ```powershell
    adb reverse tcp:8081 tcp:8081
    ```
    *This allows the emulator to talk to `localhost:8081` on your computer.*
