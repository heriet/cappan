# cappan_embed

`cappan_embed` モジュールがPDFへのフォント埋め込みに必要なメタデータ抽出とデータ変換を担当します。

---

## 概要

PDFにフォントを埋め込む際には、FontDescriptor辞書用のメタデータ（フォント名・フラグ・バウンディングボックスなど）、グリフ幅配列（`/W`）、CIDToGIDマップが必要です。本モジュールはこれらをフォントから抽出・変換して提供します。

---

## PdfFontInfo

PDF FontDescriptor に必要なフォントメタデータをまとめた構造体です。

```zig
pub const PdfFontInfo = struct {
    postscript_name: []const u8,
    flags: u32,
    bbox: [4]i16,
    italic_angle: i16,
    ascent: i16,
    descent: i16,
    cap_height: i16,
    stem_v: i16,
    units_per_em: u16,
    is_italic: bool,
    is_bold: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PdfFontInfo) void
};
```

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `postscript_name` | `[]const u8` | PostScript名（nameテーブルから取得。`deinit` で解放） |
| `flags` | `u32` | PDF FontDescriptor `/Flags` ビットフィールド |
| `bbox` | `[4]i16` | フォントバウンディングボックス `[xMin, yMin, xMax, yMax]`（フォントユニット） |
| `italic_angle` | `i16` | イタリック角度（postテーブルから取得） |
| `ascent` | `i16` | アセンダー（OS/2 sTypoAscender 優先、なければ hhea） |
| `descent` | `i16` | ディセンダー（OS/2 sTypoDescender 優先、なければ hhea） |
| `cap_height` | `i16` | キャップハイト（OS/2 sCapHeight。0の場合は `ascent * 0.7` で推定） |
| `stem_v` | `i16` | ステム幅（OS/2 weightClass から推定） |
| `units_per_em` | `u16` | EMサイズ |
| `is_italic` | `bool` | イタリックフラグ |
| `is_bold` | `bool` | ボールドフラグ |

### /Flags ビットフィールド

| ビット | 意味 | 設定条件 |
|-------|------|---------|
| bit 0（1） | FixedPitch | postテーブルの `isFixedPitch != 0` |
| bit 6（32） | Nonsymbolic | 常に設定 |
| bit 7（64） | Italic | OS/2 `fsSelection` bit0 が立つ、または `italic_angle != 0` |

---

## getPdfFontInfo

フォントから `PdfFontInfo` を生成します。

```zig
pub fn getPdfFontInfo(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
) !PdfFontInfo
```

- `name` テーブルが存在しない場合は `error.NoNameTable` を返します。
- PostScript名が取得できない場合は `"Unknown"` を使用します。
- 戻り値の `postscript_name` は呼び出し元が `deinit()` で解放してください。

---

## GlyphWidth

PDF `/W` 配列用のグリフ幅情報です。

```zig
pub const GlyphWidth = struct {
    codepoint: u21,
    glyph_id: u16,
    width: u16,
};
```

`width` は 1/1000 EMユニット換算（PDFの `/W` 配列で使用する単位）です。

---

## getGlyphWidths

指定コードポイントのグリフ幅を取得します。

```zig
pub fn getGlyphWidths(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
) ![]GlyphWidth
```

`advance_width * 1000 / unitsPerEm` で1/1000EMに変換します。グリフIDが取得できないコードポイントはスキップされます。戻り値は呼び出し元が `allocator.free()` で解放してください。

---

## buildCidToGidMap

PDF CIDToGIDMap ストリーム用のバイト列を生成します。

```zig
pub fn buildCidToGidMap(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
    glyph_mapping: ?[]const u16,
) ![]u8
```

| 引数 | 説明 |
|------|------|
| `codepoints` | 対象コードポイント列（BMP範囲 U+0000〜U+FFFF のみ有効） |
| `glyph_mapping` | サブセット後のグリフIDマッピング（`null` の場合は元IDをそのまま使用） |

出力は `(max_codepoint + 1) * 2` バイトのビッグエンディアン `u16` 配列です。インデックス `cp * 2` にグリフIDが格納されます。

---

## getFontStreamData

PDFフォントストリーム用のフォントデータを返します。

```zig
pub fn getFontStreamData(font: cappan_core.font.Font) []const u8
```

`font.data` をそのまま返します。PDF の `/FontFile2`（TrueType）ストリームとして使用します。

---

## Os2Table

OS/2テーブルのパース結果です。

```zig
pub const Os2Table = struct {
    version: u16,
    avg_char_width: i16,
    weight_class: u16,
    width_class: u16,
    fs_type: u16,
    s_typo_ascender: i16,
    s_typo_descender: i16,
    s_typo_line_gap: i16,
    us_win_ascent: u16,
    us_win_descent: u16,
    s_x_height: i16,       // version >= 2 のみ
    s_cap_height: i16,     // version >= 2 のみ
    fs_selection: u16,

    pub fn isItalic(self: Os2Table) bool
    pub fn isBold(self: Os2Table) bool
};

pub fn parse(data: []const u8) !Os2Table
```

| メソッド | 説明 |
|---------|------|
| `isItalic()` | `fsSelection` bit 0 が立っている場合 `true` |
| `isBold()` | `fsSelection` bit 5 が立っている場合 `true` |

`parse` はデータが78バイト未満の場合 `error.UnexpectedEof` を返します。`s_x_height`・`s_cap_height` は version 2 以上かつデータが90バイト以上の場合のみ有効です。

---

### StemV 推定式

OS/2 `usWeightClass` から StemV を推定します。

```
stemV = 50 + (weightClass / 65)²
```

例：`weightClass = 400`（Regular）の場合、`stemV = 50 + (6)² = 86`

---

## 使用例

```zig
const cappan_core = @import("cappan_core");
const cappan_embed = @import("cappan_embed");

const font_data = try std.fs.cwd().readFileAlloc(allocator, "font.ttf", 10_000_000);
defer allocator.free(font_data);

var font = try cappan_core.font.Font.init(allocator, font_data);
defer font.deinit();

// FontDescriptor 用メタデータ取得
var info = try cappan_embed.pdf.getPdfFontInfo(allocator, font);
defer info.deinit();

std.debug.print("PostScript名: {s}\n", .{info.postscript_name});
std.debug.print("/Flags: {d}\n", .{info.flags});
std.debug.print("StemV: {d}\n", .{info.stem_v});

// グリフ幅配列取得（/W 配列用）
const codepoints = [_]u21{ 'A', 'B', 'C' };
const widths = try cappan_embed.pdf.getGlyphWidths(allocator, font, &codepoints);
defer allocator.free(widths);

// CIDToGIDMap 生成
const cid_to_gid = try cappan_embed.pdf.buildCidToGidMap(allocator, font, &codepoints, null);
defer allocator.free(cid_to_gid);

// フォントストリームデータ
const stream_data = cappan_embed.pdf.getFontStreamData(font);
_ = stream_data; // PDF /FontFile2 ストリームに書き込む
```
