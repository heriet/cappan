const std = @import("std");
const font_mod = @import("font/font.zig");
const renderer_mod = @import("render/renderer.zig");
const ft = @import("features.zig").features;

test "render all ASCII printable characters without crash" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var fnt = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer fnt.deinit();

    var cp: u8 = 0x21;
    while (cp <= 0x7E) : (cp += 1) {
        const ch = [_]u8{cp};
        var bmp = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{fnt}, &ch, .{ .pixel_size = 48.0 });
        defer bmp.deinit();
        try std.testing.expect(bmp.width > 0);
        try std.testing.expect(bmp.height > 0);
    }
}

test "render Hello at various sizes" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var fnt = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer fnt.deinit();

    const sizes = [_]f32{ 12, 24, 48, 96, 200 };
    var prev_width: u32 = 0;
    var prev_height: u32 = 0;
    for (sizes) |size| {
        var bmp = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{fnt}, "Hello", .{ .pixel_size = size });
        defer bmp.deinit();
        try std.testing.expect(bmp.width >= prev_width);
        try std.testing.expect(bmp.height >= prev_height);
        prev_width = bmp.width;
        prev_height = bmp.height;
    }
}

test "render multiline text produces taller bitmap" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var fnt = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer fnt.deinit();

    var single_bmp = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{fnt}, "Line1", .{ .pixel_size = 48.0 });
    defer single_bmp.deinit();

    var multi_bmp = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{fnt}, "Line1\nLine2\nLine3", .{ .pixel_size = 48.0 });
    defer multi_bmp.deinit();

    try std.testing.expect(multi_bmp.width > 0);
    try std.testing.expect(multi_bmp.height > 0);
    try std.testing.expect(multi_bmp.height > single_bmp.height);
}

test "crc32 matches PNG spec" {
    var crc = std.hash.Crc32.init();
    crc.update("IEND");
    try std.testing.expectEqual(@as(u32, 0xAE426082), crc.final());
}

test "render UTF-8 text Héllo does not crash" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var fnt = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer fnt.deinit();

    var bmp = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{fnt}, "H\xC3\xA9llo", .{ .pixel_size = 48.0 });
    defer bmp.deinit();

    try std.testing.expect(bmp.width > 0);
    try std.testing.expect(bmp.height > 0);
}

test "CFF font renders 'A' without crash" {
    if (comptime !ft.enable_cff) return error.SkipZigTest;
    const font_data = @embedFile("fixture/SourceSans3-Regular.otf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var result = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{font}, "A", .{ .pixel_size = 48.0 });
    defer result.deinit();

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "CFF font renders Hello" {
    if (comptime !ft.enable_cff) return error.SkipZigTest;
    const font_data = @embedFile("fixture/SourceSans3-Regular.otf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var result = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hello", .{ .pixel_size = 48.0 });
    defer result.deinit();

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
