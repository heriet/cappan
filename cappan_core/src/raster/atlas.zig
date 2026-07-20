const std = @import("std");
const font_mod = @import("../font/font.zig");
const rasterizer_mod = @import("rasterizer.zig");
const bitmap_mod = @import("../render/bitmap.zig");

pub const AtlasRegion = struct {
    page: u16,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
};

pub const AtlasOptions = struct {
    page_width: u32 = 1024,
    page_height: u32 = 1024,
    padding: u32 = 1,
};

const SkylineNode = struct {
    x: u32,
    width: u32,
    y: u32,
};

const AtlasPage = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,
    skyline: std.ArrayListUnmanaged(SkylineNode),

    fn init(allocator: std.mem.Allocator, w: u32, h: u32) !AtlasPage {
        const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h));
        @memset(pixels, 0);
        var sky: std.ArrayListUnmanaged(SkylineNode) = .empty;
        try sky.append(allocator, .{ .x = 0, .width = w, .y = 0 });
        return .{ .allocator = allocator, .pixels = pixels, .width = w, .height = h, .skyline = sky };
    }

    fn deinit(self: *AtlasPage) void {
        self.allocator.free(self.pixels);
        self.skyline.deinit(self.allocator);
    }

    fn pack(self: *AtlasPage, rect_width: u32, rect_height: u32, padding: u32) error{OutOfMemory}!?struct { x: u32, y: u32 } {
        const pw = rect_width + padding * 2;
        const ph = rect_height + padding * 2;
        if (pw > self.width or ph > self.height) return null;

        var best_x: ?u32 = null;
        var best_y: ?u32 = null;

        for (self.skyline.items, 0..) |node, i| {
            const cx = node.x;
            if (cx + pw > self.width) continue;

            var max_y: u32 = 0;
            var span_x: u32 = cx;
            var j: usize = i;
            while (j < self.skyline.items.len and span_x < cx + pw) {
                const sn = self.skyline.items[j];
                if (sn.y > max_y) max_y = sn.y;
                span_x = sn.x + sn.width;
                j += 1;
            }
            if (span_x < cx + pw) continue;
            if (max_y + ph > self.height) continue;

            if (best_y == null or max_y < best_y.? or (max_y == best_y.? and cx < best_x.?)) {
                best_x = cx;
                best_y = max_y;
            }
        }

        const bx = best_x orelse return null;
        const by = best_y.?;
        const range_end = bx + pw;

        var new_skyline: std.ArrayListUnmanaged(SkylineNode) = .empty;
        defer new_skyline.deinit(self.allocator);

        for (self.skyline.items) |node| {
            const node_end = node.x + node.width;
            if (node_end <= bx) {
                try new_skyline.append(self.allocator, node);
            } else if (node.x < bx) {
                try new_skyline.append(self.allocator, .{ .x = node.x, .width = bx - node.x, .y = node.y });
            } else {
                break;
            }
        }

        try new_skyline.append(self.allocator, .{ .x = bx, .width = pw, .y = by + ph });

        for (self.skyline.items) |node| {
            const node_end = node.x + node.width;
            if (node_end <= range_end) continue;
            if (node.x < range_end) {
                try new_skyline.append(self.allocator, .{ .x = range_end, .width = node_end - range_end, .y = node.y });
            } else {
                try new_skyline.append(self.allocator, node);
            }
        }

        var merged: std.ArrayListUnmanaged(SkylineNode) = .empty;
        var merged_owned = false;
        defer {
            if (!merged_owned) merged.deinit(self.allocator);
        }
        for (new_skyline.items) |node| {
            if (node.width == 0) continue;
            if (merged.items.len > 0) {
                const last = &merged.items[merged.items.len - 1];
                if (last.y == node.y and last.x + last.width == node.x) {
                    last.width += node.width;
                    continue;
                }
            }
            try merged.append(self.allocator, node);
        }

        self.skyline.deinit(self.allocator);
        self.skyline = merged;
        merged_owned = true;

        return .{ .x = bx + padding, .y = by + padding };
    }
};

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(AtlasPage),
    regions: std.AutoHashMapUnmanaged(u64, AtlasRegion),
    page_width: u32,
    page_height: u32,
    padding: u32,

    pub fn init(allocator: std.mem.Allocator, options: AtlasOptions) GlyphAtlas {
        return .{
            .allocator = allocator,
            .pages = .empty,
            .regions = .empty,
            .page_width = options.page_width,
            .page_height = options.page_height,
            .padding = options.padding,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        for (self.pages.items) |*page| {
            page.deinit();
        }
        self.pages.deinit(self.allocator);
        self.regions.deinit(self.allocator);
    }

    pub fn getOrInsert(
        self: *GlyphAtlas,
        font: font_mod.Font,
        font_index: u8,
        glyph_id: u16,
        pixel_size: f32,
    ) !?AtlasRegion {
        if (self.lookup(font_index, glyph_id, pixel_size)) |region| {
            return region;
        }

        var outline = (try font.getGlyphOutline(self.allocator, glyph_id)) orelse return null;
        defer outline.deinit();

        const scale = pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
        var raster = try rasterizer_mod.rasterizeGlyph(self.allocator, outline, scale, 1, .{});
        defer raster.deinit();

        if (raster.width == 0 or raster.height == 0) {
            const region = AtlasRegion{
                .page = 0,
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
                .offset_x = raster.offset_x,
                .offset_y = raster.offset_y,
            };
            try self.regions.put(self.allocator, cacheKey(font_index, glyph_id, pixel_size), region);
            return region;
        }

        return try self.insert(
            font_index,
            glyph_id,
            pixel_size,
            raster.pixels,
            raster.width,
            raster.height,
            raster.offset_x,
            raster.offset_y,
        );
    }

    pub fn insert(
        self: *GlyphAtlas,
        font_index: u8,
        glyph_id: u16,
        pixel_size: f32,
        pixels: []const u8,
        width: u32,
        height: u32,
        offset_x: f32,
        offset_y: f32,
    ) !AtlasRegion {
        const key = cacheKey(font_index, glyph_id, pixel_size);
        if (self.regions.get(key)) |region| return region;

        for (self.pages.items, 0..) |*page, page_index| {
            if (try page.pack(width, height, self.padding)) |pos| {
                const region = AtlasRegion{
                    .page = @intCast(page_index),
                    .x = pos.x,
                    .y = pos.y,
                    .width = width,
                    .height = height,
                    .offset_x = offset_x,
                    .offset_y = offset_y,
                };
                copyPixels(page, pos.x, pos.y, pixels, width, height);
                try self.regions.put(self.allocator, key, region);
                return region;
            }
        }

        if (self.pages.items.len >= std.math.maxInt(u16)) return error.TooManyAtlasPages;

        var page = try AtlasPage.init(self.allocator, self.page_width, self.page_height);
        var page_owned_by_atlas = false;
        defer {
            if (!page_owned_by_atlas) page.deinit();
        }

        const pos = (try page.pack(width, height, self.padding)) orelse return error.GlyphTooLarge;
        const page_index = self.pages.items.len;
        try self.pages.append(self.allocator, page);
        page_owned_by_atlas = true;

        const region = AtlasRegion{
            .page = @intCast(page_index),
            .x = pos.x,
            .y = pos.y,
            .width = width,
            .height = height,
            .offset_x = offset_x,
            .offset_y = offset_y,
        };
        copyPixels(&self.pages.items[page_index], pos.x, pos.y, pixels, width, height);
        try self.regions.put(self.allocator, key, region);
        return region;
    }

    pub fn lookup(self: GlyphAtlas, font_index: u8, glyph_id: u16, pixel_size: f32) ?AtlasRegion {
        return self.regions.get(cacheKey(font_index, glyph_id, pixel_size));
    }

    pub fn getPagePixels(self: GlyphAtlas, page_index: u16) ?[]const u8 {
        if (@as(usize, page_index) >= self.pages.items.len) return null;
        return self.pages.items[@as(usize, page_index)].pixels;
    }

    pub fn pageCount(self: GlyphAtlas) u16 {
        return @intCast(self.pages.items.len);
    }

    fn exportPageImpl(self: GlyphAtlas, allocator: std.mem.Allocator, page_index: u16, comptime invert: bool) !?bitmap_mod.Bitmap {
        if (@as(usize, page_index) >= self.pages.items.len) return null;
        const page = self.pages.items[@as(usize, page_index)];
        var bitmap = try bitmap_mod.Bitmap.init(allocator, page.width, page.height);
        if (comptime invert) {
            for (page.pixels, 0..) |pixel, i| {
                bitmap.pixels[i] = 255 - pixel;
            }
        } else {
            @memcpy(bitmap.pixels, page.pixels);
        }
        return bitmap;
    }

    /// Black-on-white export: inverts pixel values (255-pixel), intended for coverage
    /// atlases meant to look like ink on paper.
    pub fn exportPage(self: GlyphAtlas, allocator: std.mem.Allocator, page_index: u16) !?bitmap_mod.Bitmap {
        return self.exportPageImpl(allocator, page_index, true);
    }

    /// Raw export: copies page pixels verbatim, no inversion. Use this for SDF (or any
    /// other non-coverage) atlases, where 255-pixel would corrupt the encoded values.
    pub fn exportPageRaw(self: GlyphAtlas, allocator: std.mem.Allocator, page_index: u16) !?bitmap_mod.Bitmap {
        return self.exportPageImpl(allocator, page_index, false);
    }

    pub fn clear(self: *GlyphAtlas) void {
        for (self.pages.items) |*page| {
            page.deinit();
        }
        self.pages.clearRetainingCapacity();
        self.regions.clearRetainingCapacity();
    }
};

