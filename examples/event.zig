const std = @import("std");
const prism = @import("prism");

const Terminal = prism.Terminal;
const altscreen = prism.altscreen;
const cursor = prism.cursor;
const mouse = prism.mouse;
const edit = prism.edit;

fn clear(term: *Terminal) !void {
    try term.print("{s}{s}:q - quit\t:c - clear\r\n", .{
        edit.erase.display(.both),
        cursor.goto(1, 1),
    });
}

pub fn main() !void {
    const file = std.io.getStdIn();
    var term = try Terminal.init(file);
    try term.enableRaw();
    try term.write(altscreen.enter);
    try term.write(mouse.track);

    defer {
        term.disableRaw() catch {};
        term.write(altscreen.leave) catch {};
        term.write(mouse.untrack) catch {};
    }

    var reader = Terminal.EventReader{ .file = file };
    var command_mode = false;
    try clear(&term);

    while (true) {
        const event = try reader.read();
        if (event != .idle) {
            try term.print("{s}\r\n", .{event});
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
                            try clear(&term);
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
