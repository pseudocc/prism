const std = @import("std");
const prism = @import("prism");

pub const Style = struct {
    const Self = @This();
    pub const Optional = prism.common.Optional(Self);

    before: []const u8,
    after: []const u8,

    pub fn fill(self: Self, maybe_other: ?Optional) Self {
        const other = maybe_other orelse return self;
        var result = self;
        if (other.before) |before| {
            result.before = before;
        }
        if (other.after) |after| {
            result.after = after;
        }
        return result;
    }
};

pub const terminal = struct {
    const stdout = std.io.getStdOut();

    var instance: prism.Terminal = undefined;
    var inited = false;

    pub var reader = prism.Terminal.EventReader{ .file = stdout };
    pub var reader_mutex = std.Thread.Mutex{};

    pub const Context = struct {
        const Self = @This();

        terminal: *prism.Terminal,
        reader: *prism.Terminal.EventReader,
        old_state: struct {
            cursor: prism.common.Point = undefined,
            raw_enabled: bool,
        },

        pub fn acquire() !Self {
            reader_mutex.lock();
            const term = try get();
            const raw_enabled = term.raw_enabled;
            try term.enableRaw();
            return .{
                .terminal = term,
                .reader = &reader,
                .old_state = .{ .raw_enabled = raw_enabled },
            };
        }

        pub fn destroy(self: *Self, cleanup: bool) void {
            reader_mutex.unlock();
            if (!self.old_state.raw_enabled) {
                self.terminal.disableRaw() catch {};
            }
            if (cleanup) {
                self.terminal.print("{s}" ** 2, .{
                    prism.cursor.gotoPoint(self.old_state.cursor),
                    prism.edit.erase.display(.below),
                }) catch {};
            } else {
                self.terminal.write("\r\n") catch {};
            }
            self.terminal.write(prism.graphic.attrs(&.{})) catch {};
            self.terminal.flush() catch {};
        }
    };

    pub fn get() !*prism.Terminal {
        if (inited) {
            return &instance;
        }
        inited = true;
        instance = try prism.Terminal.init(stdout);
        return &instance;
    }

    pub inline fn enableRaw() !void {
        var term = try get();
        if (term.raw_enabled) {
            return error.Unsupported;
        }
        try term.enableRaw();
    }

    pub inline fn disableRaw() !void {
        var term = try get();
        if (!term.raw_enabled) {
            return error.Unsupported;
        }
        try term.disableRaw();
    }
};

pub const input = @import("prompt/input.zig");
pub const password = @import("prompt/password.zig");
pub const confirm = @import("prompt/confirm.zig");
pub const select = @import("prompt/select.zig");

test {
    std.testing.refAllDecls(@This());
}
