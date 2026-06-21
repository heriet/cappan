# render

レイアウト済みのテキストを RGBA ビットマップにレンダリングするモジュール群です。ガンマ補正、LCD サブピクセルレンダリング、インクリメンタルレンダリング（テキストアニメーション）に対応しています。

---

## renderer — テキスト→RGBA ビットマップ

テキスト全体を RGBA ビットマップにレンダリングする高レベル API です。内部でレイアウト→ラスタライズ→合成を一括実行します。

### 一括レンダリング

```zig
pub fn renderText(
    allocator: Allocator,
    fonts: []const Font,
    text: []const u8,
    options: RenderOptions,
) !RgbaBitmap
```

### ストリーミングレンダリング（行単位）

全体のビットマップを保持せず、1行（1ピクセル行）ずつ RGBA データを生成します。メモリ使用量を抑えたい場合や、PNG エンコーダにストリーミングで渡す場合に有用です。

```zig
pub const RowRenderer = struct {
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, fonts: []const Font, text: []const u8, options: RenderOptions) !RowRenderer;
    pub fn deinit(self: *RowRenderer) void;

    // 指定行の RGBA データを返す（width * 4 bytes）
    // 内部バッファを返すため、次の renderRow 呼び出しで上書きされる
    pub fn renderRow(self: *RowRenderer, y: u32) []const u8;
};
```

### RenderOptions

```zig
pub const RenderOptions = struct {
    pixel_size: f32 = 48.0,
    padding: u32 = 4,
    fg_color: Color = Color.black,
    bg_color: Color = Color.white,
    gamma_correction: bool = false,          // sRGB 線形空間でのブレンド
    fractional_positioning: bool = false,     // サブピクセルポジショニング
    max_width: ?f32 = null,                  // ワードラップ幅
    text_align: TextAlign = .left,
    lcd_rendering: bool = false,             // LCD サブピクセルレンダリング
    paint_stack: ?[]const PaintOperation = null,  // マルチレイヤー描画（null 時は fg_color で単色フィル）
};
```

### カバレッジマップの合成

外部の RGBA バッファにグレースケールのカバレッジマップを合成するユーティリティ関数です。独自のレンダリングパイプラインを構築する場合に使用します。

```zig
pub fn blitCoverage(
    dst_pixels: []u8,
    dst_width: u32, dst_height: u32,
    coverage: []const u8,
    cov_width: u32, cov_height: u32,
    dst_x: i32, dst_y: i32,
    color: Color,
    opacity: f32,
) void
```

---

## rgba_bitmap — RGBA ビットマップ

RGBA ピクセルバッファとピクセル単位のブレンド操作を提供します。

```zig
pub const Color = struct {
    r: u8, g: u8, b: u8, a: u8,
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

pub const RgbaBitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,   // RGBA, width * height * 4 bytes
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32, bg_color: Color) !RgbaBitmap;
    pub fn deinit(self: *RgbaBitmap) void;

    // sRGB 空間でのアルファブレンド
    pub fn blendPixel(self: *RgbaBitmap, x: u32, y: u32, coverage: u8, fg: Color) void;

    // リニア空間でのアルファブレンド（ガンマ補正済み）
    pub fn blendPixelLinear(self: *RgbaBitmap, x: u32, y: u32, coverage: u8, fg: Color) void;

    // LCD サブピクセルブレンド（R/G/B 個別カバレッジ）
    pub fn blendPixelLcd(self: *RgbaBitmap, x: u32, y: u32, r_cov: u8, g_cov: u8, b_cov: u8, fg: Color) void;
};
```

## bitmap — グレースケールビットマップ

シングルチャンネルのグレースケールビットマップです。アトラスの `exportPage()` やラスタライズ結果の可視化に使用します。

```zig
pub const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,   // グレースケール, width * height bytes
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32) !Bitmap;  // 白背景 (255)
    pub fn deinit(self: *Bitmap) void;
    pub fn setPixel(self: *Bitmap, x: u32, y: u32, value: u8) void;
    pub fn getPixel(self: Bitmap, x: u32, y: u32) u8;
    pub fn blendPixel(self: *Bitmap, x: u32, y: u32, coverage: u8) void;
};
```

---

## gamma — ガンマ補正

sRGB とリニア空間の変換関数です。`RenderOptions.gamma_correction = true` で自動的に適用されますが、独自パイプラインから直接利用することもできます。

ガンマ補正を有効にすると、テキストの細い部分（ステムやセリフ）が視覚的に正確な太さでレンダリングされます。

```zig
pub fn srgbToLinear(v: u8) f32;               // sRGB u8 → リニア [0.0, 1.0]
pub fn linearToSrgb(linear: f32) u8;           // リニア [0.0, 1.0] → sRGB u8
pub fn blendLinear(bg_srgb: u8, fg_srgb: u8, alpha: f32) u8;  // リニア空間でブレンドし sRGB で返す
```

---

## paint — マルチレイヤー描画（PaintStack）

テキストに複数のフィル・ストロークを重ねがけする PaintStack の型定義です。`RenderOptions.paint_stack` に設定して使用します。

