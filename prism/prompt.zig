const std = @import("std");
const prism = @import("prism");

pub const terminal = struct {
    const stdout = std.io.getStdOut();

    var maybe_instance: ?prism.Terminal = null;
    pub var reader = prism.Terminal.EventReader{ .file = stdout };
    pub var reader_mutex = std.Thread.Mutex{};

    pub fn get() !prism.Terminal {
        if (maybe_instance) |instance| {
            return instance;
        }
        maybe_instance = try prism.Terminal.init(stdout);
        return maybe_instance.?;
    }
};

pub const input = @import("prompt/input.zig");
