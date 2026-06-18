const std = @import("std");

pub const css = @import("css.zig");
pub const compare = @import("compare.zig");

pub const CssFontMetrics = css.CssFontMetrics;
pub const MetricsSource = css.MetricsSource;
pub const getCssFontMetrics = css.getCssFontMetrics;

pub const FontComparison = compare.FontComparison;
pub const compareFonts = compare.compareFonts;

test {
    _ = @import("css.zig");
    _ = @import("compare.zig");
}
