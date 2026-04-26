# harbor-ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `harbor-ls` bash CLI that browses a Harbor private container registry (projects, repos, tags, scan summary) read-only, mirroring the `gitea-ops` skill shape.

**Architecture:** A single dispatcher script `bin/harbor-ls` that sources a shared library `bin/_common.sh`. The library handles config + profile resolution, HTTP + auth, pagination, manifest-based project auto-detection, and table/JSON rendering. Subcommand handlers in the dispatcher wire these together and define per-subcommand columns. Tests use a `curl` PATH-stub that returns canned responses from per-test fixture files.

**Tech Stack:** `bash >= 4.3`, `curl`, `jq`, `numfmt` (optional), POSIX `sh` for tests, `awk`/`sed` for small parsing.

**Spec:** `docs/superpowers/specs/2026-04-25-harbor-ops-design.md`

---

## File Structure

```
harbor-ops/
├── SKILL.md                              # Skill metadata + setup + usage
├── bin/
│   ├── _common.sh                        # Library: config, http, paginate, detect, render
│   └── harbor-ls                         # Dispatcher + subcommand handlers
└── tests/
    ├── lib.sh                            # Assertions + curl stub
    ├── test_config_profile.sh
    ├── test_auth_errors.sh
    ├── test_pagination.sh
    ├── test_glob_filter.sh
    ├── test_project_detect.sh
    ├── test_render.sh
    ├── test_harbor_ls_projects.sh
    ├── test_harbor_ls_repos.sh
    ├── test_harbor_ls_tags.sh
    └── test_harbor_ls_scan.sh
```

`README.md` at the repo root gets a one-line entry for the new skill, and `~/.claude/skills/harbor-ops` is symlinked to the repo dir at the end.

`bin/harbor-ls` is the only public entry point. `bin/_common.sh` is sourced and never executed directly. `tests/lib.sh` is sourced by every test.

---

## Task 1: Scaffold directories + test helpers

**Files:**
- Create: `harbor-ops/bin/_common.sh` (placeholder)
- Create: `harbor-ops/bin/harbor-ls` (placeholder)
- Create: `harbor-ops/tests/lib.sh`
- Create: `harbor-ops/tests/test_lib_smoke.sh`

- [ ] **Step 1: Create directory tree and placeholder scripts**

```bash
mkdir -p harbor-ops/bin harbor-ops/tests
cat >harbor-ops/bin/_common.sh <<'EOF'
#!/usr/bin/env bash
# harbor-ops shared library. Sourced by bin/harbor-ls. Not executable on its own.
set -euo pipefail
EOF
cat >harbor-ops/bin/harbor-ls <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"
echo "harbor-ls placeholder" >&2
exit 1
EOF
chmod +x harbor-ops/bin/harbor-ls harbor-ops/bin/_common.sh
```

- [ ] **Step 2: Write `tests/lib.sh` (assertions + curl stub)**

The stub responds to `curl` calls based on fixture files. It supports `-w '%{http_code}'` (appends code to stdout after body) and `-D <file>` (writes headers to file). Each call is appended to `$CALL_LOG`.

```bash
cat >harbor-ops/tests/lib.sh <<'EOF'
#!/bin/sh
# Shared test helpers for harbor-ops.
set -eu

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BIN="$REPO_ROOT/bin"

# --- assertions ---

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'FAIL: %s\n  expected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2
            exit 1 ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*)
            printf 'FAIL: %s\n  unexpected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2
            exit 1 ;;
        *) ;;
    esac
}

assert_exit_code() {
    # $1=actual $2=expected $3=msg
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\n  expected exit: %s\n  actual:        %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

# --- per-test sandbox ---

setup() {
    TEST_TMP="$(mktemp -d)"
    export TEST_TMP
    export STUB_DIR="$TEST_TMP/stubs"
    export FIXTURE_DIR="$TEST_TMP/fixtures"
    export CALL_LOG="$TEST_TMP/calls.log"
    export HOME="$TEST_TMP/home"
    mkdir -p "$STUB_DIR" "$FIXTURE_DIR" "$HOME/.config/harbor-ops"
    : >"$CALL_LOG"

    # Isolate from ambient env that the dispatcher would honor.
    unset HARBOR_PROFILE HARBOR_DEFAULT_PROFILE HARBOR_DEBUG HARBOR_NO_DETECT
    unset HARBOR_URL HARBOR_USER HARBOR_SECRET HARBOR_PROFILE_NAME

    export PATH="$STUB_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Write a single-profile config under sandboxed $HOME.
write_default_config() {
    cat >"$HOME/.config/harbor-ops/config" <<CFG
HARBOR_DEFAULT_PROFILE=prod
prod_HARBOR_URL=https://harbor.test
prod_HARBOR_USER=alice
prod_HARBOR_SECRET=secret-1
CFG
    chmod 600 "$HOME/.config/harbor-ops/config"
}

# Install a curl stub. Fixtures live at:
#   $FIXTURE_DIR/<METHOD>_<encoded-path-with-query>.body  (response body, default empty)
#   $FIXTURE_DIR/<METHOD>_<encoded-path-with-query>.code  (HTTP code, default 200)
#   $FIXTURE_DIR/<METHOD>_<encoded-path-with-query>.hdrs  (response header lines, default empty)
# Path encoding replaces '/' '?' '&' '=' with '_'.
install_curl_stub() {
    cat >"$STUB_DIR/curl" <<'CURL_EOF'
#!/bin/sh
log="${CALL_LOG:?CALL_LOG unset}"
fix="${FIXTURE_DIR:?FIXTURE_DIR unset}"

method="GET"
url=""
write_fmt=""
dump_headers_to=""
auth_header=""
prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        -w) write_fmt="$a" ;;
        -D) dump_headers_to="$a" ;;
        -H)
            case "$a" in
                Authorization:*) auth_header="$a" ;;
            esac
            ;;
    esac
    case "$a" in
        https://*|http://*) url="$a" ;;
    esac
    prev="$a"
done

# Log: METHOD\tURL\tAUTH-HEADER (no body for GET-only)
printf '%s\t%s\t%s\n' "$method" "$url" "$auth_header" >>"$log"

# Fixture key: METHOD + path + query (as-is, with chars normalized)
path_q="$(printf '%s' "$url" | sed -e 's|^https\?://[^/]*||')"
key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"

body_file="$fix/$key.body"
code_file="$fix/$key.code"
hdrs_file="$fix/$key.hdrs"

code="200"
[ -r "$code_file" ] && code="$(cat "$code_file")"

# Write headers if -D requested
if [ -n "$dump_headers_to" ]; then
    printf 'HTTP/1.1 %s\r\n' "$code" >"$dump_headers_to"
    if [ -r "$hdrs_file" ]; then
        cat "$hdrs_file" >>"$dump_headers_to"
    fi
    printf '\r\n' >>"$dump_headers_to"
fi

# Body
if [ -r "$body_file" ]; then
    cat "$body_file"
fi

# -w '%{http_code}' → append code to stdout after body (no newline, mirrors real curl)
if [ "$write_fmt" = "%{http_code}" ]; then
    printf '%s' "$code"
fi

exit 0
CURL_EOF
    chmod +x "$STUB_DIR/curl"
}

# Write a body fixture: fixture <method> <path-with-query> <body>
fixture() {
    method="$1"; path_q="$2"; body="$3"
    key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"
    printf '%s' "$body" >"$FIXTURE_DIR/$key.body"
}

# Write a status code fixture
fixture_code() {
    method="$1"; path_q="$2"; code="$3"
    key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"
    printf '%s' "$code" >"$FIXTURE_DIR/$key.code"
}

# Write a header-block fixture (caller passes raw header lines, CRLF separated)
fixture_hdrs() {
    method="$1"; path_q="$2"; hdrs="$3"
    key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"
    printf '%s' "$hdrs" >"$FIXTURE_DIR/$key.hdrs"
}

nth_call() { sed -n "${1}p" "$CALL_LOG"; }
call_count() { wc -l <"$CALL_LOG" | tr -d ' '; }
EOF
```

- [ ] **Step 3: Write `tests/test_lib_smoke.sh` to confirm helpers work**

