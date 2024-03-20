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

    const prompt = b.addModule("prism.prompt", .{
        .source_file = .{ .path = "prism/prompt.zig" },
        .dependencies = &.{
            .{ .name = "prism", .module = prism },
        },
    });

    var lib = b.addStaticLibrary(.{
        .name = "prism",
        .root_source_file = prism.source_file,
        .target = target,
        .optimize = optimize,
    });
    for (prism_deps) |dep| {
        lib.addModule(dep.name, dep.module);
    }
    b.installArtifact(lib);

    var prompt_lib = b.addStaticLibrary(.{
        .name = "prism.prompt",
        .root_source_file = prompt.source_file,
        .target = target,
        .optimize = optimize,
    });
    for (prompt.dependencies.keys()) |name| {
        prompt_lib.addModule(name, prompt.dependencies.get(name).?);
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
            .root_source_file = module.source_file,
            .target = target,
            .optimize = optimize,
        });
        for (module.dependencies.keys()) |name| {
            tests.addModule(name, module.dependencies.get(name).?);
        }

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    const examples_step = b.step("examples", "Build examples");
    const examples = &[_][]const u8{ "event", "widget", "prompt" };
    for (examples) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = b.fmt("examples/{s}.zig", .{name}) },
            .target = target,
            .optimize = optimize,
        });
        const install_example = b.addInstallArtifact(example, .{});
        example.addModule("prism", prism);
        example.addModule("prism.prompt", prompt);
        examples_step.dependOn(&example.step);
        examples_step.dependOn(&install_example.step);
    }
}
