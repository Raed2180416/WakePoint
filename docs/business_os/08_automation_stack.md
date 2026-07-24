# GeoWake — $0 Autonomous Business Automation Deck

> Generated 2026-07-24. Every business function mapped to the smartest $0 tool/skill/MCP/OSS/SOTA a 24/7 LOCAL agent can drive. Verified where versions/pricing change. This is the buildable stack for the future local-LLM agent that runs the business.

## GeoWake $0/month, 24/7 Autonomous Business Stack — Full Deck

Founder-owned Linux box (16-32GB RAM, RTX 4060 8GB) + one Oracle Always-Free ARM VM + Railway (existing backend host) + a private GitHub repo. Every recommendation below is $0 recurring; one-time costs (Play Console $25 already paid, optional OpenRouter $10 lifetime credit) are called out explicitly.

### 0. The brain (must exist before anything else works)

- **llama.cpp** (`llama-server`, OpenAI-compatible endpoint) — NOT Ollama. Ollama's current release mishandles the XML tool-call envelope some MoE models (GLM family) were trained on; llama.cpp gives full control of `--n-cpu-moe`/`-ngl` offload and correct chat templates.
- **Qwen3-Coder-30B-A3B-Instruct** (Unsloth GGUF, Q4_K_M) — primary local model. 30B total/3B active MoE fits an 8GB card via expert-offload to 32GB RAM, ~15-40 tok/s, up to 262K context documented on this hardware class.
- **GLM-4.7-Flash** (30B-A3B MoE) — secondary model. Leads BFCL-v3 function-calling benchmarks; use for planning/triage where tool-call reliability matters more than raw coding depth.
- **LiteLLM proxy** (self-hosted OSS) — the router. One OpenAI-compatible endpoint every business function calls, with a YAML fallback chain: local llama.cpp -> Groq (fastest, 6K TPM) -> Cerebras (1M free tokens/day) -> Gemini 2.5 Flash (1M context) -> OpenRouter free roster (incl. free Qwen3-Coder-480B). Swapping providers is a YAML edit, not a code change.

**Wiring:** `llama-server` and LiteLLM run as systemd/Docker services. Every function's cron/systemd-timer script makes one HTTP call to LiteLLM's `/v1/chat/completions` with a model alias — never talks to Ollama/llama.cpp/cloud SDKs directly. Free-tier RPM/TPM numbers drift monthly (2026-07-24 snapshot) — the router pattern is durable, the numbers are not; don't hardcode them into agent logic.

### 1. Autonomous code maintenance

- **Self-hosted GitHub Actions runner** (Oracle VM/home box) — private repo's 2,000 min/mo cap gets blown through by a 24/7 loop; self-hosted is free/unmetered on the same box as the LLM.
- **mini-swe-agent** (MIT) — primary driver: ~100-line bash-only agent, no tool-calling API dependency, works reliably with weak local models. Given an issue/CI failure log, edits files and opens a PR via `gh`.
- **aider** (Apache-2.0) — chained after mini-swe-agent for patch-quality work (dep bumps, tests, refactors); auto-commits with generated messages.
- **Serena MCP** (MIT) — local replacement for codebase-memory MCP; wraps Dart's `analysis_server` + `typescript-language-server` via LSP for symbol-level navigation. The orchestrator script is the MCP client (bare llama.cpp has none); results get injected as text into the next agent prompt.
- **osv-scanner** (Apache-2.0) — CVEs across `pubspec.lock` + `package-lock.json`, same DB Dependabot uses. Keep Dependabot version-updates ON too (free for private repos) as a parallel supplement.
- **Semgrep CE** (LGPL-2.1) scoped to Express/Node + `dart analyze`/`very_good_analysis` for Flutter/Dart — replaces CodeQL, now paid (GHAS) for private repos.
- **Trivy** (Apache-2.0) — container image/IaC layer for the Railway deploy config, plus filesystem CVE sweep.
- **gitleaks** (MIT) — free substitute for GitHub's now-paid Secret Protection add-on; pre-commit hook + CI gate stopping agents from ever landing a leaked key.

