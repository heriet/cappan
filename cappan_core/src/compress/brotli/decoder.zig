const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;
const huffman = @import("huffman.zig");
const HuffmanTable = huffman.HuffmanTable;
const context = @import("context.zig");
const dictionary = @import("dictionary.zig");

pub const BrotliError = error{
    InvalidStream,
    InvalidWindowBits,
    InvalidMetaBlockHeader,
    InvalidPrefixCode,
    InvalidBlockType,
    InvalidDistance,
    InvalidDictionary,
    RingBufferOverflow,
    OutputTooLarge,
    EndOfStream,
    OutOfMemory,
};

const MAX_OUTPUT_SIZE: usize = 256 * 1024 * 1024; // 256 MB

// ── Insert/Copy length tables (RFC 7932 §5) ─────────────────────────────────

const insert_length_n_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
const insert_length_offset = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };

const copy_length_n_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
const copy_length_offset = [24]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };

// ── Command code block layout (RFC 7932 §5) ─────────────────────────────────

const cmd_insert_base = [11]u8{ 0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16 };
const cmd_copy_base = [11]u8{ 0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16 };

// ── Block count decoding table (RFC 7932 §6) ────────────────────────────────

const block_count_extra_bits = [26]u5{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };
const block_count_offset = [26]u32{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };

// ── Block type tracking ─────────────────────────────────────────────────────

const BlockState = struct {
    nbltypes: u32,
    current_type: u32,
    prev_type: u32,
    block_count: u32,
    type_tree: ?HuffmanTable,
    count_tree: ?HuffmanTable,

    fn init() BlockState {
        return .{
            .nbltypes = 1,
            .current_type = 0,
            .prev_type = 1,
            .block_count = 0,
            .type_tree = null,
            .count_tree = null,
        };
    }

    fn deinit(self: *BlockState) void {
        if (self.type_tree) |*t| t.deinit();
        if (self.count_tree) |*t| t.deinit();
    }
};

// ── Main decompress function ────────────────────────────────────────────────

/// Decompress a complete Brotli-compressed stream.
/// Returns the decompressed data. Caller owns the returned slice.
pub fn decompress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var reader = BitReader.init(input);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // Read WBITS (window size)
    const wbits = try readWBits(&reader);
    const window_size: u32 = (@as(u32, 1) << @as(u5, @intCast(wbits))) - 16;

    // Meta-block loop
    while (true) {
        const is_last = try reader.readBit();

        if (is_last == 1) {
            const is_last_empty = try reader.readBit();
            if (is_last_empty == 1) break; // end of stream
        }

        const mnibbles_raw = try reader.readBits(2);

        if (mnibbles_raw == 3) {
            // MNIBBLES=3: empty/metadata meta-block
            try handleEmptyMetaBlock(&reader, is_last);
            if (is_last == 1) break;
            continue;
        }

        const nibble_count: u5 = @intCast(mnibbles_raw + 4); // 4, 5, or 6 nibbles
        const mlen_bits: u5 = nibble_count * 4;
        const mlen = (try reader.readBits(mlen_bits)) + 1;

        if (is_last == 0) {
            const is_uncompressed = try reader.readBit();
            if (is_uncompressed == 1) {
                reader.alignToByteBoundary();
                // Copy MLEN raw bytes to output
                if (output.items.len + mlen > MAX_OUTPUT_SIZE) return error.OutputTooLarge;
                try output.ensureTotalCapacity(allocator, output.items.len + mlen);
                const dest = output.addManyAsSliceAssumeCapacity(mlen);
                try reader.readBytes(dest);
                continue;
            }
        }

        // Compressed meta-block
        try decodeCompressedMetaBlock(allocator, &reader, &output, mlen, window_size);
        if (output.items.len > MAX_OUTPUT_SIZE) return error.OutputTooLarge;

        if (is_last == 1) break;
    }

    // Check filler bits are zero (RFC 7932: filler bits must be 0)
    if (reader.bit_pos != 0) {
        const remaining_bits: u5 = 8 - @as(u5, reader.bit_pos);
        const filler = try reader.readBits(remaining_bits);
        if (filler != 0) return BrotliError.InvalidStream;
    }

    // Check no trailing bytes after end of stream
    if (reader.byte_pos < reader.data.len) return BrotliError.InvalidStream;

    return output.toOwnedSlice(allocator);
}

// ── WBITS decoding ──────────────────────────────────────────────────────────

