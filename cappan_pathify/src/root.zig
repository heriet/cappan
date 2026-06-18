const std = @import("std");
pub const svg = @import("svg.zig");

pub const GlyphPath = svg.GlyphPath;
pub const glyphToSvgPath = svg.glyphToSvgPath;
pub const textToSvgPaths = svg.textToSvgPaths;

test {
    _ = @import("svg.zig");
}
