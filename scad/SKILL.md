---
name: scad
description: OpenSCAD로 3D 프린팅용 파트를 만들고 헤드리스 렌더로 스스로 검증한다. 3D 모델, 프린트, STL, 3MF, 브래킷, 홀더, 케이스, 지그, 어댑터, 마운트 같은 물리 부품 제작 요청에 사용.
---

# scad — 3D 프린팅 파트 제작

`~/bin/openscad-nightly` (2026.08.23, EGL 내장) 를 쓴다. apt 의 `openscad`(2021.01) 는
DISPLAY 없으면 세그폴트하고 0바이트 PNG 를 남기므로 **쓰지 않는다**.

## 명령

```bash
~/.claude/skills/scad/render.sh part.scad
# → renders/part.stl  part.3mf  part_iso.png  _front  _right  _bottom  _section.png  part.json
```

## 비협상 규칙

1. **`--hardwarnings` 를 절대 빼지 않는다.** render.sh 가 이미 붙인다. 직접 openscad 를
   부를 때도 반드시 붙인다. 없으면 `cube([10,10,zz])` 처럼 정의되지 않은 변수가
   경고만 내고 **exit 0 으로 틀린 STL 을 써버린다.** 루프에서 영원히 눈치채지 못한다.

2. **PNG 를 실제로 Read 툴로 읽는다.** 파일 경로를 `ls` 로 본 것은 렌더를 본 것이 아니다.
   기하를 바꿀 때마다 최소 **iso, bottom, section** 세 장을 눈으로 확인한다.
   bottom 을 빼지 말 것 — 베드에 닿는 면의 버그(구멍이 안 뚫림, 지오메트리가 떠 있음)는
   다른 각도에서 보이지 않는다.

3. **치수를 지어내지 않는다.** M3 볼트, 608 베어링, USB-C, 라즈베리파이 홀 간격 같은
   실제 부품 치수는 먼저 웹 검색으로 확인한다. 1~2mm 틀리면 파트가 못 쓰게 된다.

4. **메시를 손으로 고치지 않는다.** 항상 `.scad` 소스를 고치고 다시 내보낸다.

5. **모든 치수는 파일 맨 위 PARAMETERS 블록의 변수로 뺀다.** 리터럴을 기하 안에 박지 않는다.

6. **제약은 `assert()` 로 코드에 박는다.** 실패하면 exit 1 이라 루프가 자동으로 잡는다.
   렌더를 보는 것보다 싸고 정확하다.

7. **완료 조건**: exit 0 + PNG 를 실제로 확인 + assert 전부 통과 +
   `part.json` 의 `simple: true` 이고 `size` 가 의도한 치수와 일치.
   이 중 하나라도 확인 안 했으면 완료라고 말하지 않는다.

## 파일 뼈대 — 항상 이 형태로 시작한다

```scad
// units: mm
$fn = 64;
eps = 0.01;   // z-fighting 방지용. 관통 구멍은 항상 양쪽으로 eps 씩 더 뚫는다.

/* ---- PARAMETERS ---- */
plate = 40;
thick = 6;
bolt  = 3.4;   // M3 관통 = 공칭 +0.2~0.4 (refs/fdm.md 참고)

/* ---- CHECKS ---- */
assert(thick >= 1.2, "wall too thin for 0.4mm nozzle");

/* ---- MODEL ---- */
cut = 0;   // render.sh 가 -D cut=1 로 단면을 뽑는다
module show() {
    if (cut) difference() { children(); translate([-500,-500,-500]) cube([500,1000,1000]); }
    else children();
}

module part() {
    difference() {
        cube([plate, plate, thick], center = true);
        // 관통 구멍: 양쪽으로 eps 더 뚫어 coplanar face 를 피한다
        translate([0,0,-thick]) cylinder(h = thick*2 + eps, d = bolt);
    }
}

show() part();
```

`cut = 0;` 과 `show()` 를 빼면 단면 렌더가 생략된다. 내부 구조·관통 구멍이 있으면
반드시 넣는다. 겉 렌더로는 구멍이 안 뚫린 것을 볼 수 없다.

## 공차

`refs/fdm.md` 를 읽는다. 끼워 맞춤·구멍 지름·오버행이 걸리는 파트를 만들 때는 **먼저** 읽는다.

## 이 스킬을 벗어나야 할 때

임의 모서리의 **진짜 필렛/챔퍼**, **STEP 출력**, 나사산·기어 같은 표준 부품이 필요하면
OpenSCAD 로 억지로 하지 말고 (`minkowski`/`hull` 은 느리고 결과가 나쁘다)
**build123d** (파이썬 B-Rep) 로 갈아탈 것을 사용자에게 제안한다.
