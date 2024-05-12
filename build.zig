const std = @import("std");

const ModuleDependency = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const csi = b.createModule(.{
        .root_source_file = b.path("utils/csi.zig"),
    });
    const common = b.addModule("prism.common", .{
        .root_source_file = b.path("prism/common.zig"),
    });
    const cursor = b.addModule("prism.cursor", .{
        .root_source_file = b.path("prism/cursor.zig"),
    });
    cursor.addImport("prism.csi", csi);
    cursor.addImport("prism.common", common);
    const edit = b.addModule("prism.edit", .{
        .root_source_file = b.path("prism/edit.zig"),
    });
    edit.addImport("prism.csi", csi);
    const graphic = b.addModule("prism.graphic", .{
        .root_source_file = b.path("prism/graphic.zig"),
    });
    graphic.addImport("prism.csi", csi);

    const prism_deps: []const ModuleDependency = &.{
        .{ .name = "prism.csi", .module = csi },
        .{ .name = "prism.common", .module = common },
        .{ .name = "prism.cursor", .module = cursor },
        .{ .name = "prism.edit", .module = edit },
        .{ .name = "prism.graphic", .module = graphic },
    };
    const prism = b.addModule("prism", .{
        .root_source_file = b.path("prism.zig"),
    });
    for (prism_deps) |dep| {
        prism.addImport(dep.name, dep.module);
    }

    const prompt = b.addModule("prism.prompt", .{
        .root_source_file = b.path("prism/prompt.zig"),
    });
    const prompt_deps: []const ModuleDependency = &.{
        .{ .name = "prism", .module = prism },
    };
    for (prompt_deps) |dep| {
        prompt.addImport(dep.name, dep.module);
    }

    var lib = b.addStaticLibrary(.{
        .name = "prism",
        .root_source_file = prism.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });
    for (prism_deps) |dep| {
        lib.root_module.addImport(dep.name, dep.module);
    }
    b.installArtifact(lib);

    var prompt_lib = b.addStaticLibrary(.{
        .name = "prism.prompt",
        .root_source_file = prompt.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });
    for (prompt_deps) |dep| {
        prompt_lib.root_module.addImport(dep.name, dep.module);
    }
    b.installArtifact(prompt_lib);

    const test_step = b.step("test", "Run all library tests");
    const core_modules = &[_]*std.Build.Module{
        common,
        cursor,
        edit,
        graphic,
        prism,
    };
    const extension_modules = &[_]*std.Build.Module{prompt};
    const all_modules = core_modules ++ extension_modules;
    inline for (all_modules) |module| {
        const tests = b.addTest(.{
            .root_source_file = module.root_source_file.?,
            .target = target,
            .optimize = optimize,
        });

        var iter = common.iterateDependencies(tests, true);
        while (iter.next()) |dep| {
            tests.root_module.addImport(dep.name, dep.module);
        }

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    const examples_step = b.step("examples", "Build examples");
    const examples = &[_][]const u8{ "event", "widget", "prompt" };
    for (examples) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        const install_example = b.addInstallArtifact(example, .{});
        example.root_module.addImport("prism", prism);
        example.root_module.addImport("prism.prompt", prompt);
        examples_step.dependOn(&example.step);
        examples_step.dependOn(&install_example.step);
    }
}
