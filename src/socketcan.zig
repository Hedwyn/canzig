///! SocketCAN interface
///! Creates and binds to a SocketCAN, provides the primitives
///! to send/recv CAN messages from there
const std = @import("std");
const utils = @import("utils.zig");
const definitions = @import("definitions");
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

// CAN_RAW socket-level option (SOL_CAN_RAW) enabling error frame reception,
// and the mask requesting every error class (see linux/can/error.h).
const sol_can_raw = 101;
const can_raw_err_filter: u32 = 2;
const can_err_mask_all: u32 = 0x1FFFFFFF;
// SOL_CAN_RAW option asking the kernel to also deliver the frames this very
// socket sent (needs CAN_RAW_LOOPBACK, which is on by default). Such frames
// come back with MSG_CONFIRM set in the recvmsg() flags.
const can_raw_recv_own_msgs: u32 = 4;

// Alignment CMSG_DATA/CMSG_NXTHDR pad to (glibc's CMSG_ALIGN), used to walk
// the ancillary-data buffer filled in by recvmsg() - see
// `canRecvTimestamped`.
const cmsg_align = @alignOf(usize);

// type aliases
const sa_family_t = posix.sa_family_t;
const socket_t = posix.socket_t;

// CAN ID flag bits packed into `CanFrame.raw_can_id`, per the Linux
// SocketCAN ABI. Re-exported from definitions.zig for callers
// building/decoding `CanFrame` values directly (see
// examples/socketcan_send.zig, examples/socketcan_recv.zig).
pub const can_eff_flag = definitions.can_eff_flag;
pub const can_rtr_flag = definitions.can_rtr_flag;
pub const can_err_flag = definitions.can_err_flag;
pub const can_eff_mask = definitions.can_eff_mask;
pub const can_sff_mask = definitions.can_sff_mask;

pub const OpenOptions = definitions.OpenOptions;

/// Can-related errors
const CanError = error{
    SendFailed,
    InterfaceNotFound,
    SocketCanFailure,
};

/// Opens a socketcan socket.
/// See `OpenOptions` (definitions.zig) for what each option maps to;
/// `enable_timestamps` is required before calling `canRecvTimestamped` on
/// the returned socket.
/// Returns the fileno if succes
/// Or CanError if failing to open the socket
pub fn openSocketCan(can_if_name: []const u8, options: OpenOptions) !socket_t {
    const socket_rc = sys.socket(pf_can, sock_raw, can_raw);
    if (sys.errno(socket_rc) != .SUCCESS) {
        return CanError.SocketCanFailure;
    }
    const fd: socket_t = @intCast(socket_rc);
    debugPrint("Opened socket's fileno is {}", .{fd});

    if (options.allow_error_frames) {
        var err_mask: u32 = can_err_mask_all;
        const setsockopt_rc = sys.setsockopt(fd, sol_can_raw, can_raw_err_filter, @ptrCast(&err_mask), @sizeOf(u32));
        if (sys.errno(setsockopt_rc) != .SUCCESS) {
            debugPrint("setsockopt(CAN_RAW_ERR_FILTER) failed", .{});
            return CanError.SocketCanFailure;
        }
    }

    if (options.echo) {
        var one: i32 = 1;
        const setsockopt_rc = sys.setsockopt(fd, sol_can_raw, can_raw_recv_own_msgs, @ptrCast(&one), @sizeOf(i32));
        if (sys.errno(setsockopt_rc) != .SUCCESS) {
            debugPrint("setsockopt(CAN_RAW_RECV_OWN_MSGS) failed", .{});
            return CanError.SocketCanFailure;
        }
    }

    if (options.enable_timestamps) {
        var one: i32 = 1;
        const setsockopt_rc = sys.setsockopt(fd, sys.SOL.SOCKET, sys.SO.TIMESTAMPNS_OLD, @ptrCast(&one), @sizeOf(i32));
        if (sys.errno(setsockopt_rc) != .SUCCESS) {
            debugPrint("setsockopt(SO_TIMESTAMPNS) failed", .{});
            return CanError.SocketCanFailure;
        }
    }

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
    // `res0` carries library-side flags (see `can_frame_echo_flag`) but is
    // reserved on the wire, e.g. when re-sending a received echo frame.
    var wire_frame = frame.*;
    wire_frame.res0 = 0;
    const buf: [*]const u8 = (@ptrCast(&wire_frame));
    // TODO: consider flags
    // Return type differs between raw syscalls (usize, errno-encoded) and
    // libc (isize, -1 on error); `errno` decodes both.
    const sendto_rc = sys.sendto(
        fd,
        buf,
        @sizeOf(CanFrame),
        0,
        null,
        0,
    );
    if (sys.errno(sendto_rc) != .SUCCESS) {
        return CanError.SendFailed;
    }
    return @intCast(sendto_rc);
}
/// Receives a message from the CAN bus
/// Waits forever if nothing is available
/// - you should run your own selectors before calling
pub fn canRecv(fd: socket_t) CanFrame {
    var frame: CanFrame = undefined;
    _ = recvFrame(fd, &frame, null);
    return frame;
}

