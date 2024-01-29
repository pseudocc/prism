const std = @import("std");
const prism = @import("prism");

const Terminal = prism.Terminal;
const altscreen = prism.altscreen;
const cursor = prism.cursor;
const mouse = prism.mouse;
const edit = prism.edit;

const Border = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,

    pub fn draw(self: Border, term: *Terminal, rect: Rect) !void {
        try term.print("{s}{s}", .{ cursor.goto(rect.x, rect.y), self.top_left });

        for (0..rect.width - 2) |_| {
            try term.write(self.horizontal);
        }
        try term.write(self.top_right);

        for (1..rect.height - 1) |_y| {
            const y: u16 = @intCast(_y);
            try term.print("{s}{s}", .{ cursor.goto(rect.x, rect.y + y), self.vertical });
            try term.print("{s}{s}", .{ cursor.goto(rect.x + rect.width - 1, rect.y + y), self.vertical });
        }

        try term.print("{s}{s}", .{ cursor.goto(rect.x, rect.y + rect.height - 1), self.bottom_left });

        for (0..rect.width - 2) |_| {
            try term.write(self.horizontal);
        }
        try term.write(self.bottom_right);
    }
};

const CurlyBorder: Border = .{
    .top_left = "╭",
    .top_right = "╮",
    .bottom_left = "╰",
    .bottom_right = "╯",
    .horizontal = "─",
    .vertical = "│",
};

const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

const Widget = struct {
    const List = std.SinglyLinkedList([]const u8);

    rect: Rect,
    title: []const u8,
    body: []const u8,

    // state
    words: usize = 0,

    pub fn draw(self: Widget, term: *Terminal) !void {
        try CurlyBorder.draw(term, self.rect);
        // center the title with a space on either side
        const title_x: u16 = @as(u16, @intCast(self.rect.x + (self.rect.width - self.title.len) / 2));
        try term.print("{s} {s} ", .{ cursor.goto(title_x - 1, self.rect.y), self.title });

        var tokens = std.mem.tokenizeAny(u8, self.body, "\n ");
        var i: usize = 0;
        var words: usize = 0;
        try term.write(cursor.goto(self.rect.x + 1, self.rect.y + 1));

        while (tokens.next()) |t| {
            if (words == self.words) {
                break;
            }

            if (i + t.len + 1 > self.rect.width - 2) {
                try term.print("{s}{s}", .{ cursor.next(1), cursor.column(self.rect.x + 1) });
                i = 0;
            }

            if (i != 0) {
                try term.write(" ");
                i += 1;
            }

            try term.write(t);
            i += t.len;
            words += 1;
        }
    }
};

fn clear(term: *Terminal) !void {
    try term.print("{s}{s}CTRL-C - quit\r\n", .{
        edit.erase.display(.both),
        cursor.goto(1, 1),
    });
}

pub fn main() !void {
    const file = std.io.getStdIn();
    var term = try Terminal.init(file);
    try term.enableRaw();
    try term.write(altscreen.enter);
    try term.write(cursor.hide);

    defer {
        term.disableRaw() catch {};
        term.write(altscreen.leave) catch {};
        term.write(cursor.show) catch {};
    }

    var last = std.time.milliTimestamp();
    var w: Widget = .{ .rect = .{ .x = 10, .y = 5, .width = 40, .height = 16 }, .title = "As it Was", .body = "Holding me back, gravity is holding me back. I want you to hold out the palm of your hand. Why don't we leave it at that. Nothing to say, when everything gets in the way. Seems you cannot be replace. And I'm the one who will stay. OOh~ In the world, it's just us. You know it's not the same as it was, in this world, it's just us. You know it' s not the same as it was. As it was. As it was. You know it's not the same." };

    var reader = Terminal.EventReader{ .file = file };
    try w.draw(&term);
    while (true) {
        const event = try reader.read();
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .code => |c| {
                        if (c == std.ascii.control_code.etx) {
                            break;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }

        var now = std.time.milliTimestamp();
        if (now - last > 500) {
            w.words += 1;
            last = now;

            try clear(&term);
            try w.draw(&term);
        }
    }
}
