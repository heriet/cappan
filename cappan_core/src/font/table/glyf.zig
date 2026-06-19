const std = @import("std");
const parser = @import("../parser.zig");
const glyph_mod = @import("../glyph.zig");
const loca_mod = @import("loca.zig");

pub const ComponentInfo = struct {
    glyph_id: u16,
    dx: i16,
    dy: i16,
    mat_a: f32,
    mat_b: f32,
    mat_c: f32,
    mat_d: f32,
    has_transform: bool,
};

pub const GlyfTable = struct {
    data: []const u8,

    const MAX_COMPOUND_DEPTH = 10;

    // glyf flag bits
    const ON_CURVE_POINT: u8 = 0x01;
    const X_SHORT_VECTOR: u8 = 0x02;
    const Y_SHORT_VECTOR: u8 = 0x04;
    const REPEAT_FLAG: u8 = 0x08;
    const X_IS_SAME_OR_POSITIVE: u8 = 0x10;
    const Y_IS_SAME_OR_POSITIVE: u8 = 0x20;

    // compound glyph flags
    const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
    const ARGS_ARE_XY_VALUES: u16 = 0x0002;
    const MORE_COMPONENTS: u16 = 0x0020;
    const WE_HAVE_A_SCALE: u16 = 0x0008;
    const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
    const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;

    pub fn isCompoundGlyph(self: GlyfTable, glyph_id: u16, loca: loca_mod.LocaTable) GlyfError!bool {
        const loc = try loca.getGlyphLocation(glyph_id);
        if (loc.length == 0) return false;
        const end = @as(usize, loc.offset) + @as(usize, loc.length);
        if (end > self.data.len) return error.InvalidGlyphData;
        const glyph_data = self.data[loc.offset..end];
        const number_of_contours = try parser.readI16(glyph_data, 0);
        return number_of_contours < 0;
    }

    pub fn getComponentInfos(self: GlyfTable, allocator: std.mem.Allocator, glyph_id: u16, loca: loca_mod.LocaTable) GlyfError!?[]ComponentInfo {
        const loc = try loca.getGlyphLocation(glyph_id);
        if (loc.length == 0) return null;
        const end = @as(usize, loc.offset) + @as(usize, loc.length);
        if (end > self.data.len) return error.InvalidGlyphData;
        const glyph_data = self.data[loc.offset..end];
        const number_of_contours = try parser.readI16(glyph_data, 0);
        if (number_of_contours >= 0) return null; // simple glyph

        var components: std.ArrayList(ComponentInfo) = .empty;
        errdefer components.deinit(allocator);

        var offset: usize = 10;
        var flags: u16 = MORE_COMPONENTS;
        var component_count: u32 = 0;
        while (flags & MORE_COMPONENTS != 0) {
            if (component_count >= MAX_COMPOUND_DEPTH * 64) return error.InvalidGlyphData;
            component_count += 1;
            flags = try parser.readU16(glyph_data, offset);
            offset += 2;
            const component_glyph_id = try parser.readU16(glyph_data, offset);
            offset += 2;

            var dx: i16 = 0;
            var dy: i16 = 0;

            if (flags & ARGS_ARE_XY_VALUES != 0) {
                if (flags & ARG_1_AND_2_ARE_WORDS != 0) {
                    dx = try parser.readI16(glyph_data, offset);
                    dy = try parser.readI16(glyph_data, offset + 2);
                    offset += 4;
                } else {
                    dx = @as(i16, try parser.readI8(glyph_data, offset));
                    dy = @as(i16, try parser.readI8(glyph_data, offset + 1));
                    offset += 2;
                }
            } else {
                if (flags & ARG_1_AND_2_ARE_WORDS != 0) {
                    offset += 4;
                } else {
                    offset += 2;
                }
            }

            var mat_a: f32 = 1.0;
            var mat_b: f32 = 0.0;
            var mat_c: f32 = 0.0;
            var mat_d: f32 = 1.0;
            const has_transform = (flags & (WE_HAVE_A_SCALE | WE_HAVE_AN_X_AND_Y_SCALE | WE_HAVE_A_TWO_BY_TWO)) != 0;

            if (flags & WE_HAVE_A_SCALE != 0) {
                mat_a = try parser.readF2Dot14(glyph_data, offset);
                mat_d = mat_a;
                offset += 2;
            } else if (flags & WE_HAVE_AN_X_AND_Y_SCALE != 0) {
                mat_a = try parser.readF2Dot14(glyph_data, offset);
                mat_d = try parser.readF2Dot14(glyph_data, offset + 2);
                offset += 4;
            } else if (flags & WE_HAVE_A_TWO_BY_TWO != 0) {
                mat_a = try parser.readF2Dot14(glyph_data, offset);
                mat_b = try parser.readF2Dot14(glyph_data, offset + 2);
                mat_c = try parser.readF2Dot14(glyph_data, offset + 4);
                mat_d = try parser.readF2Dot14(glyph_data, offset + 6);
                offset += 8;
            }

            try components.append(allocator, .{
                .glyph_id = component_glyph_id,
                .dx = dx,
                .dy = dy,
                .mat_a = mat_a,
                .mat_b = mat_b,
                .mat_c = mat_c,
                .mat_d = mat_d,
                .has_transform = has_transform,
            });
        }
        return try components.toOwnedSlice(allocator);
    }

    pub fn getGlyphOutline(self: GlyfTable, allocator: std.mem.Allocator, glyph_id: u16, loca: loca_mod.LocaTable) GlyfError!?glyph_mod.GlyphOutline {
        return self.getGlyphOutlineRecursive(allocator, glyph_id, loca, 0);
    }

    fn getGlyphOutlineRecursive(self: GlyfTable, allocator: std.mem.Allocator, glyph_id: u16, loca: loca_mod.LocaTable, depth: u32) GlyfError!?glyph_mod.GlyphOutline {
        if (depth > MAX_COMPOUND_DEPTH) return error.CompoundGlyphTooDeep;

        const loc = try loca.getGlyphLocation(glyph_id);
        if (loc.length == 0) return null; // empty glyph (e.g. space)

        const end = @as(usize, loc.offset) + @as(usize, loc.length);
        if (end > self.data.len) return error.InvalidGlyphData;
        const glyph_data = self.data[loc.offset..end];
        const number_of_contours = try parser.readI16(glyph_data, 0);
        const x_min = try parser.readI16(glyph_data, 2);
        const y_min = try parser.readI16(glyph_data, 4);
        const x_max = try parser.readI16(glyph_data, 6);
        const y_max = try parser.readI16(glyph_data, 8);

        if (number_of_contours >= 0) {
            return try self.parseSimpleGlyph(allocator, glyph_data, @intCast(number_of_contours), x_min, y_min, x_max, y_max);
        } else {
            return try self.parseCompoundGlyph(allocator, glyph_data, loca, x_min, y_min, x_max, y_max, depth);
        }
    }

    fn parseSimpleGlyph(
        self: GlyfTable,
        allocator: std.mem.Allocator,
        glyph_data: []const u8,
        num_contours: u16,
        x_min: i16,
        y_min: i16,
        x_max: i16,
        y_max: i16,
    ) !glyph_mod.GlyphOutline {
        _ = self;
        var offset: usize = 10;

        // Read endPtsOfContours
        const end_pts = try allocator.alloc(u16, num_contours);
        defer allocator.free(end_pts);

        for (0..num_contours) |i| {
            end_pts[i] = try parser.readU16(glyph_data, offset);
            offset += 2;
        }

        const num_points: usize = if (num_contours > 0) @as(usize, end_pts[num_contours - 1]) + 1 else 0;

        // Skip instructions
        const instruction_length = try parser.readU16(glyph_data, offset);
        offset += 2 + @as(usize, instruction_length);

        // Read flags (with repeat expansion)
        const flags = try allocator.alloc(u8, num_points);
        defer allocator.free(flags);

        var flag_idx: usize = 0;
        while (flag_idx < num_points) {
            const flag = try parser.readU8(glyph_data, offset);
            offset += 1;
            flags[flag_idx] = flag;
            flag_idx += 1;

            if (flag & REPEAT_FLAG != 0) {
                const repeat_count = try parser.readU8(glyph_data, offset);
                offset += 1;
                for (0..repeat_count) |_| {
                    if (flag_idx >= num_points) break;
                    flags[flag_idx] = flag;
                    flag_idx += 1;
                }
            }
        }

        // Read x-coordinates (deltas)
        const x_coords = try allocator.alloc(i16, num_points);
        defer allocator.free(x_coords);
        var x: i16 = 0;
        for (0..num_points) |i| {
            if (flags[i] & X_SHORT_VECTOR != 0) {
                const dx = @as(i16, try parser.readU8(glyph_data, offset));
                offset += 1;
                if (flags[i] & X_IS_SAME_OR_POSITIVE != 0) {
                    x += dx;
                } else {
                    x -= dx;
                }
            } else {
                if (flags[i] & X_IS_SAME_OR_POSITIVE != 0) {
                    // x is same as previous (delta = 0)
                } else {
                    x += try parser.readI16(glyph_data, offset);
                    offset += 2;
                }
            }
            x_coords[i] = x;
        }

        // Read y-coordinates (deltas)
        const y_coords = try allocator.alloc(i16, num_points);
        defer allocator.free(y_coords);
        var y: i16 = 0;
        for (0..num_points) |i| {
            if (flags[i] & Y_SHORT_VECTOR != 0) {
                const dy = @as(i16, try parser.readU8(glyph_data, offset));
                offset += 1;
                if (flags[i] & Y_IS_SAME_OR_POSITIVE != 0) {
                    y += dy;
                } else {
                    y -= dy;
                }
            } else {
                if (flags[i] & Y_IS_SAME_OR_POSITIVE != 0) {
                    // y is same as previous (delta = 0)
                } else {
                    y += try parser.readI16(glyph_data, offset);
                    offset += 2;
                }
            }
            y_coords[i] = y;
        }

        // Split points into contours
        const contours = try allocator.alloc(glyph_mod.Contour, num_contours);
        errdefer {
            for (contours) |contour| {
                if (contour.points.len > 0) allocator.free(contour.points);
            }
            allocator.free(contours);
        }

        var start_pt: usize = 0;
        for (0..num_contours) |c| {
            const end_pt = @as(usize, end_pts[c]) + 1;
            const count = end_pt - start_pt;
            const points = try allocator.alloc(glyph_mod.Point, count);

            for (0..count) |p| {
                const idx = start_pt + p;
                points[p] = .{
                    .x = x_coords[idx],
                    .y = y_coords[idx],
                    .on_curve = (flags[idx] & ON_CURVE_POINT) != 0,
                };
            }

            contours[c] = .{ .points = points };
            start_pt = end_pt;
        }

        return .{
            .contours = contours,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
            .allocator = allocator,
        };
    }

    fn parseCompoundGlyph(
        self: GlyfTable,
        allocator: std.mem.Allocator,
        glyph_data: []const u8,
        loca: loca_mod.LocaTable,
        x_min: i16,
        y_min: i16,
        x_max: i16,
        y_max: i16,
        depth: u32,
    ) !glyph_mod.GlyphOutline {
        var offset: usize = 10;
        var all_contours: std.ArrayList(glyph_mod.Contour) = .empty;
        defer all_contours.deinit(allocator);

        var flags: u16 = MORE_COMPONENTS;
        while (flags & MORE_COMPONENTS != 0) {
            flags = try parser.readU16(glyph_data, offset);
            offset += 2;
            const component_glyph_id = try parser.readU16(glyph_data, offset);
            offset += 2;

            var dx: i16 = 0;
            var dy: i16 = 0;

            if (flags & ARGS_ARE_XY_VALUES != 0) {
                if (flags & ARG_1_AND_2_ARE_WORDS != 0) {
                    dx = try parser.readI16(glyph_data, offset);
                    dy = try parser.readI16(glyph_data, offset + 2);
                    offset += 4;
                } else {
                    dx = @as(i16, try parser.readI8(glyph_data, offset));
                    dy = @as(i16, try parser.readI8(glyph_data, offset + 1));
                    offset += 2;
                }
            } else {
                // Point number args (skip for now, just read the bytes)
                if (flags & ARG_1_AND_2_ARE_WORDS != 0) {
                    offset += 4;
                } else {
                    offset += 2;
                }
            }

            // Read transform matrix (defaults to identity)
            var mat_a: f32 = 1.0;
            var mat_b: f32 = 0.0;
            var mat_c: f32 = 0.0;
            var mat_d: f32 = 1.0;
            const has_transform = (flags & (WE_HAVE_A_SCALE | WE_HAVE_AN_X_AND_Y_SCALE | WE_HAVE_A_TWO_BY_TWO)) != 0;

            if (flags & WE_HAVE_A_SCALE != 0) {
                mat_a = try parser.readF2Dot14(glyph_data, offset);
                mat_d = mat_a;
                offset += 2;
            } else if (flags & WE_HAVE_AN_X_AND_Y_SCALE != 0) {
                mat_a = try parser.readF2Dot14(glyph_data, offset);
                mat_d = try parser.readF2Dot14(glyph_data, offset + 2);
                offset += 4;
            } else if (flags & WE_HAVE_A_TWO_BY_TWO != 0) {
                mat_a = try parser.readF2Dot14(glyph_data, offset);
                mat_b = try parser.readF2Dot14(glyph_data, offset + 2);
                mat_c = try parser.readF2Dot14(glyph_data, offset + 4);
                mat_d = try parser.readF2Dot14(glyph_data, offset + 6);
                offset += 8;
            }

            // Recursively get component outline
            if (try self.getGlyphOutlineRecursive(allocator, component_glyph_id, loca, depth + 1)) |component_const| {
                var component = component_const;
                defer component.deinit();
                for (component.contours) |contour| {
                    const new_points = try allocator.alloc(glyph_mod.Point, contour.points.len);
                    for (contour.points, 0..) |pt, i| {
                        if (has_transform) {
                            const fx = @as(f32, @floatFromInt(pt.x));
                            const fy = @as(f32, @floatFromInt(pt.y));
                            new_points[i] = .{
                                .x = @as(i16, @intFromFloat(@round(mat_a * fx + mat_c * fy))) + dx,
                                .y = @as(i16, @intFromFloat(@round(mat_b * fx + mat_d * fy))) + dy,
                                .on_curve = pt.on_curve,
                            };
                        } else {
                            new_points[i] = .{
                                .x = pt.x + dx,
                                .y = pt.y + dy,
                                .on_curve = pt.on_curve,
                            };
                        }
                    }
                    try all_contours.append(allocator, .{ .points = new_points });
                }
            }
        }

        const contours = try all_contours.toOwnedSlice(allocator);
        return .{
            .contours = contours,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
            .allocator = allocator,
        };
    }
};

