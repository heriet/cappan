const std = @import("std");
const parser = @import("../parser.zig");
const otlayout = @import("otlayout.zig");

pub const GposTable = struct {
    data: []const u8,
    kern_lookups: []const KernLookup,
    mark_base_lookups: []const GposLookupRef,
    mark_lig_lookups: []const GposLookupRef,
    mark_mark_lookups: []const GposLookupRef,
    cursive_lookups: []const GposLookupRef,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GposTable) void {
        for (self.kern_lookups) |lookup| lookup.deinit(self.allocator);
        self.allocator.free(self.kern_lookups);
        freeGposLookups(self.allocator, self.mark_base_lookups);
        freeGposLookups(self.allocator, self.mark_lig_lookups);
        freeGposLookups(self.allocator, self.mark_mark_lookups);
        freeGposLookups(self.allocator, self.cursive_lookups);
    }

    pub fn getKerning(self: GposTable, left: u16, right: u16) i16 {
        for (self.kern_lookups) |lookup| {
            const value = lookup.getKerning(self.data, left, right);
            if (value != 0) return value;
        }
        return 0;
    }

    pub fn getMarkBaseAnchors(self: GposTable, base_glyph: u16, mark_glyph: u16) ?AnchorPair {
        return queryAcrossLookups(self.mark_base_lookups, self.data, base_glyph, mark_glyph);
    }

    pub fn getMarkMarkAnchors(self: GposTable, mark1_glyph: u16, mark2_glyph: u16) ?AnchorPair {
        return queryAcrossLookups(self.mark_mark_lookups, self.data, mark1_glyph, mark2_glyph);
    }

    pub fn getMarkLigAnchors(self: GposTable, lig_glyph: u16, mark_glyph: u16, component_index: u16) ?AnchorPair {
        for (self.mark_lig_lookups) |lookup| {
            for (lookup.subtables) |sub| {
                if (queryMarkLig(self.data, sub.offset, lig_glyph, mark_glyph, component_index)) |pair| return pair;
            }
        }
        return null;
    }

    pub fn getCursiveAnchors(self: GposTable, glyph: u16) ?CursiveAnchors {
        for (self.cursive_lookups) |lookup| {
            for (lookup.subtables) |sub| {
                if (queryCursive(self.data, sub.offset, glyph)) |anchors| return anchors;
            }
        }
        return null;
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

pub const AnchorPair = struct {
    base_x: i16,
    base_y: i16,
    mark_x: i16,
    mark_y: i16,
};

pub const SubtableRef = struct {
    offset: usize,
};

pub const GposLookupRef = struct {
    subtables: []const SubtableRef,

    pub fn deinit(self: GposLookupRef, allocator: std.mem.Allocator) void {
        allocator.free(self.subtables);
    }
};

pub const CursiveAnchors = struct {
    entry: ?otlayout.Anchor,
    exit: ?otlayout.Anchor,
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

    // Collect lookup indices referenced by each feature type
    var kern_lookup_indices = std.ArrayListUnmanaged(u16).empty;
    var mark_lookup_indices = std.ArrayListUnmanaged(u16).empty;
    var mkmk_lookup_indices = std.ArrayListUnmanaged(u16).empty;
    var curs_lookup_indices = std.ArrayListUnmanaged(u16).empty;
    defer kern_lookup_indices.deinit(allocator);
    defer mark_lookup_indices.deinit(allocator);
    defer mkmk_lookup_indices.deinit(allocator);
    defer curs_lookup_indices.deinit(allocator);

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

            var target_list: ?*std.ArrayListUnmanaged(u16) = null;
            if (std.mem.eql(u8, tag, "kern")) {
                target_list = &kern_lookup_indices;
            } else if (std.mem.eql(u8, tag, "mark")) {
                target_list = &mark_lookup_indices;
            } else if (std.mem.eql(u8, tag, "mkmk")) {
                target_list = &mkmk_lookup_indices;
            } else if (std.mem.eql(u8, tag, "curs")) {
                target_list = &curs_lookup_indices;
            }

            if (target_list) |list| {
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
                    try list.append(allocator, lookup_idx);
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

    for (kern_lookup_indices.items) |lookup_idx| {
        const info = otlayout.getLookupInfo(data, lookup_list_offset, lookup_idx) orelse continue;

        var subtables = std.ArrayListUnmanaged(PairPosSubtable).empty;
        errdefer subtables.deinit(allocator);

        var si: usize = 0;
        while (si < info.subtable_count) : (si += 1) {
            var sub_abs = otlayout.getSubtableOffset(data, info.base_offset, si) orelse break;
            var effective_type = info.lookup_type;

            // Handle Extension lookup (Type 9)
            if (effective_type == 9) {
                const ext = otlayout.parseExtensionSubtable(data, sub_abs) orelse continue;
                effective_type = ext.effective_type;
                sub_abs = ext.effective_offset;
            }

            if (effective_type != 2) continue; // PairAdjustment only

            if (sub_abs + 2 > data.len) break;
            const pos_format = parser.readU16(data, sub_abs) catch break;
            if (pos_format != 1 and pos_format != 2) continue;
            try subtables.append(allocator, .{
                .offset = sub_abs,
                .format = pos_format,
            });
        }

        const owned = try subtables.toOwnedSlice(allocator);
        errdefer allocator.free(owned);
        try kern_lookups.append(allocator, .{ .subtables = owned });
    }

    const mark_base_lookups = try collectLookupRefs(allocator, data, lookup_list_offset, mark_lookup_indices.items, 4);
    errdefer freeGposLookups(allocator, mark_base_lookups);

    const mark_lig_lookups = try collectLookupRefs(allocator, data, lookup_list_offset, mark_lookup_indices.items, 5);
    errdefer freeGposLookups(allocator, mark_lig_lookups);

    const mark_mark_lookups = try collectLookupRefs(allocator, data, lookup_list_offset, mkmk_lookup_indices.items, 6);
    errdefer freeGposLookups(allocator, mark_mark_lookups);

    const cursive_lookups = try collectLookupRefs(allocator, data, lookup_list_offset, curs_lookup_indices.items, 3);
    errdefer freeGposLookups(allocator, cursive_lookups);

    return .{
        .data = data,
        .kern_lookups = try kern_lookups.toOwnedSlice(allocator),
        .mark_base_lookups = mark_base_lookups,
        .mark_lig_lookups = mark_lig_lookups,
        .mark_mark_lookups = mark_mark_lookups,
        .cursive_lookups = cursive_lookups,
        .allocator = allocator,
    };
}

const max_lookups_per_feature = 256;
const max_subtables_per_lookup = 64;

fn collectLookupRefs(
    allocator: std.mem.Allocator,
    data: []const u8,
    lookup_list_offset: u16,
    lookup_indices: []const u16,
    target_type: u16,
) ![]const GposLookupRef {
    var list = std.ArrayListUnmanaged(GposLookupRef).empty;
    errdefer {
        for (list.items) |lookup| lookup.deinit(allocator);
        list.deinit(allocator);
    }

    const capped_indices = lookup_indices[0..@min(lookup_indices.len, max_lookups_per_feature)];
    for (capped_indices) |lookup_idx| {
        const info = otlayout.getLookupInfo(data, lookup_list_offset, lookup_idx) orelse continue;
        const capped_subtable_count = @min(info.subtable_count, max_subtables_per_lookup);

        var subtables = std.ArrayListUnmanaged(SubtableRef).empty;
        errdefer subtables.deinit(allocator);

        var si: usize = 0;
        while (si < capped_subtable_count) : (si += 1) {
            var sub_offset = otlayout.getSubtableOffset(data, info.base_offset, si) orelse break;
            var effective_type = info.lookup_type;

            if (effective_type == 9) {
                const ext = otlayout.parseExtensionSubtable(data, sub_offset) orelse continue;
                effective_type = ext.effective_type;
                sub_offset = ext.effective_offset;
            }

            if (effective_type == target_type) {
                try subtables.append(allocator, .{ .offset = sub_offset });
            }
        }

        if (subtables.items.len > 0) {
            const owned = try subtables.toOwnedSlice(allocator);
            errdefer allocator.free(owned);
            try list.append(allocator, .{ .subtables = owned });
        } else {
            subtables.deinit(allocator);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn freeGposLookups(allocator: std.mem.Allocator, lookups: []const GposLookupRef) void {
    for (lookups) |lookup| lookup.deinit(allocator);
    allocator.free(lookups);
}

fn queryAcrossLookups(lookups: []const GposLookupRef, data: []const u8, glyph1: u16, glyph2: u16) ?AnchorPair {
    for (lookups) |lookup| {
        for (lookup.subtables) |sub| {
            if (queryMarkBase(data, sub.offset, glyph1, glyph2)) |pair| return pair;
        }
    }
    return null;
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

fn queryMarkBase(data: []const u8, subtable_offset: usize, base_glyph: u16, mark_glyph: u16) ?AnchorPair {
    // MarkBasePos / MarkMarkPos Format 1:
    // +0: posFormat (u16) = 1
    // +2: markCoverageOffset (u16) — subtable-relative
    // +4: baseCoverageOffset (u16) — subtable-relative
    // +6: markClassCount (u16)
    // +8: markArrayOffset (u16) — subtable-relative
    // +10: baseArrayOffset (u16) — subtable-relative

    if (subtable_offset + 12 > data.len) return null;
    const pos_format = parser.readU16(data, subtable_offset) catch return null;
    if (pos_format != 1) return null;

    const mark_cov_offset = parser.readU16(data, subtable_offset + 2) catch return null;
    const base_cov_offset = parser.readU16(data, subtable_offset + 4) catch return null;
    const mark_class_count = parser.readU16(data, subtable_offset + 6) catch return null;
    const mark_array_offset = parser.readU16(data, subtable_offset + 8) catch return null;
    const base_array_offset = parser.readU16(data, subtable_offset + 10) catch return null;

    // Check coverages
    const mark_coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, mark_cov_offset)) catch return null;
    const mark_cov_index = mark_coverage.getCoverageIndex(mark_glyph) orelse return null;

    const base_coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, base_cov_offset)) catch return null;
    const base_cov_index = base_coverage.getCoverageIndex(base_glyph) orelse return null;

    // Read MarkArray
    const mark_array_base = subtable_offset + @as(usize, mark_array_offset);
    if (mark_array_base + 2 > data.len) return null;
    const mark_count = parser.readU16(data, mark_array_base) catch return null;
    if (mark_cov_index >= mark_count) return null;

    // MarkRecord: markClass (u16) + markAnchorOffset (u16) = 4 bytes each
    const mark_rec_offset = mark_array_base + 2 + @as(usize, mark_cov_index) * 4;
    if (mark_rec_offset + 4 > data.len) return null;
    const mark_class = parser.readU16(data, mark_rec_offset) catch return null;
    const mark_anchor_offset = parser.readU16(data, mark_rec_offset + 2) catch return null;

    if (mark_class >= mark_class_count) return null;

    // Parse mark anchor
    const mark_anchor = otlayout.parseAnchor(data, mark_array_base + @as(usize, mark_anchor_offset)) orelse return null;

    // Read BaseArray / Mark2Array
    const base_array_base = subtable_offset + @as(usize, base_array_offset);
    if (base_array_base + 2 > data.len) return null;
    const base_count = parser.readU16(data, base_array_base) catch return null;
    if (base_cov_index >= base_count) return null;

    // BaseRecord: baseAnchorOffsets[markClassCount] — each u16
    const base_rec_offset = base_array_base + 2 + @as(usize, base_cov_index) * @as(usize, mark_class_count) * 2;
    const base_anchor_offset_pos = base_rec_offset + @as(usize, mark_class) * 2;
    if (base_anchor_offset_pos + 2 > data.len) return null;
    const base_anchor_offset = parser.readU16(data, base_anchor_offset_pos) catch return null;

    if (base_anchor_offset == 0) return null; // NULL anchor

    // Parse base anchor
    const base_anchor = otlayout.parseAnchor(data, base_array_base + @as(usize, base_anchor_offset)) orelse return null;

    return .{
        .base_x = base_anchor.x,
        .base_y = base_anchor.y,
        .mark_x = mark_anchor.x,
        .mark_y = mark_anchor.y,
    };
}

fn queryMarkLig(data: []const u8, subtable_offset: usize, lig_glyph: u16, mark_glyph: u16, component_index: u16) ?AnchorPair {
    // MarkLigPos Format 1:
    // +0: posFormat (u16) = 1
    // +2: markCoverageOffset (u16)
    // +4: ligatureCoverageOffset (u16)
    // +6: markClassCount (u16)
    // +8: markArrayOffset (u16)
    // +10: ligatureArrayOffset (u16)

    if (subtable_offset + 12 > data.len) return null;
    const pos_format = parser.readU16(data, subtable_offset) catch return null;
    if (pos_format != 1) return null;

    const mark_cov_offset = parser.readU16(data, subtable_offset + 2) catch return null;
    const lig_cov_offset = parser.readU16(data, subtable_offset + 4) catch return null;
    const mark_class_count = parser.readU16(data, subtable_offset + 6) catch return null;
    const mark_array_offset = parser.readU16(data, subtable_offset + 8) catch return null;
    const lig_array_offset = parser.readU16(data, subtable_offset + 10) catch return null;

    // Check coverages
    const mark_coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, mark_cov_offset)) catch return null;
    const mark_cov_index = mark_coverage.getCoverageIndex(mark_glyph) orelse return null;

    const lig_coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, lig_cov_offset)) catch return null;
    const lig_cov_index = lig_coverage.getCoverageIndex(lig_glyph) orelse return null;

    // Read MarkArray
    const mark_array_base = subtable_offset + @as(usize, mark_array_offset);
    if (mark_array_base + 2 > data.len) return null;
    const mark_count = parser.readU16(data, mark_array_base) catch return null;
    if (mark_cov_index >= mark_count) return null;

    const mark_rec_offset = mark_array_base + 2 + @as(usize, mark_cov_index) * 4;
    if (mark_rec_offset + 4 > data.len) return null;
    const mark_class = parser.readU16(data, mark_rec_offset) catch return null;
    const mark_anchor_offset = parser.readU16(data, mark_rec_offset + 2) catch return null;

    if (mark_class >= mark_class_count) return null;

    const mark_anchor = otlayout.parseAnchor(data, mark_array_base + @as(usize, mark_anchor_offset)) orelse return null;

    // Read LigatureArray
    const lig_array_base = subtable_offset + @as(usize, lig_array_offset);
    if (lig_array_base + 2 > data.len) return null;
    const lig_count = parser.readU16(data, lig_array_base) catch return null;
    if (lig_cov_index >= lig_count) return null;

    // LigatureAttach offset
    const lig_attach_offset_pos = lig_array_base + 2 + @as(usize, lig_cov_index) * 2;
    if (lig_attach_offset_pos + 2 > data.len) return null;
    const lig_attach_offset = parser.readU16(data, lig_attach_offset_pos) catch return null;

    const lig_attach_base = lig_array_base + @as(usize, lig_attach_offset);
    if (lig_attach_base + 2 > data.len) return null;
    const component_count = parser.readU16(data, lig_attach_base) catch return null;

    if (component_index >= component_count) return null;

    // ComponentRecord: ligatureAnchorOffsets[markClassCount] — each u16
    const comp_rec_offset = lig_attach_base + 2 + @as(usize, component_index) * @as(usize, mark_class_count) * 2;
    const lig_anchor_offset_pos = comp_rec_offset + @as(usize, mark_class) * 2;
    if (lig_anchor_offset_pos + 2 > data.len) return null;
    const lig_anchor_offset = parser.readU16(data, lig_anchor_offset_pos) catch return null;

    if (lig_anchor_offset == 0) return null;

    const lig_anchor = otlayout.parseAnchor(data, lig_attach_base + @as(usize, lig_anchor_offset)) orelse return null;

    return .{
        .base_x = lig_anchor.x,
        .base_y = lig_anchor.y,
        .mark_x = mark_anchor.x,
        .mark_y = mark_anchor.y,
    };
}

