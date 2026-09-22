///! PCAN interface
///! Adapter on top of the PCAN-Basic API (PCANBasic.dll on Windows,
///! libpcanbasic.so on Linux) exposing the same open/close/send/recv
///! primitives as socketcan.zig, for use with PEAK-System PCAN-USB devices.
///!
///! Reference: PEAK-System's PCAN-Basic API (PCANBasic.h).
///!
///! Requires the consuming module/executable to be built with
///! `.link_libc = true`. On Linux this makes `std.DynLib` resolve to the
///! real `dlopen`-backed implementation, which correctly pulls in
///! libpcanbasic.so's own dependencies (libc, pthread, ...) - the
///! alternative, dependency-unaware ELF loader silently crashes the moment
///! CAN_Initialize/CAN_Read/CAN_Write call into libc. Linking libc also
///! provides `nanosleep`, used to poll the receive queue. Verified against
///! a real PCAN-USB adapter over the PEAK Linux driver + libpcanbasic.so.
const std = @import("std");
const builtin = @import("builtin");

// useful aliases
const debugPrint = std.log.debug;

const is_windows = builtin.os.tag == .windows;

/// The calling convention used by the PCAN-Basic API functions.
/// On Windows the API is declared `__stdcall`; everywhere else it is a
/// plain C shared library.
const cc: std.builtin.CallingConvention = if (is_windows) .winapi else .c;

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(cc) void;

/// Blocks the calling thread for `ms` milliseconds. Used while polling the
/// PCAN receive queue. `std.Thread.sleep` requires threading an `Io`
/// instance through in this Zig version, which would leak into this
/// module's otherwise synchronous, socketcan.zig-like API, so we call the
/// platform's blocking sleep primitive directly instead.
fn sleepMs(ms: u32) void {
    if (is_windows) {
        Sleep(ms);
    } else {
        const req: std.c.timespec = .{ .sec = 0, .nsec = @intCast(@as(i64, ms) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&req, null);
    }
}

/// Can-related errors
const CanError = error{
    SendFailed,
    ReadFailed,
    InterfaceNotFound,
    LibraryLoadFailed,
    SymbolNotFound,
    InitializationFailed,
};

// ------------------------------------------------------------------
// PCAN-Basic raw types (see PCANBasic.h)
// ------------------------------------------------------------------
pub const TPCANHandle = u16;
pub const TPCANStatus = u32;
pub const TPCANParameter = u8;
pub const TPCANMessageType = u8;
pub const TPCANType = u8;
pub const TPCANBaudrate = u16;

/// Represents a PCAN message, as read/written through CAN_Read/CAN_Write.
/// Requires `extern` as the memory layout has to be strictly identical
/// to the C-version.
pub const TPCANMsg = extern struct {
    id: u32,
    msgtype: TPCANMessageType,
    len: u8,
    data: [8]u8 = @splat(0),
};

/// Timestamp of a received PCAN message.
/// Requires `extern` as the memory layout has to be strictly identical
/// to the C-version.
pub const TPCANTimestamp = extern struct {
    millis: u32,
    millis_overflow: u16,
    micros: u16,
};

// PCAN status/error codes (subset actually used here)
const pcan_error_ok: TPCANStatus = 0x00000;
const pcan_error_qrcvempty: TPCANStatus = 0x00020;

// PCAN parameters
const pcan_allow_error_frames: TPCANParameter = 0x20;
const pcan_parameter_on: u32 = 0x01;

// PCAN message types
const pcan_message_standard: TPCANMessageType = 0x00;
const pcan_message_rtr: TPCANMessageType = 0x01;
const pcan_message_extended: TPCANMessageType = 0x02;

// SocketCAN-style flag bits packed into `CanFrame.can_id`, kept identical to
// the Linux SocketCAN ABI so that frames built for socketcan.zig can be
// reused as-is with this module. Exposed for callers building `CanFrame`
// values directly (see examples/pcan_send.zig).
pub const can_eff_flag: u32 = 0x80000000;
pub const can_rtr_flag: u32 = 0x40000000;
pub const can_eff_mask: u32 = 0x1FFFFFFF;
pub const can_sff_mask: u32 = 0x000007FF;

/// The container for a CAN message.
/// Mirrors socketcan.zig's `CanFrame` field-for-field so both modules can
/// be used interchangeably by client code.
pub const CanFrame = extern struct {
    can_id: u32,
    len: u8,
    pad: u8 = 0,
    res0: u8 = 0,
    len8_dlc: u8 = 8,
    data: [8]u8 = undefined,
};

// ------------------------------------------------------------------
// Dynamic loading of the PCAN-Basic library
// ------------------------------------------------------------------

/// Minimal Windows dynamic-library loader, mirroring the subset of
/// `std.DynLib`'s API that this module needs. `std.DynLib` itself does not
/// support Windows at the time of writing, so we talk to kernel32 directly.
///
/// Uses `LoadLibraryExW` with `LOAD_LIBRARY_SEARCH_DEFAULT_DIRS` rather than
/// `LoadLibraryA`/`LoadLibraryW`: the latter's default search order includes
/// the process's current working directory, which is a DLL search-order
/// hijacking vector. Restricting the search to the application directory,
/// System32 and directories registered via `AddDllDirectory` avoids that.
const WindowsDynLib = struct {
    handle: HMODULE,

    const HMODULE = *anyopaque;
    const FARPROC = *anyopaque;
    const load_library_search_default_dirs: u32 = 0x1000;

    extern "kernel32" fn LoadLibraryExW(
        lpLibFileName: [*:0]const u16,
        hFile: ?*anyopaque,
        dwFlags: u32,
    ) callconv(cc) ?HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(cc) ?FARPROC;
    extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(cc) i32;
    extern "kernel32" fn GetLastError() callconv(cc) u32;

    pub fn open(path: []const u8) !WindowsDynLib {
        var path_utf16: [std.fs.max_path_bytes:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&path_utf16, path) catch return CanError.LibraryLoadFailed;
        path_utf16[n] = 0;

        const handle = LoadLibraryExW(
            @ptrCast(path_utf16[0..n].ptr),
            null,
            load_library_search_default_dirs,
        ) orelse {
            debugPrint("LoadLibraryExW({s}) failed with error {}", .{ path, GetLastError() });
            return CanError.LibraryLoadFailed;
        };
        return .{ .handle = handle };
    }

    pub fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        const addr = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @as(T, @ptrCast(@alignCast(addr)));
    }

    pub fn close(self: *WindowsDynLib) void {
        _ = FreeLibrary(self.handle);
        self.* = undefined;
    }
};

