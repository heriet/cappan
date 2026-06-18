# raster

グリフアウトラインをグレースケールのカバレッジビットマップに変換し、キャッシュやアトラステクスチャで管理するモジュール群です。

---

## rasterizer — グリフラスタライズ

グリフアウトラインをスケーリングし、ベジェ曲線を線分に展開した後、スキャンラインフィル（8x スーパーサンプリング）でグレースケールのカバレッジマップを生成します。

### 標準ラスタライズ

```zig
pub fn rasterizeGlyph(
    allocator: Allocator,
    outline: GlyphOutline,
    scale: f32,       // pixel_size / units_per_em
    padding: u32,     // ビットマップ周囲のパディング（ピクセル）
) !RasterResult
```

### LCD サブピクセルレンダリング

3倍幅で内部ラスタライズし、R/G/B 個別のカバレッジマップを生成します。液晶ディスプレイ向けのサブピクセルアンチエイリアシングに使用します。

```zig
pub fn rasterizeGlyphLcd(
    allocator: Allocator,
    outline: GlyphOutline,
    scale: f32,
    padding: u32,
) !LcdRasterResult
```

### RasterResult

```zig
pub const RasterResult = struct {
    pixels: []u8,       // グレースケール (0=透明, 255=完全カバー)
    width: u32,         // ビットマップ幅
    height: u32,        // ビットマップ高さ
    offset_x: f32,      // ビットマップ左上からフォント原点への X オフセット
    offset_y: f32,      // ビットマップ左上からフォント原点への Y オフセット
    allocator: Allocator,
    pub fn deinit(self: *RasterResult) void;
};
```

`offset_x`, `offset_y` はグリフのベースライン原点がビットマップ内のどこにあるかを示します。レンダラーはこの値を使ってグリフを正確にベースライン上に配置します。

### LcdRasterResult

```zig
pub const LcdRasterResult = struct {
    r_coverage: []u8,   // R チャンネルカバレッジ
    g_coverage: []u8,   // G チャンネルカバレッジ
    b_coverage: []u8,   // B チャンネルカバレッジ
    width: u32, height: u32,
    offset_x: f32, offset_y: f32,
    allocator: Allocator,
    pub fn deinit(self: *LcdRasterResult) void;
};
```

---

## glyph_cache — グリフキャッシュ

ラスタライズ結果を `(font_index, glyph_id, pixel_size)` をキーにキャッシュします。同じグリフ・同じサイズの再ラスタライズを回避し、レンダリング性能を向上させます。

```zig
pub const GlyphCache = struct {
    pub const CachedGlyph = struct {
        pixels: []const u8,    // キャッシュが所有（deinit/clear まで有効）
        width: u32,
        height: u32,
        offset_x: f32,
        offset_y: f32,
    };

    pub fn init(allocator: Allocator) GlyphCache;
    pub fn deinit(self: *GlyphCache) void;

    // キャッシュにあれば返し、なければラスタライズしてキャッシュに格納して返す
    // アウトラインが存在しないグリフ（スペース等）は null
    pub fn getOrRasterize(
        self: *GlyphCache,
        font: Font,
        font_index: u8,
        glyph_id: u16,
        pixel_size: f32,
    ) !?CachedGlyph;

    // キャッシュ内のすべてのエントリを解放（キャパシティは保持）
    pub fn clear(self: *GlyphCache) void;
};
```

`CachedGlyph.pixels` はキャッシュが所有しています。`GlyphCache` を `deinit` または `clear` するまで有効です。

---

## atlas — グリフアトラステクスチャ

複数のグリフビットマップを Skyline アルゴリズムで大きなページテクスチャにパッキングします。GPU テクスチャアップロードやバッチレンダリングに適しています。

ページは固定サイズのグレースケールバッファで、グリフが収まらなくなると新しいページが自動的に追加されます。

### 初期化

```zig
pub const AtlasOptions = struct {
    page_width: u32 = 1024,    // ページ幅（ピクセル）
    page_height: u32 = 1024,   // ページ高さ（ピクセル）
    padding: u32 = 1,          // グリフ間のパディング（ピクセル）
};

var atlas = GlyphAtlas.init(allocator, .{});
defer atlas.deinit();
```

### グリフの取得・挿入

```zig
pub const GlyphAtlas = struct {
    pub fn init(allocator: Allocator, options: AtlasOptions) GlyphAtlas;
    pub fn deinit(self: *GlyphAtlas) void;

    // グリフを取得（未登録なら自動ラスタライズ＆パック）
    pub fn getOrInsert(self: *GlyphAtlas, font: Font, font_index: u8, glyph_id: u16, pixel_size: f32) !?AtlasRegion;

    // 事前ラスタライズ済みデータを挿入
    pub fn insert(self: *GlyphAtlas, font_index: u8, glyph_id: u16, pixel_size: f32, pixels: []const u8, width: u32, height: u32, offset_x: f32, offset_y: f32) !AtlasRegion;

    // キャッシュ参照のみ（ラスタライズしない）
    pub fn lookup(self: GlyphAtlas, font_index: u8, glyph_id: u16, pixel_size: f32) ?AtlasRegion;

    // ページデータアクセス
    pub fn getPagePixels(self: GlyphAtlas, page_index: u16) ?[]const u8;
    pub fn pageCount(self: GlyphAtlas) u16;
    pub fn exportPage(self: GlyphAtlas, allocator: Allocator, page_index: u16) !?Bitmap;

    pub fn clear(self: *GlyphAtlas) void;
};
```

### AtlasRegion

アトラスページ内でのグリフの位置を表します。

```zig
pub const AtlasRegion = struct {
    page: u16,               // ページインデックス
    x: u32, y: u32,          // ページ内の左上座標
    width: u32, height: u32, // グリフビットマップサイズ
    offset_x: f32,           // フォント原点オフセット（RasterResult と同じ）
    offset_y: f32,
};
```

### GlyphCache と GlyphAtlas の使い分け

| | GlyphCache | GlyphAtlas |
|---|---|---|
| ストレージ | グリフごとに個別バッファ | 大きなページテクスチャに統合 |
| 用途 | CPU レンダリング | GPU テクスチャアップロード、バッチ描画 |
| メモリレイアウト | 分散 | ページ内で連続 |
| ページデータ取得 | - | `getPagePixels()` で一括取得可能 |
