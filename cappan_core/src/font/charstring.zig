const std = @import("std");
const glyph_mod = @import("glyph.zig");
const cff_mod = @import("table/cff.zig");

pub const CharstringError = error{
    StackOverflow,
    StackUnderflow,
    InvalidSubroutine,
    CallDepthExceeded,
    InvalidCff,
    UnexpectedEof,
    OutOfMemory,
};

const MAX_STACK = 48;
const MAX_CALL_DEPTH = 10;
const MAX_HINTS: usize = 96;

pub fn interpret(
    allocator: std.mem.Allocator,
    charstring_data: []const u8,
    global_subrs: cff_mod.Index,
    local_subrs: cff_mod.Index,
) !glyph_mod.GlyphOutline {
    var interp = Interpreter.init(allocator, global_subrs, local_subrs);
    defer interp.deinit();
    try interp.execute(charstring_data, 0);
    return interp.buildOutline();
}

const Interpreter = struct {
    allocator: std.mem.Allocator,
    stack: [MAX_STACK]f32,
    sp: usize, // stack pointer

    // 描画状態
    x: f32,
    y: f32,
    contours: std.ArrayListUnmanaged(glyph_mod.Contour),
    current_points: std.ArrayListUnmanaged(glyph_mod.Point),
    has_width: bool,
    width: ?i32,

    // バウンディングボックス
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,

    // ヒント
    num_hints: u32,
    h_stems: std.ArrayListUnmanaged(glyph_mod.StemHint),
    v_stems: std.ArrayListUnmanaged(glyph_mod.StemHint),
    masks: std.ArrayListUnmanaged(glyph_mod.HintMaskEntry),
    h_stem_acc: f32,
    v_stem_acc: f32,
    total_points: u32,
    contour_count: u32,

    // サブルーチン
    global_subrs: cff_mod.Index,
    local_subrs: cff_mod.Index,

    fn init(allocator: std.mem.Allocator, global_subrs: cff_mod.Index, local_subrs: cff_mod.Index) Interpreter {
        return .{
            .allocator = allocator,
            .stack = undefined,
            .sp = 0,
            .x = 0,
            .y = 0,
            .contours = .empty,
            .current_points = .empty,
            .has_width = false,
            .width = null,
            .x_min = std.math.floatMax(f32),
            .y_min = std.math.floatMax(f32),
            .x_max = -std.math.floatMax(f32),
            .y_max = -std.math.floatMax(f32),
            .num_hints = 0,
            .h_stems = .empty,
            .v_stems = .empty,
            .masks = .empty,
            .h_stem_acc = 0,
            .v_stem_acc = 0,
            .total_points = 0,
            .contour_count = 0,
            .global_subrs = global_subrs,
            .local_subrs = local_subrs,
        };
    }

    fn deinit(self: *Interpreter) void {
        // Free any remaining current_points (shouldn't happen normally but safety)
        self.current_points.deinit(self.allocator);
        // Free contour point slices that we allocated
        for (self.contours.items) |contour| {
            self.allocator.free(contour.points);
        }
        self.contours.deinit(self.allocator);
        self.h_stems.deinit(self.allocator);
        self.v_stems.deinit(self.allocator);
        self.masks.deinit(self.allocator);
    }

    fn push(self: *Interpreter, val: f32) !void {
        if (self.sp >= MAX_STACK) return error.StackOverflow;
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn pop(self: *Interpreter) !f32 {
        if (self.sp == 0) return error.StackUnderflow;
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn updateBounds(self: *Interpreter, px: f32, py: f32) void {
        if (px < self.x_min) self.x_min = px;
        if (py < self.y_min) self.y_min = py;
        if (px > self.x_max) self.x_max = px;
        if (py > self.y_max) self.y_max = py;
    }

    fn addPoint(self: *Interpreter, px: f32, py: f32, on_curve: bool, is_cubic: bool) !void {
        self.updateBounds(px, py);
        const ix: i16 = @intFromFloat(@round(px));
        const iy: i16 = @intFromFloat(@round(py));
        try self.current_points.append(self.allocator, .{
            .x = ix,
            .y = iy,
            .on_curve = on_curve,
            .is_cubic = is_cubic,
        });
        self.total_points += 1;
    }

    fn emitCubic(self: *Interpreter, c1x: f32, c1y: f32, c2x: f32, c2y: f32, ex: f32, ey: f32) !void {
        self.x = ex;
        self.y = ey;
        try self.addPoint(c1x, c1y, false, true);
        try self.addPoint(c2x, c2y, false, true);
        try self.addPoint(self.x, self.y, true, false);
    }

    fn callSubroutine(self: *Interpreter, subrs: cff_mod.Index, depth: u32) CharstringError!void {
        if (self.sp == 0) return error.StackUnderflow;
        const subr_index_f = self.stack[self.sp - 1];
        self.sp -= 1;
        const subr_index: i32 = @intFromFloat(subr_index_f);
        const bias = subrBias(subrs.count);
        const actual_index_i = subr_index + bias;
        if (actual_index_i < 0) return error.InvalidSubroutine;
        const actual_index = std.math.cast(u16, actual_index_i) orelse return error.InvalidSubroutine;
        const subr_data = subrs.get(actual_index) orelse return error.InvalidSubroutine;
        try self.execute(subr_data, depth + 1);
    }

    fn closeContour(self: *Interpreter) !void {
        if (self.current_points.items.len > 0) {
            const points = try self.current_points.toOwnedSlice(self.allocator);
            try self.contours.append(self.allocator, .{ .points = points });
            self.contour_count += 1;
        }
    }

    fn startContour(self: *Interpreter) !void {
        try self.closeContour();
    }

    fn checkWidth(self: *Interpreter, expected_args: usize) void {
        if (!self.has_width) {
            self.has_width = true;
            if (self.sp > expected_args) {
                // First value is width
                self.width = @intFromFloat(self.stack[0]);
                // Shift remaining stack values down
                if (self.sp > 1) {
                    var j: usize = 0;
                    while (j < self.sp - 1) : (j += 1) {
                        self.stack[j] = self.stack[j + 1];
                    }
                }
                self.sp -= 1;
            }
        }
    }

    fn clearHintStack(self: *Interpreter, is_vertical: bool) !void {
        if (!self.has_width and self.sp % 2 != 0) {
            // odd number of values: first is width
            self.has_width = true;
            self.width = @intFromFloat(self.stack[0]);
            // Shift remaining stack values down
            if (self.sp > 1) {
                var j: usize = 0;
                while (j < self.sp - 1) : (j += 1) {
                    self.stack[j] = self.stack[j + 1];
                }
            }
            self.sp -= 1;
        } else if (!self.has_width) {
            self.has_width = true;
        }

        var si: usize = 0;
        while (si + 1 < self.sp) {
            const pos_delta = self.stack[si];
            const w = self.stack[si + 1];
            if (is_vertical) {
                self.v_stem_acc += pos_delta;
                if (self.v_stems.items.len < MAX_HINTS) {
                    try self.v_stems.append(self.allocator, .{ .position = self.v_stem_acc, .width = w });
                }
                self.v_stem_acc += w;
            } else {
                self.h_stem_acc += pos_delta;
                if (self.h_stems.items.len < MAX_HINTS) {
                    try self.h_stems.append(self.allocator, .{ .position = self.h_stem_acc, .width = w });
                }
                self.h_stem_acc += w;
            }
            si += 2;
        }

        self.num_hints +|= @intCast(self.sp / 2);
        self.sp = 0;
    }

    fn hintMaskBytes(self: *Interpreter) usize {
        return (@as(usize, self.num_hints) + 7) / 8;
    }

    fn execute(self: *Interpreter, data: []const u8, depth: u32) !void {
        if (depth > MAX_CALL_DEPTH) return error.CallDepthExceeded;

        var i: usize = 0;
        while (i < data.len) {
            const b0 = data[i];
            i += 1;

            switch (b0) {
                // --- Number encodings ---
                28 => {
                    if (i + 2 > data.len) return error.UnexpectedEof;
                    const val = std.mem.readInt(i16, data[i..][0..2], .big);
                    try self.push(@floatFromInt(val));
                    i += 2;
                },
                32...246 => {
                    try self.push(@floatFromInt(@as(i32, b0) - 139));
                },
                247...250 => {
                    if (i >= data.len) return error.UnexpectedEof;
                    const val = (@as(i32, b0) - 247) * 256 + @as(i32, data[i]) + 108;
                    try self.push(@floatFromInt(val));
                    i += 1;
                },
                251...254 => {
                    if (i >= data.len) return error.UnexpectedEof;
                    const val = -(@as(i32, b0) - 251) * 256 - @as(i32, data[i]) - 108;
                    try self.push(@floatFromInt(val));
                    i += 1;
                },
                255 => {
                    if (i + 4 > data.len) return error.UnexpectedEof;
                    const val = std.mem.readInt(i32, data[i..][0..4], .big);
                    try self.push(@as(f32, @floatFromInt(val)) / 65536.0);
                    i += 4;
                },

                // --- Operators ---

                // hstem (1), vstem (3)
                1 => {
                    try self.clearHintStack(false);
                },
                3 => {
                    try self.clearHintStack(true);
                },

                // vmoveto (4)
                4 => {
                    self.checkWidth(1);
                    if (self.sp < 1) return error.StackUnderflow;
                    const dy = self.stack[0];
                    self.sp = 0;
                    self.y += dy;
                    try self.startContour();
                    try self.addPoint(self.x, self.y, true, false);
                },

                // rlineto (5)
                5 => {
                    var si: usize = 0;
                    while (si + 1 < self.sp) {
                        self.x += self.stack[si];
                        self.y += self.stack[si + 1];
                        try self.addPoint(self.x, self.y, true, false);
                        si += 2;
                    }
                    self.sp = 0;
                },

                // hlineto (6)
                6 => {
                    var si: usize = 0;
                    var horizontal = true;
                    while (si < self.sp) {
                        if (horizontal) {
                            self.x += self.stack[si];
                        } else {
                            self.y += self.stack[si];
                        }
                        try self.addPoint(self.x, self.y, true, false);
                        si += 1;
                        horizontal = !horizontal;
                    }
                    self.sp = 0;
                },

                // vlineto (7)
                7 => {
                    var si: usize = 0;
                    var vertical = true;
                    while (si < self.sp) {
                        if (vertical) {
                            self.y += self.stack[si];
                        } else {
                            self.x += self.stack[si];
                        }
                        try self.addPoint(self.x, self.y, true, false);
                        si += 1;
                        vertical = !vertical;
                    }
                    self.sp = 0;
                },

                // rrcurveto (8)
                8 => {
                    var si: usize = 0;
                    while (si + 5 < self.sp) {
                        const c1x = self.x + self.stack[si];
                        const c1y = self.y + self.stack[si + 1];
                        const c2x = c1x + self.stack[si + 2];
                        const c2y = c1y + self.stack[si + 3];
                        try self.emitCubic(c1x, c1y, c2x, c2y, c2x + self.stack[si + 4], c2y + self.stack[si + 5]);
                        si += 6;
                    }
                    self.sp = 0;
                },

                // callsubr (10) - local
                10 => {
                    try self.callSubroutine(self.local_subrs, depth);
                },

                // return (11)
                11 => {
                    return;
                },

                // endchar (14)
                14 => {
                    self.checkWidth(0);
                    try self.closeContour();
                    return;
                },

                // hstemhm (18)
                18 => {
                    try self.clearHintStack(false);
                },

                // hintmask (19), cntrmask (20)
                19, 20 => {
                    try self.clearHintStack(true);
                    const mask_bytes = self.hintMaskBytes();
                    if (i + mask_bytes <= data.len and self.masks.items.len < MAX_HINTS * 16) {
                        var entry: glyph_mod.HintMaskEntry = .{
                            .data = .{0} ** 12,
                            .point_index = self.total_points,
                            .contour_index = self.contour_count,
                            .is_counter = (b0 == 20),
                        };
                        const copy_len = @min(mask_bytes, 12);
                        @memcpy(entry.data[0..copy_len], data[i..][0..copy_len]);
                        try self.masks.append(self.allocator, entry);
                    }
                    i += mask_bytes;
                },

                // rmoveto (21)
                21 => {
                    self.checkWidth(2);
                    if (self.sp < 2) return error.StackUnderflow;
                    const dx = self.stack[0];
                    const dy = self.stack[1];
                    self.sp = 0;
                    self.x += dx;
                    self.y += dy;
                    try self.startContour();
                    try self.addPoint(self.x, self.y, true, false);
                },

                // hmoveto (22)
                22 => {
                    self.checkWidth(1);
                    if (self.sp < 1) return error.StackUnderflow;
                    const dx = self.stack[0];
                    self.sp = 0;
                    self.x += dx;
                    try self.startContour();
                    try self.addPoint(self.x, self.y, true, false);
                },

                // vstemhm (23)
                23 => {
                    try self.clearHintStack(true);
                },

                // rcurveline (24)
                24 => {
                    if (self.sp < 2) return error.StackUnderflow;
                    var si: usize = 0;
                    // Curves: groups of 6, then final 2 for line
                    const curve_end = self.sp - 2;
                    while (si + 5 <= curve_end) {
                        const c1x = self.x + self.stack[si];
                        const c1y = self.y + self.stack[si + 1];
                        const c2x = c1x + self.stack[si + 2];
                        const c2y = c1y + self.stack[si + 3];
                        try self.emitCubic(c1x, c1y, c2x, c2y, c2x + self.stack[si + 4], c2y + self.stack[si + 5]);
                        si += 6;
                    }
                    // Final line
                    self.x += self.stack[self.sp - 2];
                    self.y += self.stack[self.sp - 1];
                    try self.addPoint(self.x, self.y, true, false);
                    self.sp = 0;
                },

                // rlinecurve (25)
                25 => {
                    if (self.sp < 6) return error.StackUnderflow;
                    var si: usize = 0;
                    // Lines: groups of 2, then final 6 for curve
                    const line_end = self.sp - 6;
                    while (si + 1 <= line_end) {
                        self.x += self.stack[si];
                        self.y += self.stack[si + 1];
                        try self.addPoint(self.x, self.y, true, false);
                        si += 2;
                    }
                    // Final curve
                    const c1x = self.x + self.stack[self.sp - 6];
                    const c1y = self.y + self.stack[self.sp - 5];
                    const c2x = c1x + self.stack[self.sp - 4];
                    const c2y = c1y + self.stack[self.sp - 3];
                    try self.emitCubic(c1x, c1y, c2x, c2y, c2x + self.stack[self.sp - 2], c2y + self.stack[self.sp - 1]);
                    self.sp = 0;
                },

                // vvcurveto (26)
                26 => {
                    var si: usize = 0;
                    // Optional dx1 if stack count is odd
                    var dx1: f32 = 0;
                    if (self.sp % 4 != 0) {
                        dx1 = self.stack[si];
                        si += 1;
                    }
                    var first = true;
                    while (si + 3 < self.sp) {
                        const dya = self.stack[si];
                        const dxb = self.stack[si + 1];
                        const dyb = self.stack[si + 2];
                        const dyc = self.stack[si + 3];
                        var c1x = self.x;
                        if (first and dx1 != 0) {
                            c1x += dx1;
                            first = false;
                        }
                        const c1y = self.y + dya;
                        const c2x = c1x + dxb;
                        const c2y = c1y + dyb;
                        try self.emitCubic(c1x, c1y, c2x, c2y, c2x, c2y + dyc);
                        si += 4;
                    }
                    self.sp = 0;
                },

                // hhcurveto (27)
                27 => {
                    var si: usize = 0;
                    // Optional dy1 if stack count is odd
                    var dy1: f32 = 0;
                    if (self.sp % 4 != 0) {
                        dy1 = self.stack[si];
                        si += 1;
                    }
                    var first = true;
                    while (si + 3 < self.sp) {
                        const dxa = self.stack[si];
                        const dxb = self.stack[si + 1];
                        const dyb = self.stack[si + 2];
                        const dxc = self.stack[si + 3];
                        const c1x = self.x + dxa;
                        var c1y = self.y;
                        if (first and dy1 != 0) {
                            c1y += dy1;
                            first = false;
                        }
                        const c2x = c1x + dxb;
                        const c2y = c1y + dyb;
                        try self.emitCubic(c1x, c1y, c2x, c2y, c2x + dxc, c2y);
                        si += 4;
                    }
                    self.sp = 0;
                },

                // callgsubr (29) - global
                29 => {
                    try self.callSubroutine(self.global_subrs, depth);
                },

                // vhcurveto (30)
                30 => {
                    try self.alternatingCurves(true);
                },

                // hvcurveto (31)
                31 => {
                    try self.alternatingCurves(false);
                },

                // 2-byte operators (12, XX)
                12 => {
                    if (i >= data.len) return error.UnexpectedEof;
                    const b1 = data[i];
                    i += 1;
                    switch (b1) {
                        // hflex (12 34) — 7 args: dx1 dx2 dy2 dx3 dx4 dx5 dx6
                        34 => try self.execFlexOp(b1),
                        // flex (12 35) — 13 args: dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 dx6 dy6 fd
                        35 => try self.execFlexOp(b1),
                        // hflex1 (12 36) — 9 args: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
                        36 => try self.execFlexOp(b1),
                        // flex1 (12 37) — 11 args: dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6
                        37 => try self.execFlexOp(b1),
                        else => {
                            // Unknown sub-operator: clear stack
                            self.sp = 0;
                        },
                    }
                },

                else => {
                    // Unknown operator: ignore
                },
            }
        }
    }

    fn execFlexOp(self: *Interpreter, subop: u8) !void {
        switch (subop) {
            // hflex (12 34) — 7 args: dx1 dx2 dy2 dx3 dx4 dx5 dx6
            34 => {
                if (self.sp < 7) return error.StackUnderflow;
                const dx1 = self.stack[0];
                const dx2 = self.stack[1];
                const dy2 = self.stack[2];
                const dx3 = self.stack[3];
                const dx4 = self.stack[4];
                const dx5 = self.stack[5];
                const dx6 = self.stack[6];
                // Curve 1
                const c1x = self.x + dx1;
                const c1y = self.y;
                const c2x = c1x + dx2;
                const c2y = c1y + dy2;
                try self.emitCubic(c1x, c1y, c2x, c2y, c2x + dx3, c2y);
                // Curve 2
                const c3x = self.x + dx4;
                const c3y = self.y;
                const c4x = c3x + dx5;
                const c4y = c3y + (-dy2);
                try self.emitCubic(c3x, c3y, c4x, c4y, c4x + dx6, c4y);
                self.sp = 0;
            },
            // flex (12 35) — 13 args: dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 dx6 dy6 fd
            35 => {
                if (self.sp < 13) return error.StackUnderflow;
                const dx1 = self.stack[0];
                const dy1 = self.stack[1];
                const dx2 = self.stack[2];
                const dy2 = self.stack[3];
                const dx3 = self.stack[4];
                const dy3 = self.stack[5];
                const dx4 = self.stack[6];
                const dy4 = self.stack[7];
                const dx5 = self.stack[8];
                const dy5 = self.stack[9];
                const dx6 = self.stack[10];
                const dy6 = self.stack[11];
                // fd (stack[12]) is ignored for rendering
                // Curve 1
                const c1x = self.x + dx1;
                const c1y = self.y + dy1;
                const c2x = c1x + dx2;
                const c2y = c1y + dy2;
                try self.emitCubic(c1x, c1y, c2x, c2y, c2x + dx3, c2y + dy3);
                // Curve 2
                const c3x = self.x + dx4;
                const c3y = self.y + dy4;
                const c4x = c3x + dx5;
                const c4y = c3y + dy5;
                try self.emitCubic(c3x, c3y, c4x, c4y, c4x + dx6, c4y + dy6);
                self.sp = 0;
            },
            // hflex1 (12 36) — 9 args: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
            36 => {
                if (self.sp < 9) return error.StackUnderflow;
                const dx1 = self.stack[0];
                const dy1 = self.stack[1];
                const dx2 = self.stack[2];
                const dy2 = self.stack[3];
                const dx3 = self.stack[4];
                const dx4 = self.stack[5];
                const dx5 = self.stack[6];
                const dy5 = self.stack[7];
                const dx6 = self.stack[8];
                // Curve 1
                const c1x = self.x + dx1;
                const c1y = self.y + dy1;
                const c2x = c1x + dx2;
                const c2y = c1y + dy2;
                try self.emitCubic(c1x, c1y, c2x, c2y, c2x + dx3, c2y);
                // Curve 2
                const c3x = self.x + dx4;
                const c3y = self.y;
                const c4x = c3x + dx5;
                const c4y = c3y + dy5;
                try self.emitCubic(c3x, c3y, c4x, c4y, c4x + dx6, c4y + (-(dy1 + dy2 + dy5)));
                self.sp = 0;
            },
            // flex1 (12 37) — 11 args: dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6
            37 => {
                if (self.sp < 11) return error.StackUnderflow;
                const dx1 = self.stack[0];
                const dy1 = self.stack[1];
                const dx2 = self.stack[2];
                const dy2 = self.stack[3];
                const dx3 = self.stack[4];
                const dy3 = self.stack[5];
                const dx4 = self.stack[6];
                const dy4 = self.stack[7];
                const dx5 = self.stack[8];
                const dy5 = self.stack[9];
                const d6 = self.stack[10];
                const sum_dx = dx1 + dx2 + dx3 + dx4 + dx5;
                const sum_dy = dy1 + dy2 + dy3 + dy4 + dy5;
                const use_dx = @abs(sum_dx) > @abs(sum_dy);
                const f_dx6: f32 = if (use_dx) d6 else -sum_dx;
                const f_dy6: f32 = if (use_dx) -sum_dy else d6;
                // Curve 1
                const c1x = self.x + dx1;
                const c1y = self.y + dy1;
                const c2x = c1x + dx2;
                const c2y = c1y + dy2;
                try self.emitCubic(c1x, c1y, c2x, c2y, c2x + dx3, c2y + dy3);
                // Curve 2
                const c3x = self.x + dx4;
                const c3y = self.y + dy4;
                const c4x = c3x + dx5;
                const c4y = c3y + dy5;
                try self.emitCubic(c3x, c3y, c4x, c4y, c4x + f_dx6, c4y + f_dy6);
                self.sp = 0;
            },
            else => unreachable,
        }
    }

    /// Handle vhcurveto (start_vertical=true) and hvcurveto (start_vertical=false)
    fn alternatingCurves(self: *Interpreter, start_vertical: bool) !void {
        var si: usize = 0;
        var vertical = start_vertical;
        while (si < self.sp) {
            // Determine if this is the last curve and there's an extra value (dxf/dyf)
            const remaining = self.sp - si;
            if (remaining < 4) break;

            const has_extra = (remaining == 5);

            if (vertical) {
                // v start: dy1 dx2 dy2 dx3 [dyf]
                const dy1 = self.stack[si];
                const dx2 = self.stack[si + 1];
                const dy2 = self.stack[si + 2];
                const dx3 = self.stack[si + 3];

                const c1x = self.x;
                const c1y = self.y + dy1;
                const c2x = c1x + dx2;
                const c2y = c1y + dy2;
                const end_x = c2x + dx3;
                var end_y = c2y;
                if (has_extra) {
                    end_y += self.stack[si + 4];
                    si += 5;
                } else {
                    si += 4;
                }
                try self.emitCubic(c1x, c1y, c2x, c2y, end_x, end_y);
            } else {
                // h start: dx1 dx2 dy2 dy3 [dxf]
                const dx1 = self.stack[si];
                const dx2 = self.stack[si + 1];
                const dy2 = self.stack[si + 2];
                const dy3 = self.stack[si + 3];

                const c1x = self.x + dx1;
                const c1y = self.y;
                const c2x = c1x + dx2;
                const c2y = c1y + dy2;
                var end_x = c2x;
                const end_y = c2y + dy3;
                if (has_extra) {
                    end_x += self.stack[si + 4];
                    si += 5;
                } else {
                    si += 4;
                }
                try self.emitCubic(c1x, c1y, c2x, c2y, end_x, end_y);
            }

            vertical = !vertical;
        }
        self.sp = 0;
    }

    fn buildOutline(self: *Interpreter) !glyph_mod.GlyphOutline {
        // Close any remaining contour
        try self.closeContour();

        // Take ownership of contours from the interpreter
        const contours = try self.contours.toOwnedSlice(self.allocator);
        errdefer {
            for (contours) |contour| {
                self.allocator.free(contour.points);
            }
            self.allocator.free(contours);
        }

        // Handle case where no points were drawn (bounding box is still default)
        var x_min: i16 = 0;
        var y_min: i16 = 0;
        var x_max: i16 = 0;
        var y_max: i16 = 0;

        if (self.x_min <= self.x_max) {
            x_min = @intFromFloat(@floor(self.x_min));
            y_min = @intFromFloat(@floor(self.y_min));
            x_max = @intFromFloat(@ceil(self.x_max));
            y_max = @intFromFloat(@ceil(self.y_max));
        }

        const hints: ?glyph_mod.HintData = if (self.h_stems.items.len > 0 or self.v_stems.items.len > 0) blk: {
            const h_stems = try self.h_stems.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(h_stems);
            const v_stems = try self.v_stems.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(v_stems);
            const masks = try self.masks.toOwnedSlice(self.allocator);
            break :blk glyph_mod.HintData{
                .h_stems = h_stems,
                .v_stems = v_stems,
                .masks = masks,
                .allocator = self.allocator,
            };
        } else blk: {
            self.h_stems.deinit(self.allocator);
            self.v_stems.deinit(self.allocator);
            self.masks.deinit(self.allocator);
            self.h_stems = .empty;
            self.v_stems = .empty;
            self.masks = .empty;
            break :blk null;
        };

        return .{
            .contours = contours,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
            .hints = hints,
            .allocator = self.allocator,
        };
    }
};

fn subrBias(count: u16) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

// --- Tests ---

test "simple rectangle: rmoveto + rlineto + endchar" {
    const allocator = std.testing.allocator;

    // Build a 100x100 rectangle: (0,0) -> (100,0) -> (100,100) -> (0,100) -> close
    // Encoding:
    //   rmoveto(0, 0): 139(=0) 139(=0) 21
    //   rlineto(100, 0): 239(=100) 139(=0) 5
    //   rlineto(0, 100): 139(=0) 239(=100) 5
    //   rlineto(-100, 0): 39(=-100) 139(=0) 5
    //   rlineto(0, -100): 139(=0) 39(=-100) 5
    //   endchar: 14
    const data = [_]u8{
        139, 139, 21, // rmoveto(0, 0)
        239, 139, 5, // rlineto(100, 0)
        139, 239, 5, // rlineto(0, 100)
        39, 139, 5, // rlineto(-100, 0)
        139, 39, 5, // rlineto(0, -100)
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    // Should produce 1 contour
    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);

    // Should have 5 points: moveto(0,0) + 4 rlineto points
    try std.testing.expectEqual(@as(usize, 5), outline.contours[0].points.len);

    // Verify points
    const pts = outline.contours[0].points;
    // pts[0] is the moveto starting point
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 0), pts[0].y);
    try std.testing.expect(pts[0].on_curve);

    try std.testing.expectEqual(@as(i16, 100), pts[1].x);
    try std.testing.expectEqual(@as(i16, 0), pts[1].y);
    try std.testing.expect(pts[1].on_curve);

    try std.testing.expectEqual(@as(i16, 100), pts[2].x);
    try std.testing.expectEqual(@as(i16, 100), pts[2].y);

    try std.testing.expectEqual(@as(i16, 0), pts[3].x);
    try std.testing.expectEqual(@as(i16, 100), pts[3].y);

    try std.testing.expectEqual(@as(i16, 0), pts[4].x);
    try std.testing.expectEqual(@as(i16, 0), pts[4].y);

    // Check bounding box
    try std.testing.expectEqual(@as(i16, 0), outline.x_min);
    try std.testing.expectEqual(@as(i16, 0), outline.y_min);
    try std.testing.expectEqual(@as(i16, 100), outline.x_max);
    try std.testing.expectEqual(@as(i16, 100), outline.y_max);
}

