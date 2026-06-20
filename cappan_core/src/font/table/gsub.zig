const std = @import("std");
const parser = @import("../parser.zig");
const otlayout = @import("otlayout.zig");
const gdef_mod = @import("gdef.zig");

fn shouldSkipGlyph(gdef: ?gdef_mod.GdefTable, glyph_id: u16, lookup_flag: u16) bool {
    if (lookup_flag & 0xFFFE == 0) return false;
    const g = gdef orelse return false;
    return g.shouldSkipGlyph(glyph_id, lookup_flag, null);
}

pub const GsubTable = struct {
    data: []const u8,
    script_list_offset: u16,
    feature_list_offset: u16,
    lookup_list_offset: u16,
    gdef: ?gdef_mod.GdefTable,

    pub fn applyFeatures(
        self: GsubTable,
        allocator: std.mem.Allocator,
        script_tag: [4]u8,
        lang_tag: ?[4]u8,
        feature_tags: []const [4]u8,
        glyphs: []const u16,
    ) ![]u16 {
        const lang_sys_offset = otlayout.findLangSysOffset(
            self.data,
            self.script_list_offset,
            script_tag,
            lang_tag,
        ) orelse {
            const result = try allocator.alloc(u16, glyphs.len);
            @memcpy(result, glyphs);
            return result;
        };

        const lookup_indices = try otlayout.collectLookupIndices(
            allocator,
            self.data,
            self.feature_list_offset,
            lang_sys_offset,
            feature_tags,
        );
        defer allocator.free(lookup_indices);

        var buf = std.ArrayListUnmanaged(u16).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, glyphs);

        for (lookup_indices) |lookup_idx| {
            try self.applyLookup(allocator, lookup_idx, &buf);
        }

        return buf.toOwnedSlice(allocator);
    }

    fn applyLookup(self: GsubTable, allocator: std.mem.Allocator, lookup_index: u16, glyphs: *std.ArrayListUnmanaged(u16)) !void {
        const info = otlayout.getLookupInfo(self.data, self.lookup_list_offset, lookup_index) orelse return;

        var si: usize = 0;
        while (si < info.subtable_count) : (si += 1) {
            const sub_abs = otlayout.getSubtableOffset(self.data, info.base_offset, si) orelse break;

            var effective_type = info.lookup_type;
            var effective_offset = sub_abs;

            if (info.lookup_type == 7) {
                const ext = otlayout.parseExtensionSubtable(self.data, sub_abs) orelse continue;
                effective_type = ext.effective_type;
                effective_offset = ext.effective_offset;
            }

            switch (effective_type) {
                1 => applySingleSubst(self.data, effective_offset, glyphs, self.gdef, info.lookup_flag),
                2 => try applyMultipleSubst(self.data, effective_offset, glyphs, allocator, self.gdef, info.lookup_flag),
                3 => applyAlternateSubst(self.data, effective_offset, glyphs, self.gdef, info.lookup_flag),
                4 => applyLigatureSubst(self.data, effective_offset, glyphs, self.gdef, info.lookup_flag),
                5 => try self.applyContextSubst(allocator, effective_offset, glyphs),
                6 => try self.applyChainingContextSubst(allocator, effective_offset, glyphs),
                else => {},
            }
        }
    }

    fn applyContextSubst(self: GsubTable, allocator: std.mem.Allocator, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16)) !void {
        if (subtable_offset + 2 > self.data.len) return;
        const format = parser.readU16(self.data, subtable_offset) catch return;

        switch (format) {
            1 => {
                if (subtable_offset + 6 > self.data.len) return;
                const cov_offset = parser.readU16(self.data, subtable_offset + 2) catch return;
                const coverage = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_offset)) catch return;
                const sub_rule_set_count = parser.readU16(self.data, subtable_offset + 4) catch return;

                var i: usize = 0;
                while (i < glyphs.items.len) {
                    const glyph_id = glyphs.items[i];
                    const cov_idx = coverage.getCoverageIndex(glyph_id) orelse {
                        i += 1;
                        continue;
                    };
                    if (cov_idx >= sub_rule_set_count) {
                        i += 1;
                        continue;
                    }

                    const srs_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
                    if (srs_offset_pos + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }
                    const srs_offset = parser.readU16(self.data, srs_offset_pos) catch {
                        i += 1;
                        continue;
                    };
                    if (srs_offset == 0) {
                        i += 1;
                        continue;
                    }
                    const srs_base = subtable_offset + @as(usize, srs_offset);
                    if (srs_base + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }

                    const sub_rule_count = parser.readU16(self.data, srs_base) catch {
                        i += 1;
                        continue;
                    };

                    var matched = false;
                    var ri: usize = 0;
                    while (ri < sub_rule_count) : (ri += 1) {
                        const rule_offset_pos = srs_base + 2 + ri * 2;
                        if (rule_offset_pos + 2 > self.data.len) break;
                        const rule_offset = parser.readU16(self.data, rule_offset_pos) catch break;
                        const rule_base = srs_base + @as(usize, rule_offset);
                        if (rule_base + 4 > self.data.len) continue;

                        const glyph_count = parser.readU16(self.data, rule_base) catch continue;
                        const subst_count = parser.readU16(self.data, rule_base + 2) catch continue;
                        if (glyph_count == 0) continue;

                        const input_count = glyph_count - 1;
                        if (i + 1 + input_count > glyphs.items.len) continue;

                        var all_match = true;
                        var ci: usize = 0;
                        while (ci < input_count) : (ci += 1) {
                            const input_offset = rule_base + 4 + ci * 2;
                            if (input_offset + 2 > self.data.len) {
                                all_match = false;
                                break;
                            }
                            const expected = parser.readU16(self.data, input_offset) catch {
                                all_match = false;
                                break;
                            };
                            if (glyphs.items[i + 1 + ci] != expected) {
                                all_match = false;
                                break;
                            }
                        }

                        if (all_match) {
                            const records_offset = rule_base + 4 + @as(usize, input_count) * 2;
                            const old_len = glyphs.items.len;
                            try self.applyNestedLookups(allocator, glyphs, i, self.data, records_offset, subst_count);
                            const len_delta = @as(i32, @intCast(glyphs.items.len)) - @as(i32, @intCast(old_len));
                            i = @as(usize, @intCast(@as(i32, @intCast(i + glyph_count)) + len_delta));
                            matched = true;
                            break;
                        }
                    }

                    if (!matched) {
                        i += 1;
                    }
                }
            },
            2 => {
                if (subtable_offset + 8 > self.data.len) return;
                const cov_offset = parser.readU16(self.data, subtable_offset + 2) catch return;
                const coverage = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_offset)) catch return;
                const class_def_offset = parser.readU16(self.data, subtable_offset + 4) catch return;
                const class_def = otlayout.parseClassDef(self.data, subtable_offset + @as(usize, class_def_offset)) catch return;
                const sub_class_set_count = parser.readU16(self.data, subtable_offset + 6) catch return;

                var i: usize = 0;
                while (i < glyphs.items.len) {
                    const glyph_id = glyphs.items[i];
                    _ = coverage.getCoverageIndex(glyph_id) orelse {
                        i += 1;
                        continue;
                    };

                    const class_val = class_def.getClass(glyph_id);
                    if (class_val >= sub_class_set_count) {
                        i += 1;
                        continue;
                    }

                    const scs_offset_pos = subtable_offset + 8 + @as(usize, class_val) * 2;
                    if (scs_offset_pos + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }
                    const scs_offset = parser.readU16(self.data, scs_offset_pos) catch {
                        i += 1;
                        continue;
                    };
                    if (scs_offset == 0) {
                        i += 1;
                        continue;
                    }
                    const scs_base = subtable_offset + @as(usize, scs_offset);
                    if (scs_base + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }

                    const sub_class_rule_count = parser.readU16(self.data, scs_base) catch {
                        i += 1;
                        continue;
                    };

                    var matched = false;
                    var ri: usize = 0;
                    while (ri < sub_class_rule_count) : (ri += 1) {
                        const rule_offset_pos = scs_base + 2 + ri * 2;
                        if (rule_offset_pos + 2 > self.data.len) break;
                        const rule_offset = parser.readU16(self.data, rule_offset_pos) catch break;
                        const rule_base = scs_base + @as(usize, rule_offset);
                        if (rule_base + 4 > self.data.len) continue;

                        const glyph_count = parser.readU16(self.data, rule_base) catch continue;
                        const subst_count = parser.readU16(self.data, rule_base + 2) catch continue;
                        if (glyph_count == 0) continue;

                        const input_count = glyph_count - 1;
                        if (i + 1 + input_count > glyphs.items.len) continue;

                        var all_match = true;
                        var ci: usize = 0;
                        while (ci < input_count) : (ci += 1) {
                            const input_offset = rule_base + 4 + ci * 2;
                            if (input_offset + 2 > self.data.len) {
                                all_match = false;
                                break;
                            }
                            const expected_class = parser.readU16(self.data, input_offset) catch {
                                all_match = false;
                                break;
                            };
                            const actual_class = class_def.getClass(glyphs.items[i + 1 + ci]);
                            if (actual_class != expected_class) {
                                all_match = false;
                                break;
                            }
                        }

                        if (all_match) {
                            const records_offset = rule_base + 4 + @as(usize, input_count) * 2;
                            const old_len = glyphs.items.len;
                            try self.applyNestedLookups(allocator, glyphs, i, self.data, records_offset, subst_count);
                            const len_delta = @as(i32, @intCast(glyphs.items.len)) - @as(i32, @intCast(old_len));
                            i = @as(usize, @intCast(@as(i32, @intCast(i + glyph_count)) + len_delta));
                            matched = true;
                            break;
                        }
                    }

                    if (!matched) {
                        i += 1;
                    }
                }
            },
            3 => {
                if (subtable_offset + 6 > self.data.len) return;
                const glyph_count = parser.readU16(self.data, subtable_offset + 2) catch return;
                const subst_count = parser.readU16(self.data, subtable_offset + 4) catch return;
                if (glyph_count == 0) return;

                var i: usize = 0;
                while (i + @as(usize, glyph_count) <= glyphs.items.len) {
                    var all_match = true;
                    var ci: usize = 0;
                    while (ci < glyph_count) : (ci += 1) {
                        const cov_off_pos = subtable_offset + 6 + ci * 2;
                        if (cov_off_pos + 2 > self.data.len) {
                            all_match = false;
                            break;
                        }
                        const cov_off = parser.readU16(self.data, cov_off_pos) catch {
                            all_match = false;
                            break;
                        };
                        const cov = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_off)) catch {
                            all_match = false;
                            break;
                        };
                        if (cov.getCoverageIndex(glyphs.items[i + ci]) == null) {
                            all_match = false;
                            break;
                        }
                    }

                    if (all_match) {
                        const records_offset = subtable_offset + 6 + @as(usize, glyph_count) * 2;
                        const old_len = glyphs.items.len;
                        try self.applyNestedLookups(allocator, glyphs, i, self.data, records_offset, subst_count);
                        const len_delta = @as(i32, @intCast(glyphs.items.len)) - @as(i32, @intCast(old_len));
                        i = @as(usize, @intCast(@as(i32, @intCast(i + glyph_count)) + len_delta));
                    } else {
                        i += 1;
                    }
                }
            },
            else => {},
        }
    }

    fn applyChainingContextSubst(self: GsubTable, allocator: std.mem.Allocator, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16)) !void {
        if (subtable_offset + 2 > self.data.len) return;
        const format = parser.readU16(self.data, subtable_offset) catch return;

        switch (format) {
            1 => {
                if (subtable_offset + 6 > self.data.len) return;
                const cov_offset = parser.readU16(self.data, subtable_offset + 2) catch return;
                const coverage = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_offset)) catch return;
                const chain_sub_rule_set_count = parser.readU16(self.data, subtable_offset + 4) catch return;

                var i: usize = 0;
                while (i < glyphs.items.len) {
                    const glyph_id = glyphs.items[i];
                    const cov_idx = coverage.getCoverageIndex(glyph_id) orelse {
                        i += 1;
                        continue;
                    };
                    if (cov_idx >= chain_sub_rule_set_count) {
                        i += 1;
                        continue;
                    }

                    const csrs_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
                    if (csrs_offset_pos + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }
                    const csrs_offset = parser.readU16(self.data, csrs_offset_pos) catch {
                        i += 1;
                        continue;
                    };
                    if (csrs_offset == 0) {
                        i += 1;
                        continue;
                    }
                    const csrs_base = subtable_offset + @as(usize, csrs_offset);
                    if (csrs_base + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }

                    const chain_rule_count = parser.readU16(self.data, csrs_base) catch {
                        i += 1;
                        continue;
                    };

                    var matched = false;
                    var ri: usize = 0;
                    while (ri < chain_rule_count) : (ri += 1) {
                        const rule_offset_pos = csrs_base + 2 + ri * 2;
                        if (rule_offset_pos + 2 > self.data.len) break;
                        const rule_offset = parser.readU16(self.data, rule_offset_pos) catch break;
                        const rule_base = csrs_base + @as(usize, rule_offset);
                        if (rule_base + 2 > self.data.len) continue;

                        var pos: usize = rule_base;

                        const bt_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        if (i < bt_count) continue;
                        var bt_match = true;
                        var bi: usize = 0;
                        while (bi < bt_count) : (bi += 1) {
                            if (pos + 2 > self.data.len) {
                                bt_match = false;
                                break;
                            }
                            const expected = parser.readU16(self.data, pos) catch {
                                bt_match = false;
                                break;
                            };
                            pos += 2;
                            if (glyphs.items[i - 1 - bi] != expected) {
                                bt_match = false;
                                break;
                            }
                        }
                        if (!bt_match) continue;

                        if (pos + 2 > self.data.len) continue;
                        const input_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        if (input_count == 0) continue;
                        const actual_input = input_count - 1;
                        if (i + 1 + actual_input > glyphs.items.len) continue;
                        var in_match = true;
                        var ii: usize = 0;
                        while (ii < actual_input) : (ii += 1) {
                            if (pos + 2 > self.data.len) {
                                in_match = false;
                                break;
                            }
                            const expected = parser.readU16(self.data, pos) catch {
                                in_match = false;
                                break;
                            };
                            pos += 2;
                            if (glyphs.items[i + 1 + ii] != expected) {
                                in_match = false;
                                break;
                            }
                        }
                        if (!in_match) continue;

                        if (pos + 2 > self.data.len) continue;
                        const la_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        const lookahead_start = i + input_count;
                        if (lookahead_start + la_count > glyphs.items.len) continue;
                        var la_match = true;
                        var lai: usize = 0;
                        while (lai < la_count) : (lai += 1) {
                            if (pos + 2 > self.data.len) {
                                la_match = false;
                                break;
                            }
                            const expected = parser.readU16(self.data, pos) catch {
                                la_match = false;
                                break;
                            };
                            pos += 2;
                            if (glyphs.items[lookahead_start + lai] != expected) {
                                la_match = false;
                                break;
                            }
                        }
                        if (!la_match) continue;

                        if (pos + 2 > self.data.len) continue;
                        const subst_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        const old_len = glyphs.items.len;
                        try self.applyNestedLookups(allocator, glyphs, i, self.data, pos, subst_count);
                        const len_delta = @as(i32, @intCast(glyphs.items.len)) - @as(i32, @intCast(old_len));
                        i = @as(usize, @intCast(@as(i32, @intCast(i + input_count)) + len_delta));
                        matched = true;
                        break;
                    }

                    if (!matched) {
                        i += 1;
                    }
                }
            },
            2 => {
                if (subtable_offset + 12 > self.data.len) return;
                const cov_offset = parser.readU16(self.data, subtable_offset + 2) catch return;
                const coverage = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_offset)) catch return;
                const bt_class_def_offset = parser.readU16(self.data, subtable_offset + 4) catch return;
                const bt_class_def = otlayout.parseClassDef(self.data, subtable_offset + @as(usize, bt_class_def_offset)) catch return;
                const in_class_def_offset = parser.readU16(self.data, subtable_offset + 6) catch return;
                const in_class_def = otlayout.parseClassDef(self.data, subtable_offset + @as(usize, in_class_def_offset)) catch return;
                const la_class_def_offset = parser.readU16(self.data, subtable_offset + 8) catch return;
                const la_class_def = otlayout.parseClassDef(self.data, subtable_offset + @as(usize, la_class_def_offset)) catch return;
                const chain_sub_class_set_count = parser.readU16(self.data, subtable_offset + 10) catch return;

                var i: usize = 0;
                while (i < glyphs.items.len) {
                    const glyph_id = glyphs.items[i];
                    _ = coverage.getCoverageIndex(glyph_id) orelse {
                        i += 1;
                        continue;
                    };

                    const class_val = in_class_def.getClass(glyph_id);
                    if (class_val >= chain_sub_class_set_count) {
                        i += 1;
                        continue;
                    }

                    const cscs_offset_pos = subtable_offset + 12 + @as(usize, class_val) * 2;
                    if (cscs_offset_pos + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }
                    const cscs_offset = parser.readU16(self.data, cscs_offset_pos) catch {
                        i += 1;
                        continue;
                    };
                    if (cscs_offset == 0) {
                        i += 1;
                        continue;
                    }
                    const cscs_base = subtable_offset + @as(usize, cscs_offset);
                    if (cscs_base + 2 > self.data.len) {
                        i += 1;
                        continue;
                    }

                    const chain_rule_count = parser.readU16(self.data, cscs_base) catch {
                        i += 1;
                        continue;
                    };

                    var matched = false;
                    var ri: usize = 0;
                    while (ri < chain_rule_count) : (ri += 1) {
                        const rule_offset_pos = cscs_base + 2 + ri * 2;
                        if (rule_offset_pos + 2 > self.data.len) break;
                        const rule_offset = parser.readU16(self.data, rule_offset_pos) catch break;
                        const rule_base = cscs_base + @as(usize, rule_offset);
                        if (rule_base + 2 > self.data.len) continue;

                        var pos: usize = rule_base;

                        const bt_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        if (i < bt_count) continue;
                        var bt_match = true;
                        var bi: usize = 0;
                        while (bi < bt_count) : (bi += 1) {
                            if (pos + 2 > self.data.len) {
                                bt_match = false;
                                break;
                            }
                            const expected_class = parser.readU16(self.data, pos) catch {
                                bt_match = false;
                                break;
                            };
                            pos += 2;
                            const actual_class = bt_class_def.getClass(glyphs.items[i - 1 - bi]);
                            if (actual_class != expected_class) {
                                bt_match = false;
                                break;
                            }
                        }
                        if (!bt_match) continue;

                        if (pos + 2 > self.data.len) continue;
                        const input_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        if (input_count == 0) continue;
                        const actual_input = input_count - 1;
                        if (i + 1 + actual_input > glyphs.items.len) continue;
                        var in_match = true;
                        var ii: usize = 0;
                        while (ii < actual_input) : (ii += 1) {
                            if (pos + 2 > self.data.len) {
                                in_match = false;
                                break;
                            }
                            const expected_class = parser.readU16(self.data, pos) catch {
                                in_match = false;
                                break;
                            };
                            pos += 2;
                            const actual_class = in_class_def.getClass(glyphs.items[i + 1 + ii]);
                            if (actual_class != expected_class) {
                                in_match = false;
                                break;
                            }
                        }
                        if (!in_match) continue;

                        if (pos + 2 > self.data.len) continue;
                        const la_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        const lookahead_start = i + input_count;
                        if (lookahead_start + la_count > glyphs.items.len) continue;
                        var la_match = true;
                        var lai: usize = 0;
                        while (lai < la_count) : (lai += 1) {
                            if (pos + 2 > self.data.len) {
                                la_match = false;
                                break;
                            }
                            const expected_class = parser.readU16(self.data, pos) catch {
                                la_match = false;
                                break;
                            };
                            pos += 2;
                            const actual_class = la_class_def.getClass(glyphs.items[lookahead_start + lai]);
                            if (actual_class != expected_class) {
                                la_match = false;
                                break;
                            }
                        }
                        if (!la_match) continue;

                        if (pos + 2 > self.data.len) continue;
                        const subst_count = parser.readU16(self.data, pos) catch continue;
                        pos += 2;
                        const old_len = glyphs.items.len;
                        try self.applyNestedLookups(allocator, glyphs, i, self.data, pos, subst_count);
                        const len_delta = @as(i32, @intCast(glyphs.items.len)) - @as(i32, @intCast(old_len));
                        i = @as(usize, @intCast(@as(i32, @intCast(i + input_count)) + len_delta));
                        matched = true;
                        break;
                    }

                    if (!matched) {
                        i += 1;
                    }
                }
            },
            3 => {
                var pos: usize = subtable_offset + 2;

                if (pos + 2 > self.data.len) return;
                const bt_count = parser.readU16(self.data, pos) catch return;
                pos += 2;

                const bt_cov_start = pos;
                pos += @as(usize, bt_count) * 2;

                if (pos + 2 > self.data.len) return;
                const input_count = parser.readU16(self.data, pos) catch return;
                pos += 2;
                if (input_count == 0) return;

                const in_cov_start = pos;
                pos += @as(usize, input_count) * 2;

                if (pos + 2 > self.data.len) return;
                const la_count = parser.readU16(self.data, pos) catch return;
                pos += 2;

                const la_cov_start = pos;
                pos += @as(usize, la_count) * 2;

                if (pos + 2 > self.data.len) return;
                const subst_count = parser.readU16(self.data, pos) catch return;
                pos += 2;
                const records_offset = pos;

                var i: usize = 0;
                while (i < glyphs.items.len) {
                    if (i + input_count > glyphs.items.len) {
                        i += 1;
                        continue;
                    }

                    if (i < bt_count) {
                        i += 1;
                        continue;
                    }

                    var in_match = true;
                    var ci: usize = 0;
                    while (ci < input_count) : (ci += 1) {
                        const cov_off_pos = in_cov_start + ci * 2;
                        if (cov_off_pos + 2 > self.data.len) {
                            in_match = false;
                            break;
                        }
                        const cov_off = parser.readU16(self.data, cov_off_pos) catch {
                            in_match = false;
                            break;
                        };
                        const cov = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_off)) catch {
                            in_match = false;
                            break;
                        };
                        if (cov.getCoverageIndex(glyphs.items[i + ci]) == null) {
                            in_match = false;
                            break;
                        }
                    }
                    if (!in_match) {
                        i += 1;
                        continue;
                    }

                    var bt_match = true;
                    var bi: usize = 0;
                    while (bi < bt_count) : (bi += 1) {
                        const cov_off_pos = bt_cov_start + bi * 2;
                        if (cov_off_pos + 2 > self.data.len) {
                            bt_match = false;
                            break;
                        }
                        const cov_off = parser.readU16(self.data, cov_off_pos) catch {
                            bt_match = false;
                            break;
                        };
                        const cov = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_off)) catch {
                            bt_match = false;
                            break;
                        };
                        if (cov.getCoverageIndex(glyphs.items[i - 1 - bi]) == null) {
                            bt_match = false;
                            break;
                        }
                    }
                    if (!bt_match) {
                        i += 1;
                        continue;
                    }

                    const lookahead_start = i + input_count;
                    if (lookahead_start + la_count > glyphs.items.len) {
                        i += 1;
                        continue;
                    }
                    var la_match = true;
                    var lai: usize = 0;
                    while (lai < la_count) : (lai += 1) {
                        const cov_off_pos = la_cov_start + lai * 2;
                        if (cov_off_pos + 2 > self.data.len) {
                            la_match = false;
                            break;
                        }
                        const cov_off = parser.readU16(self.data, cov_off_pos) catch {
                            la_match = false;
                            break;
                        };
                        const cov = otlayout.parseCoverage(self.data, subtable_offset + @as(usize, cov_off)) catch {
                            la_match = false;
                            break;
                        };
                        if (cov.getCoverageIndex(glyphs.items[lookahead_start + lai]) == null) {
                            la_match = false;
                            break;
                        }
                    }
                    if (!la_match) {
                        i += 1;
                        continue;
                    }

                    const old_len = glyphs.items.len;
                    try self.applyNestedLookups(allocator, glyphs, i, self.data, records_offset, subst_count);
                    const len_delta = @as(i32, @intCast(glyphs.items.len)) - @as(i32, @intCast(old_len));
                    i = @as(usize, @intCast(@as(i32, @intCast(i + input_count)) + len_delta));
                }
            },
            else => {},
        }
    }

    fn applyNestedLookups(self: GsubTable, allocator: std.mem.Allocator, glyphs: *std.ArrayListUnmanaged(u16), match_start: usize, data: []const u8, records_offset: usize, subst_count: u16) !void {
        var offset_delta: i32 = 0;
        var ri: usize = 0;
        while (ri < subst_count) : (ri += 1) {
            const rec_pos = records_offset + ri * 4;
            if (rec_pos + 4 > data.len) break;
            const seq_idx = parser.readU16(data, rec_pos) catch break;
            const lookup_idx = parser.readU16(data, rec_pos + 2) catch break;

            const adjusted_pos = @as(i32, @intCast(match_start)) + @as(i32, @intCast(seq_idx)) + offset_delta;
            if (adjusted_pos < 0) continue;
            const pos = @as(usize, @intCast(adjusted_pos));
            if (pos >= glyphs.items.len) continue;

            const old_len = glyphs.items.len;
            try self.applyLookupAtPosition(allocator, lookup_idx, glyphs, pos);
            offset_delta += @as(i32, @intCast(glyphs.items.len)) - @as(i32, @intCast(old_len));
        }
    }

    fn applyLookupAtPosition(self: GsubTable, allocator: std.mem.Allocator, lookup_index: u16, glyphs: *std.ArrayListUnmanaged(u16), pos: usize) !void {
        if (pos >= glyphs.items.len) return;

        const info = otlayout.getLookupInfo(self.data, self.lookup_list_offset, lookup_index) orelse return;

        var si: usize = 0;
        while (si < info.subtable_count) : (si += 1) {
            const sub_abs = otlayout.getSubtableOffset(self.data, info.base_offset, si) orelse break;

            var effective_type = info.lookup_type;
            var effective_offset = sub_abs;

            if (info.lookup_type == 7) {
                const ext = otlayout.parseExtensionSubtable(self.data, sub_abs) orelse continue;
                effective_type = ext.effective_type;
                effective_offset = ext.effective_offset;
            }

            switch (effective_type) {
                1 => {
                    if (applySingleSubstAtPos(self.data, effective_offset, glyphs, pos, self.gdef, info.lookup_flag)) return;
                },
                2 => {
                    if (try applyMultipleSubstAtPos(self.data, effective_offset, glyphs, pos, allocator, self.gdef, info.lookup_flag)) return;
                },
                3 => {
                    if (applyAlternateSubstAtPos(self.data, effective_offset, glyphs, pos, self.gdef, info.lookup_flag)) return;
                },
                4 => {
                    if (applyLigatureSubstAtPos(self.data, effective_offset, glyphs, pos, self.gdef, info.lookup_flag)) return;
                },
                else => {},
            }
        }
    }
};

