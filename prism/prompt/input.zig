const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");

const g = prism.graphic;

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

fn moveLeft(items: []const u21, cursor: u16, ctrl: bool) u16 {
    if (!ctrl or cursor <= 1) {
        return @min(cursor, 1);
    }
    var move: u16 = 1;
    while (cursor - move > 0) : (move += 1) {
        const c = items[cursor - move - 1];
        const n = std.unicode.utf8CodepointSequenceLength(c) catch unreachable;
        if (n == 1 and !std.ascii.isAlphanumeric(@intCast(c))) {
            break;
        }
    }
    return move;
}

fn moveRight(items: []const u21, cursor: u16, ctrl: bool) u16 {
    if (!ctrl or items.len - cursor <= 1) {
        return @min(items.len - cursor, 1);
    }
    var move: u16 = 0;
    while (cursor + move < items.len) : (move += 1) {
        const c = items[cursor + move];
        const n = std.unicode.utf8CodepointSequenceLength(c) catch unreachable;
        if (n == 1 and !std.ascii.isAlphanumeric(@intCast(c))) {
            move += 1;
            break;
        }
    }
    return @min(move, items.len - cursor);
}

pub const text = struct {
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

    fn validate_wrapper(
        string: []const u21,
        default: ?[]const u8,
        maybe_validate: ?Options.Validator,
    ) !?[]const u8 {
        var validate = maybe_validate orelse return null;
        var allocator = std.heap.page_allocator;
        var count: usize = 0;
        for (string) |c| {
            const l = std.unicode.utf8CodepointSequenceLength(c) catch unreachable;
            count += l;
        }

        if (count == 0) {
            return validate(default orelse "");
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

    fn interm(options: Options) !std.ArrayList(u21) {
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
        var allocator = std.heap.page_allocator;
        var input = std.ArrayList(u21).init(allocator);
        var maybe_invalid: ?[]const u8 = null;
        var vdelay: usize = VDELAY;
        var cursor: u16 = 0;
        var confirmed = false;

        errdefer input.deinit();

        // "\n + up(1)" will preserve a newline for the error message
        try t.print("{s}{s}{s}\n{s}{s}", .{
            question_style.before.?,
            options.question,
            question_style.after.?,
            prism.cursor.up(1),
            prism.cursor.save,
        });

        while (!confirmed) {
            const ev = try r.read();
            switch (ev) {
                .idle => {
                    if (vdelay > 0) {
                        vdelay -= 1;
                        if (vdelay == 0) {
                            maybe_invalid = try validate_wrapper(input.items, options.default, options.validate);
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
                            } else if (std.ascii.isControl(c)) {
                                switch (c) {
                                    std.ascii.control_code.etx => return error.Interrupted,
                                    std.ascii.control_code.eot => return error.Aborted,
                                    else => {},
                                }
                            }
                        },
                        .home => cursor = 0,
                        .left => cursor -= moveLeft(input.items, cursor, e.modifiers.ctrl),
                        .end => cursor = @intCast(input.items.len),
                        .right => cursor += moveRight(input.items, cursor, e.modifiers.ctrl),
                        .delete => {
                            const move = moveRight(input.items, cursor, e.modifiers.ctrl);
                            if (move > 0) {
                                try input.replaceRange(cursor, move, &.{});
                                vdelay = VDELAY;
                            }
                        },
                        .backspace => {
                            const move = moveLeft(input.items, cursor, e.modifiers.ctrl);
                            if (move > 0) {
                                try input.replaceRange(cursor - move, move, &.{});
                                cursor -= move;
                                vdelay = VDELAY;
                            }
                        },
                        .enter => {
                            maybe_invalid = try validate_wrapper(input.items, options.default, options.validate);
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

            if (vdelay == VDELAY) {
                try t.print("{s}{s}{s}", .{
                    prism.cursor.next(1),
                    prism.edit.erase.line(.both),
                    prism.cursor.restore,
                });
                maybe_invalid = null;
            } else if (maybe_invalid) |message| {
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

        return input;
    }

    pub fn allocated(allocator: Allocator, options: Options) ![]const u8 {
        var input = try interm(options);
        defer input.deinit();

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

    pub fn buffered(dest: []u8, options: Options) !usize {
        var input = try interm(options);
        defer input.deinit();

        if (input.items.len == 0 and options.default != null) {
            const result = options.default.?;
            const n = result.len;
            if (n > dest.len) {
                return error.BufferTooSmall;
            }
            @memcpy(dest[0..n], result);
            return n;
        }

        var i: usize = 0;
        for (input.items) |c| {
            var buffer: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buffer) catch unreachable;
            if (i + n > dest.len) {
                return error.BufferTooSmall;
            }
            @memcpy(dest[i .. i + n], buffer[0..n]);
            i += n;
        }

        return i;
    }
};