test "rrcurveto produces cubic bezier points" {
    const allocator = std.testing.allocator;

    // rmoveto(0, 0) then rrcurveto(10, 20, 30, 40, 50, 60) then endchar
    // Expected: control1=(10,20), control2=(40,60), end=(90,120)
    const data = [_]u8{
        139, 139, 21, // rmoveto(0, 0)
        // rrcurveto: 10, 20, 30, 40, 50, 60
        149, // 10 (= 149-139)
        159, // 20
        169, // 30
        179, // 40
        189, // 50
        199, // 60
        8, // rrcurveto
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);

    const pts = outline.contours[0].points;
    try std.testing.expectEqual(@as(usize, 4), pts.len);

    // pts[0] is the moveto starting point (0, 0)
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 0), pts[0].y);
    try std.testing.expect(pts[0].on_curve);

    // Control point 1: (10, 20) - off-curve, cubic
    try std.testing.expectEqual(@as(i16, 10), pts[1].x);
    try std.testing.expectEqual(@as(i16, 20), pts[1].y);
    try std.testing.expect(!pts[1].on_curve);
    try std.testing.expect(pts[1].is_cubic);

    // Control point 2: (10+30=40, 20+40=60) - off-curve, cubic
    try std.testing.expectEqual(@as(i16, 40), pts[2].x);
    try std.testing.expectEqual(@as(i16, 60), pts[2].y);
    try std.testing.expect(!pts[2].on_curve);
    try std.testing.expect(pts[2].is_cubic);

    // End point: (40+50=90, 60+60=120) - on-curve
    try std.testing.expectEqual(@as(i16, 90), pts[3].x);
    try std.testing.expectEqual(@as(i16, 120), pts[3].y);
    try std.testing.expect(pts[3].on_curve);
    try std.testing.expect(!pts[3].is_cubic);
}

