const std = @import("std");
const testing = std.testing;
const csi = @import("prism.csi");

pub const AttributeTrait = union(enum) {
    style: styles.Attribute,
    color: colors.Attribute,
};

fn internal_set(value: styles.Ansi, active: bool) AttributeTrait {
    // TODO: figure out how to do this without repeating the enum
    const attr: styles.Attribute = switch (value) {
        .bold => .{ .bold = active },
        .faint => .{ .faint = active },
        .italic => .{ .italic = active },
        .under => .{ .under = active },
        .blink => .{ .blink = active },
        .reverse => .{ .reverse = active },
        .conceal => .{ .conceal = active },
        .strike => .{ .strike = active },
    };
    return .{ .style = attr };
}

pub inline fn fg(value: colors.Trait) AttributeTrait {
    return .{ .color = .{ .fg = value } };
}

pub inline fn bg(value: colors.Trait) AttributeTrait {
    return .{ .color = .{ .bg = value } };
}

pub inline fn set(value: styles.Ansi) AttributeTrait {
    return internal_set(value, true);
}

pub inline fn unset(value: styles.Ansi) AttributeTrait {
    return internal_set(value, false);
}

// aliases to avoid shadowing inside Rendition
const gfg = fg;
const gbg = bg;

const InternalRendition = struct {
    pub const Self = @This();

    items: []const AttributeTrait,

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var first: bool = true;
        try writer.writeAll(csi.ct("["));
        for (self.items) |attr| {
            if (first) {
                first = false;
            } else {
                try writer.writeAll(";");
            }
            switch (attr) {
                inline else => |a| {
                    try std.fmt.format(writer, "{}", .{a});
                },
            }
        }
        try writer.writeAll("m");
    }
};

pub fn attrs(comptime items: []const AttributeTrait) []const u8 {
    const r = InternalRendition{ .items = items };
    return std.fmt.comptimePrint("{}", .{r});
}

/// Select Graphic Rendition (SGR)
pub const Rendition = struct {
    pub const Self = @This();

    attrs: std.ArrayList(AttributeTrait),

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .attrs = std.ArrayList(AttributeTrait).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.attrs.deinit();
    }

    /// convenience function ignores errors
    pub fn fg(self: *Self, value: colors.Trait) *Self {
        self.attrs.append(gfg(value)) catch unreachable;
        return self;
    }

    /// convenience function ignores errors
    pub fn bg(self: *Self, value: colors.Trait) *Self {
        self.attrs.append(gbg(value)) catch unreachable;
        return self;
    }

    /// convenience function ignores errors
    pub fn set(self: *Self, value: styles.Ansi) *Self {
        self.attrs.append(internal_set(value, true)) catch unreachable;
        return self;
    }

    /// convenience function ignores errors
    pub fn unset(self: *Self, value: styles.Ansi) *Self {
        self.attrs.append(internal_set(value, false)) catch unreachable;
        return self;
    }

    /// convenience function
    pub fn reset(self: *Self) *Self {
        self.clear();
        return self;
    }

    /// convenience function calls `attrs.clearRetainingCapacity`
    /// under the hood
    pub fn clear(self: *Self) void {
        self.attrs.clearRetainingCapacity();
    }

    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const r = InternalRendition{ .items = self.attrs.items };
        try std.fmt.format(writer, "{}", .{r});
    }
};

pub const styles = struct {
    pub const Ansi = enum(u8) {
        bold = 1,
        faint = 2,
        italic = 3,
        under = 4,
        blink = 5,
        reverse = 7,
        conceal = 8,
        strike = 9,
    };

    pub const Attribute = union(Ansi) {
        const Self = @This();

        bold: bool,
        faint: bool,
        italic: bool,
        under: bool,
        blink: bool,
        reverse: bool,
        conceal: bool,
        strike: bool,

        pub fn format(
            self: Self,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            var value: u8 = @intFromEnum(self);
            switch (self) {
                .bold => |b| value = if (b) 1 else 22,
                inline else => |b| value = if (b) value else value + 20,
            }
            try std.fmt.format(writer, "{d}", .{value});
        }
    };
};

pub const colors = struct {
    pub const Ansi = enum(u8) {
        black = 0,
        red = 1,
        green = 2,
        yellow = 3,
        blue = 4,
        magenta = 5,
        cyan = 6,
        white = 7,

        bright_black = 60,
        bright_red = 61,
        bright_green = 62,
        bright_yellow = 63,
        bright_blue = 64,
        bright_magenta = 65,
        bright_cyan = 66,
        bright_white = 67,
    };

    pub const Trait = union(enum) {
        /// 8 color
        ansi: Ansi,
        /// 256 color
        ansi256: u8,
        /// rgb color
        rgb: struct {
            r: u8 = 0,
            g: u8 = 0,
            b: u8 = 0,
        },
        /// reset color
        reset: void,
    };

    pub const Attribute = union(enum) {
        const Self = @This();

        fg: Trait,
        bg: Trait,

        pub fn format(
            self: Self,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            var trait: Trait = undefined;
            var offset: u8 = undefined;
            switch (self) {
                .fg => {
                    trait = self.fg;
                    offset = 30;
                },
                .bg => {
                    trait = self.bg;
                    offset = 40;
                },
            }

            const f = std.fmt.format;
            switch (trait) {
                .ansi => |c| {
                    const value = @intFromEnum(c);
                    try f(writer, "{d}", .{offset + value});
                },
                .ansi256 => |c| {
                    try f(writer, "{d};5;{d}", .{ offset + 8, c });
                },
                .rgb => |c| {
                    try f(writer, "{d};2;{d};{d};{d}", .{ offset + 8, c.r, c.g, c.b });
                },
                .reset => {
                    try f(writer, "{d}", .{offset + 9});
                },
            }
        }
    };
};

fn test_rendition(r: *Rendition, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    defer r.clear();

    const result = try std.fmt.bufPrint(&buffer, "{}", .{r});
    try testing.expectEqualStrings(expected, result);
}

test "graphic.reset" {
    var r = Rendition.init(std.testing.allocator);
    defer r.deinit();

    try test_rendition(r.reset(), "\x1b[m");
    try testing.expectEqualStrings(attrs(&.{}), "\x1b[m");
}

test "graphic.style.bold" {
    var r = Rendition.init(std.testing.allocator);
    defer r.deinit();

    try test_rendition(r.set(.bold), "\x1b[1m");
    try testing.expectEqualStrings(attrs(&.{set(.bold)}), "\x1b[1m");
    try test_rendition(r.unset(.bold), "\x1b[22m");
    try testing.expectEqualStrings(attrs(&.{unset(.bold)}), "\x1b[22m");
}

test "graphic.style.blink" {
    var r = Rendition.init(std.testing.allocator);
    defer r.deinit();

    try test_rendition(r.set(.blink), "\x1b[5m");
    try test_rendition(r.unset(.blink), "\x1b[25m");
}

test "graphic.color.black" {
    var r = Rendition.init(std.testing.allocator);
    defer r.deinit();

    try test_rendition(r.fg(.{ .ansi = .black }), "\x1b[30m");
    try test_rendition(r.bg(.{ .ansi = .bright_black }), "\x1b[100m");
    try test_rendition(r.fg(.reset), "\x1b[39m");
    try test_rendition(r.bg(.reset), "\x1b[49m");
}

test "graphic.combined" {
    var r = Rendition.init(std.testing.allocator);
    defer r.deinit();

    try test_rendition(r.fg(.reset).set(.bold), "\x1b[39;1m");
    try testing.expectEqualStrings(attrs(&.{ fg(.reset), set(.bold) }), "\x1b[39;1m");
}
