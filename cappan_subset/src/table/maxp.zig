const std = @import("std");
const cappan_core = @import("cappan_core");
const writer = @import("../writer.zig");

pub fn buildMaxp(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    new_num_glyphs: u16,
) ![]u8 {
    const record = cappan_core.font.parser.findTable(font.offset_table, "maxp".*) orelse return error.NoMaxpTable;
    const maxp_data = try cappan_core.font.parser.getTableData(font.data, record);

    const buf = try allocator.dupe(u8, maxp_data);
    errdefer allocator.free(buf);

    writer.writeU16BE(buf, 4, new_num_glyphs);

    return buf;
}
