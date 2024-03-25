const std = @import("std");
const int = u16;

pub const Size = struct {
    width: int = 0,
    height: int = 0,
};

pub const Point = struct {
    x: int = 0,
    y: int = 0,
};

pub const bench = struct {
    const stderr = std.io.getStdErr().writer();
    const Location = std.builtin.SourceLocation;
    var maybe_last_us: ?i64 = null;

    /// Mark the current location with the time elapsed since the last mark.
    /// This is useful for debugging and profiling.
    /// Example:
    /// ```zig
    /// fn foo() void {
    ///    bench.mark();        // clear the last mark
    ///    compute(&all_cpus);  // do some work
    ///    bench.mark(@src());
    /// }
    /// ```
    pub inline fn mark(location: ?Location) void {
        const src = location orelse {
            maybe_last_us = null;
            return;
        };
        const now_us = std.time.microTimestamp();
        const factor = std.time.us_per_ms;

        stderr.print("{s}:{d} fn {s}", .{ src.file, src.line, src.fn_name }) catch {};
        if (maybe_last_us) |last_us| {
            const delta = now_us - last_us;
            if (delta < factor) {
                stderr.print(" {d}us elasped\n", .{delta}) catch {};
            } else {
                stderr.print(" {d}ms elasped\n", .{delta / factor}) catch {};
            }
        } else {
            stderr.print(" just started\n", .{}) catch {};
        }
        maybe_last_us = now_us;
    }
};

pub fn bufcopy(dest: []u8, src: []const u8) !usize {
    const n = src.len;
    if (n > dest.len) {
        return error.BufferTooSmall;
    }
    @memcpy(dest[0..n], src);
    return n;
}

pub fn Optional(comptime StructType: type) type {
    const T = std.builtin.Type;
    const t = switch (@typeInfo(StructType)) {
        .Struct => |case| case,
        else => @compileError("Optional only works with structs"),
    };

    const proto = comptime this: {
        var fields: [t.fields.len]T.StructField = undefined;
        var i: usize = 0;

        for (t.fields) |field| {
            fields[i] = field;
            if (@typeInfo(field.type) != .Optional) {
                const ot = @Type(.{
                    .Optional = .{ .child = field.type },
                });
                const ot_null: ot = null;
                fields[i].type = ot;
                fields[i].default_value = &ot_null;
                fields[i].alignment = @sizeOf(ot);
            }
            i += 1;
        }
        var ot = t;
        ot.fields = &fields;
        ot.layout = .Auto;
        ot.decls = &.{};

        break :this ot;
    };

    return @Type(.{ .Struct = proto });
}

test "prism.common.Optional" {
    const equals = std.testing.expectEqual;

    const T1 = struct {
        a: u8,
        b: u8,
    };
    const OT1 = Optional(T1);
    const ot1 = OT1{};
    try equals(@as(?u8, null), ot1.a);
    try equals(@as(?u8, null), ot1.b);

    const T2 = struct {
        const Self = @This();
        a: ?u8 = 0,
        b: u8,

        pub fn sum(self: Self) u8 {
            const a = self.a orelse 0;
            return a + self.b;
        }
    };
    const OT2 = Optional(T2);
    std.log.debug("{}", .{OT2});

    const ot2 = OT2{ .b = null };
    try equals(@as(?u8, 0), ot2.a);
    try equals(@as(?u8, null), ot2.b);
}