fn applySingleSubst(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), gdef: ?gdef_mod.GdefTable, lookup_flag: u16) void {
    if (subtable_offset + 6 > data.len) return;
    const format = parser.readU16(data, subtable_offset) catch return;
    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return;

    switch (format) {
        1 => {
            const delta_raw = parser.readI16(data, subtable_offset + 4) catch return;
            const delta: i32 = delta_raw;
            for (glyphs.items) |*g| {
                if (shouldSkipGlyph(gdef, g.*, lookup_flag)) continue;
                if (coverage.getCoverageIndex(g.*) != null) {
                    const new_id = @as(i32, g.*) + delta;
                    g.* = @intCast(@as(u32, @bitCast(new_id)) & 0xFFFF);
                }
            }
        },
        2 => {
            const glyph_count = parser.readU16(data, subtable_offset + 4) catch return;
            for (glyphs.items) |*g| {
                if (shouldSkipGlyph(gdef, g.*, lookup_flag)) continue;
                const cov_idx = coverage.getCoverageIndex(g.*) orelse continue;
                if (cov_idx >= glyph_count) continue;
                const sub_offset = subtable_offset + 6 + @as(usize, cov_idx) * 2;
                const substitute = parser.readU16(data, sub_offset) catch continue;
                g.* = substitute;
            }
        },
        else => {},
    }
}

