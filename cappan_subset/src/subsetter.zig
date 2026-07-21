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

/// Collects every glyph the subset needs: .notdef (id 0) and each
/// codepoint's mapped glyph, then expands to the full transitive component
/// closure via `collectTransitiveGlyphs`.
fn collectGlyphs(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
) ![]u16 {
    const loca = font.loca orelse return error.NoLocaTable;
    const glyf_record = cappan_core.font.parser.findTable(font.offset_table, "glyf".*) orelse return error.NoGlyfTable;
    const glyf_data = try cappan_core.font.parser.getTableData(font.data, glyf_record);

    var seeds: std.ArrayList(u16) = .empty;
    defer seeds.deinit(allocator);
    try seeds.append(allocator, 0); // .notdef

    for (codepoints) |cp| {
        const glyph_id = font.getGlyphId(@intCast(cp)) catch continue;
        if (glyph_id == 0) continue;
        if (glyph_id >= font.maxp.num_glyphs) continue;
        try seeds.append(allocator, glyph_id);
    }

    return collectTransitiveGlyphs(allocator, glyf_data, loca, seeds.items);
}

/// Expands `seed_glyphs` to the full set of glyphs reachable through
/// compound-glyph component references, via a worklist -- not a single-level
/// walk. A single-level walk (this logic's previous shape, before this
/// function existed) only collects a compound's *direct* components: if one
/// of those is itself compound, its own components (the subset's
/// "grandchildren") never get added, so any reference to them in the glyf
/// data this subset keeps ends up remapped to 0 (.notdef) by
/// `buildGlyphMapping`'s `@memset(mapping, 0)` default for anything not in
/// the result. The worklist generalizes to any nesting depth: each glyph
/// popped off it is walked with the same `ComponentIterator` core's
/// `getComponentInfos` uses, and every not-yet-seen component both gets
/// added to the result *and* pushed onto the worklist to have its own
/// components discovered in turn.
///
/// Split out from `collectGlyphs` specifically so the nesting behavior is
/// unit-testable against synthetic glyf/loca bytes without needing a full
/// parsed `Font` (cmap/head/hhea/maxp/hmtx all consistently populated) --
/// see the "nested compound" test below.
fn collectTransitiveGlyphs(
    allocator: std.mem.Allocator,
    glyf_data: []const u8,
    loca: cappan_core.font.table.loca.LocaTable,
    seed_glyphs: []const u16,
) ![]u16 {
    // `seen` both dedups (a glyph referenced from multiple places is only
    // queued/emitted once) and guards against an unbounded worklist from a
    // malformed/circular compound reference (component -> ancestor).
    var seen = std.AutoHashMap(u16, void).init(allocator);
    defer seen.deinit();

    var worklist: std.ArrayList(u16) = .empty;
    defer worklist.deinit(allocator);

    var used: std.ArrayList(u16) = .empty;
    errdefer used.deinit(allocator);

    const addGlyph = struct {
        fn call(seen_set: *std.AutoHashMap(u16, void), wl: *std.ArrayList(u16), out: *std.ArrayList(u16), alloc: std.mem.Allocator, id: u16) !void {
            if (seen_set.contains(id)) return;
            try seen_set.put(id, {});
            try out.append(alloc, id);
            try wl.append(alloc, id);
        }
    }.call;

    for (seed_glyphs) |id| {
        try addGlyph(&seen, &worklist, &used, allocator, id);
    }

    var i: usize = 0;
    while (i < worklist.items.len) : (i += 1) {
        const glyph_id = worklist.items[i];
        const loc = loca.getGlyphLocation(glyph_id) catch continue;
        if (loc.length == 0) continue;

        const glyph_offset: usize = @intCast(loc.offset);
        const glyph_len: usize = @intCast(loc.length);
        const glyph_end = std.math.add(usize, glyph_offset, glyph_len) catch continue;
        if (glyph_end > glyf_data.len) continue;
        const glyph_bytes = glyf_data[glyph_offset..glyph_end];
        const num_contours = cappan_core.font.parser.readI16(glyph_bytes, 0) catch continue;
        if (num_contours >= 0) continue; // simple glyph, no components

        var it = cappan_core.font.table.glyf.GlyfTable.ComponentIterator.init(glyph_bytes);
        while (it.next() catch null) |item| {
            if (item.glyph_id < loca.num_glyphs) {
                try addGlyph(&seen, &worklist, &used, allocator, item.glyph_id);
            }
        }
    }

    const owned = try used.toOwnedSlice(allocator);
    std.sort.block(u16, owned, {}, std.sort.asc(u16));
    return owned;
}

