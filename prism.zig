const std = @import("std");
const csi = @import("prism.csi");

pub const common = @import("prism.common");
pub const cursor = @import("prism.cursor");
pub const edit = @import("prism.edit");
pub const graphic = @import("prism.graphic");

const cc = std.ascii.control_code;
const QMARK = std.unicode.utf8Decode("�") catch unreachable;

fn putc(writer: anytype, c: u8) !void {
    const g = graphic;
    const grey = g.attrs(&.{g.fg(.{ .ansi256 = 8 })});
    const reset = g.attrs(&.{});
    if (std.ascii.isPrint(c)) {
        try std.fmt.format(writer, "{c}", .{c});
    } else {
        try std.fmt.format(writer, "{s}\\x{x}{s}", .{ grey, c, reset });
    }
}

fn puts(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        try putc(writer, c);
    }
}

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
    const BufferedWriter = std.io.BufferedWriter(4096, File.Writer);

    canonical: os.termios,
    raw: os.termios,
    raw_enabled: bool = false,
    file: File,

    buffered: BufferedWriter,

    pub fn init(file: File) !Terminal {
        const fd = file.handle;
        const canonical = try os.tcgetattr(fd);
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
            .buffered = .{ .unbuffered_writer = file.writer() },
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

    pub fn size(self: *Self) !common.Size {
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

    pub inline fn unbufferedWrite(self: *Self, data: anytype) !void {
        const writer = self.file.writer();
        try writer.print("{s}", .{data});
    }

    pub inline fn unbufferedPrint(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const writer = self.file.writer();
        try writer.print(fmt, args);
    }

    pub inline fn write(self: *Self, data: anytype) !void {
        const writer = self.buffered.writer();
        try writer.print("{s}", .{data});
    }

    pub inline fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const writer = self.buffered.writer();
        try writer.print(fmt, args);
    }

    pub inline fn flush(self: *Self) !void {
        try self.buffered.flush();
    }

    pub const Event = union(enum) {
        /// Key event.
        key: KeyEvent,
        /// Unicode code point.
        unicode: u21,
        /// Mouse event.
        /// Only sent when mouse tracking is enabled.
        mouse: MouseEvent,
        /// Cursor position
        position: common.Point,
        /// Unknown event, value is not allcated.
        /// If you need to store the value, make a copy.
        unknown: []const u8,
        /// Non blocking read returned 0 bytes.
        idle: void,

        pub fn format(
            self: Event,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.writeAll("Event::");
            switch (self) {
                .key => try std.fmt.format(writer, "Key: {s}", .{self.key}),
                .unicode => {
                    var buffer: [4]u8 = undefined;
                    const l = std.unicode.utf8Encode(self.unicode, &buffer) catch unreachable;
                    try std.fmt.format(writer, "Unicode: {s}", .{buffer[0..l]});
                },
                .mouse => try std.fmt.format(writer, "Mouse::{s}", .{self.mouse}),
                .position => try std.fmt.format(
                    writer,
                    "Position: ({d}, {d})",
                    .{ self.position.x, self.position.y },
                ),
                .unknown => |data| {
                    try writer.writeAll("Unknown: ");
                    try puts(writer, data);
                },
                .idle => try writer.writeAll("Idle"),
            }
        }
    };

    pub const KeyEvent = struct {
        key: Key,
        modifiers: Modifiers,

        pub fn format(
            self: KeyEvent,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            if (self.modifiers.ctrl) {
                try writer.writeAll("CTRL + ");
            }
            if (self.modifiers.alt) {
                try writer.writeAll("ALT + ");
            }
            if (self.modifiers.shift) {
                try writer.writeAll("SHIFT + ");
            }
            try std.fmt.format(writer, "{s}", .{self.key});
        }

        fn byte(code: u8) KeyEvent {
            var key_event: KeyEvent = .{
                .key = undefined,
                .modifiers = .{},
            };

            if (std.ascii.isPrint(code)) {
                key_event.key = .{ .code = code };
                key_event.modifiers.shift = std.ascii.isUpper(code);
            } else if (std.ascii.isControl(code)) {
                switch (code) {
                    cc.bs => {
                        key_event.key = .backspace;
                        key_event.modifiers.ctrl = true;
                    },
                    cc.del => key_event.key = .backspace,
                    cc.cr => key_event.key = .enter,
                    cc.ht => key_event.key = .tab,
                    else => key_event.key = .{ .code = code },
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
                key_event.modifiers = .{};
                switch (data[1]) {
                    'O' => {
                        // F1-F4 without modifiers
                        key_event.key = .{ .f = data[2] - 'O' };
                    },
                    '[' => {
                        const code = data[data.len - 1];
                        const end = if (std.mem.indexOfPos(u8, data, 2, ";")) |i| semi: {
                            const mod = data[i + 1] - '1';
                            key_event.modifiers.shift = (mod & 1) != 0;
                            key_event.modifiers.alt = (mod & 2) != 0;
                            key_event.modifiers.ctrl = (mod & 4) != 0;
                            break :semi i;
                        } else data.len - 1;

                        key_event.key = switch (code) {
                            'A' => .up,
                            'B' => .down,
                            'C' => .right,
                            'D' => .left,
                            'H' => .home,
                            'F' => .end,
                            'Z' => .backtab,
                            'P' => .{ .f = 1 },
                            'Q' => .{ .f = 2 },
                            'S' => .{ .f = 4 },
                            'u' => this: {
                                const kind = try std.fmt.parseInt(u8, data[2..end], 10);
                                break :this switch (kind) {
                                    127 => .backspace,
                                    else => .{ .unhandled = .{ .u = kind } },
                                };
                            },
                            '~' => this: {
                                const kind = try std.fmt.parseInt(u8, data[2..end], 10);
                                break :this switch (kind) {
                                    2 => .insert,
                                    3 => .delete,
                                    5 => .page_up,
                                    6 => .page_down,
                                    13 => .{ .f = 3 },
                                    15 => .{ .f = 5 },
                                    17 => .{ .f = 6 },
                                    18 => .{ .f = 7 },
                                    19 => .{ .f = 8 },
                                    20 => .{ .f = 9 },
                                    21 => .{ .f = 10 },
                                    23 => .{ .f = 11 },
                                    24 => .{ .f = 12 },
                                    29 => .menu,
                                    else => |n| .{ .unhandled = .{ .tl = n } },
                                };
                            },
                            else => return error.InvalidKeyEvent,
                        };
                    },
                    else => return error.InvalidKeyEvent,
                }
            }

            return key_event;
        }
    };

    pub const Key = union(enum) {
        const Unhandled = union(enum) {
            /// Unhandled CSI [ <N> u
            u: u16,
            /// Unhandled CSI [ <N> ~
            tl: u8,
        };

        left: void,
        right: void,
        up: void,
        down: void,
        home: void,
        end: void,
        insert: void,
        delete: void,
        page_up: void,
        page_down: void,
        backtab: void,
        menu: void,

        // aliases
        backspace: void,
        enter: void,
        tab: void,

        f: u8,
        code: u8,
        non_ascii: u8,
        null: void,
        unhandled: Unhandled,

        pub fn format(
            self: Key,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (self) {
                .left => try writer.writeAll("Left"),
                .right => try writer.writeAll("Right"),
                .up => try writer.writeAll("Up"),
                .down => try writer.writeAll("Down"),
                .home => try writer.writeAll("Home"),
                .end => try writer.writeAll("End"),
                .insert => try writer.writeAll("Insert"),
                .delete => try writer.writeAll("Delete"),
                .page_up => try writer.writeAll("PageUp"),
                .page_down => try writer.writeAll("PageDown"),
                .backtab => try writer.writeAll("Backtab"),
                .menu => try writer.writeAll("ContextMenu"),
                .backspace => try writer.writeAll("Backspace"),
                .enter => try writer.writeAll("Enter"),
                .tab => try writer.writeAll("Tab"),
                .f => try std.fmt.format(writer, "F{d}", .{self.f}),
                .code, .non_ascii => |c| try putc(writer, c),
                .null => try writer.writeAll("Null"),
                .unhandled => |case| {
                    try writer.writeAll("Unhandled CSI [ ");
                    switch (case) {
                        .u => |n| try std.fmt.format(writer, "{d} u", .{n}),
                        .tl => |n| try std.fmt.format(writer, "{d} ~", .{n}),
                    }
                },
            }
        }
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

            pub fn format(
                self: Button,
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                switch (self) {
                    .left => try writer.writeAll("Left"),
                    .middle => try writer.writeAll("Middle"),
                    .right => try writer.writeAll("Right"),
                    .extra => |n| try std.fmt.format(writer, "Extra({d})", .{n}),
                }
            }
        };

        pub const Wheel = enum {
            up,
            down,
            left,
            right,

            pub fn format(
                self: Wheel,
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                switch (self) {
                    .up => try writer.writeAll("Up"),
                    .down => try writer.writeAll("Down"),
                    .left => try writer.writeAll("Left"),
                    .right => try writer.writeAll("Right"),
                }
            }
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

        pub fn format(
            self: MouseEvent,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            if (self.move) {
                try writer.writeAll("Move");
            } else {
                switch (self.button) {
                    .click => try std.fmt.format(writer, "Click::{s}", .{self.button.click}),
                    .wheel => try std.fmt.format(writer, "Wheel::{s}", .{self.button.wheel}),
                    .release => try writer.writeAll("Release"),
                }
            }
            try std.fmt.format(writer, "({d}, {d})", .{ self.x, self.y });
        }

        fn parse(data: []const u8) !MouseEvent {
            const csi_prefix = csi.ct("[M");
            var mouse_event: MouseEvent = undefined;

            if (data.len != 6 or !std.mem.startsWith(u8, data, csi_prefix)) {
                return error.InvalidMouseEvent;
            }

            const button = data[csi_prefix.len] - 32;
            const x = data[csi_prefix.len + 1] - 32;
            const y = data[csi_prefix.len + 2] - 32;

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
            return try self.read();
        }

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

            if (end != processed and data[0] == cc.esc) {
                processed = end;
                event.* = process_other(data[0..end]);
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

        fn process_other(data: []const u8) Event {
            const unknown: Event = .{ .unknown = data };
            if (data.len < 4 or data[1] != '[') {
                return unknown;
            }

            const code = data[data.len - 1];
            switch (code) {
                'R' => {
                    const maybe_semi = std.mem.indexOfPos(u8, data, 2, ";");
                    if (maybe_semi) |semi| {
                        const rowstr = data[2..semi];
                        const colstr = data[semi + 1 .. data.len - 1];
                        const y = std.fmt.parseInt(u16, rowstr, 10) catch return unknown;
                        const x = std.fmt.parseInt(u16, colstr, 10) catch return unknown;
                        return .{ .position = .{ .x = x, .y = y } };
                    }
                },
                else => {},
            }

            return unknown;
        }
    };
};

test {
    std.testing.refAllDecls(@This());
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
/// Note: some terminals will not move the cursor to the top left corner.
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
