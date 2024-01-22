const std = @import("std");
const csi = @import("csi.zig");

pub const cursor = @import("cursor.zig");
pub const edit = @import("edit.zig");
pub const graphic = @import("graphic.zig");

pub const Input = enum {
    const Self = @This();

    insert,
    replace,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const code = switch (self) {
            .insert => csi.ct("[4h"),
            .replace => csi.ct("[4l"),
        };
        try writer.writeAll(code);
    }
};

pub const Wrap = enum {
    const Self = @This();

    enable,
    disable,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const code = switch (self) {
            .enable => csi.ct("[?7h"),
            .disable => csi.ct("[?7l"),
        };
        try writer.writeAll(code);
    }
};

pub const AltScreen = enum {
    const Self = @This();

    enter,
    leave,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const code = switch (self) {
            .enter => csi.ct("[?1049h"),
            .leave => csi.ct("[?1049l"),
        };
        try writer.writeAll(code);
    }
};

pub const Mouse = enum {
    const Self = @This();

    track,
    untrack,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const code = switch (self) {
            .track => csi.ct("[?1003h"),
            .untrack => csi.ct("[?1003l"),
        };
        try writer.writeAll(code);
    }
};

pub const Terminal = struct {
    const os = std.os;
    const sys = os.system;
    const File = std.fs.File;
    const Self = @This();

    pub const Size = struct {
        width: u16,
        height: u16,
    };

    canonical: os.termios,
    raw: os.termios,
    raw_enabled: bool = false,
    file: File,

    pub fn init(file: File) !Terminal {
        const fd = file.handle;
        var canonical = try os.tcgetattr(fd);
        var raw = canonical;

        raw.iflag &= ~(sys.BRKINT | sys.ICRNL | sys.INPCK |
            sys.ISTRIP | sys.IXON);
        raw.oflag &= ~(sys.OPOST);
        raw.cflag |= (sys.CS8);
        raw.lflag &= ~(sys.ECHO | sys.ICANON | sys.IEXTEN | sys.ISIG);

        // blocking read with timeout
        raw.cc[sys.V.MIN] = 0;
        raw.cc[sys.V.TIME] = 1;

        return .{
            .canonical = canonical,
            .raw = raw,
            .file = file,
        };
    }

    pub fn enableRaw(self: *Self) !void {
        if (self.raw_enabled) return;

        try os.tcsetattr(self.file.handle, .FLUSH, self.raw);
        self.raw_enabled = true;
    }

    pub fn disableRaw(self: *Self) !void {
        if (!self.raw_enabled) return;

        try os.tcsetattr(self.file.handle, .FLUSH, self.canonical);
        self.raw_enabled = false;
    }

    pub fn size(self: *Self) !Size {
        var sz: sys.winsize = undefined;
        const fd = self.file.handle;
        const code = sys.ioctl(fd, sys.T.IOCGWINSZ, @intFromPtr(&sz));
        if (code != 0) {
            return error.IOCTL;
        }
        return .{
            .width = sz.ws_col,
            .height = sz.ws_row,
        };
    }

    pub const Event = union(enum) {
        key: KeyEvent,
        unicode: u21,
        /// Only sent when mouse tracking is enabled.
        mouse: MouseEvent,
        unknown: []const u8,
        idle: void,
    };

    pub const KeyEvent = struct {
        key: Key,
        modifiers: Modifiers,

        fn byte(code: u8) KeyEvent {
            var key_event: KeyEvent = .{
                .key = undefined,
                .modifiers = .{},
            };

            if (std.ascii.isPrint(code)) {
                key_event.key = .{ .code = code };
                key_event.modifiers.shift = std.ascii.isUpper(code);
            } else if (std.ascii.isControl(code)) {
                // ctrl + backspace => bs
                // backspace => del
                if (code == cc.bs) {
                    key_event.key = .{ .code = cc.del };
                    key_event.modifiers.ctrl = true;
                } else {
                    key_event.key = .{ .code = code };
                }
            } else {
                key_event.key = .{ .non_ascii = code };
            }

            return key_event;
        }

        fn bytes(data: []const u8) !KeyEvent {
            var key_event: KeyEvent = undefined;
            // the first byte is always esc and length is at least 2
            if (data.len == 2) {
                key_event = byte(data[1]);
                key_event.modifiers.alt = true;
            } else {
                key_event = .{
                    .key = try Keys.parse(data),
                    .modifiers = .{},
                };
            }
            return key_event;
        }
    };

    const cc = std.ascii.control_code;

    /// Shorthand for common keys.
    /// Example: CTRL + M = Keys.enter
    pub const Keys = struct {
        const left: Key = .{ .esc_seq = .left };
        const right: Key = .{ .esc_seq = .right };
        const up: Key = .{ .esc_seq = .up };
        const down: Key = .{ .esc_seq = .down };
        const home: Key = .{ .esc_seq = .home };
        const end: Key = .{ .esc_seq = .end };
        const page_up: Key = .{ .esc_seq = .page_up };
        const page_down: Key = .{ .esc_seq = .page_down };
        const insert: Key = .{ .esc_seq = .insert };
        const delete: Key = .{ .esc_seq = .delete };
        const backtab: Key = .{ .esc_seq = .backtab };

        const backspace: Key = .{ .code = cc.del };
        const enter: Key = ctrl('m');
        const tab: Key = ctrl('i');

        /// Shorthand for CTRL + key
        pub fn ctrl(comptime code: u8) Key {
            if (!std.ascii.isAlphabetic(code)) {
                @compileError("alpha required");
            }
            // this works for both upper and lower case
            return .{ .code = code & 0x1f };
        }

        fn csiseq(comptime value: anytype) []const u8 {
            const seq = std.fmt.comptimePrint("{s}", .{value});
            return seq;
        }

        fn parse(data: []const u8) !Key {
            // TODO: handle more keys and use branches
            const pairs = .{
                .{ csiseq(cursor.left(1)), left },
                .{ csiseq(cursor.right(1)), right },
                .{ csiseq(cursor.up(1)), up },
                .{ csiseq(cursor.down(1)), down },
                .{ csiseq(cursor.goto(1, 1)), home },
                .{ csiseq(cursor.prev(1)), end },
                .{ csiseq(csi.ct("[2~")), insert },
                .{ csiseq(csi.ct("[3~")), delete },
                .{ csiseq(csi.ct("[5~")), page_up },
                .{ csiseq(csi.ct("[6~")), page_down },
                .{ csiseq(csi.ct("[Z")), backtab },
            };

            inline for (pairs) |pair| {
                if (std.mem.eql(u8, data, pair[0])) {
                    return pair[1];
                }
            }

            return error.KeyNotFound;
        }
    };

    pub const Key = union(enum) {
        esc_seq: enum {
            left,
            right,
            up,
            down,
            home,
            end,
            insert,
            delete,
            page_up,
            page_down,
            backtab,
        },

        f: u8,
        code: u8,
        non_ascii: u8,
        null: void,
    };

    pub const Modifiers = struct {
        shift: bool = false,
        alt: bool = false,
        ctrl: bool = false,
    };

    pub const MouseEvent = struct {
        pub const Button = union(enum) {
            left: void,
            middle: void,
            right: void,
            extra: u8,
        };

        pub const Wheel = enum {
            up,
            down,
            left,
            right,
        };

        pub const State = union(enum) {
            /// Mouse button was pressed.
            click: Button,
            /// Mouse wheel was scrolled.
            wheel: Wheel,
            /// Mouse button was released.
            /// Cannot determine which button was released.
            release: void,
        };

        button: State,
        x: u16,
        y: u16,
        move: bool,
        modifiers: Modifiers,

        fn parse(data: []const u8) !MouseEvent {
            const csi_prefix = csi.ct("[M");
            var mouse_event: MouseEvent = undefined;

            if (data.len != 6 or !std.mem.startsWith(u8, data, csi_prefix)) {
                return error.InvalidMouseEvent;
            }

            const button = data[csi_prefix.len] - 32;
            const x = data[csi_prefix.len + 1] - 32;
            const y = data[csi_prefix.len + 2] - 32;

            // TODO: remove debug code
            std.debug.print("code: {d}\tx: {d}\ty: {d}\r\n", .{ button, x, y });
            mouse_event.x = x;
            mouse_event.y = y;
            mouse_event.move = (button & 32) != 0;
            mouse_event.modifiers = .{
                .shift = (button & 4) != 0,
                .alt = (button & 8) != 0,
                .ctrl = (button & 16) != 0,
            };

            mouse_event.button = this: {
                const two_bits = button & 3;
                if (button & 64 != 0) {
                    break :this switch (two_bits) {
                        0 => .{ .wheel = .up },
                        1 => .{ .wheel = .down },
                        2 => .{ .wheel = .left },
                        3 => .{ .wheel = .right },
                        else => unreachable,
                    };
                } else if (button & 128 != 0) {
                    break :this .{ .click = .{ .extra = two_bits } };
                }
                break :this switch (two_bits) {
                    0 => .{ .click = .left },
                    1 => .{ .click = .middle },
                    2 => .{ .click = .right },
                    3 => .release,
                    else => unreachable,
                };
            };

            std.debug.print("mouse event: {any}\r\n", .{mouse_event});
            return mouse_event;
        }
    };

    pub const EventReader = struct {
        const BUFFER_SIZE = 4096;

        file: File,
        buffer: [BUFFER_SIZE]u8 = undefined,
        offset: usize = 0,

        pub fn read(self: *EventReader) !Event {
            var event: Event = undefined;
            var processed: usize = undefined;

            processed = process(self.buffer[0..self.offset], &event);
            if (processed != 0) {
                const unused = self.offset - processed;
                if (unused != 0) {
                    const unused_buffer = self.buffer[processed..self.offset];
                    std.mem.copyForwards(u8, &self.buffer, unused_buffer);
                }
                self.offset = unused;
                return event;
            }

            const bytes_read = try self.file.read(self.buffer[self.offset..]);
            if (bytes_read == 0) {
                return .idle;
            }

            self.offset += bytes_read;
            var writer = std.io.getStdOut().writer();
            for (self.buffer[0..self.offset]) |byte| {
                if (std.ascii.isPrint(byte)) {
                    std.fmt.format(writer, "{c}", .{byte}) catch unreachable;
                } else {
                    const g = graphic;
                    const grey = g.attrs(&.{g.fg(.{ .ansi256 = 8 })});
                    const reset = g.attrs(&.{});
                    std.fmt.format(writer, "{s}\\x{x}{s}", .{ grey, byte, reset }) catch unreachable;
                }
            }
            std.fmt.format(writer, "\r\n", .{}) catch unreachable;

            return try self.read();
        }

        const QMARK = std.unicode.utf8Decode("�") catch unreachable;
        fn process(data: []const u8, event: *Event) usize {
            var processed: usize = undefined;
            var end: usize = undefined;

            if (data.len == 0) {
                return 0;
            }

            processed = std.unicode.utf8ByteSequenceLength(data[0]) catch return 1;
            if (processed != 1) {
                const cp = std.unicode.utf8Decode(data[0..processed]) catch QMARK;
                event.* = .{ .unicode = cp };
                return @intCast(processed);
            }

            if (data[0] == cc.esc and data.len > 1) {
                const search_start: usize = if (data[1] == cc.esc) 2 else 1;
                end = std.mem.indexOfPos(u8, data, search_start, &.{cc.esc}) orelse data.len;

                var mouse_event: MouseEvent = undefined;
                processed = process_mouse(data[0..end], &mouse_event);

                if (processed != 0) {
                    event.* = .{ .mouse = mouse_event };
                    return processed;
                }
            } else {
                end = 1;
            }

            var key_event: KeyEvent = undefined;
            processed = process_key(data[0..end], &key_event);
            event.* = .{ .key = key_event };

            // mouse event workaround
            if (end != processed and data[0] == cc.esc) {
                processed = end;
                event.* = .{ .unknown = data[0..end] };
            }

            return processed;
        }

        fn process_mouse(data: []const u8, event: *MouseEvent) usize {
            event.* = MouseEvent.parse(data) catch return 0;

            return data.len;
        }

        fn process_key(data: []const u8, event: *KeyEvent) usize {
            switch (data.len) {
                0 => return 0,
                1 => {
                    event.* = KeyEvent.byte(data[0]);
                    return 1;
                },
                else => {
                    var processed = data.len;
                    event.* = KeyEvent.bytes(data) catch this: {
                        processed = 1;
                        break :this KeyEvent.byte(data[0]);
                    };
                    return processed;
                },
            }
        }
    };
};

