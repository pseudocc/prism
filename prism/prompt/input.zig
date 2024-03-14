const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");

const g = prism.graphic;

pub const Style = struct {
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,

    const p = std.fmt.comptimePrint;
    const origin = struct {
        const question: Style = .{
            .before = p("{s}> {s}", .{
                g.attrs(&.{g.fg(.{ .ansi = .green })}),
                g.attrs(&.{}),
            }),
            .after = "? ",
        };

        const default: Style = .{
            .before = p("{s}", .{
                g.attrs(&.{g.fg(.{ .ansi = .bright_black })}),
            }),
            .after = p("{s}", .{
                g.attrs(&.{}),
            }),
        };

        const invalid: Style = .{
            .before = p("{s}! {s}", .{
                g.attrs(&.{g.fg(.{ .ansi = .red })}),
                g.attrs(&.{}),
            }),
            .after = "",
        };
    };

    fn fill(self: Style, maybe_other: ?Style) Style {
        if (maybe_other == null) {
            return self;
        }
        var result = maybe_other.?;
        if (self.before != null) {
            result.before = self.before;
        }
        if (self.after != null) {
            result.after = self.after;
        }
        return result;
    }
};

pub const Theme = struct {
    question: ?Style = null,
    default: ?Style = null,
    invalid: ?Style = null,
};

pub const Options = struct {
    pub const Validator = *const fn ([]const u8) ?[]const u8;

    question: []const u8,
    default: ?[]const u8 = null,
    validate: ?Validator = null,

    theme: Theme = .{},
};

var _term_init: bool = false;
var _term: prism.Terminal = undefined;

fn term() !prism.Terminal {
    if (_term_init) {
        return _term;
    }

    const stdout = std.io.getStdOut();
    _term = try prism.Terminal.init(stdout);
    _term_init = true;
    return _term;
}

fn validate_wrapper(string: []const u21, maybe_validate: ?Options.Validator) !?[]const u8 {
    var validate = maybe_validate orelse return null;
    var allocator = std.heap.page_allocator;
    var count: usize = 0;
    for (string) |c| {
        const l = std.unicode.utf8CodepointSequenceLength(c) catch unreachable;
        count += l;
    }

    var buffer = try allocator.alloc(u8, count);
    var pos: usize = 0;
    defer allocator.free(buffer);

    for (string) |c| {
        const l = std.unicode.utf8Encode(c, buffer[pos..]) catch unreachable;
        pos += l;
    }

    return validate(buffer);
}

fn moveLeft(input: std.ArrayList(u21), cursor: u16, ctrl: bool) u16 {
    if (!ctrl or cursor <= 1) {
        return @min(cursor, 1);
    }
    var move: u16 = 1;
    while (cursor - move > 0) : (move += 1) {
        const c = input.items[cursor - move - 1];
        if (c == @as(u21, ' ')) {
            break;
        }
    }
    return move;
}

fn moveRight(input: std.ArrayList(u21), cursor: u16, ctrl: bool) u16 {
    if (!ctrl or input.items.len - cursor <= 1) {
        return @min(input.items.len - cursor, 1);
    }
    var move: u16 = 0;
    while (cursor + move < input.items.len) : (move += 1) {
        const c = input.items[cursor + move];
        if (c == @as(u21, ' ')) {
            move += 1;
            break;
        }
    }
    return @min(move, input.items.len - cursor);
}

pub fn allocated(allocator: Allocator, options: Options) ![]const u8 {
    var t = try term();
    var r = prism.Terminal.EventReader{ .file = t.file };
    try t.enableRaw();

    errdefer t.disableRaw() catch {};
    defer t.unbufferedWrite("\n") catch {};
    defer t.disableRaw() catch {};

    const question_style = Style.origin.question.fill(options.theme.question);
    const default_style = Style.origin.default.fill(options.theme.default);
    const invalid_style = Style.origin.invalid.fill(options.theme.invalid);

    const VDELAY = 5;
    var input = std.ArrayList(u21).init(allocator);
    var maybe_invalid: ?[]const u8 = null;
    var vdelay: usize = VDELAY;
    var cursor: u16 = 0;
    var confirmed = false;

    errdefer input.deinit();
    defer input.deinit();

    try t.print("{s}{s}{s}{s}", .{
        question_style.before.?,
        options.question,
        question_style.after.?,
        prism.cursor.save,
    });

    while (!confirmed) {
        const ev = try r.read();
        switch (ev) {
            .idle => {
                if (vdelay > 0) {
                    vdelay -= 1;
                    if (vdelay == 0) {
                        maybe_invalid = try validate_wrapper(input.items, options.validate);
                    }
                }
            },
            .key => |e| {
                switch (e.key) {
                    .code => |c| {
                        if (std.ascii.isPrint(c)) {
                            try input.insert(cursor, c);
                            cursor += 1;
                            vdelay = VDELAY;
                        }
                    },
                    .home => cursor = 0,
                    .left => cursor -= moveLeft(input, cursor, e.modifiers.ctrl),
                    .end => cursor = @intCast(input.items.len),
                    .right => cursor += moveRight(input, cursor, e.modifiers.ctrl),
                    .delete => {
                        const move = moveRight(input, cursor, e.modifiers.ctrl);
                        if (move > 0) {
                            try input.replaceRange(cursor, move, &.{});
                            vdelay = VDELAY;
                        }
                    },
                    .backspace => {
                        const move = moveLeft(input, cursor, e.modifiers.ctrl);
                        if (move > 0) {
                            try input.replaceRange(cursor - move, move, &.{});
                            cursor -= move;
                            vdelay = VDELAY;
                        }
                    },
                    .enter => {
                        maybe_invalid = try validate_wrapper(input.items, options.validate);
                        confirmed = true;
                    },
                    else => {},
                }
            },
            .unicode => |c| {
                try input.insert(cursor, c);
                cursor += 1;
                vdelay = VDELAY;
            },
            else => {},
        }

        if (maybe_invalid) |message| {
            try t.print("{s}{s}{s}{s}{s}", .{
                prism.cursor.next(1),
                prism.edit.erase.line(.both),
                invalid_style.before.?,
                message,
                invalid_style.after.?,
            });
            confirmed = false;
        }

        try t.write(prism.cursor.restore);
        try t.write(prism.edit.erase.line(.right));

        if (input.items.len == 0) {
            try t.print("{s}{s}{s}{s}", .{
                default_style.before.?,
                options.default.?,
                default_style.after.?,
                prism.cursor.restore,
            });
        } else {
            for (input.items) |c| {
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buffer) catch unreachable;
                try t.write(buffer[0..n]);
            }
            try t.print("{s}{s}", .{
                prism.cursor.restore,
                prism.cursor.right(cursor),
            });
        }

        try t.flush();
    }

    if (input.items.len == 0 and options.default != null) {
        return try allocator.dupe(u8, options.default.?);
    }

    var result = std.ArrayList(u8).init(allocator);
    for (input.items) |c| {
        var buffer: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buffer) catch unreachable;
        try result.appendSlice(buffer[0..n]);
    }

    return result.toOwnedSlice();
}
