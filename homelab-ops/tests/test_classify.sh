#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_classify 2>/dev/null || true
C() { bin/_classify "$@"; }   # prints "grade<TAB>rule"

# 메타문자 → destructive
assert_eq "destructive	metachar" "$(C guest -- sh -c 'rm -rf /')" "sh -c → metachar"
assert_eq "destructive	metachar" "$(C guest -- ls\; rm)" "세미콜론 → metachar"
assert_eq "destructive	metachar" "$(C node -- cat /etc/x \&\& reboot)" "&& → metachar"
# 미지 바이너리 → fallback-deny
assert_eq "destructive	fallback-deny" "$(C guest -- frobnicate --now)" "미지 바이너리 → fallback-deny"

# Regression: --method as last arg must not crash (shift 2 over-shift bug)
assert_eq "destructive	pve-write" "$(bin/_classify pve --method)" "--method as last arg: no crash, pve-write"
assert_eq "destructive	pve-write" "$(bin/_classify pve --method POST --path /x)" "pve POST → pve-write"
assert_eq "caution	pve-get" "$(bin/_classify pve --method GET --path /x)" "pve GET → pve-get"
# Regression: unknown via must emit invalid-via, not fall through silently
assert_eq "destructive	invalid-via" "$(bin/_classify bogus -- ls)" "unknown via → invalid-via"
# Regression: --method last arg exits 0 (no set -e abort)
assert_status 0 'bin/_classify pve --method' "--method last arg exits 0 (no set -e abort)"

# 단순 read-only 바이너리 → caution
assert_eq "caution	ro-allowlist:cat" "$(C guest -- cat /etc/os-release)" "cat → caution"
assert_eq "caution	ro-allowlist:journalctl" "$(C node -- journalctl -u sshd -n 50)" "journalctl → caution"
# 서브커맨드 한정 화이트리스트
assert_eq "caution	ro-allowlist:systemctl-status" "$(C guest -- systemctl status sshd)" "systemctl status → caution"
assert_eq "destructive	fallback-deny" "$(C guest -- systemctl restart sshd)" "systemctl restart → fallback-deny"
assert_eq "caution	ro-allowlist:qm-config" "$(C node -- qm config 301)" "qm config → caution"
assert_eq "destructive	fallback-deny" "$(C node -- qm stop 301)" "qm stop → fallback-deny"
# pve GET 회귀
assert_eq "caution	pve-get" "$(C pve --method GET --path /nodes/x/qemu)" "pve GET → caution"
assert_eq "destructive	pve-write" "$(C pve --method POST --path /nodes/x/qemu/301/status/stop)" "pve POST → pve-write"
# wrapper guard: env/sudo 등이 allowlist를 우회하지 못해야 함 (rule = wrapper, NOT metachar)
assert_eq "destructive	wrapper" "$(C guest -- env bash -c 'rm -rf /')" "env-wrapped shell → wrapper (no allowlist bypass)"
assert_eq "destructive	wrapper" "$(C node -- sudo systemctl restart x)" "sudo wrapper → wrapper"
# real shell-metachar cases must still be metachar (not wrapper)
assert_eq "destructive	metachar" "$(C guest -- 'a;b')" "a;b → metachar (not wrapper)"

