const std = @import("std");
const ft = @import("features.zig").features;

pub const err = @import("error.zig");
pub const features = @import("features.zig");

pub const font = struct {
    pub const parser = @import("font/parser.zig");
    pub const glyph = @import("font/glyph.zig");
    pub const sfnt_writer = @import("font/sfnt_writer.zig");
    pub const charstring = if (ft.enable_cff) @import("font/charstring.zig") else struct {};
    pub const Font = @import("font/font.zig").Font;
    pub const woff = if (ft.enable_woff) @import("font/woff.zig") else struct {};
    pub const woff2 = if (ft.enable_woff2) @import("font/woff2.zig") else struct {};
    pub const woff2_glyf = if (ft.enable_woff2) @import("font/woff2_glyf.zig") else struct {};
    pub const table = struct {
        pub const head = @import("font/table/head.zig");
        pub const maxp = @import("font/table/maxp.zig");
        pub const hhea = @import("font/table/hhea.zig");
        pub const cmap = @import("font/table/cmap.zig");
        pub const loca = @import("font/table/loca.zig");
        pub const glyf = @import("font/table/glyf.zig");
        pub const hmtx = @import("font/table/hmtx.zig");
        pub const kern = @import("font/table/kern.zig");
        pub const otlayout = if (ft.enable_opentype_layout) @import("font/table/otlayout.zig") else struct {};
        pub const gpos = if (ft.enable_opentype_layout) @import("font/table/gpos.zig") else struct {};
        pub const gsub = if (ft.enable_opentype_layout) @import("font/table/gsub.zig") else struct {};
        pub const gdef = if (ft.enable_opentype_layout) @import("font/table/gdef.zig") else struct {};
        pub const cff = if (ft.enable_cff) @import("font/table/cff.zig") else struct {};
        pub const colr = if (ft.enable_color) @import("font/table/colr.zig") else struct {};
        pub const cpal = if (ft.enable_color) @import("font/table/cpal.zig") else struct {};
        pub const cblc = if (ft.enable_bitmap) @import("font/table/cblc.zig") else struct {};
        pub const cbdt = if (ft.enable_bitmap) @import("font/table/cbdt.zig") else struct {};
        pub const name = @import("font/table/name.zig");
        pub const fvar = if (ft.enable_variable) @import("font/table/fvar.zig") else struct {};
        pub const gvar = if (ft.enable_variable) @import("font/table/gvar.zig") else struct {};
        pub const avar = if (ft.enable_variable) @import("font/table/avar.zig") else struct {};
        pub const hvar = if (ft.enable_variable) @import("font/table/hvar.zig") else struct {};
        pub const item_variation_store = if (ft.enable_variable) @import("font/table/item_variation_store.zig") else struct {};
        pub const vhea = if (ft.enable_vertical) @import("font/table/vhea.zig") else struct {};
        pub const vmtx = if (ft.enable_vertical) @import("font/table/vmtx.zig") else struct {};
        pub const vorg = if (ft.enable_vertical) @import("font/table/vorg.zig") else struct {};
        pub const vvar = if (ft.enable_variable) @import("font/table/vvar.zig") else struct {};
        pub const mvar = if (ft.enable_variable) @import("font/table/mvar.zig") else struct {};
        pub const stat = if (ft.enable_variable) @import("font/table/stat.zig") else struct {};
        // Unconditional (unlike most other feature-gated table modules here):
        // the OS/2 *table parser* itself has no hinting-specific content and is
        // used directly by cappan_embed/cappan_metrics regardless of whether
        // this cappan_core build enables hinting -- only `Font.os2` (the field
        // used internally for auto-hinting blue-zone inference, below in
        // font.zig) stays gated behind `enable_hinting`.
        pub const os2 = @import("font/table/os2.zig");
    };
};

pub const raster = struct {
    pub const outline = @import("raster/outline.zig");
    pub const scanline = @import("raster/scanline.zig");
    pub const analytical = @import("raster/analytical.zig");
    pub const rasterizer = @import("raster/rasterizer.zig");
    pub const stroker = @import("raster/stroker.zig");
    pub const glyph_cache = @import("raster/glyph_cache.zig");
    pub const atlas = @import("raster/atlas.zig");
    pub const stem_darkening = if (ft.enable_hinting) @import("raster/stem_darkening.zig") else struct {};
    pub const cff_hinting = if (ft.enable_hinting) @import("raster/cff_hinting.zig") else struct {};
    pub const auto_hinting = if (ft.enable_hinting) @import("raster/auto_hinting.zig") else struct {};
    pub const sdf = if (ft.enable_sdf) @import("raster/sdf.zig") else struct {};
    pub const msdf = if (ft.enable_sdf) @import("raster/msdf.zig") else struct {};
};