fn applyLigatureSubst(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), gdef: ?gdef_mod.GdefTable, lookup_flag: u16) void {
    if (subtable_offset + 6 > data.len) return;
    const format = parser.readU16(data, subtable_offset) catch return;
    if (format != 1) return;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return;
    const lig_set_count = parser.readU16(data, subtable_offset + 4) catch return;

    var i: usize = 0;
    while (i < glyphs.items.len) {
        const glyph_id = glyphs.items[i];
        if (shouldSkipGlyph(gdef, glyph_id, lookup_flag)) {
            i += 1;
            continue;
        }
        const cov_idx = coverage.getCoverageIndex(glyph_id) orelse {
            i += 1;
            continue;
        };
        if (cov_idx >= lig_set_count) {
            i += 1;
            continue;
        }

        const ls_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
        if (ls_offset_pos + 2 > data.len) {
            i += 1;
            continue;
        }
        const ls_offset = parser.readU16(data, ls_offset_pos) catch {
            i += 1;
            continue;
        };
        const ls_base = subtable_offset + @as(usize, ls_offset);
        if (ls_base + 2 > data.len) {
            i += 1;
            continue;
        }

        const lig_count = parser.readU16(data, ls_base) catch {
            i += 1;
            continue;
        };

        var matched = false;
        var li: usize = 0;
        while (li < lig_count) : (li += 1) {
            const lig_offset_pos = ls_base + 2 + li * 2;
            if (lig_offset_pos + 2 > data.len) break;
            const lig_offset = parser.readU16(data, lig_offset_pos) catch break;
            const lig_base = ls_base + @as(usize, lig_offset);
            if (lig_base + 4 > data.len) continue;

            const lig_glyph = parser.readU16(data, lig_base) catch continue;
            const comp_count = parser.readU16(data, lig_base + 2) catch continue;
            if (comp_count == 0) continue;

            const components_needed = comp_count - 1;
            if (i + components_needed >= glyphs.items.len) continue;

            var components_match = true;
            var ci: usize = 0;
            while (ci < components_needed) : (ci += 1) {
                const comp_offset = lig_base + 4 + ci * 2;
                if (comp_offset + 2 > data.len) {
                    components_match = false;
                    break;
                }
                const expected = parser.readU16(data, comp_offset) catch {
                    components_match = false;
                    break;
                };
                if (glyphs.items[i + 1 + ci] != expected) {
                    components_match = false;
                    break;
                }
            }

            if (components_match) {
                glyphs.items[i] = lig_glyph;
                var removed: usize = 0;
                while (removed < components_needed) : (removed += 1) {
                    _ = glyphs.orderedRemove(i + 1);
                }
                matched = true;
                break;
            }
        }

        if (!matched) {
            i += 1;
        }
    }
}

