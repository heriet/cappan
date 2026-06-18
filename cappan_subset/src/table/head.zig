const std = @import("std");
const cappan_core = @import("cappan_core");
const writer = @import("../writer.zig");

pub fn buildHead(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    index_to_loc_format: i16,
) ![]u8 {
    const head_record = cappan_core.font.parser.findTable(font.offset_table, "head".*) orelse return error.NoHeadTable;
    const head_data = try cappan_core.font.parser.getTableData(font.data, head_record);
    if (head_data.len < 54) return error.UnexpectedEof;

    const buf = try allocator.dupe(u8, head_data[0..54]);
    errdefer allocator.free(buf);

    writer.writeU32BE(buf, 8, 0);
    writer.writeI16BE(buf, 50, index_to_loc_format);

    return buf;
}
