#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

cat > /tmp/_libprobe.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
case "$1" in
  opid)  new_op_id ;;
  mask)  echo "BW_SESSION=topsecret token=abcDEF123" | mask ;;
  mask_hard) printf 'Authorization: Bearer SECRETBEARER123\n-----BEGIN OPENSSH PRIVATE KEY-----\nKEYBODYLINE0000\n-----END OPENSSH PRIVATE KEY-----\n{"password":"pw-secret-val"}\n' | mask ;;
  mask_env) printf 'PVE_TOKEN=ptokVALUE123 HL_SSH_KEY=hkeyVALUE456\n' | mask ;;
  audit) audit_append --arg a "$2" '{ts:"T",session:env.HOMELAB_SESSION_ID,action:$a}' ;;
  runlog) run_log_path "op-1" ;;
  transport) op_transport "$2" "$3" ;;
  owner) owner_host "$2" ;;
  oti)     ACTIONS[__zz]="$2"; op_transport __zz "${3:-}" ;;
  pdment)  pdm_entry ;;
  grade) action_grade "$2" ;;
  canon) canon_action "$2" ;;
esac
EOF
cp /tmp/_libprobe.sh bin/_libprobe.sh
trap 'rm -f bin/_libprobe.sh' EXIT

op="$(HOMELAB_SESSION_ID=test bash bin/_libprobe.sh opid)"
assert_contains "$op" "op-" "new_op_id has op- prefix"

masked="$(bash bin/_libprobe.sh mask)"
assert_contains "$masked" "MASKED" "secrets are masked"
[[ "$masked" != *topsecret* ]] && echo "  ok: plaintext secret removed" \
  || { echo "  FAIL: secret leaked"; exit 1; }
[[ "$masked" != *abcDEF123* ]] && echo "  ok: token value masked" \
  || { echo "  FAIL: token value leaked"; exit 1; }

hard="$(bash bin/_libprobe.sh mask_hard)"
for leak in SECRETBEARER123 KEYBODYLINE0000 pw-secret-val; do
  [[ "$hard" != *"$leak"* ]] && echo "  ok: masked $leak" \
    || { echo "  FAIL: leaked $leak"; exit 1; }
done
assert_contains "$hard" "MASKED" "hard inputs produce mask markers"

: > logs/audit.jsonl
HOMELAB_SESSION_ID=test-sess bash bin/_libprobe.sh audit "start"
last="$(tail -1 logs/audit.jsonl)"
assert_eq "test-sess" "$(jq -r .session <<<"$last")" "audit record has session"
assert_eq "start" "$(jq -r .action <<<"$last")" "audit record has action"

rp="$(HOMELAB_SESSION_ID=test-sess bash bin/_libprobe.sh runlog)"
assert_contains "$rp" "logs/runs/test-sess/op-1.log" "run_log_path under session dir"
[[ -d logs/runs/test-sess ]] && echo "  ok: run dir created" \
  || { echo "  FAIL: run dir missing"; exit 1; }

assert_eq "none" "$(bash bin/_libprobe.sh transport status proxmox-host)" "status → none"
assert_eq "pve"  "$(bash bin/_libprobe.sh transport stop vm)"            "stop vm → pve"
assert_eq "pve"  "$(bash bin/_libprobe.sh transport destroy proxmox-host)" "destroy host → pve"
assert_eq "ssh"  "$(bash bin/_libprobe.sh transport stop appliance)"     "stop appliance → ssh"
assert_eq "ssh"  "$(bash bin/_libprobe.sh transport pkg-install vm)"     "pkg-install → ssh"
assert_eq "pve"  "$(bash bin/_libprobe.sh transport provision proxmox-host)" "provision → pve"
assert_eq "none" "$(bash bin/_libprobe.sh transport frobnicate vm)"      "unknown action → none"
assert_eq "host-ssh" "$(bash bin/_libprobe.sh oti 'destructive host-ssh' vm)"   "op_transport: host-ssh token → host-ssh"
assert_eq "pdm"      "$(bash bin/_libprobe.sh oti 'destructive pdm' vm)"          "op_transport: pdm token → pdm"
assert_eq "pve"      "$(bash bin/_libprobe.sh oti 'caution guest' vm)"            "op_transport: guest+vm still → pve (regression)"
assert_eq "ssh"      "$(bash bin/_libprobe.sh oti 'caution guest' appliance)"     "op_transport: guest+appliance still → ssh (regression)"
assert_eq "none"     "$(bash bin/_libprobe.sh oti 'safe none' vm)"                "op_transport: none token still → none (regression)"
assert_eq "pdm-01"   "$(bash bin/_libprobe.sh pdment)"                            "pdm_entry → the single kind:pdm id"
assert_eq "pve"  "$(bash bin/_libprobe.sh transport delete vm)"          "delete (alias) → pve for vm"
assert_eq "safe"        "$(bash bin/_libprobe.sh grade status)"   "action_grade status → safe"
assert_eq "caution"     "$(bash bin/_libprobe.sh grade stop)"     "action_grade stop → caution"
assert_eq "destructive" "$(bash bin/_libprobe.sh grade destroy)"  "action_grade destroy → destructive"
assert_eq "destructive" "$(bash bin/_libprobe.sh grade delete)"   "action_grade delete (alias) → destructive"
assert_eq "destructive" "$(bash bin/_libprobe.sh grade frobnicate)" "unknown action → destructive (deny-default)"
assert_eq "destroy"     "$(bash bin/_libprobe.sh canon delete)"   "canon_action delete → destroy"
assert_eq "frob"        "$(bash bin/_libprobe.sh canon frob)"     "canon_action unknown → passthrough"
assert_eq "pve-01"     "$(bash bin/_libprobe.sh owner vm-100)"    "owner_host: child → parent host"
assert_eq "lab-vm-900" "$(bash bin/_libprobe.sh owner lab-vm-900)" "owner_host: orphan → itself"

menv="$(bash bin/_libprobe.sh mask_env)"
[[ "$menv" != *ptokVALUE123* ]] && echo "  ok: PVE_TOKEN value masked" \
  || { echo "  FAIL: PVE_TOKEN leaked"; exit 1; }
[[ "$menv" != *hkeyVALUE456* ]] && echo "  ok: HL_SSH_KEY value masked" \
  || { echo "  FAIL: HL_SSH_KEY leaked"; exit 1; }
assert_contains "$menv" "MASKED" "env-token inputs produce mask markers"

# dynamic 첫 토큰: action_grade 는 리터럴 'dynamic' 을 반환(guard 가 _classify 로 위임).
assert_eq "dynamic" "$(bash bin/_libprobe.sh grade exec)" "action_grade exec → dynamic (정적 산출 안 함)"
# op_transport 도 dynamic 토큰이면 'dynamic' 을 반환(실 transport 는 --via 로 guard 결정).
assert_eq "dynamic" "$(bash bin/_libprobe.sh transport exec vm)" "op_transport exec → dynamic"
# 정적 verb 회귀
assert_eq "destructive" "$(bash bin/_libprobe.sh grade disk-grow)" "정적 disk-grow 회귀"
assert_eq "host-ssh" "$(bash bin/_libprobe.sh transport disk-grow vm)" "정적 disk-grow transport 회귀"

finish; echo "PASS test_lib"