fn applyMultipleSubst(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), allocator: std.mem.Allocator, gdef: ?gdef_mod.GdefTable, lookup_flag: u16) !void {
    if (subtable_offset + 6 > data.len) return;
    const format = parser.readU16(data, subtable_offset) catch return;
    if (format != 1) return;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return;
    const seq_count = parser.readU16(data, subtable_offset + 4) catch return;

    var i: usize = glyphs.items.len;
    while (i > 0) {
        i -= 1;
        const glyph_id = glyphs.items[i];
        if (shouldSkipGlyph(gdef, glyph_id, lookup_flag)) continue;
        const cov_idx = coverage.getCoverageIndex(glyph_id) orelse continue;
        if (cov_idx >= seq_count) continue;

        const seq_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
        if (seq_offset_pos + 2 > data.len) continue;
        const seq_offset = parser.readU16(data, seq_offset_pos) catch continue;
        const seq_base = subtable_offset + @as(usize, seq_offset);
        if (seq_base + 2 > data.len) continue;

        const glyph_count = parser.readU16(data, seq_base) catch continue;

        if (glyph_count == 0) {
            _ = glyphs.orderedRemove(i);
        } else {
            const first_sub = parser.readU16(data, seq_base + 2) catch continue;
            glyphs.items[i] = first_sub;

            var si: usize = 1;
            while (si < glyph_count) : (si += 1) {
                const sub_offset = seq_base + 2 + si * 2;
                if (sub_offset + 2 > data.len) break;
                const sub_glyph = parser.readU16(data, sub_offset) catch break;
                try glyphs.insert(allocator, i + si, sub_glyph);
            }
        }
    }
}

