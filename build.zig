const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("prism", .{
        .root_source_file = .{ .path = "prism.zig" },
    });

    const lib = b.addStaticLibrary(.{
        .name = "prism",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "prism.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "prism.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