```bash
cat >harbor-ops/tests/test_lib_smoke.sh <<'EOF'
#!/bin/sh
# Sanity check: lib.sh sandbox + curl stub + fixtures.
. "$(dirname "$0")/lib.sh"
setup
trap teardown EXIT

install_curl_stub
fixture GET /api/v2.0/projects '[{"name":"p1"}]'
fixture_code GET /api/v2.0/projects 200
fixture_hdrs GET /api/v2.0/projects 'X-Total-Count: 1\r\n'

body="$(curl -s 'https://harbor.test/api/v2.0/projects')"
assert_eq "$body" '[{"name":"p1"}]' "stub returns body"

cnt="$(call_count)"
assert_eq "$cnt" "1" "one call recorded"

echo "OK test_lib_smoke"
EOF
chmod +x harbor-ops/tests/*.sh
```

- [ ] **Step 4: Run smoke test, expect PASS**

Run: `bash harbor-ops/tests/test_lib_smoke.sh`
Expected stdout: `OK test_lib_smoke`
Expected exit code: 0

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): scaffold dirs + test lib (assertions, curl stub)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Config + profile resolution

Implements `_common.sh::load_profile`. Loads `$HOME/.config/harbor-ops/config`, picks a profile by priority (flag > env > config default > sole), resolves URL/USER/SECRET. Exits 2 with named-key error on any miss.

**Files:**
- Modify: `harbor-ops/bin/_common.sh`
- Create: `harbor-ops/tests/test_config_profile.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_config_profile.sh <<'EOF'
#!/bin/sh
# Test profile resolution and secret resolution in _common.sh::load_profile.
. "$(dirname "$0")/lib.sh"

# We test load_profile by sourcing _common.sh and calling it.
# Each subtest forks a fresh shell so set/unset don't leak.

run_in_subshell() {
    # $1 = setup (write configs, set env), $2 = call (load_profile + echo vars)
    bash -c "
        set -euo pipefail
        export HOME='$HOME'
        export PATH='$PATH'
        . '$BIN/_common.sh'
        $1
        $2
    "
}

# --- subtest: --profile flag wins over env and default ---
setup; trap teardown EXIT

cat >"$HOME/.config/harbor-ops/config" <<CFG
HARBOR_DEFAULT_PROFILE=prod
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=alice
prod_HARBOR_SECRET=p1
staging_HARBOR_URL=https://staging.test
staging_HARBOR_USER=bob
staging_HARBOR_SECRET=s1
CFG

out="$(run_in_subshell '' "load_profile --profile staging; echo \$HARBOR_URL \$HARBOR_USER \$HARBOR_SECRET")"
assert_eq "$out" "https://staging.test bob s1" "--profile flag wins"

# --- subtest: env wins over default ---
out="$(run_in_subshell 'export HARBOR_PROFILE=staging' "load_profile; echo \$HARBOR_URL")"
assert_eq "$out" "https://staging.test" "HARBOR_PROFILE env wins"

# --- subtest: default used when no flag/env ---
out="$(run_in_subshell '' "load_profile; echo \$HARBOR_URL")"
assert_eq "$out" "https://prod.test" "HARBOR_DEFAULT_PROFILE used"

# --- subtest: sole profile auto-selected when no default set ---
teardown; setup; trap teardown EXIT
cat >"$HOME/.config/harbor-ops/config" <<CFG
solo_HARBOR_URL=https://solo.test
solo_HARBOR_USER=eve
solo_HARBOR_SECRET=z
CFG
out="$(run_in_subshell '' "load_profile; echo \$HARBOR_URL")"
assert_eq "$out" "https://solo.test" "sole profile auto-picked"

# --- subtest: missing config → exit 2 ---
teardown; setup; trap teardown EXIT
ec=0
run_in_subshell '' "load_profile" 2>/dev/null || ec=$?
assert_exit_code "$ec" "2" "missing config exits 2"

# --- subtest: missing key in profile → exit 2 ---
teardown; setup; trap teardown EXIT
cat >"$HOME/.config/harbor-ops/config" <<CFG
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=alice
CFG
err="$(run_in_subshell '' "load_profile --profile prod" 2>&1 >/dev/null)" && ec=0 || ec=$?
assert_exit_code "$ec" "2" "missing SECRET exits 2"
assert_contains "$err" "HARBOR_SECRET" "error names missing key"

# --- subtest: SECRET_FILE used when inline absent ---
teardown; setup; trap teardown EXIT
printf 'from-file' >"$TEST_TMP/secret"
cat >"$HOME/.config/harbor-ops/config" <<CFG
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=alice
prod_HARBOR_SECRET_FILE=$TEST_TMP/secret
CFG
out="$(run_in_subshell '' "load_profile --profile prod; echo \$HARBOR_SECRET")"
assert_eq "$out" "from-file" "SECRET_FILE read"

echo "OK test_config_profile"
EOF
chmod +x harbor-ops/tests/test_config_profile.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_config_profile.sh`
Expected: failure with `load_profile: command not found` (or similar) — function not yet defined.

- [ ] **Step 3: Implement `load_profile` in `_common.sh`**

Append to `harbor-ops/bin/_common.sh`:

```bash
cat >>harbor-ops/bin/_common.sh <<'EOF'

# Load config and resolve the active profile.
# Args: optionally --profile <name> (consumed; other args left in "$@" via caller's parsing).
# Honors HARBOR_PROFILE env. Sets globals: HARBOR_URL, HARBOR_USER, HARBOR_SECRET, HARBOR_PROFILE_NAME.
# Exits 2 on any error with a message naming the missing piece.
load_profile() {
    local cfg="$HOME/.config/harbor-ops/config"
    if [ ! -r "$cfg" ]; then
        echo "config missing: $cfg" >&2
        exit 2
    fi

    local cli_profile=""
    if [ "${1:-}" = "--profile" ]; then
        cli_profile="${2:-}"
        if [ -z "$cli_profile" ]; then
            echo "--profile requires a value" >&2
            exit 4
        fi
    fi

    # shellcheck disable=SC1090
    . "$cfg"

    local profile=""
    if [ -n "$cli_profile" ]; then
        profile="$cli_profile"
    elif [ -n "${HARBOR_PROFILE:-}" ]; then
        profile="$HARBOR_PROFILE"
    elif [ -n "${HARBOR_DEFAULT_PROFILE:-}" ]; then
        profile="$HARBOR_DEFAULT_PROFILE"
    else
        # Auto-pick if exactly one *_HARBOR_URL exists.
        local names=()
        local v
        while IFS= read -r v; do names+=("$v"); done < <(
            compgen -A variable | sed -n 's/_HARBOR_URL$//p'
        )
        if [ "${#names[@]}" -eq 1 ]; then
            profile="${names[0]}"
        else
            echo "no profile selected: pass --profile, set HARBOR_PROFILE, or set HARBOR_DEFAULT_PROFILE" >&2
            exit 2
        fi
    fi

    local url_var="${profile}_HARBOR_URL"
    local user_var="${profile}_HARBOR_USER"
    local secret_var="${profile}_HARBOR_SECRET"
    local secret_file_var="${profile}_HARBOR_SECRET_FILE"

    HARBOR_URL="${!url_var:-}"
    HARBOR_USER="${!user_var:-}"
    HARBOR_PROFILE_NAME="$profile"

    if [ -z "$HARBOR_URL" ]; then
        echo "missing ${url_var} in config" >&2; exit 2
    fi
    if [ -z "$HARBOR_USER" ]; then
        echo "missing ${user_var} in config" >&2; exit 2
    fi

    if [ -n "${!secret_var:-}" ]; then
        HARBOR_SECRET="${!secret_var}"
    elif [ -n "${!secret_file_var:-}" ]; then
        local sf="${!secret_file_var}"
        # Expand leading ~
        case "$sf" in "~/"*) sf="$HOME/${sf#\~/}" ;; esac
        if [ ! -r "$sf" ]; then
            echo "secret file unreadable: $sf" >&2; exit 2
        fi
        # Permission check (Linux/macOS/WSL only; Windows NTFS reports 0644 spuriously).
        if [ "$(uname -s)" != "MINGW"* ] && [ "$(uname -s)" != "MSYS"* ]; then
            local mode
            mode="$(stat -c '%a' "$sf" 2>/dev/null || stat -f '%Lp' "$sf" 2>/dev/null || echo "")"
            case "$mode" in
                ""|600|400) ;;
                *) echo "warning: $sf has mode $mode (expected 600 or stricter)" >&2 ;;
            esac
        fi
        HARBOR_SECRET="$(cat "$sf")"
    else
        echo "missing ${secret_var} or ${secret_file_var} in config" >&2; exit 2
    fi

    export HARBOR_URL HARBOR_USER HARBOR_SECRET HARBOR_PROFILE_NAME
}
EOF
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_config_profile.sh`
Expected stdout: `OK test_config_profile`
Expected exit code: 0

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): config + profile resolution (load_profile)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: HTTP wrapper + auth header + auth-error handling