fn readWBits(reader: *BitReader) !u32 {
    const first_bit = try reader.readBit();
    if (first_bit == 0) return 16;

    const n = try reader.readBits(3);
    if (n != 0) return 17 + n; // 18-24

    const n2 = try reader.readBits(3);
    if (n2 == 0) return 17;

    const wbits = 8 + n2;
    if (wbits < 10) return BrotliError.InvalidWindowBits;
    return wbits; // 10-15
}

// ── Empty meta-block handling ───────────────────────────────────────────────

fn handleEmptyMetaBlock(reader: *BitReader, is_last: u1) !void {
    if (is_last == 0) {
        // Read MSKIPBYTES (2 bits)
        const mskipbytes = try reader.readBits(2);
        reader.alignToByteBoundary();
        if (mskipbytes > 0) {
            // Read skip_length and skip that many bytes
            var skip_length: u32 = 0;
            var i: u32 = 0;
            while (i < mskipbytes) : (i += 1) {
                const byte_val = try reader.readBits(8);
                skip_length |= byte_val << @as(u5, @intCast(i * 8));
            }
            // Skip skip_length bytes
            if (skip_length > 0) {
                var j: u32 = 0;
                while (j < skip_length) : (j += 1) {
                    _ = try reader.readBits(8);
                }
            }
        }
    } else {
        // ISLAST with MNIBBLES=3 shouldn't normally happen (ISLASTEMPTY handles it)
        // but handle gracefully
        reader.alignToByteBoundary();
    }
}

// ── Compressed meta-block decoding ──────────────────────────────────────────

