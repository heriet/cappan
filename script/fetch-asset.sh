#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

FONT_DIR=".font"
mkdir -p "$FONT_DIR"

DEJAVU_TTF_SHA256="7da195a74c55bef988d0d48f9508bd5d849425c1770dba5d7bfc6ce9ed848954"
DEJAVU_WOFF2_SHA256="977c1f35fe0be181a68683c3b4db20f05b898a0b12d048d4d6345034866aeb6d"
SOURCE_SANS_SHA256="08df266400933d3178d081a45f94a08814c3e55b4b7dd2e0ff69cb1329f13ab6"
NOTO_SANS_CJK_SHA256="68a3fc98800b2a27b371f2fb79991daf3633bd89309d4ffaa6946fd587f375b5"
NOTO_SANS_JP_SHA256="dff723ba59d57d136764a04b9b2d03205544f7cd785a711442d6d2d085ac5073"
NOTO_SANS_ARABIC_SHA256="bd86ca02f087d7f3c3788ba458fb6b73744c7639ed276b8d870dba6def6c40d0"
BROTLI_DICT_SHA256="20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70"
TEST_COLR_V1_SHA256="e87738d4e9f7f319e34045340c0a17bba948ed638345aba47d4a0d7d6d09f163"
TEST_GLYPHS_COLR_1_SHA256="8aa611b1ca97044ac6f13dc982fde29256612f0a5acc6ef47ca541a7a5b99b28"
TEST_GLYPHS_COLR_1_VAR_SHA256="ad575a09d6748aebcb3b90ffd384c64d5c64b5fd9927967e7cd7cc0d70c98d34"
SOURCE_SANS_VF_UPRIGHT_SHA256="1147db9a3f0edd4956068de77930148acce2742dd76d57f7239b2b1c687ac63f"
SOURCE_SANS_VF_ITALIC_SHA256="c34791f4f889af43d84e2f84ebeb02e6eed07058aca21e6729d26e6436d18965"

verify_sha256() {
  local file="$1" expected="$2"
  local actual
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  [ "$actual" = "$expected" ]
}

file_ok() {
  local file="$1" expected="$2"
  [ -f "$file" ] && verify_sha256 "$file" "$expected"
}

# --- DejaVuSans.ttf ---
if ! file_ok "$FONT_DIR/DejaVuSans.ttf" "$DEJAVU_TTF_SHA256"; then
  echo "Downloading DejaVu Sans 2.37..."
  tmpdir=$(mktemp -d)
  curl -fsSL "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip" \
    -o "$tmpdir/dejavu.zip"
  unzip -q "$tmpdir/dejavu.zip" -d "$tmpdir"
  mv "$tmpdir/dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf" "$FONT_DIR/DejaVuSans.ttf"
  mv "$tmpdir/dejavu-fonts-ttf-2.37/LICENSE" "$FONT_DIR/LICENSE-DejaVuSans.txt"
  rm -rf "$tmpdir"
  if ! verify_sha256 "$FONT_DIR/DejaVuSans.ttf" "$DEJAVU_TTF_SHA256"; then
    echo "ERROR: DejaVuSans.ttf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: DejaVuSans.ttf"
else
  echo "  OK: DejaVuSans.ttf (cached)"
fi

# --- DejaVuSans.woff2 (convert from ttf) ---
if ! file_ok "$FONT_DIR/DejaVuSans.woff2" "$DEJAVU_WOFF2_SHA256"; then
  if command -v woff2_compress >/dev/null 2>&1; then
    echo "Converting DejaVuSans.ttf → woff2..."
    cp "$FONT_DIR/DejaVuSans.ttf" "$FONT_DIR/DejaVuSans_tmp.ttf"
    woff2_compress "$FONT_DIR/DejaVuSans_tmp.ttf"
    mv "$FONT_DIR/DejaVuSans_tmp.woff2" "$FONT_DIR/DejaVuSans.woff2"
    rm -f "$FONT_DIR/DejaVuSans_tmp.ttf"
    if ! verify_sha256 "$FONT_DIR/DejaVuSans.woff2" "$DEJAVU_WOFF2_SHA256"; then
      echo "WARNING: DejaVuSans.woff2 checksum mismatch (woff2_compress version difference)" >&2
      echo "  The generated file will be used but may differ from the original." >&2
    fi
    echo "  OK: DejaVuSans.woff2"
  else
    echo "WARNING: woff2_compress not found, skipping DejaVuSans.woff2" >&2
    echo "  Install woff2 package: apt-get install woff2" >&2
  fi
