#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

FONT_DIR=".font"
SOURCE_SANS_VF_DIR="$FONT_DIR/source-sans-vf"
FIXTURE_DIR="cappan_core/src/fixture"

# Source Sans 3 VF Subset for variable font tests
SOURCE_VF="$SOURCE_SANS_VF_DIR/SourceSans3VF-Upright.ttf"

if [ ! -f "$SOURCE_VF" ]; then
  echo "ERROR: $SOURCE_VF not found. Run 'make fetch-asset' first." >&2
  exit 1
fi

if ! command -v pyftsubset >/dev/null 2>&1; then
  echo "ERROR: pyftsubset not found. Install fonttools: pip install fonttools" >&2
  exit 1
fi

OUTPUT="$FIXTURE_DIR/SourceSans3VF-Subset.ttf"

if [ -f "$OUTPUT" ]; then
  echo "  OK: SourceSans3VF-Subset.ttf (cached)"
  exit 0
fi

echo "Generating SourceSans3VF-Subset.ttf..."
mkdir -p "$FIXTURE_DIR"
pyftsubset "$SOURCE_VF" \
  --output-file="$OUTPUT" \
  --unicodes="U+0041-0043,U+0061-0063,U+0020-007E" \
  --layout-features="" \
  --drop-tables="DSIG,GPOS,GSUB,GDEF,BASE,MATH,STAT,MVAR,HVAR,VVAR,avar,cvar"

echo "  OK: SourceSans3VF-Subset.ttf ($(wc -c < "$OUTPUT") bytes)"
echo "Done."