fn decodeCompressedMetaBlock(
    allocator: std.mem.Allocator,
    reader: *BitReader,
    output: *std.ArrayList(u8),
    mlen: u32,
    window_size: u32,
) !void {
    // Read block type counts for each category
    var lit_state = BlockState.init();
    defer lit_state.deinit();
    var iac_state = BlockState.init();
    defer iac_state.deinit();
    var dist_state = BlockState.init();
    defer dist_state.deinit();

    lit_state.nbltypes = try readNBLTypes(reader);
    try setupBlockState(allocator, reader, &lit_state);

    iac_state.nbltypes = try readNBLTypes(reader);
    try setupBlockState(allocator, reader, &iac_state);

    dist_state.nbltypes = try readNBLTypes(reader);
    try setupBlockState(allocator, reader, &dist_state);

    // Distance parameters
    const npostfix: u2 = @intCast(try reader.readBits(2));
    const ndirect_hbits = try reader.readBits(4);
    const ndirect: u32 = ndirect_hbits << @as(u5, npostfix);

    // Distance alphabet size
    const dist_alphabet_size: u32 = 16 + ndirect + (@as(u32, 48) << @as(u5, npostfix));

    // Context modes for literal block types
    var context_modes = try allocator.alloc(context.ContextMode, lit_state.nbltypes);
    defer allocator.free(context_modes);
    for (0..lit_state.nbltypes) |i| {
        const mode_val = try reader.readBits(2);
        context_modes[i] = @enumFromInt(mode_val);
    }

    // Read literal context map
    const lit_ntrees = try readContextMap(allocator, reader, lit_state.nbltypes * 64);
    const lit_context_map = lit_ntrees.context_map;
    defer allocator.free(lit_context_map);
    const num_lit_trees = lit_ntrees.num_trees;

    // Read distance context map
    const dist_ntrees = try readContextMap(allocator, reader, dist_state.nbltypes * 4);
    const dist_context_map = dist_ntrees.context_map;
    defer allocator.free(dist_context_map);
    const num_dist_trees = dist_ntrees.num_trees;

    // Read prefix codes for all trees
    // Literal trees
    var lit_trees = try allocator.alloc(HuffmanTable, num_lit_trees);
    var lit_trees_init: usize = 0;
    defer {
        for (lit_trees[0..lit_trees_init]) |*t| t.deinit();
        allocator.free(lit_trees);
    }
    for (0..num_lit_trees) |i| {
        lit_trees[i] = try readPrefixCode(allocator, reader, 256);
        lit_trees_init += 1;
    }

    // Insert&copy trees (one per block type)
    var iac_trees = try allocator.alloc(HuffmanTable, iac_state.nbltypes);
    var iac_trees_init: usize = 0;
    defer {
        for (iac_trees[0..iac_trees_init]) |*t| t.deinit();
        allocator.free(iac_trees);
    }
    for (0..iac_state.nbltypes) |i| {
        iac_trees[i] = try readPrefixCode(allocator, reader, 704);
        iac_trees_init += 1;
    }

    // Distance trees
    var dist_trees = try allocator.alloc(HuffmanTable, num_dist_trees);
    var dist_trees_init: usize = 0;
    defer {
        for (dist_trees[0..dist_trees_init]) |*t| t.deinit();
        allocator.free(dist_trees);
    }
    for (0..num_dist_trees) |i| {
        dist_trees[i] = try readPrefixCode(allocator, reader, dist_alphabet_size);
        dist_trees_init += 1;
    }

    // Distance ring buffer (RFC 7932 §4: last=4, second-to-last=11, third=15, fourth=16)
    var dist_ring = [4]u32{ 4, 11, 15, 16 };

    // Context bytes
    var p1: u8 = 0;
    var p2: u8 = 0;

    var bytes_remaining: u32 = mlen;

    // Command decoding loop
    while (bytes_remaining > 0) {
        // Check insert&copy block boundary
        if (iac_state.block_count == 0) {
            try switchBlockType(reader, &iac_state);
        }
        iac_state.block_count -= 1;

        // Read command code
        const cmd_code = try iac_trees[iac_state.current_type].readSymbol(reader);

        // Decode command code into insert/copy codes and use_last_distance
        const cmd = decodeCommandCode(cmd_code);
        const insert_length = try decodeInsertLength(cmd.insert_code, reader);
        const copy_length = try decodeCopyLength(cmd.copy_code, reader);

        // Process insert (literal bytes)
        var ins_i: u32 = 0;
        while (ins_i < insert_length) : (ins_i += 1) {
            if (bytes_remaining == 0) break;

            if (lit_state.block_count == 0) {
                try switchBlockType(reader, &lit_state);
            }
            lit_state.block_count -= 1;

            // Compute literal context
            const cid = context.literalContextId(context_modes[lit_state.current_type], p1, p2);
            const tree_idx = lit_context_map[64 * lit_state.current_type + cid];

            const literal = try lit_trees[tree_idx].readSymbol(reader);
            const byte_val: u8 = @intCast(literal);
            try output.append(allocator, byte_val);
            p2 = p1;
            p1 = byte_val;
            bytes_remaining -= 1;
        }

        if (bytes_remaining == 0) break;

        // Process copy (distance + back-reference or dictionary)
        var distance: u32 = undefined;
        var update_ring = false;

        if (cmd.use_last_dist) {
            distance = dist_ring[0];
        } else {
            if (dist_state.block_count == 0) {
                try switchBlockType(reader, &dist_state);
            }
            dist_state.block_count -= 1;

            const dist_cid = context.distanceContextId(copy_length);
            const dist_tree_idx = dist_context_map[4 * dist_state.current_type + dist_cid];

            const dist_code = try dist_trees[dist_tree_idx].readSymbol(reader);
            distance = try decodeDistance(dist_code, &dist_ring, npostfix, ndirect, reader);
            // dist_code=0 means "reuse last distance" - ring should not change
            // (matches C reference: dist_rb_idx compensation for dist_code=0)
            update_ring = (dist_code != 0);
        }

        const max_backward: u32 = @intCast(@min(output.items.len, window_size));

        if (distance <= max_backward) {
            // Back-reference: copy from output
            if (copy_length > bytes_remaining) {
                return BrotliError.InvalidStream;
            }
            try output.ensureUnusedCapacity(allocator, copy_length);
            if (distance >= copy_length) {
                // Non-overlapping: every source byte already existed in `output`
                // before this copy started, so the whole run can be appended in
                // one bulk slice copy instead of byte-by-byte.
                const src_start = output.items.len - distance;
                output.appendSliceAssumeCapacity(output.items[src_start..][0..copy_length]);
                if (copy_length >= 2) {
                    p2 = output.items[output.items.len - 2];
                    p1 = output.items[output.items.len - 1];
                } else if (copy_length == 1) {
                    p2 = p1;
                    p1 = output.items[output.items.len - 1];
                }
            } else {
                // Overlapping (e.g. RLE-style short repeats): later bytes depend
                // on earlier just-appended bytes, so this must stay byte-by-byte.
                var copy_i: u32 = 0;
                while (copy_i < copy_length) : (copy_i += 1) {
                    const src_pos = output.items.len - distance;
                    const byte_val = output.items[src_pos];
                    output.appendAssumeCapacity(byte_val);
                    p2 = p1;
                    p1 = byte_val;
                }
            }
            bytes_remaining -= copy_length;

            if (update_ring) {
                dist_ring[3] = dist_ring[2];
                dist_ring[2] = dist_ring[1];
                dist_ring[1] = dist_ring[0];
                dist_ring[0] = distance;
            }
        } else {
            // Dictionary reference. Range-check the attacker-controlled
            // copy_length (u32) *before* narrowing it to u8, or a value > 255
            // would panic in safe builds / truncate-and-desync elsewhere.
            if (copy_length < 4 or copy_length > 24) return BrotliError.InvalidDictionary;
            const word_len: u8 = @intCast(copy_length);

            const word_id = distance - max_backward - 1;
            const n_words: u32 = @as(u32, 1) << dictionary.kNDBits[word_len - 4];
            const word_index = word_id % n_words;
            const transform_id = word_id / n_words;

            if (transform_id >= dictionary.NUM_TRANSFORMS) return BrotliError.InvalidDictionary;

            const word = dictionary.getWord(word_len, word_index);
            var transformed: [256]u8 = undefined;
            const written = dictionary.applyTransform(word, transform_id, &transformed);

            for (0..written) |wi| {
                try output.append(allocator, transformed[wi]);
            }

            if (written >= 2) {
                p2 = transformed[written - 2];
                p1 = transformed[written - 1];
            } else if (written == 1) {
                p2 = p1;
                p1 = transformed[0];
            }

            // Subtract actual output bytes from remaining
            if (written > bytes_remaining) return BrotliError.InvalidStream;
            bytes_remaining -= @intCast(written);

            // Do NOT update distance ring buffer for dictionary references
        }
    }
}

