const std = @import("std");
const cappan_core = @import("cappan_core");

const Font = cappan_core.font.Font;

pub const TableInfo = struct {
    tag: [4]u8,
    offset: u32,
    length: u32,
    checksum: u32,
};

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

    pub fn deinit(self: *FontSummary) void {
        if (self.family_name) |name| self.allocator.free(name);
        if (self.subfamily_name) |name| self.allocator.free(name);
        self.allocator.free(self.tables);
    }
};

/// Get a summary of font metadata including table list, metrics, and name info.
pub fn getSummary(allocator: std.mem.Allocator, font: Font) !FontSummary {
    const records = font.offset_table.table_records;
    const tables = try allocator.alloc(TableInfo, records.len);
    errdefer allocator.free(tables);

    for (records, 0..) |rec, i| {
        tables[i] = .{
            .tag = rec.tag,
            .offset = rec.offset,
            .length = rec.length,
            .checksum = rec.checksum,
        };
    }

    var family_name: ?[]const u8 = null;
    var subfamily_name: ?[]const u8 = null;

    if (font.name) |name_table| {
        if (try name_table.getName(allocator, .font_family)) |name| {
            family_name = name;
        }
        if (try name_table.getName(allocator, .font_subfamily)) |name| {
            subfamily_name = name;
        }
    }

    return .{
        .num_glyphs = font.maxp.num_glyphs,
        .units_per_em = font.head.units_per_em,
        .ascender = font.hhea.ascender,
        .descender = font.hhea.descender,
        .line_gap = font.hhea.line_gap,
        .x_min = font.head.x_min,
        .y_min = font.head.y_min,
        .x_max = font.head.x_max,
        .y_max = font.head.y_max,
        .family_name = family_name,
        .subfamily_name = subfamily_name,
        .tables = tables,
        .allocator = allocator,
    };
}

test "getSummary returns valid data for DejaVuSans" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var summary = try getSummary(std.testing.allocator, font);
    defer summary.deinit();

    try std.testing.expect(summary.num_glyphs > 0);
    try std.testing.expectEqual(@as(u16, 2048), summary.units_per_em);
    try std.testing.expect(summary.ascender > 0);
    try std.testing.expect(summary.descender < 0);
    try std.testing.expect(summary.tables.len > 0);

    // Check that family name is populated
    try std.testing.expect(summary.family_name != null);

    // Verify table list contains known tables
    var found_head = false;
    var found_cmap = false;
    for (summary.tables) |tbl| {
        if (std.mem.eql(u8, &tbl.tag, "head")) found_head = true;
        if (std.mem.eql(u8, &tbl.tag, "cmap")) found_cmap = true;
    }
    try std.testing.expect(found_head);
    try std.testing.expect(found_cmap);
}
