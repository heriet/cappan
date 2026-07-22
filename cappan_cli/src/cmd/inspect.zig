const std = @import("std");
const cappan_core = @import("cappan_core");
const cappan_inspect = @import("cappan_inspect");
const cli_common = @import("../cli_common.zig");
const main = @import("../main.zig");
const CommonOptions = cli_common.CommonOptions;
const parseCommonOption = cli_common.parseCommonOption;
const warnVariationUnsupported = cli_common.warnVariationUnsupported;
const resolveFontPath = cli_common.resolveFontPath;
const loadFont = cli_common.loadFont;
const printUsage = main.printUsage;

pub const usage_text =
    \\inspect options:
    \\  --summary            Show font summary
    \\  --tables             Show font tables
    \\  --validate           Validate font tables
    \\  --coverage           Show Unicode block coverage
    \\  --features           Show OpenType features
    \\  --format             Output format: text (default), json, yaml
    \\
++ "\n";

pub fn cmdInspect(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common: CommonOptions = .{};
    defer common.paint_ops.deinit(allocator);
    var show_summary = false;
    var show_tables = false;
    var show_validate = false;
    var show_coverage = false;
    var show_features = false;
    var show_glyphs = false;
    var glyph_text: ?[]const u8 = null;
    var glyph_ids_raw: ?[]const u8 = null;
    const OutputFormat = enum { text, json, yaml };
    var format: OutputFormat = .text;

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            show_summary = true;
        } else if (std.mem.eql(u8, arg, "--tables")) {
            show_tables = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            show_validate = true;
        } else if (std.mem.eql(u8, arg, "--coverage")) {
            show_coverage = true;
        } else if (std.mem.eql(u8, arg, "--features")) {
            show_features = true;
        } else if (std.mem.eql(u8, arg, "--glyphs")) {
            show_glyphs = true;
        } else if (std.mem.eql(u8, arg, "--glyph")) {
            show_glyphs = true;
            glyph_text = args.next();
        } else if (std.mem.eql(u8, arg, "--glyph-id")) {
            show_glyphs = true;
            glyph_ids_raw = args.next();
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (args.next()) |fmt_str| {
                if (std.mem.eql(u8, fmt_str, "json")) {
                    format = .json;
                } else if (std.mem.eql(u8, fmt_str, "yaml")) {
                    format = .yaml;
                } else if (std.mem.eql(u8, fmt_str, "text")) {
                    format = .text;
                } else {
                    std.debug.print("Error: unknown format '{s}', expected text, json, or yaml\n", .{fmt_str});
                    return;
                }
            }
        }
    }

    const show_all = !show_summary and !show_tables and !show_validate and !show_coverage and !show_features and !show_glyphs;
    const do_summary = show_all or show_summary;
    const do_tables = show_all or show_tables;
    const do_validate = show_all or show_validate;
    const do_coverage = show_all or show_coverage;
    const do_features = show_all or show_features;
    const do_glyphs = show_glyphs;

    warnVariationUnsupported(common, "inspect");

    if (common.font_path == null and common.font_name == null) {
        std.debug.print("Error: --font or --font-name is required\n", .{});
        printUsage();
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    var summary_opt: ?cappan_inspect.FontSummary = null;
    defer if (summary_opt) |*s| s.deinit();
    if (do_summary or do_tables) {
        summary_opt = cappan_inspect.getSummary(allocator, font) catch |err| {
            std.debug.print("Error: could not get font summary: {}\n", .{err});
            return;
        };
    }

    var validation_opt: ?cappan_core.err.Diagnostics = null;
    defer if (validation_opt) |*v| v.deinit(allocator);
    if (do_validate) {
        validation_opt = cappan_inspect.validate(allocator, font) catch |err| {
            std.debug.print("Error: could not validate font: {}\n", .{err});
            return;
        };
    }

    var blocks_opt: ?[]cappan_inspect.UnicodeBlock = null;
    defer if (blocks_opt) |b| allocator.free(b);
    if (do_coverage) {
        blocks_opt = cappan_inspect.analyzeCoverage(allocator, font) catch |err| {
            std.debug.print("Error: could not analyze coverage: {}\n", .{err});
            return;
        };
    }

    var features_opt: ?[]cappan_inspect.FeatureInfo = null;
    defer if (features_opt) |f| allocator.free(f);
    if (do_features) {
        features_opt = cappan_inspect.listFeatures(allocator, font) catch |err| {
            std.debug.print("Error: could not list features: {}\n", .{err});
            return;
        };
    }

    var glyph_infos: std.ArrayList(cappan_inspect.GlyphInfo) = .empty;
    defer glyph_infos.deinit(allocator);

    if (do_glyphs) {
        if (glyph_text) |text| {
            const view = std.unicode.Utf8View.init(text) catch blk: {
                break :blk std.unicode.Utf8View.initUnchecked(text);
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                const glyph_id = font.getGlyphId(@as(u32, cp)) catch continue;
                const info = cappan_inspect.getGlyphInfo(allocator, font, glyph_id, @as(u32, cp)) catch continue;
                glyph_infos.append(allocator, info) catch continue;
            }
        } else if (glyph_ids_raw) |ids_str| {
            var iter = std.mem.splitScalar(u8, ids_str, ',');
            while (iter.next()) |id_str| {
                const trimmed = std.mem.trim(u8, id_str, " ");
                const glyph_id = std.fmt.parseInt(u16, trimmed, 10) catch continue;
                const info = cappan_inspect.getGlyphInfo(allocator, font, glyph_id, null) catch continue;
                glyph_infos.append(allocator, info) catch continue;
            }
        }
    }

    switch (format) {
        .text => {
            if (do_summary) {
                if (summary_opt) |summary| {
                    const family = summary.family_name orelse "(unknown)";
                    std.debug.print("Font: {s}\n", .{family});
                    if (summary.subfamily_name) |sub| {
                        std.debug.print("  Family: {s} [{s}]\n", .{ family, sub });
                    } else {
                        std.debug.print("  Family: {s}\n", .{family});
                    }
                    std.debug.print("  Glyphs: {d}\n", .{summary.num_glyphs});
                    std.debug.print("  Units per em: {d}\n", .{summary.units_per_em});
                    std.debug.print("  Ascender: {d} / Descender: {d} / Line gap: {d}\n", .{ summary.ascender, summary.descender, summary.line_gap });
                    std.debug.print("  Bounding box: [{d}, {d}, {d}, {d}]\n", .{ summary.x_min, summary.y_min, summary.x_max, summary.y_max });
                }
            }
            if (do_tables) {
                if (summary_opt) |summary| {
                    std.debug.print("\nTables ({d}):\n", .{summary.tables.len});
                    for (summary.tables) |tbl| {
                        std.debug.print("  {s}  offset={d:<8} length={d}\n", .{ tbl.tag, tbl.offset, tbl.length });
                    }
                }
            }
            if (do_validate) {
                if (validation_opt) |validation| {
                    std.debug.print("\nValidation:\n", .{});
                    for (validation.entries.items) |msg| {
                        const prefix: []const u8 = switch (msg.severity) {
                            .info => "INFO",
                            .warning => "WARN",
                            .@"error" => "ERR ",
                        };
                        if (msg.location.table_tag) |tag| {
                            const trimmed = std.mem.trimEnd(u8, &tag, " ");
                            std.debug.print("  {s}  {s}: {s}\n", .{ prefix, trimmed, msg.message });
                        } else {
                            std.debug.print("  {s}  {s}\n", .{ prefix, msg.message });
                        }
                    }
                    if (validation.entries.items.len == 0) {
                        std.debug.print("  (no issues found)\n", .{});
                    }
                }
            }
            if (do_coverage) {
                if (blocks_opt) |blocks| {
                    std.debug.print("\nUnicode coverage:\n", .{});
                    for (blocks) |blk| {
                        if (blk.covered == 0) continue;
                        const pct = @as(f64, @floatFromInt(blk.covered)) / @as(f64, @floatFromInt(blk.total)) * 100.0;
                        std.debug.print("  {s:<28} {d}/{d}   ({d:.1}%)\n", .{ blk.name, blk.covered, blk.total, pct });
                    }
                }
            }
            if (do_features) {
                if (features_opt) |features| {
                    if (features.len > 0) {
                        std.debug.print("\nOpenType features:\n", .{});
                        for (features) |feat| {
                            std.debug.print("  {s} {s} ({s}/{s})\n", .{ feat.table_tag, feat.feature_tag, feat.script_tag, feat.language_tag });
                        }
                    }
                }
            }
            if (do_glyphs and glyph_infos.items.len > 0) {
                std.debug.print("\nGlyph details:\n", .{});
                for (glyph_infos.items) |info| {
                    if (info.codepoint) |cp| {
                        if (cp >= 0x20 and cp < 0x7F) {
                            std.debug.print("  Glyph {d} (U+{X:0>4} '{c}')\n", .{ info.glyph_id, cp, @as(u8, @intCast(cp)) });
                        } else {
                            std.debug.print("  Glyph {d} (U+{X:0>4})\n", .{ info.glyph_id, cp });
                        }
                    } else {
                        std.debug.print("  Glyph {d}\n", .{info.glyph_id});
                    }
                    std.debug.print("    Advance width: {d}  LSB: {d}\n", .{ info.advance_width, info.lsb });
                    if (info.has_outline) {
                        std.debug.print("    Bounding box: [{d}, {d}, {d}, {d}]\n", .{ info.x_min, info.y_min, info.x_max, info.y_max });
                        std.debug.print("    Contours: {d}  Points: {d}\n", .{ info.contour_count, info.point_count });
                        if (info.is_compound) {
                            std.debug.print("    Type: compound\n", .{});
                        }
                    } else {
                        std.debug.print("    (no outline)\n", .{});
                    }
                }
            }
        },
        .json => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            try buf.appendSlice(allocator, "{\n");
            var first_section = true;

            if (do_summary) {
                if (summary_opt) |summary| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    const family_raw = summary.family_name orelse "";
                    const subfam_raw = summary.subfamily_name orelse "";
                    const family_esc = try jsonEscapeString(allocator, family_raw);
                    defer allocator.free(family_esc);
                    const subfam_esc = try jsonEscapeString(allocator, subfam_raw);
                    defer allocator.free(subfam_esc);
                    try buf.print(allocator,
                        \\  "summary": {{
                        \\    "family": "{s}",
                        \\    "subfamily": "{s}",
                        \\    "num_glyphs": {d},
                        \\    "units_per_em": {d},
                        \\    "ascender": {d},
                        \\    "descender": {d},
                        \\    "line_gap": {d},
                        \\    "bbox": [{d}, {d}, {d}, {d}]
                        \\  }}
                    , .{ family_esc, subfam_esc, summary.num_glyphs, summary.units_per_em, summary.ascender, summary.descender, summary.line_gap, summary.x_min, summary.y_min, summary.x_max, summary.y_max });
                }
            }

            if (do_tables) {
                if (summary_opt) |summary| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    try buf.appendSlice(allocator, "  \"tables\": [\n");
                    for (summary.tables, 0..) |tbl, i| {
                        const tag_trimmed = std.mem.trimEnd(u8, &tbl.tag, " ");
                        const tag_esc = try jsonEscapeString(allocator, tag_trimmed);
                        defer allocator.free(tag_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",\n");
                        try buf.print(allocator,
                            \\    {{"tag": "{s}", "offset": {d}, "length": {d}, "checksum": {d}}}
                        , .{ tag_esc, tbl.offset, tbl.length, tbl.checksum });
                    }
                    try buf.appendSlice(allocator, "\n  ]");
                }
            }

            if (do_validate) {
                if (validation_opt) |validation| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    const status_str = if (validation.hasErrors()) "error" else "ok";
                    try buf.print(allocator,
                        \\  "validation": {{
                        \\    "status": "{s}",
                        \\    "messages": [
                    , .{status_str});
                    for (validation.entries.items, 0..) |msg, i| {
                        const sev_str: []const u8 = switch (msg.severity) {
                            .info => "info",
                            .warning => "warning",
                            .@"error" => "error",
                        };
                        const message_esc = try jsonEscapeString(allocator, msg.message);
                        defer allocator.free(message_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",");
                        try buf.print(allocator, "\n      {{\"severity\": \"{s}\", \"message\": \"{s}\"", .{ sev_str, message_esc });
                        if (msg.location.table_tag) |tag| {
                            const tag_trimmed = std.mem.trimEnd(u8, &tag, " ");
                            const tag_esc = try jsonEscapeString(allocator, tag_trimmed);
                            defer allocator.free(tag_esc);
                            try buf.print(allocator, ", \"table\": \"{s}\"", .{tag_esc});
                        }
                        if (msg.location.glyph_id) |gid| {
                            try buf.print(allocator, ", \"glyph_id\": {d}", .{gid});
                        }
                        try buf.appendSlice(allocator, "}");
                    }
                    try buf.appendSlice(allocator, "\n    ]\n  }");
                }
            }

            if (do_coverage) {
                if (blocks_opt) |blocks| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    try buf.appendSlice(allocator, "  \"coverage\": [\n");
                    for (blocks, 0..) |blk, i| {
                        const pct = @as(f64, @floatFromInt(blk.covered)) / @as(f64, @floatFromInt(blk.total)) * 100.0;
                        const name_esc = try jsonEscapeString(allocator, blk.name);
                        defer allocator.free(name_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",\n");
                        try buf.print(allocator,
                            \\    {{"name": "{s}", "start": {d}, "end": {d}, "covered": {d}, "total": {d}, "percentage": {d:.1}}}
                        , .{ name_esc, blk.start, blk.end, blk.covered, blk.total, pct });
                    }
                    try buf.appendSlice(allocator, "\n  ]");
                }
            }

            if (do_features) {
                if (features_opt) |features| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    try buf.appendSlice(allocator, "  \"features\": [\n");
                    for (features, 0..) |feat, i| {
                        const table_trimmed = std.mem.trimEnd(u8, &feat.table_tag, " ");
                        const feature_trimmed = std.mem.trimEnd(u8, &feat.feature_tag, " ");
                        const script_trimmed = std.mem.trimEnd(u8, &feat.script_tag, " ");
                        const language_trimmed = std.mem.trimEnd(u8, &feat.language_tag, " ");
                        const table_esc = try jsonEscapeString(allocator, table_trimmed);
                        defer allocator.free(table_esc);
                        const feature_esc = try jsonEscapeString(allocator, feature_trimmed);
                        defer allocator.free(feature_esc);
                        const script_esc = try jsonEscapeString(allocator, script_trimmed);
                        defer allocator.free(script_esc);
                        const language_esc = try jsonEscapeString(allocator, language_trimmed);
                        defer allocator.free(language_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",\n");
                        try buf.print(allocator,
                            \\    {{"table": "{s}", "feature": "{s}", "script": "{s}", "language": "{s}"}}
                        , .{ table_esc, feature_esc, script_esc, language_esc });
                    }
                    try buf.appendSlice(allocator, "\n  ]");
                }
            }

            if (do_glyphs and glyph_infos.items.len > 0) {
                if (!first_section) try buf.appendSlice(allocator, ",\n");
                first_section = false;
                try buf.appendSlice(allocator, "  \"glyphs\": [\n");
                for (glyph_infos.items, 0..) |info, i| {
                    if (i > 0) try buf.appendSlice(allocator, ",\n");
                    if (info.codepoint) |cp| {
                        try buf.print(allocator,
                            \\    {{"glyph_id": {d}, "codepoint": {d}, "advance_width": {d}, "lsb": {d}, "has_outline": {s}, "is_compound": {s}
                        , .{ info.glyph_id, cp, info.advance_width, info.lsb, if (info.has_outline) "true" else "false", if (info.is_compound) "true" else "false" });
                    } else {
                        try buf.print(allocator,
                            \\    {{"glyph_id": {d}, "codepoint": null, "advance_width": {d}, "lsb": {d}, "has_outline": {s}, "is_compound": {s}
                        , .{ info.glyph_id, info.advance_width, info.lsb, if (info.has_outline) "true" else "false", if (info.is_compound) "true" else "false" });
                    }
                    if (info.has_outline) {
                        try buf.print(allocator, ", \"bbox\": [{d}, {d}, {d}, {d}], \"contours\": {d}, \"points\": {d}}}", .{ info.x_min, info.y_min, info.x_max, info.y_max, info.contour_count, info.point_count });
                    } else {
                        try buf.appendSlice(allocator, "}");
                    }
                }
                try buf.appendSlice(allocator, "\n  ]");
            }

            try buf.appendSlice(allocator, "\n}\n");
            std.debug.print("{s}", .{buf.items});
        },
        .yaml => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            if (do_summary) {
                if (summary_opt) |summary| {
                    const family_raw = summary.family_name orelse "";
                    const subfam_raw = summary.subfamily_name orelse "";
                    try buf.print(allocator,
                        \\summary:
                        \\  family: "{s}"
                        \\  subfamily: "{s}"
                        \\  num_glyphs: {d}
                        \\  units_per_em: {d}
                        \\  ascender: {d}
                        \\  descender: {d}
                        \\  line_gap: {d}
                        \\  bbox: [{d}, {d}, {d}, {d}]
                        \\
                    , .{ family_raw, subfam_raw, summary.num_glyphs, summary.units_per_em, summary.ascender, summary.descender, summary.line_gap, summary.x_min, summary.y_min, summary.x_max, summary.y_max });
                }
            }

            if (do_tables) {
                if (summary_opt) |summary| {
                    try buf.appendSlice(allocator, "tables:\n");
                    if (summary.tables.len == 0) {
                        try buf.appendSlice(allocator, "  []\n");
                    } else {
                        for (summary.tables) |tbl| {
                            const tag_trimmed = std.mem.trimEnd(u8, &tbl.tag, " ");
                            try buf.print(allocator,
                                \\  - tag: "{s}"
                                \\    offset: {d}
                                \\    length: {d}
                                \\    checksum: {d}
                                \\
                            , .{ tag_trimmed, tbl.offset, tbl.length, tbl.checksum });
                        }
                    }
                }
            }

            if (do_validate) {
                if (validation_opt) |validation| {
                    const status_str = if (validation.hasErrors()) "error" else "ok";
                    try buf.print(allocator, "validation:\n  status: \"{s}\"\n  messages:\n", .{status_str});
                    if (validation.entries.items.len == 0) {
                        try buf.appendSlice(allocator, "    []\n");
                    } else {
                        for (validation.entries.items) |msg| {
                            const sev_str: []const u8 = switch (msg.severity) {
                                .info => "info",
                                .warning => "warning",
                                .@"error" => "error",
                            };
                            try buf.print(allocator,
                                \\    - severity: "{s}"
                                \\      message: "{s}"
                                \\
                            , .{ sev_str, msg.message });
                            if (msg.location.table_tag) |tag| {
                                const tag_trimmed = std.mem.trimEnd(u8, &tag, " ");
                                try buf.print(allocator, "      table: \"{s}\"\n", .{tag_trimmed});
                            }
                            if (msg.location.glyph_id) |gid| {
                                try buf.print(allocator, "      glyph_id: {d}\n", .{gid});
                            }
                        }
                    }
                }
            }

            if (do_coverage) {
                if (blocks_opt) |blocks| {
                    try buf.appendSlice(allocator, "coverage:\n");
                    if (blocks.len == 0) {
                        try buf.appendSlice(allocator, "  []\n");
                    } else {
                        for (blocks) |blk| {
                            const pct = @as(f64, @floatFromInt(blk.covered)) / @as(f64, @floatFromInt(blk.total)) * 100.0;
                            try buf.print(allocator,
                                \\  - name: "{s}"
                                \\    start: {d}
                                \\    end: {d}
                                \\    covered: {d}
                                \\    total: {d}
                                \\    percentage: {d:.1}
                                \\
                            , .{ blk.name, blk.start, blk.end, blk.covered, blk.total, pct });
                        }
                    }
                }
            }

            if (do_features) {
                if (features_opt) |features| {
                    try buf.appendSlice(allocator, "features:\n");
                    if (features.len == 0) {
                        try buf.appendSlice(allocator, "  []\n");
                    } else {
                        for (features) |feat| {
                            const table_trimmed = std.mem.trimEnd(u8, &feat.table_tag, " ");
                            const feature_trimmed = std.mem.trimEnd(u8, &feat.feature_tag, " ");
                            const script_trimmed = std.mem.trimEnd(u8, &feat.script_tag, " ");
                            const language_trimmed = std.mem.trimEnd(u8, &feat.language_tag, " ");
                            try buf.print(allocator,
                                \\  - table: "{s}"
                                \\    feature: "{s}"
                                \\    script: "{s}"
                                \\    language: "{s}"
                                \\
                            , .{ table_trimmed, feature_trimmed, script_trimmed, language_trimmed });
                        }
                    }
                }
            }

            if (do_glyphs and glyph_infos.items.len > 0) {
                try buf.appendSlice(allocator, "glyphs:\n");
                for (glyph_infos.items) |info| {
                    try buf.print(allocator, "  - glyph_id: {d}\n", .{info.glyph_id});
                    if (info.codepoint) |cp| {
                        try buf.print(allocator, "    codepoint: {d}\n", .{cp});
                    } else {
                        try buf.appendSlice(allocator, "    codepoint: null\n");
                    }
                    try buf.print(allocator,
                        \\    advance_width: {d}
                        \\    lsb: {d}
                        \\    has_outline: {s}
                        \\    is_compound: {s}
                        \\
                    , .{ info.advance_width, info.lsb, if (info.has_outline) "true" else "false", if (info.is_compound) "true" else "false" });
                    if (info.has_outline) {
                        try buf.print(allocator,
                            \\    bbox: [{d}, {d}, {d}, {d}]
                            \\    contours: {d}
                            \\    points: {d}
                            \\
                        , .{ info.x_min, info.y_min, info.x_max, info.y_max, info.contour_count, info.point_count });
                    }
                }
            }

            std.debug.print("{s}", .{buf.items});
        },
    }
}

fn jsonEscapeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const hex = "0123456789ABCDEF";
                buf[0] = '\\';
                buf[1] = 'u';
                buf[2] = '0';
                buf[3] = '0';
                buf[4] = hex[c >> 4];
                buf[5] = hex[c & 0xF];
                try out.appendSlice(allocator, &buf);
            },
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}
