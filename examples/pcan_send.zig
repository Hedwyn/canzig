//! Sends a single CAN frame on a PCAN channel.
//!
//! Usage: pcan_send <can_id_hex> <payload_hex> [channel] [bitrate]
//!
//! Uses only the standard library's built-in argument iteration
//! (`std.process`) - no CLI parsing library.
const std = @import("std");
const pcan = @import("pcan");

const default_channel = "PCAN_USBBUS1";
const default_bitrate: u32 = 500_000;

fn usage(prog_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} <can_id_hex> <payload_hex> [channel] [bitrate]
        \\
        \\  can_id_hex   CAN identifier in hex (e.g. 123 or 1FFFFFFF). IDs
        \\               above 0x7FF are sent as 29-bit extended frames.
        \\  payload_hex  0-16 hex characters (0-8 bytes), e.g. 0102030405060708
        \\  channel      PCAN channel name (default: {s})
        \\  bitrate      Bus bitrate in bit/s (default: {})
        \\
        \\Example: {s} 123 0102030405060708
        \\
    , .{ prog_name, default_channel, default_bitrate, prog_name });
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    const prog_name = args.next() orelse "pcan_send";

    const id_arg = args.next() orelse {
        usage(prog_name);
        return error.MissingArgument;
    };
    const payload_arg = args.next() orelse {
        usage(prog_name);
        return error.MissingArgument;
    };
    const channel = args.next() orelse default_channel;
    const bitrate = if (args.next()) |b| try std.fmt.parseInt(u32, b, 10) else default_bitrate;

    if (payload_arg.len % 2 != 0 or payload_arg.len > 16) {
        std.debug.print("payload_hex must be 0-16 hex characters (0-8 bytes)\n", .{});
        return error.InvalidArgument;
    }

    const can_id = try std.fmt.parseInt(u32, id_arg, 16);
    const is_extended = can_id > pcan.can_sff_mask;

    var frame = pcan.CanFrame{
        .can_id = if (is_extended) can_id | pcan.can_eff_flag else can_id,
        .len = @intCast(payload_arg.len / 2),
        .data = @splat(0),
    };
    var i: usize = 0;
    while (i < frame.len) : (i += 1) {
        frame.data[i] = try std.fmt.parseInt(u8, payload_arg[i * 2 .. i * 2 + 2], 16);
    }

    var handle = try pcan.openPcan(channel, bitrate);
    defer pcan.closePcan(&handle);

    const sent = try pcan.canSend(&handle, &frame);
    std.debug.print(
        "Sent {} byte(s) on {s} (id=0x{x}{s})\n",
        .{ sent, channel, can_id, if (is_extended) "x" else "" },
    );
}
