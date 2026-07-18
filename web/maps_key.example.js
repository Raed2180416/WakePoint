// Google Maps JS API key for LOCAL web builds only. NEVER commit a real key.
//
// Setup: copy this file to `web/maps_key.js` (gitignored) and paste your key:
//     window.GEOWAKE_MAPS_KEY = 'AIza...';
//
// Use the SAME key you put in android/key.properties (googleMapsApiKey), and
// restrict it by HTTP referrer / Android app in the Google Cloud console.
// Without web/maps_key.js the web map renders blank; the app still runs.
window.GEOWAKE_MAPS_KEY = '';