fn queryCursive(data: []const u8, subtable_offset: usize, glyph: u16) ?CursiveAnchors {
    // CursivePos Format 1:
    // +0: posFormat (u16) = 1
    // +2: coverageOffset (u16)
    // +4: entryExitCount (u16)
    // +6: entryExitRecords[]
    //     each: entryAnchorOffset (u16) + exitAnchorOffset (u16) — subtable-relative

    if (subtable_offset + 6 > data.len) return null;
    const pos_format = parser.readU16(data, subtable_offset) catch return null;
    if (pos_format != 1) return null;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return null;
    const entry_exit_count = parser.readU16(data, subtable_offset + 4) catch return null;

    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return null;
    const cov_index = coverage.getCoverageIndex(glyph) orelse return null;

    if (cov_index >= entry_exit_count) return null;

    const rec_offset = subtable_offset + 6 + @as(usize, cov_index) * 4;
    if (rec_offset + 4 > data.len) return null;

    const entry_offset = parser.readU16(data, rec_offset) catch return null;
    const exit_offset = parser.readU16(data, rec_offset + 2) catch return null;

    const entry_anchor: ?otlayout.Anchor = if (entry_offset != 0)
        otlayout.parseAnchor(data, subtable_offset + @as(usize, entry_offset))
    else
        null;

    const exit_anchor: ?otlayout.Anchor = if (exit_offset != 0)
        otlayout.parseAnchor(data, subtable_offset + @as(usize, exit_offset))
    else
        null;

    if (entry_anchor == null and exit_anchor == null) return null;

    return .{
        .entry = entry_anchor,
        .exit = exit_anchor,
    };
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

test "parse GPOS table collects mark lookups from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const gpos_record = p.findTable(offset_table, "GPOS".*) orelse return;
    const gpos_data = try p.getTableData(font_data, gpos_record);
    var gpos = try parse(std.testing.allocator, gpos_data);
    defer gpos.deinit();

    // kern lookups should still work
    try std.testing.expect(gpos.kern_lookups.len > 0);

    // DejaVuSans has mark positioning
    try std.testing.expect(gpos.mark_base_lookups.len > 0 or gpos.mark_mark_lookups.len > 0);
}

test "GPOS getMarkBaseAnchors with DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const font_mod = @import("../font.zig");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const gpos = font.gpos orelse return;

    // Get glyph IDs for 'e' and combining acute accent (U+0301)
    const glyph_e = font.getGlyphId('e') catch return;
    const glyph_acute = font.getGlyphId(0x0301) catch return;

    if (glyph_e == 0 or glyph_acute == 0) return;

    // Try to get mark-to-base anchors
    const anchors = gpos.getMarkBaseAnchors(glyph_e, glyph_acute);
    if (anchors) |a| {
        // Base anchor should be somewhere above the baseline
        try std.testing.expect(a.base_y > 0);
    }
}
