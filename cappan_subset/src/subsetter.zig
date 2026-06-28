const std = @import("std");
const cappan_core = @import("cappan_core");
const writer = @import("writer.zig");
const table_glyf = @import("table/glyf.zig");
const table_loca = @import("table/loca.zig");
const table_cmap = @import("table/cmap.zig");
const table_hmtx = @import("table/hmtx.zig");
const table_head = @import("table/head.zig");
const table_maxp = @import("table/maxp.zig");
const table_hhea = @import("table/hhea.zig");
const table_post = @import("table/post.zig");

pub const SubsetOptions = struct {
    keep_name_table: bool = true,
};

pub const SubsetError = error{
    CffNotSupported,
    NoLocaTable,
    NoGlyfTable,
};

pub fn subsetFont(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
    options: SubsetOptions,
) ![]u8 {
    if (font.offset_table.sfnt_version == 0x4F54544F) return error.CffNotSupported;
    if (font.loca == null) return error.NoLocaTable;
    if (font.glyf == null) return error.NoGlyfTable;

    const used_glyphs = try collectGlyphs(allocator, font, codepoints);
    defer allocator.free(used_glyphs);

    const mapping = try buildGlyphMapping(allocator, used_glyphs, font.maxp.num_glyphs);
    defer allocator.free(mapping);

    const new_num_glyphs: u16 = @intCast(used_glyphs.len);

    return try assembleSfnt(allocator, font, codepoints, used_glyphs, mapping, new_num_glyphs, options);
}

fn collectGlyphs(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
) ![]u16 {
    const loca = font.loca orelse return error.NoLocaTable;
    const glyf_record = cappan_core.font.parser.findTable(font.offset_table, "glyf".*) orelse return error.NoGlyfTable;
    const glyf_data = try cappan_core.font.parser.getTableData(font.data, glyf_record);

    var set = std.ArrayList(u16).empty;
    defer set.deinit(allocator);

    try set.append(allocator, 0);

    for (codepoints) |cp| {
        const glyph_id = font.getGlyphId(@intCast(cp)) catch continue;
        if (glyph_id == 0) continue;
        try set.append(allocator, glyph_id);
        try collectCompoundComponents(allocator, &set, glyph_id, glyf_data, loca);
    }

    std.sort.block(u16, set.items, {}, std.sort.asc(u16));
    var deduped = std.ArrayList(u16).empty;
    defer deduped.deinit(allocator);
    var prev: ?u16 = null;
    for (set.items) |id| {
        if (prev == null or id != prev.?) {
            try deduped.append(allocator, id);
            prev = id;
        }
    }

    return try deduped.toOwnedSlice(allocator);
}

fn collectCompoundComponents(
    allocator: std.mem.Allocator,
    set: *std.ArrayList(u16),
    glyph_id: u16,
    glyf_data: []const u8,
    loca: cappan_core.font.table.loca.LocaTable,
) !void {
    const loc = loca.getGlyphLocation(glyph_id) catch return;
    if (loc.length == 0) return;

    const glyph_offset: usize = @intCast(loc.offset);
    const glyph_len: usize = @intCast(loc.length);
    const glyph_bytes = glyf_data[glyph_offset .. glyph_offset + glyph_len];
    const num_contours = cappan_core.font.parser.readI16(glyph_bytes, 0) catch return;
    if (num_contours >= 0) return;

    var offset: usize = 10;
    var flags: u16 = table_glyf.MORE_COMPONENTS;
    while (flags & table_glyf.MORE_COMPONENTS != 0) {
        if (offset + 4 > glyph_bytes.len) break;
        flags = cappan_core.font.parser.readU16(glyph_bytes, offset) catch break;
        offset += 2;
        const component_id = cappan_core.font.parser.readU16(glyph_bytes, offset) catch break;
        offset += 2;

        try set.append(allocator, component_id);

        if (flags & table_glyf.ARG_1_AND_2_ARE_WORDS != 0) {
            offset += 4;
        } else {
            offset += 2;
        }
        if (flags & table_glyf.WE_HAVE_A_SCALE != 0) {
            offset += 2;
        } else if (flags & table_glyf.WE_HAVE_AN_X_AND_Y_SCALE != 0) {
            offset += 4;
        } else if (flags & table_glyf.WE_HAVE_A_TWO_BY_TWO != 0) {
            offset += 8;
        }
    }
}

fn buildGlyphMapping(
    allocator: std.mem.Allocator,
    used_glyphs: []const u16,
    old_num_glyphs: u16,
) ![]u16 {
    const mapping = try allocator.alloc(u16, old_num_glyphs);
    @memset(mapping, 0);
    for (used_glyphs, 0..) |old_id, new_id| {
        mapping[old_id] = @intCast(new_id);
    }
    return mapping;
}

const TableEntry = struct {
    tag: [4]u8,
    data: []const u8,
};