**Wiring:** systemd timer wakes a Python orchestrator every N minutes; runs the scanner suite, builds a task queue, shells out to mini-swe-agent (via LiteLLM) per task, optionally queries Serena for bigger refactors, hands off to aider for the final diff, pushes a branch, `gh pr create`. Self-hosted runner runs the full check suite. **Patch-level dep bumps that pass CI clean can auto-merge; anything touching alarm/reachability/EKF/auth/payment logic routes to human approval (ntfy/Telegram) — never auto-merged**, per this repo's own documented never-late safety invariants.

### 2. Autonomous behaviour validation

- **Local headless Android emulator** (AVD/adb) — the 24/7 workhorse, unlimited runs, full logcat/screenrecord.
- **Maestro CLI** — already adopted in-repo (`test/maestro/persona_*.yaml`); YAML flows are LLM-readable/-authorable; screenshots double as a free UI-regression corpus (local pixelmatch diff). Skip Maestro Cloud ($250/device/mo).
- **Patrol** — already a pubspec dependency; drives native OS chrome (permission dialogs, notification tray, background/kill) — the only way to prove the alarm fires from a killed app. Keep the local `PatrolJUnitRunner`, not the BrowserStack/LambdaTest hooks found compiled in (trial-credit only).
- **One spare Android phone**, always-on, `adb connect` over WiFi/USB — best answer for real OEM battery-killer reliability (MIUI/OneUI findings already in memory); no emulator/cloud farm reproduces real Doze/App-Standby over days.
- **GitHub Actions + `reactivecircus/android-emulator-runner`** — fills the missing emulator/E2E job in `ci.yml` as a fast PR-gate (10-15 min), not the continuous monitor.
- **Firebase Test Lab (Spark/free)** — 5 physical + 10 virtual device runs/day free forever, `gcloud firebase test android run`, for periodic OEM-fragmentation coverage.
- **Firebase Crashlytics + Android Vitals** — primary crash/ANR channel, unlimited-free, natively captures ANRs (relevant to GW-0192).
- **Sentry Developer (free)**, backend-only — 5K events/mo cap reserved for the Express/Railway backend so mobile crash volume doesn't burn it; self-hosting explicitly not worth it (needs 4CPU/16GB, competes with the LLM box).

**Wiring:** systemd loop: boot emulator -> install APK -> Maestro/Patrol emulator pass, plus nightly real-phone pass. `adb logcat | grep FATAL/ANR` plus exit codes detect failures -> findings file -> local LLM (via LiteLLM) turns it into a fix task feeding function 1. Crashlytics/Vitals/Sentry polled via authenticated REST on a schedule — no MCP needed.

### 3. Observability + ops

- **Uptime Kuma** (self-hosted, Oracle VM) — unlimited HTTP/TCP/SSL monitors, 90+ notification integrations, REST/websocket API.
- **Prometheus + Grafana OSS + Loki + Grafana Alloy** (Oracle VM) — APM/logs/traces; also hosts a tiny exporter counting free-tier LLM calls so 429s become Grafana alerts. Grafana Cloud free tier is a drop-in fallback if the VM is under resource pressure.
- **Langfuse** (self-hosted or Cloud free hobby tier) — LLM observability (prompt/tokens/latency/cost/errors per call). Since Jan 2026 self-hosting needs ClickHouse too (heavier) — use Cloud free tier if that's too much for the VM.
- **ntfy.sh** — the phone-alert primitive, single HTTP POST, no SDK/OAuth.
- **Telegram Bot API** — redundant second alert channel with inline Approve/Reject buttons.
- **Healthchecks.io** (free, 20 checks) — dead-man's-switch catching "the agent process itself died," the one failure mode nothing else can see.
- **Google Cloud Billing Budgets API + Cloud Monitoring** on the Maps GCP project — 80%-of-credit alert via Pub/Sub -> Cloud Function -> ntfy/Telegram. **Budget alerts notify, they do NOT cap spend** — a hard circuit-breaker needs a self-implemented request-count check in the Express backend.
- **Runbooks-as-code** (`docs/runbooks/*.md`) — OSS replacement for Claude-Code-only `operations:runbook`; git-versioned Trigger/Diagnosis/Mitigation/Rollback docs, fed into context when an alert fires.

