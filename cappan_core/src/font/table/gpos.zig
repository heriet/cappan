const std = @import("std");
const parser = @import("../parser.zig");
const otlayout = @import("otlayout.zig");

pub const GposTable = struct {
    data: []const u8,
    kern_lookups: []const KernLookup,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GposTable) void {
        for (self.kern_lookups) |lookup| {
            lookup.deinit(self.allocator);
        }
        self.allocator.free(self.kern_lookups);
    }

    pub fn getKerning(self: GposTable, left: u16, right: u16) i16 {
        for (self.kern_lookups) |lookup| {
            const value = lookup.getKerning(self.data, left, right);
            if (value != 0) return value;
        }
        return 0;
    }
};

pub const KernLookup = struct {
    subtables: []const PairPosSubtable,

    pub fn deinit(self: KernLookup, allocator: std.mem.Allocator) void {
        allocator.free(self.subtables);
    }

    pub fn getKerning(self: KernLookup, data: []const u8, left: u16, right: u16) i16 {
        for (self.subtables) |sub| {
            const value = sub.getKerning(data, left, right);
            if (value != 0) return value;
        }
        return 0;
    }
};

pub const PairPosSubtable = struct {
    offset: usize,
    format: u16,

    pub fn getKerning(self: PairPosSubtable, data: []const u8, left: u16, right: u16) i16 {
        return switch (self.format) {
            1 => getKerningFormat1(data, self.offset, left, right),
            2 => getKerningFormat2(data, self.offset, left, right),
            else => 0,
        };
    }
};

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !GposTable {
    // GPOS Header:
    // +0: majorVersion u16
    // +2: minorVersion u16
    // +4: scriptListOffset u16
    // +6: featureListOffset u16
    // +8: lookupListOffset u16
    if (data.len < 10) return error.UnexpectedEof;

    const major_version = try parser.readU16(data, 0);
    if (major_version != 1) return error.InvalidVersion;

    const feature_list_offset = try parser.readU16(data, 6);
    const lookup_list_offset = try parser.readU16(data, 8);

    // Collect lookup indices referenced by kern features
    var kern_lookup_indices = std.ArrayListUnmanaged(u16).empty;
    defer kern_lookup_indices.deinit(allocator);

    const fl_base = @as(usize, feature_list_offset);
    if (fl_base + 2 <= data.len) {
        const feature_count = try parser.readU16(data, fl_base);
        // FeatureList records: each is [4]u8 tag + u16 featureOffset = 6 bytes
        var fi: usize = 0;
        while (fi < feature_count) : (fi += 1) {
            const rec_offset = fl_base + 2 + fi * 6;
            if (rec_offset + 6 > data.len) break;
            const tag = data[rec_offset .. rec_offset + 4];
            const feature_offset = try parser.readU16(data, rec_offset + 4);
            if (std.mem.eql(u8, tag, "kern")) {
                // Feature table: featureParams u16 + lookupCount u16 + lookupListIndices[]
                const feat_base = fl_base + @as(usize, feature_offset);
                if (feat_base + 4 > data.len) continue;
                // Skip featureParams at feat_base + 0
                const lookup_count = try parser.readU16(data, feat_base + 2);
                var li: usize = 0;
                while (li < lookup_count) : (li += 1) {
                    const idx_offset = feat_base + 4 + li * 2;
                    if (idx_offset + 2 > data.len) break;
                    const lookup_idx = try parser.readU16(data, idx_offset);
                    try kern_lookup_indices.append(allocator, lookup_idx);
                }
            }
        }
    }

    // Build kern lookups from collected indices
    var kern_lookups = std.ArrayListUnmanaged(KernLookup).empty;
    errdefer {
        for (kern_lookups.items) |lookup| {
            lookup.deinit(allocator);
        }
        kern_lookups.deinit(allocator);
    }

    const ll_base = @as(usize, lookup_list_offset);
    if (ll_base + 2 <= data.len) {
        const ll_lookup_count = try parser.readU16(data, ll_base);
        for (kern_lookup_indices.items) |lookup_idx| {
            if (lookup_idx >= ll_lookup_count) continue;
            const lo_offset_pos = ll_base + 2 + @as(usize, lookup_idx) * 2;
            if (lo_offset_pos + 2 > data.len) continue;
            const lo_offset = try parser.readU16(data, lo_offset_pos);
            const lo_base = ll_base + @as(usize, lo_offset);
            if (lo_base + 6 > data.len) continue;

            // Lookup:
            // +0: lookupType u16
            // +2: lookupFlag u16
            // +4: subTableCount u16
            // +6: subTableOffsets[subTableCount] u16 (relative to Lookup start)
            const lookup_type = try parser.readU16(data, lo_base);
            const subtable_count = try parser.readU16(data, lo_base + 4);

            // PairAdjustment = type 2
            if (lookup_type != 2) continue;

            var subtables = std.ArrayListUnmanaged(PairPosSubtable).empty;
            errdefer subtables.deinit(allocator);

            var si: usize = 0;
            while (si < subtable_count) : (si += 1) {
                const sub_offset_pos = lo_base + 6 + si * 2;
                if (sub_offset_pos + 2 > data.len) break;
                const sub_offset = try parser.readU16(data, sub_offset_pos);
                const sub_abs = lo_base + @as(usize, sub_offset);
                if (sub_abs + 2 > data.len) break;
                const pos_format = try parser.readU16(data, sub_abs);
                if (pos_format != 1 and pos_format != 2) continue;
                try subtables.append(allocator, .{
                    .offset = sub_abs,
                    .format = pos_format,
                });
            }

            try kern_lookups.append(allocator, .{
                .subtables = try subtables.toOwnedSlice(allocator),
            });
        }
    }

    return .{
        .data = data,
        .kern_lookups = try kern_lookups.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn getKerningFormat1(data: []const u8, subtable_offset: usize, left: u16, right: u16) i16 {
    // PairPos Format 1:
    // +0: posFormat u16 (1)
    // +2: coverageOffset u16 (subtable-relative)
    // +4: valueFormat1 u16
    // +6: valueFormat2 u16
    // +8: pairSetCount u16
    // +10: pairSetOffsets[pairSetCount] u16 (subtable-relative)

    const coverage_offset = parser.readU16(data, subtable_offset + 2) catch return 0;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, coverage_offset)) catch return 0;
    const coverage_index = coverage.getCoverageIndex(left) orelse return 0;

    const value_format1 = parser.readU16(data, subtable_offset + 4) catch return 0;
    const value_format2 = parser.readU16(data, subtable_offset + 6) catch return 0;
    const pair_set_count = parser.readU16(data, subtable_offset + 8) catch return 0;

    if (coverage_index >= pair_set_count) return 0;

    const ps_offset_pos = subtable_offset + 10 + @as(usize, coverage_index) * 2;
    const ps_offset = parser.readU16(data, ps_offset_pos) catch return 0;
    const ps_base = subtable_offset + @as(usize, ps_offset);

    // PairSet:
    // +0: pairValueCount u16
    // +2: pairValueRecords[]
    //   each: secondGlyph u16 + valueRecord1 + valueRecord2
    const pair_value_count = parser.readU16(data, ps_base) catch return 0;

    const vr1_size = otlayout.valueRecordSize(value_format1);
    const vr2_size = otlayout.valueRecordSize(value_format2);
    const record_size = 2 + vr1_size + vr2_size;

    if (record_size == 2) return 0; // no value data

    // Binary search on secondGlyph
    var lo: usize = 0;
    var hi: usize = pair_value_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const rec_pos = ps_base + 2 + mid * record_size;
        const second_glyph = parser.readU16(data, rec_pos) catch return 0;
        if (second_glyph == right) {
            if (value_format1 == 0) return 0;
            const vr = otlayout.readValueRecord(data, rec_pos + 2, value_format1) catch return 0;
            return vr.x_advance;
        } else if (second_glyph < right) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    return 0;
}

