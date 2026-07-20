const std = @import("std");
const font_mod = @import("../font/font.zig");
const rasterizer_mod = @import("rasterizer.zig");

/// Packs (font_index, glyph_id) into a single u32 lookup key. Shared by
/// render/renderer.zig's per-render glyph cache and raster/sdf.zig's SDF glyph
/// cache, so the bit layout has a single owner.
pub fn glyphCacheKeyU32(font_index: u8, glyph_id: u16) u32 {
    return (@as(u32, font_index) << 16) | @as(u32, glyph_id);
}

pub const GlyphCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, CachedGlyph),

    pub const CachedGlyph = struct {
        pixels: []const u8,
        width: u32,
        height: u32,
        offset_x: f32,
        offset_y: f32,
    };

    pub fn init(allocator: std.mem.Allocator) GlyphCache {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (entry.pixels.len > 0) {
                self.allocator.free(entry.pixels);
            }
        }
        self.entries.deinit(self.allocator);
    }

    /// キャッシュにあればそれを返し、なければラスタライズしてキャッシュに入れて返す。
    /// グリフが存在しない場合は null を返す。
    /// 返される CachedGlyph の pixels はキャッシュが所有しており、
    /// GlyphCache が deinit または clear されるまで有効。
    pub fn getOrRasterize(
        self: *GlyphCache,
        font: font_mod.Font,
        font_index: u8,
        glyph_id: u16,
        pixel_size: f32,
    ) !?CachedGlyph {
        const key = cacheKey(font_index, glyph_id, pixel_size);

        if (self.entries.get(key)) |cached| {
            return cached;
        }

        // ラスタライズ
        var outline = (try font.getGlyphOutline(self.allocator, glyph_id)) orelse return null;
        defer outline.deinit();

        const scale = pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
        const raster = try rasterizer_mod.rasterizeGlyph(self.allocator, outline, scale, 1, .{});
        // raster.pixels の所有権をキャッシュに移す（deinit しない）

        const cached = CachedGlyph{
            .pixels = raster.pixels,
            .width = raster.width,
            .height = raster.height,
            .offset_x = raster.offset_x,
            .offset_y = raster.offset_y,
        };

        try self.entries.put(self.allocator, key, cached);
        return cached;
    }

    pub fn clear(self: *GlyphCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (entry.pixels.len > 0) {
                self.allocator.free(entry.pixels);
            }
        }
        self.entries.clearRetainingCapacity();
    }

    fn cacheKey(font_index: u8, glyph_id: u16, pixel_size: f32) u64 {
        const size_q: u16 = @intFromFloat(@round(pixel_size * 4.0));
        return @as(u64, font_index) << 32 | @as(u64, glyph_id) << 16 | @as(u64, size_q);
    }
};

test "GlyphCache caches rasterized glyphs" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var cache = GlyphCache.init(std.testing.allocator);
    defer cache.deinit();

    const glyph_id = try font.getGlyphId('A');

    // 初回はキャッシュミス → ラスタライズ
    const result1 = (try cache.getOrRasterize(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(result1.width > 0);
    try std.testing.expect(result1.height > 0);

    // 2回目はキャッシュヒット → 同じポインタ
    const result2 = (try cache.getOrRasterize(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(result1.pixels.ptr, result2.pixels.ptr);
}

test "GlyphCache different sizes are cached separately" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var cache = GlyphCache.init(std.testing.allocator);
    defer cache.deinit();

    const glyph_id = try font.getGlyphId('A');

    const result_48 = (try cache.getOrRasterize(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;
    const result_24 = (try cache.getOrRasterize(font, 0, glyph_id, 24.0)) orelse return error.TestUnexpectedResult;

    // 異なるサイズなので別エントリ
    try std.testing.expect(result_48.pixels.ptr != result_24.pixels.ptr);
    try std.testing.expect(result_48.width > result_24.width);
}

test "GlyphCache clear frees all entries" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var cache = GlyphCache.init(std.testing.allocator);
    defer cache.deinit();

    const glyph_id = try font.getGlyphId('A');
    _ = try cache.getOrRasterize(font, 0, glyph_id, 48.0);

    cache.clear();

    // clear 後はキャッシュミスになる
    const result = (try cache.getOrRasterize(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(result.width > 0);
}