Implements `_common.sh::auth_header` and `_common.sh::harbor_get`. `harbor_get` is the single-page GET: emits body to stdout, sets `RESPONSE_HEADERS_FILE` for callers that need headers, exits 1/2 with named errors on HTTP failure.

**Files:**
- Modify: `harbor-ops/bin/_common.sh`
- Create: `harbor-ops/tests/test_auth_errors.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_auth_errors.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"

run_with_lib() {
    bash -c "
        set -euo pipefail
        export HOME='$HOME' PATH='$PATH'
        . '$BIN/_common.sh'
        load_profile
        $1
    "
}

# --- happy 200 ---
setup; trap teardown EXIT
write_default_config
install_curl_stub
fixture GET '/api/v2.0/projects' '[{"name":"p1"}]'
out="$(run_with_lib "harbor_get /api/v2.0/projects")"
assert_eq "$out" '[{"name":"p1"}]' "200 returns body"

# --- auth header carries Basic alice:secret-1 ---
expected_b64="$(printf 'alice:secret-1' | base64 -w0 2>/dev/null || printf 'alice:secret-1' | base64)"
call="$(nth_call 1)"
assert_contains "$call" "Authorization: Basic $expected_b64" "auth header set"

# --- 401 → exit 2, message names auth ---
teardown; setup; trap teardown EXIT
write_default_config
install_curl_stub
fixture GET '/api/v2.0/projects' ''
fixture_code GET '/api/v2.0/projects' 401
ec=0; err="$(run_with_lib "harbor_get /api/v2.0/projects" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "2" "401 exits 2"
assert_contains "$err" "auth failed" "auth message"

# --- 403 → exit 2 ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code GET '/api/v2.0/projects' 403
ec=0; run_with_lib "harbor_get /api/v2.0/projects" >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "2" "403 exits 2"

# --- 404 → exit 1, message contains path ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code GET '/api/v2.0/projects/none' 404
ec=0; err="$(run_with_lib "harbor_get /api/v2.0/projects/none" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "1" "404 exits 1"
assert_contains "$err" "not found" "404 message"

# --- 500 → exit 1, surfaces body ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects' 'oops the server is on fire'
fixture_code GET '/api/v2.0/projects' 500
ec=0; err="$(run_with_lib "harbor_get /api/v2.0/projects" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "1" "500 exits 1"
assert_contains "$err" "500" "shows status"
assert_contains "$err" "oops" "shows body excerpt"

echo "OK test_auth_errors"
EOF
chmod +x harbor-ops/tests/test_auth_errors.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_auth_errors.sh`
Expected: failure (`harbor_get: command not found`).

- [ ] **Step 3: Implement `auth_header` and `harbor_get` in `_common.sh`**

```bash
cat >>harbor-ops/bin/_common.sh <<'EOF'

# Build the Basic auth header value for the active profile.
auth_header() {
    local raw="$HARBOR_USER:$HARBOR_SECRET"
    if printf '' | base64 -w0 >/dev/null 2>&1; then
        printf 'Basic %s' "$(printf '%s' "$raw" | base64 -w0)"
    else
        printf 'Basic %s' "$(printf '%s' "$raw" | base64 | tr -d '\n')"
    fi
}

log_debug() {
    if [ "${HARBOR_DEBUG:-0}" = "1" ]; then
        printf '[harbor-ops] %s\n' "$*" >&2
    fi
}

# Single GET. $1 = path (with optional ?query). Emits body to stdout.
# Sets RESPONSE_HEADERS_FILE = path to a tmpfile with the response headers.
# Exits 2 on 401/403 (auth), 1 on other 4xx/5xx, 1 on network error.
harbor_get() {
    local path="$1"
    local url="${HARBOR_URL%/}${path}"
    local hdrs_file
    hdrs_file="$(mktemp)"
    local body_file
    body_file="$(mktemp)"
    local code

    log_debug "GET $url"
    set +e
    code="$(curl -sS -o "$body_file" -D "$hdrs_file" -w '%{http_code}' \
        -H "Authorization: $(auth_header)" \
        -H "Accept: application/json" \
        "$url")"
    local rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        rm -f "$hdrs_file" "$body_file"
        echo "network error reaching $url (curl exit $rc)" >&2
        exit 1
    fi

    case "$code" in
        2*)
            cat "$body_file"
            export RESPONSE_HEADERS_FILE="$hdrs_file"
            rm -f "$body_file"
            return 0
            ;;
        401|403)
            echo "auth failed for profile ${HARBOR_PROFILE_NAME} at ${HARBOR_URL} (HTTP $code); check HARBOR_USER / HARBOR_SECRET" >&2
            rm -f "$hdrs_file" "$body_file"
            exit 2
            ;;
        404)
            echo "not found: $path (HTTP 404)" >&2
            rm -f "$hdrs_file" "$body_file"
            exit 1
            ;;
        *)
            local snippet
            snippet="$(head -c 200 "$body_file" 2>/dev/null || true)"
            echo "API error: HTTP $code at $url" >&2
            [ -n "$snippet" ] && echo "  body: $snippet" >&2
            rm -f "$hdrs_file" "$body_file"
            exit 1
            ;;
    esac
}
EOF
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_auth_errors.sh`
Expected: `OK test_auth_errors`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): http wrapper + Basic auth + status-code errors

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Pagination

Implements `_common.sh::harbor_get_paginated`. Iterates `page=1,2,...` with `page_size=100`, concatenates JSON arrays via `jq -s 'add'`, stops on no `Link: ...rel="next"`, hits `MAX_PAGES=200` cap with stderr warning.

**Files:**
- Modify: `harbor-ops/bin/_common.sh`
- Create: `harbor-ops/tests/test_pagination.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_pagination.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"

run_with_lib() {
    bash -c "
        set -euo pipefail
        export HOME='$HOME' PATH='$PATH'
        . '$BIN/_common.sh'
        load_profile
        $1
    "
}

# --- single page, no Link header → stops after page 1 ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[{"name":"p1"},{"name":"p2"}]'
fixture_hdrs GET '/api/v2.0/projects?page=1&page_size=100' 'X-Total-Count: 2\r\n'
out="$(run_with_lib "harbor_get_paginated /api/v2.0/projects")"
assert_eq "$out" '[{"name":"p1"},{"name":"p2"}]' "single-page result"
assert_eq "$(call_count)" "1" "single call"

# --- two pages, Link rel=next on page 1 only ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[{"name":"p1"}]'
fixture_hdrs GET '/api/v2.0/projects?page=1&page_size=100' \
    'X-Total-Count: 2\r\nLink: </api/v2.0/projects?page=2&page_size=100>; rel="next"\r\n'
fixture GET '/api/v2.0/projects?page=2&page_size=100' '[{"name":"p2"}]'
fixture_hdrs GET '/api/v2.0/projects?page=2&page_size=100' 'X-Total-Count: 2\r\n'
out="$(run_with_lib "harbor_get_paginated /api/v2.0/projects")"
# jq -s 'add' yields a single combined array; result should contain both names.
assert_contains "$out" '"p1"' "page 1 included"
assert_contains "$out" '"p2"' "page 2 included"
assert_eq "$(call_count)" "2" "two calls made"

# --- extra-query is preserved ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?with_tag=true&page=1&page_size=100' '[]'
out="$(run_with_lib "harbor_get_paginated /api/v2.0/projects 'with_tag=true'")"
assert_eq "$out" '[]' "empty page handled"

echo "OK test_pagination"
EOF
chmod +x harbor-ops/tests/test_pagination.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_pagination.sh`
Expected: `harbor_get_paginated: command not found`.

- [ ] **Step 3: Implement `harbor_get_paginated`**