// ── NBLTYPES reading (RFC 7932 §4) ─────────────────────────────────────────

fn readNBLTypes(reader: *BitReader) !u32 {
    const first_bit = try reader.readBit();
    if (first_bit == 0) return 1;

    const code = try reader.readBits(3);
    if (code == 0) return 2;

    const extra = try reader.readBits(@intCast(code));
    return (@as(u32, 1) << @as(u5, @intCast(code))) + extra + 1;
}

// ── Block state setup ───────────────────────────────────────────────────────

fn setupBlockState(allocator: std.mem.Allocator, reader: *BitReader, state: *BlockState) !void {
    if (state.nbltypes < 2) {
        // Single block type: no trees needed, block_count = max
        state.block_count = std.math.maxInt(u32);
        return;
    }

    // Read prefix code for block types (alphabet = nbltypes + 2)
    state.type_tree = try readPrefixCode(allocator, reader, state.nbltypes + 2);

    // Read prefix code for block counts (alphabet = 26)
    state.count_tree = try readPrefixCode(allocator, reader, 26);

    // Read first block count
    state.block_count = try readBlockCount(reader, &state.count_tree.?);
}

// ── Block type switching ────────────────────────────────────────────────────

fn switchBlockType(reader: *BitReader, state: *BlockState) !void {
    if (state.nbltypes < 2) {
        state.block_count = std.math.maxInt(u32);
        return;
    }

    const type_sym = try state.type_tree.?.readSymbol(reader);
    const new_type = switch (type_sym) {
        0 => state.prev_type,
        1 => (state.current_type + 1) % state.nbltypes,
        else => type_sym - 2,
    };
    state.prev_type = state.current_type;
    state.current_type = new_type;

    state.block_count = try readBlockCount(reader, &state.count_tree.?);
}

// ── Block count decoding ────────────────────────────────────────────────────

fn readBlockCount(reader: *BitReader, count_tree: *const HuffmanTable) !u32 {
    const code = try count_tree.readSymbol(reader);
    const extra = try reader.readBits(block_count_extra_bits[code]);
    return block_count_offset[code] + extra;
}

// ── Command code decoding ───────────────────────────────────────────────────

const CommandDecode = struct {
    insert_code: u8,
    copy_code: u8,
    use_last_dist: bool,
};

fn decodeCommandCode(cmd_code: u16) CommandDecode {
    const block: usize = @intCast(cmd_code / 64);
    const within: u16 = cmd_code % 64;
    const insert_sub: u8 = @intCast((within >> 3) & 7);
    const copy_sub: u8 = @intCast(within & 7);

    return .{
        .insert_code = cmd_insert_base[block] + insert_sub,
        .copy_code = cmd_copy_base[block] + copy_sub,
        .use_last_dist = cmd_code < 128,
    };
}