**Wiring:** All plain HTTP — no MCP required (though `grafana/mcp-grafana` and a Langfuse MCP exist if wanted). Google Cloud uses a service-account key + `gcloud`/REST (non-interactive, unlike OAuth-flow connectors).

### 4. Autonomous marketing/growth

- **Postiz** (self-hosted, AGPL-3.0, Oracle VM) — 33-platform scheduler, REST API/webhooks/n8n nodes; publish still gets a human glance pre-go-live.
- **Google Play Developer API** — reviews.list/reply — only channel to post visible replies (350-char cap); **draft-only, human sends**.
- **google-play-scraper** + free Keyword Planner + keywordtool.io free mode — paid ASO suites (MobileAction/AppTweak/Sensor Tower, $80-150+/mo) ruled out by budget; this combo is the real $0 ASO keyword pipeline.
- **Google Search Console API + SerpBear** (self-hosted rank tracker) — GSC covers indexing/CTR; SerpBear is unlimited keywords/domains, MIT, single Docker container.
- **n8n** (self-hosted, Oracle VM) — connective tissue, 400+ integrations, unlimited workflows self-hosted under fair-code license.
- **HARO via Featured.com** — free again since April 2025; 3x-daily journalist digests parsed via IMAP. **Sending stays human-approved** — no formal API, and a bad pitch permanently burns the relationship.
- **Playwright** (HTML/CSS -> PNG) — free substitute for Canva Connect API Autofill (Enterprise-only); 3-5 branded templates screenshotted headlessly.
- **Reddit .rss feeds** (unauthenticated) + Google Alerts — Reddit's priced API tier has a 2-4 week approval backlog; `.rss` suffix survived the 2023 pricing change unauthenticated. **Posting stays human-approved** — unsolicited bot posting risks shadowbans.

**Wiring:** n8n cron/webhook nodes drive Postiz/Play/GSC/Reddit-RSS via plain HTTP; the local LLM (via LiteLLM) is called for drafting only. The `marketing:*`/`small-business:canva-creator`/Ahrefs/Klaviyo/Similarweb MCP connectors in this Claude Code environment have no local-LLM equivalent — n8n plus the OSS picks above are the direct substitutes. Every send-side action keeps a human approval gate.

### 5. Autonomous monetization + analytics

- **PostHog Cloud (free plan)** — funnels, cohorts, retention, session replay, feature flags, AND experiments (A/B), all free up to 1M events/mo, no card required. GeoWake has zero product-analytics SDK today — from-scratch pick. Feature flags drive the pass-ladder prices; Experiments measures conversion per variant.
- **PostHog official MCP server** — query insights, update flags, create experiments, pull funnel data headlessly; static API-key auth (not OAuth) runs unattended in cron.
- **AdMob Reporting API v1** — only programmatic path to ad revenue; service-account OAuth2, no billing account required. Third-party OSS MCP wrappers hold revenue credentials — review source or call REST directly.
- **Google Play Developer API** — Android Publisher (purchases/orders/voidedPurchases) + Play Developer Reporting (vitals) — ground truth for IAP revenue, refund/chargeback netting, and crash/ANR-vs-conversion correlation. RTDN via Pub/Sub (10GB/mo free) can push purchase events live.
- **Nightly cron ingestion -> PostHog `/capture`** — unifies AdMob + Play data into one HogQL-queryable table tagged to the same distinct_id/cohort as product events.
- **RevenueCat free plan** (optional, not needed now) — only if renewal/proration bookkeeping outgrows the raw script; its Experiments feature is Pro-only ($99/mo+), so PostHog Experiments stays the pricing engine regardless.

**Wiring:** PostHog MCP runs as a local stdio process (npx/Docker) with a static API key. AdMob/Play ingestion is a ~50-line Python script (service-account JSON) on cron. A daily "pricing review" prompt (via LiteLLM) queries PostHog's insight/experiment tools and, if confident, patches the feature-flag payload — a closed loop on free tiers.

### 6. Autonomous customer support + community

