const std = @import("std");
const can = @import("socketcan.zig");
const xml = @import("xml.zig");
const kcd = @import("kcd.zig");
const utils = @import("utils.zig");
const Iterator = utils.Iterator;
const easycli = @import("parser");
const debugPrint = std.log.debug;

const default_can_if: []const u8 = "vcan0";

const Options = struct {
    interface: []const u8 = default_can_if,
    db_path: ?[]const u8 = null,
};

const options_doc = [_]easycli.OptionInfo{
    .{ .name = "interface", .help = "Name of the CAN channel to connect to" },
    .{ .name = "db_path", .help = "Path to a KCD database to parse" },
};

pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .opts = Options,
        .opts_info = &options_doc,
    });
    const params = if (try ParserT.runStandalone()) |p| p else return;
    const can_if = params.options.interface;

    std.debug.print("Can if is {s}\n", .{params.options.interface});
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
    std.debug.print("path!{any} \n", .{params.options.db_path});

    // --- KCD demo ---
    if (params.options.db_path) |db_path| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const file = try std.fs.cwd().openFile(db_path, .{});

        const reader = file.reader();
        const buffer = try reader.readAllAlloc(allocator, 10_000_000);
        const database = try kcd.parseKcd(allocator, buffer);
        for (database.items) |msg| {
            // std.log.debug("msg = {}\n", .{msg.*});
            std.debug.print("{s}\n", .{msg.name});
            var it = Iterator(kcd.SignalDefinition){ .head = msg.head };
            while (it.next()) |signal| {
                std.debug.print("{s}\n", .{signal.structure.name});
            }
        }
    }
}
