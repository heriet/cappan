# Overview

- cappan のコアライブラリです。フォントの読み込みからテキストレイアウト、ラスタライズ、ビットマップ出力までの全パイプラインを提供します。

**詳細ドキュメント:**

- [font](font.md) — フォント読み込み・グリフアクセス・WOFF/WOFF2
- [layout](layout.md) — テキストレイアウト・シェーピング
- [raster](raster.md) — ラスタライズ・グリフキャッシュ・アトラステクスチャ
- [render](render.md) — テキストレンダリング・ビットマップ・インクリメンタルレンダリング

---

## クイックスタート

### テキストをRGBAビットマップにレンダリング

```zig
const cappan = @import("cappan_core");
const Font = cappan.font.Font;
const renderer = cappan.render.renderer;

// フォント読み込み
var font = try Font.init(allocator, font_data, null);
defer font.deinit();

// レンダリング
const fonts = [_]Font{font};
var bitmap = try renderer.renderText(allocator, &fonts, "Hello, World!", .{
    .pixel_size = 48.0,
    .fg_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .bg_color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
});
defer bitmap.deinit();

// bitmap.pixels: []u8 (RGBA, width * height * 4 bytes)
// bitmap.width, bitmap.height
```

### ストリーミングレンダリング（行単位）

```zig
const RowRenderer = cappan.render.renderer.RowRenderer;

var row_renderer = try RowRenderer.init(allocator, &fonts, "Hello", .{});
defer row_renderer.deinit();

var y: u32 = 0;
while (y < row_renderer.height) : (y += 1) {
    const row_rgba = row_renderer.renderRow(y); // []const u8 (width * 4)
    // 行ごとにPNGエンコーダ等に渡す
}
```

### テキストレイアウトのみ取得

```zig
const shaper = cappan.layout.shaper;

var layout = try shaper.layoutText(allocator, &fonts, "Hello, World!", .{
    .pixel_size = 48.0,
    .max_width = 200.0,      // ワードラップ
    .text_align = .center,
});
defer layout.deinit();

for (layout.positions) |pos| {
    // pos.glyph_id, pos.x_offset, pos.y_offset, pos.font_index
}
```

### グリフアトラスの利用

```zig
const atlas_mod = cappan.raster.atlas;

var atlas = atlas_mod.GlyphAtlas.init(allocator, .{
    .page_width = 1024,
    .page_height = 1024,
});
defer atlas.deinit();

// グリフを自動ラスタライズしてアトラスにパック
const region = (try atlas.getOrInsert(font, 0, glyph_id, 48.0)) orelse continue;
// region.page, region.x, region.y, region.width, region.height

// ページのピクセルデータを取得（GPU アップロード等）
const pixels = atlas.getPagePixels(region.page).?;
```

### インクリメンタルレンダリング

```zig
const incremental = cappan.render.incremental;

var reveal = try incremental.IncrementalRenderer.init(allocator, &fonts, "Hello", .{
    .pixel_size = 48.0,
    .strategy = .{ .sweep = .{} },  // sweep / fade / contour_trace / medial_axis
    .timing = .sequential,
});
defer reveal.deinit();

// progress: 0.0（非表示）→ 1.0（完全表示）
var frame = try reveal.renderFrame(0.5);
defer frame.deinit();
```

---

## モジュール構成

```
cappan_core
├── font                   フォントパースとグリフデータ
│   ├── Font               高レベルフォントAPI
│   ├── parser             バイナリパーサー（OffsetTable, TableRecord）
│   ├── glyph              グリフアウトライン（Point, Contour, GlyphOutline）
│   ├── charstring         CFF Type2 チャーストリングインタープリタ
│   ├── woff               WOFF1 透過変換
│   ├── woff2              WOFF2 透過変換（Brotli + glyf/loca 変換）
│   └── table              個別テーブルパーサー
│       ├── head, maxp, hhea, cmap, loca, glyf, hmtx
│       ├── kern, gpos, otlayout
│       ├── cff, colr, cpal, name
│
├── raster                 ラスタライズパイプライン
│   ├── outline            アウトラインスケーリング、ベジェ曲線展開
│   ├── scanline           スキャンラインフィル（8xスーパーサンプリング）
│   ├── rasterizer         アウトライン→グレースケールビットマップ変換
│   ├── glyph_cache        ラスタライズ結果キャッシュ（個別グリフ単位）
│   └── atlas              グリフアトラステクスチャ（Skylineパッキング）
│
├── layout                 テキストレイアウト
│   └── shaper             グリフ配置（カーニング・ワードラップ・アラインメント）
│
├── render                 テキストレンダリング
│   ├── renderer           テキスト→RGBAビットマップ（renderText / RowRenderer）
│   ├── bitmap             グレースケールビットマップ
│   ├── rgba_bitmap        RGBAビットマップ（Color, blendPixel）
│   ├── gamma              ガンマ補正（sRGB線形空間ブレンド）
│   ├── incremental        インクリメンタルレンダリング
│   ├── easing             イージング関数
│   └── reveal             リビールストラテジー
│       ├── sweep          水平スウィープ
│       ├── fade           フェードイン
│       ├── contour_trace  輪郭トレース
│       ├── medial_axis    中心軸
│       ├── distance_field ディスタンスフィールド
│       ├── extrema_wave   エクストリーマウェーブ
│       ├── skeleton_grow  スケルトングロウ
│       └── tangent_flow   タンジェントフロー
│
├── compress               圧縮
│   └── brotli             Brotli展開（pure Zig実装）
│
└── err                    共通エラー・診断情報
```

---

## データフロー

```
テキスト (UTF-8)
    │
    ▼
┌─────────────┐
│ layout.shaper │  layoutText() / layoutStyledText()
│             │  カーニング、ワードラップ、アラインメント
└─────┬───────┘
      │  TextLayout { positions: []GlyphPosition }
      ▼
┌─────────────┐
│ font.Font   │  getGlyphOutline(glyph_id)
│             │  TrueType / CFF アウトライン取得
└─────┬───────┘
      │  GlyphOutline { contours, bounding box }
      ▼
┌──────────────┐
│ raster       │  rasterizeGlyph(outline, scale, padding)
│ .rasterizer  │  スケーリング → ベジェ展開 → スキャンラインフィル
└─────┬────────┘
      │  RasterResult { pixels (grayscale), width, height, offsets }
      ▼
┌──────────────┐
│ render       │  blendPixel() で各グリフをRGBAビットマップに合成
│ .renderer    │  ガンマ補正、LCDサブピクセル、フラクショナルポジショニング
└─────┬────────┘
      │
      ▼
  RgbaBitmap { pixels (RGBA), width, height }
```

---

## モジュールのインポート

```zig
const cappan = @import("cappan_core");

// フォント
const Font = cappan.font.Font;

// レイアウト
const shaper = cappan.layout.shaper;

// ラスタライズ
const rasterizer = cappan.raster.rasterizer;
const GlyphCache = cappan.raster.glyph_cache.GlyphCache;
const GlyphAtlas = cappan.raster.atlas.GlyphAtlas;

// レンダリング
const renderer = cappan.render.renderer;
const RgbaBitmap = cappan.render.rgba_bitmap.RgbaBitmap;
const Color = cappan.render.rgba_bitmap.Color;
const Bitmap = cappan.render.bitmap.Bitmap;
const gamma = cappan.render.gamma;

// アニメーション
const incremental = cappan.render.incremental;

// 圧縮
const brotli = cappan.compress.brotli;
```
