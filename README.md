# CAN library for Zig
This package implements a thin adapter over two CAN backends:
* **SocketCAN** (`src/socketcan.zig`), shipped as part of the Linux kernel - documentation available [here](https://docs.kernel.org/networking/can.html.).
* **PCAN-Basic** (`src/pcan.zig`), for PEAK-System PCAN-USB adapters, via `PCANBasic.dll` on Windows or `libpcanbasic.so` on Linux.

This package currently only implements raw CAN communications, `isotp` or `J1939` communications are not supported yet. Each backend exposes the same 4 primitives:
* Opening a channel (`openSocketCan` / `openPcan`)
* Closing a channel (`closeSocketCan` / `closePcan`)
* Sending a message to the CAN bus (`canSend`)
* Receiving a message from the CAN bus (`canRecv`)

For the latter, selection is not baked in the reception process. You shoul run your own selection before calling receive, as it will block forever if no data is available.

`pcan.zig` needs the consuming module/executable built with `.link_libc = true` - see the doc comment at the top of that file for why.

# Installing and running
Clone this package and run `zig build run -- <your-interface-name>` (e.g., `zig build run -- can0`). Calling `zig build run` without argument will default to `vcan0`. Make sure the CAN interface is actually up on your system. <br>
The demo code will send a single message, then wait (potentially forever) for a message. You can send a message manually with `cansend` command from `can-utils`.<br><br>
Example usage is as follows:
```zig
const can = @import("socketcan.zig");
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

# Examples
`examples/` has small standalone send/recv CLI tools for each backend. They parse their arguments with the standard library's built-in argument iteration only (no CLI parsing library), and each is wired up as its own `zig build <name>` step, so extra arguments go after `--`. Build every example without running one with `zig build examples`.

## SocketCAN
Requires the interface to already be up, e.g. `sudo ip link set vcan0 up type vcan` for a virtual one, or `sudo ip link set can0 up type can bitrate 500000` for real hardware.

* `zig build socketcan_send -- <can_id_hex> <payload_hex> [interface]`
  ```
  zig build socketcan_send -- 123 0102030405060708 vcan0
  ```
* `zig build socketcan_recv -- [interface] [count]`
  ```
  zig build socketcan_recv -- vcan0
  ```
  `interface` defaults to `vcan0`; `count` (default 0) stops after that many frames, or omit it to listen until interrupted.

## PCAN
Talks to a PEAK-System PCAN-USB device through PCAN-Basic. On Linux, `libpcanbasic.so` must be reachable by the dynamic linker (e.g. via `LD_LIBRARY_PATH`); on Windows, `PCANBasic.dll` must be installed/on the search path.

* `zig build pcan_send -- <can_id_hex> <payload_hex> [channel] [bitrate]`
  ```
  zig build pcan_send -- 123 0102030405060708 PCAN_USBBUS1 500000
  ```
* `zig build pcan_recv -- [channel] [bitrate] [count]`
  ```
  zig build pcan_recv -- PCAN_USBBUS1 500000
  ```
  `channel` defaults to `PCAN_USBBUS1`, `bitrate` to `500000`.

For both SocketCAN and PCAN examples, `can_id_hex` above `0x7FF` is automatically sent/reported as a 29-bit extended frame, and `payload_hex` is 0-16 hex characters (0-8 bytes), e.g. `0102030405060708`.