pub fn parse(data: []const u8) GlyfTable {
    return .{ .data = data };
}

// Error set for glyph operations
pub const GlyfError = error{
    CompoundGlyphTooDeep,
    InvalidGlyphId,
    InvalidGlyphData,
    InvalidLocaOffset,
    UnexpectedEof,
    OutOfMemory,
};

test "parse simple glyph 'A' from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const head_record = parser.findTable(offset_table, "head".*) orelse return error.TableNotFound;
    const head_data = try parser.getTableData(font_data, head_record);
    const head_mod = @import("head.zig");
    const head = try head_mod.parse(head_data);

    const maxp_record = parser.findTable(offset_table, "maxp".*) orelse return error.TableNotFound;
    const maxp_data = try parser.getTableData(font_data, maxp_record);
    const maxp_mod = @import("maxp.zig");
    const maxp = try maxp_mod.parse(maxp_data);

    const cmap_record = parser.findTable(offset_table, "cmap".*) orelse return error.TableNotFound;
    const cmap_data = try parser.getTableData(font_data, cmap_record);
    const cmap_mod = @import("cmap.zig");
    const cmap = try cmap_mod.parse(cmap_data);

    const loca_record = parser.findTable(offset_table, "loca".*) orelse return error.TableNotFound;
    const loca_data = try parser.getTableData(font_data, loca_record);
    const loca = loca_mod.parse(loca_data, head.index_to_loc_format, maxp.num_glyphs);

    const glyf_record = parser.findTable(offset_table, "glyf".*) orelse return error.TableNotFound;
    const glyf_data = try parser.getTableData(font_data, glyf_record);
    const glyf = parse(glyf_data);

    const glyph_id = try cmap.charToGlyphId(0x0041); // 'A'
    var outline = (try glyf.getGlyphOutline(std.testing.allocator, glyph_id, loca)) orelse return error.TableNotFound;
    defer outline.deinit();

    // 'A' in DejaVu Sans has 2 contours (outer and inner triangle for the counter)
    try std.testing.expect(outline.contours.len == 2);
    // Each contour should have some points
    try std.testing.expect(outline.contours[0].points.len > 0);
    try std.testing.expect(outline.contours[1].points.len > 0);
}

