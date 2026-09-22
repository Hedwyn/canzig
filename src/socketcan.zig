///! SocketCAN interface
///! Creates and binds to a SocketCAN, provides the primitives
///! to send/recv CAN messages from there
const std = @import("std");
const utils = @import("utils.zig");
const definitions = @import("definitions.zig");
const posix = std.posix;
const sys = std.posix.system;

// useful aliases
const debugPrint = std.log.debug;
const assert = std.debug.assert;

// Constants
const pf_can = 29;
const af_can = pf_can;
const sock_raw = 3;
const can_raw = 1;

// type aliases
const sa_family_t = posix.sa_family_t;
const socket_t = posix.socket_t;

// CAN ID flag bits packed into `CanFrame.can_id`, per the Linux SocketCAN
// ABI. Exposed for callers building/decoding `CanFrame` values directly
// (see examples/socketcan_send.zig, examples/socketcan_recv.zig).
pub const can_eff_flag: u32 = 0x80000000;
pub const can_rtr_flag: u32 = 0x40000000;
pub const can_eff_mask: u32 = 0x1FFFFFFF;
pub const can_sff_mask: u32 = 0x000007FF;

/// Can-related errors
const CanError = error{
    SendFailed,
    InterfaceNotFound,
    SocketCanFailure,
};

/// Opens a socketcan socket.
/// Returns the fileno if succes
/// Or CanError if failing to open the socket
pub fn openSocketCan(can_if_name: []const u8) !socket_t {
    const socket_rc = sys.socket(pf_can, sock_raw, can_raw);
    if (sys.errno(socket_rc) != .SUCCESS) {
        return CanError.SocketCanFailure;
    }
    const fd: socket_t = @intCast(socket_rc);
    debugPrint("Opened socket's fileno is {}", .{fd});
    var ifname: [16]u8 = @splat(0);
    try utils.strcpy(can_if_name, &ifname);

    var ifreq = posix.ifreq{
        .ifrn = .{ .name = ifname },
        .ifru = undefined,
    };
    const ioctl_rc = sys.ioctl(fd, sys.SIOCGIFINDEX, @intFromPtr(&ifreq));
    if (sys.errno(ioctl_rc) != .SUCCESS) {
        debugPrint("ioctl reported an error when trying to get the can interface index", .{});
        return CanError.InterfaceNotFound;
    }
    debugPrint("CAN interface index is {}", .{ifreq.ifru.ivalue});
    var can_addr: SockaddrCan = .{
        .can_ifindex = ifreq.ifru.ivalue,
    };
    const addr: *posix.sockaddr = @ptrCast(&can_addr);
    const bind_rc = sys.bind(fd, addr, @sizeOf(SockaddrCan));
    if (sys.errno(bind_rc) != .SUCCESS) {
        return CanError.SocketCanFailure;
    }
    debugPrint("Bound to socketcan successfully", .{});

    return fd;
}

pub fn closeSocketCan(fd: socket_t) void {
    _ = sys.close(fd);
}

pub fn canSend(fd: socket_t, frame: *const CanFrame) CanError!usize {
    const buf: [*]const u8 = (@ptrCast(frame));
    // TODO: consider flags
    const length = sys.sendto(
        fd,
        buf,
        @sizeOf(CanFrame),
        0,
        null,
        0,
    );
    if (length < 0) {
        return CanError.SendFailed;
    }
    return length;
}
/// Receives a message from the CAN bus
/// Waits forever if nothing is available
/// - you should run your own selectors before calling
pub fn canRecv(fd: socket_t) CanFrame {
    var _frame: CanFrame = undefined;
    const ret = sys.recvfrom(fd, @ptrCast(&_frame), @sizeOf(CanFrame), 0, null, null);

    std.debug.print("Recv returned {}\n", .{ret});
    return _frame;
}

/// The CAN address socket as defined by socketcan documentation
/// Requires `extern` as the memory layout has to be strictly identitical
/// to the C-version
const SockaddrCan = extern struct {
    can_family: sa_family_t = af_can,
    can_ifindex: i32,
};

/// The container for a CAN message
pub const CanFrame = definitions.CanFrame;
