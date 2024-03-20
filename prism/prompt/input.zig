const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");
const prompt = @import("../prompt.zig");

const g = prism.graphic;

fn prepareQestion(comptime T: type, options: Options(T)) !*prism.Terminal {
    if (options.default) |default| {
        const default_value: T = switch (Options(T).kind) {
            .integer => this: {
                switch (default.base) {
                    2, 8, 10, 16 => {},
                    else => return error.UnsupportedBase,
                }
                break :this default.value;
            },
            .float => default.value,
            .string => default,
        };

        if (options.validator) |validator| {
            if (validator(default_value)) |_| {
                return error.InvalidDefault;
            }
        }
    }

    const t = try prompt.terminal.get();
    if (t.raw_enabled) {
        return error.Unsupported;
    }

    try t.enableRaw();
    const question_style = Style.origin.question.fill(options.theme.question);

    // "\n + up(1)" will preserve a newline for the error message
    try t.print("{s}" ** 3 ++ "\n" ++ "{s}" ** 2, .{
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

        inline fn removeRange(self: *Self, start: u16, count: u16) void {
            // remove items won't fail
            self.input.replaceRange(start, count, &.{}) catch unreachable;
        }

        inline fn remove(self: *Self, comptime direction: Direction, word_level: bool) void {
            const count = self.move(direction, word_level);
            if (count < 0) return;

            switch (direction) {
                .forward => {
                    self.removeRange(self.cursor, count);
                    self.resetVdelay();
                },
                .backward => {
                    self.removeRange(self.cursor - count, count);
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

    const t = try prepareQestion(T, options);
    defer deferCommon(options.cleanup, t);

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
                        const is_valid = if (T == []const u8) true else this: {
                            const signed = switch (@typeInfo(T)) {
                                .Int => |i| i.signedness == .signed,
                                .Float => true,
                                else => unreachable,
                            };
                            const is_float = switch (@typeInfo(T)) {
                                .Float => true,
                                else => false,
                            };

                            const items = ctx.input.items;
                            switch (ctx.cursor) {
                                0 => switch (c) {
                                    '-' => break :this signed,
                                    else => {},
                                },
                                1 => {
                                    const first = items[0];
                                    if (first == '0') {
                                        switch (std.ascii.toLower(c)) {
                                            'x', 'o', 'b' => break :this !is_float,
                                            else => {},
                                        }
                                    }
                                },
                                2 => {
                                    const first = items[0];
                                    const second = items[1];
                                    if (first == '0' and !is_float) {
                                        break :this switch (std.ascii.toLower(second)) {
                                            'x' => switch (c) {
                                                'a'...'f', 'A'...'F', '0'...'9' => true,
                                                else => false,
                                            },
                                            'o' => switch (c) {
                                                '0'...'7' => true,
                                                else => false,
                                            },
                                            'b' => switch (c) {
                                                '0', '1' => true,
                                                else => false,
                                            },
                                            else => std.ascii.isDigit(c),
                                        };
                                    }
                                },
                                else => {},
                            }

                            break :this switch (c) {
                                '.', 'e', 'E', '-' => is_float,
                                else => std.ascii.isDigit(c),
                            };
                        };
                        if (is_valid) try ctx.insert(c);
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
                    .delete => ctx.remove(.forward, e.modifiers.ctrl),
                    .backspace => ctx.remove(.backward, e.modifiers.ctrl),
                    .enter => try ctx.confirm(options),
                    else => {},
                }
            },
            .unicode => |c| if (BufferType == u21) try ctx.insert(c),
            else => {},
        }

        if (ctx.justUpdated()) {
            try t.print("{s}" ** 3, .{
                prism.cursor.next(1),
                prism.edit.erase.line(.both),
                prism.cursor.restore,
            });
        } else if (ctx.maybe_invalid) |message| {
            try t.print("{s}" ** 5, .{
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
            try t.write(default_style.before.?);
            if (options.default) |default| {
                const writer = t.buffered.writer();
                switch (Options(T).kind) {
                    .integer => try std.fmt.formatInt(default.value, default.base, .lower, .{}, writer),
                    .float => {
                        const format: std.fmt.FormatOptions = .{ .precision = default.precision };
                        switch (default.format) {
                            .decimal => try std.fmt.formatFloatDecimal(default.value, format, writer),
                            .scientific => try std.fmt.formatFloatScientific(default.value, format, writer),
                            .hexadecimal => try std.fmt.formatFloatHexadecimal(default.value, format, writer),
                        }
                    },
                    .string => try t.print("{s}", .{default}),
                }
            }
            try t.print("{s}" ** 2, .{
                default_style.after.?,
                prism.cursor.restore,
            });
        } else {
            for (items) |c| {
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buffer) catch unreachable;
                try t.write(buffer[0..n]);
            }
            try t.print("{s}" ** 2, .{
                prism.cursor.restore,
                prism.cursor.right(cursor),
            });
        }

        try t.flush();
    }

    return ctx.input;
}

fn deferCommon(cleanup: bool, t: *prism.Terminal) void {
    t.disableRaw() catch {};
    t.flush() catch {};
    if (cleanup) {
        t.unbufferedPrint("{s}" ** 3, .{
            prism.cursor.restore,
            prism.cursor.column(1),
            prism.edit.erase.display(.below),
        }) catch {};
    } else {
        t.unbufferedWrite("\n") catch {};
    }
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

    return struct {
        pub const Validator = *const fn (T) ?[]const u8;

        const Self = @This();
        const kind: OutputKind = if (T == []const u8) .string else switch (@typeInfo(T)) {
            .Int => .integer,
            .Float => .float,
            else => @compileError("unsupported type"),
        };

        const Default = switch (kind) {
            .integer => struct {
                value: T,
                base: u8 = 10,
            },
            .float => struct {
                value: T,
                precision: u8 = 4,
                format: enum {
                    decimal,
                    scientific,
                    hexadecimal,
                } = .decimal,
            },
            .string => T,
        };

        question: []const u8,
        default: ?Default = null,
        validator: ?Validator = null,
        cleanup: bool = false,

        theme: Theme = .{},

        fn validate(self: Self, comptime BufferType: type, string: []const BufferType) !?[]const u8 {
            const allocator = std.heap.page_allocator;
            const count = switch (BufferType) {
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
                // we checked default value before
                if (self.default) |_| return null;
                return self.validateString("");
            }

            if (BufferType == u8) {
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
                .integer => number(T).parse(string) catch |e| switch (e) {
                    std.fmt.ParseIntError.Overflow => return "Overflow",
                    std.fmt.ParseIntError.InvalidCharacter => return "Invalid character",
                },
                .float => number(T).parse(string) catch |e| switch (e) {
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

pub fn number(comptime T: type) type {
    return struct {
        pub const NumberOptions = Options(T);

        pub const validator = struct {
            pub const Bound = struct { T, bool };

            pub fn min(comptime bound: Bound) NumberOptions.Validator {
                const Closure = struct {
                    pub fn call(value: T) ?[]const u8 {
                        if (bound[1]) {
                            if (value < bound[0]) {
                                return std.fmt.comptimePrint("Value should be greater than or equal to {}", .{bound[0]});
                            }
                        } else {
                            if (value <= bound[0]) {
                                return std.fmt.comptimePrint("Value should be greater than {}", .{bound[0]});
                            }
                        }
                        return null;
                    }
                };
                return &Closure.call;
            }

            pub fn max(comptime bound: Bound) NumberOptions.Validator {
                const Closure = struct {
                    pub fn call(value: T) ?[]const u8 {
                        if (bound[1]) {
                            if (value > bound[0]) {
                                return std.fmt.comptimePrint("Value should be less than or equal to {}", .{bound[0]});
                            }
                        } else {
                            if (value >= bound[0]) {
                                return std.fmt.comptimePrint("Value should be less than {}", .{bound[0]});
                            }
                        }
                        return null;
                    }
                };
                return &Closure.call;
            }

            pub fn range(comptime lower: Bound, comptime upper: Bound) NumberOptions.Validator {
                const Closure = struct {
                    pub fn call(value: T) ?[]const u8 {
                        if (min(lower)(value)) |message| {
                            return message;
                        }
                        if (max(upper)(value)) |message| {
                            return message;
                        }
                        return null;
                    }
                };
                return &Closure.call;
            }
        };

        fn parse(items: []const u8) !T {
            switch (@typeInfo(T)) {
                .Int => {
                    const base: u8 = if (items.len > 2 and items[0] == '0') this: {
                        switch (std.ascii.toLower(items[1])) {
                            'x' => break :this 16,
                            'o' => break :this 8,
                            'b' => break :this 2,
                            else => return std.fmt.ParseIntError.InvalidCharacter,
                        }
                    } else return std.fmt.parseInt(T, items, 10);
                    return std.fmt.parseInt(T, items[2..], base);
                },
                .Float => return std.fmt.parseFloat(T, items),
                else => unreachable,
            }
        }

        pub fn inquire(options: NumberOptions) !T {
            var input = try readInput(T, u8, options);
            defer input.deinit();

            if (input.items.len == 0 and options.default != null) {
                return options.default.?.value;
            }

            return switch (@typeInfo(T)) {
                .Int, .Float => parse(input.items),
                else => unreachable,
            };
        }
    };
}