# subcommand-gated coverage
assert_eq "caution	ro-allowlist:pct-config" "$(C node -- pct config 200)" "pct config → caution"
assert_eq "destructive	fallback-deny" "$(C node -- pct start 200)" "pct start → fallback-deny"
assert_eq "caution	ro-allowlist:pvesm-status" "$(C node -- pvesm status)" "pvesm status → caution"
assert_eq "destructive	fallback-deny" "$(C node -- pvesm remove x)" "pvesm remove → fallback-deny"
assert_eq "caution	ro-allowlist:pkg-query" "$(C node -- apt list --installed)" "apt list → caution"
assert_eq "caution	ro-allowlist:pkg-query" "$(C node -- dpkg -l)" "dpkg -l → caution"
assert_eq "caution	ro-allowlist:systemctl-is-active" "$(C guest -- systemctl is-active sshd)" "systemctl is-active → caution"
assert_eq "caution	ro-allowlist:systemctl-show" "$(C guest -- systemctl show sshd)" "systemctl show → caution"
assert_eq "caution	ro-allowlist:systemctl-list-units" "$(C guest -- systemctl list-units)" "systemctl list-units → caution"
# tightened binaries: read-only forms → caution
assert_eq "caution	ro-allowlist:journalctl" "$(C node -- journalctl -u sshd -n 50)" "journalctl read → caution"
assert_eq "caution	ro-allowlist:ip" "$(C node -- ip addr show)" "ip addr show → caution"
assert_eq "caution	ro-allowlist:ip" "$(C node -- ip route)" "ip route → caution"
assert_eq "caution	ro-allowlist:ss" "$(C node -- ss -tlnp)" "ss read → caution"
assert_eq "caution	ro-allowlist:dmesg" "$(C node -- dmesg -T)" "dmesg read → caution"
# tightened binaries: mutating forms → destructive fallback-deny
assert_eq "destructive	fallback-deny" "$(C node -- ip link set eth0 down)" "ip link set → fallback-deny"
assert_eq "destructive	fallback-deny" "$(C node -- ip route add default via 1.2.3.4)" "ip route add → fallback-deny"
assert_eq "destructive	fallback-deny" "$(C node -- journalctl --vacuum-size=1M)" "journalctl --vacuum → fallback-deny"
assert_eq "destructive	fallback-deny" "$(C node -- journalctl --rotate)" "journalctl --rotate → fallback-deny"
assert_eq "destructive	fallback-deny" "$(C node -- ss -K dport = 80)" "ss -K → fallback-deny"
assert_eq "destructive	fallback-deny" "$(C node -- dmesg --clear)" "dmesg --clear → fallback-deny"
# conservatism canaries: dangerous binaries must NEVER be allowlisted
assert_eq "destructive	fallback-deny" "$(C guest -- rm /tmp/x)" "rm → fallback-deny (never allowlist)"
assert_eq "destructive	fallback-deny" "$(C guest -- chmod 777 /etc)" "chmod → fallback-deny"
assert_eq "destructive	fallback-deny" "$(C guest -- kill 1)" "kill → fallback-deny"

# kube via: kubectl 서브커맨드 기반 분류
assert_eq "caution	kube-ro:get" "$(C kube -- get pods -A)" "kubectl get → caution"
assert_eq "caution	kube-ro:describe" "$(C kube -- describe pod foo)" "kubectl describe → caution"
assert_eq "caution	kube-ro:logs" "$(C kube -- logs foo -c bar)" "kubectl logs → caution"
assert_eq "caution	kube-ro:top" "$(C kube -- top pods)" "kubectl top → caution"
assert_eq "caution	kube-ro:cluster-info" "$(C kube -- cluster-info)" "kubectl cluster-info → caution"
assert_eq "caution	kube-ro:version" "$(C kube -- version)" "kubectl version → caution"
assert_eq "destructive	kube-write:apply" "$(C kube -- apply -f x.yaml)" "kubectl apply → destructive"
assert_eq "destructive	kube-write:delete" "$(C kube -- delete pod foo)" "kubectl delete → destructive"
assert_eq "destructive	kube-write:scale" "$(C kube -- scale deploy/foo --replicas=3)" "kubectl scale → destructive"
assert_eq "destructive	kube-write:rollout" "$(C kube -- rollout restart deploy/foo)" "kubectl rollout → destructive"
assert_eq "destructive	kube-write:exec" "$(C kube -- exec foo -- bash)" "kubectl exec → destructive (셸 분기)"
assert_eq "destructive	kube-write:cp" "$(C kube -- cp foo:/etc x)" "kubectl cp → destructive"
assert_eq "destructive	kube-write:port-forward" "$(C kube -- port-forward svc/foo 8080)" "kubectl port-forward → destructive"
assert_eq "destructive	kube-write:drain" "$(C kube -- drain node-1)" "kubectl drain → destructive"
# 미지 서브커맨드 → fail-closed
assert_eq "destructive	fallback-deny" "$(C kube -- frobnicate-resource)" "kubectl 미지 서브커맨드 → fallback-deny"
# 인자 없음 → fail-closed
assert_eq "destructive	fallback-deny" "$(C kube --)" "kubectl 인자 없음 → fallback-deny"
assert_eq "destructive	fallback-deny" "$(C kube)" "kubectl '--' 없음 → fallback-deny"

finish; echo "PASS test_classify"
