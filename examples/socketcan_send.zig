//! Sends a single CAN frame on a SocketCAN interface.
//!
//! Usage: socketcan_send <can_id_hex> <payload_hex> [interface]
//!
//! Uses only the standard library's built-in argument iteration
//! (`std.process`) - no CLI parsing library.
const std = @import("std");
const can = @import("socketcan");

const default_interface = "vcan0";

fn usage(prog_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} <can_id_hex> <payload_hex> [interface]
        \\
        \\  can_id_hex   CAN identifier in hex (e.g. 123 or 1FFFFFFF). IDs
        \\               above 0x7FF are sent as 29-bit extended frames.
        \\  payload_hex  0-16 hex characters (0-8 bytes), e.g. 0102030405060708
        \\  interface    SocketCAN interface name (default: {s})
        \\
        \\Example: {s} 123 0102030405060708
        \\
        \\The interface must already be up, e.g.:
        \\  sudo ip link set {s} up type vcan
        \\
    , .{ prog_name, default_interface, prog_name, default_interface });
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    const prog_name = args.next() orelse "socketcan_send";

    const id_arg = args.next() orelse {
        usage(prog_name);
        return error.MissingArgument;
    };
    const payload_arg = args.next() orelse {
        usage(prog_name);
        return error.MissingArgument;
    };
    const interface = args.next() orelse default_interface;

    if (payload_arg.len % 2 != 0 or payload_arg.len > 16) {
        std.debug.print("payload_hex must be 0-16 hex characters (0-8 bytes)\n", .{});
        return error.InvalidArgument;
    }

    const can_id = try std.fmt.parseInt(u32, id_arg, 16);
    const is_extended = can_id > can.can_sff_mask;

    var frame = can.CanFrame{
        .can_id = if (is_extended) can_id | can.can_eff_flag else can_id,
        .len = @intCast(payload_arg.len / 2),
        .pad = 0,
        .data = @splat(0),
    };
    var i: usize = 0;
    while (i < frame.len) : (i += 1) {
        frame.data[i] = try std.fmt.parseInt(u8, payload_arg[i * 2 .. i * 2 + 2], 16);
    }

    const fd = try can.openSocketCan(interface);
    defer can.closeSocketCan(fd);

    // `canSend`'s return value is the raw socket write size (always
    // `sizeof(CanFrame)`), not the payload length, so report `frame.len`
    // instead - that is the number of payload bytes actually sent.
    _ = try can.canSend(fd, &frame);
    std.debug.print(
        "Sent {} byte(s) on {s} (id=0x{x}{s})\n",
        .{ frame.len, interface, can_id, if (is_extended) "x" else "" },
    );
}