const Lib = if (is_windows) WindowsDynLib else std.DynLib;

const lib_search_paths = if (is_windows)
    [_][]const u8{"PCANBasic.dll"}
else
    [_][]const u8{
        "libpcanbasic.so",
        "/usr/lib/libpcanbasic.so",
        "/usr/local/lib/libpcanbasic.so",
    };

fn loadLib() CanError!Lib {
    for (lib_search_paths) |path| {
        if (Lib.open(path)) |lib| {
            return lib;
        } else |_| {}
    }
    return CanError.LibraryLoadFailed;
}

fn lookupSymbol(lib: *Lib, comptime T: type, comptime name: [:0]const u8) CanError!T {
    return lib.lookup(T, name) orelse CanError.SymbolNotFound;
}

// ------------------------------------------------------------------
// PCAN-Basic function signatures (see PCANBasic.h)
// ------------------------------------------------------------------
const InitializeFn = *const fn (
    channel: TPCANHandle,
    btr0btr1: TPCANBaudrate,
    hw_type: TPCANType,
    io_port: u32,
    interrupt: u16,
) callconv(cc) TPCANStatus;
const UninitializeFn = *const fn (channel: TPCANHandle) callconv(cc) TPCANStatus;
const ResetFn = *const fn (channel: TPCANHandle) callconv(cc) TPCANStatus;
const GetStatusFn = *const fn (channel: TPCANHandle) callconv(cc) TPCANStatus;
const ReadFn = *const fn (channel: TPCANHandle, msg: *TPCANMsg, timestamp: *TPCANTimestamp) callconv(cc) TPCANStatus;
const WriteFn = *const fn (channel: TPCANHandle, msg: *const TPCANMsg) callconv(cc) TPCANStatus;
const SetValueFn = *const fn (channel: TPCANHandle, parameter: TPCANParameter, buffer: *anyopaque, buffer_len: u32) callconv(cc) TPCANStatus;
const GetErrorTextFn = *const fn (err: TPCANStatus, language: u16, buffer: [*]u8) callconv(cc) TPCANStatus;