else
  echo "  OK: DejaVuSans.woff2 (cached)"
fi

# --- SourceSans3-Regular.otf ---
if ! file_ok "$FONT_DIR/SourceSans3-Regular.otf" "$SOURCE_SANS_SHA256"; then
  echo "Downloading Source Sans 3.052R..."
  tmpdir=$(mktemp -d)
  curl -fsSL "https://github.com/adobe-fonts/source-sans/releases/download/3.052R/OTF-source-sans-3.052R.zip" \
    -o "$tmpdir/source-sans.zip"
  unzip -q -j "$tmpdir/source-sans.zip" "OTF/SourceSans3-Regular.otf" -d "$tmpdir"
  mv "$tmpdir/SourceSans3-Regular.otf" "$FONT_DIR/SourceSans3-Regular.otf"
  curl -fsSL "https://raw.githubusercontent.com/adobe-fonts/source-sans/release/LICENSE.md" \
    -o "$FONT_DIR/LICENSE-SourceSans3.md"
  rm -rf "$tmpdir"
  if ! verify_sha256 "$FONT_DIR/SourceSans3-Regular.otf" "$SOURCE_SANS_SHA256"; then
    echo "ERROR: SourceSans3-Regular.otf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: SourceSans3-Regular.otf"
else
  echo "  OK: SourceSans3-Regular.otf (cached)"
fi

# --- NotoSansCJKjp-Regular.otf ---
if ! file_ok "$FONT_DIR/NotoSansCJKjp-Regular.otf" "$NOTO_SANS_CJK_SHA256"; then
  echo "Downloading Noto Sans CJK JP 2.004..."
  tmpdir=$(mktemp -d)
  curl -fsSL "https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/06_NotoSansCJKjp.zip" \
    -o "$tmpdir/noto-cjk.zip"
  unzip -q "$tmpdir/noto-cjk.zip" -d "$tmpdir"
  mv "$tmpdir/NotoSansCJKjp-Regular.otf" "$FONT_DIR/NotoSansCJKjp-Regular.otf"
  mv "$tmpdir/LICENSE" "$FONT_DIR/LICENSE-NotoSansCJK.txt"
  rm -rf "$tmpdir"
  if ! verify_sha256 "$FONT_DIR/NotoSansCJKjp-Regular.otf" "$NOTO_SANS_CJK_SHA256"; then
    echo "ERROR: NotoSansCJKjp-Regular.otf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: NotoSansCJKjp-Regular.otf"
else
  echo "  OK: NotoSansCJKjp-Regular.otf (cached)"
fi

# --- NotoSansJP-Regular.otf ---
if ! file_ok "$FONT_DIR/NotoSansJP-Regular.otf" "$NOTO_SANS_JP_SHA256"; then
  echo "Downloading Noto Sans JP 2.004..."
  tmpdir=$(mktemp -d)
  curl -fsSL "https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/16_NotoSansJP.zip" \
    -o "$tmpdir/noto-jp.zip"
  unzip -q "$tmpdir/noto-jp.zip" -d "$tmpdir"
  mv "$tmpdir/NotoSansJP-Regular.otf" "$FONT_DIR/NotoSansJP-Regular.otf"
  mv "$tmpdir/LICENSE" "$FONT_DIR/LICENSE-NotoSansJP.txt"
  rm -rf "$tmpdir"
  if ! verify_sha256 "$FONT_DIR/NotoSansJP-Regular.otf" "$NOTO_SANS_JP_SHA256"; then
    echo "ERROR: NotoSansJP-Regular.otf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: NotoSansJP-Regular.otf"
else
  echo "  OK: NotoSansJP-Regular.otf (cached)"
fi

