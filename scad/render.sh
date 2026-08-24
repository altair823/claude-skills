#!/usr/bin/env bash
# scad build+render loop: STL + 3MF + 다각도 PNG + 단면 + 치수 요약
# usage: render.sh part.scad [outdir]
set -euo pipefail

OSCAD=${OPENSCAD:-$HOME/bin/openscad-nightly}
[ -x "$OSCAD" ] || { echo "openscad 없음: $OSCAD" >&2; exit 127; }

in=$1
out=${2:-$(dirname "$in")/renders}
b=$(basename "$in" .scad)
mkdir -p "$out"

# --hardwarnings 는 협상 불가: 없으면 미정의 변수가 exit 0 으로 통과하며 틀린 STL 을 쓴다
echo "== export =="
"$OSCAD" --hardwarnings -o "$out/$b.stl" --export-format binstl \
         --summary geometry --summary bounding-box \
         --summary-file "$out/$b.json" "$in" 2>&1 | grep -iE 'error|warn|assert' || true
"$OSCAD" --hardwarnings -o "$out/$b.3mf" "$in" >/dev/null 2>&1

echo "== render (EGL, DISPLAY 불필요) =="
# gimbal camera: tx,ty,tz,rx,ry,rz,dist — dist=0 + --viewall 이면 자동 맞춤
for v in iso:0,0,0,55,0,25,0 \
         front:0,0,0,90,0,0,0 \
         right:0,0,0,90,0,90,0 \
         bottom:0,0,0,180,0,0,0 ; do
  n=${v%%:*}
  "$OSCAD" -o "$out/${b}_$n.png" --imgsize=800,600 --viewall --autocenter \
           --colorscheme=Tomorrow --camera="${v#*:}" "$in" >/dev/null 2>&1
done

# 단면: 모델이 cut 변수를 지원할 때만 (SKILL.md 의 show() 규약)
if grep -q 'cut *=' "$in"; then
  "$OSCAD" -o "$out/${b}_section.png" --imgsize=800,600 --viewall --autocenter \
           --colorscheme=Tomorrow --camera=0,0,0,55,0,25,0 -D cut=1 "$in" >/dev/null 2>&1
else
  echo "  (cut 변수 없음 — 단면 생략. 내부 구조가 있으면 show()/cut 규약을 넣을 것)" >&2
fi

# simple=true 여야 닫힌 입체다. size 가 의도한 치수(mm)와 맞는지 확인할 것.
echo "== summary =="
cat "$out/$b.json"; echo
ls -1 "$out"/${b}*.png
