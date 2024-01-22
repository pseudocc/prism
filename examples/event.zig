const std = @import("std");
const prism = @import("prism");

const Terminal = prism.Terminal;
const altscreen = prism.altscreen;
const cursor = prism.cursor;
const mouse = prism.mouse;
const edit = prism.edit;

fn clear(writer: std.fs.File.Writer) !void {
    try std.fmt.format(writer, "{s}{s}:q - quit\t:c - clear\r\n", .{
        edit.erase.display(.both),
        cursor.goto(1, 1),
    });
}

pub fn main() !void {
    const file = std.io.getStdIn();
    var writer = file.writer();
    var term = try Terminal.init(file);
    try term.enableRaw();
    try std.fmt.format(writer, "{s}", .{altscreen.enter});
    try std.fmt.format(writer, "{s}", .{mouse.track});

    defer term.disableRaw() catch {};
    defer std.fmt.format(writer, "{s}", .{altscreen.leave}) catch {};
    defer std.fmt.format(writer, "{s}", .{mouse.untrack}) catch {};

    var reader = Terminal.EventReader{ .file = file };
    var command_mode = false;
    try clear(writer);

    while (true) {
        const event = try reader.read();
        if (event != .idle) {
            try writer.print("{s}\r\n", .{event});
        }
        switch (event) {
            .key => |e| {
                if (e.key != .code) {
                    command_mode = false;
                    continue;
                }
                switch (e.key.code) {
                    ':' => {
                        command_mode = true;
                        continue;
                    },
                    'c' => {
                        if (command_mode) {
                            try clear(writer);
                            command_mode = false;
                        }
                    },
                    'q' => {
                        if (command_mode) {
                            break;
                        }
                    },
                    else => {
                        command_mode = false;
                    },
                }
            },
            else => {},
        }
    }
}