# --- NotoSansArabic-Regular.ttf ---
if ! file_ok "$FONT_DIR/NotoSansArabic-Regular.ttf" "$NOTO_SANS_ARABIC_SHA256"; then
  echo "Downloading Noto Sans Arabic 2.013..."
  tmpdir=$(mktemp -d)
  curl -fsSL "https://github.com/notofonts/arabic/releases/download/NotoSansArabic-v2.013/NotoSansArabic-v2.013.zip" \
    -o "$tmpdir/noto-arabic.zip"
  unzip -q -j "$tmpdir/noto-arabic.zip" \
    "NotoSansArabic/unhinted/ttf/NotoSansArabic-Regular.ttf" "OFL.txt" -d "$tmpdir"
  mv "$tmpdir/NotoSansArabic-Regular.ttf" "$FONT_DIR/NotoSansArabic-Regular.ttf"
  mv "$tmpdir/OFL.txt" "$FONT_DIR/LICENSE-NotoSansArabic.txt"
  rm -rf "$tmpdir"
  if ! verify_sha256 "$FONT_DIR/NotoSansArabic-Regular.ttf" "$NOTO_SANS_ARABIC_SHA256"; then
    echo "ERROR: NotoSansArabic-Regular.ttf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: NotoSansArabic-Regular.ttf"
else
  echo "  OK: NotoSansArabic-Regular.ttf (cached)"
fi

# --- brotli_dictionary.bin ---
if ! file_ok "$FONT_DIR/brotli_dictionary.bin" "$BROTLI_DICT_SHA256"; then
  echo "Downloading Brotli dictionary (google/brotli v1.1.0)..."
  curl -fsSL "https://raw.githubusercontent.com/google/brotli/v1.1.0/c/common/dictionary.bin" \
    -o "$FONT_DIR/brotli_dictionary.bin"
  if ! verify_sha256 "$FONT_DIR/brotli_dictionary.bin" "$BROTLI_DICT_SHA256"; then
    echo "ERROR: brotli_dictionary.bin checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: brotli_dictionary.bin"
else
  echo "  OK: brotli_dictionary.bin (cached)"
fi

# --- TestCOLRv1.ttf (COLR v1 test font, MIT, HarfBuzz) ---
if ! file_ok "$FONT_DIR/TestCOLRv1.ttf" "$TEST_COLR_V1_SHA256"; then
  echo "Downloading TestCOLRv1.ttf (HarfBuzz test font)..."
  curl -fsSL "https://raw.githubusercontent.com/harfbuzz/harfbuzz/main/test/subset/data/fonts/TestCOLRv1.ttf" \
    -o "$FONT_DIR/TestCOLRv1.ttf"
  if ! verify_sha256 "$FONT_DIR/TestCOLRv1.ttf" "$TEST_COLR_V1_SHA256"; then
    echo "ERROR: TestCOLRv1.ttf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: TestCOLRv1.ttf"
else
  echo "  OK: TestCOLRv1.ttf (cached)"
fi

# --- test_glyphs-glyf_colr_1.ttf (COLR v1 test font, Apache 2.0, googlefonts) ---
if ! file_ok "$FONT_DIR/test_glyphs-glyf_colr_1.ttf" "$TEST_GLYPHS_COLR_1_SHA256"; then
  echo "Downloading test_glyphs-glyf_colr_1.ttf (googlefonts color-fonts)..."
  curl -fsSL "https://raw.githubusercontent.com/googlefonts/color-fonts/main/fonts/test_glyphs-glyf_colr_1.ttf" \
    -o "$FONT_DIR/test_glyphs-glyf_colr_1.ttf"
  if ! verify_sha256 "$FONT_DIR/test_glyphs-glyf_colr_1.ttf" "$TEST_GLYPHS_COLR_1_SHA256"; then
    echo "ERROR: test_glyphs-glyf_colr_1.ttf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: test_glyphs-glyf_colr_1.ttf"
else
  echo "  OK: test_glyphs-glyf_colr_1.ttf (cached)"
fi

