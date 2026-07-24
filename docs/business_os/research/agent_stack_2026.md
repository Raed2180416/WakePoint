## Zero-Cost 24/7 Autonomous Dev+Business Agent Stack — SOTA as of 2026-07-24

### Bottom line up front

At true $0 cost, on a single Linux machine, the realistic stack is:

- **Orchestration:** systemd timers (not n8n) triggering shell scripts, with **GitHub Actions** (2,000 free min/mo on the Free plan for private repos) as a secondary orchestrator for anything that must run in a clean container or survive the machine being off.
- **Agent runtime:** **OpenCode CLI** (`opencode serve` / `opencode run`) as the primary headless driver; **mini-swe-agent** as a minimal ~100-line fallback for narrowly-scoped fix loops ("make CI green"); **Aider** (`--message` + `--yes-always` + `--auto-test`) for scripted, git-native single-PR edits.
- **Models:** OpenCode Zen's rotating free models as the primary $0 tier, with Gemini 2.5 Flash and Groq (Llama 3.3 70B) as fallback rungs via a router, and a locally-hosted Qwen3-Coder (30B-A3B MoE, quantized) as the offline last resort on a 16–32GB CPU box.
- **Router:** self-hosted **LiteLLM** proxy (free, open-source core) chaining OpenCode Zen → Groq → Gemini → Cerebras → local Ollama with fallback/cooldown.
- **Watchdog:** wrapper scripts with hard `timeout`, heartbeat log lines, and `systemd` `OnFailure=` units — none of Claude Code, OpenCode, or Aider ship a built-in hang-recovery mechanism.
- **Explicitly NOT recommended as the unattended engine: Claude Code.** As of **June 15, 2026**, Anthropic moved `claude -p` (headless mode), the Agent SDK, and Claude Code GitHub Actions off standard subscription usage and onto a separate, non-rolling-over monthly credit pool billed at API rates ($20 Pro / $100 Max 5x / $200 Max 20x). This breaks the $0 constraint for any cron/CI-driven Claude Code loop. Interactive terminal/IDE use is unaffected and stays on the subscription — so Claude Code remains fine as an occasional human-supervised reviewer, just not as the always-on driver.

---

### 1. OpenCode CLI (opencode.ai)

