const std = @import("std");

pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data, .byte_pos = 0, .bit_pos = 0 };
    }

    /// Read n_bits (0-24) from the stream, LSB first.
    pub fn readBits(self: *BitReader, n_bits: u5) !u32 {
        var result: u32 = 0;
        var bits_filled: u5 = 0;
        while (bits_filled < n_bits) {
            if (self.byte_pos >= self.data.len) return error.EndOfStream;
            const bits_available: u5 = 8 - @as(u5, self.bit_pos);
            const bits_needed: u5 = n_bits - bits_filled;
            const bits_from_byte: u5 = if (bits_available < bits_needed) bits_available else bits_needed;
            const mask: u32 = (@as(u32, 1) << bits_from_byte) - 1;
            result |= ((@as(u32, self.data[self.byte_pos]) >> @as(u5, self.bit_pos)) & mask) << bits_filled;
            const new_bit_pos = @as(u5, self.bit_pos) + bits_from_byte;
            self.bit_pos = if (new_bit_pos == 8) 0 else @intCast(new_bit_pos);
            bits_filled += bits_from_byte;
            if (self.bit_pos == 0) {
                self.byte_pos += 1;
            }
        }
        return result;
    }

    /// Read exactly 1 bit.
    pub fn readBit(self: *BitReader) !u1 {
        const v = try self.readBits(1);
        return @truncate(v);
    }

    /// Peek n bits without consuming them.
    pub fn peekBits(self: *BitReader, n_bits: u5) !u32 {
        const saved = self.*;
        const result = try self.readBits(n_bits);
        self.* = saved;
        return result;
    }

    /// Consume n bits (they must already have been peeked).
    pub fn consumeBits(self: *BitReader, n_bits: u5) void {
        var remaining = n_bits;
        while (remaining > 0) {
            if (self.byte_pos >= self.data.len) return;
            const bits_available: u5 = 8 - @as(u5, self.bit_pos);
            const consume: u5 = if (bits_available < remaining) bits_available else remaining;
            const new_bit_pos = @as(u5, self.bit_pos) + consume;
            self.bit_pos = if (new_bit_pos == 8) 0 else @intCast(new_bit_pos);
            remaining -= consume;
            if (self.bit_pos == 0) {
                self.byte_pos += 1;
            }
        }
    }

    /// Align to next byte boundary.
    pub fn alignToByteBoundary(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.byte_pos += 1;
            self.bit_pos = 0;
        }
    }

    /// Read bytes directly (must be at byte boundary).
    pub fn readBytes(self: *BitReader, dest: []u8) !void {
        std.debug.assert(self.bit_pos == 0);
        if (self.byte_pos + dest.len > self.data.len) return error.EndOfStream;
        @memcpy(dest, self.data[self.byte_pos..][0..dest.len]);
        self.byte_pos += dest.len;
    }

    pub fn isFinished(self: *const BitReader) bool {
        return self.byte_pos >= self.data.len;
    }

    pub fn getRemainingBytes(self: *const BitReader) usize {
        if (self.byte_pos >= self.data.len) return 0;
        return self.data.len - self.byte_pos - (if (self.bit_pos > 0) @as(usize, 1) else 0);
    }
};

test "readBits basic" {
    var br = BitReader.init(&[_]u8{0xB5}); // 0b10110101
    try std.testing.expectEqual(@as(u32, 1), try br.readBits(1));
    try std.testing.expectEqual(@as(u32, 0), try br.readBits(1));
    try std.testing.expectEqual(@as(u32, 5), try br.readBits(3));
    try std.testing.expectEqual(@as(u32, 5), try br.readBits(3));
}

test "readBits across byte boundary" {
    var br = BitReader.init(&[_]u8{ 0xFF, 0x00 });
    try std.testing.expectEqual(@as(u32, 0x0F), try br.readBits(4));
    try std.testing.expectEqual(@as(u32, 0x0F), try br.readBits(4));
    try std.testing.expectEqual(@as(u32, 0x00), try br.readBits(8));
}

test "readBits multi-byte" {
    var br = BitReader.init(&[_]u8{ 0x05, 0x00 });
    try std.testing.expectEqual(@as(u32, 5), try br.readBits(16));
}

test "readBits end of stream" {
    var br = BitReader.init(&[_]u8{0xFF});
    _ = try br.readBits(8);
    try std.testing.expectError(error.EndOfStream, br.readBits(1));
}

test "alignToByteBoundary" {
    var br = BitReader.init(&[_]u8{ 0xAB, 0xCD });
    _ = try br.readBits(3);
    br.alignToByteBoundary();
    try std.testing.expectEqual(@as(u32, 0xCD), try br.readBits(8));
}

test "readBytes" {
    var br = BitReader.init(&[_]u8{ 0x01, 0x02, 0x03 });
    var buf: [2]u8 = undefined;
    try br.readBytes(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, &buf);
    try std.testing.expectEqual(@as(u32, 0x03), try br.readBits(8));
}

test "isFinished" {
    var br = BitReader.init(&[_]u8{0x01});
    try std.testing.expect(!br.isFinished());
    _ = try br.readBits(8);
    try std.testing.expect(br.isFinished());
}

test "peekBits does not consume" {
    var br = BitReader.init(&[_]u8{0xAB});
    const peeked = try br.peekBits(4);
    const read = try br.readBits(4);
    try std.testing.expectEqual(peeked, read);
}