fn applyAlternateSubst(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), gdef: ?gdef_mod.GdefTable, lookup_flag: u16) void {
    if (subtable_offset + 6 > data.len) return;
    const format = parser.readU16(data, subtable_offset) catch return;
    if (format != 1) return;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return;
    const alt_set_count = parser.readU16(data, subtable_offset + 4) catch return;

    for (glyphs.items) |*g| {
        if (shouldSkipGlyph(gdef, g.*, lookup_flag)) continue;
        const cov_idx = coverage.getCoverageIndex(g.*) orelse continue;
        if (cov_idx >= alt_set_count) continue;

        const alt_set_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
        if (alt_set_offset_pos + 2 > data.len) continue;
        const alt_set_offset = parser.readU16(data, alt_set_offset_pos) catch continue;
        const alt_set_base = subtable_offset + @as(usize, alt_set_offset);
        if (alt_set_base + 4 > data.len) continue;

        const alt_count = parser.readU16(data, alt_set_base) catch continue;
        if (alt_count == 0) continue;

        const first_alt = parser.readU16(data, alt_set_base + 2) catch continue;
        g.* = first_alt;
    }
}

fn applySingleSubstAtPos(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), pos: usize, gdef: ?gdef_mod.GdefTable, lookup_flag: u16) bool {
    if (pos >= glyphs.items.len) return false;
    if (shouldSkipGlyph(gdef, glyphs.items[pos], lookup_flag)) return false;
    if (subtable_offset + 6 > data.len) return false;
    const format = parser.readU16(data, subtable_offset) catch return false;
    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return false;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return false;

    const cov_idx = coverage.getCoverageIndex(glyphs.items[pos]) orelse return false;

    switch (format) {
        1 => {
            const delta_raw = parser.readI16(data, subtable_offset + 4) catch return false;
            const new_id = @as(i32, glyphs.items[pos]) + @as(i32, delta_raw);
            glyphs.items[pos] = @intCast(@as(u32, @bitCast(new_id)) & 0xFFFF);
            return true;
        },
        2 => {
            const glyph_count = parser.readU16(data, subtable_offset + 4) catch return false;
            if (cov_idx >= glyph_count) return false;
            const sub_offset = subtable_offset + 6 + @as(usize, cov_idx) * 2;
            const substitute = parser.readU16(data, sub_offset) catch return false;
            glyphs.items[pos] = substitute;
            return true;
        },
        else => return false,
    }
}

