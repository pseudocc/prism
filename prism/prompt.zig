const std = @import("std");
const prism = @import("prism");

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
};

pub const input = @import("prompt/input.zig");

test {
    std.testing.refAllDecls(@This());
}
