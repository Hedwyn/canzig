# CAN library for Zig
This package is currently linux-socketcan only. Socketcan is shipped as part of the Linux kernel, documentation is available [here](https://docs.kernel.org/networking/can.html.).<br>
This package currently only implements raw CAN communications, `isotp` or `J1939` communications are not supported yet. There are only 4 primitives for now:
* Opening a CAN socket (`socketcan.openSocketCan`)
* Closing a CAN socket (`socketcan.closeSocketCan`)
* Sending a message to the CAN bus (`socketcan.canSend`)
* Receving a message from the CAN bus (`socketcan.canRecv`)

For the latter, selection is not baked in the reception process. You shoul run your own selection before calling receive, as it will block forever if no data is available.

# Installing and running
Clone this package and run `zig build run -- <your-interface-name>` (e.g., `zig build run -- can0`). Calling `zig build run` without argument will default to `vcan0`. Make sure the CAN interface is actually up on your system. <br>
The demo code will send a single message, then wait (potentially forever) for a message. You can send a message manually with `cansend` command from `can-utils`.<br><br>
Example usage is as follows:
```zig
const can = @import("socketcan.zig);
const fd = try can.openSocketCan("can0");
defer can.closeSocketCan(fd);
// Sending 12345678 in hex to address 123
const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
const test_frame = can.CanFrame{
    .can_id = 0x123,
    .len = 8,
    .pad = 0,
    .data = data,
};
_ = try can.canSend(fd, &test_frame);
debugPrint("Received {}", .{can.canRecv(fd)});
```