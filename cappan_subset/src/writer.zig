const std = @import("std");

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
