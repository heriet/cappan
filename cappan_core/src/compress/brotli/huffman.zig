const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;

pub const MAX_CODE_LENGTH: u8 = 15;
pub const MAX_CODE_LENGTH_CODE_LENGTH: u8 = 5;
pub const CODE_LENGTH_CODES: usize = 18;
pub const HUFFMAN_TABLE_BITS: u5 = 8;
pub const HUFFMAN_TABLE_SIZE: usize = 256;

pub const kCodeLengthCodeOrder = [CODE_LENGTH_CODES]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
pub const kCodeLengthPrefixLength = [16]u8{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
pub const kCodeLengthPrefixValue = [16]u8{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };

pub const Entry = struct {
    bits: u8, // code length in bits (0 = invalid/empty)
    value: u16, // decoded symbol (or subtable offset when bits > HUFFMAN_TABLE_BITS)
};

pub const HuffmanTable = struct {
    allocator: std.mem.Allocator,
    root: [HUFFMAN_TABLE_SIZE]Entry,
    subtables: []Entry,
    is_single_symbol: bool = false,

    pub fn deinit(self: *HuffmanTable) void {
        self.allocator.free(self.subtables);
    }

    pub fn readSymbol(self: *const HuffmanTable, reader: *BitReader) !u16 {
        // Check for single-symbol table (bits == 0 in root means return without consuming)
        if (self.root[0].bits == 0 and self.is_single_symbol) {
            return self.root[0].value;
        }

        // Peek up to 15 bits (max Huffman code length) without consuming.
        // This mirrors the C reference decoder: peek bits, do lookup(s), then
        // drop only the bits that were actually part of the code.
        // Save state first because peekBits may corrupt reader on failure.
        const saved_reader = reader.*;
        const peeked_bits: u32 = reader.peekBits(MAX_CODE_LENGTH) catch blk: {
            // Near end of stream: restore and peek what we can, bit by bit
            reader.* = saved_reader;
            var val: u32 = 0;
            var i: u5 = 0;
            while (i < MAX_CODE_LENGTH) : (i += 1) {
                const b = reader.readBit() catch break;
                val |= @as(u32, b) << i;
            }
            reader.* = saved_reader;
            break :blk val;
        };

        const idx: usize = @intCast(peeked_bits & 0xFF);
        const entry = self.root[idx];
        if (entry.bits == 0) return error.InvalidHuffmanCode;

        if (entry.bits <= @as(u8, HUFFMAN_TABLE_BITS)) {
            // Simple root lookup: consume entry.bits bits
            reader.consumeBits(@intCast(entry.bits));
            return entry.value;
        } else {
            // Two-level lookup: root points to subtable
            const nbits: u5 = @intCast(entry.bits - @as(u8, HUFFMAN_TABLE_BITS));
            const extra: u32 = (peeked_bits >> HUFFMAN_TABLE_BITS) & ((@as(u32, 1) << nbits) - 1);
            const sub_entry = self.subtables[@as(usize, entry.value) + @as(usize, @intCast(extra))];
            if (sub_entry.bits == 0) return error.InvalidHuffmanCode;
            // Total bits consumed = HUFFMAN_TABLE_BITS + sub_entry.bits
            const total_bits: u5 = @as(u5, HUFFMAN_TABLE_BITS) + @as(u5, @intCast(sub_entry.bits));
            reader.consumeBits(total_bits);
            return sub_entry.value;
        }
    }
};

fn reverseBits(val: u32, num_bits: u5) u32 {
    var v = val;
    var result: u32 = 0;
    var i: u5 = 0;
    while (i < num_bits) : (i += 1) {
        result = (result << 1) | (v & 1);
        v >>= 1;
    }
    return result;
}

/// Build a Huffman lookup table from an array of code lengths.
/// code_lengths[i] = number of bits for symbol i (0 = symbol not present).
pub fn buildTable(allocator: std.mem.Allocator, code_lengths: []const u8) !HuffmanTable {
    var count = [_]u16{0} ** (@as(usize, MAX_CODE_LENGTH) + 1);
    for (code_lengths) |cl| {
        if (cl > 0 and cl <= MAX_CODE_LENGTH) {
            count[cl] += 1;
        }
    }

    var subtable_max_extra = [_]u8{0} ** HUFFMAN_TABLE_SIZE;

    {
        var code: u32 = 0;
        var len: u8 = 1;
        var next_code = [_]u32{0} ** (@as(usize, MAX_CODE_LENGTH) + 1);
        while (len <= MAX_CODE_LENGTH) : (len += 1) {
            next_code[len] = code;
            code = (code + @as(u32, count[len])) << 1;
        }

        for (code_lengths, 0..) |cl, sym| {
            _ = sym;
            if (cl == 0) continue;
            const cl8: u8 = @intCast(cl);
            const canonical = next_code[cl];
            next_code[cl] += 1;
            const rcode = reverseBits(canonical, @intCast(cl8));
            if (cl8 > @as(u8, HUFFMAN_TABLE_BITS)) {
                const root_idx: usize = @intCast(rcode & 0xFF);
                const extra: u8 = cl8 - @as(u8, HUFFMAN_TABLE_BITS);
                if (extra > subtable_max_extra[root_idx]) {
                    subtable_max_extra[root_idx] = extra;
                }
            }
        }
    }

    var subtable_offsets = [_]u32{0} ** HUFFMAN_TABLE_SIZE;
    var total_subtable_size: usize = 0;
    for (0..HUFFMAN_TABLE_SIZE) |i| {
        if (subtable_max_extra[i] > 0) {
            subtable_offsets[i] = @intCast(total_subtable_size);
            total_subtable_size += @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(subtable_max_extra[i]));
        }
    }

    const subtables = try allocator.alloc(Entry, total_subtable_size);
    @memset(subtables, Entry{ .bits = 0, .value = 0 });

    var table = HuffmanTable{
        .allocator = allocator,
        .root = [_]Entry{.{ .bits = 0, .value = 0 }} ** HUFFMAN_TABLE_SIZE,
        .subtables = subtables,
    };

    {
        var code: u32 = 0;
        var len: u8 = 1;
        var next_code = [_]u32{0} ** (@as(usize, MAX_CODE_LENGTH) + 1);
        while (len <= MAX_CODE_LENGTH) : (len += 1) {
            next_code[len] = code;
            code = (code + @as(u32, count[len])) << 1;
        }

        for (code_lengths, 0..) |cl, sym| {
            if (cl == 0) continue;
            const cl8: u8 = @intCast(cl);
            const canonical = next_code[cl];
            next_code[cl] += 1;
            const rcode = reverseBits(canonical, @intCast(cl8));

            if (cl8 <= @as(u8, HUFFMAN_TABLE_BITS)) {
                const step: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(cl8));
                var idx: usize = @intCast(rcode);
                while (idx < HUFFMAN_TABLE_SIZE) : (idx += step) {
                    table.root[idx] = Entry{ .bits = cl8, .value = @intCast(sym) };
                }
            } else {
                const root_idx: usize = @intCast(rcode & 0xFF);
                const extra_code: u32 = rcode >> HUFFMAN_TABLE_BITS;
                const extra_bits: u8 = cl8 - @as(u8, HUFFMAN_TABLE_BITS);
                const subtable_size: u32 = @as(u32, 1) << @as(u5, @intCast(subtable_max_extra[root_idx]));
                const step: u32 = @as(u32, 1) << @as(u5, @intCast(extra_bits));
                var sub_idx: u32 = extra_code;
                while (sub_idx < subtable_size) : (sub_idx += step) {
                    subtables[@as(usize, subtable_offsets[root_idx]) + @as(usize, @intCast(sub_idx))] = Entry{
                        .bits = extra_bits,
                        .value = @intCast(sym),
                    };
                }

                const current_root = table.root[root_idx];
                if (current_root.bits <= @as(u8, HUFFMAN_TABLE_BITS)) {
                    table.root[root_idx] = Entry{
                        .bits = @as(u8, HUFFMAN_TABLE_BITS) + subtable_max_extra[root_idx],
                        .value = @intCast(subtable_offsets[root_idx]),
                    };
                }
            }
        }
    }

    return table;
}