fn cacheKey(font_index: u8, glyph_id: u16, pixel_size: f32) u64 {
    const size_q: u16 = @intFromFloat(@round(pixel_size * 4.0));
    return @as(u64, font_index) << 32 | @as(u64, glyph_id) << 16 | @as(u64, size_q);
}

fn copyPixels(page: *AtlasPage, dst_x: u32, dst_y: u32, pixels: []const u8, width: u32, height: u32) void {
    for (0..height) |row| {
        const src_start = row * @as(usize, width);
        const dst_start = (@as(usize, dst_y) + row) * @as(usize, page.width) + @as(usize, dst_x);
        @memcpy(page.pixels[dst_start .. dst_start + @as(usize, width)], pixels[src_start .. src_start + @as(usize, width)]);
    }
}

fn regionsOverlap(a: AtlasRegion, b: AtlasRegion) bool {
    if (a.page != b.page) return false;
    return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height;
}

test "atlas page packs single rectangle" {
    var page = try AtlasPage.init(std.testing.allocator, 64, 64);
    defer page.deinit();

    const pos = (try page.pack(10, 10, 1)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), pos.x);
    try std.testing.expectEqual(@as(u32, 1), pos.y);
}

test "atlas page packs multiple rectangles without overlap" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .page_width = 64, .page_height = 64, .padding = 1 });
    defer atlas.deinit();

    const pixels = [_]u8{255} ** 100;
    const a = try atlas.insert(0, 1, 16.0, &pixels, 10, 10, 0, 0);
    const b = try atlas.insert(0, 2, 16.0, &pixels, 10, 10, 0, 0);
    const c = try atlas.insert(0, 3, 16.0, &pixels, 10, 10, 0, 0);

    try std.testing.expect(!regionsOverlap(a, b));
    try std.testing.expect(!regionsOverlap(a, c));
    try std.testing.expect(!regionsOverlap(b, c));
}

