const std = @import("std");

pub const Bitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Bitmap {
        const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
        @memset(pixels, 255); // white background
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bitmap) void {
        self.allocator.free(self.pixels);
    }

    pub fn setPixel(self: *Bitmap, x: u32, y: u32, value: u8) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = value;
    }

    pub fn getPixel(self: Bitmap, x: u32, y: u32) u8 {
        if (x >= self.width or y >= self.height) return 0;
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    /// Blend a glyph coverage value onto the bitmap (black text on white background)
    pub fn blendPixel(self: *Bitmap, x: u32, y: u32, coverage: u8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        const existing = self.pixels[idx];
        // Black text: blend = existing * (1 - coverage/255)
        const result = @as(u16, existing) * (@as(u16, 255) - @as(u16, coverage)) / 255;
        self.pixels[idx] = @intCast(result);
    }
};

test "bitmap init and pixel operations" {
    var bmp = try Bitmap.init(std.testing.allocator, 4, 4);
    defer bmp.deinit();

    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(0, 0));
    bmp.setPixel(1, 1, 128);
    try std.testing.expectEqual(@as(u8, 128), bmp.getPixel(1, 1));

    // Out of bounds should not crash
    bmp.setPixel(100, 100, 0);
    try std.testing.expectEqual(@as(u8, 0), bmp.getPixel(100, 100));
}
