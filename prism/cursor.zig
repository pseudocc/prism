const std = @import("std");
const testing = std.testing;
const csi = @import("prism.csi");
const common = @import("prism.common");

pub const Cursor = union(enum) {
    const Self = @This();

    up: u16,
    down: u16,
    right: u16,
    left: u16,
    goto: common.Point,
    column: u16,
    row: u16,
    next: u16,
    prev: u16,
    save: void,
    restore: void,

    show: void,
    hide: void,

    position: void,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .up => |n| {
                return csi.format.ns(writer, n, 'A');
            },
            .down => |n| {
                return csi.format.ns(writer, n, 'B');
            },
            .right => |n| {
                return csi.format.ns(writer, n, 'C');
            },
            .left => |n| {
                return csi.format.ns(writer, n, 'D');
            },
            .goto => |p| {
                if (p.x == 0 or p.y == 0) {
                    const payload = if (p.x == 0) row(p.y) else column(p.x);
                    return std.fmt.format(writer, "{}", .{payload});
                }
                try writer.writeAll(csi.ct("["));
                if (p.y > 1) {
                    try std.fmt.format(writer, "{d}", .{p.y});
                }
                try writer.writeAll(";");
                if (p.x > 1) {
                    try std.fmt.format(writer, "{d}", .{p.x});
                }
                return writer.writeAll("H");
            },
            .column => |n| {
                return csi.format.ns(writer, n, '`');
            },
            .row => |n| {
                return csi.format.ns(writer, n, 'd');
            },
            .next => |n| {
                return csi.format.ns(writer, n, 'E');
            },
            .prev => |n| {
                return csi.format.ns(writer, n, 'F');
            },
            .save => {
                return writer.writeAll(csi.ct("7"));
            },
            .restore => {
                return writer.writeAll(csi.ct("8"));
            },
            .show => {
                return writer.writeAll(csi.ct("[?25h"));
            },
            .hide => {
                return writer.writeAll(csi.ct("[?25l"));
            },
            .position => {
                return writer.writeAll(csi.ct("[6n"));
            },
        }
    }

    pub const Shape = enum {
        default,
        block,
        underline,
        bar,
    };

    pub const Highlight = enum {
        blink,
        steady,
    };

    pub const Style = union(Shape) {
        default: void,
        block: Highlight,
        underline: Highlight,
        bar: Highlight,

        pub fn format(
            self: Style,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const pack: std.meta.Tuple(&.{ u8, Highlight }) = switch (self) {
                .default => return try writer.writeAll(csi.ct("[ q")),
                .block => |t| .{ 1, t },
                .underline => |t| .{ 3, t },
                .bar => |t| .{ 5, t },
            };
            try std.fmt.format(writer, "{s}{d} q", .{
                csi.ct("["),
                pack[0] + @intFromEnum(pack[1]),
            });
        }
    };

    pub const Scroll = union(enum) {
        const Self = @This();

        up: u16,
        down: u16,

        pub fn format(
            self: Scroll,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (self) {
                .up => |n| try csi.format.ns(writer, n, 'S'),
                .down => |n| try csi.format.ns(writer, n, 'T'),
            }
        }
    };
};

/// Cursor Up (CUU)
/// Move the cursor up N lines.
/// Under the hood: `ESC [ <N> A`
pub inline fn up(n: u16) Cursor {
    return .{ .up = n };
}

/// Cursor Down (CUD)
/// Move the cursor down N lines.
/// Under the hood: `ESC [ <N> B`
pub inline fn down(n: u16) Cursor {
    return .{ .down = n };
}

/// Cursor Right (CUF)
/// Move the cursor to the right N columns.
/// Under the hood: `ESC [ <N> C`
pub inline fn right(n: u16) Cursor {
    return .{ .right = n };
}

/// Cursor Left (CUB)
/// Move the cursor to the left N columns.
/// Under the hood: `ESC [ <N> D`
pub inline fn left(n: u16) Cursor {
    return .{ .left = n };
}

/// Cursor Position (CUP)
/// Move the cursor to row X, column Y.
/// Under the hood: `ESC [ <X> ; <Y> H`
pub inline fn goto(x: u16, y: u16) Cursor {
    return .{ .goto = .{ .x = x, .y = y } };
}

/// Cursor Position (CUP)
/// Move the cursor to row P.X, column P.Y.
/// Under the hood: `ESC [ <P.X> ; <P.Y> H`
pub inline fn gotoPoint(p: common.Point) Cursor {
    return .{ .goto = p };
}

