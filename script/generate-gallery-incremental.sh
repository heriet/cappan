#!/usr/bin/env bash
set -euo pipefail

CAPPAN="docker compose run --rm dev zig build run --"
FONT="cappan_doc/asset/font/NotoSansCJKjp-Regular.otf"
TEXT="あのイーハトーヴォのすきとおった風"
OUT="cappan_doc/content/guide/image/incremental-rendering"
SIZE=64
FPS=24
FRAMES=144
HOLD=24

mkdir -p "$OUT"

animate() {
  local name="$1"; shift
  echo "Generating $name..."
  $CAPPAN animate \
    --font "$FONT" --text "$TEXT" --size "$SIZE" \
    --frames "$FRAMES" --fps "$FPS" --hold "$HOLD" \
    "$@" \
    --output "$OUT/$name.png"
}

animate sweep_ltr_seq      --strategy sweep --sweep-direction left-to-right --timing sequential
animate sweep_ltr_sim      --strategy sweep --sweep-direction left-to-right --timing simultaneous
animate sweep_ttb_seq      --strategy sweep --sweep-direction top-to-bottom --timing sequential
animate sweep_ltr_overlap03 --strategy sweep --timing "overlap:0.3"
animate sweep_ltr_overlap07 --strategy sweep --timing "overlap:0.7"
animate fade_seq           --strategy fade --timing sequential
animate fade_sim           --strategy fade --timing simultaneous
animate contour_font_seq   --strategy contour-trace --contour-ordering font-order --timing sequential
animate contour_stroke_seq --strategy contour-trace --contour-ordering stroke-heuristic --timing sequential
animate contour_area_seq   --strategy contour-trace --contour-ordering area-priority --timing sequential
animate contour_writing_seq --strategy contour-trace --contour-ordering writing-order --timing sequential
animate contour_writing_rev  --strategy contour-trace --contour-ordering writing-order --timing sequential --reverse
animate medial_axis_seq      --strategy medial-axis --timing sequential
animate medial_axis_sim      --strategy medial-axis --timing simultaneous
animate medial_axis_writing  --strategy medial-axis --contour-ordering writing-order --timing sequential
animate distance_field_seq   --strategy distance-field --timing sequential
animate distance_field_sim   --strategy distance-field --timing simultaneous
animate extrema_wave_seq     --strategy extrema-wave --timing sequential
animate extrema_wave_sim     --strategy extrema-wave --timing simultaneous
animate extrema_wave_inv_seq --strategy extrema-wave --extrema-invert  --timing sequential
animate extrema_wave_inv_sim --strategy extrema-wave --extrema-invert  --timing simultaneous
animate sweep_easeio_seq     --strategy sweep --timing sequential --easing ease-in-out
animate medial_axis_writing_weighted --strategy medial-axis --contour-ordering writing-order --timing weighted
animate contour_writing_weighted --strategy contour-trace --contour-ordering writing-order --timing weighted
animate skeleton_grow_weighted --strategy skeleton-grow --timing weighted
animate skeleton_grow_seq    --strategy skeleton-grow --timing sequential
animate skeleton_grow_sim    --strategy skeleton-grow --timing simultaneous
animate tangent_flow_seq     --strategy tangent-flow --timing sequential
animate tangent_flow_sim     --strategy tangent-flow --timing simultaneous


echo "Done. Generated $(ls "$OUT"/*.png | wc -l) incremental rendering images in $OUT/"
