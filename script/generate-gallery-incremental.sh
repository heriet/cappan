#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib/gallery.sh
gallery_reexec_in_container_once "$0" "$@"

FONT="cappan_doc/asset/font/NotoSansCJKjp-Regular.otf"
TEXT="あのイーハトーヴォのすきとおった風"
OUT="cappan_doc/content/guide/image/incremental-rendering"
SIZE=64
FPS=24
FRAMES=96
HOLD=24

mkdir -p "$OUT"
gallery_build

gallery_animate sweep_ltr_seq      --strategy sweep --sweep-direction left-to-right --timing sequential
gallery_animate sweep_ltr_sim      --strategy sweep --sweep-direction left-to-right --timing simultaneous
gallery_animate sweep_ttb_seq      --strategy sweep --sweep-direction top-to-bottom --timing sequential
gallery_animate sweep_ltr_overlap03 --strategy sweep --timing "overlap:0.3"
gallery_animate sweep_ltr_overlap07 --strategy sweep --timing "overlap:0.7"
gallery_animate fade_seq           --strategy fade --timing sequential
gallery_animate fade_sim           --strategy fade --timing simultaneous
gallery_animate contour_font_seq   --strategy contour-trace --contour-ordering font-order --timing sequential
gallery_animate contour_stroke_seq --strategy contour-trace --contour-ordering stroke-heuristic --timing sequential
gallery_animate contour_area_seq   --strategy contour-trace --contour-ordering area-priority --timing sequential
gallery_animate contour_writing_seq --strategy contour-trace --contour-ordering writing-order --timing sequential
gallery_animate contour_writing_rev  --strategy contour-trace --contour-ordering writing-order --timing sequential --reverse
gallery_animate medial_axis_seq      --strategy medial-axis --timing sequential
gallery_animate medial_axis_sim      --strategy medial-axis --timing simultaneous
gallery_animate medial_axis_writing  --strategy medial-axis --contour-ordering writing-order --timing sequential
gallery_animate distance_field_seq   --strategy distance-field --timing sequential
gallery_animate distance_field_sim   --strategy distance-field --timing simultaneous
gallery_animate extrema_wave_seq     --strategy extrema-wave --timing sequential
gallery_animate extrema_wave_sim     --strategy extrema-wave --timing simultaneous
gallery_animate extrema_wave_inv_seq --strategy extrema-wave --extrema-invert  --timing sequential
gallery_animate extrema_wave_inv_sim --strategy extrema-wave --extrema-invert  --timing simultaneous
gallery_animate sweep_easeio_seq     --strategy sweep --timing sequential --easing ease-in-out
gallery_animate medial_axis_writing_weighted --strategy medial-axis --contour-ordering writing-order --timing weighted
gallery_animate contour_writing_weighted --strategy contour-trace --contour-ordering writing-order --timing weighted
gallery_animate skeleton_grow_weighted --strategy skeleton-grow --timing weighted
gallery_animate skeleton_grow_seq    --strategy skeleton-grow --timing sequential
gallery_animate skeleton_grow_sim    --strategy skeleton-grow --timing simultaneous
gallery_animate tangent_flow_seq     --strategy tangent-flow --timing sequential
gallery_animate tangent_flow_sim     --strategy tangent-flow --timing simultaneous

echo "Done. Generated $(ls "$OUT"/*.png | wc -l) incremental rendering images in $OUT/"
