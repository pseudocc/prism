const std = @import("std");
const testing = std.testing;
const csi = @import("../utils/csi.zig");

pub const Cursor = union(enum) {
    const Self = @This();

    /// Cursor Up (CUU)
    up: u16,
    /// Cursor Down (CUD)
    down: u16,
    /// Cursor Right (CUF)
    right: u16,
    /// Cursor Left (CUB)
    left: u16,
    /// Cursor Position (CUP)
    goto: struct {
        x: u16 = 0,
        y: u16 = 0,
    },
    /// Cursor Horizontal Position Absolute (HPA)
    column: u16,
    /// Cursor Vertical Position Absolute (VPA)
    row: u16,
    /// Cursor Next Line (CNL)
    next: u16,
    /// Cursor Previous Line (CPL)
    prev: u16,
    /// Save Cursor (DECSC)
    save: void,
    /// Restore Cursor (DECRC)
    restore: void,

    /// Cursor Visibility Show (DECTCEM)
    show: void,
    /// Cursor Visibility Hide (DECTCEM)
    hide: void,

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
                return writer.writeAll(csi.ct("?25h"));
            },
            .hide => {
                return writer.writeAll(csi.ct("?25l"));
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

    /// Cursor Style (DECSCUSR)
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

pub inline fn up(n: u16) Cursor {
    return .{ .up = n };
}

pub inline fn down(n: u16) Cursor {
    return .{ .down = n };
}

pub inline fn right(n: u16) Cursor {
    return .{ .right = n };
}

pub inline fn left(n: u16) Cursor {
    return .{ .left = n };
}

pub inline fn goto(x: u16, y: u16) Cursor {
    return .{ .goto = .{ .x = x, .y = y } };
}

pub inline fn column(n: u16) Cursor {
    return .{ .column = n };
}

pub inline fn row(n: u16) Cursor {
    return .{ .row = n };
}

pub inline fn next(n: u16) Cursor {
    return .{ .next = n };
}

pub inline fn prev(n: u16) Cursor {
    return .{ .prev = n };
}

pub const save: Cursor = .save;

pub const restore: Cursor = .restore;

pub const show: Cursor = .show;

pub const hide: Cursor = .hide;

pub const style = struct {
    pub const default: Cursor.Style = .default;

    pub inline fn block(h: Cursor.Highlight) Cursor.Style {
        return .{ .block = h };
    }

    pub inline fn underline(h: Cursor.Highlight) Cursor.Style {
        return .{ .underline = h };
    }

    pub inline fn bar(h: Cursor.Highlight) Cursor.Style {
        return .{ .bar = h };
    }
};

/// Scroll Up (SU) / Scroll Down (SD)
pub const scroll = struct {
    /// Scroll Up (SU)
    pub inline fn up(n: u16) Cursor.Scroll {
        return .{ .up = n };
    }

    /// Scroll Down (SD)
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
    try test_any(goto(1, 2), "\x1b[2;H");
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
