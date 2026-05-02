#!/bin/sh
# Shared test helpers for gitea-ops shell tests.
# Each test sources this, calls `setup`, runs the script under test, then asserts.

set -eu

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BIN="$REPO_ROOT/bin"

# --- assertions ---

assert_eq() {
    # $1=actual $2=expected $3=msg
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

assert_contains() {
    # $1=haystack $2=needle $3=msg
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'FAIL: %s\n  expected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2
            exit 1 ;;
    esac
}

assert_file_contains() {
    # $1=path $2=needle $3=msg
    [ -r "$1" ] || { printf 'FAIL: %s\n  no such file: %s\n' "$3" "$1" >&2; exit 1; }
    if ! grep -q -F -- "$2" "$1"; then
        printf 'FAIL: %s\n  not found in %s: %s\n' "$3" "$1" "$2" >&2
        printf 'file content:\n' >&2; cat "$1" >&2
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
    mkdir -p "$STUB_DIR" "$FIXTURE_DIR"
    : >"$CALL_LOG"

    # Use a token file inside sandbox so real ~/.config/gitea-ops/token is untouched.
    export GITEA_TOKEN_FILE="$TEST_TMP/token"
    printf 'fake-token\n' >"$GITEA_TOKEN_FILE"

    # Reviewer token sandbox so real ~/.config/gitea-ops/reviewer-token is untouched.
    export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/reviewer-token"
    printf 'fake-reviewer-token\n' >"$GITEA_REVIEWER_TOKEN_FILE"

    # Default repo coords; tests may override.
    export GITEA_URL="https://gitea.test"
    export GITEA_REPO="owner/repo"

    # Place stubs ahead of real binaries on PATH.
    export PATH="$STUB_DIR:$PATH"

    # tea stub answers `tea logins ls` claiming both logins already exist,
    # so ensure_tea_login skips the registration path during tests.
    # install_curl_stub() (kept for back-compat name) now installs the tea stub.
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Install a tea stub that:
#   - claims `tea logins ls` lists both expected logins (so ensure_tea_login skips add)
#   - intercepts `tea api -X METHOD --login NAME [--repo REPO] [-d @-] /path`
#     and serves fixture bodies by (METHOD, /api/v1/<resolved-path>) key.
#   - no-ops `tea releases assets create <tag> <file>...` (logs the call instead).
# Fixtures: $FIXTURE_DIR/<METHOD>_<urlencoded-path-incl-/api/v1>.body
# Path placeholders {owner}/{repo} are resolved from $GITEA_REPO before lookup,
# matching the original curl-era fixture keys verbatim.
install_curl_stub() {
    cat >"$STUB_DIR/tea" <<'TEA_EOF'
#!/bin/sh
log="${CALL_LOG:?CALL_LOG unset}"
fix="${FIXTURE_DIR:?FIXTURE_DIR unset}"

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
    logins)
        sub="${1:-ls}"; shift 2>/dev/null || true
        case "$sub" in
            ls|list)
                printf 'NAME,URL,SSH HOST,USER,DEFAULT\n'
                printf 'gitea-ops-author,https://gitea.test,,user,1\n'
                printf 'gitea-ops-reviewer,https://gitea.test,,reviewer,0\n'
                ;;
            *) ;;  # add/edit/delete are unreachable in tests
        esac
        exit 0
        ;;
    releases)
        # tea releases assets create <tag> <file>... — log only.
        all="$*"
        printf 'tea\treleases\t%s\n' "$all" >>"$log"
        exit 0
        ;;
    api) ;;  # falls through to handler below
    *)
        printf 'tea-stub: unknown command: %s\n' "$cmd" >&2
        exit 1
        ;;
esac

# --- tea api handler ---
method="GET"; login=""; repo=""; path=""; data=""; read_stdin=0
while [ $# -gt 0 ]; do
    case "$1" in
        -X|--method) method="$2"; shift 2 ;;
        -l|--login)  login="$2"; shift 2 ;;
        -r|--repo)   repo="$2"; shift 2 ;;
        -R|--remote) shift 2 ;;
        -d|--data)
            if [ "$2" = "@-" ]; then
                read_stdin=1
            elif [ "${2#@}" != "$2" ]; then
                # @file — read from file
                data="$(cat "${2#@}")"
            else
                data="$2"
            fi
            shift 2 ;;
        -H|--header) shift 2 ;;
        -F|--Field)  shift 2 ;;
        -f|--field)  shift 2 ;;
        -i|--include) shift ;;
        -o|--output) shift 2 ;;
        --debug|--vvv) shift ;;
        /*|http*) path="$1"; shift ;;
        *) shift ;;
    esac
done

if [ "$read_stdin" = "1" ]; then
    data="$(cat)"
fi

# Resolve {owner}/{repo} placeholders: --repo wins, else GITEA_REPO env.
src_repo="${repo:-${GITEA_REPO:-}}"
if [ -n "$src_repo" ]; then
    owner="${src_repo%/*}"
    rname="${src_repo#*/}"
    path="$(printf '%s' "$path" | sed -e "s|{owner}|$owner|g" -e "s|{repo}|$rname|g")"
fi

# tea api auto-prefixes /api/v1 unless path already starts with /api/.
case "$path" in
    /api/*|http*) ;;
    *) path="/api/v1$path" ;;
esac

# Log shape preserved: METHOD<TAB>URL<TAB>BODY (URL synthesized for compatibility).
data_log="$(printf '%s' "$data" | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {printf "%s", $0}' | sed 's/\t/\\t/g')"
printf '%s\thttps://gitea.test%s\t%s\n' "$method" "$path" "$data_log" >>"$log"

# Strip query string for fixture lookup (matches original curl stub semantics).
path_clean="${path%%\?*}"
key="$(printf '%s_%s' "$method" "$path_clean" | tr '/?&=' '____')"
body_file="$fix/$key.body"
seq_idx_file="$fix/$key.seq.idx"

if [ -r "$fix/$key.seq.1.body" ]; then
    idx=1
    [ -r "$seq_idx_file" ] && idx="$(cat "$seq_idx_file")"
    chosen="$fix/$key.seq.$idx.body"
    if [ ! -r "$chosen" ]; then
        prev_idx=$((idx - 1))
        chosen="$fix/$key.seq.$prev_idx.body"
    else
        next=$((idx + 1))
        printf '%s' "$next" >"$seq_idx_file"
    fi
    cat "$chosen"
elif [ -r "$body_file" ]; then
    cat "$body_file"
fi
TEA_EOF
    chmod +x "$STUB_DIR/tea"
}

# Write a fixture body for a (method, path) pair.
fixture() {
    method="$1"; path="$2"; body="$3"
    key="$(printf '%s_%s' "$method" "$path" | tr '/?&=' '____')"
    printf '%s' "$body" >"$FIXTURE_DIR/$key.body"
}

# Read N-th call from log: "METHOD\tURL\tBODY"
nth_call() {
    sed -n "${1}p" "$CALL_LOG"
}

call_count() {
    wc -l <"$CALL_LOG" | tr -d ' '
}

# Sequenced fixture: each subsequent call to (method,path) returns the next body.
# Usage: fixture_seq METHOD /path body1 body2 body3 ...
# 기존 `fixture` 등록과 같은 (method, path) 에 대해 둘 다 존재하면 sequenced 가 우선.
fixture_seq() {
    method="$1"; path="$2"; shift 2
    key="$(printf '%s_%s' "$method" "$path" | tr '/?&=' '____')"
    n=1
    for body in "$@"; do
        printf '%s' "$body" >"$FIXTURE_DIR/$key.seq.$n.body"
        n=$((n + 1))
    done
}
