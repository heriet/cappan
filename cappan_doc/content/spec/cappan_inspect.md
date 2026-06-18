# cappan_inspect

`cappan_inspect` モジュールがフォントのメタデータ解析、整合性検証、Unicodeカバレッジ分析、OpenType featureリストアップを担当します。

---

## 概要

フォントファイルの内容を検査するためのユーティリティ群です。テーブル一覧の取得から、テーブル間の整合性チェック、収録文字の分析、OpenTypeの機能一覧取得まで対応します。

---

## table_dump: テーブルダンプ

### TableInfo

フォントの個々のテーブルに関する情報です。

```zig
pub const TableInfo = struct {
    tag: [4]u8,
    offset: u32,
    length: u32,
    checksum: u32,
};
```

### FontSummary

フォント全体のサマリー情報です。

```zig
pub const FontSummary = struct {
    num_glyphs: u16,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    family_name: ?[]const u8,
    subfamily_name: ?[]const u8,
    tables: []TableInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FontSummary) void
};
```

| フィールド | 説明 |
|-----------|------|
| `num_glyphs` | グリフ総数（maxpテーブルから） |
| `units_per_em` | EMサイズ（headテーブルから） |
| `ascender` / `descender` / `line_gap` | 垂直メトリクス（hheaテーブルから） |
| `x_min` / `y_min` / `x_max` / `y_max` | フォントバウンディングボックス（headテーブルから） |
| `family_name` | フォントファミリー名（nameテーブルから。`null` の可能性あり） |
| `subfamily_name` | サブファミリー名（nameテーブルから。`null` の可能性あり） |
| `tables` | テーブル一覧 |

### getSummary

```zig
pub fn getSummary(allocator: std.mem.Allocator, font: Font) !FontSummary
```

フォントのサマリー情報を取得します。戻り値は `deinit()` で解放してください。

---

## validator: 整合性検証

### Severity

```zig
pub const Severity = enum { info, warning, @"error" };
```

### ValidationMessage

個々の検証メッセージです。

```zig
pub const ValidationMessage = struct {
    severity: Severity,
    code: []const u8,
    message: []const u8,
};
```

### ValidationResult

```zig
pub const ValidationResult = struct {
    messages: []ValidationMessage,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ValidationResult) void
    pub fn hasErrors(self: ValidationResult) bool
};
```

### validate

```zig
pub fn validate(allocator: std.mem.Allocator, font: Font) !ValidationResult
```

フォントテーブルの整合性を検証します。以下の5項目をチェックします。

| コード | 深刻度 | チェック内容 |
|--------|--------|------------|
| `UNITS_PER_EM_OUT_OF_RANGE` | warning | `head.units_per_em` が推奨範囲 `[16, 16384]` 外 |
| `INVALID_LOCA_FORMAT` | error | `head.index_to_loc_format` が 0 または 1 以外 |
| `LOCA_EXCEEDS_GLYF` | error | `loca` の最終オフセットが `glyf` テーブルサイズを超過 |
| `HMTX_SIZE_MISMATCH` | error | `hmtx` テーブルが `hhea.number_of_h_metrics` に必要なサイズより小さい |
| `CMAP_GLYPH_OUT_OF_RANGE` | error | `cmap('A')` が返すグリフIDが `maxp.num_glyphs` 以上 |

---

## coverage: Unicodeカバレッジ分析

### UnicodeBlock

Unicodeブロックごとのカバレッジ情報です。

```zig
pub const UnicodeBlock = struct {
    name: []const u8,
    start: u21,
    end: u21,
    covered: u32,
    total: u32,
};
```

### analyzeCoverage

```zig
pub fn analyzeCoverage(allocator: std.mem.Allocator, font: Font) ![]UnicodeBlock
```

フォントのUnicodeブロックカバレッジを分析します。戻り値は呼び出し元が `allocator.free()` で解放してください。

**分析対象の15ブロック:**

| ブロック名 | 範囲 | サンプリング |
|-----------|------|------------|
| Basic Latin | U+0020〜U+007E | 全数チェック |
| Latin-1 Supplement | U+00A0〜U+00FF | 全数チェック |
| Latin Extended-A | U+0100〜U+017F | 全数チェック |
| Latin Extended-B | U+0180〜U+024F | 全数チェック |
| Greek and Coptic | U+0370〜U+03FF | 全数チェック |
| Cyrillic | U+0400〜U+04FF | 全数チェック |
| Arabic | U+0600〜U+06FF | 全数チェック |
| Devanagari | U+0900〜U+097F | 全数チェック |
| General Punctuation | U+2000〜U+206F | 全数チェック |
| Mathematical Operators | U+2200〜U+22FF | 全数チェック |
| Hiragana | U+3040〜U+309F | 全数チェック |
| Katakana | U+30A0〜U+30FF | 全数チェック |
| CJK Unified Ideographs | U+4E00〜U+9FFF | 16コードポイントごとにサンプリング |
| Hangul Syllables | U+AC00〜U+D7AF | 64コードポイントごとにサンプリング |
| Emoji | U+1F600〜U+1F64F | 全数チェック |

