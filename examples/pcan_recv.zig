//! Prints CAN frames received on a PCAN channel as they arrive.
//!
//! Usage: pcan_recv [channel] [bitrate] [count]
//!
//! Uses only the standard library's built-in argument iteration
//! (`std.process`) - no CLI parsing library.
const std = @import("std");
const pcan = @import("pcan");

const default_channel = "PCAN_USBBUS1";
const default_bitrate: u32 = 500_000;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name

    const channel = args.next() orelse default_channel;
    const bitrate = if (args.next()) |b| try std.fmt.parseInt(u32, b, 10) else default_bitrate;
    // Number of frames to print before exiting; 0 means run until interrupted.
    const count = if (args.next()) |c| try std.fmt.parseInt(usize, c, 10) else 0;

    var handle = try pcan.openPcan(channel, bitrate);
    defer pcan.closePcan(&handle);

    std.debug.print("Listening on {s} at {} bit/s (Ctrl+C to stop)...\n", .{ channel, bitrate });

    var received: usize = 0;
    while (count == 0 or received < count) : (received += 1) {
        const frame = pcan.canRecv(&handle);
        const is_extended = (frame.can_id & pcan.can_eff_flag) != 0;
        const is_rtr = (frame.can_id & pcan.can_rtr_flag) != 0;
        const raw_id = frame.can_id & (if (is_extended) pcan.can_eff_mask else pcan.can_sff_mask);

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