- **Google Play Developer API** — reviews.list/reply — poll on cron, LLM drafts, human approves via Telegram/FreeScout, then reply fires. No Pub/Sub push for reviews exists.
- **FreeScout** (self-hosted PHP/Laravel) — the Intercom replacement: ~10MB footprint, shared inbox, built-in Knowledge Base, canned responses, REST API for drafts-as-private-notes.
- **Chatwoot CE** (alternative/complement) — if live-chat/omnichannel is wanted; needs ~4GB RAM/2vCPU, tight on the post-downgrade 12GB VM tier alongside everything else.
- **Reddit .rss feeds** — same unauthenticated pattern as function 4, for mention monitoring.
- **Telegram Bot API** — community FAQ bot (RAG over help docs) AND the human-approval UI for every drafted reply.
- **Local LLM (via LiteLLM)** — sentiment/classification/triage/drafting directly, structured JSON output (category/sentiment/severity/drafted_reply) for deterministic downstream routing; no paid sentiment API needed.
- **n8n** (same instance as function 4) — cron-polls every channel, calls LiteLLM for drafting, routes drafts to FreeScout/Telegram for approval, fires the send on approval.
- **Gmail API** (or IMAP) for support@ — Draft-via-API is a built-in approval gate if the inbox is Gmail rather than FreeScout's SMTP.

**Wiring:** Same n8n orchestrator as function 4. The approval gate — FreeScout draft a human sends, or Telegram inline Approve/Reject — is the direct OSS analogue of the Claude-Code-only `intercom` MCP / `schedule`/`loop` skills, neither callable by a local agent.

### 7. Orchestration backbone

- **systemd timers + .service units** (local box) — the real backbone; no network/account/quota dependency. `OnFailure=` fires a notify-unit on any non-zero exit; `Persistent=true` catches missed runs after sleep/reboot, unlike cron. More debuggable (`systemctl status`, `journalctl -u`).
- **Windmill** (self-hosted, Oracle VM) — for genuinely multi-step workflows (fetch -> transform -> LLM -> post -> notify): retries, run-history UI, secrets, ~287MB RAM footprint vs ~832MB for a comparable Temporal stack. Script-as-code version-controls cleanly; n8n's node model fights version control, Temporal is over-built for this scale.
- **mcpo** (open-webui/mcpo) — MCP-to-OpenAPI gateway; since Ollama/vLLM/LM Studio speak OpenAI-style function calling, not native MCP stdio, mcpo wraps any MCP server (Serena, PostHog MCP, a custom GeoWake-metrics MCP) as a plain REST endpoint the local LLM's tool-calling loop can hit.
- **healthchecks.io** — dead-man's-switch surviving even a fully-down home box.
- **GitHub Actions scheduled workflows** — off-box redundant trigger for anything that must fire when the home machine sleeps (Railway keepalive, Play Store status check); not for time-sensitive work (5-30 min drift is normal).
- **Uptime Kuma + ntfy.sh** — pull-based probing complementing healthchecks.io's push model; ntfy is the universal alert sink.
- **Claude Code `schedule` skill / scheduled-tasks MCP** — useful as a bridge today (zero setup in this environment) but Claude-Code-only and subscription-dependent; migrate logic into systemd+Windmill+mcpo once the local LLM is live.

**Wiring:** systemd timer -> runner script -> POST to LiteLLM -> model's tool calls resolved via mcpo's REST endpoints -> results loop back until done -> success pings healthchecks.io, failure curls ntfy.sh and exits non-zero (triggering `OnFailure=` too). **Note the June 2026 Oracle Always-Free downgrade (4 OCPU/24GB -> 2 OCPU/12GB)** — keep the VM to Windmill + Uptime Kuma + mcpo + lighter services; do heavier work (indexing, the LLM itself) on the home box.

### Design principles applied throughout

