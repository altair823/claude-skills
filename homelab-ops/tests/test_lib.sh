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
  audit) audit_append --arg a "$2" '{ts:"T",session:env.HOMELAB_SESSION_ID,action:$a}' ;;
  runlog) run_log_path "op-1" ;;
  transport) op_transport "$2" "$3" ;;
  owner) owner_host "$2" ;;
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
assert_eq "pve-01"     "$(bash bin/_libprobe.sh owner vm-100)"    "owner_host: child → parent host"
assert_eq "lab-vm-900" "$(bash bin/_libprobe.sh owner lab-vm-900)" "owner_host: orphan → itself"

finish; echo "PASS test_lib"
