const std = @import("std");
const parser = @import("../parser.zig");

pub const AxisRecord = struct {
    tag: [4]u8,
    min_value: f32,
    default_value: f32,
    max_value: f32,
    flags: u16,
    axis_name_id: u16,
};

pub const FvarTable = struct {
    data: []const u8,
    axis_count: u16,
    instance_count: u16,
    instance_size: u16,
    axes_offset: u16,
    axis_size: u16,

    pub fn getAxisCount(self: FvarTable) u16 {
        return self.axis_count;
    }

    pub fn getAxis(self: FvarTable, index: u16) !AxisRecord {
        if (index >= self.axis_count) return error.InvalidAxisIndex;
        const offset: usize = @as(usize, self.axes_offset) + @as(usize, index) * @as(usize, self.axis_size);
        const tag = self.data[offset..][0..4].*;
        const min_raw = try parser.readI32(self.data, offset + 4);
        const default_raw = try parser.readI32(self.data, offset + 8);
        const max_raw = try parser.readI32(self.data, offset + 12);
        const flags = try parser.readU16(self.data, offset + 16);
        const axis_name_id = try parser.readU16(self.data, offset + 18);
        return .{
            .tag = tag,
            .min_value = @as(f32, @floatFromInt(min_raw)) / 65536.0,
            .default_value = @as(f32, @floatFromInt(default_raw)) / 65536.0,
            .max_value = @as(f32, @floatFromInt(max_raw)) / 65536.0,
            .flags = flags,
            .axis_name_id = axis_name_id,
        };
    }

    pub fn normalizeCoord(self: FvarTable, axis_index: u16, user_value: f32) !f32 {
        const axis = try self.getAxis(axis_index);
        if (user_value == axis.default_value) return 0.0;
        if (user_value <= axis.min_value) return -1.0;
        if (user_value >= axis.max_value) return 1.0;
        if (user_value < axis.default_value) {
            if (axis.default_value == axis.min_value) return 0.0;
            return -(axis.default_value - user_value) / (axis.default_value - axis.min_value);
        }
        if (user_value > axis.default_value) {
            if (axis.max_value == axis.default_value) return 0.0;
            return (user_value - axis.default_value) / (axis.max_value - axis.default_value);
        }
        return 0.0;
    }

    pub fn normalizeCoords(self: FvarTable, allocator: std.mem.Allocator, user_coords: []const f32) ![]f32 {
        if (user_coords.len != self.axis_count) return error.InvalidAxisCount;
        const result = try allocator.alloc(f32, self.axis_count);
        errdefer allocator.free(result);
        for (0..self.axis_count) |i| {
            result[i] = try self.normalizeCoord(@intCast(i), user_coords[i]);
        }
        return result;
    }
};

pub const FvarError = error{
    InvalidAxisIndex,
    InvalidAxisCount,
    UnexpectedEof,
};

pub fn parse(data: []const u8) !FvarTable {
    if (data.len < 16) return error.UnexpectedEof;
    const axes_offset = try parser.readU16(data, 4);
    const axis_count = try parser.readU16(data, 8);
    const axis_size = try parser.readU16(data, 10);
    const instance_count = try parser.readU16(data, 12);
    const instance_size = try parser.readU16(data, 14);
    return .{
        .data = data,
        .axis_count = axis_count,
        .instance_count = instance_count,
        .instance_size = instance_size,
        .axes_offset = axes_offset,
        .axis_size = axis_size,
    };
}

test "parse fvar from SourceSans3VF-Subset" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const fvar_record = parser.findTable(offset_table, "fvar".*) orelse return error.TableNotFound;
    const fvar_data = try parser.getTableData(font_data, fvar_record);
    const fvar = try parse(fvar_data);

    try std.testing.expectEqual(@as(u16, 1), fvar.getAxisCount());

    const axis = try fvar.getAxis(0);
    try std.testing.expect(std.mem.eql(u8, &axis.tag, "wght"));
    try std.testing.expectEqual(@as(f32, 200.0), axis.min_value);
    try std.testing.expectEqual(@as(f32, 900.0), axis.max_value);
}

test "normalizeCoord" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const fvar_record = parser.findTable(offset_table, "fvar".*) orelse return error.TableNotFound;
    const fvar_data = try parser.getTableData(font_data, fvar_record);
    const fvar = try parse(fvar_data);

    const axis = try fvar.getAxis(0);
    const norm_default = try fvar.normalizeCoord(0, axis.default_value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), norm_default, 0.001);

    // min == default in this font, so normalized min is 0.0
    const norm_min = try fvar.normalizeCoord(0, axis.min_value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), norm_min, 0.001);

    const norm_max = try fvar.normalizeCoord(0, axis.max_value);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm_max, 0.001);
}