/// Receives one frame with `recvmsg` rather than `recvfrom`, since only the
/// former reports the `MSG_CONFIRM` flag identifying echo frames (see
/// `OpenOptions.echo`), which is then recorded via `can_frame_echo_flag`.
/// `control_buf`, if given, receives the ancillary data (timestamps).
fn recvFrame(fd: socket_t, frame: *CanFrame, control_buf: ?[]align(@alignOf(sys.cmsghdr)) u8) sys.msghdr {
    var iov = [_]posix.iovec{.{
        .base = @ptrCast(frame),
        .len = @sizeOf(CanFrame),
    }};
    var msg = sys.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = if (control_buf) |buf| buf.ptr else null,
        .controllen = if (control_buf) |buf| buf.len else 0,
        .flags = 0,
    };

    _ = sys.recvmsg(fd, &msg, 0);
    frame.res0 = if ((msg.flags & sys.MSG.CONFIRM) != 0) definitions.can_frame_echo_flag else 0;
    return msg;
}

/// True if `fd` has `SO_TIMESTAMPNS` enabled (see `openSocketCan`).
fn timestampsEnabled(fd: socket_t) bool {
    var enabled: i32 = 0;
    var len: u32 = @sizeOf(i32);
    const rc = sys.getsockopt(fd, sys.SOL.SOCKET, sys.SO.TIMESTAMPNS_OLD, @ptrCast(&enabled), &len);
    return sys.errno(rc) == .SUCCESS and enabled != 0;
}

/// First `cmsghdr` in a `recvmsg`-filled ancillary-data buffer, or `null` if
/// the buffer is empty (mirrors glibc's `CMSG_FIRSTHDR`).
fn firstCmsg(msg: *const sys.msghdr) ?*const sys.cmsghdr {
    if (msg.controllen < @sizeOf(sys.cmsghdr)) return null;
    return @ptrCast(@alignCast(msg.control.?));
}

/// The `cmsghdr` following `cmsg` in the same buffer, or `null` past the
/// last one (mirrors glibc's `CMSG_NXTHDR`).
fn nextCmsg(msg: *const sys.msghdr, cmsg: *const sys.cmsghdr) ?*const sys.cmsghdr {
    const next_addr = @intFromPtr(cmsg) + std.mem.alignForward(usize, cmsg.len, cmsg_align);
    const control_end = @intFromPtr(msg.control.?) + msg.controllen;
    if (next_addr + @sizeOf(sys.cmsghdr) > control_end) return null;
    return @ptrFromInt(next_addr);
}

/// Extracts the `SCM_TIMESTAMPNS` ancillary message set by `SO_TIMESTAMPNS`
/// (see `openSocketCan`) from a `recvmsg`-filled message header.
fn recvTimestampNs(msg: *const sys.msghdr) ?i128 {
    var maybe_cmsg = firstCmsg(msg);
    while (maybe_cmsg) |cmsg| : (maybe_cmsg = nextCmsg(msg, cmsg)) {
        if (cmsg.level == sys.SOL.SOCKET and cmsg.type == sys.SO.TIMESTAMPNS_OLD) {
            const data: [*]const u8 = @as([*]const u8, @ptrCast(cmsg)) + std.mem.alignForward(usize, @sizeOf(sys.cmsghdr), cmsg_align);
            const ts: *align(1) const posix.timespec = @ptrCast(data);
            return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
        }
    }
    return null;
}

/// Same as `canRecv`, but also returns the kernel's receive timestamp for
/// the frame. Requires the socket to have been opened with
/// `enable_timestamps = true` (see `openSocketCan`).
pub fn canRecvTimestamped(fd: socket_t) definitions.TimestampedFrame {
    assert(timestampsEnabled(fd));

    var frame: CanFrame = undefined;
    var control_buf: [64]u8 align(@alignOf(sys.cmsghdr)) = undefined;
    const msg = recvFrame(fd, &frame, &control_buf);
    // `timestampsEnabled` already asserted the socket requests this
    // ancillary message, so the kernel is expected to have supplied it.
    const ns_since_epoch = recvTimestampNs(&msg) orelse unreachable;

    return .{
        .frame = frame,
        .timestamp = .{ .ns_since_epoch = ns_since_epoch },
    };
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
