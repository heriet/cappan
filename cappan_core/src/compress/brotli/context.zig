const std = @import("std");

/// Literal context modes (RFC 7932 §7.3)
pub const ContextMode = enum(u2) {
    lsb6 = 0,
    msb6 = 1,
    utf8 = 2,
    signed = 3,
};

/// Look-up table for UTF-8 context mode (p1 contribution)
const kLut0 = [256]u8{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  4,  4,  0,  0,  4,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    8,  12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
    44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
    12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
    52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
    12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
    60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12, 0,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
};

/// Look-up table for UTF-8 context mode (p2 contribution)
const kLut1 = [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
    1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
};

/// Look-up table for Signed context mode
const kLut2 = [256]u8{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7,
};

/// Compute the literal context ID (0-63) given context mode and two preceding bytes.
/// p1 = previous byte, p2 = byte before p1.
pub fn literalContextId(mode: ContextMode, p1: u8, p2: u8) u8 {
    return switch (mode) {
        .lsb6 => p1 & 0x3F,
        .msb6 => p1 >> 2,
        .utf8 => kLut0[p1] | kLut1[p2],
        .signed => (kLut2[p1] << 3) | kLut2[p2],
    };
}

/// Compute the distance context ID (0-3) from a copy length.
/// Defined as min(copy_length - 2, 3).
pub fn distanceContextId(copy_length: u32) u8 {
    const diff = copy_length -| 2;
    return @intCast(@min(diff, 3));
}

// ── Unit tests ────────────────────────────────────────────────────────────────

test "literalContextId lsb6" {
    // LSB6: returns lowest 6 bits of p1; p2 is ignored
    try std.testing.expectEqual(@as(u8, 0x00), literalContextId(.lsb6, 0x00, 0xFF));
    try std.testing.expectEqual(@as(u8, 0x3F), literalContextId(.lsb6, 0xFF, 0x00));
    try std.testing.expectEqual(@as(u8, 0x01), literalContextId(.lsb6, 0x41, 0x00)); // 'A' & 0x3F = 1
    try std.testing.expectEqual(@as(u8, 0x3F), literalContextId(.lsb6, 0x7F, 0xAB)); // 0x7F & 0x3F = 0x3F
}

test "literalContextId msb6" {
    // MSB6: returns top 6 bits of p1 (p1 >> 2); p2 is ignored
    try std.testing.expectEqual(@as(u8, 0x00), literalContextId(.msb6, 0x00, 0xFF));
    try std.testing.expectEqual(@as(u8, 0x3F), literalContextId(.msb6, 0xFF, 0x00));
    try std.testing.expectEqual(@as(u8, 0x10), literalContextId(.msb6, 0x41, 0x00)); // 0x41 >> 2 = 0x10
    try std.testing.expectEqual(@as(u8, 0x1F), literalContextId(.msb6, 0x7F, 0xAB)); // 0x7F >> 2 = 0x1F
}

test "literalContextId utf8" {
    // UTF8: kLut0[p1] | kLut1[p2]
    // kLut0[0] = 0, kLut1[0] = 0 -> 0
    try std.testing.expectEqual(@as(u8, 0), literalContextId(.utf8, 0, 0));
    // kLut0['a'=0x61] = 56, kLut1[' '=0x20] = 0 -> 56
    try std.testing.expectEqual(@as(u8, 56), literalContextId(.utf8, 'a', ' '));
    // kLut0['A'=0x41] = 48, kLut1['0'=0x30] = 2 -> 50
    try std.testing.expectEqual(@as(u8, 50), literalContextId(.utf8, 'A', '0'));
}

test "literalContextId signed" {
    // Signed: (kLut2[p1] << 3) | kLut2[p2]
    // kLut2[0] = 0, kLut2[0] = 0 -> 0
    try std.testing.expectEqual(@as(u8, 0), literalContextId(.signed, 0, 0));
    // kLut2[1] = 1, kLut2[1] = 1 -> (1<<3)|1 = 9
    try std.testing.expectEqual(@as(u8, 9), literalContextId(.signed, 1, 1));
    // kLut2[0x10=16] = 2, kLut2[0x10=16] = 2 -> (2<<3)|2 = 18
    try std.testing.expectEqual(@as(u8, 18), literalContextId(.signed, 0x10, 0x10));
    // kLut2[0x40=64] = 3, kLut2[0] = 0 -> (3<<3)|0 = 24
    try std.testing.expectEqual(@as(u8, 24), literalContextId(.signed, 0x40, 0));
    // kLut2[0xFF=255] = 7, kLut2[0xFF=255] = 7 -> (7<<3)|7 = 63
    try std.testing.expectEqual(@as(u8, 63), literalContextId(.signed, 0xFF, 0xFF));
}

test "distanceContextId" {
    // min(copy_length - 2, 3)
    try std.testing.expectEqual(@as(u8, 0), distanceContextId(2)); // 2-2=0, min(0,3)=0
    try std.testing.expectEqual(@as(u8, 1), distanceContextId(3)); // 3-2=1
    try std.testing.expectEqual(@as(u8, 2), distanceContextId(4)); // 4-2=2
    try std.testing.expectEqual(@as(u8, 3), distanceContextId(5)); // 5-2=3
    try std.testing.expectEqual(@as(u8, 3), distanceContextId(6)); // 6-2=4, min(4,3)=3
    try std.testing.expectEqual(@as(u8, 3), distanceContextId(100));
}
