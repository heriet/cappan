const std = @import("std");
const parser = @import("../parser.zig");
const glyph_mod = @import("../glyph.zig");
const glyf_mod = @import("glyf.zig");

pub const VariationDeltas = struct {
    x: []f32,
    y: []f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VariationDeltas) void {
        self.allocator.free(self.x);
        self.allocator.free(self.y);
    }
};

pub const GvarTable = struct {
    data: []const u8,
    axis_count: u16,
    shared_tuple_count: u16,
    shared_tuples_offset: u32,
    glyph_count: u16,
    flags: u16,
    glyph_variation_data_offset: u32,

    pub fn applyDeltas(
        self: GvarTable,
        allocator: std.mem.Allocator,
        glyph_id: u16,
        outline: *glyph_mod.GlyphOutline,
        normalized_coords: []const f32,
    ) !void {
        var total_points: usize = 0;
        for (outline.contours) |contour| {
            total_points += contour.points.len;
        }

        var deltas = (try self.computeDeltas(allocator, glyph_id, total_points + 4, normalized_coords)) orelse return;
        defer deltas.deinit();

        var pt_idx: usize = 0;
        for (outline.contours) |contour| {
            for (contour.points) |*pt| {
                pt.x = @as(i16, @intFromFloat(@round(@as(f32, @floatFromInt(pt.x)) + deltas.x[pt_idx])));
                pt.y = @as(i16, @intFromFloat(@round(@as(f32, @floatFromInt(pt.y)) + deltas.y[pt_idx])));
                pt_idx += 1;
            }
        }
    }

    pub fn applyCompoundDeltas(
        self: GvarTable,
        allocator: std.mem.Allocator,
        glyph_id: u16,
        components: []glyf_mod.ComponentInfo,
        normalized_coords: []const f32,
    ) !void {
        var deltas = (try self.computeDeltas(allocator, glyph_id, components.len + 4, normalized_coords)) orelse return;
        defer deltas.deinit();

        for (components, 0..) |*comp, i| {
            comp.dx = @as(i16, @intFromFloat(@round(@as(f32, @floatFromInt(comp.dx)) + deltas.x[i])));
            comp.dy = @as(i16, @intFromFloat(@round(@as(f32, @floatFromInt(comp.dy)) + deltas.y[i])));
        }
    }

    fn computeDeltas(
        self: GvarTable,
        allocator: std.mem.Allocator,
        glyph_id: u16,
        num_points_with_phantom: usize,
        normalized_coords: []const f32,
    ) !?VariationDeltas {
        if (glyph_id >= self.glyph_count) return null;
        if (normalized_coords.len != self.axis_count) return null;

        const var_data_offset = try self.getGlyphVariationDataOffset(glyph_id);
        const var_data_end = try self.getGlyphVariationDataOffset(glyph_id + 1);
        if (var_data_offset == var_data_end) return null;

        const base = @as(usize, self.glyph_variation_data_offset) + var_data_offset;
        const end = @as(usize, self.glyph_variation_data_offset) + var_data_end;
        if (end > self.data.len) return error.UnexpectedEof;
        const glyph_var_data = self.data[base..end];

        const x_deltas = try allocator.alloc(f32, num_points_with_phantom);
        errdefer allocator.free(x_deltas);
        const y_deltas = try allocator.alloc(f32, num_points_with_phantom);
        errdefer allocator.free(y_deltas);
        @memset(x_deltas, 0.0);
        @memset(y_deltas, 0.0);

        const tuple_variation_count_raw = try parser.readU16(glyph_var_data, 0);
        const tuple_count: u16 = tuple_variation_count_raw & 0x0FFF;
        const has_shared_points = (tuple_variation_count_raw & 0x8000) != 0;
        const serialized_data_offset = try parser.readU16(glyph_var_data, 2);

        var serialized_pos: usize = @as(usize, serialized_data_offset);

        var shared_points: ?[]u16 = null;
        defer if (shared_points) |sp| allocator.free(sp);

        if (has_shared_points) {
            const result = try unpackPointNumbers(allocator, glyph_var_data, serialized_pos);
            shared_points = result.points orelse null;
            serialized_pos = result.new_offset;
        }

        var header_offset: usize = 4;
        var tuple_idx: u16 = 0;
        while (tuple_idx < tuple_count) : (tuple_idx += 1) {
            const variation_data_size = try parser.readU16(glyph_var_data, header_offset);
            const tuple_index = try parser.readU16(glyph_var_data, header_offset + 2);
            header_offset += 4;

            const EMBEDDED_PEAK_TUPLE: u16 = 0x8000;
            const INTERMEDIATE_REGION: u16 = 0x4000;
            const PRIVATE_POINT_NUMBERS: u16 = 0x2000;

            var peak_coords = try allocator.alloc(f32, self.axis_count);
            defer allocator.free(peak_coords);

            if (tuple_index & EMBEDDED_PEAK_TUPLE != 0) {
                for (0..self.axis_count) |i| {
                    peak_coords[i] = try parser.readF2Dot14(glyph_var_data, header_offset);
                    header_offset += 2;
                }
            } else {
                const shared_idx = tuple_index & 0x0FFF;
                const tuple_offset = @as(usize, self.shared_tuples_offset) + @as(usize, shared_idx) * @as(usize, self.axis_count) * 2;
                for (0..self.axis_count) |i| {
                    peak_coords[i] = try parser.readF2Dot14(self.data, tuple_offset + i * 2);
                }
            }

            var start_coords: ?[]f32 = null;
            var end_coords: ?[]f32 = null;
            defer if (start_coords) |sc| allocator.free(sc);
            defer if (end_coords) |ec| allocator.free(ec);

            if (tuple_index & INTERMEDIATE_REGION != 0) {
                start_coords = try allocator.alloc(f32, self.axis_count);
                for (0..self.axis_count) |i| {
                    start_coords.?[i] = try parser.readF2Dot14(glyph_var_data, header_offset);
                    header_offset += 2;
                }
                end_coords = try allocator.alloc(f32, self.axis_count);
                for (0..self.axis_count) |i| {
                    end_coords.?[i] = try parser.readF2Dot14(glyph_var_data, header_offset);
                    header_offset += 2;
                }
            }

            const scalar = computeScalar(normalized_coords, peak_coords, start_coords, end_coords);
            if (scalar == 0.0) {
                serialized_pos += variation_data_size;
                continue;
            }

            const data_start = serialized_pos;

            var points: ?[]u16 = null;
            defer if (points) |p| allocator.free(p);

            if (tuple_index & PRIVATE_POINT_NUMBERS != 0) {
                const result = try unpackPointNumbers(allocator, glyph_var_data, serialized_pos);
                points = result.points orelse null;
                serialized_pos = result.new_offset;
            }

            const active_points = points orelse shared_points;

            const x_result = try unpackDeltas(allocator, glyph_var_data, serialized_pos, if (active_points) |ap| @as(u16, @intCast(ap.len)) else @as(u16, @intCast(num_points_with_phantom)));
            serialized_pos = x_result.new_offset;
            defer allocator.free(x_result.deltas);

            const y_result = try unpackDeltas(allocator, glyph_var_data, serialized_pos, if (active_points) |ap| @as(u16, @intCast(ap.len)) else @as(u16, @intCast(num_points_with_phantom)));
            defer allocator.free(y_result.deltas);

            serialized_pos = data_start + variation_data_size;

            if (active_points) |ap| {
                for (ap, 0..) |pt_idx, i| {
                    if (pt_idx < num_points_with_phantom and i < x_result.deltas.len and i < y_result.deltas.len) {
                        x_deltas[pt_idx] += @as(f32, @floatFromInt(x_result.deltas[i])) * scalar;
                        y_deltas[pt_idx] += @as(f32, @floatFromInt(y_result.deltas[i])) * scalar;
                    }
                }
            } else {
                const count = @min(num_points_with_phantom, @min(x_result.deltas.len, y_result.deltas.len));
                for (0..count) |i| {
                    x_deltas[i] += @as(f32, @floatFromInt(x_result.deltas[i])) * scalar;
                    y_deltas[i] += @as(f32, @floatFromInt(y_result.deltas[i])) * scalar;
                }
            }
        }

        return .{
            .x = x_deltas,
            .y = y_deltas,
            .allocator = allocator,
        };
    }

    fn getGlyphVariationDataOffset(self: GvarTable, index: u16) !usize {
        const long_offsets = (self.flags & 1) != 0;
        const offsets_start: usize = 20;
        if (long_offsets) {
            const pos = offsets_start + @as(usize, index) * 4;
            return @as(usize, try parser.readU32(self.data, pos));
        } else {
            const pos = offsets_start + @as(usize, index) * 2;
            return @as(usize, try parser.readU16(self.data, pos)) * 2;
        }
    }
};

