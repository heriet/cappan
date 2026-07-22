const std = @import("std");

// Generic SFNT container assembly: given a list of (tag, data) table entries,
// builds a complete, valid SFNT binary (12-byte header, 16-byte-per-table
// directory with per-table checksums, 4-byte-aligned table data, and the
// standard OpenType "head" table checksum-adjustment two-pass dance). This has
// nothing subset-specific about it -- cappan_subset's subsetter.zig used to
// carry this logic inline, but a future font merge/convert tool would need the
// exact same assembly step, so it lives in core instead.

pub const TableEntry = struct {
    tag: [4]u8,
    data: []const u8,
};

pub fn writeU16BE(buf: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, buf[offset..][0..2], value, .big);
}

pub fn writeI16BE(buf: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, buf[offset..][0..2], value, .big);
}

pub fn writeU32BE(buf: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buf[offset..][0..4], value, .big);
}

pub fn writeI32BE(buf: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, buf[offset..][0..4], value, .big);
}

pub const SearchParams = struct {
    search_range: u16,
    entry_selector: u16,
    range_shift: u16,
};

/// Computes the SFNT offset-table search parameters (searchRange,
/// entrySelector, rangeShift) for `num_tables`, per the OpenType spec. Uses
/// u32 intermediates so a malformed table count can't overflow/underflow the
/// u16 arithmetic: numTables==0 (rangeShift would go 0*16 - 16 negative) or a
/// count whose *16 exceeds u16 (>= 4096). The result is byte-identical to the
/// naive u16 form for every well-formed count (1 <= numTables <= 4095).
pub fn searchParams(num_tables: u16) SearchParams {
    var search_range: u32 = 1;
    var entry_selector: u16 = 0;
    while (search_range * 2 <= num_tables) {
        search_range *= 2;
        entry_selector += 1;
    }
    search_range *= 16;
    const total: u32 = @as(u32, num_tables) * 16;
    const range_shift: u32 = if (total >= search_range) total - search_range else 0;
    return .{
        .search_range = @truncate(search_range),
        .entry_selector = entry_selector,
        .range_shift = @truncate(range_shift),
    };
}

/// Calculate a TrueType table checksum (sum of 32-bit big-endian words, with zero-padding).
pub fn calcChecksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        sum +%= std.mem.readInt(u32, data[i..][0..4], .big);
    }
    // Handle remaining bytes (padded with zeros)
    if (i < data.len) {
        var last: [4]u8 = .{ 0, 0, 0, 0 };
        for (data[i..], 0..) |b, j| {
            last[j] = b;
        }
        sum +%= std.mem.readInt(u32, &last, .big);
    }
    return sum;
}

fn tagLessThan(_: void, a: TableEntry, b: TableEntry) bool {
    return std.mem.lessThan(u8, &a.tag, &b.tag);
}

