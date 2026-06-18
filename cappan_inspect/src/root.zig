const std = @import("std");
const cappan_core = @import("cappan_core");

pub const table_dump = @import("table_dump.zig");
pub const validator = @import("validator.zig");
pub const coverage = @import("coverage.zig");
pub const feature = @import("feature.zig");
pub const glyph_info = @import("glyph_info.zig");

// Re-export main types for convenience
pub const TableInfo = table_dump.TableInfo;
pub const FontSummary = table_dump.FontSummary;
pub const getSummary = table_dump.getSummary;

pub const Diagnostics = cappan_core.err.Diagnostics;
pub const Severity = cappan_core.err.Severity;
pub const DiagnosticEntry = cappan_core.err.DiagnosticEntry;
pub const Location = cappan_core.err.Location;
pub const validate = validator.validate;

pub const UnicodeBlock = coverage.UnicodeBlock;
pub const analyzeCoverage = coverage.analyzeCoverage;

pub const FeatureInfo = feature.FeatureInfo;
pub const listFeatures = feature.listFeatures;

pub const GlyphInfo = glyph_info.GlyphInfo;
pub const getGlyphInfo = glyph_info.getGlyphInfo;

test {
    _ = @import("table_dump.zig");
    _ = @import("validator.zig");
    _ = @import("coverage.zig");
    _ = @import("feature.zig");
    _ = @import("glyph_info.zig");
}
