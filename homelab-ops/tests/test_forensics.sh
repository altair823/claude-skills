#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/forensics 2>/dev/null || true

# Seed a deterministic audit log with two sessions + one failure.
: > logs/audit.jsonl
jq -cn '{ts:"2026-05-16T10:00:00Z",session:"S1",op:"op-a",actor:"claude",action:"status",target:"vm-100",grade:"safe",env:"prod",tags:[],inv_snapshot:{id:"vm-100"},dryrun_hash:null,approver:null,approved_at:null,exit:0,duration_ms:12}' >> logs/audit.jsonl
jq -cn '{ts:"2026-05-16T10:01:00Z",session:"S1",op:"op-b",actor:"claude",action:"destroy",target:"vm-100",grade:"destructive",env:"prod",tags:[],inv_snapshot:{id:"vm-100"},dryrun_hash:"abc",approver:"claude+user",approved_at:"2026-05-16T10:00:59Z",exit:20,duration_ms:300}' >> logs/audit.jsonl
jq -cn '{ts:"2026-05-16T11:00:00Z",session:"S2",op:"op-c",actor:"claude",action:"start",target:"nas-01",grade:"caution",env:"prod",tags:["critical"],inv_snapshot:{id:"nas-01"},dryrun_hash:null,approver:null,approved_at:null,exit:0,duration_ms:40}' >> logs/audit.jsonl

s1="$(bin/forensics session S1)"
assert_contains "$s1" "op-a" "session filter includes op-a"
assert_contains "$s1" "op-b" "session filter includes op-b"
[[ "$s1" != *"op-c"* ]] && echo "  ok: session filter excludes other sessions" \
  || { echo "  FAIL: leaked op-c"; exit 1; }

tgt="$(bin/forensics target nas-01)"
assert_contains "$tgt" "op-c" "target filter works"

tl="$(bin/forensics timeline S1)"
# timeline is ordered and surfaces the failure (exit 20)
assert_contains "$tl" "op-a" "timeline has first op"
assert_contains "$tl" "exit=20" "timeline surfaces the failed op exit code"
first_line="$(head -1 <<<"$tl")"
assert_contains "$first_line" "10:00:00" "timeline ordered by time (earliest first)"


# runlog: error path then happy path (the drill-down half of §6 reconstruction)
assert_status 1 'bin/forensics runlog S1/nope.log' "runlog missing file exits 1"
mkdir -p logs/runs/S1
echo "PRE-OP SNAPSHOT marker xyz" > logs/runs/S1/op-b.log
rl="$(bin/forensics runlog S1/op-b.log)"
assert_contains "$rl" "PRE-OP SNAPSHOT marker xyz" "runlog cats the run log"

finish; echo "PASS test_forensics"