test "atlas page returns null when full" {
    var page = try AtlasPage.init(std.testing.allocator, 8, 8);
    defer page.deinit();

    try std.testing.expect(try page.pack(8, 8, 1) == null);
}

test "GlyphAtlas insert pre-rasterized glyph" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .page_width = 32, .page_height = 32, .padding = 1 });
    defer atlas.deinit();

    const pixels = [_]u8{200} ** 16;
    const region = try atlas.insert(0, 42, 12.0, &pixels, 4, 4, 1.5, 2.5);
    try std.testing.expectEqual(@as(u16, 1), atlas.pageCount());
    try std.testing.expectEqual(@as(u32, 4), region.width);
    try std.testing.expectEqual(@as(u32, 4), region.height);
    try std.testing.expectEqual(@as(f32, 1.5), region.offset_x);
    const pixel_index = @as(usize, region.y) * @as(usize, atlas.pages.items[0].width) + @as(usize, region.x);
    try std.testing.expectEqual(@as(u8, 200), atlas.pages.items[0].pixels[pixel_index]);
}

test "GlyphAtlas lookup returns null for missing" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    try std.testing.expect(atlas.lookup(0, 1, 12.0) == null);
}

test "GlyphAtlas clear resets state" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .page_width = 32, .page_height = 32, .padding = 1 });
    defer atlas.deinit();

    const pixels = [_]u8{128} ** 16;
    _ = try atlas.insert(0, 1, 12.0, &pixels, 4, 4, 0, 0);
    atlas.clear();

    try std.testing.expectEqual(@as(u16, 0), atlas.pageCount());
    try std.testing.expect(atlas.lookup(0, 1, 12.0) == null);
}