1. **One brain, many mouths** — every function calls the same LiteLLM endpoint; no per-function model wiring or vendor lock.
2. **MCP where MCP-native, plain REST/CLI everywhere else** — local runtimes don't speak MCP natively, mcpo bridges it; most functions don't need MCP at all.
3. **Human-in-the-loop is load-bearing on every outbound/public/financial action** — Play replies, HARO pitches, Reddit posts, social publishes, and PRs touching alarm/EKF/auth/payment logic are all gated behind an explicit approve step, consistent with this repo's own documented never-late safety invariants.
4. **Self-hosted beats free-cloud-tier only when it doesn't compete for the same 8-32GB the LLM needs** — the Sentry/Langfuse/PostHog self-host-vs-cloud calls in this deck always protect the LLM's own resource budget.

## Whole-stack architecture

```
HOME LINUX BOX (16-32GB RAM, RTX 4060 8GB) — always-on, the actual "24/7 brain"
├── llama-server (llama.cpp, CUDA build)  :8080   — Qwen3-Coder-30B-A3B / GLM-4.7-Flash GGUF, --n-cpu-moe offload
├── LiteLLM proxy  :4000  — OpenAI-compatible router
│      fallback chain: local-coder -> Groq -> Cerebras -> Gemini-2.5-Flash -> OpenRouter(:free)
├── mcpo  :8000  — MCP-to-OpenAPI gateway (wraps Serena / PostHog MCP / GeoWake-metrics MCP)
├── Serena MCP (LSP: Dart analysis_server, typescript-language-server)
├── systemd timers/services (the real scheduler)
│      ├─ code-maintenance.timer   -> orchestrator.py -> osv-scanner/Semgrep/dart analyze/Trivy/gitleaks
│      │                              -> mini-swe-agent -> aider -> gh pr create
│      ├─ behaviour-validation.timer -> emulator boot -> adb install -> Maestro + Patrol
│      │                                 (+ nightly pass against spare phone over adb/WiFi)
│      ├─ marketing-support.timer  -> n8n webhook trigger
│      ├─ monetization.timer       -> AdMob+Play ingestion script -> PostHog /capture
│      └─ OnFailure=  -> ntfy-notify.service (every unit)
├── One spare Android phone (adb connect over WiFi, screen-off, always powered)
│      -> nightly Patrol "arm alarm, background, kill, verify fired" loop (real OEM battery-killer test)
└── Self-hosted GitHub Actions runner (registered to the private WakePoint/GeoWake repo)
       -> flutter test / dart analyze / Semgrep / osv-scanner / Trivy / gitleaks on every agent PR

           |  git push / PR / webhook               |  HTTP (REST, no MCP needed)
           v                                          v
GITHUB (private repo)                    ORACLE ALWAYS-FREE ARM VM (2 OCPU/12GB post-downgrade)
├── GitHub Actions (cloud, ~2000 min/mo) ├── n8n (self-hosted)         — glue: cron+webhook -> REST calls
│    -> reactivecircus/android-          │      (Postiz, Play API, GSC, Reddit RSS, FreeScout, Gmail)
│       emulator-runner (PR-gate only)   ├── Windmill (self-hosted)    — multi-step LLM workflows w/ retries
├── Dependabot (version-updates, free)   ├── Uptime Kuma               — HTTP/TCP probes, 90+ notif integrations
└── gh CLI (polled by home-box scripts)  ├── Prometheus + Grafana + Loki + Alloy  — metrics/logs/traces + LLM-quota exporter
                                         ├── Langfuse (or Cloud free tier)  — LLM call tracing
                                         ├── Postiz                    — 33-platform social scheduler
                                         ├── SerpBear                  — self-hosted rank tracker
                                         └── FreeScout (or Chatwoot CE) — support inbox + KB/FAQ

FREE CLOUD APIs / SaaS (all $0 tier, service-account or static-key auth — no interactive OAuth)
├── Groq / Cerebras / Gemini / OpenRouter   — LLM fallback tiers (behind LiteLLM)
├── Google Play Developer API               — reviews.list/reply, Android Publisher, Play Developer Reporting
├── AdMob Reporting API v1                  — ad revenue
├── PostHog Cloud (free, 1M events/mo)      — funnels/cohorts/flags/experiments + official MCP server
├── Firebase Crashlytics + Android Vitals   — mobile crash/ANR (unlimited free)
├── Firebase Test Lab (Spark)               — 5 physical + 10 virtual device runs/day
├── Sentry Developer (free, 5K events/mo)   — backend-only errors
├── Healthchecks.io (free, 20 checks)       — dead-man's-switch for every scheduled job
├── ntfy.sh / Telegram Bot API              — phone alerting + human-approval inline buttons
├── Google Cloud Billing Budgets/Monitoring — Maps quota guardrail (notify-only, no auto-cap)
└── HARO/Featured.com, Reddit .rss, GSC API — inbound signal for marketing/support (outbound = human-gated)

PRODUCTION
└── Railway (Express backend, existing host) <-- monitored by Uptime Kuma + Sentry(backend) + GH Actions keepalive

HUMAN-APPROVAL GATES (Telegram inline buttons / FreeScout draft-send / manual review) sit in front of:
  Play Store review replies · HARO pitches · Reddit posts · Postiz-queued publishes ·
  any PR touching alarm/reachability/EKF/auth/payment logic · Maps hard-spend circuit-breaker changes
```

