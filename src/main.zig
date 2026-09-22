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

pub fn showDatabaseContent(io: std.Io, db_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_output = try std.Io.Dir.cwd().createFile(
        io,
        "output.json",
        .{ .read = true },
    );
    defer json_output.close(io);
    var write_buffer: [4096]u8 = undefined;
    var json_writer = json_output.writer(io, &write_buffer);

    const database = try kcd.KcdDatabase.parseFile(io, db_path, allocator);

    const serializable_db = try database.serialize(allocator);

    try std.json.Stringify.value(serializable_db.items, .{ .whitespace = .indent_4 }, &json_writer.interface);
    try json_writer.interface.flush();
    std.debug.print("Output exported to output.json\n", .{});
}

pub fn exportDatabaseToJson(io: std.Io, db_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const file = try std.Io.Dir.cwd().openFile(io, db_path, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const buffer = try file_reader.interface.allocRemaining(allocator, .limited(10_000_000));
    const database = try kcd.KcdParser(allocator, buffer);
    for (database.items) |msg| {
        // std.log.debug("msg = {}\n", .{msg.*});
        std.debug.print("{s}\n", .{msg.name});
        var it = Iterator(kcd.SignalDefinition){ .head = msg.head };
        while (it.next()) |signal| {
            std.debug.print("{s}\n", .{signal.structure.name});
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const ParserT = easycli.CliParser(.{
        .opts = Options,
        .opts_info = &options_doc,
        .args = Arguments,
    });
    const params = if (try ParserT.runStandalone(init)) |p| p else return;
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
            try showDatabaseContent(init.io, db_path);
        },
        .encode => {
            std.debug.print("Payload {s}\n", .{params.options.payload});
        },
        else => {},
    }
}
