const std = @import("std");
const cappan_core = @import("cappan_core");

const Font = cappan_core.font.Font;

pub const UnicodeBlock = struct {
    name: []const u8,
    start: u21,
    end: u21,
    covered: u32,
    total: u32,
};

const BlockDef = struct {
    name: []const u8,
    start: u21,
    end: u21,
    /// Step size for sampling (1 = check every codepoint, N = check every Nth)
    step: u21,
};

const BLOCKS = [_]BlockDef{
    .{ .name = "Basic Latin", .start = 0x0020, .end = 0x007E, .step = 1 },
    .{ .name = "Latin-1 Supplement", .start = 0x00A0, .end = 0x00FF, .step = 1 },
    .{ .name = "Latin Extended-A", .start = 0x0100, .end = 0x017F, .step = 1 },
    .{ .name = "Latin Extended-B", .start = 0x0180, .end = 0x024F, .step = 1 },
    .{ .name = "Greek and Coptic", .start = 0x0370, .end = 0x03FF, .step = 1 },
    .{ .name = "Cyrillic", .start = 0x0400, .end = 0x04FF, .step = 1 },
    .{ .name = "Arabic", .start = 0x0600, .end = 0x06FF, .step = 1 },
    .{ .name = "Devanagari", .start = 0x0900, .end = 0x097F, .step = 1 },
    .{ .name = "General Punctuation", .start = 0x2000, .end = 0x206F, .step = 1 },
    .{ .name = "Mathematical Operators", .start = 0x2200, .end = 0x22FF, .step = 1 },
    .{ .name = "Hiragana", .start = 0x3040, .end = 0x309F, .step = 1 },
    .{ .name = "Katakana", .start = 0x30A0, .end = 0x30FF, .step = 1 },
    .{ .name = "CJK Unified Ideographs", .start = 0x4E00, .end = 0x9FFF, .step = 16 },
    .{ .name = "Hangul Syllables", .start = 0xAC00, .end = 0xD7AF, .step = 64 },
    .{ .name = "Emoji", .start = 0x1F600, .end = 0x1F64F, .step = 1 },
};

/// Analyze Unicode block coverage for the given font.
/// Returns a slice of UnicodeBlock values (caller owns the slice).
pub fn analyzeCoverage(allocator: std.mem.Allocator, font: Font) ![]UnicodeBlock {
    const blocks = try allocator.alloc(UnicodeBlock, BLOCKS.len);
    errdefer allocator.free(blocks);

    for (BLOCKS, 0..) |def, idx| {
        var covered: u32 = 0;
        var cp: u21 = def.start;
        while (cp <= def.end) : (cp += def.step) {
            const glyph_id = font.cmap.charToGlyphId(cp) catch 0;
            if (glyph_id != 0) {
                covered += def.step;
            }
        }
        const block_size = @as(u32, def.end - def.start + 1);
        // Cap covered at block_size (sampling can overshoot slightly)
        if (covered > block_size) covered = block_size;

        blocks[idx] = .{
            .name = def.name,
            .start = def.start,
            .end = def.end,
            .covered = covered,
            .total = block_size,
        };
    }

    return blocks;
}

test "analyzeCoverage Basic Latin coverage for DejaVuSans" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const blocks = try analyzeCoverage(std.testing.allocator, font);
    defer std.testing.allocator.free(blocks);

    try std.testing.expect(blocks.len > 0);

    // Find Basic Latin block
    var basic_latin: ?UnicodeBlock = null;
    for (blocks) |blk| {
        if (std.mem.eql(u8, blk.name, "Basic Latin")) {
            basic_latin = blk;
            break;
        }
    }

    try std.testing.expect(basic_latin != null);
    const bl = basic_latin.?;
    // DejaVuSans should cover nearly all Basic Latin
    try std.testing.expect(bl.covered >= bl.total * 95 / 100);
}
