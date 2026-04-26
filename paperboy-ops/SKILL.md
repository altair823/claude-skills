---
name: paperboy-ops
description: Use when the user wants to interact with paperboy — a private HTTP service that drives a BIXOLON SRP-350III thermal receipt printer (print text or raw ESC/POS, check printer/queue status, list/cancel print jobs, view metrics). The skill discovers endpoints from the live `/openapi.json` (so it stays correct as the API evolves) instead of hardcoding routes, then calls them via a generic authenticated client. Auto-loads URL + Basic Auth from `~/.config/paperboy-ops/config`.
---

# paperboy-ops

Two thin tools:

- `paperboy-spec` — inspect the live OpenAPI document (paths, operations, schemas).
- `paperboy-api` — generic authenticated HTTP client (`paperboy-api METHOD PATH …`).

Both read `~/.config/paperboy-ops/config` for `PAPERBOY_URL`, `PAPERBOY_USERNAME`, `PAPERBOY_PASSWORD` (+ optional metrics creds, openapi/swagger paths, custom CA).

**The API is evolving.** Do NOT call endpoints from memory or from `paperboy/API.md`. Always start by reading the live spec.

## Workflow

```
discover → read schema → call → poll if async
```

1. `paperboy-spec paths` — list every `METHOD PATH` the server currently exposes.
2. `paperboy-spec op <METHOD> <PATH>` — read the chosen operation's request body, parameters, and response shapes.
3. `paperboy-spec schema <Name>` — dereference any `$ref` you saw under `op` (e.g. `TextPayload`, `JobAccepted`).
4. `paperboy-api <METHOD> <PATH> [--json …] [--idem-auto]` — fire the call.
5. For async print/control endpoints, poll `GET /jobs/{id}` until `status` is terminal (`succeeded` or any `failed_*`).

## When to use

- "Print this text on my receipt printer" / "Cut the paper" / "Print this ESC/POS payload"
- "Is paperboy/the printer healthy? Is paper loaded?"
- "What jobs failed today?" / "Cancel that pending job"
- "What endpoints does paperboy expose right now?" / "What's the request body for `/print/text`?"
- Pulling Prometheus metrics (`/metrics`) with the secondary metrics credentials.

Do NOT use for other thermal printer projects, ESC/POS test rigs, or anything that doesn't speak paperboy's HTTP API.

## Setup

`~/.config/paperboy-ops/config` (mode 0600), shell-sourced format:

```sh
PAPERBOY_URL='https://paperboy.example.com'
PAPERBOY_USERNAME='printer'
PAPERBOY_PASSWORD='…'

# Optional
PAPERBOY_METRICS_USERNAME='metrics'
PAPERBOY_METRICS_PASSWORD='…'
PAPERBOY_OPENAPI_PATH='/openapi.json'   # default
PAPERBOY_SWAGGER_PATH='/swagger-ui/'    # default
PAPERBOY_CACERT='/path/to/ca.pem'       # for self-signed HTTPS
PAPERBOY_INSECURE=1                     # last resort: curl -k
```

Quote any value containing `$` so the shell doesn't expand it. **Never commit this file.**

Symlink so Claude Code finds the skill:

```sh
ln -sfn ~/claude-skills/paperboy-ops ~/.claude/skills/paperboy-ops
```

## paperboy-spec

| Command | What it does |
|---|---|
| `paperboy-spec` | Print the full openapi.json |
| `paperboy-spec paths` | List `METHOD path summary` rows |
| `paperboy-spec paths --filter <ere>` | Same, regex-filtered |
| `paperboy-spec op <METHOD> <PATH>` | Show one operation's params / requestBody / responses |
| `paperboy-spec schema <Name>` | Dereference one component schema |
| `paperboy-spec schemas` | List all schema names |
| `paperboy-spec swagger` | Print the Swagger UI URL (open in browser) |
| `paperboy-spec refresh` | Force re-fetch (bypass 5-min cache) |

Cached at `~/.cache/paperboy-ops/openapi.json` for 5 minutes. After the user redeploys paperboy with new endpoints, run `paperboy-spec refresh`.

## paperboy-api

```
paperboy-api <METHOD> <PATH> [options]
```

Body options (mutually exclusive):
- `--json '<inline-json>'`
- `--json-file <path>`
- `--json-stdin` (or trailing `@-`) — read JSON from stdin

