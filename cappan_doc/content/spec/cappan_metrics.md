# cappan_metrics

`cappan_metrics` モジュールがCSS `@font-face` 用のメトリクス計算とフォント間のメトリクス比較を担当します。

---

## 概要

Webフォントのフォールバック設定や代替フォントのサイジング調整に必要なメトリクスを計算します。CSS `@font-face` の `ascent-override`・`descent-override`・`line-gap-override`・`size-adjust` プロパティに対応する値を提供します。

---

## css.zig: CSS @font-face メトリクス

### MetricsSource

メトリクス値の取得元を示す列挙型です。

```zig
pub const MetricsSource = enum {
    os2_typo,  // OS/2 sTypoAscender/Descender/LineGap
    os2_win,   // OS/2 usWinAscent/usWinDescent
    hhea,      // hhea ascender/descender/line_gap
};
```

### CssFontMetrics

CSS `@font-face` に設定するメトリクス値です。

```zig
pub const CssFontMetrics = struct {
    ascent_override: f32,   // ascent-override（%）
    descent_override: f32,  // descent-override（%、正値）
    line_gap_override: f32, // line-gap-override（%）
    source: MetricsSource,
};
```

値は `unitsPerEm` に対する百分率（%）です。例: `ascent_override = 105.0` は `ascent-override: 105%` を意味します。

### getCssFontMetrics

```zig
pub fn getCssFontMetrics(font: cappan_core.font.Font) CssFontMetrics
```

フォントから CSS `@font-face` 用のメトリクスを計算します（アロケーターは不要）。

**フォールバック優先順位:**

```
1. OS/2 sTypoAscender が 0 でない
   → sTypoAscender / unitsPerEm × 100  （source = .os2_typo）
   → |sTypoDescender| / unitsPerEm × 100
   → sTypoLineGap / unitsPerEm × 100

2. OS/2 sTypoAscender が 0（または OS/2 テーブルなし）
   → usWinAscent / unitsPerEm × 100    （source = .os2_win）
   → usWinDescent / unitsPerEm × 100
   → line_gap_override = 0.0

3. OS/2 テーブルが存在しない
   → hhea ascender / unitsPerEm × 100  （source = .hhea）
   → |hhea descender| / unitsPerEm × 100
   → hhea line_gap / unitsPerEm × 100
```

`descent_override` は常に正値（絶対値）で返します。

---

## compare.zig: フォント間メトリクス比較

### FontComparison

2フォント間のメトリクス比較結果です。

```zig
pub const FontComparison = struct {
    x_height_ratio: f32,    // font_b.x_height / font_a.x_height
    avg_width_ratio: f32,   // font_b.avg_width / font_a.avg_width
    size_adjust: f32,       // CSS size-adjust（%）= font_a.avg_width / font_b.avg_width × 100

    font_a_x_height: f32,
    font_b_x_height: f32,
    font_a_avg_width: f32,
    font_b_avg_width: f32,
};
```

`size_adjust` はCSSの `size-adjust` プロパティ値（%）です。フォールバックフォント（`font_b`）に適用することで、基準フォント（`font_a`）の文字幅に近づけます。

### compareFonts

```zig
pub fn compareFonts(
    font_a: cappan_core.font.Font,
    font_b: cappan_core.font.Font,
) FontComparison
```

`font_a` を基準フォント（目的のフォント）、`font_b` をフォールバックフォント（実際に表示されるフォント）として比較します（アロケーターは不要）。

---

### x-height 計算

x高さを `unitsPerEm` で正規化した値（0.0〜1.0程度）を返します。

**フォールバック優先順位:**

```
1. OS/2 version >= 2 かつ sXHeight != 0
   → sXHeight / unitsPerEm

2. 'x'（U+0078）グリフのバウンディングボックス y_max
   → outline.y_max / unitsPerEm

3. hhea ascender を使った推定値
   → ascender × 0.5 / unitsPerEm
```

---

### 平均文字幅計算

平均文字幅を `unitsPerEm` で正規化した値を返します。

**フォールバック優先順位:**

```
1. OS/2 xAvgCharWidth != 0
   → xAvgCharWidth / unitsPerEm

2. 'a'〜'z' の advance_width の平均
   → (a〜z の平均 advance_width) / unitsPerEm

3. hhea ascender を使った推定値（究極のフォールバック）
   → ascender × 0.5 / unitsPerEm
```

---

## 使用例

```zig
const cappan_core = @import("cappan_core");
const cappan_metrics = @import("cappan_metrics");

// フォント読み込み
const font_data_a = try std.fs.cwd().readFileAlloc(allocator, "primary.ttf", 10_000_000);
defer allocator.free(font_data_a);
var font_a = try cappan_core.font.Font.init(allocator, font_data_a);
defer font_a.deinit();

// CSS @font-face メトリクス計算
const css_metrics = cappan_metrics.css.getCssFontMetrics(font_a);
std.debug.print(
    "@font-face {{\n  ascent-override: {d:.2}%;\n  descent-override: {d:.2}%;\n  line-gap-override: {d:.2}%;\n}}\n",
    .{ css_metrics.ascent_override, css_metrics.descent_override, css_metrics.line_gap_override },
);

// フォールバックフォントとのメトリクス比較
const font_data_b = try std.fs.cwd().readFileAlloc(allocator, "fallback.ttf", 10_000_000);
defer allocator.free(font_data_b);
var font_b = try cappan_core.font.Font.init(allocator, font_data_b);
defer font_b.deinit();

const cmp = cappan_metrics.compare.compareFonts(font_a, font_b);
std.debug.print(
    "size-adjust: {d:.2}%\nx-height比率: {d:.4}\n平均文字幅比率: {d:.4}\n",
    .{ cmp.size_adjust, cmp.x_height_ratio, cmp.avg_width_ratio },
);
// CSS 出力例: @font-face { font-family: "Fallback"; size-adjust: 98.50%; }
```
