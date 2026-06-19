const std = @import("std");
const parser = @import("../parser.zig");

pub const DesignAxis = struct {
    axis_tag: [4]u8,
    axis_name_id: u16,
    axis_ordering: u16,
};

pub const AxisValueFlags = struct {
    pub const OLDER_SIBLING_FONT_ATTRIBUTE: u16 = 0x0001;
    pub const ELIDABLE_AXIS_VALUE_NAME: u16 = 0x0002;
};

pub const AxisValue = union(enum) {
    format1: AxisValueFormat1,
    format2: AxisValueFormat2,
    format3: AxisValueFormat3,
    format4: AxisValueFormat4,
};

pub const AxisValueFormat1 = struct {
    axis_index: u16,
    flags: u16,
    value_name_id: u16,
    value: f32,
};

pub const AxisValueFormat2 = struct {
    axis_index: u16,
    flags: u16,
    value_name_id: u16,
    nominal_value: f32,
    range_min_value: f32,
    range_max_value: f32,
};

pub const AxisValueFormat3 = struct {
    axis_index: u16,
    flags: u16,
    value_name_id: u16,
    value: f32,
    linked_value: f32,
};

pub const AxisValueFormat4 = struct {
    flags: u16,
    value_name_id: u16,
    axis_count: u16,
};

pub const StatTable = struct {
    data: []const u8,
    design_axis_size: u16,
    design_axis_count: u16,
    design_axes_offset: u32,
    axis_value_count: u16,
    axis_value_array_offset: u32,
    elided_fallback_name_id: u16,

    pub fn getDesignAxis(self: StatTable, index: u16) !DesignAxis {
        if (index >= self.design_axis_count) return error.IndexOutOfRange;
        const offset = @as(usize, self.design_axes_offset) + @as(usize, index) * @as(usize, self.design_axis_size);
        return .{
            .axis_tag = .{
                try parser.readU8(self.data, offset),
                try parser.readU8(self.data, offset + 1),
                try parser.readU8(self.data, offset + 2),
                try parser.readU8(self.data, offset + 3),
            },
            .axis_name_id = try parser.readU16(self.data, offset + 4),
            .axis_ordering = try parser.readU16(self.data, offset + 6),
        };
    }

    pub fn getDesignAxisCount(self: StatTable) u16 {
        return self.design_axis_count;
    }

    pub fn getAxisValueCount(self: StatTable) u16 {
        return self.axis_value_count;
    }

    pub fn getElidedFallbackNameId(self: StatTable) u16 {
        return self.elided_fallback_name_id;
    }

    pub fn getAxisValue(self: StatTable, index: u16) !AxisValue {
        if (index >= self.axis_value_count) return error.IndexOutOfRange;
        if (self.axis_value_array_offset == 0) return error.IndexOutOfRange;

        const array_base = @as(usize, self.axis_value_array_offset);
        const entry_pos = array_base + @as(usize, index) * 2;
        if (entry_pos + 2 > self.data.len) return error.UnexpectedEof;
        const entry_offset = try parser.readU16(self.data, entry_pos);
        const av_offset = array_base + @as(usize, entry_offset);
        if (av_offset + 2 > self.data.len) return error.UnexpectedEof;

        const format = try parser.readU16(self.data, av_offset);
        switch (format) {
            1 => {
                return .{ .format1 = .{
                    .axis_index = try parser.readU16(self.data, av_offset + 2),
                    .flags = try parser.readU16(self.data, av_offset + 4),
                    .value_name_id = try parser.readU16(self.data, av_offset + 6),
                    .value = try readFixed(self.data, av_offset + 8),
                } };
            },
            2 => {
                return .{ .format2 = .{
                    .axis_index = try parser.readU16(self.data, av_offset + 2),
                    .flags = try parser.readU16(self.data, av_offset + 4),
                    .value_name_id = try parser.readU16(self.data, av_offset + 6),
                    .nominal_value = try readFixed(self.data, av_offset + 8),
                    .range_min_value = try readFixed(self.data, av_offset + 12),
                    .range_max_value = try readFixed(self.data, av_offset + 16),
                } };
            },
            3 => {
                return .{ .format3 = .{
                    .axis_index = try parser.readU16(self.data, av_offset + 2),
                    .flags = try parser.readU16(self.data, av_offset + 4),
                    .value_name_id = try parser.readU16(self.data, av_offset + 6),
                    .value = try readFixed(self.data, av_offset + 8),
                    .linked_value = try readFixed(self.data, av_offset + 12),
                } };
            },
            4 => {
                return .{ .format4 = .{
                    .axis_count = try parser.readU16(self.data, av_offset + 2),
                    .flags = try parser.readU16(self.data, av_offset + 4),
                    .value_name_id = try parser.readU16(self.data, av_offset + 6),
                } };
            },
            else => return error.UnsupportedFormat,
        }
    }

    pub fn getFormat4AxisValue(self: StatTable, axis_value_index: u16, position: u16) !struct { axis_index: u16, value: f32 } {
        if (axis_value_index >= self.axis_value_count) return error.IndexOutOfRange;
        if (self.axis_value_array_offset == 0) return error.IndexOutOfRange;

        const array_base = @as(usize, self.axis_value_array_offset);
        const entry_pos = array_base + @as(usize, axis_value_index) * 2;
        if (entry_pos + 2 > self.data.len) return error.UnexpectedEof;
        const entry_offset = try parser.readU16(self.data, entry_pos);
        const av_offset = array_base + @as(usize, entry_offset);
        if (av_offset + 8 > self.data.len) return error.UnexpectedEof;

        const format = try parser.readU16(self.data, av_offset);
        if (format != 4) return error.UnsupportedFormat;

        const axis_count = try parser.readU16(self.data, av_offset + 2);
        if (position >= axis_count) return error.IndexOutOfRange;

        const rec_offset = av_offset + 8 + @as(usize, position) * 6;
        if (rec_offset + 6 > self.data.len) return error.UnexpectedEof;
        return .{
            .axis_index = try parser.readU16(self.data, rec_offset),
            .value = try readFixed(self.data, rec_offset + 2),
        };
    }
};

