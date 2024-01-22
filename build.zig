const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const csi = b.createModule(.{
        .source_file = .{ .path = "utils/csi.zig" },
    });
    const cursor = b.addModule("prism.cursor", .{
        .source_file = .{ .path = "prism/cursor.zig" },
        .dependencies = &.{
            .{ .name = "prism.csi", .module = csi },
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
        .{ .name = "prism.cursor", .module = cursor },
        .{ .name = "prism.edit", .module = edit },
        .{ .name = "prism.graphic", .module = graphic },
    };
    const prism = b.addModule("prism", .{
        .source_file = .{ .path = "prism.zig" },
        .dependencies = prism_deps,
    });
    _ = prism;

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
        lib.addModule(dep.name, dep.module);
    }

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