/// Handle onto an initialized PCAN channel.
/// Analogous to socketcan.zig's `socket_t` fd, but heavier (it owns the
/// loaded library and its resolved function pointers), so it is passed
/// around by pointer rather than by value.
pub const PcanHandle = struct {
    lib: Lib,
    channel: TPCANHandle,
    initialize_fn: InitializeFn,
    uninitialize_fn: UninitializeFn,
    reset_fn: ResetFn,
    get_status_fn: GetStatusFn,
    read_fn: ReadFn,
    write_fn: WriteFn,
    set_value_fn: SetValueFn,
    get_error_text_fn: GetErrorTextFn,
};

// Known PCAN-USB channel names, as defined by PCAN-Basic (PCANBasic.h).
const PcanChannelEntry = struct { name: []const u8, handle: TPCANHandle };
const pcan_channel_names = [_]PcanChannelEntry{
    .{ .name = "PCAN_NONEBUS", .handle = 0x00 },
    .{ .name = "PCAN_USBBUS1", .handle = 0x51 },
    .{ .name = "PCAN_USBBUS2", .handle = 0x52 },
    .{ .name = "PCAN_USBBUS3", .handle = 0x53 },
    .{ .name = "PCAN_USBBUS4", .handle = 0x54 },
    .{ .name = "PCAN_USBBUS5", .handle = 0x55 },
    .{ .name = "PCAN_USBBUS6", .handle = 0x56 },
    .{ .name = "PCAN_USBBUS7", .handle = 0x57 },
    .{ .name = "PCAN_USBBUS8", .handle = 0x58 },
    .{ .name = "PCAN_USBBUS9", .handle = 0x509 },
    .{ .name = "PCAN_USBBUS10", .handle = 0x50A },
    .{ .name = "PCAN_USBBUS11", .handle = 0x50B },
    .{ .name = "PCAN_USBBUS12", .handle = 0x50C },
    .{ .name = "PCAN_USBBUS13", .handle = 0x50D },
    .{ .name = "PCAN_USBBUS14", .handle = 0x50E },
    .{ .name = "PCAN_USBBUS15", .handle = 0x50F },
    .{ .name = "PCAN_USBBUS16", .handle = 0x510 },
};

/// Resolves a channel name (e.g. "PCAN_USBBUS1") to its PCAN-Basic handle.
/// Also accepts a raw numeric handle (e.g. "0x51") for advanced use.
fn channelFromName(name: []const u8) CanError!TPCANHandle {
    for (pcan_channel_names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.handle;
        }
    }
    return std.fmt.parseInt(TPCANHandle, name, 0) catch CanError.InterfaceNotFound;
}

// BTR0BTR1 codes for the standard bitrates, as defined by PCAN-Basic.
const BitrateEntry = struct { bitrate: u32, code: TPCANBaudrate };
const pcan_bitrates = [_]BitrateEntry{
    .{ .bitrate = 1_000_000, .code = 0x0014 },
    .{ .bitrate = 800_000, .code = 0x0016 },
    .{ .bitrate = 500_000, .code = 0x001C },
    .{ .bitrate = 250_000, .code = 0x011C },
    .{ .bitrate = 125_000, .code = 0x031C },
    .{ .bitrate = 100_000, .code = 0x432F },
    .{ .bitrate = 95_000, .code = 0xC34E },
    .{ .bitrate = 83_000, .code = 0x852B },
    .{ .bitrate = 50_000, .code = 0x472F },
    .{ .bitrate = 47_000, .code = 0x1414 },
    .{ .bitrate = 33_000, .code = 0x8B2F },
    .{ .bitrate = 20_000, .code = 0x532F },
    .{ .bitrate = 10_000, .code = 0x672F },
    .{ .bitrate = 5_000, .code = 0x7F7F },
};
const pcan_baud_500k: TPCANBaudrate = 0x001C;

/// Maps a bitrate in bit/s to its PCAN BTR0BTR1 code.
/// Falls back to 500 kbit/s if the bitrate is not one of the standard values.
fn pcanBaudrate(bitrate: u32) TPCANBaudrate {
    for (pcan_bitrates) |entry| {
        if (entry.bitrate == bitrate) {
            return entry.code;
        }
    }
    return pcan_baud_500k;
}

