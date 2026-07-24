# GeoWake n8n Workflows — Import via n8n UI or API

These are workflow descriptions for n8n. After deploying n8n on your Oracle VM,
import these workflows manually through the n8n UI (Settings → Import from File).

## Workflow 1: Backend Health Check (every 5 minutes)

**Trigger:** Schedule (every 5 minutes)
**Actions:**
1. HTTP Request: GET https://geowake.example.com/api/health
2. IF node: `{{$json.statusCode}}` equals 200
   - True: (pass silently)
   - False: → HTTP Request to Telegram Bot API:
     ```
     POST https://api.telegram.org/bot{{TELEGRAM_BOT_TOKEN}}/sendMessage
     Body: {"chat_id": "{{TELEGRAM_CHAT_ID}}", "text": "🔴 GeoWake backend is DOWN (HTTP {{statusCode}}) at {{now}}"}
     ```
3. Also check Share backend: GET https://share.geowake.example.com/health
4. Same IF → Telegram alert if down

## Workflow 2: CI Failure → AI Analysis → GitHub Issue

**Trigger:** GitHub Webhook (on check_run completed, conclusion=failure)
**Actions:**
1. Webhook node receives GitHub Actions failure event
2. HTTP Request: GET the failed check run logs via GitHub API
3. AI Agent node (LLM: Groq Llama 3.3 70B):
   - System prompt: "You are a CI failure analyzer. Analyze this test failure and provide a diagnosis."
   - User message: "Repository: geowake2. Failed test logs: {{$json.logs}}. Analyze the root cause and suggest a fix."
4. HTTP Request: POST to GitHub API to create issue:
   ```
   POST https://api.github.com/repos/OWNER/REPO/issues
   Headers: Authorization: Bearer {{GITHUB_TOKEN}}
   Body: {
     "title": "[AUTO] CI Failure: {{$json.title}}",
     "body": "## Automated Analysis\n\n{{$json.analysis}}\n\n## Failed Test Logs\n```\n{{$json.logs}}\n```",
     "labels": ["bug", "auto-generated"]
   }
   ```

## Workflow 3: API Quota Monitor (daily at 9 AM IST)

**Trigger:** Schedule (daily at 09:00 Asia/Kolkata)
**Actions:**
1. HTTP Request: GET Google Cloud API usage (via Google Cloud Monitoring API)
2. IF node: usage > 80% of free tier limit
   - True: → Telegram alert: "⚠️ Google Maps API quota at 80% — consider switching to OSM fallback"
   - Also create GitHub issue with label "cost-leak"

## Workflow 4: Auto-Fix on New Bug Issue (webhook triggered)

**Trigger:** GitHub Webhook (on issues opened, label=bug)
**Actions:**
1. Webhook node receives new issue event
2. Filter: only trigger if issue has "bug" label
3. HTTP Request: POST to Mini-SWE-agent endpoint:
   ```
   POST http://swe-agent:8000/fix
   Body: {
     "repo": "/workspace/geowake",
     "issue_title": "{{$json.issue.title}}",
     "issue_body": "{{$json.issue.body}}",
     "model": "groq/llama-3.3-70b-versatile"
   }
   ```
4. Wait for response (agent creates branch, writes fix, runs tests)
5. IF tests pass: HTTP Request to GitHub API to create PR
6. Telegram notification: "🔧 Auto-fix attempted for issue #{{$json.issue.number}} — PR #{{$json.pr_number}} created, awaiting review"

## Workflow 5: Weekly Ops Report (Sunday 10 AM IST)

**Trigger:** Schedule (weekly on Sunday at 10:00 Asia/Kolkata)
**Actions:**
1. HTTP Request: GitHub API — list PRs merged this week
2. HTTP Request: GitHub API — list issues opened/closed this week
3. HTTP Request: Uptime Kuma API — uptime stats for the week
4. HTTP Request: Sentry API — error counts for the week
5. AI Agent node (LLM: Groq Llama 3.3 70B):
   - System prompt: "You are an ops report generator. Create a concise weekly operations report in Markdown."
   - User message: "PRs merged: {{$json.merged_prs}}. Issues opened: {{$json.issues_opened}}. Issues closed: {{$json.issues_closed}}. Uptime: {{$json.uptime}}%. Errors: {{$json.errors}}. Generate a weekly report."
6. HTTP Request: Telegram — send report as message
7. HTTP Request: GitHub API — create issue with the report for archival

## Workflow 6: Nightly Full Test Suite (daily at 2 AM IST)

**Trigger:** Schedule (daily at 02:00 Asia/Kolkata)
**Actions:**
1. HTTP Request: POST to GitHub Actions API — trigger workflow_dispatch on ci.yml
2. Wait 30 minutes
3. HTTP Request: GET workflow run status
4. IF failed: → Telegram alert with link to failed run
5. IF passed: → (silent pass, log to n8n execution history)

## Setup Instructions

1. Deploy n8n on Oracle VM (included in docker-compose.yml)
2. Access n8n at https://n8n.geowake.example.com
3. Set up basic auth (configured in .env.n8n)
4. Configure credentials in n8n:
   - GitHub Personal Access Token (repo scope)
   - Telegram Bot Token
   - Groq API Key (for AI agent nodes)
5. Import each workflow via Settings → Import from File
6. Enable each workflow

## Credential Setup

### GitHub Token
Settings → Developer settings → Personal access tokens → Fine-grained tokens
Permissions: repo (full), actions: read, issues: write, pull-requests: write

### Telegram Bot
1. Talk to @BotFather on Telegram
2. Create a new bot: /newbot
3. Get the bot token
4. Add the bot to your alert channel/group
6. Get chat ID: send a message to the bot, then visit
   https://api.telegram.org/bot<TOKEN>/getUpdates to find the chat_id

### Groq API Key
1. Go to https://console.groq.com
2. Create account (free, no credit card)
3. API Keys → Create API Key
4. Copy to n8n credentials