test "vmoveto and hmoveto" {
    const allocator = std.testing.allocator;

    // vmoveto(50), rlineto(10, 0), endchar
    const data = [_]u8{
        189, 4, // vmoveto(50): 189=50, 4=vmoveto
        149, 139, 5, // rlineto(10, 0)
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    const pts = outline.contours[0].points;
    try std.testing.expectEqual(@as(usize, 2), pts.len);
    // pts[0] is the vmoveto starting point (0, 50)
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 50), pts[0].y);
    // After rlineto(10,0): point at (10, 50)
    try std.testing.expectEqual(@as(i16, 10), pts[1].x);
    try std.testing.expectEqual(@as(i16, 50), pts[1].y);
}

test "hlineto and vlineto" {
    const allocator = std.testing.allocator;

    // rmoveto(0,0), hlineto(100, 50), endchar
    // hlineto alternates: h(100), v(50)
    const data = [_]u8{
        139, 139, 21, // rmoveto(0, 0)
        239, 189, 6, // hlineto: 100, 50
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    const pts = outline.contours[0].points;
    try std.testing.expectEqual(@as(usize, 3), pts.len);
    // pts[0] is the rmoveto starting point (0, 0)
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 0), pts[0].y);
    // First: h(100) -> (100, 0)
    try std.testing.expectEqual(@as(i16, 100), pts[1].x);
    try std.testing.expectEqual(@as(i16, 0), pts[1].y);
    // Second: v(50) -> (100, 50)
    try std.testing.expectEqual(@as(i16, 100), pts[2].x);
    try std.testing.expectEqual(@as(i16, 50), pts[2].y);
}

