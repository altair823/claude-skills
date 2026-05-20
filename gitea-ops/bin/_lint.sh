#!/bin/sh
# PR 일관성 lint. Stateless·side-effect 없는 pure 모듈.
# 호출자: gitea-pr (생성 전), gitea-pr-status (entry-gate).
# 의존성 없음 (jq, tea 등 source 안 함).

# 정규식 상수. extended POSIX regex (`grep -E`) 호환.
_LINT_TITLE_RE='^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+'
_LINT_BRANCH_RE='^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$'

lint_pr_title() {
    title="$1"
    if printf '%s' "$title" | grep -qE "$_LINT_TITLE_RE"; then
        return 0
    fi
    printf 'lint failed: title does not match %s\n' "$_LINT_TITLE_RE"
    return 2
}

lint_branch_name() {
    branch="$1"
    if printf '%s' "$branch" | grep -qE "$_LINT_BRANCH_RE"; then
        return 0
    fi
    printf 'lint failed: branch does not match %s\n' "$_LINT_BRANCH_RE"
    return 2
}

# `## 요약` / `## 검증` 헤더 + `## 요약` 절 본문이 whitespace·newline 제거 후 1자 이상.
lint_pr_body() {
    body="$1"
    result="$(printf '%s' "$body" | awk '
        /^## 요약$/ { has_summary=1; in_summary=1; next }
        /^## 검증$/ { has_validate=1; in_summary=0; next }
        /^## / { in_summary=0 }
        in_summary {
            line=$0
            gsub(/[ \t]/, "", line)
            if (length(line) > 0) summary_content=1
        }
        END {
            if (!has_summary)       print "missing_summary"
            else if (!has_validate) print "missing_validate"
            else if (!summary_content) print "empty_summary"
            else print "ok"
        }
    ')"
    case "$result" in
        ok) return 0 ;;
        missing_summary)  printf 'lint failed: body missing required header %s\n' '## 요약'; return 2 ;;
        missing_validate) printf 'lint failed: body missing required header %s\n' '## 검증'; return 2 ;;
        empty_summary)    printf 'lint failed: %s section is empty (whitespace-only)\n' '## 요약'; return 2 ;;
    esac
}

lint_pr_all() {
    title="$1"; branch="$2"; body="$3"
    rc=0
    lint_pr_title "$title"     || rc=2
    lint_branch_name "$branch" || rc=2
    lint_pr_body "$body"       || rc=2
    return $rc
}
