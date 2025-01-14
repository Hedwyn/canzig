const std = @import("std");
const can = @import("socketcan.zig");
const xml = @import("xml.zig");
const easycli = @import("parser");
const debugPrint = std.log.debug;

const default_can_if = "vcan0";

const Options = struct {
    interface: []const u8,
    db_path: []const u8,
};

pub fn main() !void {
    const ParserT = easycli.CliParser(Options, struct {});
    const params = if (try ParserT.runStandalone(.{})) |p| p else return;
    const can_if = params.options.interface;
    const db_path = params.options.db_path;
    std.debug.print("Can if is {s}\n", .{can_if});
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
