# SettingsDrawer

- Purpose: Global drawer providing theme toggle, ringtone selection, and premium placeholder.
- Theme Toggle:
  - Finds `MyAppState` ancestor to read and toggle `isDarkMode`.
- Navigation:
  - Closes drawer and pushes `RingtonesScreen` on Alarm Ringtones tap.
- Structure:
  - Header with styling, list tiles for Dark/Light mode, Alarm Ringtones, Go Premium (stub), and Close.