fn decodeInsertLength(code: u8, reader: *BitReader) !u32 {
    const extra = try reader.readBits(insert_length_n_extra[code]);
    return insert_length_offset[code] + extra;
}

fn decodeCopyLength(code: u8, reader: *BitReader) !u32 {
    const extra = try reader.readBits(copy_length_n_extra[code]);
    return copy_length_offset[code] + extra;
}

// ── Distance decoding (RFC 7932 §4) ────────────────────────────────────────

fn decodeDistance(dist_code: u16, ring: *[4]u32, npostfix: u2, ndirect: u32, reader: *BitReader) !u32 {
    if (dist_code < 16) {
        // Special distances from ring buffer
        if (dist_code < 4) return ring[dist_code];

        const ring_idx: usize = if (dist_code < 10) 0 else 1;
        const base_offset: u16 = if (dist_code < 10) 4 else 10;
        const delta_idx = dist_code - base_offset;
        const is_add = (delta_idx & 1) == 1;
        const delta: u32 = (delta_idx >> 1) + 1;

        if (is_add) {
            return ring[ring_idx] + delta;
        }
        if (ring[ring_idx] <= delta) return BrotliError.InvalidDistance;
        return ring[ring_idx] - delta;
    }

    if (dist_code < 16 + @as(u16, @intCast(ndirect))) {
        // Direct distance
        return @as(u32, dist_code) - 15;
    }

    // Extra-bits distance
    const dcode: u32 = @as(u32, dist_code) - 16 - ndirect;
    const hcode: u32 = dcode >> @as(u5, npostfix);
    const lcode: u32 = dcode & ((@as(u32, 1) << @as(u5, npostfix)) - 1);
    const ndistbits: u5 = @intCast(1 + (hcode >> 1));
    const offset: u32 = ((@as(u32, 2) + (hcode & 1)) << ndistbits) - 4;
    const dextra = try reader.readBits(ndistbits);
    return ((offset + dextra) << @as(u5, npostfix)) + lcode + ndirect + 1;
}

// ── Context map reading (RFC 7932 §7.3) ─────────────────────────────────────

const ContextMapResult = struct {
    context_map: []u8,
    num_trees: u32,
};

fn readContextMap(allocator: std.mem.Allocator, reader: *BitReader, context_map_size: u32) !ContextMapResult {
    if (context_map_size == 0) {
        return .{
            .context_map = try allocator.alloc(u8, 0),
            .num_trees = 1,
        };
    }

    // Read NTREES
    const num_trees = try readNBLTypes(reader);

    if (num_trees == 1) {
        // All zeros
        const cm = try allocator.alloc(u8, context_map_size);
        @memset(cm, 0);
        return .{ .context_map = cm, .num_trees = num_trees };
    }

    // RLEMAX
    var rlemax: u32 = 0;
    const rlemax_bit = try reader.readBit();
    if (rlemax_bit == 1) {
        rlemax = (try reader.readBits(4)) + 1;
    }

    // Build prefix code for context map alphabet
    const alphabet_size = num_trees + rlemax;
    var tree = try readPrefixCode(allocator, reader, alphabet_size);
    defer tree.deinit();

    // Decode context map entries
    const cm = try allocator.alloc(u8, context_map_size);
    errdefer allocator.free(cm);

    var i: u32 = 0;
    while (i < context_map_size) {
        const sym = try tree.readSymbol(reader);

        if (sym == 0) {
            cm[i] = 0;
            i += 1;
        } else if (sym <= @as(u16, @intCast(rlemax))) {
            // RLE zeros: count = (1 << sym) + readBits(sym)
            const sym_u5: u5 = @intCast(sym);
            const reps = (@as(u32, 1) << sym_u5) + (try reader.readBits(sym_u5));
            var j: u32 = 0;
            while (j < reps and i < context_map_size) : (j += 1) {
                cm[i] = 0;
                i += 1;
            }
        } else {
            // Value = sym - rlemax (tree index 1..num_trees-1)
            cm[i] = @intCast(sym - @as(u16, @intCast(rlemax)));
            i += 1;
        }
    }

    // Inverse MTF if bit is set
    const imtf_bit = try reader.readBit();
    if (imtf_bit == 1) {
        inverseMTF(cm);
    }

    return .{ .context_map = cm, .num_trees = num_trees };
}

fn inverseMTF(v: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*m, i| {
        m.* = @intCast(i);
    }
    for (v) |*val| {
        const idx = val.*;
        const value = mtf[idx];
        val.* = value;
        var j: usize = idx;
        while (j > 0) : (j -= 1) {
            mtf[j] = mtf[j - 1];
        }
        mtf[0] = value;
    }
}

