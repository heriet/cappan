const std = @import("std");
const parser = @import("../parser.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const CpalTable = struct {
    data: []const u8,
    num_palette_entries: u16,
    num_palettes: u16,
    color_records_offset: u32,
    palette_offsets_start: u32,

    pub fn getColor(self: CpalTable, palette_idx: u16, entry_idx: u16) ?Color {
        if (palette_idx >= self.num_palettes or entry_idx >= self.num_palette_entries) return null;
        const idx_offset = std.math.add(u32, self.palette_offsets_start, @as(u32, palette_idx) * 2) catch return null;
        const idx_offset_usize: usize = @intCast(idx_offset);
        const first_color_idx = parser.readU16(self.data, idx_offset_usize) catch return null;
        const color_idx = std.math.add(u32, @as(u32, first_color_idx), @as(u32, entry_idx)) catch return null;
        const color_offset = std.math.add(u32, self.color_records_offset, std.math.mul(u32, color_idx, 4) catch return null) catch return null;
        const color_offset_usize: usize = @intCast(color_offset);
        const b = parser.readU8(self.data, color_offset_usize) catch return null;
        const g = parser.readU8(self.data, color_offset_usize + 1) catch return null;
        const r = parser.readU8(self.data, color_offset_usize + 2) catch return null;
        const a = parser.readU8(self.data, color_offset_usize + 3) catch return null;
        return Color{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub fn parse(data: []const u8) !CpalTable {
    if (data.len < 12) return error.UnexpectedEof;
    const num_palette_entries = try parser.readU16(data, 2);
    const num_palettes = try parser.readU16(data, 4);
    const color_records_offset = try parser.readU32(data, 8);
    return CpalTable{
        .data = data,
        .num_palette_entries = num_palette_entries,
        .num_palettes = num_palettes,
        .color_records_offset = color_records_offset,
        .palette_offsets_start = 12,
    };
}

test "cpal parse does not crash on missing table" {
    const result = parse(&[_]u8{0} ** 5);
    try std.testing.expectError(error.UnexpectedEof, result);
}
