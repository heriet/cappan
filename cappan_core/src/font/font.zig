const std = @import("std");
const parser = @import("parser.zig");
const glyph_mod = @import("glyph.zig");
const head_mod = @import("table/head.zig");
const maxp_mod = @import("table/maxp.zig");
const hhea_mod = @import("table/hhea.zig");
const cmap_mod = @import("table/cmap.zig");
const loca_mod = @import("table/loca.zig");
const glyf_mod = @import("table/glyf.zig");
const hmtx_mod = @import("table/hmtx.zig");
const kern_mod = @import("table/kern.zig");
const gpos_mod = @import("table/gpos.zig");
const gsub_mod = @import("table/gsub.zig");
const gdef_mod = @import("table/gdef.zig");
const cff_mod = @import("table/cff.zig");
const colr_mod = @import("table/colr.zig");
const cpal_mod = @import("table/cpal.zig");
const cblc_mod = @import("table/cblc.zig");
const cbdt_mod = @import("table/cbdt.zig");
const name_mod = @import("table/name.zig");
const fvar_mod = @import("table/fvar.zig");
const gvar_mod = @import("table/gvar.zig");
const avar_mod = @import("table/avar.zig");
const hvar_mod = @import("table/hvar.zig");
const vhea_mod = @import("table/vhea.zig");
const vmtx_mod = @import("table/vmtx.zig");
const vorg_mod = @import("table/vorg.zig");
const vvar_mod = @import("table/vvar.zig");
const mvar_mod = @import("table/mvar.zig");
const stat_mod = @import("table/stat.zig");
const os2_mod = @import("table/os2.zig");
const auto_hinting_mod = @import("../raster/auto_hinting.zig");
const charstring_mod = @import("charstring.zig");
const rasterizer_mod = @import("../raster/rasterizer.zig");
const woff_mod = @import("woff.zig");
const woff2_mod = @import("woff2.zig");
const err_mod = @import("../error.zig");
const ft = @import("../features.zig").features;

pub const RasterResult = rasterizer_mod.RasterResult;

pub const VerticalSubstituter = struct {
    allocator: std.mem.Allocator,
    gsub: if (ft.enable_opentype_layout) ?gsub_mod.GsubTable else void,
    lookup_indices: []const u16,

    pub fn init(allocator: std.mem.Allocator, font: *const Font) VerticalSubstituter {
        if (comptime !ft.enable_vertical or !ft.enable_opentype_layout) {
            return .{ .allocator = allocator, .gsub = {}, .lookup_indices = &.{} };
        }

        const gsub = font.gsub orelse {
            return .{ .allocator = allocator, .gsub = null, .lookup_indices = &.{} };
        };

        const scripts = [_][4]u8{ "kana".*, "hani".*, "hang".*, "DFLT".*, "latn".* };
        const features = [_][4]u8{ "vrt2".*, "vert".* };
        for (scripts) |script| {
            for (features) |feature| {
                const indices = gsub.resolveLookupIndices(allocator, script, null, &.{feature}) catch continue;
                if (indices.len != 0) {
                    return .{ .allocator = allocator, .gsub = gsub, .lookup_indices = indices };
                }
                allocator.free(indices);
            }
        }

        return .{ .allocator = allocator, .gsub = gsub, .lookup_indices = &.{} };
    }

    pub fn substitute(self: VerticalSubstituter, glyph_id: u16) u16 {
        if (comptime !ft.enable_vertical or !ft.enable_opentype_layout) return glyph_id;
        if (self.lookup_indices.len == 0) return glyph_id;
        const gsub = self.gsub orelse return glyph_id;

        var input = [_]u16{glyph_id};
        const result = gsub.applyLookupIndices(self.allocator, self.lookup_indices, &input) catch return glyph_id;
        defer self.allocator.free(result);
        if (result.len == 1 and result[0] != glyph_id) return result[0];
        return glyph_id;
    }

    pub fn deinit(self: VerticalSubstituter) void {
        if (comptime ft.enable_vertical and ft.enable_opentype_layout) {
            if (self.lookup_indices.len != 0) self.allocator.free(self.lookup_indices);
        }
    }
};