// ── Prefix code reading (RFC 7932 §3) ──────────────────────────────────────

fn readPrefixCode(allocator: std.mem.Allocator, reader: *BitReader, alphabet_size: u32) !HuffmanTable {
    const hskip = try reader.readBits(2);
    if (hskip == 1) {
        return readSimplePrefixCode(allocator, reader, alphabet_size);
    } else {
        return readComplexPrefixCode(allocator, reader, alphabet_size, @intCast(hskip));
    }
}

fn readSimplePrefixCode(allocator: std.mem.Allocator, reader: *BitReader, alphabet_size: u32) !HuffmanTable {
    const nsym_minus_1 = try reader.readBits(2);
    const nsym: u32 = nsym_minus_1 + 1;

    // Calculate bits needed to represent alphabet
    const alphabet_bits: u5 = if (alphabet_size <= 1) 0 else ceilLog2(alphabet_size);

    // Read symbol values
    var symbols: [4]u16 = .{ 0, 0, 0, 0 };
    var i: u32 = 0;
    while (i < nsym) : (i += 1) {
        const val = try reader.readBits(alphabet_bits);
        if (val >= alphabet_size) return BrotliError.InvalidPrefixCode;
        symbols[i] = @intCast(val);
    }

    if (nsym == 1) {
        // Single symbol: build table that returns it without consuming bits
        return huffman.buildSingleSymbol(allocator, symbols[0]);
    }

    // Assign code lengths based on nsym
    const code_lengths = try allocator.alloc(u8, alphabet_size);
    defer allocator.free(code_lengths);
    @memset(code_lengths, 0);

    switch (nsym) {
        2 => {
            // Sort symbols
            if (symbols[0] > symbols[1]) {
                const tmp = symbols[0];
                symbols[0] = symbols[1];
                symbols[1] = tmp;
            }
            code_lengths[symbols[0]] = 1;
            code_lengths[symbols[1]] = 1;
        },
        3 => {
            code_lengths[symbols[0]] = 1;
            code_lengths[symbols[1]] = 2;
            code_lengths[symbols[2]] = 2;
        },
        4 => {
            const tree_select = try reader.readBit();
            if (tree_select == 0) {
                // All length 2
                for (symbols[0..4]) |s| {
                    code_lengths[s] = 2;
                }
            } else {
                // Lengths 1, 2, 3, 3
                code_lengths[symbols[0]] = 1;
                code_lengths[symbols[1]] = 2;
                code_lengths[symbols[2]] = 3;
                code_lengths[symbols[3]] = 3;
            }
        },
        else => return BrotliError.InvalidPrefixCode,
    }

    return huffman.buildTable(allocator, code_lengths);
}

