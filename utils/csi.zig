const std = @import("std");

pub const esc: []const u8 = &.{@as(u8, std.ascii.control_code.esc)};
pub fn ct(comptime s: []const u8) [:0]const u8 {
    return std.fmt.comptimePrint("{s}{s}", .{ esc, s });
}

pub const format = struct {
    pub fn ns(
        writer: anytype,
        n: u16,
        comptime s: u8,
    ) !void {
        if (n == 0) {
            return;
        }
        try writer.writeAll(ct("["));
        if (n > 1) {
            try std.fmt.format(writer, "{d}", .{n});
        }
        try writer.writeAll(&.{s});
    }
};
