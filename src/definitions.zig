///! Common CAN definitions shared across backend implementations
///! (socketcan.zig, pcan.zig).
const std = @import("std");

/// The container for a CAN message.
/// Requires `extern` as the memory layout has to be strictly identical
/// to the C-version.
pub const CanFrame = extern struct {
    can_id: u32,
    len: u8,
    pad: u8 = 0,
    res0: u8 = 0,
    len8_dlc: u8 = 8,
    data: [8]u8 = undefined,
};