pub const layout = struct {
    pub const shaper = @import("layout/shaper.zig");
};

pub const render = struct {
    pub const bitmap = @import("render/bitmap.zig");
    pub const rgba_bitmap = @import("render/rgba_bitmap.zig");
    pub const gamma = @import("render/gamma.zig");
    pub const paint = @import("render/paint.zig");
    pub const renderer = @import("render/renderer.zig");
    pub const incremental = if (ft.enable_incremental) @import("render/incremental.zig") else struct {};
    pub const glyph_reveal = if (ft.enable_incremental) @import("render/glyph_reveal.zig") else struct {};
    pub const colr_painter = if (ft.enable_colr_v1) @import("render/colr_painter.zig") else struct {};
};

pub const image = struct {
    pub const png_decoder = if (ft.enable_bitmap) @import("image/png_decoder.zig") else struct {};
};

pub const compress = struct {
    pub const brotli = if (ft.enable_woff2) @import("compress/brotli.zig") else struct {};
};

test {
    _ = @import("error.zig");
    _ = @import("font/parser.zig");
    _ = @import("font/sfnt_writer.zig");
    if (ft.enable_woff) {
        _ = @import("font/woff.zig");
    }
    if (ft.enable_woff2) {
        _ = @import("font/woff2.zig");
        _ = @import("font/woff2_glyf.zig");
    }
    _ = @import("font/font.zig");
    _ = @import("font/table/head.zig");
    _ = @import("font/table/maxp.zig");
    _ = @import("font/table/hhea.zig");
    _ = @import("font/table/cmap.zig");
    _ = @import("font/table/loca.zig");
    _ = @import("font/table/glyf.zig");
    _ = @import("font/table/hmtx.zig");
    _ = @import("font/table/kern.zig");
    if (ft.enable_opentype_layout) {
        _ = @import("font/table/otlayout.zig");
        _ = @import("font/table/gpos.zig");
        _ = @import("font/table/gsub.zig");
        _ = @import("font/table/gdef.zig");
    }
    if (ft.enable_cff) {
        _ = @import("font/table/cff.zig");
        _ = @import("font/charstring.zig");
    }
    if (ft.enable_color) {
        _ = @import("font/table/colr.zig");
        _ = @import("font/table/cpal.zig");
    }
    if (ft.enable_colr_v1) {
        _ = @import("render/gradient.zig");
        _ = @import("render/composite.zig");
        _ = @import("render/colr_painter.zig");
    }
    if (ft.enable_bitmap) {
        _ = @import("font/table/cblc.zig");
        _ = @import("font/table/cbdt.zig");
    }
    _ = @import("font/table/name.zig");
    if (ft.enable_variable) {
        _ = @import("font/table/avar.zig");
        _ = @import("font/table/hvar.zig");
        _ = @import("font/table/item_variation_store.zig");
        _ = @import("font/table/vvar.zig");
        _ = @import("font/table/mvar.zig");
        _ = @import("font/table/stat.zig");
    }
    if (ft.enable_vertical) {
        _ = @import("font/table/vhea.zig");
        _ = @import("font/table/vmtx.zig");
        _ = @import("font/table/vorg.zig");
    }
    if (ft.enable_hinting) {
        _ = @import("font/table/os2.zig");
    }
    _ = @import("raster/outline.zig");
    _ = @import("raster/scanline.zig");
    _ = @import("raster/analytical.zig");
    _ = @import("raster/rasterizer.zig");
    _ = @import("raster/stroker.zig");
    _ = @import("raster/glyph_cache.zig");
    _ = @import("raster/atlas.zig");
    if (ft.enable_hinting) {
        _ = @import("raster/stem_darkening.zig");
        _ = @import("raster/cff_hinting.zig");
        _ = @import("raster/auto_hinting.zig");
    }
    if (ft.enable_sdf) {
        _ = @import("raster/sdf.zig");
        _ = @import("raster/msdf.zig");
    }
    _ = @import("layout/shaper.zig");
    _ = @import("render/bitmap.zig");
    _ = @import("render/rgba_bitmap.zig");
    _ = @import("render/gamma.zig");
    _ = @import("render/paint.zig");
    _ = @import("render/renderer.zig");
    if (ft.enable_incremental) {
        _ = @import("render/incremental.zig");
        _ = @import("render/glyph_reveal.zig");
        _ = @import("render/reveal/sweep.zig");
        _ = @import("render/reveal/fade.zig");
        _ = @import("render/reveal/contour_trace.zig");
        _ = @import("render/reveal/medial_axis.zig");
    }
    if (ft.enable_bitmap) {
        _ = @import("image/png_decoder.zig");
    }
    if (ft.enable_woff2) {
        _ = @import("compress/brotli.zig");
    }
    _ = @import("test_integration.zig");
}
