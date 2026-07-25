# GeoWake Website

Marketing site for GeoWake — hosted on GitHub Pages.

## Structure

```
website/
├── index.html          # Single-file site (all CSS/JS inline)
├── assets/
│   ├── qr-play-store.png       # Branded QR (purple on white)
│   ├── qr-play-store-light.png # White on purple
│   └── qr-dark.png             # Cyan on dark
└── README.md
```

## Local preview

```bash
cd website && python3 -m http.server 8080
# Open http://localhost:8080
```

## Deployment

Push to `production-ready-audit-v2` or `stable-release-1` (changes under `website/`)
triggers the GitHub Actions workflow (`.github/workflows/deploy-website.yml`),
which deploys to GitHub Pages.

**Before enabling:** Go to repo Settings → Pages → Source: GitHub Actions.

## Customizing

| What | Where |
|------|-------|
| Play Store link | `index.html` — search for `play.google.com` (appears in QR generation + store badge) |
| QR code | Re-run the QR generator script (see below) |
| Colors | `:root` CSS variables at top of `index.html` |
| Pricing | `#pricing` section |
| Features | `#features` and `#pro` sections |

## Regenerate QR code

```bash
pip install qrcode[pil]
python3 - << 'EOF'
import qrcode
from qrcode.constants import ERROR_CORRECT_H
qr = qrcode.QRCode(version=None, error_correction=ERROR_CORRECT_H, box_size=10, border=2)
qr.add_data("https://play.google.com/store/apps/details?id=com.geowake.app")
qr.make(fit=True)
qr.make_image(fill_color="white", back_color="#4c1d95").save("assets/qr-play-store.png")
EOF
```

## Design

- **Aesthetic:** "Deep Night Aurora" — atmospheric dark base with deep-purple/violet aurora gradients, grain texture, geometric data-viz accents.
- **Fonts:** Plus Jakarta Sans (display) + Space Grotesk (body).
- **Brand colors:** Deep purple (`#4c1d95` / `#7c3aed`) with cyan (`#22d3ee`) and amber (`#fbbf24`) accents.
- **Responsive:** Mobile-first, fluid typography with `clamp()`, grid-based layout.
- **Accessible:** Semantic HTML, `prefers-reduced-motion` support, 44px+ touch targets, sufficient contrast.
