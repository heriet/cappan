const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("cappan_core", .{
        .root_source_file = b.path("cappan_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "cappan_core",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const subset_mod = b.addModule("cappan_subset", .{
        .root_source_file = b.path("cappan_subset/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cappan_core", .module = lib_mod },
        },
    });

    const subset_lib = b.addLibrary(.{
        .name = "cappan_subset",
        .root_module = subset_mod,
    });
    b.installArtifact(subset_lib);

    const embed_mod = b.addModule("cappan_embed", .{
        .root_source_file = b.path("cappan_embed/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cappan_core", .module = lib_mod },
        },
    });

    const embed_lib = b.addLibrary(.{
        .name = "cappan_embed",
        .root_module = embed_mod,
    });
    b.installArtifact(embed_lib);

    const pathify_mod = b.addModule("cappan_pathify", .{
        .root_source_file = b.path("cappan_pathify/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cappan_core", .module = lib_mod },
        },
    });

    const pathify_lib = b.addLibrary(.{
        .name = "cappan_pathify",
        .root_module = pathify_mod,
    });
    b.installArtifact(pathify_lib);

    const inspect_mod = b.addModule("cappan_inspect", .{
        .root_source_file = b.path("cappan_inspect/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cappan_core", .module = lib_mod },
        },
    });

    const inspect_lib = b.addLibrary(.{
        .name = "cappan_inspect",
        .root_module = inspect_mod,
    });
    b.installArtifact(inspect_lib);

    const metrics_mod = b.addModule("cappan_metrics", .{
        .root_source_file = b.path("cappan_metrics/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cappan_core", .module = lib_mod },
        },
    });

    const metrics_lib = b.addLibrary(.{
        .name = "cappan_metrics",
        .root_module = metrics_mod,
    });
    b.installArtifact(metrics_lib);

    const discover_mod = b.addModule("cappan_discover", .{
        .root_source_file = b.path("cappan_discover/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cappan_core", .module = lib_mod },
        },
    });
    const discover_lib = b.addLibrary(.{
        .name = "cappan_discover",
        .root_module = discover_mod,
    });
    b.installArtifact(discover_lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("cappan_cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cappan_core", .module = lib_mod },
            .{ .name = "cappan_subset", .module = subset_mod },
            .{ .name = "cappan_embed", .module = embed_mod },
            .{ .name = "cappan_inspect", .module = inspect_mod },
            .{ .name = "cappan_pathify", .module = pathify_mod },
            .{ .name = "cappan_metrics", .module = metrics_mod },
            .{ .name = "cappan_discover", .module = discover_mod },
        },
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

    const lib_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_core/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_test = b.addRunArtifact(lib_test);

    const exe_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
                .{ .name = "cappan_subset", .module = subset_mod },
                .{ .name = "cappan_embed", .module = embed_mod },
                .{ .name = "cappan_inspect", .module = inspect_mod },
                .{ .name = "cappan_pathify", .module = pathify_mod },
                .{ .name = "cappan_metrics", .module = metrics_mod },
                .{ .name = "cappan_discover", .module = discover_mod },
            },
        }),
    });
    const run_exe_test = b.addRunArtifact(exe_test);

    const subset_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_subset/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
            },
        }),
    });
    const run_subset_test = b.addRunArtifact(subset_test);

    const embed_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_embed/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
            },
        }),
    });
    const run_embed_test = b.addRunArtifact(embed_test);

    const pathify_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_pathify/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
            },
        }),
    });
    const run_pathify_test = b.addRunArtifact(pathify_test);

    const inspect_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_inspect/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
            },
        }),
    });
    const run_inspect_test = b.addRunArtifact(inspect_test);

    const metrics_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_metrics/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
            },
        }),
    });
    const run_metrics_test = b.addRunArtifact(metrics_test);

    const discover_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cappan_discover/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cappan_core", .module = lib_mod },
            },
        }),
    });
    const run_discover_test = b.addRunArtifact(discover_test);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_test.step);
    test_step.dependOn(&run_exe_test.step);
    test_step.dependOn(&run_subset_test.step);
    test_step.dependOn(&run_embed_test.step);
    test_step.dependOn(&run_pathify_test.step);
    test_step.dependOn(&run_inspect_test.step);
    test_step.dependOn(&run_metrics_test.step);
    test_step.dependOn(&run_discover_test.step);

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
