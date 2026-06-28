const std = @import("std");
const parser = @import("../parser.zig");
const glyph_mod = @import("../glyph.zig");

pub const Index = struct {
    count: u16,
    off_size: u8,
    offsets_start: usize, // data 内のオフセット配列の開始位置
    data_start: usize, // data 内のデータ部の開始位置
    data: []const u8, // CFF テーブル全体への参照

    /// INDEX 構造全体のバイトサイズ（次の構造体の開始位置計算用）
    pub fn totalSize(self: Index) usize {
        if (self.count == 0) return 2; // count=0 の場合は 2 バイトのみ
        // last offset value gives the total data size
        const last_offset = self.readOffset(self.count);
        // 2(count) + 1(offSize) + (count+1)*offSize + data_size
        return 3 + @as(usize, @as(u32, self.count) + 1) * @as(usize, self.off_size) + (last_offset - 1);
    }

    /// i 番目の要素のデータスライスを返す (0-indexed)
    pub fn get(self: Index, index: u16) ?[]const u8 {
        if (index >= self.count) return null;
        const off1 = self.readOffset(index); // 1-indexed offset
        const off2 = self.readOffset(index + 1);
        if (off1 == 0 or off2 < off1) return null;
        const start = self.data_start + off1 - 1; // offset は 1-indexed
        const end = self.data_start + off2 - 1;
        if (end > self.data.len) return null;
        return self.data[start..end];
    }

    fn readOffset(self: Index, index: u16) usize {
        const pos = self.offsets_start + @as(usize, index) * @as(usize, self.off_size);
        if (pos + self.off_size > self.data.len) return 0;
        return switch (self.off_size) {
            1 => @as(usize, self.data[pos]),
            2 => @as(usize, std.mem.readInt(u16, self.data[pos..][0..2], .big)),
            3 => @as(usize, self.data[pos]) << 16 |
                @as(usize, self.data[pos + 1]) << 8 |
                @as(usize, self.data[pos + 2]),
            4 => @as(usize, std.mem.readInt(u32, self.data[pos..][0..4], .big)),
            else => 0,
        };
    }
};

pub fn parseIndex(data: []const u8, offset: usize) !Index {
    const count = try parser.readU16(data, offset);
    if (count == 0) return .{ .count = 0, .off_size = 0, .offsets_start = 0, .data_start = 0, .data = data };
    if (offset + 2 >= data.len) return error.UnexpectedEof;
    const off_size = data[offset + 2];
    if (off_size == 0 or off_size > 4) return error.InvalidCff;
    const offsets_start = offset + 3;
    const data_start = offsets_start + @as(usize, @as(u32, count) + 1) * @as(usize, off_size);
    return .{
        .count = count,
        .off_size = off_size,
        .offsets_start = offsets_start,
        .data_start = data_start,
        .data = data,
    };
}

// --- DICT decoder ---

pub const DictEntry = struct {
    operator: u16, // 1バイト or 2バイト (12,XX → 0x0C00 | XX)
    operands: [48]i32,
    operand_count: u8,
};

