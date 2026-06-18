const std = @import("std");

const HEADER_SIZE: usize = 36;

const ON_CURVE: u8 = 0x01;
const X_SHORT: u8 = 0x02;
const Y_SHORT: u8 = 0x04;
const REPEAT_FLAG: u8 = 0x08;
const X_IS_SAME: u8 = 0x10;
const Y_IS_SAME: u8 = 0x20;

const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
const WE_HAVE_A_SCALE: u16 = 0x0008;
const MORE_COMPONENTS: u16 = 0x0020;
const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;
const WE_HAVE_INSTRUCTIONS: u16 = 0x0100;

pub const GlyfLocaResult = struct {
    glyf_data: []u8,
    loca_data: []u8,
    index_format: u16,

    pub fn deinit(self: GlyfLocaResult, allocator: std.mem.Allocator) void {
        allocator.free(self.glyf_data);
        allocator.free(self.loca_data);
    }
};

const TransformedHeader = struct {
    option_flags: u16,
    num_glyphs: u16,
    index_format: u16,
    n_contour_stream_size: u32,
    n_points_stream_size: u32,
    flag_stream_size: u32,
    glyph_stream_size: u32,
    composite_stream_size: u32,
    bbox_stream_size: u32,
    instruction_stream_size: u32,
};

pub fn reconstructGlyfLoca(
    allocator: std.mem.Allocator,
    transformed_glyf: []const u8,
    loca_orig_length: u32,
) !GlyfLocaResult {
    if (transformed_glyf.len < HEADER_SIZE) return error.UnexpectedEof;

    const header = try parseHeader(transformed_glyf);
    if (header.index_format > 1) return error.InvalidWoff2;

    const num_glyphs: usize = @intCast(header.num_glyphs);
    const expected_loca_len: u32 = if (header.index_format == 0)
        @as(u32, @intCast((num_glyphs + 1) * 2))
    else
        @as(u32, @intCast((num_glyphs + 1) * 4));
    if (loca_orig_length != 0 and loca_orig_length != expected_loca_len) return error.InvalidWoff2;

    const n_contour_size = num_glyphs * 2;
    if (header.n_contour_stream_size != @as(u32, @intCast(n_contour_size))) return error.InvalidWoff2;

    var pos: usize = HEADER_SIZE;
    const n_contour_stream = try readSlice(transformed_glyf, &pos, n_contour_size);
    const n_points_stream = try readSlice(transformed_glyf, &pos, @intCast(header.n_points_stream_size));
    const flag_stream = try readSlice(transformed_glyf, &pos, @intCast(header.flag_stream_size));
    const glyph_stream = try readSlice(transformed_glyf, &pos, @intCast(header.glyph_stream_size));
    const composite_stream = try readSlice(transformed_glyf, &pos, @intCast(header.composite_stream_size));
    const bbox_stream = try readSlice(transformed_glyf, &pos, @intCast(header.bbox_stream_size));
    const instruction_stream = try readSlice(transformed_glyf, &pos, @intCast(header.instruction_stream_size));
    if (pos != transformed_glyf.len) return error.InvalidWoff2;

    const bbox_bitmap_size = ((num_glyphs + 31) >> 5) << 2;
    if (bbox_bitmap_size > bbox_stream.len) return error.UnexpectedEof;
    const bbox_bitmap = bbox_stream[0..bbox_bitmap_size];
    const bbox_explicit = bbox_stream[bbox_bitmap_size..];

    var glyf: std.ArrayList(u8) = .empty;
    errdefer glyf.deinit(allocator);

    const offsets = try allocator.alloc(u32, num_glyphs + 1);
    defer allocator.free(offsets);

    var npoints_pos: usize = 0;
    var flag_pos: usize = 0;
    var glyph_pos: usize = 0;
    var composite_pos: usize = 0;
    var bbox_pos: usize = 0;
    var instruction_pos: usize = 0;

    for (0..num_glyphs) |glyph_id| {
        offsets[glyph_id] = @intCast(glyf.items.len);

        const contour_offset = glyph_id * 2;
        const n_contours = std.mem.readInt(i16, n_contour_stream[contour_offset..][0..2], .big);
        if (n_contours == 0) continue;

        if (n_contours > 0) {
            try reconstructSimpleGlyph(
                allocator,
                &glyf,
                @intCast(n_contours),
                glyph_id,
                n_points_stream,
                &npoints_pos,
                flag_stream,
                &flag_pos,
                glyph_stream,
                &glyph_pos,
                bbox_bitmap,
                bbox_explicit,
                &bbox_pos,
                instruction_stream,
                &instruction_pos,
            );
        } else {
            try reconstructCompoundGlyph(
                allocator,
                &glyf,
                glyph_stream,
                &glyph_pos,
                composite_stream,
                &composite_pos,
                bbox_explicit,
                &bbox_pos,
                instruction_stream,
                &instruction_pos,
            );
        }
    }
    offsets[num_glyphs] = @intCast(glyf.items.len);

    if (npoints_pos != n_points_stream.len) return error.InvalidWoff2;
    if (flag_pos != flag_stream.len) return error.InvalidWoff2;
    if (glyph_pos != glyph_stream.len) return error.InvalidWoff2;
    if (composite_pos != composite_stream.len) return error.InvalidWoff2;
    if (bbox_pos != bbox_explicit.len) return error.InvalidWoff2;
    if (instruction_pos != instruction_stream.len) return error.InvalidWoff2;

    const loca = try buildLoca(allocator, offsets, header.index_format);
    errdefer allocator.free(loca);

    const glyf_data = try glyf.toOwnedSlice(allocator);
    return .{
        .glyf_data = glyf_data,
        .loca_data = loca,
        .index_format = header.index_format,
    };
}