test "width detection in rmoveto" {
    const allocator = std.testing.allocator;

    // rmoveto with 3 args (width + dx + dy): width=200, dx=10, dy=20
    // 200 = b0-139 -> b0=339 -- too large for single byte
    // Use 247-250 range: (b0-247)*256 + b1 + 108 = 200 -> b0=247, b1=92
    const data = [_]u8{
        247, 92, // 200 (width)
        149, // 10 (dx)
        159, // 20 (dy)
        21, // rmoveto
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    // The contour now includes the moveto starting point
    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    try std.testing.expectEqual(@as(usize, 1), outline.contours[0].points.len);
    // moveto point at (10, 20)
    try std.testing.expectEqual(@as(i16, 10), outline.contours[0].points[0].x);
    try std.testing.expectEqual(@as(i16, 20), outline.contours[0].points[0].y);
}

test "hstem hint counting and hintmask" {
    const allocator = std.testing.allocator;

    // hstem with 4 values (2 hint pairs), then hintmask
    // After hstem: num_hints = 2, so hintmask needs ceil(2/8) = 1 byte
    const data = [_]u8{
        139, // 0
        189, // 50
        239, // 100
        189, // 50
        1, // hstem (4 values = 2 hint pairs)
        19, 0xFF, // hintmask with 1 mask byte
        139, 139, 21, // rmoveto(0, 0)
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    // Should not error - verifies hintmask byte count is correct
    // Now produces 1 contour with the moveto point at (0, 0)
    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    try std.testing.expectEqual(@as(usize, 1), outline.contours[0].points.len);
}

test "subrBias calculation" {
    try std.testing.expectEqual(@as(i32, 107), subrBias(0));
    try std.testing.expectEqual(@as(i32, 107), subrBias(1239));
    try std.testing.expectEqual(@as(i32, 1131), subrBias(1240));
    try std.testing.expectEqual(@as(i32, 1131), subrBias(33899));
    try std.testing.expectEqual(@as(i32, 32768), subrBias(33900));
}

test "hflex operator (12 34) produces 6 points" {
    const allocator = std.testing.allocator;

    // rmoveto(0, 0): 139 139 21
    // hflex: dx1=10 dx2=20 dy2=5 dx3=30 dx4=30 dx5=20 dx6=10
    //   Encoded: 149(10) 159(20) 144(5) 169(30) 169(30) 159(20) 149(10) 12 34
    // endchar: 14
    const data = [_]u8{
        139, 139, 21, // rmoveto(0, 0)
        149, 159, 144, 169, 169, 159, 149, // push: 10 20 5 30 30 20 10
        12, 34, // hflex
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    const pts = outline.contours[0].points;
    // moveto(0,0) + 2 curves × 3 points each = 7 points
    try std.testing.expectEqual(@as(usize, 7), pts.len);

    // pts[0] is the rmoveto starting point (0, 0)
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 0), pts[0].y);
    try std.testing.expect(pts[0].on_curve);

    // Curve 1: start=(0,0), dx1=10,dya=0 → c1=(10,0); dx2=20,dy2=5 → c2=(30,5); dx3=30,dyc=0 → end=(60,5)
    try std.testing.expectEqual(@as(i16, 10), pts[1].x);
    try std.testing.expectEqual(@as(i16, 0), pts[1].y);
    try std.testing.expect(!pts[1].on_curve);

    try std.testing.expectEqual(@as(i16, 30), pts[2].x);
    try std.testing.expectEqual(@as(i16, 5), pts[2].y);
    try std.testing.expect(!pts[2].on_curve);

    try std.testing.expectEqual(@as(i16, 60), pts[3].x);
    try std.testing.expectEqual(@as(i16, 5), pts[3].y);
    try std.testing.expect(pts[3].on_curve);

    // Curve 2: start=(60,5), dx4=30,dya=0 → c3=(90,5); dx5=20,dyb=-5 → c4=(110,0); dx6=10,dyc=0 → end=(120,0)
    try std.testing.expectEqual(@as(i16, 90), pts[4].x);
    try std.testing.expectEqual(@as(i16, 5), pts[4].y);
    try std.testing.expect(!pts[4].on_curve);

    try std.testing.expectEqual(@as(i16, 110), pts[5].x);
    try std.testing.expectEqual(@as(i16, 0), pts[5].y);
    try std.testing.expect(!pts[5].on_curve);

    try std.testing.expectEqual(@as(i16, 120), pts[6].x);
    try std.testing.expectEqual(@as(i16, 0), pts[6].y);
    try std.testing.expect(pts[6].on_curve);
}

test "flex operator (12 35) produces 6 points" {
    const allocator = std.testing.allocator;

    // rmoveto(0, 0): 139 139 21
    // flex: dx1=10 dy1=0 dx2=20 dy2=5 dx3=30 dy3=0 dx4=30 dy4=0 dx5=20 dy5=-5 dx6=10 dy6=0 fd=50
    //   Encoded values: 149 139 159 144 169 139 169 139 159 134 149 139 189 12 35
    // endchar: 14
    const data = [_]u8{
        139, 139, 21, // rmoveto(0, 0)
        149, 139, 159, 144, 169, 139, // dx1=10 dy1=0 dx2=20 dy2=5 dx3=30 dy3=0
        169, 139, 159, 134, 149, 139, // dx4=30 dy4=0 dx5=20 dy5=-5 dx6=10 dy6=0
        189, // fd=50
        12, 35, // flex
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    const pts = outline.contours[0].points;
    // moveto(0,0) + 2 curves × 3 points each = 7 points
    try std.testing.expectEqual(@as(usize, 7), pts.len);

    // pts[0] is the rmoveto starting point (0, 0)
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 0), pts[0].y);
    try std.testing.expect(pts[0].on_curve);

    // Curve 1: start=(0,0); c1=(10,0); c2=(30,5); end=(60,5)
    try std.testing.expectEqual(@as(i16, 10), pts[1].x);
    try std.testing.expectEqual(@as(i16, 0), pts[1].y);
    try std.testing.expect(!pts[1].on_curve);

    try std.testing.expectEqual(@as(i16, 30), pts[2].x);
    try std.testing.expectEqual(@as(i16, 5), pts[2].y);
    try std.testing.expect(!pts[2].on_curve);

    try std.testing.expectEqual(@as(i16, 60), pts[3].x);
    try std.testing.expectEqual(@as(i16, 5), pts[3].y);
    try std.testing.expect(pts[3].on_curve);

    // Curve 2: start=(60,5); c3=(90,5); c4=(110,0); end=(120,0)
    try std.testing.expectEqual(@as(i16, 90), pts[4].x);
    try std.testing.expectEqual(@as(i16, 5), pts[4].y);
    try std.testing.expect(!pts[4].on_curve);

    try std.testing.expectEqual(@as(i16, 110), pts[5].x);
    try std.testing.expectEqual(@as(i16, 0), pts[5].y);
    try std.testing.expect(!pts[5].on_curve);

    try std.testing.expectEqual(@as(i16, 120), pts[6].x);
    try std.testing.expectEqual(@as(i16, 0), pts[6].y);
    try std.testing.expect(pts[6].on_curve);
}

