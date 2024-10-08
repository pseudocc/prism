const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");
const prompt = @import("../prompt.zig");

const Style = prompt.Style;
const testing = std.testing;

fn prepareQestion(comptime T: type, options: Options(T), t: *prism.Terminal) !void {
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

    const question_style = style.question.fill(options.theme.question);

    if (options.cleanup) {
        try t.unbufferedWrite(prism.cursor.position);
    }

    // "\n + up(1)" will preserve a newline for the error message
    try t.unbufferedPrint("{s}" ** 6, .{
        question_style.before,
        options.question,
        question_style.after,
        "\n",
        prism.cursor.up(1),
        prism.cursor.save,
    });
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

            var found_target: bool = false;
            var count: u16 = switch (direction) {
                .forward => 1,
                .backward => 0,
            };
            while (true) : (count += 1) {
                const if_cond = switch (direction) {
                    .forward => self.cursor + count < items.len,
                    .backward => self.cursor > count,
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

                const match = switch (direction) {
                    .forward => std.ascii.isWhitespace(sentinel),
                    .backward => !std.ascii.isWhitespace(sentinel),
                };
                if (match) {
                    if (found_target) continue;
                    found_target = true;
                } else if (found_target) {
                    break;
                }
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
            if (count == 0) return;

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

        fn u8Input(self: *Self) !std.ArrayList(u8) {
            var result = std.ArrayList(u8).init(std.heap.page_allocator);

            for (self.input.items) |c| {
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buffer) catch unreachable;
                try result.appendSlice(buffer[0..n]);
            }

            return result;
        }

        inline fn validate(self: *Self, options: anytype) !void {
            self.maybe_invalid = switch (T) {
                u8 => options.validate(self.input.items),
                u21 => this: {
                    const input = try self.u8Input();
                    defer input.deinit();
                    break :this options.validate(input.items);
                },
                else => unreachable,
            };
        }

        inline fn confirm(self: *Self, options: anytype) !void {
            try self.validate(options);
            self.confirmed = true;
        }

        inline fn setCursor(self: *Self, cursor: u16) void {
            self.cursor = cursor;
            self.resetVdelay();
        }

        /// Returns true if performed validation
        inline fn decVdelay(self: *Self, options: anytype) !bool {
            if (self.vdelay > 0) {
                self.vdelay -= 1;
                if (self.vdelay == 0) {
                    try self.validate(options);
                    return true;
                }
            }
            return false;
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

test "prism.prompt.input.InputContext(u8)" {
    const allocator = testing.allocator;
    const initial = "Hello, world!";

    var ctx = InputContext(u8){ .input = std.ArrayList(u8).init(allocator) };
    var count: u16 = undefined;
    defer ctx.input.deinit();

    for (initial) |c| {
        try ctx.insert(c);
    }

    try testing.expectEqualStrings(ctx.input.items, initial);
    try testing.expect(ctx.cursor == initial.len);
    try testing.expect(ctx.cursor == ctx.input.items.len);

    count = ctx.move(.backward, false);
    try testing.expect(count == 1);

    ctx.remove(.backward, false);
    try testing.expectEqualStrings(ctx.input.items, "Hello, world");

    ctx.cursor -= ctx.move(.backward, true);
    for ("new ") |c| {
        try ctx.insert(c);
    }
    try testing.expectEqualStrings(ctx.input.items, "Hello, new world");

    ctx.cursor = 0;
    ctx.remove(.forward, true);
    for ("Bye") |c| {
        try ctx.insert(c);
    }
    try testing.expectEqualStrings(ctx.input.items, "Bye, new world");
}

test "prism.prompt.input.InputContext(u21)" {
    const allocator = testing.allocator;

    var ctx = InputContext(u21){ .input = std.ArrayList(u21).init(allocator) };
    defer ctx.input.deinit();

    for ("Hello, ") |c| {
        try ctx.insert(c);
    }
    try ctx.insert(std.unicode.utf8Decode("世") catch unreachable);
    try ctx.insert(std.unicode.utf8Decode("界") catch unreachable);
    try ctx.insert(std.unicode.utf8Decode("🌍") catch unreachable);

    const u8_input = try ctx.u8Input();
    defer u8_input.deinit();
    try testing.expectEqualStrings(u8_input.items, "Hello, 世界🌍");
    try testing.expect(ctx.cursor == ctx.input.items.len);
}

fn readInput(comptime T: type, comptime BufferType: type, options: Options(T)) !std.ArrayList(BufferType) {
    switch (BufferType) {
        u8, u21 => {},
        else => @compileError("unsupported type"),
    }

    prompt.terminal.reader_mutex.lock();
    defer prompt.terminal.reader_mutex.unlock();

    const t = try prompt.terminal.get();
    const r = &prompt.terminal.reader;

    const origin_raw_enabled = t.raw_enabled;
    var real_idle: bool = undefined;
    var first_round: bool = true;
    var origin_cursor: prism.common.Point = undefined;

    try t.enableRaw();
    try r.reset();
    try prepareQestion(T, options, t);

    defer {
        if (!origin_raw_enabled) {
            t.disableRaw() catch {};
        }
        if (options.cleanup) {
            t.print("{s}" ** 2, .{
                prism.cursor.gotoPoint(origin_cursor),
                prism.edit.erase.display(.below),
            }) catch {};
        } else {
            t.write("\r\n") catch {};
        }
        t.write(prism.graphic.attrs(&.{})) catch {};
        t.flush() catch {};
    }

    const default_style = style.default.fill(options.theme.default);
    const invalid_style = style.invalid.fill(options.theme.invalid);

    var ctx = InputContext(BufferType){ .input = std.ArrayList(BufferType).init(std.heap.page_allocator) };
    errdefer ctx.input.deinit();

    while (!ctx.confirmed) {
        const ev = try r.read();
        defer first_round = false;

        if (ev != .idle) real_idle = false;
        switch (ev) {
            .idle => real_idle = !try ctx.decVdelay(options),
            .position => |p| origin_cursor = p,
            .key => |e| {
                switch (e.key) {
                    .code => |c| if (std.ascii.isPrint(c)) {
                        const is_valid = if (T == []const u8) true else this: {
                            const signed = switch (@typeInfo(T)) {
                                .int => |i| i.signedness == .signed,
                                .float => true,
                                else => unreachable,
                            };
                            const is_float = switch (@typeInfo(T)) {
                                .float => true,
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

        if (real_idle and !first_round) continue;

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
                invalid_style.before,
                message,
                invalid_style.after,
            });
            ctx.confirmed = false;
        }

        try t.write(prism.cursor.restore);
        try t.write(prism.edit.erase.line(.right));

        const items = ctx.input.items;
        const cursor = ctx.cursor;
        if (items.len == 0) {
            const writer = t.buffered.writer();
            try writer.writeAll(default_style.before);
            try options.printDefault(writer);
            try writer.print("{s}" ** 2, .{
                default_style.after,
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

const style = struct {
    const p = std.fmt.comptimePrint;
    const g = prism.graphic;
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

pub const Theme = struct {
    question: ?Style.Optional = null,
    default: ?Style.Optional = null,
    invalid: ?Style.Optional = null,
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
            .int => .integer,
            .float => .float,
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

        fn validate(self: Self, string: []const u8) ?[]const u8 {
            if (string.len == 0) {
                // we checked default value before
                if (self.default) |_| return null;
            }
            return self.validateString(string);
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

        fn printDefault(self: Self, writer: anytype) !void {
            const default = self.default orelse return;
            switch (kind) {
                .integer => {
                    switch (default.base) {
                        2 => try writer.writeAll("0b"),
                        8 => try writer.writeAll("0o"),
                        16 => try writer.writeAll("0x"),
                        else => {},
                    }
                    try std.fmt.formatInt(default.value, default.base, .lower, .{}, writer);
                },
                .float => {
                    const format: std.fmt.FormatOptions = .{ .precision = default.precision };
                    switch (default.format) {
                        .decimal => try std.fmt.formatFloatDecimal(default.value, format, writer),
                        .scientific => try std.fmt.formatFloatScientific(default.value, format, writer),
                        .hexadecimal => try std.fmt.formatFloatHexadecimal(default.value, format, writer),
                    }
                },
                .string => try writer.writeAll(default),
            }
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

    pub fn buffered(comptime v: Variant, dest: []u8, options: TextOptions) !usize {
        const bufcopy = prism.common.bufcopy;
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
                .int => {
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
                .float => return std.fmt.parseFloat(T, items),
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
                .int, .float => parse(input.items),
                else => unreachable,
            };
        }
    };
}