fn parseHeader(data: []const u8) !TransformedHeader {
    // Transformed glyf table header (WOFF2 spec):
    // reserved (UInt16, must be 0), optionFlags (UInt16), numGlyphs (UInt16),
    // indexFormat (UInt16), followed by 7 UInt32 stream sizes.
    const reserved = std.mem.readInt(u16, data[0..2], .big);
    if (reserved != 0) return error.InvalidWoff2;

    return .{
        .option_flags = std.mem.readInt(u16, data[2..4], .big),
        .num_glyphs = std.mem.readInt(u16, data[4..6], .big),
        .index_format = std.mem.readInt(u16, data[6..8], .big),
        .n_contour_stream_size = std.mem.readInt(u32, data[8..12], .big),
        .n_points_stream_size = std.mem.readInt(u32, data[12..16], .big),
        .flag_stream_size = std.mem.readInt(u32, data[16..20], .big),
        .glyph_stream_size = std.mem.readInt(u32, data[20..24], .big),
        .composite_stream_size = std.mem.readInt(u32, data[24..28], .big),
        .bbox_stream_size = std.mem.readInt(u32, data[28..32], .big),
        .instruction_stream_size = std.mem.readInt(u32, data[32..36], .big),
    };
}

fn reconstructSimpleGlyph(
    allocator: std.mem.Allocator,
    glyf: *std.ArrayList(u8),
    n_contours: usize,
    glyph_id: usize,
    n_points_stream: []const u8,
    npoints_pos: *usize,
    flag_stream: []const u8,
    flag_pos: *usize,
    glyph_stream: []const u8,
    glyph_pos: *usize,
    bbox_bitmap: []const u8,
    bbox_explicit: []const u8,
    bbox_pos: *usize,
    instruction_stream: []const u8,
    instruction_pos: *usize,
) !void {
    var end_pts: std.ArrayList(u16) = .empty;
    defer end_pts.deinit(allocator);

    var end_point: i32 = -1;
    for (0..n_contours) |_| {
        const pts_of_contour = try read255UShort(n_points_stream, npoints_pos);
        end_point += @as(i32, @intCast(pts_of_contour));
        if (end_point < 0 or end_point > std.math.maxInt(u16)) return error.InvalidWoff2;
        try end_pts.append(allocator, @intCast(end_point));
    }

    const n_points: usize = @intCast(end_point + 1);
    const transformed_flags = try readSlice(flag_stream, flag_pos, n_points);

    const x_coords = try allocator.alloc(i16, n_points);
    defer allocator.free(x_coords);
    const y_coords = try allocator.alloc(i16, n_points);
    defer allocator.free(y_coords);

    var x: i32 = 0;
    var y: i32 = 0;
    for (transformed_flags, 0..) |flag, i| {
        const triplet = try readTriplet(flag, glyph_stream, glyph_pos);
        x += @as(i32, @intCast(triplet.dx));
        y += @as(i32, @intCast(triplet.dy));
        if (x < std.math.minInt(i16) or x > std.math.maxInt(i16)) return error.InvalidWoff2;
        if (y < std.math.minInt(i16) or y > std.math.maxInt(i16)) return error.InvalidWoff2;
        x_coords[i] = @intCast(x);
        y_coords[i] = @intCast(y);
    }

    const instruction_length = try read255UShort(glyph_stream, glyph_pos);
    const instructions = try readSlice(instruction_stream, instruction_pos, @intCast(instruction_length));

    const bbox = if (hasBBox(bbox_bitmap, glyph_id))
        try readBBox(bbox_explicit, bbox_pos)
    else
        computeBBox(x_coords, y_coords);

    try appendI16(glyf, allocator, @intCast(n_contours));
    try appendI16(glyf, allocator, bbox.x_min);
    try appendI16(glyf, allocator, bbox.y_min);
    try appendI16(glyf, allocator, bbox.x_max);
    try appendI16(glyf, allocator, bbox.y_max);

    for (end_pts.items) |end_pt| {
        try appendU16(glyf, allocator, end_pt);
    }
    try appendU16(glyf, allocator, instruction_length);
    try glyf.appendSlice(allocator, instructions);

    var output_flags: std.ArrayList(u8) = .empty;
    defer output_flags.deinit(allocator);
    var x_bytes: std.ArrayList(u8) = .empty;
    defer x_bytes.deinit(allocator);
    var y_bytes: std.ArrayList(u8) = .empty;
    defer y_bytes.deinit(allocator);

    var prev_x: i16 = 0;
    var prev_y: i16 = 0;
    for (0..n_points) |i| {
        // WOFF2: bit 7 = 0 means on-curve, bit 7 = 1 means off-curve
        var flag: u8 = if (transformed_flags[i] & 0x80 == 0) ON_CURVE else 0;

        const dx: i32 = @as(i32, x_coords[i]) - @as(i32, prev_x);
        const dy: i32 = @as(i32, y_coords[i]) - @as(i32, prev_y);

        try encodeCoordinateDelta(&flag, X_SHORT, X_IS_SAME, dx, &x_bytes, allocator);
        try encodeCoordinateDelta(&flag, Y_SHORT, Y_IS_SAME, dy, &y_bytes, allocator);
        try output_flags.append(allocator, flag);

        prev_x = x_coords[i];
        prev_y = y_coords[i];
    }

    try glyf.appendSlice(allocator, output_flags.items);
    try glyf.appendSlice(allocator, x_bytes.items);
    try glyf.appendSlice(allocator, y_bytes.items);
    try pad2(glyf, allocator);
}

