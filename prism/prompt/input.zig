const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");
const prompt = @import("../prompt.zig");

const g = prism.graphic;

fn prepareQestion(options: anytype) !*prism.Terminal {
    const t = try prompt.terminal.get();
    if (t.raw_enabled) {
        return error.Unsupported;
    }

    try t.enableRaw();
    const question_style = Style.origin.question.fill(options.theme.question);

    // "\n + up(1)" will preserve a newline for the error message
    try t.print("{s}{s}{s}\n{s}{s}", .{
        question_style.before.?,
        options.question,
        question_style.after.?,
        prism.cursor.up(1),
        prism.cursor.save,
    });

    return t;
}

fn readInput(comptime T: type, options: anytype) !std.ArrayList(T) {
    switch (T) {
        u8, u21 => {},
        else => @compileError("unsupported type"),
    }

    var t = try prepareQestion(options);
    defer deferCommon(t);
    errdefer errdeferCommon(t);

    const default_style = Style.origin.default.fill(options.theme.default);
    const invalid_style = Style.origin.invalid.fill(options.theme.invalid);

    const VDELAY = 5;
    var maybe_invalid: ?[]const u8 = null;
    var vdelay: usize = VDELAY;
    var cursor: u16 = 0;
    var confirmed = false;

    var input = std.ArrayList(T).init(std.heap.page_allocator);
    errdefer input.deinit();

    prompt.terminal.reader_mutex.lock();
    defer prompt.terminal.reader_mutex.unlock();
    const r = &prompt.terminal.reader;
    try r.reset();

    while (!confirmed) {
        const ev = try r.read();
        switch (ev) {
            .idle => {
                if (vdelay > 0) {
                    vdelay -= 1;
                    if (vdelay == 0) {
                        maybe_invalid = try options.validate(T, input.items);
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
                    .left => cursor -= moveLeft(T, input.items, cursor, e.modifiers.ctrl),
                    .end => cursor = @intCast(input.items.len),
                    .right => cursor += moveRight(T, input.items, cursor, e.modifiers.ctrl),
                    .delete => {
                        const move = moveRight(T, input.items, cursor, e.modifiers.ctrl);
                        if (move > 0) {
                            try input.replaceRange(cursor, move, &.{});
                            vdelay = VDELAY;
                        }
                    },
                    .backspace => {
                        const move = moveLeft(T, input.items, cursor, e.modifiers.ctrl);
                        if (move > 0) {
                            try input.replaceRange(cursor - move, move, &.{});
                            cursor -= move;
                            vdelay = VDELAY;
                        }
                    },
                    .enter => {
                        maybe_invalid = try options.validate(T, input.items);
                        confirmed = true;
                    },
                    else => {},
                }
            },
            .unicode => |c| {
                if (T == u21) {
                    try input.insert(cursor, c);
                    cursor += 1;
                    vdelay = VDELAY;
                }
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
                options.default orelse "",
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

fn deferCommon(t: *prism.Terminal) void {
    t.disableRaw() catch {};
    t.unbufferedWrite("\n") catch {};
}

fn errdeferCommon(t: *prism.Terminal) void {
    t.disableRaw() catch {};
}

fn moveLeft(comptime T: type, items: []const T, cursor: u16, ctrl: bool) u16 {
    if (!ctrl or cursor <= 1) {
        return @min(cursor, 1);
    }
    var move: u16 = 1;
    while (cursor - move > 0) : (move += 1) {
        const item = items[cursor - move - 1];
        const sentinel: u8 = switch (T) {
            u8 => item,
            u21 => this: {
                const n = std.unicode.utf8CodepointSequenceLength(item) catch unreachable;
                break :this if (n == 1) @intCast(item) else std.ascii.control_code.nul;
            },
            else => unreachable,
        };
        if (!std.ascii.isAlphanumeric(sentinel)) {
            break;
        }
    }
    return move;
}

fn moveRight(comptime T: type, items: []const T, cursor: u16, ctrl: bool) u16 {
    if (!ctrl or items.len - cursor <= 1) {
        return @min(items.len - cursor, 1);
    }
    var move: u16 = 0;
    while (cursor + move < items.len) : (move += 1) {
        const item = items[cursor + move];
        const sentinel: u8 = switch (T) {
            u8 => item,
            u21 => this: {
                const n = std.unicode.utf8CodepointSequenceLength(item) catch unreachable;
                break :this if (n == 1) @intCast(item) else std.ascii.control_code.nul;
            },
            else => unreachable,
        };
        if (!std.ascii.isAlphanumeric(sentinel)) {
            move += 1;
            break;
        }
    }
    return @min(move, items.len - cursor);
}

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

pub fn Options(comptime T: type) type {
    const OutputKind = enum {
        integer,
        float,
        string,
    };

    const kind: OutputKind = if (T == []const u8) .string else switch (@typeInfo(T)) {
        .Int => .integer,
        .Float => .float,
        else => @compileError("unsupported type"),
    };

    return struct {
        const Self = @This();
        pub const Validator = *const fn (T) ?[]const u8;

        question: []const u8,
        default: ?T = null,
        validator: ?Validator = null,

        theme: Theme = .{},

        fn validate(self: Self, comptime Y: type, string: []const Y) !?[]const u8 {
            var allocator = std.heap.page_allocator;
            const count = switch (Y) {
                u8 => string.len,
                u21 => this: {
                    var n: usize = 0;
                    for (string) |c| {
                        const l = std.unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        n += l;
                    }
                    break :this n;
                },
                else => unreachable,
            };

            if (count == 0) {
                const default_string = this: {
                    const default = self.default orelse break :this "";
                    break :this switch (kind) {
                        .integer => std.fmt.allocPrint(allocator, "{d}", .{default}),
                        .float => std.fmt.allocPrint(allocator, "{f}", .{default}),
                        .string => return self.validateString(default),
                    };
                };
                defer allocator.free(default_string);
                return self.validateString(default_string);
            }

            if (Y == u8) {
                return self.validateString(string);
            }

            var buffer = try allocator.alloc(u8, count);
            var pos: usize = 0;
            defer allocator.free(buffer);

            for (string) |c| {
                const l = std.unicode.utf8Encode(c, buffer[pos..]) catch unreachable;
                pos += l;
            }

            return self.validateString(buffer);
        }

        fn validateString(self: Self, string: []const u8) ?[]const u8 {
            const validator = self.validator orelse return null;
            const value: T = switch (kind) {
                .integer => std.fmt.parseInt(T, string, 10) catch |e| switch (e) {
                    std.fmt.ParseIntError.Overflow => return "Overflow",
                    std.fmt.ParseIntError.InvalidCharacter => return "Invalid character",
                },
                .float => std.fmt.parseFloat(T, string) catch |e| switch (e) {
                    std.fmt.ParseFloatError.InvalidCharacter => return "Invalid character",
                },
                .string => string,
            };
            return validator(value);
        }
    };
}

pub const text = struct {
    const TextOptions = Options([]const u8);

    pub const Variant = enum {
        ascii,
        unicode,
    };

    pub fn allocated(comptime v: Variant, allocator: Allocator, options: TextOptions) ![]const u8 {
        var input = switch (v) {
            .ascii => try readInput(u8, options),
            .unicode => try readInput(u21, options),
        };
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

    fn bufcopy(dest: []u8, src: []const u8) !usize {
        const n = src.len;
        if (n > dest.len) {
            return error.BufferTooSmall;
        }
        @memcpy(dest[0..n], src);
        return n;
    }

    pub fn buffered(comptime v: Variant, dest: []u8, options: TextOptions) !usize {
        var input = switch (v) {
            .ascii => try readInput(u8, options),
            .unicode => try readInput(u21, options),
        };
        defer input.deinit();

        if (input.items.len == 0 and options.default != null) {
            return bufcopy(dest, options.default.?);
        }

        return switch (v) {
            .ascii => bufcopy(dest, input.items),
            .unicode => this: {
                var i: usize = 0;
                for (input.items) |c| {
                    var buffer: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &buffer) catch unreachable;
                    if (i + n > dest.len) {
                        break :this error.BufferTooSmall;
                    }
                    @memcpy(dest[i .. i + n], buffer[0..n]);
                    i += n;
                }
                break :this i;
            },
        };
    }
};
