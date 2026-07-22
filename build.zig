const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Feature flags (all enabled by default for backward compatibility)
    const enable_cff = b.option(bool, "enable_cff", "Enable CFF/OTF outline support") orelse true;
    const enable_opentype_layout = b.option(bool, "enable_opentype_layout", "Enable GSUB/GPOS/GDEF") orelse true;
    const enable_color = b.option(bool, "enable_color", "Enable COLR/CPAL color glyphs") orelse true;
    const enable_colr_v1_opt = b.option(bool, "enable_colr_v1", "Enable COLR v1 gradient/composite rendering (requires enable_color)") orelse true;
    const enable_colr_v1 = enable_colr_v1_opt and enable_color;
    const enable_bitmap = b.option(bool, "enable_bitmap", "Enable CBLC/CBDT bitmap glyphs") orelse true;
    const enable_variable = b.option(bool, "enable_variable", "Enable Variable Fonts") orelse true;
    const enable_hinting = b.option(bool, "enable_hinting", "Enable hinting and stem darkening") orelse true;
    const enable_incremental = b.option(bool, "enable_incremental", "Enable incremental rendering and reveal animations") orelse true;
    const enable_woff = b.option(bool, "enable_woff", "Enable WOFF1 container") orelse true;
    const enable_woff2 = b.option(bool, "enable_woff2", "Enable WOFF2 container") orelse true;
    const enable_vertical = b.option(bool, "enable_vertical", "Enable vertical metrics") orelse true;
    const enable_sdf = b.option(bool, "enable_sdf", "Enable SDF glyph rendering") orelse true;

    const feature_options = b.addOptions();
    // Single source of truth for the version: the package manifest.
    feature_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    feature_options.addOption(bool, "enable_cff", enable_cff);
    feature_options.addOption(bool, "enable_opentype_layout", enable_opentype_layout);
    feature_options.addOption(bool, "enable_color", enable_color);
    feature_options.addOption(bool, "enable_colr_v1", enable_colr_v1);
    feature_options.addOption(bool, "enable_bitmap", enable_bitmap);
    feature_options.addOption(bool, "enable_variable", enable_variable);
    feature_options.addOption(bool, "enable_hinting", enable_hinting);
    feature_options.addOption(bool, "enable_incremental", enable_incremental);
    feature_options.addOption(bool, "enable_woff", enable_woff);
    feature_options.addOption(bool, "enable_woff2", enable_woff2);
    feature_options.addOption(bool, "enable_vertical", enable_vertical);
    feature_options.addOption(bool, "enable_sdf", enable_sdf);

    const lib_mod = b.addModule("cappan_core", .{
        .root_source_file = b.path("cappan_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", feature_options);

    const lib = b.addLibrary(.{
        .name = "cappan_core",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Collected here and only wired up to the "test" step at the end, so that
    // step's declaration order (relative to "run"/"wasm") matches the
    // original file's -- `zig build --help` lists steps in declaration order.
    var test_run_steps: std.ArrayList(*std.Build.Step) = .empty;

    // lib_test reuses lib_mod directly (rather than building a second module
    // with the same root_source_file + build_options) -- addTest accepts an
    // already-in-use module just like addLibrary/addModule imports do.
    const lib_test = b.addTest(.{
        .root_module = lib_mod,
    });
    test_run_steps.append(b.allocator, &b.addRunArtifact(lib_test).step) catch @panic("OOM");

    // The 6 sibling modules (cappan_subset/cappan_embed/cappan_pathify/
    // cappan_inspect/cappan_metrics/cappan_discover) all follow the exact same
    // shape: a module importing only cappan_core, a library built from it,
    // installed, and a test run from the same module. Looping over their
    // names/paths keeps this in one place instead of 6 near-identical copies.
    const SiblingModule = struct {
        name: []const u8,
        root_source_file: []const u8,
    };
    const sibling_modules = [_]SiblingModule{
        .{ .name = "cappan_subset", .root_source_file = "cappan_subset/src/root.zig" },
        .{ .name = "cappan_embed", .root_source_file = "cappan_embed/src/root.zig" },
        .{ .name = "cappan_pathify", .root_source_file = "cappan_pathify/src/root.zig" },
        .{ .name = "cappan_inspect", .root_source_file = "cappan_inspect/src/root.zig" },
        .{ .name = "cappan_metrics", .root_source_file = "cappan_metrics/src/root.zig" },
        .{ .name = "cappan_discover", .root_source_file = "cappan_discover/src/root.zig" },
    };

    // cappan_cli's own exe module below imports every sibling module by name,
    // so keep the built modules around (in the same order) to build that
    // import list without hardcoding it a second time.
    var sibling_imports: [sibling_modules.len]std.Build.Module.Import = undefined;

    for (sibling_modules, 0..) |sm, i| {
        const mod = b.addModule(sm.name, .{
            .root_source_file = b.path(sm.root_source_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
            },
        });

        const sibling_lib = b.addLibrary(.{
            .name = sm.name,
            .root_module = mod,
        });
        b.installArtifact(sibling_lib);

        const sibling_test = b.addTest(.{
            .root_module = mod,
        });
        test_run_steps.append(b.allocator, &b.addRunArtifact(sibling_test).step) catch @panic("OOM");

        sibling_imports[i] = .{ .name = sm.name, .module = mod };
    }

    var exe_imports: [1 + sibling_modules.len]std.Build.Module.Import = undefined;
    exe_imports[0] = .{ .name = "cappan_core", .module = lib_mod };
    for (sibling_imports, 0..) |imp, i| {
        exe_imports[1 + i] = imp;
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("cappan_cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &exe_imports,
    });

    const exe = b.addExecutable(.{
        .name = "cappan",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the cappan CLI");
    run_step.dependOn(&run_cmd.step);

    // exe_test reuses exe_mod directly instead of re-declaring the same
    // root_source_file + 7-entry import list a second time.
    const exe_test = b.addTest(.{
        .root_module = exe_mod,
    });
    test_run_steps.append(b.allocator, &b.addRunArtifact(exe_test).step) catch @panic("OOM");

    const test_step = b.step("test", "Run unit tests");
    for (test_run_steps.items) |s| {
        test_step.dependOn(s);
    }

    // WASM build
    const wasm_step = b.step("wasm", "Build WASM module");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_core_mod = b.addModule("cappan_core_wasm", .{
        .root_source_file = b.path("cappan_core/src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_core_mod.addOptions("build_options", feature_options);

    const wasm_exe = b.addExecutable(.{
        .name = "cappan_wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_wasm/src/main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "cappan_core", .module = wasm_core_mod },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const wasm_mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "docs/demo" });
    const wasm_copy = b.addSystemCommand(&.{"cp"});
    wasm_copy.addFileArg(wasm_exe.getEmittedBin());
    wasm_copy.addArg("docs/demo/cappan_wasm.wasm");
    wasm_copy.step.dependOn(&wasm_mkdir.step);
    wasm_step.dependOn(&wasm_copy.step);
}