pub const Font = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    owned_data: ?[]u8, // non-null when Font owns the data (e.g. WOFF conversion)
    offset_table: parser.OffsetTable,
    head: head_mod.HeadTable,
    maxp: maxp_mod.MaxpTable,
    hhea: hhea_mod.HheaTable,
    cmap: cmap_mod.CmapTable,
    loca: ?loca_mod.LocaTable,
    glyf: ?glyf_mod.GlyfTable,
    hmtx: hmtx_mod.HmtxTable,
    kern: ?kern_mod.KernTable,
    gpos: if (ft.enable_opentype_layout) ?gpos_mod.GposTable else void,
    gsub: if (ft.enable_opentype_layout) ?gsub_mod.GsubTable else void,
    gdef: if (ft.enable_opentype_layout) ?gdef_mod.GdefTable else void,
    cff: if (ft.enable_cff) ?cff_mod.CffTable else void,
    colr: if (ft.enable_color) ?colr_mod.ColrTable else void,
    cpal: if (ft.enable_color) ?cpal_mod.CpalTable else void,
    cblc: if (ft.enable_bitmap) ?cblc_mod.CblcTable else void,
    cbdt: if (ft.enable_bitmap) ?cbdt_mod.CbdtTable else void,
    name: ?name_mod.NameTable,
    fvar: if (ft.enable_variable) ?fvar_mod.FvarTable else void,
    gvar: if (ft.enable_variable) ?gvar_mod.GvarTable else void,
    avar: if (ft.enable_variable) ?avar_mod.AvarTable else void,
    hvar: if (ft.enable_variable) ?hvar_mod.HvarTable else void,
    vhea: if (ft.enable_vertical) ?vhea_mod.VheaTable else void,
    vmtx: if (ft.enable_vertical) ?vmtx_mod.VmtxTable else void,
    vorg: if (ft.enable_vertical) ?vorg_mod.VorgTable else void,
    vvar: if (ft.enable_variable) ?vvar_mod.VvarTable else void,
    mvar: if (ft.enable_variable) ?mvar_mod.MvarTable else void,
    stat: if (ft.enable_variable) ?stat_mod.StatTable else void,
    os2: if (ft.enable_hinting) ?os2_mod.Os2Table else void,

    pub fn init(allocator: std.mem.Allocator, data: []const u8, diag: ?*err_mod.Diagnostics) !Font {
        if (comptime ft.enable_woff) {
            if (woff_mod.isWoffFile(data)) {
                const sfnt_data = try woff_mod.woffToSfnt(allocator, data);
                errdefer allocator.free(sfnt_data);
                var font = try if (parser.isTtcFile(sfnt_data))
                    initCollectionIndex(allocator, sfnt_data, 0, diag)
                else
                    initAt(allocator, sfnt_data, 0, diag);
                font.owned_data = sfnt_data;
                return font;
            }
        }
        if (comptime ft.enable_woff2) {
            if (woff2_mod.isWoff2File(data)) {
                const sfnt_data = try woff2_mod.woff2ToSfnt(allocator, data);
                errdefer allocator.free(sfnt_data);
                var font = try if (parser.isTtcFile(sfnt_data))
                    initCollectionIndex(allocator, sfnt_data, 0, diag)
                else
                    initAt(allocator, sfnt_data, 0, diag);
                font.owned_data = sfnt_data;
                return font;
            }
        }
        if (parser.isTtcFile(data)) {
            return initCollectionIndex(allocator, data, 0, diag);
        }
        return initAt(allocator, data, 0, diag);
    }

    pub fn initCollectionIndex(allocator: std.mem.Allocator, data: []const u8, font_index: u32, diag: ?*err_mod.Diagnostics) !Font {
        const ttc_header = try parser.parseTtcHeader(allocator, data);
        defer allocator.free(ttc_header.offsets);

        if (font_index >= ttc_header.num_fonts) {
            if (diag) |d| {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "font index {d} exceeds collection size {d}", .{ font_index, ttc_header.num_fonts }) catch "font index out of range";
                d.addError(allocator, .{}, msg) catch {};
            }
            return error.InvalidFontIndex;
        }

        const font_index_usize: usize = @intCast(font_index);
        return initAt(allocator, data, ttc_header.offsets[font_index_usize], diag);
    }

    pub fn countFontsInCollection(allocator: std.mem.Allocator, data: []const u8) !u32 {
        const ttc_header = try parser.parseTtcHeader(allocator, data);
        defer allocator.free(ttc_header.offsets);
        return ttc_header.num_fonts;
    }

    fn initAt(allocator: std.mem.Allocator, data: []const u8, start_offset: u32, diag: ?*err_mod.Diagnostics) !Font {
        const offset_table = try parser.parseOffsetTableAt(allocator, data, start_offset);
        errdefer allocator.free(offset_table.table_records);

        const head_record = parser.findTable(offset_table, "head".*) orelse {
            if (diag) |d| d.addError(allocator, .{ .table_tag = "head".* }, "required table 'head' not found") catch {};
            return error.TableNotFound;
        };
        const head = try head_mod.parse(try parser.getTableData(data, head_record));

        const maxp_record = parser.findTable(offset_table, "maxp".*) orelse {
            if (diag) |d| d.addError(allocator, .{ .table_tag = "maxp".* }, "required table 'maxp' not found") catch {};
            return error.TableNotFound;
        };
        const maxp = try maxp_mod.parse(try parser.getTableData(data, maxp_record));

        const hhea_record = parser.findTable(offset_table, "hhea".*) orelse {
            if (diag) |d| d.addError(allocator, .{ .table_tag = "hhea".* }, "required table 'hhea' not found") catch {};
            return error.TableNotFound;
        };
        const hhea = try hhea_mod.parse(try parser.getTableData(data, hhea_record));

        const cmap_record = parser.findTable(offset_table, "cmap".*) orelse {
            if (diag) |d| d.addError(allocator, .{ .table_tag = "cmap".* }, "required table 'cmap' not found") catch {};
            return error.TableNotFound;
        };
        const cmap = try cmap_mod.parse(try parser.getTableData(data, cmap_record));

        // CFF/TrueType 分岐
        const is_cff = offset_table.sfnt_version == 0x4F54544F;

        var loca_table: ?loca_mod.LocaTable = null;
        var glyf_table: ?glyf_mod.GlyfTable = null;
        var cff_table: if (ft.enable_cff) ?cff_mod.CffTable else void = if (comptime ft.enable_cff) null else {};

        if (is_cff) {
            if (comptime ft.enable_cff) {
                const cff_record = parser.findTable(offset_table, "CFF ".*) orelse {
                    if (diag) |d| d.addError(allocator, .{ .table_tag = "CFF ".* }, "required table 'CFF ' not found") catch {};
                    return error.TableNotFound;
                };
                const cff_data = try parser.getTableData(data, cff_record);
                cff_table = try cff_mod.parseCff(allocator, cff_data);
            } else {
                if (diag) |d| d.addError(allocator, .{}, "CFF font not supported (feature disabled)") catch {};
                return error.CffNotSupported;
            }
        } else {
            const loca_record = parser.findTable(offset_table, "loca".*) orelse {
                if (diag) |d| d.addError(allocator, .{ .table_tag = "loca".* }, "required table 'loca' not found") catch {};
                return error.TableNotFound;
            };
            loca_table = loca_mod.parse(try parser.getTableData(data, loca_record), head.index_to_loc_format, maxp.num_glyphs);
            const glyf_record = parser.findTable(offset_table, "glyf".*) orelse {
                if (diag) |d| d.addError(allocator, .{ .table_tag = "glyf".* }, "required table 'glyf' not found") catch {};
                return error.TableNotFound;
            };
            glyf_table = glyf_mod.parse(try parser.getTableData(data, glyf_record));
        }

        const hmtx_record = parser.findTable(offset_table, "hmtx".*) orelse {
            if (diag) |d| d.addError(allocator, .{ .table_tag = "hmtx".* }, "required table 'hmtx' not found") catch {};
            return error.TableNotFound;
        };
        const hmtx = hmtx_mod.parse(try parser.getTableData(data, hmtx_record), hhea.number_of_h_metrics);

        const kern_table: ?kern_mod.KernTable = blk: {
            const kern_record = parser.findTable(offset_table, "kern".*);
            if (kern_record) |rec| {
                const kern_data = try parser.getTableData(data, rec);
                break :blk kern_mod.parse(kern_data) catch null;
            } else {
                break :blk null;
            }
        };

        const gpos_table: if (ft.enable_opentype_layout) ?gpos_mod.GposTable else void = if (comptime ft.enable_opentype_layout) blk: {
            const gpos_record = parser.findTable(offset_table, "GPOS".*);
            if (gpos_record) |rec| {
                const gpos_data = try parser.getTableData(data, rec);
                break :blk gpos_mod.parse(allocator, gpos_data) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => null,
                };
            } else {
                break :blk null;
            }
        } else {};
        const gdef_table: if (ft.enable_opentype_layout) ?gdef_mod.GdefTable else void = if (comptime ft.enable_opentype_layout) blk: {
            const gdef_record = parser.findTable(offset_table, "GDEF".*);
            if (gdef_record) |rec| {
                const gdef_data = try parser.getTableData(data, rec);
                break :blk gdef_mod.parse(gdef_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const gsub_table: if (ft.enable_opentype_layout) ?gsub_mod.GsubTable else void = if (comptime ft.enable_opentype_layout) blk: {
            const gsub_record = parser.findTable(offset_table, "GSUB".*);
            if (gsub_record) |rec| {
                const gsub_data = try parser.getTableData(data, rec);
                break :blk gsub_mod.parse(gsub_data, gdef_table) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const colr_table: if (ft.enable_color) ?colr_mod.ColrTable else void = if (comptime ft.enable_color) blk: {
            const colr_record = parser.findTable(offset_table, "COLR".*);
            if (colr_record) |rec| {
                const colr_data = try parser.getTableData(data, rec);
                break :blk colr_mod.parse(colr_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const cpal_table: if (ft.enable_color) ?cpal_mod.CpalTable else void = if (comptime ft.enable_color) blk: {
            const cpal_record = parser.findTable(offset_table, "CPAL".*);
            if (cpal_record) |rec| {
                const cpal_data = try parser.getTableData(data, rec);
                break :blk cpal_mod.parse(cpal_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const cblc_table: if (ft.enable_bitmap) ?cblc_mod.CblcTable else void = if (comptime ft.enable_bitmap) blk: {
            const cblc_record = parser.findTable(offset_table, "CBLC".*);
            if (cblc_record) |rec| {
                const cblc_data = try parser.getTableData(data, rec);
                break :blk cblc_mod.parse(cblc_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const cbdt_table: if (ft.enable_bitmap) ?cbdt_mod.CbdtTable else void = if (comptime ft.enable_bitmap) blk: {
            const cbdt_record = parser.findTable(offset_table, "CBDT".*);
            if (cbdt_record) |rec| {
                const cbdt_data = try parser.getTableData(data, rec);
                break :blk cbdt_mod.parse(cbdt_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const name_table: ?name_mod.NameTable = blk: {
            const name_record = parser.findTable(offset_table, "name".*);
            if (name_record) |rec| {
                const name_data_raw = try parser.getTableData(data, rec);
                break :blk name_mod.parse(name_data_raw) catch null;
            } else {
                break :blk null;
            }
        };
        const fvar_table: if (ft.enable_variable) ?fvar_mod.FvarTable else void = if (comptime ft.enable_variable) blk: {
            const fvar_record = parser.findTable(offset_table, "fvar".*);
            if (fvar_record) |rec| {
                const fvar_data = try parser.getTableData(data, rec);
                break :blk fvar_mod.parse(fvar_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const gvar_table: if (ft.enable_variable) ?gvar_mod.GvarTable else void = if (comptime ft.enable_variable) blk: {
            const gvar_record = parser.findTable(offset_table, "gvar".*);
            if (gvar_record) |rec| {
                const gvar_data = try parser.getTableData(data, rec);
                break :blk gvar_mod.parse(gvar_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const avar_table: if (ft.enable_variable) ?avar_mod.AvarTable else void = if (comptime ft.enable_variable) blk: {
            const avar_record = parser.findTable(offset_table, "avar".*);
            if (avar_record) |rec| {
                const avar_data = try parser.getTableData(data, rec);
                break :blk avar_mod.parse(avar_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const hvar_table: if (ft.enable_variable) ?hvar_mod.HvarTable else void = if (comptime ft.enable_variable) blk: {
            const hvar_record = parser.findTable(offset_table, "HVAR".*);
            if (hvar_record) |rec| {
                const hvar_data = try parser.getTableData(data, rec);
                break :blk hvar_mod.parse(hvar_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const vhea_table: if (ft.enable_vertical) ?vhea_mod.VheaTable else void = if (comptime ft.enable_vertical) blk: {
            const vhea_record = parser.findTable(offset_table, "vhea".*);
            if (vhea_record) |rec| {
                const vhea_data = try parser.getTableData(data, rec);
                break :blk vhea_mod.parse(vhea_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const vmtx_table: if (ft.enable_vertical) ?vmtx_mod.VmtxTable else void = if (comptime ft.enable_vertical) blk: {
            if (vhea_table) |vhea| {
                const vmtx_record = parser.findTable(offset_table, "vmtx".*);
                if (vmtx_record) |rec| {
                    const vmtx_data = try parser.getTableData(data, rec);
                    break :blk vmtx_mod.parse(vmtx_data, vhea.number_of_v_metrics);
                }
            }
            break :blk null;
        } else {};
        const vorg_table: if (ft.enable_vertical) ?vorg_mod.VorgTable else void = if (comptime ft.enable_vertical) blk: {
            const vorg_record = parser.findTable(offset_table, "VORG".*);
            if (vorg_record) |rec| {
                const vorg_data = try parser.getTableData(data, rec);
                break :blk vorg_mod.parse(vorg_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const vvar_table: if (ft.enable_variable) ?vvar_mod.VvarTable else void = if (comptime ft.enable_variable) blk: {
            const vvar_record = parser.findTable(offset_table, "VVAR".*);
            if (vvar_record) |rec| {
                const vvar_data = try parser.getTableData(data, rec);
                break :blk vvar_mod.parse(vvar_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const mvar_table: if (ft.enable_variable) ?mvar_mod.MvarTable else void = if (comptime ft.enable_variable) blk: {
            const mvar_record = parser.findTable(offset_table, "MVAR".*);
            if (mvar_record) |rec| {
                const mvar_data = try parser.getTableData(data, rec);
                break :blk mvar_mod.parse(mvar_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const stat_table: if (ft.enable_variable) ?stat_mod.StatTable else void = if (comptime ft.enable_variable) blk: {
            const stat_record = parser.findTable(offset_table, "STAT".*);
            if (stat_record) |rec| {
                const stat_data = try parser.getTableData(data, rec);
                break :blk stat_mod.parse(stat_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        const os2_table: if (ft.enable_hinting) ?os2_mod.Os2Table else void = if (comptime ft.enable_hinting) blk: {
            const os2_record = parser.findTable(offset_table, "OS/2".*);
            if (os2_record) |rec| {
                const os2_data = try parser.getTableData(data, rec);
                break :blk os2_mod.parse(os2_data) catch null;
            } else {
                break :blk null;
            }
        } else {};
        return .{
            .allocator = allocator,
            .data = data,
            .owned_data = null,
            .offset_table = offset_table,
            .head = head,
            .maxp = maxp,
            .hhea = hhea,
            .cmap = cmap,
            .loca = loca_table,
            .glyf = glyf_table,
            .hmtx = hmtx,
            .kern = kern_table,
            .gpos = gpos_table,
            .gsub = gsub_table,
            .gdef = gdef_table,
            .cff = cff_table,
            .colr = colr_table,
            .cpal = cpal_table,
            .cblc = cblc_table,
            .cbdt = cbdt_table,
            .name = name_table,
            .fvar = fvar_table,
            .gvar = gvar_table,
            .avar = avar_table,
            .hvar = hvar_table,
            .vhea = vhea_table,
            .vmtx = vmtx_table,
            .vorg = vorg_table,
            .vvar = vvar_table,
            .mvar = mvar_table,
            .stat = stat_table,
            .os2 = os2_table,
        };
    }

    pub fn deinit(self: *Font) void {
        if (comptime ft.enable_opentype_layout) {
            if (self.gpos) |*g| g.deinit();
        }
        if (comptime ft.enable_cff) {
            if (self.cff) |*c| c.deinit();
        }
        self.allocator.free(self.offset_table.table_records);
        if (self.owned_data) |od| self.allocator.free(od);
    }

    pub fn getGlyphId(self: Font, codepoint: u32) !u16 {
        return self.cmap.charToGlyphId(codepoint);
    }

    pub fn getGlyphOutline(self: Font, allocator: std.mem.Allocator, glyph_id: u16) !?glyph_mod.GlyphOutline {
        if (comptime ft.enable_cff) {
            if (self.cff) |cff_table| {
                const charstring_data = cff_table.getCharString(glyph_id) orelse return null;
                return try charstring_mod.interpret(
                    allocator,
                    charstring_data,
                    cff_table.global_subrs,
                    cff_table.getLocalSubrs(glyph_id),
                );
            }
        }
        if (self.glyf) |glyf_table| {
            return glyf_table.getGlyphOutline(allocator, glyph_id, self.loca.?);
        } else {
            return null;
        }
    }

    pub fn getBlueZones(self: Font, glyph_id: u16) ?glyph_mod.BlueZones {
        if (comptime !ft.enable_cff) return null;
        const cff_table = self.cff orelse return null;
        return cff_table.getBlueZones(glyph_id);
    }

    pub fn getAutoBlueZones(self: Font) glyph_mod.BlueZones {
        if (comptime ft.enable_hinting) {
            return auto_hinting_mod.inferBlueZones(self.os2, self.hhea.ascender, self.hhea.descender);
        } else {
            return auto_hinting_mod.inferBlueZones(null, self.hhea.ascender, self.hhea.descender);
        }
    }

    pub fn getHMetrics(self: Font, glyph_id: u16) !hmtx_mod.HMetrics {
        return self.hmtx.getMetrics(glyph_id);
    }

    fn adjustCoordsForVariation(
        self: Font,
        normalized_coords: []const f32,
        stack_buf: []f32,
    ) !struct { coords: []f32, allocated: bool } {
        var adjusted: []f32 = undefined;
        var allocated = false;
        if (normalized_coords.len <= stack_buf.len) {
            @memcpy(stack_buf[0..normalized_coords.len], normalized_coords);
            adjusted = stack_buf[0..normalized_coords.len];
        } else {
            const heap = try self.allocator.alloc(f32, normalized_coords.len);
            @memcpy(heap, normalized_coords);
            adjusted = heap;
            allocated = true;
        }

        if (comptime ft.enable_variable) {
            if (self.avar) |avar| {
                try avar.mapNormalizedCoords(adjusted);
            }
        }

        return .{ .coords = adjusted, .allocated = allocated };
    }

    pub fn getHMetricsWithVariation(self: Font, glyph_id: u16, normalized_coords: []const f32) !hmtx_mod.HMetrics {
        var metrics = try self.hmtx.getMetrics(glyph_id);
        if (comptime ft.enable_variable) {
            if (self.hvar) |hvar| {
                var buf: [16]f32 = undefined;
                const adj = try self.adjustCoordsForVariation(normalized_coords, &buf);
                defer if (adj.allocated) self.allocator.free(adj.coords);
                const aw_delta = try hvar.getAdvanceWidthDelta(glyph_id, adj.coords);
                const new_aw = @as(i32, metrics.advance_width) + aw_delta;
                metrics.advance_width = @as(u16, @intCast(std.math.clamp(new_aw, 0, std.math.maxInt(u16))));
                const lsb_delta = try hvar.getLsbDelta(glyph_id, adj.coords);
                const new_lsb = @as(i32, metrics.lsb) + lsb_delta;
                metrics.lsb = @as(i16, @intCast(std.math.clamp(new_lsb, std.math.minInt(i16), std.math.maxInt(i16))));
            }
        }
        return metrics;
    }

    pub fn getVMetrics(self: Font, glyph_id: u16) !?vmtx_mod.VMetrics {
        if (comptime !ft.enable_vertical) return null;
        if (self.vmtx) |vmtx| return try vmtx.getMetrics(glyph_id);
        return null;
    }

    pub fn getVertOriginY(self: Font, glyph_id: u16) ?i16 {
        if (comptime !ft.enable_vertical) return null;
        if (self.vorg) |vorg| return vorg.getVertOriginY(glyph_id);
        return null;
    }

    pub fn getVMetricsWithVariation(self: Font, glyph_id: u16, normalized_coords: []const f32) !?vmtx_mod.VMetrics {
        if (comptime !ft.enable_vertical) return null;
        var metrics = (try self.getVMetrics(glyph_id)) orelse return null;
        if (comptime ft.enable_variable) {
            if (self.vvar) |vvar| {
                var buf: [16]f32 = undefined;
                const adj = try self.adjustCoordsForVariation(normalized_coords, &buf);
                defer if (adj.allocated) self.allocator.free(adj.coords);
                const ah_delta = try vvar.getAdvanceHeightDelta(glyph_id, adj.coords);
                const new_ah = @as(i32, metrics.advance_height) + ah_delta;
                metrics.advance_height = @as(u16, @intCast(std.math.clamp(new_ah, 0, std.math.maxInt(u16))));
                const tsb_delta = try vvar.getTsbDelta(glyph_id, adj.coords);
                const new_tsb = @as(i32, metrics.tsb) + tsb_delta;
                metrics.tsb = @as(i16, @intCast(std.math.clamp(new_tsb, std.math.minInt(i16), std.math.maxInt(i16))));
            }
        }
        return metrics;
    }

    pub fn getMetricDelta(self: Font, tag: [4]u8, normalized_coords: []const f32) !i32 {
        if (comptime !ft.enable_variable) return 0;
        if (self.mvar) |mvar| {
            var buf: [16]f32 = undefined;
            const adj = try self.adjustCoordsForVariation(normalized_coords, &buf);
            defer if (adj.allocated) self.allocator.free(adj.coords);

            return mvar.getMetricDelta(tag, adj.coords);
        }
        return 0;
    }

    pub fn getStatTable(self: Font) ?stat_mod.StatTable {
        if (comptime !ft.enable_variable) return null;
        return self.stat;
    }

    pub fn getUnitsPerEm(self: Font) u16 {
        return self.head.units_per_em;
    }

    pub fn getAscender(self: Font) i16 {
        return self.hhea.ascender;
    }

    pub fn getDescender(self: Font) i16 {
        return self.hhea.descender;
    }

    pub fn getLineGap(self: Font) i16 {
        return self.hhea.line_gap;
    }

    pub fn getKerning(self: Font, left_glyph: u16, right_glyph: u16) i16 {
        if (comptime ft.enable_opentype_layout) {
            if (self.gpos) |gpos| {
                const value = gpos.getKerning(left_glyph, right_glyph);
                if (value != 0) return value;
            }
        }
        if (self.kern) |kern| {
            return kern.getKerning(left_glyph, right_glyph);
        }
        return 0;
    }

    pub fn getVerticalKerning(self: Font, top_glyph: u16, bottom_glyph: u16) i16 {
        if (comptime !ft.enable_vertical or !ft.enable_opentype_layout) return 0;
        if (self.gpos) |gpos| return gpos.getVerticalKerning(top_glyph, bottom_glyph);
        return 0;
    }

    pub fn getMarkBaseAnchors(self: Font, base_glyph: u16, mark_glyph: u16) ?gpos_mod.AnchorPair {
        if (comptime !ft.enable_opentype_layout) return null;
        const gpos = self.gpos orelse return null;
        return gpos.getMarkBaseAnchors(base_glyph, mark_glyph);
    }

    pub fn getMarkMarkAnchors(self: Font, mark1_glyph: u16, mark2_glyph: u16) ?gpos_mod.AnchorPair {
        if (comptime !ft.enable_opentype_layout) return null;
        const gpos = self.gpos orelse return null;
        return gpos.getMarkMarkAnchors(mark1_glyph, mark2_glyph);
    }

    pub fn getMarkLigAnchors(self: Font, lig_glyph: u16, mark_glyph: u16, component_index: u16) ?gpos_mod.AnchorPair {
        if (comptime !ft.enable_opentype_layout) return null;
        const gpos = self.gpos orelse return null;
        return gpos.getMarkLigAnchors(lig_glyph, mark_glyph, component_index);
    }

    pub fn getCursiveAnchors(self: Font, glyph: u16) ?gpos_mod.CursiveAnchors {
        if (comptime !ft.enable_opentype_layout) return null;
        const gpos = self.gpos orelse return null;
        return gpos.getCursiveAnchors(glyph);
    }

    pub fn getGsubTable(self: Font) ?gsub_mod.GsubTable {
        if (comptime !ft.enable_opentype_layout) return null;
        return self.gsub;
    }

    pub fn getGdefTable(self: Font) ?gdef_mod.GdefTable {
        if (comptime !ft.enable_opentype_layout) return null;
        return self.gdef;
    }

    pub fn applyGsubFeatures(
        self: Font,
        allocator: std.mem.Allocator,
        script_tag: [4]u8,
        lang_tag: ?[4]u8,
        feature_tags: []const [4]u8,
        glyphs: []const u16,
    ) ![]u16 {
        if (comptime ft.enable_opentype_layout) {
            if (self.gsub) |gsub| {
                return gsub.applyFeatures(allocator, script_tag, lang_tag, feature_tags, glyphs);
            }
        }
        const result = try allocator.alloc(u16, glyphs.len);
        @memcpy(result, glyphs);
        return result;
    }

    /// Substitute a single glyph for vertical writing using vrt2 first, then vert.
    pub fn substituteVerticalGlyph(self: Font, glyph_id: u16) u16 {
        if (comptime !ft.enable_vertical or !ft.enable_opentype_layout) return glyph_id;
        if (self.gsub == null) return glyph_id;
        const substituter = VerticalSubstituter.init(self.allocator, &self);
        defer substituter.deinit();
        return substituter.substitute(glyph_id);
    }

    pub fn getColorLayers(self: Font, glyph_id: u16) ?colr_mod.BaseGlyphRecord {
        if (comptime !ft.enable_color) return null;
        if (self.colr) |colr| {
            return colr.findBaseGlyph(glyph_id);
        }
        return null;
    }

    pub fn getColrV1Paint(self: Font, glyph_id: u16) ?u32 {
        if (comptime !ft.enable_colr_v1) return null;
        if (self.colr) |colr| {
            return colr.findBaseGlyphV1Paint(glyph_id);
        }
        return null;
    }

    pub fn getColorLayer(self: Font, layer_idx: u16) ?colr_mod.ColorLayer {
        if (comptime !ft.enable_color) return null;
        if (self.colr) |colr| {
            return colr.getLayer(layer_idx);
        }
        return null;
    }

    pub fn getPaletteColor(self: Font, palette_idx: u16, entry_idx: u16) ?cpal_mod.Color {
        if (comptime !ft.enable_color) return null;
        if (self.cpal) |cpal| {
            return cpal.getColor(palette_idx, entry_idx);
        }
        return null;
    }

    pub fn getBitmapGlyph(self: Font, glyph_id: u16) ?cbdt_mod.GlyphBitmap {
        if (comptime !ft.enable_bitmap) return null;
        const cblc = self.cblc orelse return null;
        const cbdt = self.cbdt orelse return null;
        const location = cblc.findGlyphBitmap(glyph_id) orelse return null;
        return cbdt.getGlyphBitmap(location);
    }

    /// Measure the total advance width of a UTF-8 string rendered at the given pixel size.
    /// Includes inter-glyph kerning. Glyphs with errors are skipped.
    pub fn measureTextWidth(self: Font, text: []const u8, pixel_size: f32) f32 {
        const scale = pixel_size / @as(f32, @floatFromInt(self.getUnitsPerEm()));
        var total: f32 = 0.0;
        var prev_glyph_id: ?u16 = null;

        if (std.unicode.Utf8View.init(text)) |view| {
            var iter = view.iterator();
            while (iter.nextCodepoint()) |codepoint| {
                const glyph_id = self.getGlyphId(codepoint) catch continue;
                const metrics = self.getHMetrics(glyph_id) catch continue;
                if (prev_glyph_id) |prev| {
                    total += @as(f32, @floatFromInt(self.getKerning(prev, glyph_id))) * scale;
                }
                total += @as(f32, @floatFromInt(metrics.advance_width)) * scale;
                prev_glyph_id = glyph_id;
            }
        } else |_| {
            for (text) |byte| {
                const glyph_id = self.getGlyphId(@as(u21, byte)) catch continue;
                const metrics = self.getHMetrics(glyph_id) catch continue;
                if (prev_glyph_id) |prev| {
                    total += @as(f32, @floatFromInt(self.getKerning(prev, glyph_id))) * scale;
                }
                total += @as(f32, @floatFromInt(metrics.advance_width)) * scale;
                prev_glyph_id = glyph_id;
            }
        }

        return total;
    }

    pub fn rasterizeCodepoint(self: Font, allocator: std.mem.Allocator, codepoint: u32, pixel_size: f32) !?RasterResult {
        const glyph_id = try self.getGlyphId(codepoint);
        if (glyph_id == 0) return null;

        var outline = (try self.getGlyphOutline(allocator, glyph_id)) orelse return null;
        defer outline.deinit();

        const scale = pixel_size / @as(f32, @floatFromInt(self.getUnitsPerEm()));
        return try rasterizer_mod.rasterizeGlyph(allocator, outline, scale, 1, .{});
    }

    pub fn getCodepointAdvancePx(self: Font, codepoint: u32, pixel_size: f32) !f32 {
        const glyph_id = try self.getGlyphId(codepoint);
        const metrics = try self.getHMetrics(glyph_id);
        const scale = pixel_size / @as(f32, @floatFromInt(self.getUnitsPerEm()));
        return @as(f32, @floatFromInt(metrics.advance_width)) * scale;
    }

    pub fn getFontFamily(self: Font, allocator: std.mem.Allocator) !?[]u8 {
        if (self.name) |name_table| {
            return try name_table.getName(allocator, .font_family);
        }
        return null;
    }

    pub fn getFontSubfamily(self: Font, allocator: std.mem.Allocator) !?[]u8 {
        if (self.name) |name_table| {
            return try name_table.getName(allocator, .font_subfamily);
        }
        return null;
    }

    pub fn getFullFontName(self: Font, allocator: std.mem.Allocator) !?[]u8 {
        if (self.name) |name_table| {
            return try name_table.getName(allocator, .full_name);
        }
        return null;
    }

    pub fn isVariableFont(self: Font) bool {
        if (comptime !ft.enable_variable) return false;
        return self.fvar != null;
    }

    pub fn getAxisCount(self: Font) u16 {
        if (comptime !ft.enable_variable) return 0;
        if (self.fvar) |fvar| return fvar.getAxisCount();
        return 0;
    }

    pub fn getAxis(self: Font, index: u16) !fvar_mod.AxisRecord {
        if (comptime !ft.enable_variable) return error.InvalidAxisIndex;
        if (self.fvar) |fvar| return fvar.getAxis(index);
        return error.InvalidAxisIndex;
    }

    pub fn getInstanceCount(self: Font) u16 {
        if (comptime !ft.enable_variable) return 0;
        if (self.fvar) |fvar| return fvar.getInstanceCount();
        return 0;
    }

    pub fn getInstance(self: Font, allocator: std.mem.Allocator, index: u16) !fvar_mod.NamedInstance {
        if (comptime !ft.enable_variable) return error.InvalidInstanceIndex;
        if (self.fvar) |fvar| return fvar.getInstance(allocator, index);
        return error.InvalidInstanceIndex;
    }

    pub fn getGlyphOutlineWithVariation(
        self: Font,
        allocator: std.mem.Allocator,
        glyph_id: u16,
        normalized_coords: []const f32,
    ) !?glyph_mod.GlyphOutline {
        if (comptime !ft.enable_variable) return self.getGlyphOutline(allocator, glyph_id);
        var buf: [16]f32 = undefined;
        const adj = try self.adjustCoordsForVariation(normalized_coords, &buf);
        defer if (adj.allocated) self.allocator.free(adj.coords);

        return self.getGlyphOutlineWithVariationRecursive(allocator, glyph_id, adj.coords, 0);
    }

    fn getGlyphOutlineWithVariationRecursive(
        self: Font,
        allocator: std.mem.Allocator,
        glyph_id: u16,
        adjusted_coords: []const f32,
        depth: u32,
    ) !?glyph_mod.GlyphOutline {
        if (depth > 10) return error.CompoundGlyphTooDeep;

        const glyf_table = self.glyf orelse return null;
        const loca_table = self.loca orelse return null;

        if (try glyf_table.getComponentInfos(allocator, glyph_id, loca_table)) |components_slice| {
            const components = components_slice;
            defer allocator.free(components);

            if (comptime ft.enable_variable) {
                if (self.gvar) |gvar| {
                    try gvar.applyCompoundDeltas(allocator, glyph_id, components, adjusted_coords);
                }
            }

            var all_contours: std.ArrayList(glyph_mod.Contour) = .empty;
            defer all_contours.deinit(allocator);

            for (components) |comp| {
                if (try self.getGlyphOutlineWithVariationRecursive(allocator, comp.glyph_id, adjusted_coords, depth + 1)) |component_outline_const| {
                    var component_outline = component_outline_const;
                    defer component_outline.deinit();
                    for (component_outline.contours) |contour| {
                        const new_points = try allocator.alloc(glyph_mod.Point, contour.points.len);
                        for (contour.points, 0..) |pt, i| {
                            if (comp.has_transform) {
                                const fx = @as(f32, @floatFromInt(pt.x));
                                const fy = @as(f32, @floatFromInt(pt.y));
                                new_points[i] = .{
                                    .x = @as(i16, @intFromFloat(@round(comp.mat_a * fx + comp.mat_c * fy))) + comp.dx,
                                    .y = @as(i16, @intFromFloat(@round(comp.mat_b * fx + comp.mat_d * fy))) + comp.dy,
                                    .on_curve = pt.on_curve,
                                };
                            } else {
                                new_points[i] = .{
                                    .x = pt.x + comp.dx,
                                    .y = pt.y + comp.dy,
                                    .on_curve = pt.on_curve,
                                };
                            }
                        }
                        try all_contours.append(allocator, .{ .points = new_points });
                    }
                }
            }

            const loc = try loca_table.getGlyphLocation(glyph_id);
            const glyph_end = std.math.add(usize, @as(usize, loc.offset), @as(usize, loc.length)) catch return error.InvalidGlyphData;
            if (glyph_end > glyf_table.data.len) return error.InvalidGlyphData;
            const glyph_data = glyf_table.data[loc.offset..glyph_end];
            const contours = try all_contours.toOwnedSlice(allocator);
            return .{
                .contours = contours,
                .x_min = try parser.readI16(glyph_data, 2),
                .y_min = try parser.readI16(glyph_data, 4),
                .x_max = try parser.readI16(glyph_data, 6),
                .y_max = try parser.readI16(glyph_data, 8),
                .allocator = allocator,
            };
        } else {
            var outline = (try self.getGlyphOutline(allocator, glyph_id)) orelse return null;
            if (comptime ft.enable_variable) {
                if (self.gvar) |gvar| {
                    try gvar.applyDeltas(allocator, glyph_id, &outline, adjusted_coords);
                }
            }
            return outline;
        }
    }
};

test "Font API integration test" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    try std.testing.expectEqual(@as(u16, 2048), font.getUnitsPerEm());
    try std.testing.expect(font.getAscender() > 0);
    try std.testing.expect(font.getDescender() < 0);

    // Look up 'A'
    const glyph_id = try font.getGlyphId(0x0041);
    try std.testing.expect(glyph_id > 0);

    // Get outline
    var outline = (try font.getGlyphOutline(std.testing.allocator, glyph_id)) orelse return error.TableNotFound;
    defer outline.deinit();
    try std.testing.expect(outline.contours.len > 0);

    // Get metrics
    const metrics = try font.getHMetrics(glyph_id);
    try std.testing.expect(metrics.advance_width > 0);
}

test "Font API CFF integration test" {
    if (comptime !ft.enable_cff) return;
    const font_data = @embedFile("../fixture/SourceSans3-Regular.otf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    try std.testing.expectEqual(@as(u16, 1000), font.getUnitsPerEm());
    try std.testing.expect(font.getAscender() > 0);
    try std.testing.expect(font.getDescender() < 0);

    try std.testing.expect(font.cff != null);
    try std.testing.expect(font.glyf == null);
    try std.testing.expect(font.loca == null);

    const glyph_id = try font.getGlyphId(0x0041);
    try std.testing.expect(glyph_id > 0);

    var outline = (try font.getGlyphOutline(std.testing.allocator, glyph_id)) orelse return error.TableNotFound;
    defer outline.deinit();
    try std.testing.expect(outline.contours.len > 0);

    const metrics = try font.getHMetrics(glyph_id);
    try std.testing.expect(metrics.advance_width > 0);
}

test "Font API TrueType still works" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    if (comptime ft.enable_cff) try std.testing.expect(font.cff == null);
    try std.testing.expect(font.glyf != null);
    try std.testing.expect(font.loca != null);

    const glyph_id = try font.getGlyphId(0x0041);
    var outline = (try font.getGlyphOutline(std.testing.allocator, glyph_id)) orelse return error.TableNotFound;
    defer outline.deinit();
    try std.testing.expect(outline.contours.len > 0);
}

test "rasterizeCodepoint returns bitmap for 'A'" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var result = (try font.rasterizeCodepoint(std.testing.allocator, 'A', 48.0)) orelse return error.TestUnexpectedResult;
    defer result.deinit();

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
    try std.testing.expect(result.pixels.len > 0);
}

test "rasterizeCodepoint returns null for missing glyph" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    // U+FFFF is unlikely to have a glyph in DejaVuSans
    const result = try font.rasterizeCodepoint(std.testing.allocator, 0x10FFFF, 48.0);
    try std.testing.expect(result == null);
}

test "getCodepointAdvancePx returns positive value" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const advance = try font.getCodepointAdvancePx('A', 48.0);
    try std.testing.expect(advance > 0.0);

    const advance_small = try font.getCodepointAdvancePx('A', 12.0);
    try std.testing.expect(advance_small > 0.0);
    try std.testing.expect(advance_small < advance);
}

test "measureTextWidth Hello" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();
    const width = font.measureTextWidth("Hello", 48.0);
    try std.testing.expect(width > 0);
}

test "Font API WOFF2 integration test" {
    if (comptime !ft.enable_woff2) return;
    const font_data = @embedFile("../fixture/DejaVuSans.woff2");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    try std.testing.expect(font.getUnitsPerEm() > 0);
    try std.testing.expect(font.getAscender() > 0);

    const glyph_id = try font.getGlyphId(0x0041);
    try std.testing.expect(glyph_id > 0);

    var outline = (try font.getGlyphOutline(std.testing.allocator, glyph_id)) orelse return error.TableNotFound;
    defer outline.deinit();
    try std.testing.expect(outline.contours.len > 0);
}

test "Variable Font fvar parsing" {
    if (comptime !ft.enable_variable) return;
    const font_data = @embedFile("../fixture/SourceSans3VF-Subset.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    try std.testing.expect(font.isVariableFont());
    try std.testing.expectEqual(@as(u16, 1), font.getAxisCount());

    const axis = try font.getAxis(0);
    try std.testing.expect(std.mem.eql(u8, &axis.tag, "wght"));
}

test "Variable Font gvar apply deltas" {
    if (comptime !ft.enable_variable) return;
    const font_data = @embedFile("../fixture/SourceSans3VF-Subset.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId(0x0041);

    var outline_default = (try font.getGlyphOutline(std.testing.allocator, glyph_id)) orelse return error.TableNotFound;
    defer outline_default.deinit();

    const normalized = [_]f32{1.0};
    var outline_bold = (try font.getGlyphOutlineWithVariation(std.testing.allocator, glyph_id, &normalized)) orelse return error.TableNotFound;
    defer outline_bold.deinit();

    try std.testing.expectEqual(outline_default.contours.len, outline_bold.contours.len);

    var differs = false;
    for (outline_default.contours, outline_bold.contours) |dc, bc| {
        for (dc.points, bc.points) |dp, bp| {
            if (dp.x != bp.x or dp.y != bp.y) {
                differs = true;
                break;
            }
        }
    }
    try std.testing.expect(differs);
}
