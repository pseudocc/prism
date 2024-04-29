const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");
const prompt = @import("../prompt.zig");

const Style = prompt.Style;
const testing = std.testing;

pub const Theme = struct {
    question: ?Style.Optional = null,
    choice_title: ?Style.Optional = null,
    choice_tip: ?Style.Optional = null,
    choice_tip_indent: ?[]const u8 = null,
    selected: ?[]const u8 = null,
    unselected: ?[]const u8 = null,
};

const style = struct {
    const p = std.fmt.comptimePrint;
    const attrs = prism.graphic.attrs;
    const fg = prism.graphic.fg;

    const question: Style = .{
        .before = p("{s}* {s}", .{
            attrs(&.{fg(.{ .ansi = .blue })}),
            attrs(&.{}),
        }),
        .after = "? ",
    };

    const choice_title: Style = .{
        .before = "",
        .after = "",
    };

    const choice_tip: Style = .{
        .before = p("{s}", .{attrs(&.{fg(.{ .ansi = .bright_black })})}),
        .after = p("{s}", .{attrs(&.{})}),
    };

    const choice_tip_indent_char = " ";
    const choice_tip_indent_count = 2;
    const choice_tip_indent = choice_tip_indent_char ** choice_tip_indent_count;

    const selected = p("{s}■ {s}", .{
        attrs(&.{fg(.{ .ansi = .green })}),
        attrs(&.{}),
    });

    const unselected = p("{s}□ {s}", .{
        attrs(&.{fg(.{ .ansi = .bright_black })}),
        attrs(&.{}),
    });
};

const stderr = std.io.getStdErr().writer();

const InputContext = struct {
    const Self = @This();

    cursor: usize,
    anchors: []u16,

    selected: []const u8,
    unselected: []const u8,

    inline fn up(self: *Self) bool {
        if (self.cursor > 0) {
            self.cursor -= 1;
            return true;
        }
        return false;
    }

    inline fn down(self: *Self) bool {
        if (self.cursor < self.anchors.len - 1) {
            self.cursor += 1;
            return true;
        }
        return false;
    }

    inline fn first(self: *Self) bool {
        if (self.cursor > 0) {
            self.cursor = 0;
            return true;
        }
        return false;
    }

    inline fn last(self: *Self) bool {
        if (self.cursor < self.anchors.len - 1) {
            self.cursor = self.anchors.len - 1;
            return true;
        }
        return false;
    }

    fn redraw(self: Self, t: *prism.Terminal) !void {
        for (self.anchors, 0..) |anchor, i| {
            const state = if (i == self.cursor) self.selected else self.unselected;
            try t.print("{s}" ** 3, .{
                prism.cursor.restore,
                prism.cursor.next(anchor),
                state,
            });
        }
        const active = self.anchors[self.cursor];
        try t.print("{s}" ** 2, .{
            prism.cursor.restore,
            prism.cursor.next(active),
        });
        try t.flush();
    }
};

pub fn Options(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Choice = struct {
            title: []const u8,
            tip: ?[]const u8 = null,
            selected: bool = false,
            value: T,
        };

        question: []const u8,
        choices: []const Choice,
        cleanup: bool = false,

        theme: Theme = .{},

        fn sanity(self: Self) !void {
            var seen_selected = false;
            if (self.choices.len == 0)
                return error.NoChoices;
            for (self.choices) |choice| {
                if (choice.title.len == 0)
                    return error.EmptyChoiceTitle;
                if (choice.selected) {
                    if (seen_selected)
                        return error.MultipleSelectedChoices;
                    seen_selected = true;
                }
            }
        }

        fn prepare(self: Self, t: *prism.Terminal) !InputContext {
            const allocator = std.heap.page_allocator;

            try self.sanity();
            try t.enableRaw();

            const question_style = style.question.fill(self.theme.question);
            const title_style = style.choice_title.fill(self.theme.choice_title);
            const tip_style = style.choice_tip.fill(self.theme.choice_tip);
            const choice_tip_indent = self.theme.choice_tip_indent orelse style.choice_tip_indent;
            const selected = self.theme.selected orelse style.selected;
            const unselected = self.theme.unselected orelse style.unselected;

            try t.unbufferedPrint("{s}" ** 5, .{
                question_style.before,
                self.question,
                question_style.after,
                prism.cursor.save,
                "\r\n",
            });

            var ctx: InputContext = .{
                .cursor = 0,
                .anchors = try allocator.alloc(u16, self.choices.len),
                .selected = selected,
                .unselected = unselected,
            };

            var anchor_offset: u16 = 1;
            for (self.choices, 0..) |choice, i| {
                if (choice.selected)
                    ctx.cursor = i;

                ctx.anchors[i] = anchor_offset;
                try t.print("{s}" ** 5, .{
                    if (choice.selected) selected else unselected,
                    title_style.before,
                    choice.title,
                    title_style.after,
                    "\r\n",
                });
                anchor_offset += 1;

                if (choice.tip) |tip| {
                    try t.write(tip_style.before);
                    var iter = std.mem.splitSequence(u8, tip, "\n");
                    while (iter.next()) |line| {
                        try t.print("{s}{s}\r\n", .{ choice_tip_indent, line });
                        anchor_offset += 1;
                    }
                    try t.write(tip_style.after);
                }
            }

            return ctx;
        }
    };
}

pub fn choose(comptime T: type, options: Options(T)) !T {
    var tctx = try prompt.terminal.Context.acquire();
    defer tctx.destroy(options.cleanup);

    const t = tctx.terminal;
    const r = tctx.reader;

    var real_idle: bool = undefined;
    var first_render: bool = true;

    if (options.cleanup) {
        try t.unbufferedWrite(prism.cursor.position);
    }

    var ctx = try options.prepare(t);

    while (true) {
        const ev = try r.read();
        real_idle = true;

        switch (ev) {
            .position => |p| tctx.old_state.cursor = p,
            .key => |e| switch (e.key) {
                .code => |c| switch (c) {
                    'j', 'J' => real_idle = !ctx.down(),
                    'k', 'K' => real_idle = !ctx.up(),
                    std.ascii.control_code.etx => return error.Interrupted,
                    std.ascii.control_code.eot => return error.Aborted,
                    else => {},
                },
                .up => real_idle = !ctx.up(),
                .down => real_idle = !ctx.down(),
                .home => real_idle = !ctx.first(),
                .end => real_idle = !ctx.last(),
                .enter => break,
                else => {},
            },
            else => {},
        }

        if (real_idle and !first_render) continue;

        first_render = false;
        try ctx.redraw(t);
    }

    const choice = options.choices[ctx.cursor];
    if (!options.cleanup) {
        const title_style = style.choice_title.fill(options.theme.choice_title);
        try t.unbufferedPrint("{s}" ** 5, .{
            prism.cursor.restore,
            prism.edit.erase.display(.below),
            title_style.before,
            choice.title,
            title_style.after,
        });
    }

    return choice.value;
}