fn computeScalar(coords: []const f32, peak: []const f32, start: ?[]f32, end: ?[]f32) f32 {
    var scalar: f32 = 1.0;
    for (0..coords.len) |i| {
        if (peak[i] == 0.0) continue;
        if (coords[i] == peak[i]) continue;

        if (start != null and end != null) {
            if (coords[i] < start.?[i] or coords[i] > end.?[i]) return 0.0;
            if (coords[i] < peak[i]) {
                if (peak[i] == start.?[i]) return 0.0;
                scalar *= (coords[i] - start.?[i]) / (peak[i] - start.?[i]);
            } else {
                if (peak[i] == end.?[i]) return 0.0;
                scalar *= (end.?[i] - coords[i]) / (end.?[i] - peak[i]);
            }
        } else {
            if (coords[i] == 0.0) return 0.0;
            if ((coords[i] < 0.0) != (peak[i] < 0.0)) return 0.0;
            if (@abs(coords[i]) < @abs(peak[i])) {
                scalar *= coords[i] / peak[i];
            }
        }
    }
    return scalar;
}

const UnpackPointsResult = struct {
    points: ?[]u16,
    new_offset: usize,
};

fn unpackPointNumbers(allocator: std.mem.Allocator, data: []const u8, offset: usize) !UnpackPointsResult {
    var pos = offset;
    const count_byte = try parser.readU8(data, pos);
    pos += 1;
    var count: u16 = undefined;
    if (count_byte == 0) {
        return .{ .points = null, .new_offset = pos };
    }
    if (count_byte & 0x80 != 0) {
        const next = try parser.readU8(data, pos);
        pos += 1;
        count = (@as(u16, count_byte & 0x7F) << 8) | @as(u16, next);
    } else {
        count = @as(u16, count_byte);
    }
    const points = try allocator.alloc(u16, count);
    errdefer allocator.free(points);

    var i: usize = 0;
    var accumulated: u16 = 0;
    while (i < count) {
        const control = try parser.readU8(data, pos);
        pos += 1;
        const run_count: usize = @as(usize, control & 0x7F) + 1;
        const is_word = (control & 0x80) != 0;

        for (0..run_count) |_| {
            if (i >= count) break;
            if (is_word) {
                accumulated += try parser.readU16(data, pos);
                pos += 2;
            } else {
                accumulated += @as(u16, try parser.readU8(data, pos));
                pos += 1;
            }
            points[i] = accumulated;
            i += 1;
        }
    }
    return .{ .points = points, .new_offset = pos };
}