fn reconstructCompoundGlyph(
    allocator: std.mem.Allocator,
    glyf: *std.ArrayList(u8),
    glyph_stream: []const u8,
    glyph_pos: *usize,
    composite_stream: []const u8,
    composite_pos: *usize,
    bbox_explicit: []const u8,
    bbox_pos: *usize,
    instruction_stream: []const u8,
    instruction_pos: *usize,
) !void {
    var component_data: std.ArrayList(u8) = .empty;
    defer component_data.deinit(allocator);

    var have_instructions = false;
    while (true) {
        const flags_bytes = try readSlice(composite_stream, composite_pos, 2);
        const flags_u16 = std.mem.readInt(u16, flags_bytes[0..2], .big);
        try component_data.appendSlice(allocator, flags_bytes);

        const glyph_index = try readSlice(composite_stream, composite_pos, 2);
        try component_data.appendSlice(allocator, glyph_index);

        const arg_size: usize = if (flags_u16 & ARG_1_AND_2_ARE_WORDS != 0) 4 else 2;
        try component_data.appendSlice(allocator, try readSlice(composite_stream, composite_pos, arg_size));

        const transform_size: usize = if (flags_u16 & WE_HAVE_A_SCALE != 0)
            2
        else if (flags_u16 & WE_HAVE_AN_X_AND_Y_SCALE != 0)
            4
        else if (flags_u16 & WE_HAVE_A_TWO_BY_TWO != 0)
            8
        else
            0;
        try component_data.appendSlice(allocator, try readSlice(composite_stream, composite_pos, transform_size));

        if (flags_u16 & WE_HAVE_INSTRUCTIONS != 0) have_instructions = true;
        if (flags_u16 & MORE_COMPONENTS == 0) break;
    }

    if (have_instructions) {
        const instruction_length = try read255UShort(glyph_stream, glyph_pos);
        try appendU16(&component_data, allocator, instruction_length);
        const instructions = try readSlice(instruction_stream, instruction_pos, @intCast(instruction_length));
        try component_data.appendSlice(allocator, instructions);
    }

    const bbox = try readBBox(bbox_explicit, bbox_pos);

    try appendI16(glyf, allocator, -1);
    try appendI16(glyf, allocator, bbox.x_min);
    try appendI16(glyf, allocator, bbox.y_min);
    try appendI16(glyf, allocator, bbox.x_max);
    try appendI16(glyf, allocator, bbox.y_max);
    try glyf.appendSlice(allocator, component_data.items);
    try pad2(glyf, allocator);
}

