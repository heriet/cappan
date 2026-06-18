# layout

UTF-8 テキストからグリフの配置（位置座標）を計算するモジュールです。

---

## shaper

テキストシェーピングとレイアウトを行います。カーニング、改行（`\n`）、ワードラップ、テキストアラインメントに対応しています。複数フォントを渡すとフォントフォールバック（先頭のフォントにグリフがなければ次のフォントを試す）が機能します。

### 単一スタイルのテキストレイアウト

```zig
pub fn layoutText(
    allocator: Allocator,
    fonts: []const Font,
    text: []const u8,
    options: LayoutOptions,
) !TextLayout
```

### 複数スタイルのテキストレイアウト

スパン単位でフォントサイズやフォントインデックスを変更できます。見出し+本文のような混合スタイルのテキストに使用します。

```zig
pub fn layoutStyledText(
    allocator: Allocator,
    fonts: []const Font,
    spans: []const StyledSpan,
    options: StyledLayoutOptions,
) !TextLayout
```

---

## 型定義

### LayoutOptions

```zig
pub const LayoutOptions = struct {
    pixel_size: f32 = 48.0,
    max_width: ?f32 = null,       // 設定するとワードラップ有効
    text_align: TextAlign = .left,
};
```

### StyledSpan / StyledLayoutOptions

```zig
pub const StyledSpan = struct {
    text: []const u8,
    pixel_size: f32,
    font_index: u8 = 0,    // fonts 配列のインデックス
};

pub const StyledLayoutOptions = struct {
    max_width: ?f32 = null,
    text_align: TextAlign = .left,
};
```

### TextAlign

```zig
pub const TextAlign = enum { left, center, right };
```

### TextLayout

`layoutText` / `layoutStyledText` の戻り値。全グリフの配置情報とテキスト全体のメトリクスを含みます。

```zig
pub const TextLayout = struct {
    positions: []GlyphPosition,   // 各グリフの配置
    total_width: f32,             // テキスト全体の幅（ピクセル）
    total_height: f32,            // テキスト全体の高さ（ピクセル）
    ascender_px: f32,             // アセンダー（ピクセル）
    descender_px: f32,            // ディセンダー（ピクセル）
    line_height: f32,             // 行の高さ（ピクセル）
    num_lines: u32,               // 行数
    allocator: Allocator,
    pub fn deinit(self: *TextLayout) void;
};
```

### GlyphPosition

各グリフのレイアウト結果。ピクセル空間での位置を示します。

```zig
pub const GlyphPosition = struct {
    glyph_id: u16,
    font_index: u8,       // フォールバック先を識別
    codepoint: u21,        // 元の Unicode コードポイント
    x_offset: f32,         // ベースラインからの X オフセット（ピクセル）
    y_offset: f32,         // ベースラインからの Y オフセット（ピクセル）
    pixel_size: f32 = 48.0,
};
```
