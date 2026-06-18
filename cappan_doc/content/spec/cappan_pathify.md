# cappan_pathify

`cappan_pathify` モジュールがフォントグリフのアウトラインをSVGの `path` 要素の `d` 属性文字列に変換します。

---

## 概要

グリフアウトライン（TrueType 2次ベジェ、CFF 3次ベジェ）をSVGパスコマンド文字列に変換します。単一グリフのフォントユニット出力と、テキスト文字列のピクセルスケール出力の2モードを提供します。

---

## GlyphPath

テキスト変換時の1グリフ分のパス情報です。

```zig
pub const GlyphPath = struct {
    codepoint: u21,
    glyph_id: u16,
    path_data: []const u8,
    advance_width: f32,
    x_offset: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlyphPath) void
};
```

| フィールド | 説明 |
|-----------|------|
| `codepoint` | 対応するコードポイント |
| `glyph_id` | グリフID |
| `path_data` | SVG `d` 属性文字列（`deinit` で解放） |
| `advance_width` | グリフの送り幅（ピクセル単位） |
| `x_offset` | テキスト先頭からのX方向オフセット（ピクセル単位、カーニング適用済み） |

---

## glyphToSvgPath

単一グリフをSVGパス文字列に変換します。座標系はフォントユニット（Y軸上向き）の整数座標です。

```zig
pub fn glyphToSvgPath(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    glyph_id: u16,
) !?[]const u8
```

- アウトラインが存在しないグリフ（スペースなど）は `null` を返します。
- 戻り値は呼び出し元が `allocator.free()` で解放してください。
- 座標値は整数（フォントユニット）として出力します。

---

## textToSvgPaths

テキスト文字列を `GlyphPath` の配列に変換します。ピクセルスケールでY軸反転済みの浮動小数点座標を出力します。

```zig
pub fn textToSvgPaths(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    text: []const u8,
    pixel_size: f32,
) ![]GlyphPath
```

| 引数 | 説明 |
|------|------|
| `text` | UTF-8文字列 |
| `pixel_size` | フォントサイズ（ピクセル）。`scale = pixel_size / unitsPerEm` でスケーリング |

- グリフIDが取得できないコードポイントはスキップされます。
- GPOS / kern テーブルを使ったカーニングが適用されます（`Font.getKerning` に準じます）。
- 戻り値の各 `GlyphPath` は `deinit()` で解放し、スライス自体は `allocator.free()` で解放してください。

---

## SVGパスコマンド

| コマンド | 条件 | 説明 |
|---------|------|------|
| `M x y` | 輪郭開始 | 最初のオンカーブ点に移動 |
| `L x y` | オンカーブ点 | 直線セグメント |
| `Q cx cy x y` | オフカーブ点1個（TrueType 2次ベジェ） | 2次ベジェ曲線 |
| `C cx1 cy1 cx2 cy2 x y` | オフカーブ点2個（CFF 3次ベジェ） | 3次ベジェ曲線 |
| `Z` | 輪郭終端 | パスを閉じる |

輪郭が全オフカーブ点のみの場合、最初の2点の中点を暗黙のオンカーブ開始点として使用します。連続するオフカーブ点が2つある場合も、その中点を暗黙のオンカーブ点として処理します。

---

## 座標系

| モード | 関数 | 座標系 | 数値形式 |
|--------|------|--------|---------|
| フォントユニット | `glyphToSvgPath` | Y軸上向き（フォントユニット） | 整数 |
| ピクセルスケール | `textToSvgPaths` | Y軸下向き（ピクセル、Y反転済み） | 小数点2桁 |

SVG の座標系はY軸下向きのため、`textToSvgPaths` では `y = -font_y * scale` として変換します。

---

## 使用例

```zig
const cappan_core = @import("cappan_core");
const cappan_pathify = @import("cappan_pathify");

const font_data = try std.fs.cwd().readFileAlloc(allocator, "font.ttf", 10_000_000);
defer allocator.free(font_data);

var font = try cappan_core.font.Font.init(allocator, font_data);
defer font.deinit();

// 単一グリフをフォントユニットで変換
const glyph_id = try font.getGlyphId('A');
const path = try cappan_pathify.svg.glyphToSvgPath(allocator, font, glyph_id);
defer if (path) |p| allocator.free(p);

if (path) |d| {
    std.debug.print("<path d=\"{s}\" />\n", .{d});
}

// テキストをピクセルスケールで変換（48px）
const paths = try cappan_pathify.svg.textToSvgPaths(allocator, font, "Hello", 48.0);
defer {
    for (paths) |*p| @constCast(p).deinit();
    allocator.free(paths);
}

for (paths) |gp| {
    std.debug.print(
        "<path transform=\"translate({d:.2},0)\" d=\"{s}\" />\n",
        .{ gp.x_offset, gp.path_data },
    );
}
```
