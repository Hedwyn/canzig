///! Common CAN definitions shared across backend implementations
///! (socketcan.zig, pcan.zig).
const std = @import("std");

// CAN ID flag bits packed into `CanFrame.raw_can_id`, per the Linux
// SocketCAN ABI. socketcan.zig encodes/decodes these natively; pcan.zig
// translates them to/from PCAN-Basic's separate `TPCANMsg.msgtype` field, so
// both backends produce `CanFrame` values using this same convention.
pub const can_eff_flag: u32 = 0x80000000;
pub const can_rtr_flag: u32 = 0x40000000;
pub const can_eff_mask: u32 = 0x1FFFFFFF;
pub const can_sff_mask: u32 = 0x000007FF;

/// The container for a CAN message.
/// Requires `extern` as the memory layout has to be strictly identical
/// to the C-version.
pub const CanFrame = extern struct {
    /// Raw CAN identifier as packed on the wire: the EFF/RTR flag bits
    /// (`can_eff_flag`/`can_rtr_flag`) are ORed into the high bits alongside
    /// the actual identifier. Prefer `can_id()`/`isExtended()`/`isRtr()`
    /// over reading this directly.
    raw_can_id: u32,
    len: u8,
    pad: u8 = 0,
    res0: u8 = 0,
    len8_dlc: u8 = 8,
    data: [8]u8 = undefined,

    pub inline fn isExtended(self: CanFrame) bool {
        return (self.raw_can_id & can_eff_flag) != 0;
    }

    pub inline fn isRtr(self: CanFrame) bool {
        return (self.raw_can_id & can_rtr_flag) != 0;
    }

    /// The logical CAN identifier, with the EFF/RTR flag bits masked off.
    pub inline fn can_id(self: CanFrame) u32 {
        return self.raw_can_id & (if (self.isExtended()) can_eff_mask else can_sff_mask);
    }
};
