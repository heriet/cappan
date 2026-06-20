const std = @import("std");

pub const err = @import("error.zig");

pub const font = struct {
    pub const parser = @import("font/parser.zig");
    pub const glyph = @import("font/glyph.zig");
    pub const charstring = @import("font/charstring.zig");
    pub const Font = @import("font/font.zig").Font;
    pub const woff = @import("font/woff.zig");
    pub const woff2 = @import("font/woff2.zig");
    pub const woff2_glyf = @import("font/woff2_glyf.zig");
    pub const table = struct {
        pub const head = @import("font/table/head.zig");
        pub const maxp = @import("font/table/maxp.zig");
        pub const hhea = @import("font/table/hhea.zig");
        pub const cmap = @import("font/table/cmap.zig");
        pub const loca = @import("font/table/loca.zig");
        pub const glyf = @import("font/table/glyf.zig");
        pub const hmtx = @import("font/table/hmtx.zig");
        pub const kern = @import("font/table/kern.zig");
        pub const otlayout = @import("font/table/otlayout.zig");
        pub const gpos = @import("font/table/gpos.zig");
        pub const gsub = @import("font/table/gsub.zig");
        pub const gdef = @import("font/table/gdef.zig");
        pub const cff = @import("font/table/cff.zig");
        pub const colr = @import("font/table/colr.zig");
        pub const cpal = @import("font/table/cpal.zig");
        pub const cblc = @import("font/table/cblc.zig");
        pub const cbdt = @import("font/table/cbdt.zig");
        pub const name = @import("font/table/name.zig");
        pub const fvar = @import("font/table/fvar.zig");
        pub const gvar = @import("font/table/gvar.zig");
        pub const avar = @import("font/table/avar.zig");
        pub const hvar = @import("font/table/hvar.zig");
        pub const item_variation_store = @import("font/table/item_variation_store.zig");
        pub const vhea = @import("font/table/vhea.zig");
        pub const vmtx = @import("font/table/vmtx.zig");
        pub const vvar = @import("font/table/vvar.zig");
        pub const mvar = @import("font/table/mvar.zig");
        pub const stat = @import("font/table/stat.zig");
    };
};

pub const raster = struct {
    pub const outline = @import("raster/outline.zig");
    pub const scanline = @import("raster/scanline.zig");
    pub const rasterizer = @import("raster/rasterizer.zig");
    pub const glyph_cache = @import("raster/glyph_cache.zig");
    pub const atlas = @import("raster/atlas.zig");
};

pub const layout = struct {
    pub const shaper = @import("layout/shaper.zig");
};

pub const render = struct {
    pub const bitmap = @import("render/bitmap.zig");
    pub const rgba_bitmap = @import("render/rgba_bitmap.zig");
    pub const gamma = @import("render/gamma.zig");
    pub const renderer = @import("render/renderer.zig");
    pub const incremental = @import("render/incremental.zig");
    pub const glyph_reveal = @import("render/glyph_reveal.zig");
};

pub const image = struct {
    pub const png_decoder = @import("image/png_decoder.zig");
};

pub const compress = struct {
    pub const brotli = @import("compress/brotli.zig");
};

test {
    _ = @import("error.zig");
    _ = @import("font/parser.zig");
    _ = @import("font/woff.zig");
    _ = @import("font/woff2.zig");
    _ = @import("font/woff2_glyf.zig");
    _ = @import("font/font.zig");
    _ = @import("font/table/head.zig");
    _ = @import("font/table/maxp.zig");
    _ = @import("font/table/hhea.zig");
    _ = @import("font/table/cmap.zig");
    _ = @import("font/table/loca.zig");
    _ = @import("font/table/glyf.zig");
    _ = @import("font/table/hmtx.zig");
    _ = @import("font/table/kern.zig");
    _ = @import("font/table/otlayout.zig");
    _ = @import("font/table/gpos.zig");
    _ = @import("font/table/gsub.zig");
    _ = @import("font/table/gdef.zig");
    _ = @import("font/table/cff.zig");
    _ = @import("font/table/colr.zig");
    _ = @import("font/table/cpal.zig");
    _ = @import("font/table/cblc.zig");
    _ = @import("font/table/cbdt.zig");
    _ = @import("font/table/name.zig");
    _ = @import("font/table/avar.zig");
    _ = @import("font/table/hvar.zig");
    _ = @import("font/table/item_variation_store.zig");
    _ = @import("font/table/vhea.zig");
    _ = @import("font/table/vmtx.zig");
    _ = @import("font/table/vvar.zig");
    _ = @import("font/table/mvar.zig");
    _ = @import("font/table/stat.zig");
    _ = @import("font/charstring.zig");
    _ = @import("raster/outline.zig");
    _ = @import("raster/scanline.zig");
    _ = @import("raster/rasterizer.zig");
    _ = @import("raster/glyph_cache.zig");
    _ = @import("raster/atlas.zig");
    _ = @import("layout/shaper.zig");
    _ = @import("render/bitmap.zig");
    _ = @import("render/rgba_bitmap.zig");
    _ = @import("render/gamma.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/incremental.zig");
    _ = @import("render/glyph_reveal.zig");
    _ = @import("render/reveal/sweep.zig");
    _ = @import("render/reveal/fade.zig");
    _ = @import("render/reveal/contour_trace.zig");
    _ = @import("render/reveal/medial_axis.zig");
    _ = @import("image/png_decoder.zig");
    _ = @import("compress/brotli.zig");
    _ = @import("test_integration.zig");
}
