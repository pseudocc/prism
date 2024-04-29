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

const Fruit = enum {
    Apple,
    Banana,
    Cherry,
    Durian,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const readiness = prompt.confirm.decide(.{
        .question = "Are you ready to start",
        .default = true,
    }) catch |e| return handleInterrupt(e);
    if (readiness) {
        try stdout.writeAll("Let's get started!\n");
    } else {
        try stdout.writeAll("Goodbye!\n");
        return;
    }

    const favorite_fruit = prompt.select.choose(Fruit, .{
        .question = "What is your favorite fruit",
        .choices = &.{
            .{
                .title = "Apple",
                .tip = "A fruit that keeps the doctor away",
                .value = .Apple,
            },
            .{
                .title = "Banana",
                .tip = "A fruit that monkeys love",
                .selected = true,
                .value = .Banana,
            },
            .{
                .title = "Cherry",
                .value = .Cherry,
            },
            .{
                .title = "Durian",
                .tip = "A fruit that smells bad but tastes good",
                .value = .Durian,
            },
        },
    }) catch |e| return handleInterrupt(e);
    const remark = switch (favorite_fruit) {
        .Apple => "You like apples, good for your health!",
        .Banana => "I like bananas too!",
        .Cherry => "Cherries are delicious, but watch out for the pits!",
        .Durian => "How can you like durians, they smell so bad!",
    };
    try stdout.print("{s}\n", .{remark});

    const name = prompt.input.text.allocated(.unicode, allocator, .{
        .question = "What is your name",
        .default = "Nobody",
    }) catch |e| return handleInterrupt(e);
    defer allocator.free(name);
    try stdout.print("Hello, {s}.\n", .{name});

    const age = prompt.input.number(u32).inquire(.{
        .question = "What is your age",
        .default = .{ .value = 30 },
        .validator = prompt.input.number(u32).validator.max(.{ 255, false }),
    }) catch |e| return handleInterrupt(e);
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

    const password = prompt.password.allocated(allocator, .{
        .prompt = "Enter your password",
    }) catch |e| return handleInterrupt(e);
    defer allocator.free(password);
    try stdout.print("Your password is: {s}\n", .{password});
}