fn buildLoca(allocator: std.mem.Allocator, offsets: []const u32, index_format: u16) ![]u8 {
    var loca: std.ArrayList(u8) = .empty;
    errdefer loca.deinit(allocator);

    if (index_format == 0) {
        for (offsets) |offset| {
            if (offset & 1 != 0) return error.InvalidWoff2;
            const short_offset = offset / 2;
            if (short_offset > std.math.maxInt(u16)) return error.InvalidWoff2;
            try appendU16(&loca, allocator, @intCast(short_offset));
        }
    } else {
        for (offsets) |offset| {
            try appendU32(&loca, allocator, offset);
        }
    }

    return loca.toOwnedSlice(allocator);
}

fn readSlice(data: []const u8, pos: *usize, len: usize) ![]const u8 {
    const end = std.math.add(usize, pos.*, len) catch return error.UnexpectedEof;
    if (end > data.len) return error.UnexpectedEof;
    const slice = data[pos.*..end];
    pos.* = end;
    return slice;
}

fn appendU16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    try buf.appendSlice(allocator, &bytes);
}

fn appendI16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(i16, &bytes, value, .big);
    try buf.appendSlice(allocator, &bytes);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try buf.appendSlice(allocator, &bytes);
}

fn pad2(buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    if (buf.items.len & 1 != 0) try buf.append(allocator, 0);
}

const BBox = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

fn readBBox(data: []const u8, pos: *usize) !BBox {
    const bytes = try readSlice(data, pos, 8);
    return .{
        .x_min = std.mem.readInt(i16, bytes[0..2], .big),
        .y_min = std.mem.readInt(i16, bytes[2..4], .big),
        .x_max = std.mem.readInt(i16, bytes[4..6], .big),
        .y_max = std.mem.readInt(i16, bytes[6..8], .big),
    };
}

fn computeBBox(x_coords: []const i16, y_coords: []const i16) BBox {
    if (x_coords.len == 0) {
        return .{ .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 };
    }

    var bbox = BBox{
        .x_min = x_coords[0],
        .y_min = y_coords[0],
        .x_max = x_coords[0],
        .y_max = y_coords[0],
    };
    for (x_coords[1..], y_coords[1..]) |x, y| {
        bbox.x_min = @min(bbox.x_min, x);
        bbox.y_min = @min(bbox.y_min, y);
        bbox.x_max = @max(bbox.x_max, x);
        bbox.y_max = @max(bbox.y_max, y);
    }
    return bbox;
}

fn encodeCoordinateDelta(
    flag: *u8,
    short_bit: u8,
    same_bit: u8,
    delta: i32,
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    if (delta == 0) {
        flag.* |= same_bit;
    } else if (delta >= 1 and delta <= 255) {
        flag.* |= short_bit | same_bit;
        try bytes.append(allocator, @intCast(delta));
    } else if (delta >= -255 and delta <= -1) {
        flag.* |= short_bit;
        try bytes.append(allocator, @intCast(-delta));
    } else {
        if (delta < std.math.minInt(i16) or delta > std.math.maxInt(i16)) return error.InvalidWoff2;
        var raw: [2]u8 = undefined;
        std.mem.writeInt(i16, &raw, @intCast(delta), .big);
        try bytes.appendSlice(allocator, &raw);
    }
}

fn read255UShort(data: []const u8, pos: *usize) !u16 {
    if (pos.* >= data.len) return error.UnexpectedEof;
    const code = data[pos.*];
    pos.* += 1;
    if (code == 253) {
        const bytes = try readSlice(data, pos, 2);
        const val = std.mem.readInt(u16, bytes[0..2], .big);
        return val;
    } else if (code == 255) {
        if (pos.* >= data.len) return error.UnexpectedEof;
        const val: u16 = @as(u16, data[pos.*]) + 253;
        pos.* += 1;
        return val;
    } else if (code == 254) {
        if (pos.* >= data.len) return error.UnexpectedEof;
        const val: u16 = @as(u16, data[pos.*]) + 253 * 2;
        pos.* += 1;
        return val;
    } else {
        return @as(u16, code);
    }
}

