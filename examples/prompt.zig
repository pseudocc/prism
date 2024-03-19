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

const stdout = std.io.getStdOut().writer();

inline fn handleInterrupt(e: anyerror) !void {
    if (e == error.Interrupted) {
        try stdout.writeAll("CTRL+C received, exiting...\n");
        return;
    }
    return e;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const name = prompt.input.text.allocated(.unicode, allocator, .{
        .question = "What is your name",
        .default = "Nobody",
    }) catch |e| return handleInterrupt(e);
    defer allocator.free(name);
    try stdout.print("Hello, {s}.\n", .{name});

    const age = prompt.input.number(f32).inquire(.{
        .question = "What is your age",
        .default = .{
            .precision = 1,
            .value = 30,
            .format = .decimal,
        },
        .validator = prompt.input.number(f32).validator.max(.{ 255, false }),
    }) catch |e| return handleInterrupt(e);
    const rounded_age: u8 = @intFromFloat(@round(age));
    const message = switch (rounded_age) {
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