const UnpackDeltasResult = struct {
    deltas: []i16,
    new_offset: usize,
};

fn unpackDeltas(allocator: std.mem.Allocator, data: []const u8, offset: usize, count: u16) !UnpackDeltasResult {
    const deltas = try allocator.alloc(i16, count);
    errdefer allocator.free(deltas);

    var pos = offset;
    var i: usize = 0;
    while (i < count) {
        const control = try parser.readU8(data, pos);
        pos += 1;
        const run_count: usize = @as(usize, control & 0x3F) + 1;
        const is_zero = (control & 0x80) != 0;
        const is_word = (control & 0x40) != 0;

        if (is_zero) {
            for (0..run_count) |_| {
                if (i >= count) break;
                deltas[i] = 0;
                i += 1;
            }
        } else if (is_word) {
            for (0..run_count) |_| {
                if (i >= count) break;
                deltas[i] = try parser.readI16(data, pos);
                pos += 2;
                i += 1;
            }
        } else {
            for (0..run_count) |_| {
                if (i >= count) break;
                deltas[i] = @as(i16, try parser.readI8(data, pos));
                pos += 1;
                i += 1;
            }
        }
    }
    return .{ .deltas = deltas, .new_offset = pos };
}

pub fn parse(data: []const u8) !GvarTable {
    if (data.len < 20) return error.UnexpectedEof;
    return .{
        .data = data,
        .axis_count = try parser.readU16(data, 4),
        .shared_tuple_count = try parser.readU16(data, 6),
        .shared_tuples_offset = try parser.readU32(data, 8),
        .glyph_count = try parser.readU16(data, 12),
        .flags = try parser.readU16(data, 14),
        .glyph_variation_data_offset = try parser.readU32(data, 16),
    };
}

test "parse gvar from SourceSans3VF-Subset" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const gvar_record = parser.findTable(offset_table, "gvar".*) orelse return error.TableNotFound;
    const gvar_data = try parser.getTableData(font_data, gvar_record);
    const gvar = try parse(gvar_data);

    try std.testing.expectEqual(@as(u16, 1), gvar.axis_count);
    try std.testing.expect(gvar.glyph_count > 0);
    try std.testing.expect(gvar.shared_tuple_count > 0);
}