- Go-based CLI, 75+ LLM providers behind one interface; as of July 2026 it's reported as the most-starred coding agent on GitHub (182K+ stars, ~8M monthly users) per secondary sources — treat the popularity number as an estimate, not verified against GitHub's own counter. [opencode.ai/docs/cli](https://opencode.ai/docs/cli/), [opencode-primer](https://github.com/wesammustafa/opencode-primer)
- **Headless/server mode:** `opencode serve` runs a headless HTTP server exposing an OpenAPI 3.1 spec (e.g. `http://localhost:4096/doc`); can be locked down with `OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME` for basic auth. `opencode run` executes a single non-interactive prompt and exits — the CI-friendly form. [open-code.ai/docs/server](https://open-code.ai/en/docs/server), [open-code.ai/docs/cli](https://open-code.ai/en/docs/cli)
- **GitHub integration:** ships a GitHub Action that triggers on issue/PR comments containing `/opencode` or `/oc`, on `pull_request` events, or on `schedule` (cron) — runs inside your own Actions runner using the built-in `GITHUB_TOKEN`, no separate app install required. This is a real, usable "issue → branch → PR" loop today. [opencode.ai/docs/github](https://opencode.ai/docs/github/), [DeepWiki: GitHub Action Integration](https://deepwiki.com/anomalyco/opencode/6.4-github-action-integration)

### 2. OpenCode Zen free models

Confirmed free-tier roster (base URL `https://opencode.ai/zen/v1`): **Big Pickle** (stealth model, context unspecified), **DeepSeek V4 Flash** (1M context), **MiMo-V2.5** (1M context), **Laguna S 2.1** (context unspecified), **Nemotron-3-Ultra** (1M context, NVIDIA-hosted — logged "for security purposes and to improve NVIDIA products"), **North Mini Code** (256K context), and a newer **Hy3 preview** (256K context) not in your original list. [opencode.ai/docs/zen](https://opencode.ai/docs/zen/), [freellm.net/providers/opencode](https://freellm.net/providers/opencode)

**Important gap — could not verify:** neither OpenCode's own docs nor third-party aggregators publish concrete per-model rate limits (RPM/RPD/TPM). Docs explicitly state "free-tier limits are not published per model," and a live GitHub issue (`anomalyco/opencode#13318`, "Keep getting rate limited on Zen") plus a related header-compatibility bug (`earendil-works/pi#2824`) confirm rate limiting exists and is opaque/fragile in practice — expect throttling under any real automation load, and treat "free" as "free but unpredictable," not a guaranteed capacity number. All six models are explicitly framed as **limited-time promotional free tiers**, several with data-retention/training caveats — do not route anything sensitive (e.g., GeoWake user mobility data) through them, and do not assume they'll still be free in 6 months.

### 3. Crush CLI (charm.land / charmbracelet)

- Open-source terminal coding agent, config schema at `https://charm.land/crush.json`, supporting OpenAI-compatible and Anthropic-compatible provider types (`openai` vs `openai-compat` distinguishes routed-through-OpenAI vs OpenAI-shaped third-party APIs). [GitHub: charmbracelet/crush](https://github.com/charmbracelet/crush)
- **Headless mode:** `crush run "<prompt>"` sends one prompt and prints the response to stdout — this is the CI-usable non-interactive entrypoint; a `CRUSH_CLIENT_SERVER` env var switches it to stream from a remote server instead of running locally. [DeepWiki: CLI Usage](https://deepwiki.com/charmbracelet/crush/2.2-cli-usage)
- Weaker documented GitHub-Action story than OpenCode as of this search — no equivalent first-party issue/PR automation workflow surfaced. Use it as a secondary CLI, not the primary orchestrator.

### 4. Claude Code non-interactive / SDK — pricing reality (the load-bearing finding)

- `claude -p` / `--print` runs the full agent loop non-interactively and is the standard pattern for scripts/cron/CI. [buildthisnow.com guide](https://www.buildthisnow.com/blog/guide/development/claude-code-headless-mode)
- **June 15, 2026 billing change** (multiple corroborating secondary sources, dated May–June 2026): Anthropic split off four surfaces — the Agent SDK (Python/TS), `claude -p` headless mode, Claude Code GitHub Actions, and third-party apps authenticating via the Agent SDK — into a **separate monthly credit pool** billed at standard API rates: **$20/mo (Pro), $100/mo (Max 5x), $200/mo (Max 20x)**, non-rolling. Interactive terminal/IDE Claude Code is unaffected and still draws from normal subscription limits. [techtimes.com](https://www.techtimes.com/articles/317625/20260602/anthropic-ends-subscription-subsidy-agents-june-15-credit-pool-replaces-flat-rate-access.htm), [totalum.app](https://www.totalum.app/blog/claude-agent-sdk-credits-2026), [codersera.com](https://codersera.com/blog/anthropic-june-2026-billing-change-claude-code/)
- Practical implication cited: a Max 20x subscriber's $200/mo automation credit is estimated at roughly **222 Opus-4.8-rate headless bug-fix runs/month** — i.e., even paid tiers are throughput-capped for autonomous use, and there is **no free tier at all** for headless/SDK/Actions usage. [cloudzero.com](https://www.cloudzero.com/blog/claude-code-pricing/)
- **Verdict for GeoWake's $0 constraint:** exclude Claude Code from the always-on loop. Use it interactively (human-supervised) for high-stakes review/design work where you're paying for the subscription anyway, not for nightly automation.

### 5. mini-SWE-agent (SWE-agent/mini-swe-agent)

- Genuinely minimal: ~100 lines of Python, no heavy framework, >74% on SWE-bench Verified; supports local/docker/podman/singularity/apptainer/bubblewrap sandboxing and routes models through litellm, OpenRouter, Portkey, etc. Adopted internally (per project claims) by Meta, NVIDIA, Essential AI, IBM, Nebius, Anyscale, Princeton, Stanford. [github.com/SWE-agent/mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent), [docs.litellm.ai/docs/projects/mini-swe-agent](https://docs.litellm.ai/docs/projects/mini-swe-agent)
- **Could not verify** a specific "v2.4.x" release note or changelog entry in this search pass — the repo's public docs reference a general v2/v1 split rather than a confirmed v2.4.x tag; treat the exact version number in your prompt as unconfirmed until checked directly against `github.com/SWE-agent/mini-swe-agent/releases`.
- Good fit for GeoWake: cheap enough (in code-complexity terms) to run against a free/rotating model without much wrapper overhead, and its litellm-native design plugs directly into the router recommended below.

### 6. OpenHands (formerly OpenDevin)

- Model-agnostic; supports Claude, GPT-4o, Gemini, Mistral, and **local models via Ollama/LM Studio/vLLM/SGLang**. As of the May 2026 product update, the team's recommended first local model is **Qwen3.6-35B-A3B**, an open-weight MoE built for agentic coding with a large context window. [openhands.dev/blog — May 2026 update](https://www.openhands.dev/blog/openhands-product-update---may-2026), [docs.openhands.dev/openhands/usage/llms/local-llms](https://docs.openhands.dev/openhands/usage/llms/local-llms)
- New profile-management UX: save/switch multiple LLM configs via a `/model` chat command — useful if you want one OpenHands instance juggling several free-tier keys without hand-editing config files each run.
- Heavier than OpenCode/mini-swe-agent/Aider for a solo $0 setup — better suited if you specifically want its browser/GUI-driving agent capabilities; for straight code-fix loops the lighter tools are less operational overhead.

### 7. Aider

- Actively maintained as of 2026 — frequent (multi-weekly) releases, ~44K GitHub stars, cited ~6.8M PyPI installs and ~15B tokens/week flowing through it; broad model support (GPT, Claude, DeepSeek, Gemini) plus expanding language coverage (MATLAB, Clojure added). [aifordevelopers.org](https://aifordevelopers.org/tool/github-com-paul-gauthier-aider), [nxcode.io tutorial](https://www.nxcode.io/resources/news/aider-complete-tutorial-guide-install-setup-2026)
- **Scriptable/headless pattern confirmed:** `aider --message "<instruction>" --yes-always --auto-test --test-cmd "flutter test"` — single-pass, no interactive confirmation, exits cleanly. This is directly usable as a nightly "fix failing tests" cron job. [aider.chat/docs/scripting.html](https://aider.chat/docs/scripting.html)
- Best-fit role in the stack: the git-native, diff-disciplined tool for small scoped patches (one file, one test fix), rather than the general orchestrator.

### 8. n8n vs systemd timers + scripts

- For a solo dev with near-zero budget, secondary-source consensus (mid-2026) is: **systemd timers are the practical default** for infra/customer-facing scheduled jobs (journald logging, missed-run recovery via `Persistent=true`, dependency ordering), with plain `cron` still fine for trivial personal jobs. [stackademic.com](https://blog.stackademic.com/cron-vs-systemd-timers-what-every-developer-should-know-before-choosing-f75ae7168c26), [crongen.com](https://www.crongen.com/blog/cron-vs-systemd-timers-2026)
- n8n is pitched as superior once you're at high execution volume (50,000+ ops/month) or need visual multi-step integrations with many SaaS nodes — that's not GeoWake's current shape. For a single machine running a handful of nightly agent jobs, n8n adds a persistent Node.js service, its own DB, and UI surface area for no real benefit over `systemd timer + bash script + agent CLI`. **Recommendation: skip n8n**, keep systemd timers, and only reach for n8n later if you need to fan out into many third-party API integrations (e.g., ad networks, Play Console reporting) with visual debugging.

### 9. GitHub Actions free tier as orchestrator

- Confirmed unchanged in 2026: **2,000 free Linux minutes/month** on private repos on the Free plan, 500MB artifact storage; Linux minutes count 1x, Windows 2x, macOS 10x against the quota. Overage rate cut on 2026-01-01 to **$0.006/min** all-in (down from $0.008). [docs.github.com billing](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions), [cicdcalculator.com free-tier](https://cicdcalculator.com/github-actions-free-tier)
- **Flutter test budget check (estimate, not directly sourced):** a typical Flutter `flutter test` run for a mid-size app is commonly 2–6 minutes on a GitHub-hosted Linux runner including setup/caching; a nightly run would burn roughly 60–180 min/month, leaving comfortable headroom under 2,000 min for nightly test + occasional opencode-action issue-fix runs. This is a reasonable-engineering-judgment estimate — actual GeoWake CI timing should be pulled from your own Actions run history (`.github/workflows/ci.yml`) rather than assumed.
- Verdict: GitHub Actions' free tier is **sufficient as a secondary/backup orchestrator** (nightly test gate, occasional issue-to-PR runs) but not as the primary 24/7 loop — a systemd-timer-driven local process is the always-on layer; GitHub Actions is the "runs even if my laptop is off" safety net.

### 10. Local LLM state — CPU-only on 16–32GB RAM (2026)

- **Qwen3-Coder-30B-A3B** (MoE, only ~3B active params) is the commonly recommended CPU-feasible coding model for consumer hardware. Reported speeds (from user benchmarks, not vendor-verified): **~12–15 tok/s** on a 32GB DDR4/DDR5 system with a modern desktop CPU (e.g., Ryzen 9 7950X3D, even a Ryzen 5 5600G) at appropriate quantization; heavier quantization (Q2_K/Q4_K_M) with limited context can reach 15–25 tok/s but with quality tradeoffs. 16GB systems are workable only with aggressive quantization and reduced context, at slower speed. [arsturn.com](https://www.arsturn.com/blog/running-qwen3-coder-30b-at-full-context-memory-requirements-performance-tips), [unsloth.ai docs](https://unsloth.ai/docs/models/tutorials/qwen3-coder-how-to-run-locally)
- A larger MoE variant, **Qwen3-Coder-Next (Qwen3-Next-80B)**, is reported to run notably slower on CPU than expected — a live llama.cpp GitHub issue (`ggml-org/llama.cpp#19480`) documents ~5x-worse-than-expected CPU inference on consumer hardware, and one 96GB-RAM CPU-only benchmark reported only ~10 tok/s. Treat the 80B-class model as impractical for a 16-32GB CPU-only box; **stick to the 30B-A3B size class**.
- **Practical read for GeoWake:** local Qwen3-Coder-30B-A3B on a 32GB desktop is a legitimate offline fallback for simple, well-scoped edits (single-file fixes, doc generation) at roughly 12-15 tok/s — usable but noticeably slower than any cloud free-tier model; use it as the last-resort rung in the router chain, not the default.

### 11. LiteLLM router for free-tier rotation

- LiteLLM (SDK + self-hosted proxy) is free/open-source (no licensing cost for the core), supports 100+ providers behind one OpenAI-compatible API, and provides router-level load balancing, retries, cooldowns, ordered fallback chains, budget/spend tracking, and observability integrations (Langfuse, MLflow). [docs.litellm.ai/docs/routing-load-balancing](https://docs.litellm.ai/docs/routing-load-balancing), [docs.litellm.ai/docs/proxy/reliability](https://docs.litellm.ai/docs/proxy/reliability)
- Recommended fallback chain for GeoWake's router config: **OpenCode Zen free models → Groq (Llama 3.3 70B) → Gemini 2.5 Flash → Cerebras (gpt-oss-120b/GLM-4.7) → local Ollama (Qwen3-Coder-30B-A3B)**, each rung triggering on rate-limit/error via LiteLLM's `fallbacks` config.

### 12. Free-tier limits verified for July 2026 (exact numbers, with caveats)

| Provider | Verified limit | Source note |
|---|---|---|
| **Groq** (general free tier) | 30 RPM / 14,400 RPD; TPM capped ~6,000 for most models | [tokenmix.ai](https://tokenmix.ai/blog/groq-free-tier-limits-2026) |
| **Groq** (`llama-3.3-70b-versatile`, as of 2026-06-04) | 30 RPM, 1,000 RPD, 12,000 TPM, 100,000 TPD | Model-specific, dated snapshot — [tokenmix.ai](https://tokenmix.ai/blog/groq-free-tier-limits-2026) |
| **Cerebras** (free) | ~1M tokens/day; 5 RPM / 30,000 TPM (per most-recent docs, June 2026 — older sources still cite 30 RPM, likely stale); 8,192-token context cap; applies to `gpt-oss-120b` and `GLM-4.7` only | [pricepertoken.com](https://pricepertoken.com/endpoints/cerebras/free), [tokenmix.ai](https://tokenmix.ai/blog/cerebras-api-key-rate-limits-free-tier-2026) |
| **Gemini 2.5 Flash** (free) | 10 RPM / 250 RPD; all free-tier models share 250,000 TPM and 1M-token context | Reported reduction: Google cut free-tier quotas 50-80% on 2025-12-07, so these are the *post-cut* numbers | [tokenmix.ai](https://tokenmix.ai/blog/gemini-api-free-tier-limits) — **note:** Google's own rate-limits doc (fetched 2026-07-21) does not publish exact numbers and instead points users to a personal AI Studio dashboard, so treat the 10 RPM/250 RPD figures as third-party-reported, not primary-source-confirmed |
| **OpenCode Zen free models** | Not published per model; docs explicitly say limits aren't disclosed, and a live GitHub issue confirms real-world throttling | [opencode.ai/docs/zen](https://opencode.ai/docs/zen/), GitHub issue `anomalyco/opencode#13318` |

**Caveat that matters for planning:** Gemini's own current documentation (fetched directly, last-updated 2026-07-21 UTC) does **not** publish the RPM/RPD numbers publicly — it tells you to check your personal quota in AI Studio. The 10 RPM / 250 RPD figures above come from third-party trackers, not Google's primary docs, so verify against your own AI Studio dashboard before depending on them for GeoWake's pipeline.

### 13. Watchdog patterns for unattended agents

- This is a real, currently-unsolved pain point, not a solved problem you can just configure away. Open, live GitHub issues confirm both **Claude Code** (`anthropics/claude-code#28482`: "Agent hangs indefinitely mid-task — no recovery path without Esc," and `#49150`: "Task() tool has no timeout") and by extension similar CLI agents lack built-in hang detection. [github.com/anthropics/claude-code/issues/28482](https://github.com/anthropics/claude-code/issues/28482), [#49150](https://github.com/anthropics/claude-code/issues/49150)
- Recommended concrete pattern for GeoWake's systemd-timer-driven jobs:
  1. Wrap every agent invocation in `timeout --signal=KILL <N>m <agent-cmd>` (hard ceiling — e.g. 20 min for a single-file fix, 60 min for a full nightly test-and-patch pass).
  2. Have the wrapper script emit a heartbeat line to a log file every N minutes (a background `while` loop with `sleep` + `date` >> log, killed when the main process exits) so a separate `systemd timer` "log watcher" can detect silence and alert (e.g. via a free ntfy.sh push or a git commit of a status file) rather than trusting the agent's own progress claims.
  3. Set `OnFailure=` on each systemd service unit to trigger a lightweight notifier unit on non-zero exit *or* timeout-kill, rather than silently retrying indefinitely.
  4. For multi-agent chains (e.g., OpenCode fixes → Aider tests → GitHub Action verifies), treat each stage as independently watchdog-wrapped — the "silent pipeline stall" failure mode (a stage hangs without erroring) is explicitly called out as a distinct risk from single-agent hangs in current practitioner writeups. [rz-ai-learning.com watchdog layer](https://rz-ai-learning.com/posts/watchdog-multi-agent-monitoring/), [dev.to production-failure lessons](https://dev.to/bobrenze/how-ai-agents-handle-stalled-tasks-and-timeouts-lessons-from-my-production-failure-1jj9)

---

### Concrete recommended stack (final)

| Layer | Choice | Why |
|---|---|---|
| Scheduler | systemd timers (local, always-on machine) + GitHub Actions (2,000 free min/mo, off-machine backup) | Lower overhead than n8n at GeoWake's scale; Actions covers "laptop is off" gap |
| Primary agent CLI | OpenCode CLI (`opencode run` / `opencode serve`) | Best-documented free-model access + native GitHub Action issue→PR flow |
| Scoped fix-loop agent | mini-swe-agent | ~100 LOC, litellm-native, cheap to run against any free rung |
| Git-native patch tool | Aider (`--message --yes-always --auto-test`) | Best for single scoped test-fix commits, mature scripting docs |
| Model router | Self-hosted LiteLLM proxy | Free, handles fallback chain across all providers below |
| Free cloud models (priority order) | OpenCode Zen free roster → Groq Llama-3.3-70B → Gemini 2.5 Flash → Cerebras gpt-oss-120b | Rotate on rate-limit; none guaranteed to stay free — re-verify monthly |
| Offline fallback | Local Qwen3-Coder-30B-A3B via Ollama, ~12-15 tok/s on 32GB CPU box | Works when all cloud free tiers are exhausted/down |
| Explicitly excluded from the 24/7 loop | Claude Code headless/SDK/Actions | No free tier since 2026-06-15; billed against a capped, non-rolling monthly credit pool even on paid plans |
| Watchdog | `timeout` + heartbeat log + systemd `OnFailure=` | No agent CLI ships hang-detection; this is a known open gap (live GitHub issues) |

### Realistic throughput at $0 (estimates, not guaranteed)

- **Cloud free-tier agent turns/day:** roughly 1,000–1,400 lightweight requests/day achievable by combining Groq's ~14,400 RPD headroom (rarely fully usable due to TPM ceiling) with Gemini's ~250 RPD and OpenCode Zen's undisclosed-but-real capacity — plan for **low hundreds of meaningful agent invocations/day**, not thousands, once TPM/context ceilings (Cerebras' 8K-token cap is notably restrictive) are accounted for.
- **GitHub Actions nightly CI:** comfortably fits within 2,000 free min/month for a Flutter test suite plus occasional opencode-action PR runs, assuming per-run times in the low single-digit minutes (verify against GeoWake's actual `.github/workflows/ci.yml` run history rather than this estimate).
- **Local model:** ~12-15 tok/s is workable for single-file patches and doc generation but too slow for large multi-file refactors — reserve it for the "everything else is rate-limited or down" case.

### What could not be fully verified in this pass

- Exact numeric rate limits (RPM/RPD/TPM) per individual OpenCode Zen model — not published by OpenCode itself.
- A confirmed "v2.4.x" version tag for mini-swe-agent — repo docs reference v1/v2 generally; exact patch version unconfirmed.
- Gemini's exact free-tier RPM/RPD from Google's own primary docs — Google's page (fetched 2026-07-21) defers to a personal AI Studio dashboard rather than publishing numbers; the 10 RPM/250 RPD figures cited here are third-party.
- Real-world GeoWake-specific `flutter test` CI run duration — estimated from general Flutter CI norms, not pulled from this repo's actual Actions history.

## KEY FACTS
- [likely] Claude Code headless mode (claude -p), the Agent SDK, and Claude Code GitHub Actions moved off subscription usage onto a separate, non-rolling monthly credit pool ($20/$100/$200 by plan tier) effective June 15, 2026 — this rules out Claude Code as a $0 unattended-agent engine. (techtimes.com, totalum.app, codersera.com (multiple corroborating secondary sources, May-June 2026))
- [verified] GitHub Actions Free plan (private repos) provides 2,000 Linux-equivalent minutes/month and 500MB artifact storage, unchanged in 2026; overage cut to $0.006/min on 2026-01-01. (docs.github.com billing page; cicdcalculator.com)
- [likely] OpenCode Zen's free model roster is Big Pickle, DeepSeek V4 Flash, MiMo-V2.5, Laguna S 2.1, Nemotron-3-Ultra, North Mini Code, plus a newer Hy3 preview — but per-model rate limits are not published by OpenCode, and a live GitHub issue confirms real throttling in practice. (opencode.ai/docs/zen, freellm.net, GitHub issue anomalyco/opencode#13318)
- [likely] OpenCode ships a first-party GitHub Action that triggers on /opencode or /oc comments, PR events, or cron schedule, running an issue-to-PR loop inside your own Actions runner using the built-in GITHUB_TOKEN. (opencode.ai/docs/github, DeepWiki GitHub Action Integration page)
- [estimate] Qwen3-Coder-30B-A3B (MoE) is the practical CPU-only coding model for a 16-32GB RAM desktop, reported at ~12-15 tok/s on 32GB DDR4/DDR5 with a modern CPU at appropriate quantization. (arsturn.com, unsloth.ai docs — user-reported benchmarks, not vendor-verified)
- [estimate] Groq free tier: ~30 RPM / 14,400 RPD general, with model-specific limits (e.g. llama-3.3-70b-versatile at 30 RPM/1,000 RPD/12,000 TPM/100,000 TPD as of 2026-06-04). (tokenmix.ai blog posts, dated snapshots, not Groq primary docs)
- [estimate] Cerebras free tier: ~1M tokens/day, 5 RPM/30,000 TPM per most recent docs (June 2026), 8,192-token context cap, limited to gpt-oss-120b and GLM-4.7. (pricepertoken.com, tokenmix.ai)
- [estimate] Gemini API's own current rate-limits documentation (fetched 2026-07-21) does not publish exact free-tier numbers; it directs users to a personal AI Studio dashboard. Third-party trackers report Gemini 2.5 Flash free tier at 10 RPM/250 RPD with a shared 250,000 TPM across models. (ai.google.dev/gemini-api/docs/rate-limits (primary, no numbers published); tokenmix.ai (secondary, numbers))
- [verified] Neither Claude Code nor OpenCode has built-in hang/timeout recovery for unattended runs — confirmed by live open GitHub issues (anthropics/claude-code #28482 and #49150). (github.com/anthropics/claude-code issues #28482, #49150)
- [likely] Aider is actively maintained in 2026 with a confirmed scriptable headless pattern: `aider --message "..." --yes-always --auto-test --test-cmd "..."` for single-pass, non-interactive CI runs. (aider.chat/docs/scripting.html)
- [estimate] A specific 'mini-SWE-agent v2.4.x' release could not be confirmed in this research pass; the project's docs reference v1/v2 generally without a verified v2.4.x tag. (github.com/SWE-agent/mini-swe-agent (releases page not directly confirmed for v2.4.x))
