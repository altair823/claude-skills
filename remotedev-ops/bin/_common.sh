# bin/_common.sh — shared helpers for remotedev-ops verb scripts.
# Sourced, never executed. No `set -e` here (callers own their mode).

log()  { printf '[remotedev] %s\n' "$*" >&2; }
warn() { printf '[remotedev] warning: %s\n' "$*" >&2; }
die()  { printf '[remotedev] error: %s\n' "$*" >&2; exit 1; }

rdo_home() { cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd; }

is_git_repo() { git rev-parse --show-toplevel >/dev/null 2>&1; }
repo_root()   { git rev-parse --show-toplevel 2>/dev/null || pwd; }

host_up() { ssh -o BatchMode=yes -o ConnectTimeout=4 "$1" true 2>/dev/null; }

shim_dir() { printf '%s' "${REMOTEDEV_SHIM_DIR:-$HOME/.local/share/remotedev/shims}"; }

rc_file() {
  if [ -n "${REMOTEDEV_RC:-}" ]; then printf '%s' "$REMOTEDEV_RC"; return; fi
  case "${SHELL:-}" in
    */zsh) printf '%s' "$HOME/.zshrc" ;;
    *)     printf '%s' "$HOME/.bashrc" ;;
  esac
}

RDO_BEG='# >>> remotedev >>>'
RDO_END='# <<< remotedev <<<'

rc_block_remove() {
  local f="$1"; [ -f "$f" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -v b="$RDO_BEG" -v e="$RDO_END" '
    $0==b{skip=1} skip==0{print} $0==e{skip=0}' "$f" > "$tmp"
  mv "$tmp" "$f"
}

rc_block_write() {
  local f="$1"; touch "$f"; rc_block_remove "$f"
  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then printf '\n' >> "$f"; fi
  { printf '%s\n' "$RDO_BEG"
    printf 'export REMOTEDEV_SHIM_DIR="%s"\n' "$(shim_dir)"
    printf 'export PATH="$REMOTEDEV_SHIM_DIR:$PATH"\n'
    printf '%s\n' "$RDO_END"
  } >> "$f"
}

# git_hide/git_unhide operate on a path relative to the current repo root.
git_hide() {
  local rel="$1"
  if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    git update-index --skip-worktree -- "$rel"
  else
    local ex; ex="$(git rev-parse --git-dir)/info/exclude"
    grep -qxF -- "$rel" "$ex" 2>/dev/null || printf '%s\n' "$rel" >> "$ex"
  fi
}
git_unhide() {
  local rel="$1"
  if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    git update-index --no-skip-worktree -- "$rel" 2>/dev/null || true
  fi
  local ex; ex="$(git rev-parse --git-dir 2>/dev/null)/info/exclude"
  if [ -f "$ex" ]; then grep -vxF -- "$rel" "$ex" > "$ex.tmp" 2>/dev/null || true; mv "$ex.tmp" "$ex"; fi
  return 0
}

shim_installed() { [ -e "$(shim_dir)/cargo" ]; }

INTERCEPT=(cargo uv make cmake go npm pnpm yarn bun ninja meson dotnet)

read_cfg() {
  REMOTEDEV_HOST=""; REMOTEDEV_REMOTE_DIR=""
  REMOTEDEV_EXCLUDES=(.git target node_modules .venv build dist .gradle)
  REMOTEDEV_ARTIFACTS=(); BUILD_CMD=""; TEST_CMD=""; RUN_CMD=""
  # shellcheck disable=SC1090
  . "$1"
}