fn assembleSfnt(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
    used_glyphs: []const u16,
    mapping: []const u16,
    new_num_glyphs: u16,
    options: SubsetOptions,
) ![]u8 {
    const loca = font.loca orelse return error.NoLocaTable;
    const glyf_record = cappan_core.font.parser.findTable(font.offset_table, "glyf".*) orelse return error.NoGlyfTable;
    const glyf_data_raw = try cappan_core.font.parser.getTableData(font.data, glyf_record);

    const glyf_result = try table_glyf.subsetGlyf(allocator, glyf_data_raw, loca, used_glyphs, mapping);
    defer glyf_result.deinit(allocator);

    var use_short_loca = true;
    for (glyf_result.offsets) |off| {
        if (off > 0x1FFFE) {
            use_short_loca = false;
            break;
        }
    }
    const index_to_loc_format: i16 = if (use_short_loca) 0 else 1;

    const loca_data = try table_loca.buildLoca(allocator, glyf_result.offsets, use_short_loca);
    defer allocator.free(loca_data);

    const cmap_data = try table_cmap.buildCmap(allocator, codepoints, mapping, font);
    defer allocator.free(cmap_data);

    const hmtx_data = try table_hmtx.subsetHmtx(allocator, font, used_glyphs);
    defer allocator.free(hmtx_data);

    const head_data = try table_head.buildHead(allocator, font, index_to_loc_format);
    defer allocator.free(head_data);

    const maxp_data = try table_maxp.buildMaxp(allocator, font, new_num_glyphs);
    defer allocator.free(maxp_data);

    const hhea_data = try table_hhea.buildHhea(allocator, font, new_num_glyphs);
    defer allocator.free(hhea_data);

    const post_data = try table_post.buildPost(allocator);
    defer allocator.free(post_data);

    var entries = std.ArrayList(TableEntry).empty;
    defer entries.deinit(allocator);

    try entries.append(allocator, .{ .tag = "cmap".*, .data = cmap_data });
    try entries.append(allocator, .{ .tag = "glyf".*, .data = glyf_result.data });
    try entries.append(allocator, .{ .tag = "head".*, .data = head_data });
    try entries.append(allocator, .{ .tag = "hhea".*, .data = hhea_data });
    try entries.append(allocator, .{ .tag = "hmtx".*, .data = hmtx_data });
    try entries.append(allocator, .{ .tag = "loca".*, .data = loca_data });
    try entries.append(allocator, .{ .tag = "maxp".*, .data = maxp_data });
    try entries.append(allocator, .{ .tag = "post".*, .data = post_data });

    var name_data_copy: ?[]u8 = null;
    if (options.keep_name_table) {
        if (cappan_core.font.parser.findTable(font.offset_table, "name".*)) |name_record| {
            const name_raw = try cappan_core.font.parser.getTableData(font.data, name_record);
            name_data_copy = try allocator.dupe(u8, name_raw);
            try entries.append(allocator, .{ .tag = "name".*, .data = name_data_copy.? });
        }
    }
    defer if (name_data_copy) |nd| allocator.free(nd);

    const num_tables: u16 = @intCast(entries.items.len);

    var search_range: u16 = 1;
    var entry_selector: u16 = 0;
    while (search_range * 2 <= num_tables) {
        search_range *= 2;
        entry_selector += 1;
    }
    search_range *= 16;
    const range_shift: u16 = num_tables * 16 - search_range;

    const header_size: usize = 12 + @as(usize, num_tables) * 16;
    var tables_size: usize = 0;
    for (entries.items) |e| {
        tables_size += (e.data.len + 3) & ~@as(usize, 3);
    }
    const total_size = header_size + tables_size;

    const out = try allocator.alloc(u8, total_size);
    errdefer allocator.free(out);
    @memset(out, 0);

    var pos: usize = 0;
    writer.writeU32BE(out, pos, 0x00010000); pos += 4;
    writer.writeU16BE(out, pos, num_tables); pos += 2;
    writer.writeU16BE(out, pos, search_range); pos += 2;
    writer.writeU16BE(out, pos, entry_selector); pos += 2;
    writer.writeU16BE(out, pos, range_shift); pos += 2;

    var data_offset: u32 = @intCast(header_size);
    var head_checksum_offset: usize = 0;

    for (entries.items) |e| {
        const checksum = writer.calcChecksum(e.data);
        out[pos] = e.tag[0];
        out[pos+1] = e.tag[1];
        out[pos+2] = e.tag[2];
        out[pos+3] = e.tag[3];
        pos += 4;
        writer.writeU32BE(out, pos, checksum); pos += 4;
        writer.writeU32BE(out, pos, data_offset); pos += 4;
        writer.writeU32BE(out, pos, @intCast(e.data.len)); pos += 4;

        if (std.mem.eql(u8, &e.tag, "head")) {
            head_checksum_offset = @intCast(data_offset + 8);
        }

        const aligned: usize = (e.data.len + 3) & ~@as(usize, 3);
        data_offset += @intCast(aligned);
    }

    for (entries.items) |e| {
        @memcpy(out[pos .. pos + e.data.len], e.data);
        const aligned: usize = (e.data.len + 3) & ~@as(usize, 3);
        pos += aligned;
    }

    writer.writeU32BE(out, head_checksum_offset, 0);
    const file_checksum = writer.calcChecksum(out);
    const adjustment: u32 = 0xB1B0AFBA -% file_checksum;
    writer.writeU32BE(out, head_checksum_offset, adjustment);

    return out;
}

test "subset font and re-parse" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const codepoints = [_]u21{ 'H', 'e', 'l', 'o' };
    const subset_data = try subsetFont(std.testing.allocator, font, &codepoints, .{});
    defer std.testing.allocator.free(subset_data);

    var subset_font = try cappan_core.font.Font.init(std.testing.allocator, subset_data, null);
    defer subset_font.deinit();

    const h_id = try subset_font.getGlyphId('H');
    try std.testing.expect(h_id != 0);

    const z_id = try subset_font.getGlyphId('Z');
    try std.testing.expectEqual(@as(u16, 0), z_id);
}