## Gaps & risks

- No hard spend cap on Google Maps: Cloud Billing Budgets only notify at a threshold, they do not disable the API key or cap usage — a traffic spike could turn $0 into a real bill unless the founder self-implements a request-count circuit-breaker in the Express backend.
- Free-tier LLM numbers (Groq RPM/TPM, Cerebras daily tokens, Gemini RPD, OpenRouter RPD) reshuffle roughly monthly per the sources checked 2026-07-24 — the LiteLLM router pattern is durable but any hardcoded limit in agent logic will silently go stale and cause mid-task 429s until re-verified.
- Ollama cannot be the production tool-calling runtime for GLM-family models due to its XML tool-call envelope gap — this constrains the stack to llama.cpp, which is more setup/maintenance burden for a solo founder than the 'easy button' Ollama path.
- Self-hosted GitHub Actions runner is a real security surface: it executes agent-produced code with repo push/PR-create credentials on the same machine that also holds Play/AdMob/GitHub API keys — a compromised or prompt-injected agent run has a large blast radius (e.g. a malicious PR description, a poisoned dependency, or injected text in a scraped Play review/Reddit post feeding into a privileged prompt) unless the runner is sandboxed/isolated from the LLM's own credential store.
- Oracle Always-Free ARM tier was downgraded mid-2026 (4 OCPU/24GB -> 2 OCPU/12GB for new/some existing free accounts) — the VM now has to be carefully rationed across n8n + Windmill + Uptime Kuma + Prometheus/Grafana/Loki/Alloy + Langfuse + Postiz + SerpBear + FreeScout/Chatwoot; running all of them simultaneously likely will not fit in 12GB and needs pruning or moving some services to the home box.
- Self-hosted Langfuse now requires a ClickHouse instance (since the Jan 2026 ClickHouse acquisition) which is materially heavier than the old Postgres-only deployment — likely too heavy for the downgraded Oracle VM, pushing toward Langfuse Cloud's free hobby tier as the practical default rather than the 'ideal' self-hosted option originally scoped.
- Reddit monitoring relies on the unauthenticated .rss workaround, not the official API — this is explicitly outside Reddit's priced/supported surface and could be throttled or removed without notice, silently breaking brand-mention monitoring with no warning channel.
- google-play-scraper is an unofficial scraper against Play Store's web layout and is documented to break on Play Store UI changes — the ASO keyword pipeline has a standing fragility risk with no official fallback at $0.
- Third-party OSS MCP wrappers for AdMob and Play Developer API (e.g. community admob-mcp / play-store-mcp repos) would hold live revenue-account credentials if used — these are unverified third-party code and should be source-reviewed or bypassed in favor of calling the official REST APIs directly.
- Several functions are irreducibly human-in-the-loop by design (Play review replies, HARO pitches, Reddit posts, social publishes, and any PR touching alarm/reachability/EKF/auth/payment code) — the stack automates drafting/triage but not full autonomy on these paths; the 24/7 system still needs the founder to tap 'approve' regularly or a backlog accumulates.
- Google Play Developer API and AdMob Reporting API both require one-time interactive OAuth/service-account setup in Google Cloud Console by a human before they can run headlessly — not zero-config despite being 'free forever' once set up.
- No native Pub/Sub push exists for Play Store reviews (only for purchases/subscriptions via RTDN) — review monitoring is permanently polling-based, with a ceiling of 200 GET/hr that is ample now but is a scaling constraint if GeoWake's review volume grows substantially.
- Sentry's free tier (5K events/month) is scoped to the backend only specifically to protect the cap; if backend error volume itself spikes (e.g. a bad deploy causing repeated 500s), the cap can be exhausted within the same incident that most needs visibility, right when it matters most.
- The overall design substitutes a large number of small self-hosted services (Uptime Kuma, Windmill, n8n, Langfuse, Postiz, SerpBear, FreeScout/Chatwoot, Prometheus/Grafana/Loki/Alloy) for paid SaaS — this trades subscription cost for real solo-dev ops burden (Docker upgrades, disk/RAM management, occasional breakage) that a fully-autonomous system does not eliminate, it just relocates from 'pay a vendor' to 'the founder is the SRE.'
- Prompt-injection surface: content ingested from public/adversarial sources (Play Store reviews, Reddit posts, GitHub issues/PR comments, HARO query emails) is fed into prompts for an agent that also holds tool access to push code, reply publicly, and touch revenue systems — none of the tools in this deck include an explicit injection-defense layer beyond the human-approval gates, which is the real mitigation and must not be weakened for convenience.

