/// Packs (font_index, glyph_id) into a single u32 lookup key. Shared by
/// render/renderer.zig's per-render glyph cache and raster/sdf.zig's SDF glyph
/// cache, so the bit layout has a single owner.
pub fn glyphCacheKeyU32(font_index: u8, glyph_id: u16) u32 {
    return (@as(u32, font_index) << 16) | @as(u32, glyph_id);
}
