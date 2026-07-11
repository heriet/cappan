const build_options = @import("build_options");

pub const features: Features = .{
    .enable_cff = build_options.enable_cff,
    .enable_opentype_layout = build_options.enable_opentype_layout,
    .enable_color = build_options.enable_color,
    .enable_colr_v1 = build_options.enable_colr_v1,
    .enable_bitmap = build_options.enable_bitmap,
    .enable_variable = build_options.enable_variable,
    .enable_hinting = build_options.enable_hinting,
    .enable_incremental = build_options.enable_incremental,
    .enable_woff = build_options.enable_woff,
    .enable_woff2 = build_options.enable_woff2,
    .enable_vertical = build_options.enable_vertical,
};

pub const Features = struct {
    enable_cff: bool,
    enable_opentype_layout: bool,
    enable_color: bool,
    enable_colr_v1: bool,
    enable_bitmap: bool,
    enable_variable: bool,
    enable_hinting: bool,
    enable_incremental: bool,
    enable_woff: bool,
    enable_woff2: bool,
    enable_vertical: bool,

    pub const all_enabled: Features = .{
        .enable_cff = true,
        .enable_opentype_layout = true,
        .enable_color = true,
        .enable_colr_v1 = true,
        .enable_bitmap = true,
        .enable_variable = true,
        .enable_hinting = true,
        .enable_incremental = true,
        .enable_woff = true,
        .enable_woff2 = true,
        .enable_vertical = true,
    };
};
