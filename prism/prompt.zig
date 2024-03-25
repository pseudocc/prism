const std = @import("std");
const prism = @import("prism");

pub const Style = struct {
    const Self = @This();
    pub const Optional = prism.common.Optional(Self);

    before: []const u8,
    after: []const u8,

    pub fn fill(self: Self, maybe_other: ?Optional) Self {
        if (maybe_other == null) {
            return self;
        }
        var result = self;
        var other = maybe_other.?;
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

test {
    std.testing.refAllDecls(@This());
}
