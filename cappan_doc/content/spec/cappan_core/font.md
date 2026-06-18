# font

フォントファイルのパース、グリフアウトライン取得、メトリクス参照などを行うモジュール群です。

---

## Font

フォントファイルをパースし、グリフアウトライン・メトリクス・カーニング等を取得するための高レベルAPI。TTF/OTF/WOFF/WOFF2 を透過的に扱います。WOFF/WOFF2 は内部で自動的にSFNT形式に変換されます。

### 初期化・解放

```zig
// フォントデータからパース（TTF/OTF/WOFF/WOFF2 を自動判別）
pub fn init(allocator: Allocator, data: []const u8, diag: ?*Diagnostics) !Font

// TTC（TrueType Collection）内の特定フォントを指定して読み込み
pub fn initCollectionIndex(allocator: Allocator, data: []const u8, font_index: u32, diag: ?*Diagnostics) !Font

// TTC内のフォント数を取得
pub fn countFontsInCollection(allocator: Allocator, data: []const u8) !u32

pub fn deinit(self: *Font) void
```

`diag` に `Diagnostics` を渡すと、パース中の警告・エラー情報を収集できます。不要なら `null` を渡してください。

### グリフ取得

```zig
// Unicode コードポイントからグリフ ID を取得（cmap テーブル経由）
pub fn getGlyphId(self: Font, codepoint: u32) !u16

// グリフ ID からアウトラインデータを取得（TrueType / CFF を自動判別）
// アウトラインが存在しないグリフ（スペース等）は null を返す
pub fn getGlyphOutline(self: Font, allocator: Allocator, glyph_id: u16) !?GlyphOutline
```

### メトリクス

```zig
pub fn getUnitsPerEm(self: Font) u16       // フォント設計単位（通常 1000 or 2048）
pub fn getAscender(self: Font) i16          // アセンダー（ベースラインからの上方向距離）
pub fn getDescender(self: Font) i16         // ディセンダー（負値）
pub fn getLineGap(self: Font) i16           // 行間ギャップ
pub fn getHMetrics(self: Font, glyph_id: u16) !HMetrics  // advance_width, lsb
pub fn getKerning(self: Font, left: u16, right: u16) i16  // GPOS または kern テーブル
```

`getHMetrics` が返す `HMetrics` は `advance_width`（送り幅）と `lsb`（左サイドベアリング）を持ちます。ピクセル座標への変換は `value * pixel_size / units_per_em` で行います。

### カラーフォント (COLR/CPAL)

COLRv0 テーブルによるカラーグリフレイヤーと、CPAL テーブルによるカラーパレットにアクセスできます。

```zig
pub fn getColorLayers(self: Font, glyph_id: u16) ?BaseGlyphRecord
pub fn getColorLayer(self: Font, layer_idx: u16) ?ColorLayer
pub fn getPaletteColor(self: Font, palette_idx: u16, entry_idx: u16) ?Color
```

### ユーティリティ

```zig
// テキスト幅の測定（カーニング込み、ピクセル単位）
pub fn measureTextWidth(self: Font, text: []const u8, pixel_size: f32) f32

// 単一文字をラスタライズ（Font.getGlyphOutline + rasterizeGlyph のショートカット）
pub fn rasterizeCodepoint(self: Font, allocator: Allocator, codepoint: u32, pixel_size: f32) !?RasterResult

// 単一文字の送り幅をピクセル単位で取得
pub fn getCodepointAdvancePx(self: Font, codepoint: u32, pixel_size: f32) !f32

// フォント名情報（name テーブルから取得、呼び出し側が free する）
pub fn getFontFamily(self: Font, allocator: Allocator) !?[]u8
pub fn getFontSubfamily(self: Font, allocator: Allocator) !?[]u8
pub fn getFullFontName(self: Font, allocator: Allocator) !?[]u8
```

---

## glyph — グリフアウトラインデータ

`Font.getGlyphOutline()` が返すアウトラインデータの型定義です。

```zig
pub const Point = struct {
    x: i16,                   // フォント設計単位での座標
    y: i16,
    on_curve: bool,           // true = 直線の端点、false = 制御点
    is_cubic: bool = false,   // true = CFF の三次ベジェ制御点
};

pub const Contour = struct {
    points: []Point,          // 閉じたパスを構成する点列
};

pub const GlyphOutline = struct {
    contours: []Contour,
    x_min: i16, y_min: i16,  // バウンディングボックス
    x_max: i16, y_max: i16,
    allocator: Allocator,
    pub fn deinit(self: *GlyphOutline) void;
};
```

TrueType フォントは二次ベジェ曲線（`on_curve=false, is_cubic=false`）、CFF/OpenType フォントは三次ベジェ曲線（`is_cubic=true`）を使用します。TrueType では連続するオフカーブ点間に暗黙のオンカーブ中間点が挿入されます。

---

## WOFF / WOFF2 変換

WOFF および WOFF2 形式のフォントを SFNT（TTF/OTF）形式に変換する低レベルAPI。通常は `Font.init()` が自動的に呼び出すため、直接使う必要はありません。

```zig
// WOFF1
pub fn isWoffFile(data: []const u8) bool
pub fn woffToSfnt(allocator: Allocator, woff_data: []const u8) ![]u8

// WOFF2（Brotli展開 + glyf/loca テーブル再構築を含む）
pub fn isWoff2File(data: []const u8) bool
pub fn woff2ToSfnt(allocator: Allocator, woff2_data: []const u8) ![]u8
```

### Brotli 展開

WOFF2 内部で使用される Brotli 圧縮データの展開。RFC 7932 準拠の pure Zig 実装です。

```zig
pub fn decompress(compressed: []const u8, dest: []u8) !usize;
pub fn decompressAlloc(allocator: Allocator, compressed: []const u8, max_size: usize) ![]u8;
```