test "space glyph returns null" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const head_record = parser.findTable(offset_table, "head".*) orelse return error.TableNotFound;
    const head_data = try parser.getTableData(font_data, head_record);
    const head_mod = @import("head.zig");
    const head = try head_mod.parse(head_data);

    const maxp_record = parser.findTable(offset_table, "maxp".*) orelse return error.TableNotFound;
    const maxp_data = try parser.getTableData(font_data, maxp_record);
    const maxp_mod = @import("maxp.zig");
    const maxp = try maxp_mod.parse(maxp_data);

    const cmap_record = parser.findTable(offset_table, "cmap".*) orelse return error.TableNotFound;
    const cmap_data = try parser.getTableData(font_data, cmap_record);
    const cmap_mod = @import("cmap.zig");
    const cmap = try cmap_mod.parse(cmap_data);

    const loca_record = parser.findTable(offset_table, "loca".*) orelse return error.TableNotFound;
    const loca_data = try parser.getTableData(font_data, loca_record);
    const loca = loca_mod.parse(loca_data, head.index_to_loc_format, maxp.num_glyphs);

    const glyf_record = parser.findTable(offset_table, "glyf".*) orelse return error.TableNotFound;
    const glyf_data = try parser.getTableData(font_data, glyf_record);
    const glyf = parse(glyf_data);

    const glyph_id = try cmap.charToGlyphId(0x0020); // space
    const outline = try glyf.getGlyphOutline(std.testing.allocator, glyph_id, loca);
    try std.testing.expect(outline == null);
}