/// Opens and initializes a PCAN channel (e.g. "PCAN_USBBUS1") at the given
/// bitrate (in bit/s). Loads the PCAN-Basic library (PCANBasic.dll on
/// Windows, libpcanbasic.so on Linux) and resolves the functions needed to
/// operate the channel.
/// Returns CanError on failure.
pub fn openPcan(channel_name: []const u8, bitrate: u32) !PcanHandle {
    var lib = try loadLib();
    errdefer lib.close();

    const channel = try channelFromName(channel_name);

    const initialize_fn = try lookupSymbol(&lib, InitializeFn, "CAN_Initialize");
    const uninitialize_fn = try lookupSymbol(&lib, UninitializeFn, "CAN_Uninitialize");
    const reset_fn = try lookupSymbol(&lib, ResetFn, "CAN_Reset");
    const get_status_fn = try lookupSymbol(&lib, GetStatusFn, "CAN_GetStatus");
    const read_fn = try lookupSymbol(&lib, ReadFn, "CAN_Read");
    const write_fn = try lookupSymbol(&lib, WriteFn, "CAN_Write");
    const set_value_fn = try lookupSymbol(&lib, SetValueFn, "CAN_SetValue");
    const get_error_text_fn = try lookupSymbol(&lib, GetErrorTextFn, "CAN_GetErrorText");

    const btr0btr1 = pcanBaudrate(bitrate);
    const init_status = initialize_fn(channel, btr0btr1, 0, 0, 0);
    if (init_status != pcan_error_ok) {
        debugPrint("PCAN CAN_Initialize failed for channel 0x{x} with status 0x{x}", .{ channel, init_status });
        return CanError.InitializationFailed;
    }
    debugPrint("Initialized PCAN channel 0x{x} at {} bit/s", .{ channel, bitrate });

    var handle = PcanHandle{
        .lib = lib,
        .channel = channel,
        .initialize_fn = initialize_fn,
        .uninitialize_fn = uninitialize_fn,
        .reset_fn = reset_fn,
        .get_status_fn = get_status_fn,
        .read_fn = read_fn,
        .write_fn = write_fn,
        .set_value_fn = set_value_fn,
        .get_error_text_fn = get_error_text_fn,
    };

    // Report bus errors as (pseudo) frames rather than only surfacing them
    // through CAN_GetStatus.
    var allow_error_frames: u32 = pcan_parameter_on;
    _ = handle.set_value_fn(handle.channel, pcan_allow_error_frames, @ptrCast(&allow_error_frames), @sizeOf(u32));

    return handle;
}

pub fn closePcan(handle: *PcanHandle) void {
    _ = handle.uninitialize_fn(handle.channel);
    handle.lib.close();
}

pub fn canSend(handle: *PcanHandle, frame: *const CanFrame) CanError!usize {
    const is_extended = (frame.can_id & can_eff_flag) != 0;
    const is_rtr = (frame.can_id & can_rtr_flag) != 0;
    const raw_id = frame.can_id & (if (is_extended) can_eff_mask else can_sff_mask);

    var msgtype: TPCANMessageType = if (is_extended) pcan_message_extended else pcan_message_standard;
    if (is_rtr) {
        msgtype |= pcan_message_rtr;
    }

    const msg = TPCANMsg{
        .id = raw_id,
        .msgtype = msgtype,
        .len = frame.len,
        .data = frame.data,
    };

    const status = handle.write_fn(handle.channel, &msg);
    if (status != pcan_error_ok) {
        return CanError.SendFailed;
    }
    return frame.len;
}

/// Receives a message from the CAN bus.
/// Waits forever if nothing is available (polls the PCAN receive queue),
/// matching socketcan.zig's `canRecv` semantics.
pub fn canRecv(handle: *PcanHandle) CanFrame {
    var msg: TPCANMsg = undefined;
    var timestamp: TPCANTimestamp = undefined;

    while (true) {
        const status = handle.read_fn(handle.channel, &msg, &timestamp);
        if (status == pcan_error_ok) {
            break;
        }
        if (status != pcan_error_qrcvempty) {
            debugPrint("PCAN CAN_Read reported an error: status 0x{x}", .{status});
        }
        sleepMs(1);
    }

    var can_id: u32 = msg.id;
    if ((msg.msgtype & pcan_message_extended) != 0) {
        can_id |= can_eff_flag;
    }
    if ((msg.msgtype & pcan_message_rtr) != 0) {
        can_id |= can_rtr_flag;
    }

    return CanFrame{
        .can_id = can_id,
        .len = msg.len,
        .data = msg.data,
    };
}

/// Queries the current status of the PCAN channel (see PCAN_ERROR_* codes).
pub fn getStatus(handle: *PcanHandle) TPCANStatus {
    return handle.get_status_fn(handle.channel);
}
