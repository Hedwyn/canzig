//! Prints CAN frames received on a SocketCAN interface as they arrive.
//!
//! Usage: socketcan_recv [interface] [count]
//!
//! Uses only the standard library's built-in argument iteration
//! (`std.process`) - no CLI parsing library.
const std = @import("std");
const can = @import("socketcan");

const default_interface = "vcan0";

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name

    const interface = args.next() orelse default_interface;
    // Number of frames to print before exiting; 0 means run until interrupted.
    const count = if (args.next()) |c| try std.fmt.parseInt(usize, c, 10) else 0;

    const fd = try can.openSocketCan(interface);
    defer can.closeSocketCan(fd);

    std.debug.print("Listening on {s} (Ctrl+C to stop)...\n", .{interface});

    var received: usize = 0;
    while (count == 0 or received < count) : (received += 1) {
        const frame = can.canRecv(fd);

        std.debug.print(
            "id=0x{x}{s}{s} len={} data={x}\n",
            .{
                frame.can_id(),
                if (frame.isExtended()) "x" else "",
                if (frame.isRtr()) " RTR" else "",
                frame.len,
                frame.data[0..frame.len],
            },
        );
    }
}