```bash
cat >>harbor-ops/bin/_common.sh <<'EOF'

HARBOR_MAX_PAGES="${HARBOR_MAX_PAGES:-200}"
HARBOR_PAGE_SIZE="${HARBOR_PAGE_SIZE:-100}"

# Paginated GET. $1 = path (no query). $2 = optional extra-query string (e.g. "with_tag=true").
# Emits a single concatenated JSON array on stdout.
harbor_get_paginated() {
    local base_path="$1"
    local extra="${2:-}"
    local page=1
    local pages_dir
    pages_dir="$(mktemp -d)"

    while [ "$page" -le "$HARBOR_MAX_PAGES" ]; do
        local q="page=${page}&page_size=${HARBOR_PAGE_SIZE}"
        [ -n "$extra" ] && q="${extra}&${q}"
        local body
        body="$(harbor_get "${base_path}?${q}")"
        printf '%s' "$body" >"$pages_dir/page-$(printf '%04d' "$page").json"

        # Decide whether a next page exists.
        if [ -r "$RESPONSE_HEADERS_FILE" ] && \
           grep -qiE '^Link:.*rel="next"' "$RESPONSE_HEADERS_FILE"; then
            page=$((page + 1))
            continue
        fi
        break
    done

    if [ "$page" -gt "$HARBOR_MAX_PAGES" ]; then
        echo "warning: pagination truncated at MAX_PAGES=$HARBOR_MAX_PAGES; results may be partial" >&2
    fi

    # Concatenate all page arrays into one.
    if ls "$pages_dir"/*.json >/dev/null 2>&1; then
        jq -s 'add // []' "$pages_dir"/*.json
    else
        printf '[]'
    fi
    rm -rf "$pages_dir"
}
EOF
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_pagination.sh`
Expected: `OK test_pagination`.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): paginated GET with Link/MAX_PAGES handling

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Glob → regex filter

Implements `_common.sh::glob_to_regex`. Escapes regex metas, substitutes `*` → `.*` and `?` → `.`, anchors `^...$`. Used by every list subcommand.

**Files:**
- Modify: `harbor-ops/bin/_common.sh`
- Create: `harbor-ops/tests/test_glob_filter.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_glob_filter.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"

run() {
    bash -c "
        export PATH='$PATH'
        . '$BIN/_common.sh'
        glob_to_regex '$1'
    "
}

assert_eq "$(run 'foo')" '^foo$' "literal"
assert_eq "$(run 'foo*')" '^foo.*$' "trailing star"
assert_eq "$(run '*foo')" '^.*foo$' "leading star"
assert_eq "$(run 'fo?')" '^fo.$' "question mark"
# Regex metas must be escaped before substitution.
assert_eq "$(run 'a.b')" '^a\.b$' "dot escaped"
assert_eq "$(run 'a+b')" '^a\+b$' "plus escaped"
assert_eq "$(run 'a(b)')" '^a\(b\)$' "parens escaped"
assert_eq "$(run 'a[b]')" '^a\[b\]$' "brackets escaped"
assert_eq "$(run 'a|b')" '^a\|b$' "pipe escaped"
# Combined: glob meta + regex meta in same input.
assert_eq "$(run 'v1.*')" '^v1\..*$' "dot then star"

echo "OK test_glob_filter"
EOF
chmod +x harbor-ops/tests/test_glob_filter.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_glob_filter.sh`
Expected: `glob_to_regex: command not found`.

- [ ] **Step 3: Implement `glob_to_regex`**

```bash
cat >>harbor-ops/bin/_common.sh <<'EOF'

# Convert a shell-style glob to an anchored ERE.
# Steps: escape regex metas (. + ( ) [ ] { } ^ $ | \), then substitute (* → .*, ? → .),
# then anchor.
glob_to_regex() {
    local g="$1"
    # Escape regex metacharacters (literal backslash first to avoid double-escape).
    g="${g//\\/\\\\}"
    g="${g//./\\.}"
    g="${g//+/\\+}"
    g="${g//(/\\(}"
    g="${g//)/\\)}"
    g="${g//[/\\[}"
    g="${g//]/\\]}"
    g="${g//\{/\\\{}"
    g="${g//\}/\\\}}"
    g="${g//^/\\^}"
    g="${g//\$/\\\$}"
    g="${g//|/\\|}"
    # Now glob substitutions.
    g="${g//\*/.*}"
    g="${g//\?/.}"
    printf '^%s$' "$g"
}
EOF
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_glob_filter.sh`
Expected: `OK test_glob_filter`.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): glob-to-regex helper for --filter

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Project auto-detection

Implements `_common.sh::detect_project`. Walks up cwd → git root (or HOME), scans manifest files in lexicographic order, regex-matches `<host>/<project>(/<repo>)?(:<tag>)?`. Returns first match on stdout, exits 3 on no match. Honors `HARBOR_NO_DETECT=1`.

**Files:**
- Modify: `harbor-ops/bin/_common.sh`
- Create: `harbor-ops/tests/test_project_detect.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_project_detect.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"

run_with_lib() {
    # $1 = cwd, $2 = command
    bash -c "
        set -euo pipefail
        export HOME='$HOME' PATH='$PATH'
        . '$BIN/_common.sh'
        load_profile
        cd '$1'
        $2
    "
}

# --- match in Dockerfile ---
setup; trap teardown EXIT
write_default_config
install_curl_stub
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM harbor.test/myproj/myrepo:v1
DF
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "myproj/myrepo" "Dockerfile match"

# --- match in compose, image: key ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/docker-compose.yml" <<DC
services:
  api:
    image: harbor.test/team-a/api:latest
DC
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "team-a/api" "compose match"

# --- match in k8s yaml ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/deploy.yaml" <<K8S
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: c
          image: harbor.test/billing/worker:v2.3.4
K8S
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "billing/worker" "k8s yaml match"

# --- walk up to git root ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/repo/sub/deeper"
( cd "$TEST_TMP/repo" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init )
cat >"$TEST_TMP/repo/Dockerfile" <<DF
FROM harbor.test/upstream/img:v1
DF
out="$(run_with_lib "$TEST_TMP/repo/sub/deeper" "detect_project")"
assert_eq "$out" "upstream/img" "walks up to git root"

# --- HARBOR_NO_DETECT skips ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM harbor.test/myproj/myrepo:v1
DF
ec=0
err="$(run_with_lib "$TEST_TMP/proj" "HARBOR_NO_DETECT=1 detect_project" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "3" "no-detect skips and errors"

# --- host mismatch → no match → exit 3 ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM other-registry.example.com/x/y:v1
DF
ec=0
run_with_lib "$TEST_TMP/proj" "detect_project" >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "3" "host mismatch exits 3"

# --- lexicographic file order: aaa.yaml beats zzz.yaml ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/zzz.yaml" <<Y
image: harbor.test/last/one:v1
Y
cat >"$TEST_TMP/proj/aaa.yaml" <<Y
image: harbor.test/first/one:v1
Y
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "first/one" "lexicographic file order"

echo "OK test_project_detect"
EOF
chmod +x harbor-ops/tests/test_project_detect.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_project_detect.sh`
Expected: `detect_project: command not found`.

- [ ] **Step 3: Implement `detect_project`**

```bash
cat >>harbor-ops/bin/_common.sh <<'EOF'

# Walk up from cwd to git root (or $HOME), scan manifest files in lex order,
# match the active profile's host. On match, print "<project>/<repo>" and return 0.
# Exit 3 with a message on no match. HARBOR_NO_DETECT=1 forces no match.
detect_project() {
    if [ "${HARBOR_NO_DETECT:-0}" = "1" ]; then
        echo "project not detected (HARBOR_NO_DETECT=1)" >&2
        exit 3
    fi

    local host
    host="$(printf '%s' "$HARBOR_URL" | sed -E 's|^https?://([^/]+).*|\1|')"
    if [ -z "$host" ]; then
        echo "no host in HARBOR_URL: $HARBOR_URL" >&2
        exit 2
    fi

    # Determine the highest dir to scan.
    local stop_dir
    if stop_dir="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        :
    else
        stop_dir="$HOME"
    fi

    local cur="$PWD"
    local host_re
    # Escape dots in host for ERE.
    host_re="$(printf '%s' "$host" | sed 's/\./\\./g')"
    local re="${host_re}/([A-Za-z0-9._-]+)/([A-Za-z0-9._/-]+?)(:[A-Za-z0-9._-]+)?"

    while :; do
        # Visit candidate files in lex order.
        local f
        for f in $(find "$cur" -maxdepth 1 -type f \( \
            -name 'Dockerfile' -o -name 'Dockerfile.*' \
            -o -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
            -o -name 'compose.yml' -o -name 'compose.yaml' \
            -o -name '*.yaml' -o -name '*.yml' \
        \) 2>/dev/null | LC_ALL=C sort); do
            # For yaml/yml that aren't compose, only consider files containing 'image:'.
            case "$(basename "$f")" in
                docker-compose.yml|docker-compose.yaml|compose.yml|compose.yaml|Dockerfile|Dockerfile.*) ;;
                *.yaml|*.yml)
                    grep -q '^[[:space:]]*image:' "$f" || continue
                    ;;
            esac
            local match
            match="$(grep -E -m1 -o "$re" "$f" 2>/dev/null || true)"
            if [ -n "$match" ]; then
                # Strip host + leading slash, drop optional :tag.
                local rest="${match#${host}/}"
                rest="${rest%%:*}"
                log_debug "detect: $f → $rest"
                printf '%s' "$rest"
                return 0
            fi
        done
        if [ "$cur" = "$stop_dir" ] || [ "$cur" = "/" ]; then
            break
        fi
        cur="$(dirname "$cur")"
    done

    echo "project not detected from manifests; pass <project> explicitly or use --no-detect" >&2
    exit 3
}
EOF
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_project_detect.sh`
Expected: `OK test_project_detect`.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): manifest-based project auto-detection

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Output renderer (table + JSON + size formatting)

