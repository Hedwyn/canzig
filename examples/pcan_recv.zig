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

    var handle = try pcan.openPcan(channel, bitrate, true);
    defer pcan.closePcan(&handle);

    std.debug.print("Listening on {s} at {} bit/s (Ctrl+C to stop)...\n", .{ channel, bitrate });

    var received: usize = 0;
    while (count == 0 or received < count) : (received += 1) {
        const received_frame = pcan.canRecvTimestamped(&handle);
        const frame = received_frame.frame;

        std.debug.print(
            "t={d}ns id=0x{x}{s}{s}{s} len={} data={x}\n",
            .{
                received_frame.timestamp.ns_since_epoch,
                frame.can_id(),
                if (frame.isExtended()) "x" else "",
                if (frame.isRtr()) " RTR" else "",
                if (frame.isError()) " ERR" else "",
                frame.len,
                frame.data[0..frame.len],
            },
        );
    }
}