Headers:
- `--idem <key>` — sets `Idempotency-Key`
- `--idem-auto` — generate a unique one (use this for one-shot CLI prints)
- `-H 'Header: value'` — repeatable extra headers (e.g. `-H 'X-Allow-Duplicate: 1'`)

Auth role: `--auth main` (default) or `--auth metrics` (for `/metrics`).

Misc: `--raw` (skip jq), `--status` (echo `[NNN]` HTTP code to stderr), `--debug`.

Exit code: 0 on 2xx, 1 otherwise. Body always written to stdout.

## Worked example — text print + verify

```sh
# 1. Confirm the route + body shape from the live server.
paperboy-spec op POST /print/text
paperboy-spec schema TextPayload     # required: text; optional: align/bold/size/cut/feed_lines

# 2. Sanity-check the printer.
paperboy-api GET /readyz             # {ok:true, usb_open:true, online:true, ...}

# 3. Enqueue (auto Idempotency-Key so retries don't double-print).
#    align=1 → centred. size=[2,2] → double-wide, double-tall (1..=8 per axis;
#    [1,1] is the printer's default). Cut defaults true.
JOB=$(paperboy-api POST /print/text --idem-auto \
  --json '{"text":"안녕 paperboy","align":1,"size":[2,2]}' \
  | jq -r .job_id)

# 4. Poll until terminal.
while :; do
  s=$(paperboy-api GET "/jobs/$JOB" --raw | jq -r .status)
  case "$s" in
    succeeded|failed_*|cancelled) echo "$s"; break ;;
  esac
  sleep 1
done
```

UTF-8 in, EUC-KR encoding handled by the server — just send Korean text as-is.

## Worked example — raw ESC/POS bytes

```sh
# init + text + feed 8 lines (cutter offset) + partial cut
B64=$(printf '\x1b\x40hello raw\x0a\x1b\x64\x08\x1d\x56\x00' | base64)
paperboy-api POST /print/raw --idem-auto --json "{\"data_b64\":\"$B64\"}"
```

Raw payloads are capped at 64 KiB and the server does no ESC/POS validation.

## Idempotency rules

The server accepts `Idempotency-Key` on enqueue endpoints. If absent, paperboy hashes the body and dedupes anyway (resend = same job). Practical guidance:

- One-shot CLI prints → `--idem-auto`.
- Pipelines that retry their own steps → caller-supplied stable key per logical job.
- Genuinely intentional duplicate (same body, must print twice) → `-H 'X-Allow-Duplicate: 1'`.
- Same key + different body → server returns `409 Conflict`. Pick a fresh key.

## Common operations

| Goal | Call |
|---|---|
| Health (no auth) | `paperboy-api GET /healthz` |
| Ready + USB + online | `paperboy-api GET /readyz` |
| Live printer + queue snapshot | `paperboy-api GET /status` |
| Full debug dump | `paperboy-api GET /debug/info` |
| Recent failed jobs | `paperboy-api GET '/jobs?status=failed_paper_out&limit=10'` |
| Cancel queued job | `paperboy-api DELETE /jobs/<id>` |
| Manual cut | `paperboy-api POST /control/cut --json '{}' --idem-auto` |
| Prometheus scrape | `paperboy-api GET /metrics --auth metrics --raw` |

Re-derive any of these from `paperboy-spec paths` if behaviour looks off — the server is the source of truth.

## Common mistakes

| Symptom | Fix |
|---|---|
| `401 Unauthorized` on `/metrics` | Use `--auth metrics`; the printer account is denied. |
| `409 Conflict` on second print | Same Idempotency-Key, different body. Use `--idem-auto` or a fresh key. |
| Quiet enqueue but printer never fires | Poll the job — `failed_paper_out` / `failed_cover_open` / `failed_offline` show up there, not in the enqueue response. |
| Skill recipe references a path that 404s | The API evolved. Re-read `paperboy-spec paths` (and `paperboy-spec refresh` if you suspect a stale cache). |
| `openapi response is not valid JSON` | Wrong `PAPERBOY_OPENAPI_PATH`, or auth blocking the endpoint. Check `paperboy-spec swagger` URL in a browser. |
| Robot/secret with `$` corrupts auth | Single-quote the value in the config file. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (HTTP 2xx) |
| 1 | HTTP non-2xx, network error, malformed openapi response |
| 2 | Bad CLI usage / missing config / missing required env |