test "hflex1 operator (12 36) produces 6 points" {
    const allocator = std.testing.allocator;

    // rmoveto(0, 0): 139 139 21
    // hflex1: dx1=10 dy1=2 dx2=20 dy2=3 dx3=30 dx4=30 dx5=20 dy5=-3 dx6=10
    //   dy for curve 2 endpoint = -(dy1+dy2+dy5) = -(2+3-3) = -2
    //   Encoded: 149 141 159 142 169 169 159 136 149 12 36
    // endchar: 14
    const data = [_]u8{
        139, 139, 21, // rmoveto(0, 0)
        149, 141, 159, 142, 169, 169, 159, 136, 149, // 10 2 20 3 30 30 20 -3 10
        12, 36, // hflex1
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    const pts = outline.contours[0].points;
    // moveto(0,0) + 2 curves × 3 points each = 7 points
    try std.testing.expectEqual(@as(usize, 7), pts.len);

    // pts[0] is the rmoveto starting point (0, 0)
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 0), pts[0].y);
    try std.testing.expect(pts[0].on_curve);

    // Curve 1: start=(0,0); c1=(10,2) [dx1=10,dy1=2]; c2=(30,5) [dx2=20,dy2=3]; end=(60,5) [dx3=30,dy=0]
    try std.testing.expectEqual(@as(i16, 10), pts[1].x);
    try std.testing.expectEqual(@as(i16, 2), pts[1].y);
    try std.testing.expect(!pts[1].on_curve);

    try std.testing.expectEqual(@as(i16, 30), pts[2].x);
    try std.testing.expectEqual(@as(i16, 5), pts[2].y);
    try std.testing.expect(!pts[2].on_curve);

    try std.testing.expectEqual(@as(i16, 60), pts[3].x);
    try std.testing.expectEqual(@as(i16, 5), pts[3].y);
    try std.testing.expect(pts[3].on_curve);

    // Curve 2: start=(60,5); c3=(90,5) [dx4=30,dy=0]; c4=(110,2) [dx5=20,dy5=-3]; end=(120,0) [dx6=10,dy=-(2+3-3)=-2]
    try std.testing.expectEqual(@as(i16, 90), pts[4].x);
    try std.testing.expectEqual(@as(i16, 5), pts[4].y);
    try std.testing.expect(!pts[4].on_curve);

    try std.testing.expectEqual(@as(i16, 110), pts[5].x);
    try std.testing.expectEqual(@as(i16, 2), pts[5].y);
    try std.testing.expect(!pts[5].on_curve);

    try std.testing.expectEqual(@as(i16, 120), pts[6].x);
    try std.testing.expectEqual(@as(i16, 0), pts[6].y);
    try std.testing.expect(pts[6].on_curve);
}