/// Assembles `entries` into a complete SFNT binary: 12-byte offset-table
/// header (version 0x00010000, i.e. TrueType outlines), a 16-byte-per-table
/// directory (searchRange/entrySelector/rangeShift computed from the table
/// count per the OpenType spec), 4-byte-aligned table data, and the standard
/// "head" table checkSumAdjustment two-pass fixup (zero it, compute the
/// whole-file checksum, then write `0xB1B0AFBA -% file_checksum` into it) if a
/// "head" table is present.
///
/// The OpenType spec requires the table *directory* to be sorted by tag in
/// ascending order (and the header's searchRange/entrySelector/rangeShift
/// advertise a binary search that only works on a sorted directory). Rather
/// than trust every caller to pre-sort, `assemble` sorts a local copy of the
/// entries by tag before emitting anything, so the output is spec-conformant
/// regardless of the order tables were appended in. Both the directory and the
/// table data are laid out in this sorted order; the checkSumAdjustment fixup
/// runs against the final byte layout, so it stays correct after the sort.
/// Caller owns the returned slice.
pub fn assemble(allocator: std.mem.Allocator, entries: []const TableEntry) ![]u8 {
    const num_tables: u16 = @intCast(entries.len);

    // Sort a private copy by tag so the emitted directory is in ascending-tag
    // order (OpenType requirement) no matter what order the caller supplied.
    const sorted = try allocator.dupe(TableEntry, entries);
    defer allocator.free(sorted);
    std.mem.sort(TableEntry, sorted, {}, tagLessThan);

    const sp = searchParams(num_tables);
    const search_range = sp.search_range;
    const entry_selector = sp.entry_selector;
    const range_shift = sp.range_shift;

    const header_size: usize = 12 + @as(usize, num_tables) * 16;
    var tables_size: usize = 0;
    for (sorted) |e| {
        tables_size += (e.data.len + 3) & ~@as(usize, 3);
    }
    const total_size = header_size + tables_size;

    const out = try allocator.alloc(u8, total_size);
    errdefer allocator.free(out);
    @memset(out, 0);

    var pos: usize = 0;
    writeU32BE(out, pos, 0x00010000);
    pos += 4;
    writeU16BE(out, pos, num_tables);
    pos += 2;
    writeU16BE(out, pos, search_range);
    pos += 2;
    writeU16BE(out, pos, entry_selector);
    pos += 2;
    writeU16BE(out, pos, range_shift);
    pos += 2;

    var data_offset: u32 = @intCast(header_size);
    var head_checksum_offset: usize = 0;

    for (sorted) |e| {
        const checksum = calcChecksum(e.data);
        out[pos] = e.tag[0];
        out[pos + 1] = e.tag[1];
        out[pos + 2] = e.tag[2];
        out[pos + 3] = e.tag[3];
        pos += 4;
        writeU32BE(out, pos, checksum);
        pos += 4;
        writeU32BE(out, pos, data_offset);
        pos += 4;
        writeU32BE(out, pos, @intCast(e.data.len));
        pos += 4;

        if (std.mem.eql(u8, &e.tag, "head")) {
            head_checksum_offset = @intCast(data_offset + 8);
        }

        const aligned: usize = (e.data.len + 3) & ~@as(usize, 3);
        data_offset += @intCast(aligned);
    }

    for (sorted) |e| {
        @memcpy(out[pos .. pos + e.data.len], e.data);
        const aligned: usize = (e.data.len + 3) & ~@as(usize, 3);
        pos += aligned;
    }

    if (head_checksum_offset != 0) {
        writeU32BE(out, head_checksum_offset, 0);
        const file_checksum = calcChecksum(out);
        const adjustment: u32 = 0xB1B0AFBA -% file_checksum;
        writeU32BE(out, head_checksum_offset, adjustment);
    }

    return out;
}

test "writeU16BE" {
    var buf: [2]u8 = undefined;
    writeU16BE(&buf, 0, 0x1234);
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);
}

test "writeU32BE" {
    var buf: [4]u8 = undefined;
    writeU32BE(&buf, 0, 0x12345678);
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x56), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x78), buf[3]);
}

test "calcChecksum aligned" {
    // 4 bytes: 0x00000001 -> sum = 1
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x01 };
    try std.testing.expectEqual(@as(u32, 1), calcChecksum(&data));
}

test "calcChecksum with remainder" {
    // 5 bytes: word 0x01020304, then 0x05 padded -> 0x05000000
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    const expected: u32 = 0x01020304 +% 0x05000000;
    try std.testing.expectEqual(expected, calcChecksum(&data));
}

test "calcChecksum empty" {
    try std.testing.expectEqual(@as(u32, 0), calcChecksum(&[_]u8{}));
}