test "GlyphAtlas getOrInsert with real font" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    const glyph_id = try font.getGlyphId('A');
    const region = (try atlas.getOrInsert(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;

    try std.testing.expect(region.width > 0);
    try std.testing.expect(region.height > 0);
    try std.testing.expectEqual(@as(u16, 1), atlas.pageCount());
}

test "GlyphAtlas cache hit returns same region" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    const glyph_id = try font.getGlyphId('A');
    const a = (try atlas.getOrInsert(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;
    const b = (try atlas.getOrInsert(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(a.page, b.page);
    try std.testing.expectEqual(a.x, b.x);
    try std.testing.expectEqual(a.y, b.y);
}

test "GlyphAtlas different sizes separate" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var atlas = GlyphAtlas.init(std.testing.allocator, .{});
    defer atlas.deinit();

    const glyph_id = try font.getGlyphId('A');
    const large = (try atlas.getOrInsert(font, 0, glyph_id, 48.0)) orelse return error.TestUnexpectedResult;
    const small = (try atlas.getOrInsert(font, 0, glyph_id, 24.0)) orelse return error.TestUnexpectedResult;

    try std.testing.expect(large.width > small.width);
    try std.testing.expect(large.x != small.x or large.y != small.y or large.page != small.page);
}

test "GlyphAtlas multiple pages" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .page_width = 64, .page_height = 64, .padding = 1 });
    defer atlas.deinit();

    const pixels = [_]u8{255} ** 400;
    for (0..20) |i| {
        _ = try atlas.insert(0, @intCast(i + 1), 16.0, &pixels, 20, 20, 0, 0);
    }

    try std.testing.expect(atlas.pageCount() > 1);
}

test "GlyphAtlas exportPage" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .page_width = 16, .page_height = 16, .padding = 1 });
    defer atlas.deinit();

    const pixels = [_]u8{255} ** 4;
    const region = try atlas.insert(0, 1, 8.0, &pixels, 2, 2, 0, 0);
    var bitmap = (try atlas.exportPage(std.testing.allocator, 0)) orelse return error.TestUnexpectedResult;
    defer bitmap.deinit();

    try std.testing.expectEqual(@as(u32, 16), bitmap.width);
    try std.testing.expectEqual(@as(u32, 16), bitmap.height);
    try std.testing.expectEqual(@as(u8, 0), bitmap.getPixel(region.x, region.y));
}

test "GlyphAtlas exportPageRaw returns pixels without inversion" {
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .page_width = 16, .page_height = 16, .padding = 1 });
    defer atlas.deinit();

    const pixels = [_]u8{200} ** 4;
    const region = try atlas.insert(0, 1, 8.0, &pixels, 2, 2, 0, 0);
    var bitmap = (try atlas.exportPageRaw(std.testing.allocator, 0)) orelse return error.TestUnexpectedResult;
    defer bitmap.deinit();

    try std.testing.expectEqual(@as(u32, 16), bitmap.width);
    try std.testing.expectEqual(@as(u32, 16), bitmap.height);
    // Unlike exportPage, the inserted value comes through unmodified (no 255-pixel inversion).
    try std.testing.expectEqual(@as(u8, 200), bitmap.getPixel(region.x, region.y));
    // Untouched background stays at the page's raw fill value (0), not inverted to 255.
    try std.testing.expectEqual(@as(u8, 0), bitmap.getPixel(0, 0));
}

test "GlyphAtlas overflow packs across exactly two pages" {
    // page_width == page_height == the glyph's own padded size, so each insert fills an
    // entire page and the second one must spill onto a new page.
    var atlas = GlyphAtlas.init(std.testing.allocator, .{ .page_width = 10, .page_height = 10, .padding = 0 });
    defer atlas.deinit();

    const pixels = [_]u8{100} ** 100;
    const region_a = try atlas.insert(0, 1, 10.0, &pixels, 10, 10, 0, 0);
    const region_b = try atlas.insert(0, 2, 10.0, &pixels, 10, 10, 0, 0);

    try std.testing.expectEqual(@as(u16, 2), atlas.pageCount());
    try std.testing.expectEqual(@as(u16, 0), region_a.page);
    try std.testing.expectEqual(@as(u16, 1), region_b.page);

    var page1_bitmap = (try atlas.exportPageRaw(std.testing.allocator, 1)) orelse return error.TestUnexpectedResult;
    defer page1_bitmap.deinit();
    try std.testing.expectEqual(@as(u32, 10), page1_bitmap.width);
    try std.testing.expectEqual(@as(u8, 100), page1_bitmap.getPixel(region_b.x, region_b.y));
}

test "skyline merges adjacent nodes" {
    var page = try AtlasPage.init(std.testing.allocator, 8, 8);
    defer page.deinit();

    _ = (try page.pack(2, 2, 0)) orelse return error.TestUnexpectedResult;
    _ = (try page.pack(2, 2, 0)) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 2), page.skyline.items.len);
    try std.testing.expectEqual(@as(u32, 4), page.skyline.items[0].width);
    try std.testing.expectEqual(@as(u32, 2), page.skyline.items[0].y);
}