/// Cursor Horizontal Position Absolute (HPA)
/// Move the cursor to the column N, row is unchanged.
/// Under the hood: ``ESC [ <N> `\``
pub inline fn column(n: u16) Cursor {
    return .{ .column = n };
}

/// Cursor Vertical Position Absolute (VPA)
/// Move the cursor to the row N, column is unchanged.
/// Under the hood: `ESC [ <N> d`
pub inline fn row(n: u16) Cursor {
    return .{ .row = n };
}

/// Cursor Next Line (CNL)
/// Move cursor to next N line(s).
/// Under the hood: `ESC [ <N> E`
pub inline fn next(n: u16) Cursor {
    return .{ .next = n };
}

/// Cursor Previous Line (CPL)
/// Move cursor to previous N line(s).
/// Under the hood: `ESC [ <N> F`
pub inline fn prev(n: u16) Cursor {
    return .{ .prev = n };
}

/// Save Cursor (DECSC)
/// Save cursor position and further state.
/// Under the hood: `ESC 7`
pub const save: Cursor = .save;

/// Restore Cursor (DECRC)
/// Restore cursor position and further state.
/// Under the hood: `ESC 8`
pub const restore: Cursor = .restore;

/// Cursor Visibility (DECTCEM)
/// Under the hood: `ESC [ ?25h`
pub const show: Cursor = .show;

/// Cursor Visibility (DECTCEM)
/// Under the hood: `ESC [ ?25l`
pub const hide: Cursor = .hide;

/// Request Cursor Position Report (CPR)
/// Under the hood: `ESC [ 6 n`
pub const position: Cursor = .position;

/// Set Cursor Style (DECSCUSR)
pub const style = struct {
    pub const default: Cursor.Style = .default;

    /// Select Cursor Style Blinking/Steady Block
    /// Example: `style.block(.blink)` or `style.block(.steady)`
    /// Under the hood: `ESC [ <n> q`
    pub inline fn block(h: Cursor.Highlight) Cursor.Style {
        return .{ .block = h };
    }

    /// Select Cursor Style Blinking/Steady Underline
    /// Example: `style.block(.blink)` or `style.block(.steady)`
    pub inline fn underline(h: Cursor.Highlight) Cursor.Style {
        return .{ .underline = h };
    }

    /// Select Cursor Style Blinking/Steady Bar
    /// Example: `style.block(.blink)` or `style.block(.steady)`
    pub inline fn bar(h: Cursor.Highlight) Cursor.Style {
        return .{ .bar = h };
    }
};

/// Scroll Up (SU) / Scroll Down (SD)
pub const scroll = struct {
    /// Scroll Up (SU)
    /// Scroll the page up N lines.
    /// Under the hood: `ESC [ <N> S`
    pub inline fn up(n: u16) Cursor.Scroll {
        return .{ .up = n };
    }

    /// Scroll Down (SD)
    /// Scroll the page down N lines.
    /// Under the hood: `ESC [ <N> T`
    pub inline fn down(n: u16) Cursor.Scroll {
        return .{ .down = n };
    }
};

fn test_any(value: anytype, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const result = try std.fmt.bufPrint(&buffer, "{}", .{value});
    try testing.expectEqualStrings(expected, result);
}

test "cursor.up" {
    try test_any(up(1), "\x1b[A");
    try test_any(up(2), "\x1b[2A");
}

test "cursor.save" {
    try test_any(save, "\x1b7");
}

test "cursor.goto" {
    try test_any(goto(0, 0), "");
    try test_any(goto(1, 0), "\x1b[`");
    try test_any(goto(0, 2), "\x1b[2d");
    try test_any(goto(1, 1), "\x1b[;H");
    try test_any(goto(2, 1), "\x1b[;2H");
    try test_any(gotoPoint(.{ .x = 1, .y = 2 }), "\x1b[2;H");
    try test_any(goto(2, 4), "\x1b[4;2H");
}

test "cursor.style" {
    try test_any(style.default, "\x1b[ q");
    try test_any(style.block(.blink), "\x1b[1 q");
    try test_any(style.block(.steady), "\x1b[2 q");
    try test_any(style.underline(.blink), "\x1b[3 q");
    try test_any(style.underline(.steady), "\x1b[4 q");
    try test_any(style.bar(.blink), "\x1b[5 q");
    try test_any(style.bar(.steady), "\x1b[6 q");
}

test "cursor.scroll" {
    try test_any(scroll.up(1), "\x1b[S");
    try test_any(scroll.up(2), "\x1b[2S");
    try test_any(scroll.down(1), "\x1b[T");
    try test_any(scroll.down(2), "\x1b[2T");
}
