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
        const is_extended = (frame.can_id & can.can_eff_flag) != 0;
        const is_rtr = (frame.can_id & can.can_rtr_flag) != 0;
        const raw_id = frame.can_id & (if (is_extended) can.can_eff_mask else can.can_sff_mask);

        std.debug.print(
            "id=0x{x}{s}{s} len={} data={x}\n",
            .{
                raw_id,
                if (is_extended) "x" else "",
                if (is_rtr) " RTR" else "",
                frame.len,
                frame.data[0..frame.len],
            },
        );
    }
}