fn readComplexPrefixCode(allocator: std.mem.Allocator, reader: *BitReader, alphabet_size: u32, hskip: u2) !HuffmanTable {
    var cl_code_lengths: [18]u8 = .{0} ** 18;

    var space: i32 = 32;
    var num_codes: u32 = 0;

    var ci: u5 = hskip;
    while (ci < 18) : (ci += 1) {
        const v = try reader.peekBits(4);
        const cl_len = huffman.kCodeLengthPrefixLength[v];
        const cl_val = huffman.kCodeLengthPrefixValue[v];
        reader.consumeBits(@intCast(cl_len));

        cl_code_lengths[huffman.kCodeLengthCodeOrder[ci]] = cl_val;
        if (cl_val != 0) {
            space -= @as(i32, 32) >> @as(u5, @intCast(cl_val));
            num_codes += 1;
            if (space <= 0) break;
        }
    }

    if (space != 0 and num_codes != 1) {
        return BrotliError.InvalidPrefixCode;
    }

    // Build Huffman table for the code-length alphabet
    var cl_table = try huffman.buildTable(allocator, &cl_code_lengths);
    defer cl_table.deinit();

    // Decode actual symbol code lengths using cumulative repeat logic (RFC 7932 §3.5).
    // Consecutive sym=16 or sym=17 accumulate: each repeat modifies the
    // previous repeat count rather than starting fresh.
    const code_lengths = try allocator.alloc(u8, alphabet_size);
    defer allocator.free(code_lengths);
    @memset(code_lengths, 0);

    // Use unsigned space to match reference decoder behavior (wraps on underflow)
    var cl_space: u32 = 32768;
    var prev_code_len: u8 = 8;
    var repeat: u32 = 0;
    var repeat_code_len: u8 = 0;

    var idx: u32 = 0;
    while (idx < alphabet_size and cl_space > 0) {
        const sym = try cl_table.readSymbol(reader);

        if (sym < 16) {
            // Literal code length (ProcessSingleCodeLength)
            repeat = 0;
            code_lengths[idx] = @intCast(sym);
            if (sym != 0) {
                prev_code_len = @intCast(sym);
                cl_space -%= @as(u32, 32768) >> @as(u5, @intCast(sym));
            }
            idx += 1;
        } else if (sym == 16 or sym == 17) {
            // ProcessRepeatedCodeLength (RFC 7932 §3.5 cumulative repeat)
            const extra_bits: u5 = if (sym == 16) 2 else 3;
            const new_len: u8 = if (sym == 16) prev_code_len else 0;
            const repeat_delta_raw = try reader.readBits(extra_bits);

            if (repeat_code_len != new_len) {
                repeat = 0;
                repeat_code_len = new_len;
            }

            const old_repeat = repeat;
            if (repeat > 0) {
                repeat = (repeat -% 2) << extra_bits;
            }
            repeat +%= repeat_delta_raw + 3;

            // Clamp repeat_delta to not exceed alphabet_size (matches C reference decoder)
            const actual_delta = @min(repeat -% old_repeat, alphabet_size - idx);

            if (repeat_code_len != 0) {
                var j: u32 = 0;
                while (j < actual_delta) : (j += 1) {
                    code_lengths[idx] = repeat_code_len;
                    idx += 1;
                }
                cl_space -%= actual_delta << @as(u5, @intCast(@as(u32, 15) - @as(u32, repeat_code_len)));
            } else {
                idx += actual_delta;
            }
        } else {
            return BrotliError.InvalidPrefixCode;
        }
    }

    // Check for single-symbol case (only one nonzero code length)
    if (cl_space != 0) {
        var nonzero_count: u32 = 0;
        var single_symbol: u16 = 0;
        for (code_lengths[0..alphabet_size], 0..) |cl, si| {
            if (cl != 0) {
                nonzero_count += 1;
                single_symbol = @intCast(si);
            }
        }
        if (nonzero_count == 1) {
            return huffman.buildSingleSymbol(allocator, single_symbol);
        }
        // Oversubscribed codes: the C reference decoder allows this and
        // builds the table anyway. The table builder handles it correctly.
    }

    return huffman.buildTable(allocator, code_lengths[0..alphabet_size]);
}

// ── Utility ─────────────────────────────────────────────────────────────────

