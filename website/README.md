# GeoWake Website

Marketing site for GeoWake — hosted on GitHub Pages.

## Structure

```
website/
├── index.html                 # Single-file site (all CSS/JS inline)
├── assets/
│   ├── app-icon.png           # The real app icon (copy of assets/app_icon.png)
│   └── screens/               # Real screenshots of the shipping build
│       ├── metro-tracking.png # Mid-journey, multi-leg route (hero)
│       ├── home-distance.png  # Home, distance mode
│       ├── home-stops.png     # Home, Metro Mode / stops
│       ├── search.png         # Places autocomplete
│       ├── settings.png       # Settings drawer
│       └── pricing.png        # Pro passes
└── README.md
```

## Design

The site does not have its own visual identity — it borrows the app's, so the two
read as one product. Everything below is lifted from the shipping build:

| Token | Value | Source |
|---|---|---|
| Wordmark | Pacifico | `lib/screens/homescreen.dart:1413` |
| Body type | Montserrat | `lib/themes/appthemes.dart:11` |
| Page / card surfaces | `#121212` / `#303030` / `#424242` | `AppThemes.darkTheme` |
| Primary | deepPurple 500 `#673ab7` | `primarySwatch` |
| Accent (sliders, toggles) | deepPurple 200 `#b39ddb` | in-app controls |
| Teal | `#6a9594` | sampled from `assets/app_icon.png` |
| Amber | `#f0a93b` | the app's "switch routes" notice |
| Icons | Material Symbols Rounded | the app's own icon set |

If you restyle the app, update this table first and the site follows.

## Screenshots

They are **real captures**, not mockups. `metro-tracking.png` and `home-stops.png`
came off a physical device; the rest off an `x86_64` emulator running a release
build. All are normalised to 540 × 1170 (9:19.5) with the status bar, the debug
ribbon and the ad banner cropped out, then padded to a common aspect.

To add one: capture at any size, crop off the system chrome, resize to 540 wide,
pad the bottom to 1170px with the screen's own background colour.

## Local preview

```bash
cd website && python3 -m http.server 8080
# Open http://localhost:8080
```

## Deployment

Pushing changes under `website/` to `production-ready-audit-v2` or
`stable-release-1` triggers `.github/workflows/deploy-website.yml`, which deploys
to GitHub Pages.

**Before enabling:** repo Settings → Pages → Source: GitHub Actions.

## Customizing

| What | Where |
|------|-------|
| Colours / type | `:root` CSS variables at the top of `index.html` |
| Pricing | `#pricing` section |
| Features | `#features` (free) and `#pro` (paid) sections |
| Screenshots + captions | `#screens` section |
| Store links | `#get` section |

## Before launch

- [ ] `#get` says **"Coming soon to Google Play"** with no link, because the app
      isn't published yet. Swap in a real store link once it is.
- [ ] There is no waitlist or contact capture anywhere on the page. Add one if you
      want signups before launch.
- [ ] Re-read `../docs/WEBSITE_CLAIMS_AUDIT.md` and confirm the softened claims still match the
      code — several describe behaviour that was still being finished.
