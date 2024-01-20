const std = @import("std");
const testing = std.testing;
const csi = @import("csi.zig");

pub const Input = union(enum) {
    const Self = @This();

    pub const Tab = union(enum) {
        /// Forward Tabulation (CHT)
        forward: u16,
        /// Backward Tabulation (CBT)
        backward: u16,
    };

    tab: Tab,
    line: u16,
    blank: u16,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .tab => |t| {
                switch (t) {
                    .forward => |n| try csi.format.ns(writer, n, 'I'),
                    .backward => |n| try csi.format.ns(writer, n, 'Z'),
                }
            },
            .line => |n| try csi.format.ns(writer, n, 'L'),
            .blank => |n| try csi.format.ns(writer, n, '@'),
        }
    }
};

pub const Erase = union(enum) {
    const Self = @This();

    pub const Display = enum {
        /// Above cursor
        above,
        /// Below cursor
        below,
        /// The entire display
        both,
        /// The entire display and scrollback buffer
        all,
    };

    pub const Line = enum {
        /// Cursor to beginning of line
        left,
        /// Cursor to end of line
        right,
        /// The entire line
        both,
    };

    display: Display,
    line: Line,
    char: u16,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .display => |d| {
                switch (d) {
                    .above => try writer.writeAll(csi.ct("[1J")),
                    .below => try writer.writeAll(csi.ct("[J")),
                    .both => try writer.writeAll(csi.ct("[2J")),
                    .all => try writer.writeAll(csi.ct("[3J")),
                }
            },
            .line => |l| {
                switch (l) {
                    .left => try writer.writeAll(csi.ct("[1K")),
                    .right => try writer.writeAll(csi.ct("[K")),
                    .both => try writer.writeAll(csi.ct("[2K")),
                }
            },
            .char => |n| try csi.format.ns(writer, n, 'X'),
        }
    }
};

pub const Delete = union(enum) {
    const Self = @This();

    /// Delete Line (DL)
    /// Direction: cursor to bottom
    line: u16,
    /// Delete Character (DCH)
    /// Direction: cursor to right
    char: u16,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try switch (self) {
            .line => |n| csi.format.ns(writer, n, 'M'),
            .char => |n| csi.format.ns(writer, n, 'P'),
        };
    }
};

pub const input = struct {
    /// Cursor Horizontal Tabulation
    /// - `n < 0`: Backward Tabulation (CBT)
    /// - `n > 0`: Forward Tabulation (CHT)
    pub inline fn tab(n: i16) Input {
        if (n < 0) {
            return .{ .tab = .{ .backward = @intCast(-n) } };
        } else {
            return .{ .tab = .{ .forward = @intCast(n) } };
        }
    }

    /// Insert Line (IL)
    pub inline fn line(n: i16) Input {
        return .{ .line = n };
    }

    /// Insert Blanks (ICH)
    pub inline fn blank(n: i16) Input {
        return .{ .blank = n };
    }
};

pub const erase = struct {
    /// Erase Display (ED)
    pub inline fn display(d: Erase.Display) Erase {
        return .{ .display = d };
    }

    /// Erase Line (EL)
    pub inline fn line(l: Erase.Line) Erase {
        return .{ .line = l };
    }

    /// Erase Character (ECH)
    pub inline fn char(n: u16) Erase {
        return .{ .char = n };
    }
};

pub const delete = struct {
    /// Delete Line (DL)
    pub inline fn line(n: u16) Delete {
        return .{ .line = n };
    }

    /// Delete Character (DCH)
    /// Direction: cursor to right
    pub inline fn char(n: u16) Delete {
        return .{ .char = n };
    }
};

fn test_any(value: anytype, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const result = try std.fmt.bufPrint(&buffer, "{}", .{value});
    try testing.expectEqualStrings(expected, result);
}

test "input" {
    try test_any(input.tab(0), "");
    try test_any(input.tab(1), "\x1b[I");
    try test_any(input.tab(-2), "\x1b[2Z");
    try test_any(input.line(1), "\x1b[L");
    try test_any(input.blank(0), "");
    try test_any(input.blank(2), "\x1b[2@");
}

test "erase" {
    try test_any(erase.display(.above), "\x1b[1J");
    try test_any(erase.display(.below), "\x1b[J");
    try test_any(erase.display(.both), "\x1b[2J");
    try test_any(erase.display(.all), "\x1b[3J");
    try test_any(erase.line(.left), "\x1b[1K");
    try test_any(erase.line(.right), "\x1b[K");
    try test_any(erase.line(.both), "\x1b[2K");
    try test_any(erase.char(0), "");
    try test_any(erase.char(1), "\x1b[X");
    try test_any(erase.char(2), "\x1b[2X");
}

test "delete" {
    try test_any(delete.line(0), "");
    try test_any(delete.line(1), "\x1b[M");
    try test_any(delete.line(2), "\x1b[2M");
    try test_any(delete.char(0), "");
    try test_any(delete.char(1), "\x1b[P");
    try test_any(delete.char(2), "\x1b[2P");
}
