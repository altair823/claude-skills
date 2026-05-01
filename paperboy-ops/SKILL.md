---
name: paperboy-ops
description: Use when the user wants to interact with paperboy — a private HTTP service that drives a BIXOLON SRP-350III thermal receipt printer (print text or raw ESC/POS, check printer/queue status, list/cancel print jobs, view metrics). The skill discovers endpoints from the live `/openapi.json` (so it stays correct as the API evolves) instead of hardcoding routes, then calls them via a generic authenticated client. Auto-loads URL + Basic Auth from `~/.config/paperboy-ops/config`.
---

# paperboy-ops

Three tools:
- `paperboy-spec` — inspect live OpenAPI (paths/ops/schemas).
- `paperboy-api` — auth'd HTTP client (`METHOD PATH`).
- `paperboy-estimate` — local line/cm estimator (paper-saving gate).

`paperboy-spec` / `paperboy-api` read `~/.config/paperboy-ops/config` for URL + Basic Auth (+ optional metrics creds, paths, CA). `paperboy-estimate` is local-only.

**The API is evolving.** Do NOT call endpoints from memory — always start by reading the live spec.

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

## Paper-saving rules

The printer is a B&W thermal unit. Every line eats paper. Before sending any
**text-bearing payload** (a JSON body whose human-readable content lives in a
field like `text`, `body`, `content`, or `markdown`), Claude MUST walk the
checklist below, then call `paperboy-estimate` to verify length.

Raw payloads (`/print/raw` and any future endpoint that ships base64/binary)
are exempt — the caller is byte-aware by definition.

### Pre-print compaction checklist

| # | Rule | Why |
|---|---|---|
| 1 | Convert prose to tables or bullets | Prose pads with filler; tables strip it. |
| 2 | Hoist repeated label prefixes into a table header (one row per item) | Removes per-line redundancy. |
| 3 | Drop colour metadata (`행운의 색: 파랑`, etc.) | Printer is B&W; the value renders as text but conveys nothing. |
| 4 | Glyphs only from ASCII, Hangul, common Hanja, basic punctuation (`.,!?:;-/()`) and box drawing (`─│┌┐└┘├┤┬┴┼`) | Server encodes EUC-KR. Emoji and symbols outside EUC-KR will be replaced or fail the print. When in doubt, use `--check-charset` to verify. |
| 5 | Collapse consecutive blank lines to one. `feed_lines=0` unless cutter offset demands 1–3 | Each blank line = paper. |
| 6 | `size=[1,1]` is the default. Only `[2,2]+` when the user explicitly asks for "크게/제목/강조" | Doubling each axis quadruples paper area. |
| 7 | `bold=false`, `align=0` unless the user requests otherwise | Conservative defaults; nothing is "decorative by default". |

Multiple-item requests are NOT auto-merged. If the user asks for three
fortunes, print three jobs unless the user themselves asks for a single strip
with dividers — paper separation can carry intent.

### Length gate

After composing, run on the text field:

```sh
echo "$TEXT" | paperboy-estimate --size "$W,$H" --feed-lines "$N"
```

JSON output: `physical_lines`, `approx_cm`, `over_threshold`, `threshold`. Exit `0` under threshold (default 15), `1` over, `2` charset failure (with `--check-charset`).

`over_threshold=false` → print. `true` → show user preview (first ~10 lines + `... (총 N줄, ~M cm)`), wait for OK. The gate is confirmation, not block — long content proceeds with one OK. Override via `--threshold N` or `PAPERBOY_LINE_THRESHOLD`.

### When to use `--check-charset`

Only for unusual glyphs (decorative marks, Unicode symbols, uncommon Hanja). Runs strict `iconv -f UTF-8 -t EUC-KR`, prints offending chars to stderr, exits 2. ASCII + Hangul + common punctuation never needs it.

## Pre-flight check

Before the first authenticated call: deps (`curl jq`) + config is UTF-8 no BOM + mode 0600. Config is shell-sourced — a BOM corrupts the first variable name and silently breaks auth.

**PowerShell pitfall**: default `>` / `Out-File` writes UTF-16 LE BOM. Use `Set-Content -Encoding utf8NoBOM` or `[IO.File]::WriteAllText()`.

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

Body (mutually exclusive): `--json '<inline>'` / `--json-file <path>` / `--json-stdin` (or trailing `@-`).

Headers: `--idem <key>` (Idempotency-Key) / `--idem-auto` (auto unique — for one-shot CLI prints) / `-H 'Header: value'` (repeatable, e.g. `-H 'X-Allow-Duplicate: 1'`).

Auth: `--auth main` (default) or `--auth metrics` (for `/metrics`). Misc: `--raw` (skip jq), `--status` ([NNN] HTTP code to stderr), `--debug`. Exit 0 on 2xx, 1 otherwise. Body always to stdout.

## Worked example — text print + verify

```sh
paperboy-spec op POST /print/text                         # discover route + body
paperboy-spec schema TextPayload                          # required: text; opt: align/bold/size/cut/feed_lines
paperboy-api GET /readyz                                  # printer health

TEXT='[영수증]
커피      4500
샌드위치  6000
─────────────
합계     10500'

echo "$TEXT" | paperboy-estimate --size 1,1 --feed-lines 0  # exit 1 = preview + ask user first

JOB=$(paperboy-api POST /print/text --idem-auto \
  --json "$(jq -n --arg t "$TEXT" '{text:$t,align:0,size:[1,1],cut:true,feed_lines:0}')" \
  | jq -r .job_id)

# Poll until terminal: succeeded | failed_* | cancelled
while :; do
  s=$(paperboy-api GET "/jobs/$JOB" --raw | jq -r .status)
  case "$s" in succeeded|failed_*|cancelled) echo "$s"; break ;; esac
  sleep 1
done
```

UTF-8 in, server handles EUC-KR — send Korean text as-is.

## Worked example — raw ESC/POS bytes

```sh
# init + text + 8-line feed (cutter offset) + partial cut
B64=$(printf '\x1b\x40hello raw\x0a\x1b\x64\x08\x1d\x56\x00' | base64)
paperboy-api POST /print/raw --idem-auto --json "{\"data_b64\":\"$B64\"}"
```

Capped at 64 KiB, server does no ESC/POS validation.

## Idempotency rules

Server accepts `Idempotency-Key` on enqueue endpoints. Absent → paperboy hashes body and dedupes (resend = same job).

- One-shot CLI prints → `--idem-auto`.
- Retry-driven pipelines → caller-supplied stable key per logical job.
- Intentional duplicate (same body, print twice) → `-H 'X-Allow-Duplicate: 1'`.
- Same key + different body → `409 Conflict`. Pick fresh key.

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

`0` success (HTTP 2xx) / `1` HTTP non-2xx, network error, malformed openapi / `2` bad CLI usage, missing config or env.