Implements `_common.sh::format_size` and `_common.sh::render_table`. Subcommands pass column-name + jq-expression pairs; the renderer pipes the input JSON through `jq -r` (TSV), then `column -t -s '\t'`, prepending an uppercase header row. JSON mode emits `jq -c` directly. Empty array prints headers + `(no results)` to stderr (table) or `[]` (json).

**Files:**
- Modify: `harbor-ops/bin/_common.sh`
- Create: `harbor-ops/tests/test_render.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_render.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"

run() {
    bash -c "
        set -euo pipefail
        export PATH='$PATH'
        . '$BIN/_common.sh'
        $1
    "
}

# --- format_size: bytes → IEC ---
out="$(run "format_size 0")"
assert_eq "$out" "0B" "0 bytes"
out="$(run "format_size 1024")"
assert_eq "$out" "1.0KiB" "1KiB"
out="$(run "format_size 47185920")"
assert_contains "$out" "MiB" "MiB"

# --- render_table: simple two-column ---
input='[{"name":"a","count":1},{"name":"b","count":2}]'
out="$(run "echo '$input' | render_table 'NAME=.name' 'COUNT=.count'")"
assert_contains "$out" "NAME" "header present"
assert_contains "$out" "COUNT" "header present"
assert_contains "$out" "a" "row a"
assert_contains "$out" "b" "row b"

# --- render_table: empty input → header + (no results) on stderr ---
out_e="$(run "echo '[]' | render_table 'NAME=.name' 2>&1 1>/dev/null")"
assert_contains "$out_e" "no results" "empty stderr note"

# --- render_json: passthrough compact ---
out="$(run "echo '$input' | render_json")"
assert_eq "$out" '[{"name":"a","count":1},{"name":"b","count":2}]' "json compact"

# --- render_json: empty array stays [] ---
out="$(run "echo '[]' | render_json")"
assert_eq "$out" "[]" "empty json"

echo "OK test_render"
EOF
chmod +x harbor-ops/tests/test_render.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_render.sh`
Expected: `format_size: command not found`.

- [ ] **Step 3: Implement `format_size`, `render_table`, `render_json`**

```bash
cat >>harbor-ops/bin/_common.sh <<'EOF'

# Bytes → IEC string. Falls back to "<n>B" when numfmt is missing.
format_size() {
    local n="$1"
    if [ -z "$n" ] || [ "$n" = "null" ]; then
        printf -- '-'
        return 0
    fi
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --format='%.1f' -- "$n"
    else
        printf '%sB' "$n"
    fi
}

# render_json: pipe stdin (a JSON array) → stdout (compact).
render_json() {
    jq -c .
}

# render_table: pipe stdin (JSON array) → stdout (aligned table).
# Args: each is "HEADER=<jq-expr>". Empty input prints header row + "(no results)" stderr note.
render_table() {
    local input
    input="$(cat)"
    local headers=() exprs=()
    local pair name expr
    for pair in "$@"; do
        name="${pair%%=*}"
        expr="${pair#*=}"
        headers+=("$name")
        exprs+=("$expr")
    done

    # Header row, tab-joined.
    local hdr_line
    hdr_line="$(IFS=$'\t'; printf '%s' "${headers[*]}")"

    # Build a jq filter that emits one row per element with tab separators.
    local row_filter=""
    local i
    for i in "${!exprs[@]}"; do
        if [ "$i" -gt 0 ]; then row_filter+=' + "\t" + '; fi
        row_filter+="(${exprs[$i]} | tostring)"
    done

    local count
    count="$(printf '%s' "$input" | jq 'length')"
    if [ "$count" -eq 0 ]; then
        printf '%s\n' "$hdr_line"
        echo "(no results)" >&2
        return 0
    fi

    {
        printf '%s\n' "$hdr_line"
        printf '%s' "$input" | jq -r ".[] | $row_filter"
    } | column -t -s "$(printf '\t')"
}
EOF
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_render.sh`
Expected: `OK test_render`.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): table + json renderer + IEC size formatter

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Dispatcher + `harbor-ls projects`

Wire `bin/harbor-ls`: parse common flags, dispatch by first positional, implement `cmd_projects`. Filter and limit are applied client-side via the renderer.

**Files:**
- Modify: `harbor-ops/bin/harbor-ls`
- Modify: `harbor-ops/bin/_common.sh` (add `apply_filter`, `apply_limit`)
- Create: `harbor-ops/tests/test_harbor_ls_projects.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_harbor_ls_projects.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- happy path table ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' \
    '[{"name":"p1","project_id":1,"metadata":{"public":"true"},"repo_count":3,"creation_time":"2026-04-20T10:11:00.000Z"},
      {"name":"p2","project_id":2,"metadata":{"public":"false"},"repo_count":7,"creation_time":"2026-04-21T08:30:00.000Z"}]'
out="$(harbor-ls projects 2>/dev/null)"
assert_contains "$out" "NAME" "header"
assert_contains "$out" "p1" "row p1"
assert_contains "$out" "p2" "row p2"

# --- --json passthrough ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[{"name":"p1"}]'
out="$(harbor-ls projects --json 2>/dev/null)"
assert_contains "$out" '"name":"p1"' "json output"

# --- --filter glob applied after fetch ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' \
    '[{"name":"alpha"},{"name":"beta"},{"name":"gamma"}]'
out="$(harbor-ls projects --filter 'a*' 2>/dev/null)"
assert_contains "$out" "alpha" "alpha kept"
assert_not_contains "$out" "beta" "beta filtered"
assert_not_contains "$out" "gamma" "gamma filtered"

# --- --limit truncates ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' \
    '[{"name":"a"},{"name":"b"},{"name":"c"}]'
out="$(harbor-ls projects --limit 1 2>/dev/null)"
assert_contains "$out" "a" "first kept"
assert_not_contains "$out" "b" "second dropped"

# --- empty result → header + (no results) note ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[]'
err="$(harbor-ls projects 2>&1 >/dev/null)"
assert_contains "$err" "no results" "empty stderr note"

echo "OK test_harbor_ls_projects"
EOF
chmod +x harbor-ops/tests/test_harbor_ls_projects.sh
```

