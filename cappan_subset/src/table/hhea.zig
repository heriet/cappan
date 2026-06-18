const std = @import("std");
const cappan_core = @import("cappan_core");
const writer = @import("../writer.zig");

pub fn buildHhea(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    new_num_h_metrics: u16,
) ![]u8 {
    const record = cappan_core.font.parser.findTable(font.offset_table, "hhea".*) orelse return error.NoHheaTable;
    const hhea_data = try cappan_core.font.parser.getTableData(font.data, record);
    if (hhea_data.len < 36) return error.UnexpectedEof;

    const buf = try allocator.dupe(u8, hhea_data[0..36]);
    errdefer allocator.free(buf);

    writer.writeU16BE(buf, 34, new_num_h_metrics);

    return buf;
}