# --- test_glyphs-glyf_colr_1_variable.ttf (variable COLR v1 test font, Apache 2.0, googlefonts) ---
if ! file_ok "$FONT_DIR/test_glyphs-glyf_colr_1_variable.ttf" "$TEST_GLYPHS_COLR_1_VAR_SHA256"; then
  echo "Downloading test_glyphs-glyf_colr_1_variable.ttf (googlefonts color-fonts)..."
  curl -fsSL "https://raw.githubusercontent.com/googlefonts/color-fonts/main/fonts/test_glyphs-glyf_colr_1_variable.ttf" \
    -o "$FONT_DIR/test_glyphs-glyf_colr_1_variable.ttf"
  if ! verify_sha256 "$FONT_DIR/test_glyphs-glyf_colr_1_variable.ttf" "$TEST_GLYPHS_COLR_1_VAR_SHA256"; then
    echo "ERROR: test_glyphs-glyf_colr_1_variable.ttf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: test_glyphs-glyf_colr_1_variable.ttf"
else
  echo "  OK: test_glyphs-glyf_colr_1_variable.ttf (cached)"
fi

# --- SourceSans3-Variable.ttf ---
SOURCE_SANS_VF_DIR="$FONT_DIR/source-sans-vf"
if ! file_ok "$SOURCE_SANS_VF_DIR/SourceSans3VF-Upright.ttf" "$SOURCE_SANS_VF_UPRIGHT_SHA256" ||
   ! file_ok "$SOURCE_SANS_VF_DIR/SourceSans3VF-Italic.ttf" "$SOURCE_SANS_VF_ITALIC_SHA256"; then
  echo "Downloading Source Sans 3 Variable 3.052R..."
  tmpdir=$(mktemp -d)
  curl -fsSL "https://github.com/adobe-fonts/source-sans/releases/download/3.052R/VF-source-sans-3.052R.zip" \
    -o "$tmpdir/source-sans-vf.zip"
  unzip -q "$tmpdir/source-sans-vf.zip" -d "$tmpdir"
  mkdir -p "$SOURCE_SANS_VF_DIR"
  find "$tmpdir" -name "*.ttf" -exec cp {} "$SOURCE_SANS_VF_DIR/" \;
  rm -rf "$tmpdir"
  if ! verify_sha256 "$SOURCE_SANS_VF_DIR/SourceSans3VF-Upright.ttf" "$SOURCE_SANS_VF_UPRIGHT_SHA256"; then
    echo "ERROR: SourceSans3VF-Upright.ttf checksum mismatch" >&2
    exit 1
  fi
  if ! verify_sha256 "$SOURCE_SANS_VF_DIR/SourceSans3VF-Italic.ttf" "$SOURCE_SANS_VF_ITALIC_SHA256"; then
    echo "ERROR: SourceSans3VF-Italic.ttf checksum mismatch" >&2
    exit 1
  fi
  echo "  OK: Source Sans 3 Variable"
else
  echo "  OK: Source Sans 3 Variable (cached)"
fi

# --- Copy to target locations ---
echo "Copying fonts to target locations..."

copy_font() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
}

copy_font "$FONT_DIR/DejaVuSans.ttf" cappan_core/src/fixture/DejaVuSans.ttf
copy_font "$FONT_DIR/DejaVuSans.ttf" cappan_embed/src/fixture/DejaVuSans.ttf
copy_font "$FONT_DIR/DejaVuSans.ttf" cappan_inspect/src/fixture/DejaVuSans.ttf
copy_font "$FONT_DIR/DejaVuSans.ttf" cappan_metrics/src/fixture/DejaVuSans.ttf
copy_font "$FONT_DIR/DejaVuSans.ttf" cappan_pathify/src/fixture/DejaVuSans.ttf
copy_font "$FONT_DIR/DejaVuSans.ttf" cappan_subset/src/fixture/DejaVuSans.ttf

if [ -f "$FONT_DIR/DejaVuSans.woff2" ]; then
  copy_font "$FONT_DIR/DejaVuSans.woff2" cappan_core/src/fixture/DejaVuSans.woff2
fi

copy_font "$FONT_DIR/SourceSans3-Regular.otf" cappan_core/src/fixture/SourceSans3-Regular.otf
copy_font "$FONT_DIR/NotoSansCJKjp-Regular.otf" cappan_doc/asset/font/NotoSansCJKjp-Regular.otf
copy_font "$FONT_DIR/NotoSansJP-Regular.otf" cappan_wasm/src/asset/font/NotoSansJP-Regular.otf
copy_font "$FONT_DIR/brotli_dictionary.bin" cappan_core/src/compress/brotli_dictionary.bin

echo "Done."