The `export PATH="$BIN:$PATH"` line lets the test invoke `harbor-ls` directly (so the dispatcher's `$0`-style detection sees the real install path), while `$BIN` was already exported by `lib.sh`.

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_harbor_ls_projects.sh`
Expected: failure (placeholder dispatcher exits 1 with "harbor-ls placeholder").

- [ ] **Step 3: Add `apply_filter` + `apply_limit` to `_common.sh`**

```bash
cat >>harbor-ops/bin/_common.sh <<'EOF'

# apply_filter: pipe JSON array through stdin, get filtered array on stdout.
# Args: <field-jq-expr> <glob>. If <glob> is empty, passthrough.
apply_filter() {
    local field="$1" glob="$2"
    if [ -z "$glob" ]; then cat; return; fi
    local re
    re="$(glob_to_regex "$glob")"
    jq --arg re "$re" "map(select((${field}) | tostring | test(\$re)))"
}

# apply_limit: pipe JSON array, slice to first N. Empty N = passthrough.
apply_limit() {
    local n="$1"
    if [ -z "$n" ]; then cat; return; fi
    jq --argjson n "$n" '.[:$n]'
}
EOF
```

- [ ] **Step 4: Replace `bin/harbor-ls` placeholder with the dispatcher + projects handler**

```bash
cat >harbor-ops/bin/harbor-ls <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"

usage() {
    cat <<USAGE >&2
Usage: harbor-ls <subcommand> [options] [args]

Subcommands:
  projects                              List all projects
  repos    [<project>]                  List repos in a project (auto-detect if omitted)
  tags     <project>/<repo>             List tags in a repository
  scan     <project>/<repo>:<tag>       Show scan-overview summary

Common options:
  --profile <name>      Select profile from config
  --json                Emit JSON instead of a table
  --limit <N>           Truncate results client-side
  --filter <glob>       Glob match on the primary name field
  --no-detect           Disable manifest-based project detection
  --debug               Verbose stderr logging
  -h, --help            Show this message
USAGE
}

# --- arg parsing ---

OPT_PROFILE=""
OPT_JSON=0
OPT_LIMIT=""
OPT_FILTER=""
OPT_NO_DETECT=0
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) OPT_PROFILE="$2"; shift 2;;
        --json) OPT_JSON=1; shift;;
        --limit) OPT_LIMIT="$2"; shift 2;;
        --filter) OPT_FILTER="$2"; shift 2;;
        --no-detect) OPT_NO_DETECT=1; shift;;
        --debug) export HARBOR_DEBUG=1; shift;;
        -h|--help) usage; exit 0;;
        --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done;;
        -*) echo "unknown flag: $1" >&2; usage; exit 4;;
        *) POSITIONAL+=("$1"); shift;;
    esac
done

if [ "$OPT_NO_DETECT" = "1" ]; then export HARBOR_NO_DETECT=1; fi

if [ "${#POSITIONAL[@]}" -eq 0 ]; then
    usage; exit 4
fi

SUBCMD="${POSITIONAL[0]}"
ARGS=("${POSITIONAL[@]:1}")

# Load profile (consumes optional --profile).
if [ -n "$OPT_PROFILE" ]; then
    load_profile --profile "$OPT_PROFILE"
else
    load_profile
fi

# --- output gateway ---
emit() {
    # stdin = JSON array.
    local data
    data="$(cat)"
    if [ "$OPT_JSON" = "1" ]; then
        printf '%s' "$data" | render_json
    else
        printf '%s' "$data" | render_table "$@"
    fi
}

# --- subcommand: projects ---
cmd_projects() {
    local raw
    raw="$(harbor_get_paginated /api/v2.0/projects)"
    printf '%s' "$raw" \
        | apply_filter '.name' "$OPT_FILTER" \
        | apply_limit "$OPT_LIMIT" \
        | emit \
            'NAME=.name' \
            'ID=.project_id' \
            'PUBLIC=.metadata.public' \
            'REPO_COUNT=.repo_count' \
            'CREATED=(.creation_time // "" | sub("\\..*Z$"; "Z") | sub("T"; " "))'
}

# --- dispatch ---
case "$SUBCMD" in
    projects) cmd_projects "${ARGS[@]}";;
    repos|tags|scan)
        echo "not implemented yet: $SUBCMD" >&2
        exit 4
        ;;
    *)
        echo "unknown subcommand: $SUBCMD" >&2
        usage
        exit 4
        ;;
esac
EOF
chmod +x harbor-ops/bin/harbor-ls
```

- [ ] **Step 5: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_harbor_ls_projects.sh`
Expected: `OK test_harbor_ls_projects`.

- [ ] **Step 6: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): dispatcher + harbor-ls projects subcommand

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `harbor-ls repos`

Add `cmd_repos`. Positional `<project>` is optional — when omitted, calls `detect_project` and uses just the project portion. 404 on a missing project surfaces from `harbor_get` already.

**Files:**
- Modify: `harbor-ops/bin/harbor-ls`
- Create: `harbor-ops/tests/test_harbor_ls_repos.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_harbor_ls_repos.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- explicit project ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/myproj/repositories?page=1&page_size=100' \
    '[{"name":"myproj/api","artifact_count":3,"pull_count":42,"update_time":"2026-04-20T10:11:00.000Z"}]'
out="$(harbor-ls repos myproj 2>/dev/null)"
assert_contains "$out" "api" "repo name shown"

# --- detect-fill from manifest ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM harbor.test/team-x/anything:v1
DF
fixture GET '/api/v2.0/projects/team-x/repositories?page=1&page_size=100' \
    '[{"name":"team-x/svc"}]'
out="$(cd "$TEST_TMP/proj" && harbor-ls repos 2>/dev/null)"
assert_contains "$out" "svc" "detected project queried"

# --- 404 project → exit 1 ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code GET '/api/v2.0/projects/no-such/repositories?page=1&page_size=100' 404
ec=0
harbor-ls repos no-such >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "1" "404 → exit 1"

# --- --filter on repo name ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories?page=1&page_size=100' \
    '[{"name":"p/alpha"},{"name":"p/beta"}]'
out="$(harbor-ls repos p --filter 'a*' 2>/dev/null)"
assert_contains "$out" "alpha" "alpha kept"
assert_not_contains "$out" "beta" "beta filtered"

echo "OK test_harbor_ls_repos"
EOF
chmod +x harbor-ops/tests/test_harbor_ls_repos.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_harbor_ls_repos.sh`
Expected: failure (`not implemented yet: repos`).

- [ ] **Step 3: Add `cmd_repos` to `bin/harbor-ls`**

Replace the `repos|tags|scan)` stub block with:

```bash
# Edit bin/harbor-ls: add cmd_repos before the dispatch case, then
# update the case to call it.
```

Apply this edit (use the Edit tool: replace the stub `repos|tags|scan)` block and insert `cmd_repos` above the dispatch). The full new dispatcher tail looks like:

```bash
# --- subcommand: repos ---
cmd_repos() {
    local project="${1:-}"
    if [ -z "$project" ]; then
        local detected
        detected="$(detect_project)"
        # detect_project returns "<proj>/<repo>" or "<proj>"; take the first segment.
        project="${detected%%/*}"
    fi
    # Strip the project/ prefix from each .name for the table.
    local raw
    raw="$(harbor_get_paginated "/api/v2.0/projects/${project}/repositories")"
    printf '%s' "$raw" \
        | jq --arg p "$project" 'map(.short_name = (.name | sub("^"+$p+"/"; "")))' \
        | apply_filter '.short_name' "$OPT_FILTER" \
        | apply_limit "$OPT_LIMIT" \
        | emit \
            'NAME=.short_name' \
            'ARTIFACT_COUNT=.artifact_count' \
            'PULL_COUNT=.pull_count' \
            'UPDATED=(.update_time // "" | sub("\\..*Z$"; "Z") | sub("T"; " "))'
}

# --- dispatch ---
case "$SUBCMD" in
    projects) cmd_projects "${ARGS[@]}";;
    repos)    cmd_repos    "${ARGS[@]}";;
    tags|scan)
        echo "not implemented yet: $SUBCMD" >&2
        exit 4
        ;;
    *)
        echo "unknown subcommand: $SUBCMD" >&2
        usage
        exit 4
        ;;
esac
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_harbor_ls_repos.sh`
Expected: `OK test_harbor_ls_repos`.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): harbor-ls repos subcommand

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `harbor-ls tags`

Add `cmd_tags`. Positional is `<project>/<repo>` (or just `<repo>` with detection). Calls `/artifacts?with_tag=true&with_scan_overview=false`. One row per tag (multi-tag artifacts split). Untagged artifacts shown as `<none>`. Digest truncated to 19 chars (`sha256:abcdef012345`). Size formatted IEC.

**Files:**
- Modify: `harbor-ops/bin/harbor-ls`
- Create: `harbor-ops/tests/test_harbor_ls_tags.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_harbor_ls_tags.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- multi-tag artifact, untagged artifact, digest truncation, IEC size ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts?with_tag=true&with_scan_overview=false&page=1&page_size=100' \
    '[
       {"digest":"sha256:abcdef0123456789aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "size":47185920,
        "push_time":"2026-04-20T10:11:00.000Z",
        "tags":[{"name":"v1.2.0"},{"name":"latest"}]},
       {"digest":"sha256:9999999999999999bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "size":1024,
        "push_time":"2026-04-19T08:30:00.000Z",
        "tags":null}
     ]'
out="$(harbor-ls tags p/r 2>/dev/null)"
assert_contains "$out" "v1.2.0" "v1.2.0 row"
assert_contains "$out" "latest" "latest row"
assert_contains "$out" "<none>" "untagged shown"
assert_contains "$out" "sha256:abcdef012345" "digest truncated"
assert_not_contains "$out" "abcdef0123456789aa" "full digest hidden"
assert_contains "$out" "MiB" "IEC size"

echo "OK test_harbor_ls_tags"
EOF
chmod +x harbor-ops/tests/test_harbor_ls_tags.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_harbor_ls_tags.sh`
Expected: failure (`not implemented yet: tags`).