fn applyMultipleSubstAtPos(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), pos: usize, allocator: std.mem.Allocator, gdef: ?gdef_mod.GdefTable, lookup_flag: u16) !bool {
    if (pos >= glyphs.items.len) return false;
    if (shouldSkipGlyph(gdef, glyphs.items[pos], lookup_flag)) return false;
    if (subtable_offset + 6 > data.len) return false;
    const format = parser.readU16(data, subtable_offset) catch return false;
    if (format != 1) return false;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return false;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return false;
    const seq_count = parser.readU16(data, subtable_offset + 4) catch return false;

    const cov_idx = coverage.getCoverageIndex(glyphs.items[pos]) orelse return false;
    if (cov_idx >= seq_count) return false;

    const seq_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
    if (seq_offset_pos + 2 > data.len) return false;
    const seq_offset = parser.readU16(data, seq_offset_pos) catch return false;
    const seq_base = subtable_offset + @as(usize, seq_offset);
    if (seq_base + 2 > data.len) return false;

    const glyph_count = parser.readU16(data, seq_base) catch return false;

    if (glyph_count == 0) {
        _ = glyphs.orderedRemove(pos);
        return true;
    }

    const first_sub = parser.readU16(data, seq_base + 2) catch return false;
    glyphs.items[pos] = first_sub;

    var si: usize = 1;
    while (si < glyph_count) : (si += 1) {
        const sub_off = seq_base + 2 + si * 2;
        if (sub_off + 2 > data.len) break;
        const sub_glyph = parser.readU16(data, sub_off) catch break;
        try glyphs.insert(allocator, pos + si, sub_glyph);
    }

    return true;
}