/// Build a single-symbol Huffman table that always returns the given symbol
/// without consuming any bits from the stream.
pub fn buildSingleSymbol(allocator: std.mem.Allocator, symbol: u16) !HuffmanTable {
    const subtables = try allocator.alloc(Entry, 0);
    var table = HuffmanTable{
        .allocator = allocator,
        .root = [_]Entry{.{ .bits = 0, .value = symbol }} ** HUFFMAN_TABLE_SIZE,
        .subtables = subtables,
        .is_single_symbol = true,
    };
    _ = &table;
    return table;
}

test "buildTable simple 2-symbol" {
    const allocator = std.testing.allocator;
    const code_lengths = [_]u8{ 1, 1 };
    var table = try buildTable(allocator, &code_lengths);
    defer table.deinit();

    var br0 = BitReader.init(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u16, 0), try table.readSymbol(&br0));

    var br1 = BitReader.init(&[_]u8{0x01});
    try std.testing.expectEqual(@as(u16, 1), try table.readSymbol(&br1));
}

test "buildTable 4-symbol equal lengths" {
    const allocator = std.testing.allocator;
    const code_lengths = [_]u8{ 2, 2, 2, 2 };
    var table = try buildTable(allocator, &code_lengths);
    defer table.deinit();

    var br0 = BitReader.init(&[_]u8{0b00000000});
    try std.testing.expectEqual(@as(u16, 0), try table.readSymbol(&br0));

    var br1 = BitReader.init(&[_]u8{0b00000010});
    try std.testing.expectEqual(@as(u16, 1), try table.readSymbol(&br1));
}

test "buildTable uneven lengths" {
    const allocator = std.testing.allocator;
    const code_lengths = [_]u8{ 1, 2, 2 };
    var table = try buildTable(allocator, &code_lengths);
    defer table.deinit();

    var br0 = BitReader.init(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u16, 0), try table.readSymbol(&br0));

    var br1 = BitReader.init(&[_]u8{0b00000001});
    try std.testing.expectEqual(@as(u16, 1), try table.readSymbol(&br1));

    var br2 = BitReader.init(&[_]u8{0b00000011});
    try std.testing.expectEqual(@as(u16, 2), try table.readSymbol(&br2));
}

test "buildTable multiple reads" {
    const allocator = std.testing.allocator;
    const code_lengths = [_]u8{ 1, 1 };
    var table = try buildTable(allocator, &code_lengths);
    defer table.deinit();

    var br = BitReader.init(&[_]u8{0b01010101});
    try std.testing.expectEqual(@as(u16, 1), try table.readSymbol(&br));
    try std.testing.expectEqual(@as(u16, 0), try table.readSymbol(&br));
    try std.testing.expectEqual(@as(u16, 1), try table.readSymbol(&br));
    try std.testing.expectEqual(@as(u16, 0), try table.readSymbol(&br));
}
