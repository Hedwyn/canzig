const std = @import("std");
const can = @import("socketcan.zig");
const debugPrint = std.log.debug;

const default_can_if = "vcan0";

pub fn main() !void {
    var args_it = std.process.args();
    // First arg is exe name
    _ = args_it.next();
    const user_can_if: ?[]const u8 = args_it.next();
    const can_if = user_can_if orelse default_can_if;

    if (user_can_if == null) {
        std.debug.print("Defaulting to {s}\n", .{can_if});
    } else {
        std.debug.print("Using {s}\n", .{can_if});
    }

    const fd = try can.openSocketCan(can_if);
    defer can.closeSocketCan(fd);
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const test_frame = can.CanFrame{
        .can_id = 0x123,
        .len = 8,
        .pad = 0,
        .data = data,
    };
    _ = try can.canSend(fd, &test_frame);
    debugPrint("Received {}", .{can.canRecv(fd)});
}
