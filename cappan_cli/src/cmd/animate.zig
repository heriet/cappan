const std = @import("std");
const cappan_core = @import("cappan_core");
const cli_common = @import("../cli_common.zig");
const main = @import("../main.zig");
const RgbaBitmap = cappan_core.render.rgba_bitmap.RgbaBitmap;
const incremental_mod = cappan_core.render.incremental;
const png_mod = @import("../image/png.zig");
const apng_mod = @import("../image/apng.zig");
const CommonOptions = cli_common.CommonOptions;
const parseCommonOption = cli_common.parseCommonOption;
const resolveFontPath = cli_common.resolveFontPath;
const loadFont = cli_common.loadFont;
const loadFontSet = cli_common.loadFontSet;
const warnVariationUnsupported = cli_common.warnVariationUnsupported;
const printUsage = main.printUsage;

pub const usage_text =
    \\animate options (APNG mode — default):
    \\  --output             Output APNG file path
    \\  --fps                Frames per second (default: 10)
    \\
    \\animate options (frame sequence mode):
    \\  --output-dir         Output directory for individual frame PNGs
    \\
    \\animate common options:
    \\  --frames             Number of frames (default: 10)
    \\  --strategy           Reveal strategy: sweep (default), fade, contour-trace, medial-axis, distance-field, extrema-wave, skeleton-grow, tangent-flow
    \\  --sweep-direction    left-to-right (default), right-to-left, top-to-bottom, bottom-to-top
    \\  --timing             sequential (default), simultaneous, weighted, overlap:<value>
    \\  --contour-ordering   font-order (default), stroke-heuristic, area-priority, writing-order
    \\  --hold               Number of frames to hold completed state at end (default: 0)
    \\  --easing             Easing: linear (default), ease-in, ease-out, ease-in-out, ease-in-cubic, ease-out-cubic, ease-in-out-cubic
    \\  --reverse            Play animation in reverse (progress 1.0 to 0.0)
    \\  --extrema-invert     Invert extrema-wave reveal (near extrema first)
    \\  --paint-layer-timing Paint layer timing: simultaneous (default), sequential
    \\
++ "\n";