/// DICT データをパースして、指定オペレーターのオペランドを返す
pub fn dictLookup(dict_data: []const u8, target_op: u16) ?DictEntry {
    var stack: [48]i32 = undefined;
    var sp: u8 = 0;

    var i: usize = 0;
    while (i < dict_data.len) {
        const b0 = dict_data[i];
        i += 1;

        if (b0 == 28) {
            // Next 2 bytes as i16
            if (i + 2 > dict_data.len) return null;
            const val = std.mem.readInt(i16, dict_data[i..][0..2], .big);
            if (sp < 48) {
                stack[sp] = @as(i32, val);
                sp += 1;
            }
            i += 2;
        } else if (b0 == 29) {
            // Next 4 bytes as i32
            if (i + 4 > dict_data.len) return null;
            const val = std.mem.readInt(i32, dict_data[i..][0..4], .big);
            if (sp < 48) {
                stack[sp] = val;
                sp += 1;
            }
            i += 4;
        } else if (b0 == 30) {
            // Real number (BCD encoded) - skip for now, push 0
            while (i < dict_data.len) {
                const nibble_byte = dict_data[i];
                i += 1;
                // Check for end nibble (0xf) in either high or low nibble
                if ((nibble_byte >> 4) == 0x0f or (nibble_byte & 0x0f) == 0x0f) break;
            }
            if (sp < 48) {
                stack[sp] = 0;
                sp += 1;
            }
        } else if (b0 >= 32 and b0 <= 246) {
            // value = b0 - 139
            if (sp < 48) {
                stack[sp] = @as(i32, b0) - 139;
                sp += 1;
            }
        } else if (b0 >= 247 and b0 <= 250) {
            // value = (b0-247)*256 + b1 + 108
            if (i >= dict_data.len) return null;
            const b1 = dict_data[i];
            i += 1;
            if (sp < 48) {
                stack[sp] = (@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108;
                sp += 1;
            }
        } else if (b0 >= 251 and b0 <= 254) {
            // value = -(b0-251)*256 - b1 - 108
            if (i >= dict_data.len) return null;
            const b1 = dict_data[i];
            i += 1;
            if (sp < 48) {
                stack[sp] = -(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108;
                sp += 1;
            }
        } else if (b0 == 12) {
            // 2-byte operator: 0x0C00 | next_byte
            if (i >= dict_data.len) return null;
            const b1 = dict_data[i];
            i += 1;
            const op: u16 = 0x0C00 | @as(u16, b1);
            if (op == target_op) {
                var entry: DictEntry = .{
                    .operator = op,
                    .operands = undefined,
                    .operand_count = sp,
                };
                for (0..sp) |j| {
                    entry.operands[j] = stack[j];
                }
                return entry;
            }
            sp = 0;
        } else if (b0 <= 21) {
            // 1-byte operator (0-11, 13-21)
            const op: u16 = @as(u16, b0);
            if (op == target_op) {
                var entry: DictEntry = .{
                    .operator = op,
                    .operands = undefined,
                    .operand_count = sp,
                };
                for (0..sp) |j| {
                    entry.operands[j] = stack[j];
                }
                return entry;
            }
            sp = 0;
        } else {
            // Unknown byte in DICT, skip (should not happen in well-formed data)
        }
    }
    return null;
}

/// Lookup a single integer operand for the given operator
pub fn dictLookupInt(dict_data: []const u8, target_op: u16) ?i32 {
    const entry = dictLookup(dict_data, target_op) orelse return null;
    if (entry.operand_count == 0) return null;
    return entry.operands[entry.operand_count - 1];
}

/// Lookup a pair of integer operands for the given operator (e.g., Private DICT: size, offset)
pub fn dictLookupPair(dict_data: []const u8, target_op: u16) ?[2]i32 {
    const entry = dictLookup(dict_data, target_op) orelse return null;
    if (entry.operand_count < 2) return null;
    return .{ entry.operands[entry.operand_count - 2], entry.operands[entry.operand_count - 1] };
}

// --- CFF Table ---

pub const CffTable = struct {
    data: []const u8,
    charstrings: Index, // CharStrings INDEX
    global_subrs: Index, // Global Subr INDEX

    // Non-CID: single local subrs + widths
    local_subrs: Index, // Local Subr INDEX (Private DICT から)
    default_width: i32,
    nominal_width: i32,
    blue_zones: glyph_mod.BlueZones,

    // CID-keyed: per-FD local subrs + widths
    is_cid: bool,
    fd_local_subrs: []Index, // allocated array, one per FD entry
    fd_default_widths: []i32,
    fd_nominal_widths: []i32,
    fd_blue_zones: []glyph_mod.BlueZones,
    fd_select_data: []const u8, // raw FDSelect data (past format byte)
    fd_select_format: u8,
    num_glyphs: u16, // for FDSelect format 0 bounds checking
    allocator: ?std.mem.Allocator, // for freeing fd arrays

    pub fn getCharString(self: CffTable, glyph_id: u16) ?[]const u8 {
        return self.charstrings.get(glyph_id);
    }

    pub fn getLocalSubrs(self: CffTable, glyph_id: u16) Index {
        if (!self.is_cid) return self.local_subrs;
        const fd_index = self.fdSelectLookup(glyph_id);
        if (fd_index >= self.fd_local_subrs.len) return self.local_subrs;
        return self.fd_local_subrs[fd_index];
    }

    fn fdSelectLookup(self: CffTable, glyph_id: u16) usize {
        if (!self.is_cid) return 0;
        const fd_data = self.fd_select_data;

        if (self.fd_select_format == 0) {
            // format 0: fd_data[i] = FD index for glyph i
            if (glyph_id < fd_data.len) return @as(usize, fd_data[glyph_id]);
            return 0;
        } else if (self.fd_select_format == 3) {
            // format 3: nRanges(u16), ranges[nRanges]{first:u16, fd:u8}, sentinel:u16
            if (fd_data.len < 2) return 0;
            const n_ranges = std.mem.readInt(u16, fd_data[0..2], .big);
            if (n_ranges == 0) return 0;

            // Binary search: find range where ranges[i].first <= glyph_id < ranges[i+1].first
            var lo: usize = 0;
            var hi: usize = n_ranges;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                // range[mid].first at offset 2 + mid * 3
                const mid_first_off = 2 + mid * 3;
                if (mid_first_off + 2 > fd_data.len) break;
                const mid_first = std.mem.readInt(u16, fd_data[mid_first_off..][0..2], .big);
                if (glyph_id >= mid_first) {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            // FD index at range[lo].fd = fd_data[2 + lo*3 + 2]
            const fd_off = 2 + lo * 3 + 2;
            if (fd_off >= fd_data.len) return 0;
            return @as(usize, fd_data[fd_off]);
        }
        return 0;
    }

    pub fn getBlueZones(self: CffTable, glyph_id: u16) glyph_mod.BlueZones {
        if (!self.is_cid) return self.blue_zones;
        const fd_index = self.fdSelectLookup(glyph_id);
        if (fd_index >= self.fd_blue_zones.len) return self.blue_zones;
        return self.fd_blue_zones[fd_index];
    }

    pub fn deinit(self: *CffTable) void {
        if (self.allocator) |alloc| {
            alloc.free(self.fd_local_subrs);
            alloc.free(self.fd_default_widths);
            alloc.free(self.fd_nominal_widths);
            alloc.free(self.fd_blue_zones);
        }
    }
};

pub const CffError = error{
    InvalidCff,
    UnexpectedEof,
};

fn parseDeltaArray(comptime N: usize, dest: *[N]f32, count: *u8, private_data: []const u8, op: u16) void {
    const entry = dictLookup(private_data, op) orelse return;
    var acc: f32 = 0;
    const max_count: usize = @min(@as(usize, entry.operand_count), N);
    for (0..max_count) |i| {
        acc += @floatFromInt(entry.operands[i]);
        dest[i] = acc;
    }
    count.* = @intCast(max_count);
}

/// Parse a Private DICT and return local_subrs, widths, and blue zones.
fn parsePrivateDict(data: []const u8, private_size: i32, private_offset: i32) struct { local_subrs: Index, default_width: i32, nominal_width: i32, blue_zones: glyph_mod.BlueZones } {
    const empty_index = Index{ .count = 0, .off_size = 0, .offsets_start = 0, .data_start = 0, .data = data };
    if (private_size <= 0 or private_offset < 0) {
        return .{ .local_subrs = empty_index, .default_width = 0, .nominal_width = 0, .blue_zones = .{} };
    }
    const p_off: usize = @intCast(private_offset);
    const p_size: usize = @intCast(private_size);
    if (p_off + p_size > data.len) {
        return .{ .local_subrs = empty_index, .default_width = 0, .nominal_width = 0, .blue_zones = .{} };
    }
    const private_data = data[p_off .. p_off + p_size];

    var local_subrs = empty_index;
    var blue_zones = glyph_mod.BlueZones{};
    // operator 19 = Local Subr offset (Private DICT 先頭からの相対)
    if (dictLookupInt(private_data, 19)) |subr_off| {
        if (subr_off >= 0) {
            const abs_off: usize = p_off + @as(usize, @intCast(subr_off));
            if (abs_off < data.len) {
                local_subrs = parseIndex(data, abs_off) catch empty_index;
            }
        }
    }

    // operator 20 = defaultWidthX
    const default_width = dictLookupInt(private_data, 20) orelse 0;
    // operator 21 = nominalWidthX
    const nominal_width = dictLookupInt(private_data, 21) orelse 0;

    parseDeltaArray(14, &blue_zones.blue_values, &blue_zones.blue_count, private_data, 6);
    parseDeltaArray(10, &blue_zones.other_blues, &blue_zones.other_count, private_data, 7);
    if (dictLookupInt(private_data, 0x0C0A)) |v| blue_zones.blue_shift = @floatFromInt(v);
    if (dictLookupInt(private_data, 0x0C0B)) |v| blue_zones.blue_fuzz = @floatFromInt(v);
    if (dictLookupInt(private_data, 10)) |v| blue_zones.std_hw = @floatFromInt(v);
    if (dictLookupInt(private_data, 11)) |v| blue_zones.std_vw = @floatFromInt(v);
    parseDeltaArray(12, &blue_zones.snap_h, &blue_zones.snap_h_count, private_data, 0x0C0C);
    parseDeltaArray(12, &blue_zones.snap_v, &blue_zones.snap_v_count, private_data, 0x0C0D);

    return .{ .local_subrs = local_subrs, .default_width = default_width, .nominal_width = nominal_width, .blue_zones = blue_zones };
}

pub fn parseCff(allocator: std.mem.Allocator, data: []const u8) !CffTable {
    if (data.len < 4) return error.InvalidCff;

    // 1. Header: major(u8), minor(u8), hdrSize(u8), offSize(u8)
    const hdr_size: usize = data[2];

    // 2. Name INDEX (hdrSize から)
    const name_index = try parseIndex(data, hdr_size);

    // 3. Top DICT INDEX (Name INDEX の直後)
    const top_dict_index_offset = hdr_size + name_index.totalSize();
    const top_dict_index = try parseIndex(data, top_dict_index_offset);

    // 4. String INDEX (Top DICT INDEX の直後)
    const string_index_offset = top_dict_index_offset + top_dict_index.totalSize();
    const string_index = try parseIndex(data, string_index_offset);

    // 5. Global Subr INDEX (String INDEX の直後)
    const gsubr_offset = string_index_offset + string_index.totalSize();
    const global_subrs = try parseIndex(data, gsubr_offset);

    // 6. Top DICT を読んで CharStrings offset と Private DICT 情報を取得
    const top_dict_data = top_dict_index.get(0) orelse return error.InvalidCff;

    // operator 17 = CharStrings offset
    const charstrings_offset = dictLookupInt(top_dict_data, 17) orelse return error.InvalidCff;
    if (charstrings_offset < 0) return error.InvalidCff;
    const charstrings = try parseIndex(data, @intCast(charstrings_offset));

    const num_glyphs = charstrings.count;

    // Check for CID-keyed font: operator (12, 30) = ROS
    const is_cid = dictLookup(top_dict_data, 0x0C1E) != null;

    const empty_index = Index{ .count = 0, .off_size = 0, .offsets_start = 0, .data_start = 0, .data = data };

    if (is_cid) {
        // CID-keyed font: parse FDArray and FDSelect

        // operator (12, 36) = FDArray offset
        const fd_array_offset_i = dictLookupInt(top_dict_data, 0x0C24) orelse return error.InvalidCff;
        if (fd_array_offset_i < 0) return error.InvalidCff;
        const fd_array_index = try parseIndex(data, @intCast(fd_array_offset_i));
        const fd_count = fd_array_index.count;

        // Allocate per-FD arrays
        const fd_local_subrs = try allocator.alloc(Index, fd_count);
        errdefer allocator.free(fd_local_subrs);
        const fd_default_widths = try allocator.alloc(i32, fd_count);
        errdefer allocator.free(fd_default_widths);
        const fd_nominal_widths = try allocator.alloc(i32, fd_count);
        errdefer allocator.free(fd_nominal_widths);
        const fd_blue_zones = try allocator.alloc(glyph_mod.BlueZones, fd_count);
        errdefer allocator.free(fd_blue_zones);

        for (0..fd_count) |i| {
            const fd_dict_data = fd_array_index.get(@intCast(i)) orelse {
                fd_local_subrs[i] = empty_index;
                fd_default_widths[i] = 0;
                fd_nominal_widths[i] = 0;
                fd_blue_zones[i] = .{};
                continue;
            };
            // Each Font DICT has operator 18 = Private (size, offset)
            if (dictLookupPair(fd_dict_data, 18)) |private_info| {
                const result = parsePrivateDict(data, private_info[0], private_info[1]);
                fd_local_subrs[i] = result.local_subrs;
                fd_default_widths[i] = result.default_width;
                fd_nominal_widths[i] = result.nominal_width;
                fd_blue_zones[i] = result.blue_zones;
            } else {
                fd_local_subrs[i] = empty_index;
                fd_default_widths[i] = 0;
                fd_nominal_widths[i] = 0;
                fd_blue_zones[i] = .{};
            }
        }

        // operator (12, 37) = FDSelect offset
        const fd_select_offset_i = dictLookupInt(top_dict_data, 0x0C25) orelse return error.InvalidCff;
        if (fd_select_offset_i < 0) return error.InvalidCff;
        const fd_select_abs: usize = @intCast(fd_select_offset_i);
        if (fd_select_abs >= data.len) return error.InvalidCff;

        const fd_select_format = data[fd_select_abs];
        // fd_select_data points past the format byte
        const fd_select_data = data[fd_select_abs + 1 ..];

        return .{
            .data = data,
            .charstrings = charstrings,
            .global_subrs = global_subrs,
            .local_subrs = empty_index,
            .default_width = 0,
            .nominal_width = 0,
            .blue_zones = .{},
            .is_cid = true,
            .fd_local_subrs = fd_local_subrs,
            .fd_default_widths = fd_default_widths,
            .fd_nominal_widths = fd_nominal_widths,
            .fd_blue_zones = fd_blue_zones,
            .fd_select_data = fd_select_data,
            .fd_select_format = fd_select_format,
            .num_glyphs = num_glyphs,
            .allocator = allocator,
        };
    }

    // Non-CID font: operator 18 = Private (size, offset)
    var local_subrs: Index = empty_index;
    var default_width: i32 = 0;
    var nominal_width: i32 = 0;
    var blue_zones = glyph_mod.BlueZones{};

    if (dictLookupPair(top_dict_data, 18)) |private_info| {
        const result = parsePrivateDict(data, private_info[0], private_info[1]);
        local_subrs = result.local_subrs;
        default_width = result.default_width;
        nominal_width = result.nominal_width;
        blue_zones = result.blue_zones;
    }

    return .{
        .data = data,
        .charstrings = charstrings,
        .global_subrs = global_subrs,
        .local_subrs = local_subrs,
        .default_width = default_width,
        .nominal_width = nominal_width,
        .blue_zones = blue_zones,
        .is_cid = false,
        .fd_local_subrs = &.{},
        .fd_default_widths = &.{},
        .fd_nominal_widths = &.{},
        .fd_blue_zones = &.{},
        .fd_select_data = &.{},
        .fd_select_format = 0,
        .num_glyphs = num_glyphs,
        .allocator = null,
    };
}

// --- Tests ---

test "INDEX parser: parse simple INDEX with 2 entries" {
    // Hand-crafted INDEX: count=2, offSize=1, offsets=[1,4,7], data="abcdef"
    const data = [_]u8{
        0x00, 0x02, // count = 2
        0x01, // offSize = 1
        0x01, 0x04, 0x07, // offsets: [1, 4, 7] (1-indexed)
        'a', 'b', 'c', // entry 0: "abc"
        'd', 'e', 'f', // entry 1: "def"
    };

    const index = try parseIndex(&data, 0);
    try std.testing.expectEqual(@as(u16, 2), index.count);
    try std.testing.expectEqual(@as(u8, 1), index.off_size);

    const entry0 = index.get(0) orelse return error.InvalidCff;
    try std.testing.expectEqualSlices(u8, "abc", entry0);

    const entry1 = index.get(1) orelse return error.InvalidCff;
    try std.testing.expectEqualSlices(u8, "def", entry1);

    // Out of range returns null
    try std.testing.expect(index.get(2) == null);

    // totalSize: 2 + 1 + 3*1 + 6 = 12
    try std.testing.expectEqual(@as(usize, 12), index.totalSize());
}

test "INDEX parser: empty INDEX" {
    const data = [_]u8{
        0x00, 0x00, // count = 0
    };

    const index = try parseIndex(&data, 0);
    try std.testing.expectEqual(@as(u16, 0), index.count);
    try std.testing.expectEqual(@as(usize, 2), index.totalSize());
    try std.testing.expect(index.get(0) == null);
}

test "INDEX parser: 2-byte offSize" {
    // INDEX: count=1, offSize=2, offsets=[1, 4] (big-endian u16), data="xyz"
    const data = [_]u8{
        0x00, 0x01, // count = 1
        0x02, // offSize = 2
        0x00, 0x01, // offset[0] = 1
        0x00, 0x04, // offset[1] = 4
        'x', 'y', 'z', // entry 0: "xyz"
    };

    const index = try parseIndex(&data, 0);
    try std.testing.expectEqual(@as(u16, 1), index.count);
    const entry0 = index.get(0) orelse return error.InvalidCff;
    try std.testing.expectEqualSlices(u8, "xyz", entry0);
}

test "DICT decoder: simple integer operand" {
    // DICT: value 500 (encoded as 29, then i32 big-endian), then operator 17
    const data = [_]u8{
        29, 0x00, 0x00, 0x01, 0xF4, // i32 = 500
        17, // operator 17 (CharStrings)
    };

    const result = dictLookupInt(&data, 17);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 500), result.?);
}

test "DICT decoder: small integer encoding" {
    // value = b0 - 139: b0=139 → 0, b0=140 → 1, b0=239 → 100
    const data = [_]u8{
        239, // value = 239 - 139 = 100
        17, // operator 17
    };

    const result = dictLookupInt(&data, 17);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 100), result.?);
}