fn getKerningFormat2(data: []const u8, subtable_offset: usize, left: u16, right: u16) i16 {
    // PairPos Format 2:
    // +0:  posFormat u16 (2)
    // +2:  coverageOffset u16 (subtable-relative)
    // +4:  valueFormat1 u16
    // +6:  valueFormat2 u16
    // +8:  classDef1Offset u16 (subtable-relative)
    // +10: classDef2Offset u16 (subtable-relative)
    // +12: class1Count u16
    // +14: class2Count u16
    // +16: class1Records[class1Count * class2Count] (valueRecord1 + valueRecord2 each)

    const coverage_offset = parser.readU16(data, subtable_offset + 2) catch return 0;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, coverage_offset)) catch return 0;
    if (coverage.getCoverageIndex(left) == null) return 0;

    const value_format1 = parser.readU16(data, subtable_offset + 4) catch return 0;
    const value_format2 = parser.readU16(data, subtable_offset + 6) catch return 0;
    const class_def1_offset = parser.readU16(data, subtable_offset + 8) catch return 0;
    const class_def2_offset = parser.readU16(data, subtable_offset + 10) catch return 0;
    const class1_count = parser.readU16(data, subtable_offset + 12) catch return 0;
    const class2_count = parser.readU16(data, subtable_offset + 14) catch return 0;

    const class_def1 = otlayout.parseClassDef(data, subtable_offset + @as(usize, class_def1_offset)) catch return 0;
    const class_def2 = otlayout.parseClassDef(data, subtable_offset + @as(usize, class_def2_offset)) catch return 0;

    const class1 = class_def1.getClass(left);
    const class2 = class_def2.getClass(right);

    if (class1 >= class1_count or class2 >= class2_count) return 0;

    const vr1_size = otlayout.valueRecordSize(value_format1);
    const vr2_size = otlayout.valueRecordSize(value_format2);
    const record_size = vr1_size + vr2_size;

    if (record_size == 0) return 0;

    const header_size: usize = 16;
    const record_idx = @as(usize, class1) * @as(usize, class2_count) + @as(usize, class2);
    const rec_offset = subtable_offset + header_size + record_idx * record_size;
    if (rec_offset + record_size > data.len) return 0;

    if (value_format1 == 0) return 0;
    const vr = otlayout.readValueRecord(data, rec_offset, value_format1) catch return 0;
    return vr.x_advance;
}

test "parse GPOS table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const gpos_record = p.findTable(offset_table, "GPOS".*) orelse return;
    const gpos_data = try p.getTableData(font_data, gpos_record);
    var gpos = try parse(std.testing.allocator, gpos_data);
    defer gpos.deinit();

    try std.testing.expect(gpos.kern_lookups.len > 0);
    try std.testing.expectEqual(@as(i16, 0), gpos.getKerning(0, 0));
}

test "GPOS getKerning with Font API" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const font_mod = @import("../font.zig");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_A = try font.getGlyphId('A');
    const glyph_V = try font.getGlyphId('V');

    const kern_val = font.getKerning(glyph_A, glyph_V);
    try std.testing.expect(kern_val != 0);
}
