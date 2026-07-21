const std = @import("std");
pub const subsetter = @import("subsetter.zig");

test {
    _ = @import("subsetter.zig");
    _ = @import("table/glyf.zig");
    _ = @import("table/loca.zig");
    _ = @import("table/cmap.zig");
    _ = @import("table/hmtx.zig");
    _ = @import("table/head.zig");
    _ = @import("table/maxp.zig");
    _ = @import("table/hhea.zig");
    _ = @import("table/post.zig");
}