fn readFixed(data: []const u8, offset: usize) !f32 {
    const raw = try parser.readI32(data, offset);
    return @as(f32, @floatFromInt(raw)) / 65536.0;
}

pub fn parse(data: []const u8) !StatTable {
    if (data.len < 18) return error.UnexpectedEof;
    const minor_version = try parser.readU16(data, 2);
    var elided_fallback_name_id: u16 = 0;
    if (minor_version >= 1 and data.len >= 20) {
        elided_fallback_name_id = try parser.readU16(data, 18);
    }
    return .{
        .data = data,
        .design_axis_size = try parser.readU16(data, 4),
        .design_axis_count = try parser.readU16(data, 6),
        .design_axes_offset = try parser.readU32(data, 8),
        .axis_value_count = try parser.readU16(data, 12),
        .axis_value_array_offset = try parser.readU32(data, 14),
        .elided_fallback_name_id = elided_fallback_name_id,
    };
}

test "parse STAT from SourceSans3VF-Subset" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const stat_record = p.findTable(offset_table, "STAT".*);
    if (stat_record) |rec| {
        const stat_data = try p.getTableData(font_data, rec);
        const stat = try parse(stat_data);

        try std.testing.expect(stat.getDesignAxisCount() > 0);

        const axis0 = try stat.getDesignAxis(0);
        try std.testing.expectEqualSlices(u8, "wght", &axis0.axis_tag);

        if (stat.getAxisValueCount() > 0) {
            const av = try stat.getAxisValue(0);
            switch (av) {
                .format1 => |f1| {
                    try std.testing.expect(f1.value_name_id > 0);
                },
                .format2 => |f2| {
                    try std.testing.expect(f2.value_name_id > 0);
                },
                .format3 => |f3| {
                    try std.testing.expect(f3.value_name_id > 0);
                },
                .format4 => |f4| {
                    try std.testing.expect(f4.value_name_id > 0);
                },
            }
        }
    }
}

test "STAT with synthetic format 1 data" {
    var data: [42]u8 = .{0} ** 42;
    data[0] = 0x00; data[1] = 0x01;
    data[2] = 0x00; data[3] = 0x01;
    data[4] = 0x00; data[5] = 0x08;
    data[6] = 0x00; data[7] = 0x01;
    data[8] = 0x00; data[9] = 0x00; data[10] = 0x00; data[11] = 0x14;
    data[12] = 0x00; data[13] = 0x01;
    data[14] = 0x00; data[15] = 0x00; data[16] = 0x00; data[17] = 0x1C;
    data[18] = 0x01; data[19] = 0x00;

    data[20] = 'w'; data[21] = 'g'; data[22] = 'h'; data[23] = 't';
    data[24] = 0x01; data[25] = 0x01;
    data[26] = 0x00; data[27] = 0x00;

    data[28] = 0x00; data[29] = 0x02;

    data[30] = 0x00; data[31] = 0x01;
    data[32] = 0x00; data[33] = 0x00;
    data[34] = 0x00; data[35] = 0x02;
    data[36] = 0x01; data[37] = 0x02;
    data[38] = 0x01; data[39] = 0x90; data[40] = 0x00; data[41] = 0x00;

    const stat = try parse(&data);
    try std.testing.expectEqual(@as(u16, 1), stat.getDesignAxisCount());
    try std.testing.expectEqual(@as(u16, 1), stat.getAxisValueCount());
    try std.testing.expectEqual(@as(u16, 256), stat.getElidedFallbackNameId());

    const axis = try stat.getDesignAxis(0);
    try std.testing.expectEqualSlices(u8, "wght", &axis.axis_tag);
    try std.testing.expectEqual(@as(u16, 257), axis.axis_name_id);

    const av = try stat.getAxisValue(0);
    switch (av) {
        .format1 => |f1| {
            try std.testing.expectEqual(@as(u16, 0), f1.axis_index);
            try std.testing.expectEqual(@as(u16, 0x0002), f1.flags);
            try std.testing.expectEqual(@as(u16, 258), f1.value_name_id);
            try std.testing.expectApproxEqAbs(@as(f32, 400.0), f1.value, 0.01);
        },
        else => return error.UnexpectedFormat,
    }

    try std.testing.expectError(error.IndexOutOfRange, stat.getDesignAxis(1));
    try std.testing.expectError(error.IndexOutOfRange, stat.getAxisValue(1));
}
