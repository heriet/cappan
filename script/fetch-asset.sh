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
BROTLI_DICT_SHA256="20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70"

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