fn applyAlternateSubstAtPos(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), pos: usize, gdef: ?gdef_mod.GdefTable, lookup_flag: u16) bool {
    if (pos >= glyphs.items.len) return false;
    if (shouldSkipGlyph(gdef, glyphs.items[pos], lookup_flag)) return false;
    if (subtable_offset + 6 > data.len) return false;
    const format = parser.readU16(data, subtable_offset) catch return false;
    if (format != 1) return false;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return false;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return false;
    const alt_set_count = parser.readU16(data, subtable_offset + 4) catch return false;

    const cov_idx = coverage.getCoverageIndex(glyphs.items[pos]) orelse return false;
    if (cov_idx >= alt_set_count) return false;

    const alt_set_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
    if (alt_set_offset_pos + 2 > data.len) return false;
    const alt_set_offset = parser.readU16(data, alt_set_offset_pos) catch return false;
    const alt_set_base = subtable_offset + @as(usize, alt_set_offset);
    if (alt_set_base + 4 > data.len) return false;

    const alt_count = parser.readU16(data, alt_set_base) catch return false;
    if (alt_count == 0) return false;

    const first_alt = parser.readU16(data, alt_set_base + 2) catch return false;
    glyphs.items[pos] = first_alt;
    return true;
}

fn applyLigatureSubstAtPos(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16), pos: usize, gdef: ?gdef_mod.GdefTable, lookup_flag: u16) bool {
    if (pos >= glyphs.items.len) return false;
    if (shouldSkipGlyph(gdef, glyphs.items[pos], lookup_flag)) return false;
    if (subtable_offset + 6 > data.len) return false;
    const format = parser.readU16(data, subtable_offset) catch return false;
    if (format != 1) return false;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return false;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return false;
    const lig_set_count = parser.readU16(data, subtable_offset + 4) catch return false;

    const glyph_id = glyphs.items[pos];
    const cov_idx = coverage.getCoverageIndex(glyph_id) orelse return false;
    if (cov_idx >= lig_set_count) return false;

    const ls_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
    if (ls_offset_pos + 2 > data.len) return false;
    const ls_offset = parser.readU16(data, ls_offset_pos) catch return false;
    const ls_base = subtable_offset + @as(usize, ls_offset);
    if (ls_base + 2 > data.len) return false;

    const lig_count = parser.readU16(data, ls_base) catch return false;

    var li: usize = 0;
    while (li < lig_count) : (li += 1) {
        const lig_offset_pos = ls_base + 2 + li * 2;
        if (lig_offset_pos + 2 > data.len) break;
        const lig_offset = parser.readU16(data, lig_offset_pos) catch break;
        const lig_base = ls_base + @as(usize, lig_offset);
        if (lig_base + 4 > data.len) continue;

        const lig_glyph = parser.readU16(data, lig_base) catch continue;
        const comp_count = parser.readU16(data, lig_base + 2) catch continue;
        if (comp_count == 0) continue;

        const components_needed = comp_count - 1;
        if (pos + components_needed >= glyphs.items.len) continue;

        var components_match = true;
        var ci: usize = 0;
        while (ci < components_needed) : (ci += 1) {
            const comp_offset = lig_base + 4 + ci * 2;
            if (comp_offset + 2 > data.len) {
                components_match = false;
                break;
            }
            const expected = parser.readU16(data, comp_offset) catch {
                components_match = false;
                break;
            };
            if (glyphs.items[pos + 1 + ci] != expected) {
                components_match = false;
                break;
            }
        }

        if (components_match) {
            glyphs.items[pos] = lig_glyph;
            var removed: usize = 0;
            while (removed < components_needed) : (removed += 1) {
                _ = glyphs.orderedRemove(pos + 1);
            }
            return true;
        }
    }

    return false;
}

pub fn parse(data: []const u8, gdef: ?gdef_mod.GdefTable) !GsubTable {
    if (data.len < 10) return error.UnexpectedEof;
    const major_version = try parser.readU16(data, 0);
    if (major_version != 1) return error.InvalidVersion;

    return .{
        .data = data,
        .script_list_offset = try parser.readU16(data, 4),
        .feature_list_offset = try parser.readU16(data, 6),
        .lookup_list_offset = try parser.readU16(data, 8),
        .gdef = gdef,
    };
}

// ============================================================
// Tests
// ============================================================

test "Single Substitution Format 1: delta" {
    const data = [_]u8{
        0x00, 0x01, // substFormat = 1
        0x00, 0x06, // coverageOffset = 6
        0x00, 0x05, // deltaGlyphID = 5
        0x00, 0x01, // coverage format = 1
        0x00, 0x02, // glyphCount = 2
        0x00, 0x0A, // glyph 10
        0x00, 0x14, // glyph 20
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 10, 15, 20, 30 });

    applySingleSubst(&data, 0, &glyphs, null, 0);

    try std.testing.expectEqual(@as(u16, 15), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 15), glyphs.items[1]);
    try std.testing.expectEqual(@as(u16, 25), glyphs.items[2]);
    try std.testing.expectEqual(@as(u16, 30), glyphs.items[3]);
}

