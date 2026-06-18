const std = @import("std");
const cappan_core = @import("cappan_core");

const Font = cappan_core.font.Font;
const parser = cappan_core.font.parser;

pub const FeatureInfo = struct {
    table_tag: [4]u8,
    feature_tag: [4]u8,
    script_tag: [4]u8,
    language_tag: [4]u8,
};

/// Parse features from a GSUB or GPOS table's raw data.
/// Iterates ScriptList -> Script -> LangSys -> FeatureIndices, then looks up
/// each FeatureIndex in the FeatureList to get the feature tag.
fn parseFeaturesFromTable(
    allocator: std.mem.Allocator,
    table_data: []const u8,
    table_tag: [4]u8,
    out: *std.ArrayList(FeatureInfo),
) !void {
    // Header layout:
    //   0: u16 majorVersion
    //   2: u16 minorVersion
    //   4: u16 scriptListOffset
    //   6: u16 featureListOffset
    //   8: u16 lookupListOffset
    if (table_data.len < 10) return;

    const script_list_off = @as(usize, try parser.readU16(table_data, 4));
    const feature_list_off = @as(usize, try parser.readU16(table_data, 6));

    if (script_list_off == 0 or feature_list_off == 0) return;
    if (script_list_off >= table_data.len or feature_list_off >= table_data.len) return;

    const script_list = table_data[script_list_off..];
    const feature_list = table_data[feature_list_off..];

    // FeatureList:
    //   0: u16 featureCount
    //   Per feature (6 bytes):
    //     [4]u8 featureTag
    //     u16 featureOffset (from start of FeatureList, unused here)
    if (feature_list.len < 2) return;
    const feature_count = try parser.readU16(feature_list, 0);

    // ScriptList:
    //   0: u16 scriptCount
    //   Per script (6 bytes):
    //     [4]u8 scriptTag
    //     u16 scriptOffset (from start of ScriptList)
    if (script_list.len < 2) return;
    const script_count = try parser.readU16(script_list, 0);

    for (0..script_count) |si| {
        const script_entry_off: usize = 2 + si * 6;
        if (script_entry_off + 6 > script_list.len) break;

        const script_tag: [4]u8 = script_list[script_entry_off..][0..4].*;
        const script_off = @as(usize, try parser.readU16(script_list, script_entry_off + 4));

        const script_abs = script_list_off + script_off;
        if (script_abs >= table_data.len) continue;
        const script_table = table_data[script_abs..];

        // Script table:
        //   0: u16 defaultLangSysOffset (0 = none)
        //   2: u16 langSysCount
        //   Per langSys (6 bytes):
        //     [4]u8 langSysTag
        //     u16 langSysOffset (from start of Script table)
        if (script_table.len < 4) continue;
        const default_langsys_off = try parser.readU16(script_table, 0);
        const lang_sys_count = try parser.readU16(script_table, 2);

        // Collect (langSysTag, langSysOffset) pairs
        const LangSysEntry = struct { tag: [4]u8, off: usize };
        const max_entries = @as(usize, lang_sys_count) + 1;
        const entries = try allocator.alloc(LangSysEntry, max_entries);
        defer allocator.free(entries);
        var entry_count: usize = 0;

        if (default_langsys_off != 0) {
            entries[entry_count] = .{ .tag = "dflt".*, .off = @as(usize, default_langsys_off) };
            entry_count += 1;
        }

        for (0..lang_sys_count) |li| {
            const ls_entry_off: usize = 4 + li * 6;
            if (ls_entry_off + 6 > script_table.len) break;
            const ls_tag: [4]u8 = script_table[ls_entry_off..][0..4].*;
            const ls_off = @as(usize, try parser.readU16(script_table, ls_entry_off + 4));
            entries[entry_count] = .{ .tag = ls_tag, .off = ls_off };
            entry_count += 1;
        }

        for (entries[0..entry_count]) |entry| {
            const ls_abs = script_abs + entry.off;
            if (ls_abs >= table_data.len) continue;
            const ls_table = table_data[ls_abs..];

            // LangSys table:
            //   0: u16 lookupOrder (reserved = 0)
            //   2: u16 requiredFeatureIndex (0xFFFF = none)
            //   4: u16 featureIndexCount
            //   Per index: u16 featureIndex
            if (ls_table.len < 6) continue;
            const required_fi = try parser.readU16(ls_table, 2);
            const fi_count = try parser.readU16(ls_table, 4);

            const total_fi = @as(usize, fi_count) + (if (required_fi != 0xFFFF) @as(usize, 1) else @as(usize, 0));
            const fi_list = try allocator.alloc(u16, total_fi);
            defer allocator.free(fi_list);
            var fi_pos: usize = 0;

            if (required_fi != 0xFFFF) {
                fi_list[fi_pos] = required_fi;
                fi_pos += 1;
            }
            for (0..fi_count) |fii| {
                const fi_off: usize = 6 + fii * 2;
                if (fi_off + 2 > ls_table.len) break;
                fi_list[fi_pos] = try parser.readU16(ls_table, fi_off);
                fi_pos += 1;
            }

            for (fi_list[0..fi_pos]) |fi| {
                if (fi >= feature_count) continue;
                const feat_entry_off: usize = 2 + @as(usize, fi) * 6;
                if (feat_entry_off + 4 > feature_list.len) continue;
                const feat_tag: [4]u8 = feature_list[feat_entry_off..][0..4].*;

                try out.append(allocator, .{
                    .table_tag = table_tag,
                    .feature_tag = feat_tag,
                    .script_tag = script_tag,
                    .language_tag = entry.tag,
                });
            }
        }
    }
}

/// List all OpenType features from GSUB and GPOS tables.
pub fn listFeatures(allocator: std.mem.Allocator, font: Font) ![]FeatureInfo {
    var list: std.ArrayList(FeatureInfo) = .empty;
    errdefer list.deinit(allocator);

    // Try GSUB
    if (parser.findTable(font.offset_table, "GSUB".*)) |rec| {
        const data = try parser.getTableData(font.data, rec);
        try parseFeaturesFromTable(allocator, data, "GSUB".*, &list);
    }

    // Try GPOS
    if (parser.findTable(font.offset_table, "GPOS".*)) |rec| {
        const data = try parser.getTableData(font.data, rec);
        try parseFeaturesFromTable(allocator, data, "GPOS".*, &list);
    }

    return list.toOwnedSlice(allocator);
}

test "listFeatures finds kern in DejaVuSans GPOS" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const features = try listFeatures(std.testing.allocator, font);
    defer std.testing.allocator.free(features);

    var found_kern = false;
    for (features) |feat| {
        if (std.mem.eql(u8, &feat.feature_tag, "kern") and
            std.mem.eql(u8, &feat.table_tag, "GPOS"))
        {
            found_kern = true;
            break;
        }
    }
    try std.testing.expect(found_kern);
}