test "assemble produces a valid SFNT header and directory" {
    const allocator = std.testing.allocator;
    const entries = [_]TableEntry{
        .{ .tag = "aaaa".*, .data = &[_]u8{ 1, 2, 3, 4 } },
        .{ .tag = "bbbb".*, .data = &[_]u8{ 5, 6, 7 } }, // needs padding to align to 4
    };
    const out = try assemble(allocator, &entries);
    defer allocator.free(out);

    // sfntVersion
    try std.testing.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, out[0..4], .big));
    // numTables
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[4..6], .big));

    // First table directory entry: tag "aaaa", offset = 12 + 2*16 = 44
    try std.testing.expectEqualSlices(u8, "aaaa", out[12..16]);
    const first_offset = std.mem.readInt(u32, out[20..24], .big);
    try std.testing.expectEqual(@as(u32, 44), first_offset);
    const first_length = std.mem.readInt(u32, out[24..28], .big);
    try std.testing.expectEqual(@as(u32, 4), first_length);

    // Second table directory entry: tag "bbbb", offset = 44 + 4 (aligned) = 48
    try std.testing.expectEqualSlices(u8, "bbbb", out[28..32]);
    const second_offset = std.mem.readInt(u32, out[36..40], .big);
    try std.testing.expectEqual(@as(u32, 48), second_offset);
}

test "assemble sorts the table directory into ascending tag order" {
    const allocator = std.testing.allocator;
    // Deliberately supply entries out of tag order. The "head" table needs at
    // least 12 bytes so the checkSumAdjustment field (offset 8) fits.
    var head_data: [12]u8 = .{0} ** 12;
    const entries = [_]TableEntry{
        .{ .tag = "name".*, .data = &[_]u8{ 1, 2, 3, 4 } },
        .{ .tag = "cmap".*, .data = &[_]u8{ 5, 6, 7, 8 } },
        .{ .tag = "glyf".*, .data = &[_]u8{ 9, 10, 11, 12 } },
        .{ .tag = "head".*, .data = &head_data },
    };
    const out = try assemble(allocator, &entries);
    defer allocator.free(out);

    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, out[4..6], .big));

    // Directory entries live at 12 + i*16; the first 4 bytes of each are the tag.
    // Expect ascending order: cmap, glyf, head, name.
    const expected_tags = [_][]const u8{ "cmap", "glyf", "head", "name" };
    var prev: [4]u8 = .{ 0, 0, 0, 0 };
    for (expected_tags, 0..) |tag, i| {
        const entry_off = 12 + i * 16;
        const got = out[entry_off .. entry_off + 4];
        try std.testing.expectEqualSlices(u8, tag, got);
        // Strictly ascending relative to the previous directory tag.
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, &prev, got));
        @memcpy(&prev, got);

        // Offset + length stay within the assembled file.
        const offset = std.mem.readInt(u32, out[entry_off + 8 ..][0..4], .big);
        const length = std.mem.readInt(u32, out[entry_off + 12 ..][0..4], .big);
        try std.testing.expect(offset + length <= out.len);
        // Every table body must start 4-byte aligned.
        try std.testing.expectEqual(@as(u32, 0), offset % 4);
    }
}

test "assemble applies the head checkSumAdjustment fixup when a head table is present" {
    const allocator = std.testing.allocator;
    // A minimal fake "head" table: 4 zero bytes, then a checkSumAdjustment
    // field at byte offset 8 (needs at least 12 bytes total for the offset+4
    // field to fit).
    var head_data: [12]u8 = .{0} ** 12;
    const entries = [_]TableEntry{
        .{ .tag = "head".*, .data = &head_data },
    };
    const out = try assemble(allocator, &entries);
    defer allocator.free(out);

    // head table starts right after the 12+16=28-byte header.
    const head_offset = 28;
    const adjustment = std.mem.readInt(u32, out[head_offset + 8 ..][0..4], .big);
    // Zero out the adjustment field in a copy, recompute the checksum, and
    // confirm adjustment +% checksum == the OpenType magic constant.
    const check_copy = try allocator.dupe(u8, out);
    defer allocator.free(check_copy);
    writeU32BE(check_copy, head_offset + 8, 0);
    const recomputed = calcChecksum(check_copy);
    try std.testing.expectEqual(@as(u32, 0xB1B0AFBA), recomputed +% adjustment);
}
