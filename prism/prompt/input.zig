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

fn InputContext(comptime T: type) type {
    const VDELAY = 5;
    const Direction = enum {
        forward,
        backward,
    };

    return struct {
        const Self = @This();

        vdelay: usize = VDELAY,
        cursor: u16 = 0,
        confirmed: bool = false,
        maybe_invalid: ?[]const u8 = null,
        input: std.ArrayList(T),

        // refactor moveLeft and moveRight into this
        fn move(self: *Self, comptime direction: Direction, word_level: bool) u16 {
            const items = self.input.items;
            const early_exit: bool = !word_level or switch (direction) {
                .forward => items.len - self.cursor <= 1,
                .backward => self.cursor <= 1,
            };
            if (early_exit) {
                return switch (direction) {
                    .forward => @min(items.len - self.cursor, 1),
                    .backward => @min(self.cursor, 1),
                };
            }

            var count: u16 = switch (direction) {
                .forward => 1,
                .backward => 0,
            };
            while (true) : (count += 1) {
                const if_cond = switch (direction) {
                    .forward => self.cursor + count < items.len,
                    .backward => self.cursor - count > 0,
                };
                if (!if_cond) break;

                const item = switch (direction) {
                    .forward => items[self.cursor + count],
                    .backward => items[self.cursor - count - 1],
                };
                const sentinel: u8 = switch (T) {
                    u8 => item,
                    u21 => this: {
                        const n = std.unicode.utf8CodepointSequenceLength(item) catch unreachable;
                        break :this if (n == 1) @intCast(item) else std.ascii.control_code.nul;
                    },
                    else => unreachable,
                };
                if (!std.ascii.isAlphanumeric(sentinel)) break;
            }
            return count;
        }

        inline fn insert(self: *Self, c: T) !void {
            try self.input.insert(self.cursor, c);
            self.setCursor(self.cursor + 1);
        }

        inline fn remove(self: *Self, comptime direction: Direction, word_level: bool) !void {
            const count = self.move(direction, word_level);
            if (count < 0) return;

            switch (direction) {
                .forward => {
                    try self.input.replaceRange(self.cursor, count, &.{});
                    self.resetVdelay();
                },
                .backward => {
                    try self.input.replaceRange(self.cursor - count, count, &.{});
                    self.setCursor(self.cursor - count);
                },
            }
        }

        inline fn confirm(self: *Self, options: anytype) !void {
            self.maybe_invalid = try options.validate(T, self.input.items);
            self.confirmed = true;
        }

        inline fn setCursor(self: *Self, cursor: u16) void {
            self.cursor = cursor;
            self.resetVdelay();
        }

        inline fn decVdelay(self: *Self, options: anytype) !void {
            if (self.vdelay == 0) return;
            self.vdelay -= 1;
            if (self.vdelay == 0) {
                self.maybe_invalid = try options.validate(T, self.input.items);
            }
        }

        inline fn resetVdelay(self: *Self) void {
            self.vdelay = VDELAY;
            self.maybe_invalid = null;
        }

        inline fn justUpdated(self: *Self) bool {
            return self.vdelay == VDELAY;
        }
    };
}

fn readInput(comptime T: type, comptime BufferType: type, options: Options(T)) !std.ArrayList(BufferType) {
    switch (BufferType) {
        u8, u21 => {},
        else => @compileError("unsupported type"),
    }

    var t = try prepareQestion(options);
    defer deferCommon(t);
    errdefer errdeferCommon(t);

    const default_style = Style.origin.default.fill(options.theme.default);
    const invalid_style = Style.origin.invalid.fill(options.theme.invalid);

    var ctx = InputContext(BufferType){ .input = std.ArrayList(BufferType).init(std.heap.page_allocator) };
    errdefer ctx.input.deinit();

    prompt.terminal.reader_mutex.lock();
    defer prompt.terminal.reader_mutex.unlock();
    const r = &prompt.terminal.reader;
    try r.reset();

    while (!ctx.confirmed) {
        const ev = try r.read();
        switch (ev) {
            .idle => try ctx.decVdelay(options),
            .key => |e| {
                switch (e.key) {
                    .code => |c| if (std.ascii.isPrint(c)) {
                        try ctx.insert(c);
                    } else if (std.ascii.isControl(c)) {
                        switch (c) {
                            std.ascii.control_code.etx => return error.Interrupted,
                            std.ascii.control_code.eot => return error.Aborted,
                            else => {},
                        }
                    },
                    .home => ctx.cursor = 0,
                    .left => ctx.cursor -= ctx.move(.backward, e.modifiers.ctrl),
                    .end => ctx.cursor = @intCast(ctx.input.items.len),
                    .right => ctx.cursor += ctx.move(.forward, e.modifiers.ctrl),
                    .delete => try ctx.remove(.forward, e.modifiers.ctrl),
                    .backspace => try ctx.remove(.backward, e.modifiers.ctrl),
                    .enter => try ctx.confirm(options),
                    else => {},
                }
            },
            .unicode => |c| if (BufferType == u21) try ctx.insert(c),
            else => {},
        }

        if (ctx.justUpdated()) {
            try t.print("{s}{s}{s}", .{
                prism.cursor.next(1),
                prism.edit.erase.line(.both),
                prism.cursor.restore,
            });
        } else if (ctx.maybe_invalid) |message| {
            try t.print("{s}{s}{s}{s}{s}", .{
                prism.cursor.next(1),
                prism.edit.erase.line(.both),
                invalid_style.before.?,
                message,
                invalid_style.after.?,
            });
            ctx.confirmed = false;
        }

        try t.write(prism.cursor.restore);
        try t.write(prism.edit.erase.line(.right));

        const items = ctx.input.items;
        const cursor = ctx.cursor;
        if (items.len == 0) {
            try t.print("{s}{s}{s}{s}", .{
                default_style.before.?,
                options.default orelse "",
                default_style.after.?,
                prism.cursor.restore,
            });
        } else {
            for (items) |c| {
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

    return ctx.input;
}

fn deferCommon(t: *prism.Terminal) void {
    t.disableRaw() catch {};
    t.unbufferedWrite("\n") catch {};
}

fn errdeferCommon(t: *prism.Terminal) void {
    t.disableRaw() catch {};
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
            .ascii => try readInput([]const u8, u8, options),
            .unicode => try readInput([]const u8, u21, options),
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
            .ascii => try readInput([]const u8, u8, options),
            .unicode => try readInput([]const u8, u21, options),
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
