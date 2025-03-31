const std = @import("std");
const can = @import("socketcan.zig");
const xml = @import("xml.zig");
const kcd = @import("kcd.zig");
const utils = @import("utils.zig");
const Iterator = utils.Iterator;
const easycli = @import("parser");
const debugPrint = std.log.debug;

const default_can_if: []const u8 = "vcan0";

const Subcommand = enum {
    send,
    show,
    decode,
    encode,
};

const Arguments = struct {
    subcommand: Subcommand = Subcommand.send,
};

const Options = struct {
    interface: ?[]const u8 = null,
    db_path: ?[]const u8 = null,
    payload: []const u8 = "",
};

const options_doc = [_]easycli.OptionInfo{
    .{ .name = "interface", .help = "Name of the CAN channel to connect to" },
    .{ .name = "db_path", .help = "Path to a KCD database to parse" },
};

pub fn showDatabaseContent(db_path: []const u8) !void {
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

pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .opts = Options,
        .opts_info = &options_doc,
        .args = Arguments,
    });
    const params = if (try ParserT.runStandalone()) |p| p else return;
    const can_if = params.options.interface orelse default_can_if;

    const fd = try can.openSocketCan(can_if);
    defer can.closeSocketCan(fd);
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const test_frame = can.CanFrame{
        .can_id = 0x123,
        .len = 8,
        .pad = 0,
        .data = data,
    };

    switch (params.args.subcommand) {
        .send => {
            _ = try can.canSend(fd, &test_frame);
        },
        .show => {
            const db_path = params.options.db_path orelse {
                std.debug.print("Please pass a path to a KCD database\n", .{});
                return;
            };
            try showDatabaseContent(db_path);
        },
        .encode => {
            std.debug.print("Payload {s}\n", .{params.options.payload});
        },
        else => {},
    }

    std.debug.print("path!{any} \n", .{params.options.db_path});
}