### PaintOperation

```zig
pub const PaintOperation = union(enum) {
    fill: FillPaint,
    stroke: StrokePaint,
};
```

`paint_stack` の配列は**下から上**の順序で描画されます（index 0 が最背面）。

### FillPaint

```zig
pub const FillPaint = struct {
    color: Color,
    opacity: f32 = 1.0,
};
```

### StrokePaint

```zig
pub const StrokePaint = struct {
    color: Color,
    width: StrokeWidth = .{ .px = 1.0 },
    opacity: f32 = 1.0,
    join: LineJoin = .round,
    position: StrokePosition = .outside,
    miter_limit: f32 = 4.0,
};
```

### StrokeWidth

```zig
pub const StrokeWidth = union(enum) {
    px: f32,   // ピクセル単位（絶対値）
    em: f32,   // pixel_size に比例してスケール
};
```

### 使用例

```zig
const paint_ops = [_]PaintOperation{
    .{ .stroke = .{ .color = red, .width = .{ .px = 6.0 }, .position = .outside } },
    .{ .stroke = .{ .color = white, .width = .{ .px = 3.0 }, .position = .outside } },
    .{ .fill = .{ .color = black } },
};

var bitmap = try renderer.renderText(allocator, &fonts, "Hello", .{
    .pixel_size = 48.0,
    .paint_stack = &paint_ops,
});
```

### 半透明描画

`opacity < 1.0` の場合、一時バッファに全グリフを不透明で描画した後、指定の不透明度でメインビットマップに合成します。グリフ間の重なりで二重ブレンドが発生しません。

### LCD レンダリングとの関係

PaintStack と LCD サブピクセルレンダリング (`lcd_rendering = true`) は併用できません。両方が指定された場合、LCD レンダリングは自動的に無効化されます。

---

## incremental — インクリメンタルレンダリング

テキストを段階的に表示するアニメーション用レンダラーです。フレームごとに `progress` (0.0～1.0) を指定して RGBA ビットマップを取得します。

表示の制御は **Reveal** と **Timing** の2つの軸で行います。

- **Reveal** — 個々のグリフが「どのように出現するか」を定義するエフェクト。グリフのカバレッジマップに対して progress に応じたマスク処理を適用します。
- **Timing** — 複数グリフ間の「いつ出現するか」の順序を制御します。

### Reveal ストラテジー

| ストラテジー | 効果 |
|-------------|------|
| `sweep` | 指定方向にスウィープラインを移動し、通過した部分から表示 |
| `fade` | グリフ全体を均一にフェードイン |
| `contour_trace` | グリフの輪郭に沿って線を引くように表示 |
| `medial_axis` | グリフの骨格（中心軸）から外側に向かって拡散表示 |
| `distance_field` | グリフ内部から輪郭へ向かって広がるように表示 |
| `extrema_wave` | アウトラインの極値点から波が広がるように表示 |
| `skeleton_grow` | 骨格線から外側へ肉付けするように表示 |
| `tangent_flow` | アウトラインの接線方向でグループ化して表示 |
| `custom` | ユーザー定義のコールバック関数で任意のエフェクトを実装 |

```zig
pub const RevealStrategy = union(enum) {
    sweep: SweepOptions,
    fade,
    contour_trace: ContourTraceOptions,
    medial_axis: MedialAxisOptions,
    distance_field: DistanceFieldOptions,
    extrema_wave: ExtremaWaveOptions,
    skeleton_grow: SkeletonGrowOptions,
    tangent_flow: TangentFlowOptions,
    custom: CustomReveal,
};
```

### Timing

```zig
pub const Timing = union(enum) {
    simultaneous,       // 全グリフを同時にアニメーション
    sequential,         // 1文字ずつ順番にアニメーション
    weighted,           // グリフの複雑さに応じて時間配分を重み付けして逐次表示
    overlap: f32,       // 前の文字と重なりながら順次表示（0.0～1.0）
};
```

### Options

```zig
pub const Options = struct {
    pixel_size: f32 = 48.0,
    padding: u32 = 4,
    fg_color: Color = Color.black,
    bg_color: Color = Color.white,
    gamma_correction: bool = false,
    fractional_positioning: bool = false,
    strategy: RevealStrategy = .{ .sweep = .{} },
    timing: Timing = .sequential,
    max_width: ?f32 = null,
    text_align: TextAlign = .left,
};
```

### IncrementalRenderer

```zig
pub const IncrementalRenderer = struct {
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, fonts: []const Font, text: []const u8, options: Options) !IncrementalRenderer;
    pub fn deinit(self: *IncrementalRenderer) void;

    // progress (0.0 = 非表示, 1.0 = 完全表示) でフレームを生成
    pub fn renderFrame(self: *IncrementalRenderer, progress: f32) !RgbaBitmap;

    // フレーム番号指定（APNG 等のフレームベースアニメーション向け）
    pub fn renderFrameByIndex(self: *IncrementalRenderer, frame: u32, total_frames: u32) !RgbaBitmap;
};
```