## First 10 installs (ordered by automation ROI)

1. 1. Provision the Oracle Always-Free ARM VM (verify current tier: 2 OCPU/12GB post-June-2026-downgrade) — the foundation every self-hosted service below needs; do this before anything else.
2. 2. Install llama.cpp (CUDA build) + pull Qwen3-Coder-30B-A3B-Instruct GGUF (Unsloth Q4_K_M) on the home box, run llama-server as a systemd service with --n-cpu-moe tuned for 8GB VRAM/32GB RAM — this is the brain every other function depends on.
3. 3. Install LiteLLM proxy in front of llama-server with a litellm_config.yaml fallback chain (local -> Groq -> Cerebras -> Gemini -> OpenRouter free); register free API keys for all four cloud fallbacks (no credit card needed for any) — makes the brain resilient before wiring anything to it.
4. 4. Set up systemd timers + healthchecks.io (free 20-check tier) + ntfy.sh topic — the orchestration/alerting skeleton that every later job pings into, so nothing fails silently from day one.
5. 5. Register a self-hosted GitHub Actions runner on the home box/VM against the private WakePoint/GeoWake repo — unblocks unlimited CI minutes, which the entire autonomous code-maintenance loop needs to function at all.
6. 6. Install and wire osv-scanner + Semgrep CE + Trivy + gitleaks + dart analyze as a systemd-timer-triggered scan pipeline feeding a task queue, then mini-swe-agent + aider pointed at the LiteLLM endpoint for the fix loop — the single highest-ROI function (continuous bug/CVE/dep-update coverage) becomes live.
7. 7. Create Google Cloud service-account credentials for the Play Developer API (reviews.list/reply, Android Publisher, Play Developer Reporting) and the AdMob Reporting API v1 — one human-driven setup step that unlocks review monitoring, IAP revenue truth, vitals, and ad revenue for every downstream function.
8. 8. Sign up for PostHog Cloud (free tier, no card) and run the official PostHog MCP server locally via mcpo — gives the local LLM one queryable store for funnels/cohorts/flags/experiments and is the engine for the pass-ladder pricing experiments.
9. 9. Install n8n (self-hosted, Community Edition) on the Oracle VM and wire its first cron workflow: poll Play reviews -> draft via LiteLLM -> post to Telegram for one-tap approval -> reviews.reply on approval — proves the human-in-the-loop pattern end-to-end on the function most exposed to the public.
10. 10. Deploy Uptime Kuma on the Oracle VM monitoring the Railway backend + Play Store availability, and set up the local Android emulator + Maestro/Patrol loop plus the spare-phone adb-connect real-device reliability test — closes the observability and behaviour-validation gaps that protect the app's core never-late promise.