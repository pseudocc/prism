const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");
const prompt = @import("../prompt.zig");

const Style = prompt.Style;

fn preparePrompt(options: Options, t: *prism.Terminal) !void {
    const prompt_style = style.prompt.fill(options.theme.prompt);

    if (options.cleanup) {
        try t.unbufferedWrite(prism.cursor.reqpos);
    }

    // "\n + up(1)" will preserve a newline for the error message
    try t.unbufferedPrint("{s}" ** 6, .{
        prompt_style.before,
        options.prompt,
        prompt_style.after,
        "\n",
        prism.cursor.up(1),
        prism.cursor.save,
    });
}

pub const Theme = struct {
    prompt: ?Style.Optional = null,
    invalid: ?Style.Optional = null,
};

const style = struct {
    const p = std.fmt.comptimePrint;
    const attrs = prism.graphic.attrs;
    const fg = prism.graphic.fg;

    const prompt: Style = .{
        .before = p("{s}? {s}", .{
            attrs(&.{fg(.{ .ansi = .yellow })}),
            attrs(&.{}),
        }),
        .after = ": ",
    };

    const invalid: Style = .{
        .before = p("{s}! {s}", .{
            attrs(&.{fg(.{ .ansi = .red })}),
            attrs(&.{}),
        }),
        .after = "",
    };
};

pub const Options = struct {
    pub const Validator = *const fn ([]const u8) ?[]const u8;
    prompt: []const u8,
    mask: u8 = '*',
    cleanup: bool = false,
    validator: ?Validator = null,

    theme: Theme = .{},
};

const InputContext = struct {
    const VDELAY = 5;
    const Self = @This();
    const Direction = enum {
        forward,
        backward,
    };

    vdelay: usize = VDELAY,
    cursor: u16 = 0,
    confirmed: bool = false,
    maybe_invalid: ?[]const u8 = null,
    input: std.ArrayList(u8),

    inline fn insert(self: *Self, c: u8) !void {
        try self.input.insert(self.cursor, c);
        self.setCursor(self.cursor + 1);
    }

    inline fn removeRange(self: *Self, start: u16, count: u16) void {
        // remove items won't fail
        self.input.replaceRange(start, count, &.{}) catch unreachable;
    }

    inline fn remove(self: *Self, comptime direction: Direction, all: bool) void {
        const right: u16 = @intCast(self.input.items.len - self.cursor);
        const count: u16 = switch (direction) {
            .forward => if (all) right else @min(right, 1),
            .backward => if (all) self.cursor else @min(self.cursor, 1),
        };
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

    inline fn setCursor(self: *Self, cursor: u16) void {
        self.cursor = cursor;
        self.resetVdelay();
    }

    inline fn validate(self: *Self, options: Options) void {
        self.maybe_invalid = if (options.validator) |validator| validator(self.input.items) else null;
    }

    inline fn confirm(self: *Self, options: anytype) void {
        self.validate(options);
        self.confirmed = true;
    }

    /// Returns true if performed validation
    inline fn decVdelay(self: *Self, options: Options) !bool {
        if (self.vdelay > 0) {
            self.vdelay -= 1;
            if (self.vdelay == 0) {
                self.validate(options);
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

pub fn buffered(dest: []u8, options: Options) !usize {
    const allocator = std.heap.page_allocator;
    var input = try allocated(allocator, options);
    defer allocator.free(input);
    return prism.common.bufcopy(dest, input);
}

pub fn allocated(allocator: Allocator, options: Options) ![]const u8 {
    prompt.terminal.reader_mutex.lock();
    defer prompt.terminal.reader_mutex.unlock();

    const t = try prompt.terminal.get();
    const r = &prompt.terminal.reader;

    const origin_raw_enabled = t.raw_enabled;
    var real_idle: bool = undefined;
    var origin_cursor: prism.common.Point = undefined;

    const ESC_HELD = 8;
    var esc_held: u8 = 0;

    try t.enableRaw();
    try r.reset();
    try preparePrompt(options, t);

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

    const invalid_style = style.invalid.fill(options.theme.invalid);

    var ctx = InputContext{ .input = std.ArrayList(u8).init(allocator) };
    errdefer ctx.input.deinit();

    while (!ctx.confirmed) {
        const ev = try r.read();
        const max_len: u16 = @intCast(ctx.input.items.len);

        const last_esc_held = esc_held != 0;
        esc_held -= if (last_esc_held) 1 else 0;

        if (ev != .idle) real_idle = false;
        switch (ev) {
            .idle => real_idle = !try ctx.decVdelay(options),
            .position => |p| origin_cursor = p,
            .key => |e| {
                switch (e.key) {
                    .code => |c| if (std.ascii.isPrint(c)) {
                        esc_held = 0;
                        try ctx.insert(c);
                    } else if (std.ascii.isControl(c)) {
                        switch (c) {
                            std.ascii.control_code.etx => return error.Interrupted,
                            std.ascii.control_code.eot => return error.Aborted,
                            std.ascii.control_code.esc => {
                                real_idle = !try ctx.decVdelay(options);
                                // need a longer delay before repeated ESC key strokes
                                esc_held = if (last_esc_held) 2 else ESC_HELD;
                            },
                            else => {},
                        }
                    },
                    .home => ctx.cursor = 0,
                    .left => ctx.cursor = if (e.modifiers.ctrl) 0 else @max(ctx.cursor, 1) - 1,
                    .end => ctx.cursor = @intCast(max_len),
                    .right => ctx.cursor = if (e.modifiers.ctrl) max_len else @min(ctx.cursor + 1, max_len),
                    .delete => ctx.remove(.forward, e.modifiers.ctrl),
                    .backspace => ctx.remove(.backward, e.modifiers.ctrl),
                    .enter => ctx.confirm(options),
                    else => {},
                }
            },
            else => {},
        }

        const esc_held_changed = esc_held == ESC_HELD or esc_held == 0;
        if (real_idle and !esc_held_changed) continue;

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
        if (items.len > 0) {
            var cursor_restore = false;
            if (esc_held > 0) {
                for (items) |c| {
                    try t.write(c);
                }
                cursor_restore = true;
            } else if (std.ascii.isPrint(options.mask)) {
                for (0..items.len) |_| {
                    try t.write(options.mask);
                }
                cursor_restore = true;
            }
            if (cursor_restore) {
                try t.print("{s}" ** 2, .{
                    prism.cursor.restore,
                    prism.cursor.right(cursor),
                });
            }
        }

        try t.flush();
    }

    return ctx.input.toOwnedSlice();
}