test "flex1 operator (12 37) produces 6 points" {
    const allocator = std.testing.allocator;

    // rmoveto(0, 0): 139 139 21
    // flex1: dx1=10 dy1=5 dx2=20 dy2=10 dx3=30 dy3=0 dx4=30 dy4=0 dx5=20 dy5=-10 d6=10
    //   sum_dx = 10+20+30+30+20 = 110, sum_dy = 5+10+0+0-10 = 5
    //   |sum_dx|=110 > |sum_dy|=5, so dx6=d6=10, dy6=-sum_dy=-5
    //   Encoded: 149 144 159 149 169 139 169 139 159 129 149 12 37
    // endchar: 14
    const data = [_]u8{
        139, 139, 21, // rmoveto(0, 0)
        149, 144, 159, 149, 169, 139, 169, 139, 159, 129, 149, // 10 5 20 10 30 0 30 0 20 -10 10
        12, 37, // flex1
        14, // endchar
    };

    const empty_index = cff_mod.Index{
        .count = 0,
        .off_size = 0,
        .offsets_start = 0,
        .data_start = 0,
        .data = &.{},
    };

    var outline = try interpret(allocator, &data, empty_index, empty_index);
    defer outline.deinit();

    try std.testing.expectEqual(@as(usize, 1), outline.contours.len);
    const pts = outline.contours[0].points;
    // moveto(0,0) + 2 curves × 3 points each = 7 points
    try std.testing.expectEqual(@as(usize, 7), pts.len);

    // pts[0] is the rmoveto starting point (0, 0)
    try std.testing.expectEqual(@as(i16, 0), pts[0].x);
    try std.testing.expectEqual(@as(i16, 0), pts[0].y);
    try std.testing.expect(pts[0].on_curve);

    // Curve 1: start=(0,0); c1=(10,5); c2=(30,15); end=(60,15)
    try std.testing.expectEqual(@as(i16, 10), pts[1].x);
    try std.testing.expectEqual(@as(i16, 5), pts[1].y);
    try std.testing.expect(!pts[1].on_curve);

    try std.testing.expectEqual(@as(i16, 30), pts[2].x);
    try std.testing.expectEqual(@as(i16, 15), pts[2].y);
    try std.testing.expect(!pts[2].on_curve);

    try std.testing.expectEqual(@as(i16, 60), pts[3].x);
    try std.testing.expectEqual(@as(i16, 15), pts[3].y);
    try std.testing.expect(pts[3].on_curve);

    // Curve 2: start=(60,15); c3=(90,15); c4=(110,5); end=(120,10) [dx6=10,dy6=-5]
    try std.testing.expectEqual(@as(i16, 90), pts[4].x);
    try std.testing.expectEqual(@as(i16, 15), pts[4].y);
    try std.testing.expect(!pts[4].on_curve);

    try std.testing.expectEqual(@as(i16, 110), pts[5].x);
    try std.testing.expectEqual(@as(i16, 5), pts[5].y);
    try std.testing.expect(!pts[5].on_curve);

    try std.testing.expectEqual(@as(i16, 120), pts[6].x);
    try std.testing.expectEqual(@as(i16, 0), pts[6].y);
    try std.testing.expect(pts[6].on_curve);
}
