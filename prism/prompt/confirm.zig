const std = @import("std");
const Allocator = std.mem.Allocator;
const prism = @import("prism");
const prompt = @import("../prompt.zig");

const Style = prompt.Style;
const testing = std.testing;

pub const Theme = struct {
    question: ?Style.Optional = null,
    answer: ?Style.Optional = null,
};

const style = struct {
    const p = std.fmt.comptimePrint;
    const attrs = prism.graphic.attrs;
    const fg = prism.graphic.fg;

    const question: Style = .{
        .before = p("{s}& {s}", .{
            attrs(&.{fg(.{ .ansi = .magenta })}),
            attrs(&.{}),
        }),
        .after = "? ",
    };

    const answer: Style = .{
        .before = "",
        .after = "",
    };
};

pub const Options = struct {
    const Self = @This();

    question: []const u8,
    default: ?bool = null,
    cleanup: bool = false,

    theme: Theme = .{},

    fn prepare(self: Self, t: *prism.Terminal) !void {
        try t.enableRaw();
        const question_style = style.question.fill(self.theme.question);

        if (self.cleanup) {
            try t.unbufferedWrite(prism.cursor.position);
        }

        try t.print("{s}" ** 4, .{
            question_style.before,
            self.question,
            question_style.after,
            prism.cursor.save,
        });

        const answer_style = style.answer.fill(self.theme.answer);
        try t.write(answer_style.before);
        try t.print("{s}/{s}", .{
            if (self.default == true) "Y" else "y",
            if (self.default == false) "N" else "n",
        });
        try t.write(answer_style.after);
    }
};

pub fn decide(options: Options) !bool {
    var tctx = try prompt.terminal.Context.acquire();
    defer tctx.destroy(options.cleanup);

    const t = tctx.terminal;
    const r = tctx.reader;

    var real_idle: bool = undefined;
    var first_render: bool = true;
    var maybe_decision: ?bool = options.default;
    try options.prepare(t);

    while (true) {
        const ev = try r.read();
        real_idle = true;

        switch (ev) {
            .position => |p| tctx.old_state.cursor = p,
            .key => |e| switch (e.key) {
                .code => |c| switch (c) {
                    'y', 'Y' => {
                        maybe_decision = true;
                        real_idle = false;
                    },
                    'n', 'N' => {
                        maybe_decision = false;
                        real_idle = false;
                    },
                    std.ascii.control_code.esc => {
                        maybe_decision = options.default;
                        real_idle = false;
                    },
                    std.ascii.control_code.etx => return error.Interrupted,
                    std.ascii.control_code.eot => return error.Aborted,
                    else => {},
                },
                .enter => if (maybe_decision != null) break,
                else => {},
            },
            else => {},
        }

        if (real_idle and !first_render) continue;
        first_render = false;

        if (maybe_decision) |decision| {
            try t.print("{s}" ** 2, .{
                prism.cursor.restore,
                prism.cursor.show,
            });
            if (!decision) {
                try t.write(prism.cursor.right(2));
            }
        } else {
            try t.write(prism.cursor.hide);
        }
        try t.flush();
    }

    const decision = maybe_decision.?;
    const answer_style = style.answer.fill(options.theme.answer);
    if (!options.cleanup) {
        try t.unbufferedPrint("{s}" ** 5, .{
            prism.cursor.restore,
            prism.edit.erase.line(.right),
            answer_style.before,
            if (decision) "Yes" else "No",
            answer_style.after,
        });
    }

    return decision;
}
