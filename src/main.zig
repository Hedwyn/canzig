const std = @import("std");
const can = @import("socketcan.zig");
const xml = @import("xml.zig");
const debugPrint = std.log.debug;

const default_can_if = "vcan0";

pub fn main() !void {
    var args_it = std.process.args();
    // First arg is exe name
    _ = args_it.next();
    const user_can_if: ?[]const u8 = args_it.next();
    const can_if = user_can_if orelse default_can_if;
    const db_path = args_it.next() orelse unreachable;

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

    const file = try std.fs.cwd().openFile(db_path, .{});
    const reader = file.reader();
    const allocator = std.heap.page_allocator;
    const buffer = try reader.readAllAlloc(allocator, 10_000_000);
    std.debug.print("{s}", .{buffer});
    const document = try xml.parse(allocator, buffer);
    defer document.deinit();

    const root_node = document.root;
    var it = root_node.iterator();

    while (it.next()) |child| {
        switch (child.*) {
            .char_data => |d| std.debug.print("Char data= {s}\n", .{d}),
            .element => |el| std.debug.print("Element, tag={s}\n", .{el.tag}),
            .comment => |c| std.debug.print("Comment= {s}\n", .{c}),
        }
        std.debug.print("Next element = {}\n", .{child});
    }
    std.debug.print("{}", .{document});
    allocator.free(buffer);
    debugPrint("Received {}", .{can.canRecv(fd)});
}
