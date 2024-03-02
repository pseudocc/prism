const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const csi = b.createModule(.{
        .source_file = .{ .path = "utils/csi.zig" },
    });
    const common = b.addModule("prism.common", .{
        .source_file = .{ .path = "prism/common.zig" },
    });
    const cursor = b.addModule("prism.cursor", .{
        .source_file = .{ .path = "prism/cursor.zig" },
        .dependencies = &.{
            .{ .name = "prism.csi", .module = csi },
            .{ .name = "prism.common", .module = common },
        },
    });
    const edit = b.addModule("prism.edit", .{
        .source_file = .{ .path = "prism/edit.zig" },
        .dependencies = &.{
            .{ .name = "prism.csi", .module = csi },
        },
    });
    const graphic = b.addModule("prism.graphic", .{
        .source_file = .{ .path = "prism/graphic.zig" },
        .dependencies = &.{
            .{ .name = "prism.csi", .module = csi },
        },
    });

    const prism_deps: []const std.build.ModuleDependency = &.{
        .{ .name = "prism.csi", .module = csi },
        .{ .name = "prism.common", .module = common },
        .{ .name = "prism.cursor", .module = cursor },
        .{ .name = "prism.edit", .module = edit },
        .{ .name = "prism.graphic", .module = graphic },
    };
    const prism = b.addModule("prism", .{
        .source_file = .{ .path = "prism.zig" },
        .dependencies = prism_deps,
    });

    var lib = b.addStaticLibrary(.{
        .name = "prism",
        .root_source_file = .{ .path = "prism.zig" },
        .target = target,
        .optimize = optimize,
    });
    for (prism_deps) |dep| {
        lib.addModule(dep.name, dep.module);
    }

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "prism.zig" },
        .target = target,
        .optimize = optimize,
    });
    for (prism_deps) |dep| {
        main_tests.addModule(dep.name, dep.module);
    }

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const examples = &[_][]const u8{ "event", "widget" };
    for (examples) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = b.fmt("examples/{s}.zig", .{name}) },
            .target = target,
            .optimize = optimize,
        });
        const install_example = b.addInstallArtifact(example, .{});
        example.addModule("prism", prism);
        examples_step.dependOn(&example.step);
        examples_step.dependOn(&install_example.step);
    }
}