fn readTriplet(flag_byte: u8, glyph_data: []const u8, pos: *usize) !struct { dx: i16, dy: i16 } {
    const flag: u8 = flag_byte & 0x7F;
    const n_bytes: usize = if (flag < 84) 1 else if (flag < 120) 2 else if (flag < 124) 3 else 4;
    const b = try readSlice(glyph_data, pos, n_bytes);
    var dx: i32 = 0;
    var dy: i32 = 0;
    if (flag < 10) {
        dx = 0;
        const base: i32 = @as(i32, flag & 14) << 7;
        dy = base + @as(i32, b[0]);
        if (flag & 1 == 0) dy = -dy;
    } else if (flag < 20) {
        const f = flag - 10;
        const base: i32 = @as(i32, f & 14) << 7;
        dx = base + @as(i32, b[0]);
        dy = 0;
        if (flag & 1 == 0) dx = -dx;
    } else if (flag < 84) {
        const b0: i32 = @as(i32, flag) - 20;
        const byte1 = b[0];
        dx = 1 + (b0 & 0x30) + @as(i32, byte1 >> 4);
        dy = 1 + ((b0 & 0x0c) << 2) + @as(i32, byte1 & 0x0f);
        if (flag & 1 == 0) dx = -dx;
        if ((flag >> 1) & 1 == 0) dy = -dy;
    } else if (flag < 120) {
        const b0: i32 = @as(i32, flag) - 84;
        dx = 1 + (@divTrunc(b0, 12) << 8) + @as(i32, b[0]);
        dy = 1 + ((@rem(b0, 12) >> 2) << 8) + @as(i32, b[1]);
        if (flag & 1 == 0) dx = -dx;
        if ((flag >> 1) & 1 == 0) dy = -dy;
    } else if (flag < 124) {
        dx = (@as(i32, b[0]) << 4) | @as(i32, b[1] >> 4);
        dy = (@as(i32, b[1] & 0x0f) << 8) | @as(i32, b[2]);
        if (flag & 1 == 0) dx = -dx;
        if ((flag >> 1) & 1 == 0) dy = -dy;
    } else {
        dx = (@as(i32, b[0]) << 8) | @as(i32, b[1]);
        dy = (@as(i32, b[2]) << 8) | @as(i32, b[3]);
        if (flag & 1 == 0) dx = -dx;
        if ((flag >> 1) & 1 == 0) dy = -dy;
    }
    if (dx < std.math.minInt(i16) or dx > std.math.maxInt(i16)) return error.InvalidWoff2;
    if (dy < std.math.minInt(i16) or dy > std.math.maxInt(i16)) return error.InvalidWoff2;
    return .{ .dx = @intCast(dx), .dy = @intCast(dy) };
}

fn hasBBox(bitmap: []const u8, glyph_id: usize) bool {
    const byte_idx = glyph_id >> 3;
    if (byte_idx >= bitmap.len) return false;
    return (bitmap[byte_idx] & (@as(u8, 0x80) >> @intCast(glyph_id & 7))) != 0;
}

test "read255UShort single byte" {
    const data = [_]u8{42};
    var pos: usize = 0;
    const val = try read255UShort(&data, &pos);
    try std.testing.expectEqual(@as(u16, 42), val);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "read255UShort code 253 two bytes" {
    const data = [_]u8{ 253, 0x01, 0x00 }; // = 256
    var pos: usize = 0;
    const val = try read255UShort(&data, &pos);
    try std.testing.expectEqual(@as(u16, 256), val);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "read255UShort code 255" {
    const data = [_]u8{ 255, 10 }; // = 10 + 253 = 263
    var pos: usize = 0;
    const val = try read255UShort(&data, &pos);
    try std.testing.expectEqual(@as(u16, 263), val);
}

test "read255UShort code 254" {
    const data = [_]u8{ 254, 0 }; // = 0 + 506 = 506
    var pos: usize = 0;
    const val = try read255UShort(&data, &pos);
    try std.testing.expectEqual(@as(u16, 506), val);
}

test "hasBBox" {
    const bitmap = [_]u8{ 0b10100000, 0b00000001 };
    try std.testing.expect(hasBBox(&bitmap, 0));
    try std.testing.expect(!hasBBox(&bitmap, 1));
    try std.testing.expect(hasBBox(&bitmap, 2));
    try std.testing.expect(!hasBBox(&bitmap, 3));
    try std.testing.expect(hasBBox(&bitmap, 15));
}