test "Single Substitution Format 2: direct mapping" {
    const data = [_]u8{
        0x00, 0x02, // substFormat = 2
        0x00, 0x0A, // coverageOffset = 10
        0x00, 0x02, // glyphCount = 2
        0x00, 0x64, // substituteGlyphIDs[0] = 100
        0x00, 0xC8, // substituteGlyphIDs[1] = 200
        0x00, 0x01, // coverage format = 1
        0x00, 0x02, // glyphCount = 2
        0x00, 0x0A, // glyph 10
        0x00, 0x14, // glyph 20
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 10, 15, 20 });

    applySingleSubst(&data, 0, &glyphs, null, 0);

    try std.testing.expectEqual(@as(u16, 100), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 15), glyphs.items[1]);
    try std.testing.expectEqual(@as(u16, 200), glyphs.items[2]);
}

test "Ligature Substitution: f + i -> fi" {
    const data = [_]u8{
        0x00, 0x01, // substFormat = 1
        0x00, 0x08, // coverageOffset = 8
        0x00, 0x01, // ligatureSetCount = 1
        0x00, 0x0E, // ligatureSetOffsets[0] = 14
        0x00, 0x01, // coverage format = 1
        0x00, 0x01, // glyphCount = 1
        0x00, 0x28, // glyph 40
        0x00, 0x01, // ligatureCount = 1
        0x00, 0x04, // ligatureOffsets[0] = 4
        0x00, 0x63, // ligatureGlyph = 99
        0x00, 0x02, // componentCount = 2
        0x00, 0x29, // componentGlyphIDs[0] = 41
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 40, 41, 42 });

    applyLigatureSubst(&data, 0, &glyphs, null, 0);

    try std.testing.expectEqual(@as(usize, 2), glyphs.items.len);
    try std.testing.expectEqual(@as(u16, 99), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 42), glyphs.items[1]);
}

test "parse GSUB table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const gsub_record = p.findTable(offset_table, "GSUB".*) orelse return;
    const gsub_data = try p.getTableData(font_data, gsub_record);
    const gsub = try parse(gsub_data, null);

    try std.testing.expect(gsub.script_list_offset > 0);
    try std.testing.expect(gsub.feature_list_offset > 0);
    try std.testing.expect(gsub.lookup_list_offset > 0);
}

test "GSUB liga feature with DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const font_mod = @import("../font.zig");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const gsub = font.getGsubTable() orelse return;

    const glyph_f = try font.getGlyphId('f');
    const glyph_i = try font.getGlyphId('i');
    try std.testing.expect(glyph_f > 0);
    try std.testing.expect(glyph_i > 0);

    const input = [_]u16{ glyph_f, glyph_i };
    const feature_tags = [_][4]u8{"liga".*};

    const result_latn = try gsub.applyFeatures(
        std.testing.allocator,
        "latn".*,
        null,
        &feature_tags,
        &input,
    );
    defer std.testing.allocator.free(result_latn);

    if (result_latn.len < input.len) {
        try std.testing.expect(result_latn.len == 1);
        try std.testing.expect(result_latn[0] != glyph_f);
        try std.testing.expect(result_latn[0] != glyph_i);
        return;
    }

    const result_dflt = try gsub.applyFeatures(
        std.testing.allocator,
        "DFLT".*,
        null,
        &feature_tags,
        &input,
    );
    defer std.testing.allocator.free(result_dflt);

    if (result_dflt.len < input.len) {
        try std.testing.expect(result_dflt.len == 1);
        try std.testing.expect(result_dflt[0] != glyph_f);
        try std.testing.expect(result_dflt[0] != glyph_i);
    }
}

test "Multiple Substitution: 1 glyph to 3 glyphs" {
    const data = [_]u8{
        0x00, 0x01, // substFormat = 1
        0x00, 0x08, // coverageOffset = 8
        0x00, 0x01, // sequenceCount = 1
        0x00, 0x0E, // sequenceOffsets[0] = 14
        0x00, 0x01, // coverage format = 1
        0x00, 0x01, // glyphCount = 1
        0x00, 0x0A, // glyph 10
        0x00, 0x03, // sequence glyphCount = 3
        0x00, 0x14, // glyph 20
        0x00, 0x15, // glyph 21
        0x00, 0x16, // glyph 22
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 5, 10, 15 });

    try applyMultipleSubst(&data, 0, &glyphs, std.testing.allocator, null, 0);

    try std.testing.expectEqual(@as(usize, 5), glyphs.items.len);
    try std.testing.expectEqual(@as(u16, 5), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 20), glyphs.items[1]);
    try std.testing.expectEqual(@as(u16, 21), glyphs.items[2]);
    try std.testing.expectEqual(@as(u16, 22), glyphs.items[3]);
    try std.testing.expectEqual(@as(u16, 15), glyphs.items[4]);
}

test "Alternate Substitution: glyph 10 to first alternate 100" {
    const data = [_]u8{
        0x00, 0x01, // substFormat = 1
        0x00, 0x08, // coverageOffset = 8
        0x00, 0x01, // alternateSetCount = 1
        0x00, 0x0E, // alternateSetOffsets[0] = 14
        0x00, 0x01, // coverage format = 1
        0x00, 0x01, // glyphCount = 1
        0x00, 0x0A, // glyph 10
        0x00, 0x02, // alternate glyphCount = 2
        0x00, 0x64, // glyph 100
        0x00, 0xC8, // glyph 200
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 5, 10, 15 });

    applyAlternateSubst(&data, 0, &glyphs, null, 0);

    try std.testing.expectEqual(@as(usize, 3), glyphs.items.len);
    try std.testing.expectEqual(@as(u16, 5), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 100), glyphs.items[1]);
    try std.testing.expectEqual(@as(u16, 15), glyphs.items[2]);
}

test "GSUB chaining context with DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const font_mod = @import("../font.zig");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const gsub = font.getGsubTable() orelse return;

    const glyph_f = try font.getGlyphId('f');
    const glyph_i = try font.getGlyphId('i');
    const input = [_]u16{ glyph_f, glyph_i };
    const feature_tags = [_][4]u8{"liga".*};

    const result = try gsub.applyFeatures(
        std.testing.allocator,
        "latn".*,
        null,
        &feature_tags,
        &input,
    );
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 0);
}