test "DICT decoder: negative integer encoding" {
    // b0=251: value = -(251-251)*256 - b1 - 108 = -b1 - 108
    // b0=251, b1=0: value = -108
    const data = [_]u8{
        251, 0, // value = -(251-251)*256 - 0 - 108 = -108
        17, // operator 17
    };

    const result = dictLookupInt(&data, 17);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, -108), result.?);
}

test "DICT decoder: pair operands (Private DICT)" {
    // Private DICT operator 18 with two operands: size=100, offset=200
    const data = [_]u8{
        239, // value = 100 (239-139)
        28, 0x00, 0xC8, // i16 = 200
        18, // operator 18 (Private)
    };

    const result = dictLookupPair(&data, 18);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 100), result.?[0]);
    try std.testing.expectEqual(@as(i32, 200), result.?[1]);
}

test "DICT decoder: 2-byte operator (12, XX)" {
    // 2-byte operator: 12, 7 = 0x0C07 (FontMatrix)
    const data = [_]u8{
        139, // value = 0
        12, 7, // operator 0x0C07
    };

    const result = dictLookupInt(&data, 0x0C07);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 0), result.?);
}

test "DICT decoder: target not found returns null" {
    const data = [_]u8{
        139, // value = 0
        17, // operator 17
    };

    const result = dictLookupInt(&data, 18);
    try std.testing.expect(result == null);
}

test "DICT decoder: 247-250 range encoding" {
    // b0=247, b1=155: value = (247-247)*256 + 155 + 108 = 263
    const data = [_]u8{
        247, 155, // value = 0*256 + 155 + 108 = 263
        17, // operator 17
    };

    const result = dictLookupInt(&data, 17);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 263), result.?);
}

test "DICT decoder: i16 encoding (b0=28)" {
    // b0=28, then i16 big-endian
    const data = [_]u8{
        28, 0x01, 0x00, // i16 = 256
        17, // operator 17
    };

    const result = dictLookupInt(&data, 17);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 256), result.?);
}
