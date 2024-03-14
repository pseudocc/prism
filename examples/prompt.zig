const std = @import("std");
const prism = @import("prism");
const prompt = @import("prism.prompt");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();
    var name = try prompt.input.allocated(allocator, .{
        .question = "What is your name",
        .default = "Nobody",
    });
    defer allocator.free(name);
    std.debug.print("Hello, {s}.\n", .{name});
}
