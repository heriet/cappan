const std = @import("std");
const cappan_core = @import("cappan_core");
const writer = @import("../writer.zig");

const Group = struct {
    start_char_code: u32,
    end_char_code: u32,
    start_glyph_id: u32,
};

pub fn buildCmap(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    mapping: []const u16,
    font: cappan_core.font.Font,
) ![]u8 {
    const Pair = struct { cp: u32, gid: u32 };
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);

    for (codepoints) |cp| {
        const old_id = font.getGlyphId(@intCast(cp)) catch continue;
        if (old_id == 0) continue;
        const new_id = if (old_id < mapping.len) mapping[old_id] else 0;
        if (new_id == 0) continue;
        try pairs.append(allocator, .{ .cp = @intCast(cp), .gid = new_id });
    }

    std.sort.block(Pair, pairs.items, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.cp < b.cp;
        }
    }.lessThan);

    var groups = std.ArrayList(Group).empty;
    defer groups.deinit(allocator);

    var i: usize = 0;
    while (i < pairs.items.len) {
        const start_cp = pairs.items[i].cp;
        const start_gid = pairs.items[i].gid;
        var end_cp = start_cp;
        var j = i + 1;
        while (j < pairs.items.len) {
            const expected_cp = end_cp + 1;
            const expected_gid = start_gid + (expected_cp - start_cp);
            if (pairs.items[j].cp == expected_cp and pairs.items[j].gid == expected_gid) {
                end_cp = expected_cp;
                j += 1;
            } else {
                break;
            }
        }
        try groups.append(allocator, .{
            .start_char_code = start_cp,
            .end_char_code = end_cp,
            .start_glyph_id = start_gid,
        });
        i = j;
    }

    const num_groups: u32 = @intCast(groups.items.len);
    const subtable_len: u32 = 16 + 12 * num_groups;
    const total_len: usize = @intCast(4 + 8 + subtable_len);
    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);
    @memset(buf, 0);

    var off: usize = 0;
    writer.writeU16BE(buf, off, 0); off += 2;
    writer.writeU16BE(buf, off, 1); off += 2;
    writer.writeU16BE(buf, off, 3); off += 2;
    writer.writeU16BE(buf, off, 10); off += 2;
    writer.writeU32BE(buf, off, 12); off += 4;
    writer.writeU16BE(buf, off, 12); off += 2;
    writer.writeU16BE(buf, off, 0); off += 2;
    writer.writeU32BE(buf, off, subtable_len); off += 4;
    writer.writeU32BE(buf, off, 0); off += 4;
    writer.writeU32BE(buf, off, num_groups); off += 4;

    for (groups.items) |g| {
        writer.writeU32BE(buf, off, g.start_char_code); off += 4;
        writer.writeU32BE(buf, off, g.end_char_code); off += 4;
        writer.writeU32BE(buf, off, g.start_glyph_id); off += 4;
    }

    return buf;
}