fn buildGlyphMapping(
    allocator: std.mem.Allocator,
    used_glyphs: []const u16,
    old_num_glyphs: u16,
) ![]u16 {
    const mapping = try allocator.alloc(u16, old_num_glyphs);
    @memset(mapping, 0);
    for (used_glyphs, 0..) |old_id, new_id| {
        if (old_id < mapping.len) mapping[old_id] = @intCast(new_id);
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
    writer.writeU32BE(out, pos, 0x00010000);
    pos += 4;
    writer.writeU16BE(out, pos, num_tables);
    pos += 2;
    writer.writeU16BE(out, pos, search_range);
    pos += 2;
    writer.writeU16BE(out, pos, entry_selector);
    pos += 2;
    writer.writeU16BE(out, pos, range_shift);
    pos += 2;

    var data_offset: u32 = @intCast(header_size);
    var head_checksum_offset: usize = 0;

    for (entries.items) |e| {
        const checksum = writer.calcChecksum(e.data);
        out[pos] = e.tag[0];
        out[pos + 1] = e.tag[1];
        out[pos + 2] = e.tag[2];
        out[pos + 3] = e.tag[3];
        pos += 4;
        writer.writeU32BE(out, pos, checksum);
        pos += 4;
        writer.writeU32BE(out, pos, data_offset);
        pos += 4;
        writer.writeU32BE(out, pos, @intCast(e.data.len));
        pos += 4;

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

// Regression test for the nested-compound gap: `collectGlyphs`'s previous
// single-level walk only collected a compound's *direct* components, so a
// compound-of-a-compound's own components (this subset's "grandchildren")
// were silently dropped and would have remapped to 0 (.notdef) in the
// written-out glyf data. Synthetic 2-level chain: glyph 1 (A) is compound,
// referencing glyph 2 (B); glyph 2 (B) is itself compound, referencing
// glyph 3 (C, a simple glyph with 0 contours). Seeding with just {1} must
// still surface {1, 2, 3} -- 3 is the two-hop-away grandchild the bug lost.
test "collectTransitiveGlyphs follows a 2-level nested compound (A -> B -> C)" {
    const allocator = std.testing.allocator;

    // glyph 1 (A): compound, one component -> glyph 2, no further components.
    const glyph_a = [_]u8{
        0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // header: numberOfContours=-1
        0x00, 0x03, // flags = ARGS_ARE_XY_VALUES | ARG_1_AND_2_ARE_WORDS (no MORE_COMPONENTS)
        0x00, 0x02, // glyphIndex = 2
        0x00, 0x00, 0x00, 0x00, // dx=0, dy=0 (words)
    };
    // glyph 2 (B): compound, one component -> glyph 3, no further components.
    const glyph_b = [_]u8{
        0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03,
        0x00, 0x03, // glyphIndex = 3
        0x00, 0x00,
        0x00, 0x00,
    };
    // glyph 3 (C): simple glyph, 0 contours -- no components to walk further.
    const glyph_c = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // numberOfContours=0
    };

    var glyf_data: [glyph_a.len + glyph_b.len + glyph_c.len]u8 = undefined;
    @memcpy(glyf_data[0..glyph_a.len], &glyph_a);
    @memcpy(glyf_data[glyph_a.len .. glyph_a.len + glyph_b.len], &glyph_b);
    @memcpy(glyf_data[glyph_a.len + glyph_b.len ..], &glyph_c);

    // Long-format loca (index_to_loc_format=1, u32 offsets), 4 glyphs (0..3),
    // so 5 entries. Glyph 0 (.notdef) is zero-length/unused by this test.
    const off_a: u32 = 0;
    const off_b: u32 = glyph_a.len;
    const off_c: u32 = glyph_a.len + glyph_b.len;
    const off_end: u32 = glyf_data.len;
    var loca_data: [5 * 4]u8 = undefined;
    std.mem.writeInt(u32, loca_data[0..4], 0, .big); // glyph 0 start
    std.mem.writeInt(u32, loca_data[4..8], off_a, .big); // glyph 0 end / glyph 1 start
    std.mem.writeInt(u32, loca_data[8..12], off_b, .big); // glyph 1 end / glyph 2 start
    std.mem.writeInt(u32, loca_data[12..16], off_c, .big); // glyph 2 end / glyph 3 start
    std.mem.writeInt(u32, loca_data[16..20], off_end, .big); // glyph 3 end

    const loca = cappan_core.font.table.loca.parse(&loca_data, 1, 4);

    const result = try collectTransitiveGlyphs(allocator, &glyf_data, loca, &[_]u16{1});
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u16, &[_]u16{ 1, 2, 3 }, result);
}