fn test_terminal() !void {
    const file = std.io.getStdIn();
    var writer = file.writer();
    var term = try Terminal.init(file);
    try term.enableRaw();
    try std.fmt.format(writer, "{s}", .{altscreen.enter});
    try std.fmt.format(writer, "{s}", .{mouse.track});

    std.testing.log_level = .debug;
    defer term.disableRaw() catch {};
    defer std.fmt.format(writer, "{s}", .{altscreen.leave}) catch {};
    defer std.fmt.format(writer, "{s}", .{mouse.untrack}) catch {};

    var reader = Terminal.EventReader{ .file = file };
    var command_mode = false;
    while (true) {
        const event = try reader.read();
        switch (event) {
            .key => |e| {
                if (e.key != .code) {
                    command_mode = false;
                    continue;
                }
                switch (e.key.code) {
                    ':' => {
                        command_mode = true;
                        continue;
                    },
                    'c' => {
                        if (command_mode) {
                            try std.fmt.format(writer, "{s}{s}", .{
                                edit.erase.display(.both),
                                cursor.goto(1, 1),
                            });
                            command_mode = false;
                        }
                    },
                    'q' => {
                        if (command_mode) {
                            break;
                        }
                    },
                    else => {
                        command_mode = false;
                    },
                }
            },
            else => {},
        }
    }
}

test "terminal" {
    try test_terminal();
}

/// Insert/Replace Mode (IRM)
/// Default: replace.
pub const input = struct {
    pub const insert: Input = .insert;
    pub const replace: Input = .replace;
};

/// Autowrap Mode (DECAWM)
/// Default: no autowrap.
pub const wrap = struct {
    pub const enable: Wrap = .enable;
    pub const disable: Wrap = .disable;
};

/// Alternate Screen Buffer (ALTBUF) With Cursor Save and Clear on Enter
/// Default: primary screen buffer.
pub const altscreen = struct {
    pub const enter: AltScreen = .enter;
    pub const leave: AltScreen = .leave;
};

/// Mouse Down+Up Tracking (?1000)
pub const mouse = struct {
    pub const track: Mouse = .track;
    pub const untrack: Mouse = .untrack;
};
