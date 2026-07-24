// src/routes/legal.js
//
// Serves the user-facing Privacy Policy and Terms of Use as public, no-auth
// HTML pages. The GeoWake app links these at /legal/privacy and /legal/terms
// (see lib/screens/monetization/paywall_screen.dart and settingsdrawer.dart).
//
// Google Play requires a privacy policy that is reachable AND matches the app's
// actual data behaviour and the Data Safety form. The copy below is written to
// match what the audited code actually does today:
//   - Location is used only to run the wake alarm; the mobility-data pipeline
//     is inert (zero egress) unless the user explicitly opts in.
//   - Telemetry is local-only unless a build-time endpoint is configured.
//   - Journey share / Guardian send location to the share backend only when the
//     user starts a share / enables Guardian.
//
// REVIEW BEFORE LAUNCH: confirm the contact address and the effective date, and
// have the final wording reviewed. The privacy surface is a human decision
// (see docs/business_os/07_governance.md) — this is an accurate draft, not a
// substitute for your own review.

const express = require('express');
const router = express.Router();

const CONTACT_EMAIL = process.env.LEGAL_CONTACT_EMAIL || 'support@geowake.app';
const EFFECTIVE_DATE = process.env.LEGAL_EFFECTIVE_DATE || '2026-07-24';

const shell = (title, body) => `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="all">
<title>${title} — GeoWake</title>
<style>
  :root { color-scheme: light dark; }
  body { max-width: 42rem; margin: 0 auto; padding: 2rem 1.25rem 4rem;
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif;
    color: #16202b; background: #fff; }
  @media (prefers-color-scheme: dark) { body { color: #e8edf3; background: #0d1014; } a { color: #f0a835; } }
  h1 { font-size: 1.7rem; letter-spacing: -0.02em; margin: 0 0 .25rem; }
  h2 { font-size: 1.15rem; margin: 2rem 0 .5rem; }
  .meta { color: #8695a4; font-size: .85rem; margin-bottom: 2rem; }
  ul { padding-left: 1.2rem; } li { margin: .3rem 0; }
  a { color: #c67c12; }
  code { font-family: ui-monospace, monospace; font-size: .9em; }
</style></head><body>
${body}
<p class="meta">Effective ${EFFECTIVE_DATE}. Contact: <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a></p>
</body></html>`;

const privacy = shell('Privacy Policy', `
<h1>GeoWake Privacy Policy</h1>
<p class="meta">Effective ${EFFECTIVE_DATE}</p>
<p>GeoWake is a transit wake-up alarm. This policy explains what data the app
uses and why. The guiding principle is data minimisation: GeoWake collects the
least it can to wake you before your stop, and shares nothing by default.</p>

<h2>Location</h2>
<ul>
  <li><strong>What:</strong> your device location, including in the background
  (even when the app is closed), while a journey is active.</li>
  <li><strong>Why:</strong> solely to track your transit journey and sound the
  wake-up alarm before your stop. It is not used for advertising and is never
  sold.</li>
  <li><strong>Where it goes:</strong> location is processed on your device.
  Route and place lookups are sent to our servers only as needed to compute your
  journey; we do not build a profile of your movements.</li>
</ul>

<h2>Journey sharing &amp; Guardian (optional)</h2>
<p>If you start a live journey share, or enable Guardian mode, GeoWake sends your
live journey location to our share backend so the contact you chose can follow
your trip. This happens only when you turn it on, and stops when the journey
ends. If you never use these features, no location leaves your device for them.</p>

<h2>Anonymous mobility statistics (off by default)</h2>
<p>GeoWake includes an optional, opt-in feature to contribute anonymous,
noise-added station-count statistics. It is <strong>off by default</strong> and
sends nothing unless you explicitly turn it on. The data is aggregated,
protected with differential privacy and k-anonymity, and contains no GPS
coordinates. You can withdraw at any time, which erases the local statistics.</p>

<h2>Purchases &amp; ads</h2>
<ul>
  <li><strong>Pro purchase</strong> is handled by Google Play Billing; GeoWake
  does not see or store your payment details.</li>
  <li><strong>Ads</strong> on the free tier are served by Google AdMob, which
  may collect device/advertising identifiers per Google's policies. Pro removes
  ads. Ads are never shown on the tracking or alarm screen.</li>
</ul>

<h2>Diagnostics</h2>
<p>GeoWake keeps limited reliability diagnostics on your device to help ensure
the alarm fires on time. These stay on the device unless a future update, with
notice, enables opt-in sharing.</p>

<h2>Data retention &amp; your rights</h2>
<p>Journey-share data is retained only for the duration needed to deliver the
share. You can withdraw the optional statistics consent at any time in Settings.
For questions or requests about your data, contact us below.</p>

<h2>Children</h2>
<p>GeoWake is not directed at children under 13 (or the minimum age in your
jurisdiction). The optional statistics feature requires you to confirm you are
18 or older.</p>

<h2>Changes</h2>
<p>We will update this policy as the app evolves and revise the effective date.
Material changes to data sharing will be surfaced in the app.</p>
`);

const terms = shell('Terms of Use', `
<h1>GeoWake Terms of Use</h1>
<p class="meta">Effective ${EFFECTIVE_DATE}</p>
<p>By using GeoWake you agree to these terms.</p>

<h2>What GeoWake does</h2>
<p>GeoWake helps you wake before your transit stop. We work hard to make the
alarm reliable, including when GPS is unavailable underground. However, GeoWake
depends on your device's sensors, operating-system behaviour, battery settings,
and network — factors partly outside our control. <strong>GeoWake is an aid, not
a guarantee.</strong> Keep your own judgement, especially for critical trips.</p>

<h2>Your responsibilities</h2>
<ul>
  <li>Grant the permissions the alarm needs (location "all the time",
  notifications, exact alarms) and keep battery optimisation from killing the
  app if you rely on background waking.</li>
  <li>Use GeoWake lawfully and do not attempt to disrupt or abuse the service.</li>
</ul>

<h2>Purchases</h2>
<p>Pro is a one-time purchase via Google Play. Refunds are handled under Google
Play's refund policy.</p>

<h2>Disclaimer &amp; liability</h2>
<p>GeoWake is provided "as is", without warranties of any kind. To the maximum
extent permitted by law, we are not liable for missed stops, missed alarms, or
any indirect or consequential loss arising from use of the app.</p>

<h2>Changes</h2>
<p>We may update these terms and will revise the effective date. Continued use
after changes means you accept them.</p>
`);

router.get('/privacy', (req, res) => res.type('html').send(privacy));
router.get('/terms', (req, res) => res.type('html').send(terms));

module.exports = router;