CJK統合漢字・ハングルのように範囲が大きいブロックはサンプリングで計算コストを抑えます。

---

## feature: OpenType featureリストアップ

### FeatureInfo

OpenType featureの1エントリです。

```zig
pub const FeatureInfo = struct {
    table_tag: [4]u8,     // "GSUB" または "GPOS"
    feature_tag: [4]u8,   // 例: "kern", "liga", "calt"
    script_tag: [4]u8,    // 例: "latn", "kana"
    language_tag: [4]u8,  // 例: "dflt", "JAN "
};
```

### listFeatures

```zig
pub fn listFeatures(allocator: std.mem.Allocator, font: Font) ![]FeatureInfo
```

GSUBおよびGPOSテーブルからすべてのOpenType featureを列挙します。

処理フロー:
```
GSUB/GPOSテーブル
  └─ ScriptList → Script → LangSys → FeatureIndices
       └─ FeatureList[index] → featureTag
```

同一featureが複数のスクリプト・言語で定義されている場合は、それぞれ別エントリとして返します。戻り値は呼び出し元が `allocator.free()` で解放してください。

---

## glyph_info: グリフ詳細情報

### GlyphInfo

グリフ1つ分の詳細情報です。

```zig
pub const GlyphInfo = struct {
    glyph_id: u16,
    codepoint: ?u32,      // グリフIDで直接検索した場合は null
    advance_width: u16,
    lsb: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    contour_count: u16,
    point_count: u16,
    is_compound: bool,
    has_outline: bool,
};
```

| フィールド | 説明 |
|-----------|------|
| `glyph_id` | グリフID |
| `codepoint` | コードポイント（グリフIDで直接指定した場合は `null`） |
| `advance_width` | アドバンス幅（フォントユニット） |
| `lsb` | 左サイドベアリング（Left Side Bearing） |
| `x_min` / `y_min` / `x_max` / `y_max` | グリフバウンディングボックス（フォントユニット） |
| `contour_count` | 輪郭数（複合グリフの場合は展開後の合計） |
| `point_count` | ポイント数（全輪郭の合計） |
| `is_compound` | 複合グリフ（composite glyph）かどうか |
| `has_outline` | アウトラインデータがあるかどうか（スペース文字等は `false`） |

### getGlyphInfo

```zig
pub fn getGlyphInfo(allocator: std.mem.Allocator, font: cappan_core.font.Font, glyph_id: u16, codepoint: ?u32) !GlyphInfo
```

指定グリフの詳細情報を取得します。

- `glyph_id`: 取得対象のグリフID
- `codepoint`: 元のコードポイント（グリフIDで直接検索した場合は `null` を渡す）

TrueType（glyf/loca）フォントではバウンディングボックスをテーブルの生データから直接読み取ります。CFF フォントではアウトライン解析から取得します。

---

## 使用例

```zig
const cappan_core = @import("cappan_core");
const cappan_inspect = @import("cappan_inspect");

const font_data = try std.fs.cwd().readFileAlloc(allocator, "font.ttf", 10_000_000);
defer allocator.free(font_data);

var font = try cappan_core.font.Font.init(allocator, font_data);
defer font.deinit();

// テーブルサマリー
var summary = try cappan_inspect.table_dump.getSummary(allocator, font);
defer summary.deinit();
std.debug.print("グリフ数: {d}\n", .{summary.num_glyphs});
std.debug.print("フォントファミリー: {?s}\n", .{summary.family_name});

// 整合性検証
var result = try cappan_inspect.validator.validate(allocator, font);
defer result.deinit();
if (result.hasErrors()) {
    for (result.messages) |msg| {
        if (msg.severity == .@"error") {
            std.debug.print("[ERROR] {s}: {s}\n", .{ msg.code, msg.message });
        }
    }
}

// Unicodeカバレッジ分析
const blocks = try cappan_inspect.coverage.analyzeCoverage(allocator, font);
defer allocator.free(blocks);
for (blocks) |blk| {
    std.debug.print("{s}: {d}/{d}\n", .{ blk.name, blk.covered, blk.total });
}

// OpenType feature一覧
const features = try cappan_inspect.feature.listFeatures(allocator, font);
defer allocator.free(features);
for (features) |feat| {
    std.debug.print("{s}/{s}/{s}/{s}\n", .{
        feat.table_tag, feat.feature_tag, feat.script_tag, feat.language_tag,
    });
}

// グリフ詳細情報
const glyph_id = try font.getGlyphId(0x0041); // 'A'
const info = try cappan_inspect.getGlyphInfo(allocator, font, glyph_id, 0x0041);
std.debug.print("グリフ {d}: advance={d} contours={d}\n", .{
    info.glyph_id, info.advance_width, info.contour_count,
});
```
