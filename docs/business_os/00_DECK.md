# GeoWake Business OS — Master Deck

> The single entry point. Read this, then the numbered chapters. Everything here
> is grounded in the code (audited 2026-07-24) and fact-checked web research
> (`research/`), not optimism. Where a claim is an estimate it says so.

## What GeoWake is

A transit wake-up alarm, India-first, Android-first. Set your metro/bus stop,
sleep, and it wakes you before arrival — reliably, **through silent mode, Do
Not Disturb, and GPS-dead tunnels** (EKF sensor fusion + a physics-based
never-late guarantee). Free core forever; ₹199 one-time Pro (ad-free + safety
features); ads on free tier.

The engineering is genuinely ahead of the market (never-late replay-harness CI
gate, reachability physics, EKF underground positioning, 869-station India metro
dataset). The competitive research confirms **no competitor pairs a real
DND-breaking wake alarm with tunnel-proof positioning** — that's the moat.

## The two goals (from the brief) and where they stand

1. **Get to 100% production-ready.** Status after this session: a
   deep 8-dimension audit ran (36 verified findings, 8 P0). The alarm-chain and
   Play-compliance ship-blockers are fixed and committed; server wallet-drain
   protection and monetization-correctness fixes are in progress. See
   `01_launch_readiness.md` for the live checklist and what's left.
2. **Stand up a system that runs the business 24/7 at ~$0.** Built this
   session: `autopilot/` (a real, installed-by-one-script maintenance loop on
   this machine using free CLI agents) + this deck as the operating manual for a
   future local-LLM agent. See `02_engineering_autopilot.md` and
   `07_governance.md`.

## The chapters

| # | File | What it decides |
|---|---|---|
| 00 | this | Orientation + KPIs |
| 01 | `01_launch_readiness.md` | The concrete go-live checklist (audit findings + Play policy) |
| 02 | `02_engineering_autopilot.md` | The 24/7 code-maintenance loop (built, v1 in `autopilot/`) |
| 03 | `03_monetization.md` | Committed pricing + which revenue tracks are real |
| 04 | `04_marketing.md` | Zero-budget 90-day growth playbook |
| 05 | `05_maps_cost_elimination.md` | The Google-Maps-replacement roadmap (behavior-identical, ~free) |
| 06 | `06_expansion_and_underground.md` | New cities + proving underground reliability from public data |
| 07 | `07_governance.md` | What the autonomy may never do; invariants; risk register |
| — | `research/` | Fact-checked source reports (policy, maps, marketing, monetization, competitors, agent stack, underground data) |

## The business in one screen

- **Revenue:** an OPEN decision between your prepaid pass ladder
  (₹7/₹35/₹99/₹899, `PASS_PRICING_ANALYSIS.md`) and the ₹199 one-time the code
  ships today — see `03` for the honest tradeoff (both are UPI-friendly; passes
  win on recurring LTV, one-time wins on simplicity). Plus marginal free-tier
  ads. B2B data is dead for planning; corporate safety deferred until a pilot.
- **Cost that matters:** Google Maps is the only thing that scales into real
  money (~$1–1.5k/mo at 10k DAU, ~$13–18k/mo at 100k DAU on India pricing). The
  replacement stack lands the same behavior for ~$10–50/mo then ~$150–300/mo —
  a 50–100× cost gap. Launch on Google Maps; migrate in the background as users
  grow. See `05`.
- **Growth that's free:** ASO + POV-format Reels/Shorts + city-subreddit
  founder posts + journey-share viral loop. See `04`.
- **The existential risk:** Google shipping a real wake-alarm into Maps/Android.
  Today's Pixel Transit Mode is a manual DND filter that does NOT wake you —
  the gap is real but temporary. Defense: be deeper (underground, safety) and
  fast to 100k users. See `03` §3 and `06`.

## The product KPI above all others

**Successful-wake rate.** If a rider is ever silently not woken, nothing else
matters — the app's one promise broke. Every gate, the autopilot, and the
governance rails exist to protect this number. Ship metrics track it per device
cohort (Indian OEM battery-killers are the known threat — see the
backstop/doze work and `01`).
