#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib/gallery.sh
gallery_reexec_in_container_once "$0" "$@"

FONT="cappan_doc/asset/font/NotoSansCJKjp-Regular.otf"
TEXT="あのイーハトーヴォのすきとおった風"
OUT="cappan_doc/content/guide/image/stroke-paint"
SIZE=64
FPS=24
FRAMES=96
HOLD=24

mkdir -p "$OUT"
gallery_build

gallery_render stroke_outside_red \
  --stroke "2px,000000" \
  --fill "F05030"

gallery_render stroke_multi_layer \
  --stroke "8px,000000" \
  --stroke "4px,FFFFFF" \
  --fill "F05030"

gallery_render stroke_center \
  --stroke "4px,0066CC,position=center" \
  --fill "000000"

gallery_render stroke_inside \
  --stroke "4px,CC6600,position=inside" \
  --fill "000000"

gallery_render stroke_join_miter \
  --stroke "6px,000000,join=miter" \
  --fill "F05030"

gallery_render stroke_join_bevel \
  --stroke "6px,000000,join=bevel" \
  --fill "F05030"

gallery_render stroke_opacity \
  --stroke "8px,FF0000,opacity=0.5" \
  --fill "000000,opacity=0.8"

gallery_render stroke_em_unit \
  --stroke "0.15em,0066FF" \
  --fill "FFFFFF"

gallery_render stroke_neon \
  --bg-color "222222" \
  --stroke "6px,00FFFF,opacity=0.4" \
  --stroke "3px,00FFFF,opacity=0.7" \
  --fill "FFFFFF"

gallery_animate stroke_sweep_ltr_seq \
  --strategy sweep --sweep-direction left-to-right --timing sequential \
  --stroke "4px,000000" \
  --fill "F05030"

gallery_animate stroke_contour_writing_seq \
  --strategy contour-trace --contour-ordering writing-order --timing sequential \
  --stroke "4px,000000" \
  --fill "F05030"

echo "Done. Generated $(ls "$OUT"/*.png | wc -l) stroke-paint images in $OUT/"