- [ ] **Step 3: Add `cmd_tags` to `bin/harbor-ls`**

Insert this function before the dispatch case, then update the dispatch case (shown after the function):

```bash
# --- subcommand: tags ---
cmd_tags() {
    local arg="${1:-}"
    local project="" repo=""
    case "$arg" in
        */*) project="${arg%%/*}"; repo="${arg#*/}";;
        "")
            local detected; detected="$(detect_project)"
            project="${detected%%/*}"; repo="${detected#*/}"
            if [ "$project" = "$repo" ] || [ -z "$repo" ]; then
                echo "tags requires <project>/<repo>; detection only filled <project>" >&2
                exit 3
            fi
            ;;
        *)
            local detected; detected="$(detect_project)"
            project="${detected%%/*}"
            repo="$arg"
            ;;
    esac

    local repo_enc="${repo//\//%2F}"
    local raw
    raw="$(harbor_get_paginated \
        "/api/v2.0/projects/${project}/repositories/${repo_enc}/artifacts" \
        'with_tag=true&with_scan_overview=false')"

    # Explode tags into rows.
    local exploded
    exploded="$(printf '%s' "$raw" | jq '
        [ .[] |
          ( .tags // [] ) as $tags |
          if ($tags | length) == 0
          then { tag: "<none>", digest, size, push_time }
          else $tags[] as $t | { tag: $t.name, digest, size, push_time }
          end
        ]
    ')"

    # Add display fields (digest_short, pushed). Then filter+limit.
    local display
    display="$(printf '%s' "$exploded" | jq '
        map(. + {
            digest_short: (.digest | .[0:19]),
            pushed: ((.push_time // "") | sub("\\..*Z$"; "Z") | sub("T"; " "))
        })
    ' | apply_filter '.tag' "$OPT_FILTER" | apply_limit "$OPT_LIMIT")"

    if [ "$OPT_JSON" = "1" ]; then
        printf '%s' "$display" | render_json
        return
    fi

    # Table mode: format size per-row in shell, since format_size needs `numfmt`.
    local with_size
    with_size="$(printf '%s' "$display" | jq -c '.')"
    # Build a new array with size_str field.
    local rows="["; local first=1
    local n; n="$(printf '%s' "$with_size" | jq 'length')"
    local i=0
    while [ "$i" -lt "$n" ]; do
        local row; row="$(printf '%s' "$with_size" | jq -c ".[$i]")"
        local sz; sz="$(printf '%s' "$row" | jq -r '.size')"
        local szs; szs="$(format_size "$sz")"
        if [ "$first" -eq 1 ]; then first=0; else rows="${rows},"; fi
        rows="${rows}$(printf '%s' "$row" | jq -c --arg s "$szs" '. + {size_str: $s}')"
        i=$((i+1))
    done
    rows="${rows}]"

    printf '%s' "$rows" | render_table \
        'TAG=.tag' \
        'DIGEST=.digest_short' \
        'PUSHED=.pushed' \
        'SIZE=.size_str'
}
```

Apply via Edit (or rewrite the file). Update the dispatch case:

```bash
case "$SUBCMD" in
    projects) cmd_projects "${ARGS[@]}";;
    repos)    cmd_repos    "${ARGS[@]}";;
    tags)     cmd_tags     "${ARGS[@]}";;
    scan)
        echo "not implemented yet: scan" >&2
        exit 4
        ;;
    ...
esac
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_harbor_ls_tags.sh`
Expected: `OK test_harbor_ls_tags`.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): harbor-ls tags subcommand (multi-tag split, IEC size)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `harbor-ls scan`

Add `cmd_scan`. Positional is `<project>/<repo>:<tag>`. Single-artifact GET with `with_scan_overview=true`. Lexicographically first scanner key picked. Status + severity counts emitted; not-yet-scanned shows `STATUS=Not Scanned` and `-` for counts.

**Files:**
- Modify: `harbor-ops/bin/harbor-ls`
- Create: `harbor-ops/tests/test_harbor_ls_scan.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat >harbor-ops/tests/test_harbor_ls_scan.sh <<'EOF'
#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- scanned artifact: severity counts populated ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts/v1?with_scan_overview=true' \
    '{
       "digest":"sha256:aaaa",
       "scan_overview":{
         "application/vnd.security.vulnerability.report; version=1.1": {
           "scan_status":"Success",
           "end_time":"2026-04-24T10:11:23.000Z",
           "summary": { "summary": {"Critical":2,"High":5,"Medium":8,"Low":3,"Unknown":1} }
         }
       }
     }'
out="$(harbor-ls scan p/r:v1 2>/dev/null)"
assert_contains "$out" "Success" "status shown"
assert_contains "$out" "p/r:v1" "ref shown"
# Severities present in some column form
assert_contains "$out" "2" "critical count"
assert_contains "$out" "5" "high count"

# --- multiple scanner keys: lexicographic first wins ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts/v1?with_scan_overview=true' \
    '{
       "scan_overview":{
         "zz-scanner":{"scan_status":"Error","summary":{"summary":{}}},
         "aa-scanner":{"scan_status":"Success","summary":{"summary":{"Critical":1}}}
       }
     }'
out="$(harbor-ls scan p/r:v1 2>/dev/null)"
assert_contains "$out" "Success" "lex-first scanner status"
assert_not_contains "$out" "Error" "later scanner ignored"

# --- not yet scanned: empty scan_overview ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts/v1?with_scan_overview=true' \
    '{"scan_overview":{}}'
out="$(harbor-ls scan p/r:v1 2>/dev/null)"
assert_contains "$out" "Not Scanned" "fallback status"

echo "OK test_harbor_ls_scan"
EOF
chmod +x harbor-ops/tests/test_harbor_ls_scan.sh
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `bash harbor-ops/tests/test_harbor_ls_scan.sh`
Expected: failure (`not implemented yet: scan`).

- [ ] **Step 3: Add `cmd_scan` to `bin/harbor-ls`**

```bash
# --- subcommand: scan ---
cmd_scan() {
    local arg="${1:-}"
    if [ -z "$arg" ]; then
        echo "scan requires <project>/<repo>:<tag>" >&2; exit 4
    fi
    local proj_repo="${arg%%:*}"
    local tag="${arg##*:}"
    if [ "$proj_repo" = "$arg" ] || [ -z "$tag" ]; then
        echo "scan requires <project>/<repo>:<tag>" >&2; exit 4
    fi
    local project="${proj_repo%%/*}"
    local repo="${proj_repo#*/}"
    if [ -z "$project" ] || [ "$project" = "$proj_repo" ]; then
        echo "scan requires <project>/<repo>:<tag>" >&2; exit 4
    fi
    local repo_enc="${repo//\//%2F}"

    local raw
    raw="$(harbor_get "/api/v2.0/projects/${project}/repositories/${repo_enc}/artifacts/${tag}?with_scan_overview=true")"

    if [ "$OPT_JSON" = "1" ]; then
        printf '%s' "$raw" | jq -c '.scan_overview // {}'
        return
    fi

    # Pick the lexicographically first scanner key.
    local scanner
    scanner="$(printf '%s' "$raw" | jq -r '
        (.scan_overview // {}) | keys_unsorted | sort | .[0] // ""
    ')"

    local status critical high medium low unknown end_time
    if [ -z "$scanner" ]; then
        status="Not Scanned"
        end_time="-"
        critical="-"; high="-"; medium="-"; low="-"; unknown="-"
    else
        status="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].scan_status // "-"')"
        end_time="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '
            (.scan_overview[$s].end_time // "") | sub("\\..*Z$"; "Z") | sub("T"; " ")
        ')"
        [ -z "$end_time" ] && end_time="-"
        local sev_path
        # Some Harbor versions: summary.summary; others: severity
        sev_path="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '
            if (.scan_overview[$s].summary.summary // null) != null then "summary.summary"
            elif (.scan_overview[$s].severity // null) != null then "severity"
            else "" end
        ')"
        if [ "$sev_path" = "summary.summary" ]; then
            critical="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].summary.summary.Critical // 0')"
            high="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].summary.summary.High // 0')"
            medium="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].summary.summary.Medium // 0')"
            low="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].summary.summary.Low // 0')"
            unknown="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].summary.summary.Unknown // 0')"
        elif [ "$sev_path" = "severity" ]; then
            critical="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].severity.Critical // 0')"
            high="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].severity.High // 0')"
            medium="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].severity.Medium // 0')"
            low="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].severity.Low // 0')"
            unknown="$(printf '%s' "$raw" | jq -r --arg s "$scanner" '.scan_overview[$s].severity.Unknown // 0')"
        else
            critical="-"; high="-"; medium="-"; low="-"; unknown="-"
        fi
    fi

    # Synthesize a 1-row JSON array and reuse render_table.
    local row
    row="$(jq -c -n --arg ref "${project}/${repo}:${tag}" \
        --arg status "$status" --arg end "$end_time" \
        --arg c "$critical" --arg h "$high" --arg m "$medium" \
        --arg l "$low" --arg u "$unknown" \
        '[ {ref:$ref, status:$status, scanned:$end, c:$c, h:$h, m:$m, l:$l, u:$u} ]')"

    printf '%s' "$row" | render_table \
        'PROJECT/REPO:TAG=.ref' \
        'STATUS=.status' \
        'SCANNED=.scanned' \
        'CRITICAL=.c' \
        'HIGH=.h' \
        'MEDIUM=.m' \
        'LOW=.l' \
        'UNKNOWN=.u'
}
```

Update dispatch case:

```bash
case "$SUBCMD" in
    projects) cmd_projects "${ARGS[@]}";;
    repos)    cmd_repos    "${ARGS[@]}";;
    tags)     cmd_tags     "${ARGS[@]}";;
    scan)     cmd_scan     "${ARGS[@]}";;
    *)
        echo "unknown subcommand: $SUBCMD" >&2
        usage
        exit 4
        ;;