pub fn cmdRenderIncremental(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common: CommonOptions = .{};
    defer common.paint_ops.deinit(allocator);
    var output_path: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var num_frames: u32 = 10;
    var fps: u16 = 10;
    var strategy_name: []const u8 = "sweep";
    var sweep_dir_name: []const u8 = "left-to-right";
    var timing_name: []const u8 = "sequential";
    var contour_ordering_name: []const u8 = "font-order";
    var hold_frames: u32 = 0;
    var reverse = false;
    var extrema_invert = true;
    var easing_name: []const u8 = "linear";
    var paint_layer_timing_name: []const u8 = "simultaneous";
    var fallback_font_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer fallback_font_paths.deinit(allocator);

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            output_dir = args.next();
        } else if (std.mem.eql(u8, arg, "--frames")) {
            if (args.next()) |s| {
                num_frames = std.fmt.parseInt(u32, s, 10) catch {
                    std.debug.print("Error: invalid frames count '{s}'\n", .{s});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--fps")) {
            if (args.next()) |s| {
                fps = std.fmt.parseInt(u16, s, 10) catch {
                    std.debug.print("Error: invalid fps '{s}'\n", .{s});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--strategy")) {
            strategy_name = args.next() orelse "sweep";
        } else if (std.mem.eql(u8, arg, "--sweep-direction")) {
            sweep_dir_name = args.next() orelse "left-to-right";
        } else if (std.mem.eql(u8, arg, "--timing")) {
            timing_name = args.next() orelse "sequential";
        } else if (std.mem.eql(u8, arg, "--contour-ordering")) {
            contour_ordering_name = args.next() orelse "font-order";
        } else if (std.mem.eql(u8, arg, "--hold")) {
            if (args.next()) |s| {
                hold_frames = std.fmt.parseInt(u32, s, 10) catch {
                    std.debug.print("Error: invalid hold frames '{s}'\n", .{s});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            reverse = true;
        } else if (std.mem.eql(u8, arg, "--extrema-invert")) {
            extrema_invert = false;
        } else if (std.mem.eql(u8, arg, "--easing")) {
            easing_name = args.next() orelse "linear";
        } else if (std.mem.eql(u8, arg, "--paint-layer-timing")) {
            paint_layer_timing_name = args.next() orelse "simultaneous";
        } else if (std.mem.eql(u8, arg, "--fallback-font")) {
            if (args.next()) |path| {
                fallback_font_paths.append(allocator, path) catch {
                    std.debug.print("Error: could not store fallback font path\n", .{});
                    return;
                };
            }
        }
    }

    warnVariationUnsupported(common, "animate");

    if ((common.font_path == null and common.font_name == null) or common.text == null) {
        std.debug.print("Error: --font or --font-name and --text are required\n", .{});
        printUsage();
        return;
    }

    if (output_path == null and output_dir == null) {
        std.debug.print("Error: either --output (APNG) or --output-dir (frame sequence) is required\n", .{});
        printUsage();
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    var font_set = loadFontSet(allocator, io, font, fallback_font_paths.items) catch return;
    defer font_set.deinit(allocator);
    const fonts = font_set.fonts_list.items;

    // Parse sweep direction
    const sweep_dir: incremental_mod.SweepDirection = if (std.mem.eql(u8, sweep_dir_name, "right-to-left"))
        .right_to_left
    else if (std.mem.eql(u8, sweep_dir_name, "top-to-bottom"))
        .top_to_bottom
    else if (std.mem.eql(u8, sweep_dir_name, "bottom-to-top"))
        .bottom_to_top
    else
        .left_to_right;

    // Parse contour ordering
    const contour_ordering: incremental_mod.ContourOrdering =
        if (std.mem.eql(u8, contour_ordering_name, "stroke-heuristic"))
            .stroke_heuristic
        else if (std.mem.eql(u8, contour_ordering_name, "area-priority"))
            .area_priority
        else if (std.mem.eql(u8, contour_ordering_name, "writing-order"))
            .writing_order
        else
            .font_order;

    // Parse strategy
    const strategy: incremental_mod.RevealStrategy = if (std.mem.eql(u8, strategy_name, "fade"))
        .fade
    else if (std.mem.eql(u8, strategy_name, "contour-trace"))
        .{ .contour_trace = .{ .ordering = contour_ordering } }
    else if (std.mem.eql(u8, strategy_name, "medial-axis"))
        .{ .medial_axis = .{ .ordering = contour_ordering } }
    else if (std.mem.eql(u8, strategy_name, "distance-field"))
        .{ .distance_field = .{} }
    else if (std.mem.eql(u8, strategy_name, "extrema-wave"))
        .{ .extrema_wave = .{ .invert = extrema_invert } }
    else if (std.mem.eql(u8, strategy_name, "skeleton-grow"))
        .{ .skeleton_grow = .{} }
    else if (std.mem.eql(u8, strategy_name, "tangent-flow"))
        .{ .tangent_flow = .{} }
    else
        .{ .sweep = .{ .direction = sweep_dir } };

    // Parse easing
    const easing: incremental_mod.Easing = if (std.mem.eql(u8, easing_name, "ease-in"))
        .ease_in
    else if (std.mem.eql(u8, easing_name, "ease-out"))
        .ease_out
    else if (std.mem.eql(u8, easing_name, "ease-in-out"))
        .ease_in_out
    else if (std.mem.eql(u8, easing_name, "ease-in-cubic"))
        .ease_in_cubic
    else if (std.mem.eql(u8, easing_name, "ease-out-cubic"))
        .ease_out_cubic
    else if (std.mem.eql(u8, easing_name, "ease-in-out-cubic"))
        .ease_in_out_cubic
    else
        .linear;

    // Parse timing
    const timing: incremental_mod.Timing = blk: {
        if (std.mem.eql(u8, timing_name, "simultaneous")) {
            break :blk .simultaneous;
        } else if (std.mem.eql(u8, timing_name, "weighted")) {
            break :blk .weighted;
        } else if (std.mem.startsWith(u8, timing_name, "overlap:")) {
            const val_str = timing_name["overlap:".len..];
            const val = std.fmt.parseFloat(f32, val_str) catch 0.5;
            break :blk .{ .overlap = val };
        } else {
            break :blk .sequential;
        }
    };

    var inc = incremental_mod.IncrementalRenderer.init(allocator, fonts, common.text.?, .{
        .pixel_size = common.size,
        .fg_color = common.fg_color,
        .bg_color = common.bg_color,
        .gamma_correction = common.gamma_correction,
        .fractional_positioning = common.fractional_positioning,
        .strategy = strategy,
        .timing = timing,
        .easing = easing,
        .max_width = common.max_width,
        .text_align = common.text_align,
        .paint_stack = if (common.paint_ops.items.len > 0) common.paint_ops.items else null,
        .paint_layer_timing = if (std.mem.eql(u8, paint_layer_timing_name, "sequential")) .sequential else .simultaneous,
        .raster_options = common.raster_options,
        .stem_darkening = common.stem_darkening,
        .cff_hinting = common.cff_hinting,
        .auto_hinting = common.auto_hinting,
    }) catch |err| {
        std.debug.print("Error: could not create incremental renderer: {}\n", .{err});
        return;
    };
    defer inc.deinit();

    const cwd = std.Io.Dir.cwd();

    // Build the sequence of animation frame indices (shared by both output modes)
    var frame_indices: std.ArrayListUnmanaged(u32) = .empty;
    defer frame_indices.deinit(allocator);

    // Phase 1: Animation frames (forward or reverse)
    if (reverse) {
        var rev: u32 = num_frames;
        while (rev > 0) {
            rev -= 1;
            frame_indices.append(allocator, rev) catch |err| {
                std.debug.print("Error: could not build frame index list: {}\n", .{err});
                return;
            };
        }
    } else {
        for (0..num_frames) |f| {
            frame_indices.append(allocator, @intCast(f)) catch |err| {
                std.debug.print("Error: could not build frame index list: {}\n", .{err});
                return;
            };
        }
    }
    // Phase 2: Hold frames (repeat final frame)
    {
        const hold_frame: u32 = if (reverse) 0 else num_frames - 1;
        for (0..hold_frames) |_| {
            frame_indices.append(allocator, hold_frame) catch |err| {
                std.debug.print("Error: could not build hold frame index list: {}\n", .{err});
                return;
            };
        }
    }

    if (output_path != null) {
        // APNG mode: collect all frames and write as a single APNG file
        var frame_bitmaps: std.ArrayList(RgbaBitmap) = .empty;
        defer {
            for (frame_bitmaps.items) |*bmp| {
                bmp.deinit();
            }
            frame_bitmaps.deinit(allocator);
        }

        for (frame_indices.items) |anim_frame| {
            const bitmap = inc.renderFrameByIndex(anim_frame, num_frames) catch |err| {
                std.debug.print("Error: could not render frame {d}: {}\n", .{ anim_frame, err });
                return;
            };
            frame_bitmaps.append(allocator, bitmap) catch |err| {
                std.debug.print("Error: could not collect frame {d}: {}\n", .{ anim_frame, err });
                return;
            };
        }

        const file = cwd.createFile(io, output_path.?, .{}) catch |err| {
            std.debug.print("Error: could not create output file '{s}': {}\n", .{ output_path.?, err });
            return;
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        apng_mod.writeApngRgba(allocator, frame_bitmaps.items, 1, fps, &writer.interface) catch |err| {
            std.debug.print("Error: could not write APNG: {}\n", .{err});
            return;
        };
        writer.interface.flush() catch |err| {
            std.debug.print("Error: could not flush output: {}\n", .{err});
            return;
        };

        const total_output_frames = frame_bitmaps.items.len;
        std.debug.print("Rendered {d} frames to {s} ({d}x{d}, {d}fps)\n", .{ total_output_frames, output_path.?, inc.width, inc.height, fps });
    } else {
        // Frame sequence mode: write individual PNG files to output_dir
        cwd.createDir(io, output_dir.?, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Error: could not create output directory '{s}': {}\n", .{ output_dir.?, err });
                return;
            }
        };

        var path_buf: [4096]u8 = undefined;

        for (frame_indices.items, 0..) |anim_frame, output_idx| {
            var bitmap = inc.renderFrameByIndex(anim_frame, num_frames) catch |err| {
                std.debug.print("Error: could not render frame {d}: {}\n", .{ anim_frame, err });
                return;
            };
            defer bitmap.deinit();

            const frame_path = std.fmt.bufPrint(&path_buf, "{s}/frame_{d:0>4}.png", .{ output_dir.?, output_idx }) catch {
                std.debug.print("Error: path too long\n", .{});
                return;
            };

            const file = cwd.createFile(io, frame_path, .{}) catch |err| {
                std.debug.print("Error: could not create file '{s}': {}\n", .{ frame_path, err });
                return;
            };
            defer file.close(io);

            var buf: [4096]u8 = undefined;
            var writer = file.writer(io, &buf);
            png_mod.writePngRgba(allocator, bitmap, &writer.interface) catch |err| {
                std.debug.print("Error: could not write PNG for frame {d}: {}\n", .{ output_idx, err });
                return;
            };
            writer.interface.flush() catch |err| {
                std.debug.print("Error: could not flush frame {d}: {}\n", .{ output_idx, err });
                return;
            };
        }

        std.debug.print("Rendered {d} frames to {s}/ ({d}x{d})\n", .{ frame_indices.items.len, output_dir.?, inc.width, inc.height });
    }
}