fn ceilLog2(n: u32) u5 {
    if (n <= 1) return 0;
    var val = n - 1;
    var bits: u5 = 0;
    while (val > 0) {
        val >>= 1;
        bits += 1;
    }
    return bits;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "dictionary reference with copy_length > 255 errors instead of panicking" {
    // Craft a stream whose single insert&copy command decodes to a large copy
    // length (326) with a distance that lands in the static-dictionary range.
    // The old code narrowed copy_length to u8 *before* range-checking it, so a
    // value > 255 panicked (@intCast) in safe builds. It must now return
    // InvalidDictionary.
    const Writer = struct {
        buf: [16]u8 = @splat(0),
        byte: usize = 0,
        bit: u3 = 0,
        fn put(self: *@This(), value: u32, n: u5) void {
            var i: u5 = 0;
            while (i < n) : (i += 1) {
                const b: u32 = (value >> i) & 1;
                if (b == 1) self.buf[self.byte] |= (@as(u8, 1) << self.bit);
                if (self.bit == 7) {
                    self.bit = 0;
                    self.byte += 1;
                } else {
                    self.bit += 1;
                }
            }
        }
    };
    var w = Writer{};
    w.put(0, 1); // WBITS first bit -> window 16
    w.put(1, 1); // ISLAST = 1
    w.put(0, 1); // ISLASTEMPTY = 0
    w.put(0, 2); // MNIBBLES = 0 -> 4 nibbles
    w.put(0, 16); // MLEN raw 0 -> mlen = 1
    w.put(0, 1); // literal NBLTYPES -> 1
    w.put(0, 1); // insert&copy NBLTYPES -> 1
    w.put(0, 1); // distance NBLTYPES -> 1
    w.put(0, 2); // NPOSTFIX = 0
    w.put(0, 4); // NDIRECT hbits = 0
    w.put(0, 2); // context mode for literal type 0
    w.put(0, 1); // literal context map NTREES -> 1 (all zeros)
    w.put(0, 1); // distance context map NTREES -> 1 (all zeros)
    // Literal prefix code (alphabet 256): simple, single symbol 0
    w.put(1, 2); // HSKIP = 1 -> simple
    w.put(0, 2); // NSYM-1 = 0 -> 1 symbol
    w.put(0, 8); // symbol value 0
    // Insert&copy prefix code (alphabet 704): simple, single symbol 388.
    // cmd 388 -> insert_code 0 (len 0), copy_code 20 (len 326 + 8 extra bits).
    w.put(1, 2);
    w.put(0, 2);
    w.put(388, 10);
    // Distance prefix code (alphabet 64): simple, single symbol 0 (-> ring[0]=4)
    w.put(1, 2);
    w.put(0, 2);
    w.put(0, 6);
    // copy_code 20 carries 8 extra bits; 0 -> copy_length = 326
    w.put(0, 8);

    const allocator = std.testing.allocator;
    try std.testing.expectError(BrotliError.InvalidDictionary, decompress(allocator, &w.buf));
}

test "decompress Hello, World!" {
    const allocator = std.testing.allocator;
    // Brotli-compressed encoding of "Hello, World!\n"
    const compressed = [_]u8{
        0x8f, 0x06, 0x80, 0x48, 0x65, 0x6c, 0x6c, 0x6f,
        0x2c, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21,
        0x0a, 0x03,
    };
    const result = try decompress(allocator, &compressed);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello, World!\n", result);
}

test "decompress empty stream" {
    const allocator = std.testing.allocator;
    // Empty Brotli stream: WBITS=16 (bit 0 = 0), ISLAST=1, ISLASTEMPTY=1
    // Byte: 0b00000110 = 0x06
    // bit 0: 0 -> WBITS=16
    // bit 1: 1 -> ISLAST=1
    // bit 2: 1 -> ISLASTEMPTY=1
    const compressed = [_]u8{0x06};
    const result = try decompress(allocator, &compressed);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "ceilLog2" {
    try std.testing.expectEqual(@as(u5, 0), ceilLog2(1));
    try std.testing.expectEqual(@as(u5, 1), ceilLog2(2));
    try std.testing.expectEqual(@as(u5, 2), ceilLog2(3));
    try std.testing.expectEqual(@as(u5, 2), ceilLog2(4));
    try std.testing.expectEqual(@as(u5, 8), ceilLog2(256));
    try std.testing.expectEqual(@as(u5, 9), ceilLog2(257));
}

test "decodeCommandCode basic" {
    // cmd_code 0: block 0, within 0, insert_base=0, copy_base=0
    const cmd0 = decodeCommandCode(0);
    try std.testing.expectEqual(@as(u8, 0), cmd0.insert_code);
    try std.testing.expectEqual(@as(u8, 0), cmd0.copy_code);
    try std.testing.expect(cmd0.use_last_dist);

    // cmd_code 128: block 2, within 0, insert_base=0, copy_base=0, not last dist
    const cmd128 = decodeCommandCode(128);
    try std.testing.expectEqual(@as(u8, 0), cmd128.insert_code);
    try std.testing.expectEqual(@as(u8, 0), cmd128.copy_code);
    try std.testing.expect(!cmd128.use_last_dist);
}

test "inverseMTF" {
    var data = [_]u8{ 1, 0, 0 };
    inverseMTF(&data);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1 }, &data);
}

test "decompress 100 a's (compressed)" {
    const allocator = std.testing.allocator;
    const compressed = [_]u8{ 0x1b, 0x63, 0x00, 0xf8, 0x25, 0xc2, 0x02, 0xb1, 0x40, 0xa0, 0x03 };
    const result = try decompress(allocator, &compressed);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 100), result.len);
    for (result) |b| try std.testing.expectEqual(@as(u8, 'a'), b);
}

test "decompress repeated Hello (compressed)" {
    const allocator = std.testing.allocator;
    const compressed = [_]u8{ 0x1b, 0x22, 0x00, 0xf8, 0x8d, 0xd4, 0x4e, 0xf5, 0xd4, 0xa2, 0x4a, 0x36, 0xa4, 0xb7, 0x02, 0x29, 0x0b, 0x7a, 0xe2, 0x00, 0x2f, 0x03 };
    const result = try decompress(allocator, &compressed);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello Hello Hello Hello Hello Hello", result);
}