esac
```

- [ ] **Step 4: Run test, expect PASS**

Run: `bash harbor-ops/tests/test_harbor_ls_scan.sh`
Expected: `OK test_harbor_ls_scan`.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/
git commit -m "$(cat <<'EOF'
feat(harbor-ops): harbor-ls scan subcommand (severity-count summary)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: SKILL.md + README + symlink

Document the skill so Claude Code can find it (frontmatter `description` is the search key). Add an entry to the repo README. Create the symlink so Claude Code picks it up.

**Files:**
- Create: `harbor-ops/SKILL.md`
- Modify: `README.md`

- [ ] **Step 1: Write `harbor-ops/SKILL.md`**

```bash
cat >harbor-ops/SKILL.md <<'EOF'
---
name: harbor-ops
description: Use when the user wants to browse a private Harbor container registry — list projects, list repos in a project, list tags / artifacts in a repo, or read the vulnerability-scan severity summary for an artifact. Read-only. Auto-detects project from Dockerfile / docker-compose / k8s manifests in cwd. Multi-profile config so a single setup can target several Harbor instances.
---

# harbor-ops

Read-only browse of a Harbor private container registry from the CLI. Single
binary `harbor-ls` with subcommands. Zero deps beyond `bash >= 4.3`, `curl`,
`jq` (and optionally `numfmt` for human-readable sizes).

## When to use

- "What projects are on our Harbor?"
- "List the tags of `myproj/api`"
- "Did the last image push pass the vulnerability scan?"
- "Show repos under project X"

Do NOT use for image push/pull (that's `docker`), for write operations
(creating projects, robot accounts, replication policies), or for
non-Harbor registries (Docker Hub, GHCR, ECR have different APIs).

## Setup

1. Generate a CLI Secret in Harbor: *User Profile → CLI Secret → Generate*.
   For CI, use a robot account secret instead.

2. Create `~/.config/harbor-ops/config` (mode `0600`):

   ```
   HARBOR_DEFAULT_PROFILE=prod

   prod_HARBOR_URL=https://harbor.example.com
   prod_HARBOR_USER=alice
   prod_HARBOR_SECRET=<cli-secret-or-robot-secret>

   # Optional: more profiles
   staging_HARBOR_URL=https://harbor-staging.example.com
   staging_HARBOR_USER=alice
   staging_HARBOR_SECRET_FILE=~/.config/harbor-ops/secrets/staging
   ```

   `chmod 600 ~/.config/harbor-ops/config`. **Never commit this file** —
   secrets are inline. If you sync dotfiles, use the `_HARBOR_SECRET_FILE`
   variant and exclude the secret file from version control.

3. Symlink the skill into Claude Code's skills dir:

   ```sh
   ln -sfn ~/claude-skills/harbor-ops ~/.claude/skills/harbor-ops
   ```

### Windows

Works on Git Bash 2.x (bash 4.4+) and WSL2. NTFS ignores `chmod`, so the
config file's mode-0600 protection is best-effort on native Git Bash; rely
on user-directory ACLs.

## Subcommands

```
harbor-ls projects                          List all projects
harbor-ls repos    [<project>]              List repos in a project
harbor-ls tags     <project>/<repo>         List tags / artifacts
harbor-ls scan     <project>/<repo>:<tag>   Severity-count scan summary
```

### Common flags

| Flag | Effect |
|---|---|
| `--profile <name>` | Select a profile from config |
| `--json` | Emit JSON instead of a table |
| `--limit <N>` | Truncate results client-side |
| `--filter <glob>` | Glob match on the primary name field |
| `--no-detect` | Disable manifest-based project detection |
| `--debug` | Verbose stderr logging |

### Project auto-detection

When a subcommand needs `<project>` (or `<project>/<repo>`) and the user
omitted it, the skill walks up from cwd to the git root (or `$HOME`),
scanning `Dockerfile`, `docker-compose.{yml,yaml}`, `compose.{yml,yaml}`,
and `*.{yml,yaml}` files containing an `image:` key, in lexicographic
order. The first reference matching `<host>/<project>/<repo>(:<tag>)?`
where `<host>` is the active profile's Harbor host wins.

### Examples

```sh
harbor-ls projects
harbor-ls projects --filter 'team-*'
harbor-ls repos myproj
harbor-ls tags myproj/api --limit 5
harbor-ls tags myproj/api --filter 'v1.*'
harbor-ls scan myproj/api:v1.2.0
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | API error (network, 4xx other than auth, 5xx, malformed response) |
| 2 | Config or auth error |
| 3 | Project auto-detect failed |
| 4 | Invalid argument |
EOF
```

- [ ] **Step 2: Update repo `README.md`**

Use Edit tool. Find the `## Skills` section and add a line under the existing `gitea-ops` entry:

```markdown
- [harbor-ops](harbor-ops/SKILL.md) — read-only browse of a private Harbor
  container registry (projects, repos, tags, scan summary) via REST API.
```

- [ ] **Step 3: Create the symlink (manual step on the developer's machine)**

```bash
ln -sfn "$(pwd)/harbor-ops" ~/.claude/skills/harbor-ops
ls -la ~/.claude/skills/harbor-ops
```

Expected: a symlink pointing at `<repo>/harbor-ops`.

- [ ] **Step 4: Run all tests as a final smoke**

```bash
for t in harbor-ops/tests/test_*.sh; do
    echo "=== $t ==="
    bash "$t" || { echo "FAIL: $t"; exit 1; }
done
```

Expected: every test prints its `OK ...` line and the loop exits 0.

- [ ] **Step 5: Commit**

```bash
git add harbor-ops/SKILL.md README.md
git commit -m "$(cat <<'EOF'
docs(harbor-ops): SKILL.md + README entry for harbor-ls skill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the Implementer

- All `bash` scripts begin with `#!/usr/bin/env bash` and `set -euo pipefail`.
- `tests/lib.sh` itself uses `#!/bin/sh` for portability; tests under it can
  use `bash` for indirect-expansion features by spawning `bash -c '...'`.
- The curl stub in `tests/lib.sh` is intentionally simple (URL-keyed
  fixtures). When a test needs status, headers, and body all controlled,
  use `fixture`, `fixture_code`, `fixture_hdrs`.
- The `format_size` helper requires `numfmt`. On systems without it (rare
  on modern Git Bash, present on Linux/WSL/macOS via coreutils), tests
  that assert on `MiB`/`KiB` will fail — guard installation in CI if you
  add CI later.
- `glob_to_regex` doesn't handle character classes (`[abc]`); spec
  doesn't require them. If you find yourself wanting them, extend
  `apply_filter` to accept a `--regex` flag rather than expanding glob
  syntax.
