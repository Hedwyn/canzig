///! SocketCAN interface
///! Creates and binds to a SocketCAN, provides the primitives
///! to send/recv CAN messages from there
const std = @import("std");
const utils = @import("utils.zig");
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
    const fd = try posix.socket(pf_can, sock_raw, can_raw);
    debugPrint("Opened socket's fileno is {}", .{fd});
    var ifname = [_]u8{0} ** 16;
    try utils.strcpy(can_if_name, &ifname);

    var ifreq = posix.ifreq{
        .ifrn = .{ .name = ifname },
        .ifru = undefined,
    };
    posix.ioctl_SIOCGIFINDEX(fd, &ifreq) catch |e| {
        debugPrint("ioctl reported {} when trying to get the can interface index", .{e});
        return CanError.InterfaceNotFound;
    };
    debugPrint("CAN interface index is {}", .{ifreq.ifru.ivalue});
    var can_addr: SockaddrCan = .{
        .can_ifindex = ifreq.ifru.ivalue,
    };
    const addr: *posix.sockaddr = @ptrCast(&can_addr);
    posix.bind(fd, addr, @sizeOf(SockaddrCan)) catch {
        return CanError.SocketCanFailure;
    };
    debugPrint("Bound to socketcan successfully", .{});

    return fd;
}

pub fn closeSocketCan(fd: socket_t) void {
    posix.close(fd);
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
/// Requires `extern` as the memory layout has to be strictly identitical
/// to the C-version
pub const CanFrame = extern struct {
    can_id: u32,
    len: u8,
    pad: u8,
    res0: u8 = 0,
    len8_dlc: u8 = 8,
    data: [8]u8 = undefined,
};
