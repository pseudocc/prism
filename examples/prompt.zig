const std = @import("std");
const prism = @import("prism");
const prompt = @import("prism.prompt");

fn validateAge(value: []const u8) ?[]const u8 {
    const age = std.fmt.parseInt(i64, value, 10) catch {
        return "Invalid age";
    };
    if (age < 0) {
        return "Age must be positive";
    }
    if (age > 255) {
        return "You are too old to be using this program";
    }
    return null;
}

pub fn main() !void {
    var stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();
    const name = try prompt.input.allocated(allocator, .{
        .question = "What is your name",
        .default = "Nobody",
    });
    defer allocator.free(name);
    try stdout.print("Hello, {s}.\n", .{name});

    var buffer: [16]u8 = undefined;
    const n = try prompt.input.buffered(&buffer, .{
        .question = "What is your age",
        .default = "30",
        .validate = &validateAge,
    });
    const ageString = buffer[0..n];
    const age = std.fmt.parseInt(u8, ageString, 10) catch unreachable;
    const message = switch (age) {
        0...2 => "Baby, you won't remember this!",
        3...12 => "Kid, enjoy your childhood!",
        13...19 => "Teenager, don't do anything stupid!",
        20...64 => "Adult, you are responsible for your actions!",
        65...90 => "Senior, you are wise and experienced!",
        91...120 => "Elder, you are a living legend!",
        else => "Ghost, you are not supposed to be here!",
    };
    try stdout.print("{s}\n", .{message});
}
