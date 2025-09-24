# RingtonesScreen

- Purpose: Lets user preview and select a ringtone from bundled assets for alarms.
- Data:
  - `availableRingtones`: curated list of `Ringtone(name, assetPath)` with One UI sounds.
  - `SharedPreferences` key `selected_ringtone` persists the chosen asset path.
- Behavior:
  - On init, loads saved ringtone or defaults to first entry.
  - Preview button toggles playback via `audioplayers` using `AssetSource` (asset path minus leading `assets/`).
  - Selecting a row updates state and saves preference immediately.
- UI:
  - AppBar title with Google Fonts styling.
  - ListView of radio + title + play/pause button; highlights selected row.
