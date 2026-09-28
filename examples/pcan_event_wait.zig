//! Waits for CAN frames using PCAN-Basic's receive-event object instead of
//! polling CAN_Read on a sleep loop (see pcan.zig's `waitForReceiveEvent`).
//!
//! Windows-only. On Linux, PCAN-Basic hands back the underlying SocketCAN
//! driver's fd for this same parameter, with no benefit over using
//! socketcan.zig (or pcan.zig's plain `canRecv`) directly - so this example
//! is a no-op there.
//!
//! Usage: pcan_event_wait [channel] [bitrate] [count]
const std = @import("std");
const builtin = @import("builtin");
const pcan = @import("pcan");

const default_channel = "PCAN_USBBUS1";
const default_bitrate: u32 = 500_000;
const wait_timeout_ms: u32 = 1000;

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name

    const channel = args.next() orelse default_channel;
    const bitrate = if (args.next()) |b| try std.fmt.parseInt(u32, b, 10) else default_bitrate;
    // Number of frames to print before exiting; 0 means run until interrupted.
    const count = if (args.next()) |c| try std.fmt.parseInt(usize, c, 10) else 0;

    if (builtin.os.tag != .windows) {
        std.debug.print(
            "pcan_event_wait uses PCAN-Basic's Win32 receive event and only runs on Windows; see pcan_recv for a portable polling loop.\n",
            .{},
        );
        return;
    }

    var handle = try pcan.openPcan(channel, bitrate);
    defer pcan.closePcan(&handle);

    std.debug.print("Waiting for events on {s} at {} bit/s (Ctrl+C to stop)...\n", .{ channel, bitrate });

    var received: usize = 0;
    while (count == 0 or received < count) {
        const signaled = try pcan.waitForReceiveEvent(&handle, wait_timeout_ms);
        if (!signaled) continue; // timed out; wait again

        while (try pcan.tryRecv(&handle)) |frame| {
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

            received += 1;
            if (count != 0 and received >= count) return;
        }
    }
}
