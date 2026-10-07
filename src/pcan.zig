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
const definitions = @import("definitions");

// useful aliases
const debugPrint = std.log.debug;

const is_windows = builtin.os.tag == .windows;

/// The calling convention used by the PCAN-Basic API functions.
/// On Windows the API is declared `__stdcall`; everywhere else it is a
/// plain C shared library.
const cc: std.builtin.CallingConvention = if (is_windows) .winapi else .c;

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(cc) void;

/// Opaque Win32 handle, used for the PCAN_RECEIVE_EVENT event object below.
const HANDLE = *anyopaque;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: i32,
    bInitialState: i32,
    lpName: ?[*:0]const u16,
) callconv(cc) ?HANDLE;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(cc) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(cc) u32;

/// Win32 FILETIME: 100ns intervals since 1601-01-01 UTC. Used only to read
/// the wall clock for timestamp calibration - see `wallClockNs`.
const FILETIME = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetSystemTimePreciseAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(cc) void;

// Win32 WaitForSingleObject result codes actually used here (winbase.h).
const wait_object_0: u32 = 0x00000000;
const wait_timeout: u32 = 0x00000102;

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

/// Current wall-clock time as ns since the Unix epoch. Used only for
/// timestamp calibration (see `timestampToNs`) -
/// like `sleepMs` above, this calls the platform's clock primitive directly
/// rather than going through `std.time`/`std.Io`.
fn wallClockNs() i128 {
    if (is_windows) {
        var file_time: FILETIME = undefined;
        GetSystemTimePreciseAsFileTime(&file_time);
        const filetime_100ns: i128 = (@as(i128, file_time.high) << 32) | file_time.low;
        // FILETIME epoch (1601-01-01) is 11644473600s before the Unix epoch.
        const unix_epoch_offset_100ns: i128 = 116444736000000000;
        return (filetime_100ns - unix_epoch_offset_100ns) * 100;
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
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
// Bus-state codes: `CAN_Read` reports bus error conditions through its
// return value, independently of `pcan_allow_error_frames`. They describe
// the bus, not a failure of the read itself - see `readMsg`.
const pcan_error_buslight: TPCANStatus = 0x00004;
const pcan_error_busheavy: TPCANStatus = 0x00008;
const pcan_error_buspassive: TPCANStatus = 0x40000;
const pcan_error_bus_warnings: TPCANStatus = pcan_error_buslight | pcan_error_busheavy | pcan_error_buspassive;

// PCAN parameters
const pcan_allow_status_frames: TPCANParameter = 0x1E;
const pcan_allow_error_frames: TPCANParameter = 0x20;
const pcan_receive_event: TPCANParameter = 0x03;
const pcan_parameter_off: u32 = 0x00;
const pcan_parameter_on: u32 = 0x01;

// PCAN message types
const pcan_message_standard: TPCANMessageType = 0x00;
const pcan_message_rtr: TPCANMessageType = 0x01;
const pcan_message_extended: TPCANMessageType = 0x02;
// Pseudo-frame markers: set instead of standard/rtr/extended when the
// "message" is actually the driver reporting a bus error or a status change
// (see `pcan_allow_error_frames` in `openPcan`), not a real CAN frame.
const pcan_message_errframe: TPCANMessageType = 0x40;
const pcan_message_status: TPCANMessageType = 0x80;
const pcan_message_pseudo_mask: TPCANMessageType = pcan_message_errframe | pcan_message_status;

// SocketCAN-style flag bits packed into `CanFrame.raw_can_id`, kept
// identical to the Linux SocketCAN ABI so that frames built for
// socketcan.zig can be reused as-is with this module. Re-exported from
// definitions.zig for callers building `CanFrame` values directly (see
// examples/pcan_send.zig).
pub const can_eff_flag = definitions.can_eff_flag;
pub const can_rtr_flag = definitions.can_rtr_flag;
pub const can_err_flag = definitions.can_err_flag;
pub const can_eff_mask = definitions.can_eff_mask;
pub const can_sff_mask = definitions.can_sff_mask;

/// The container for a CAN message.
/// Shared with socketcan.zig via definitions.zig so both modules can be
/// used interchangeably by client code.
pub const CanFrame = definitions.CanFrame;

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
const GetValueFn = *const fn (channel: TPCANHandle, parameter: TPCANParameter, buffer: *anyopaque, buffer_len: u32) callconv(cc) TPCANStatus;
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
    get_value_fn: GetValueFn,
    set_value_fn: SetValueFn,
    get_error_text_fn: GetErrorTextFn,
    /// Win32 event object registered via CAN_SetValue(PCAN_RECEIVE_EVENT),
    /// signaled by the driver whenever a frame arrives. Windows only - see
    /// `waitForReceiveEvent`. PCAN-Basic's Linux equivalent for this same
    /// parameter just hands back the underlying SocketCAN driver's fd, with
    /// no benefit over using socketcan.zig directly, so it's not bound here.
    event_handle: if (is_windows) HANDLE else void,
    /// Offset (ns) mapping the driver's `TPCANTimestamp` counter onto host
    /// wall-clock time (ns since Unix epoch), so timestamps share
    /// socketcan.zig's epoch-based format - see `timestampToNs`. The
    /// counter's origin is driver-specific (reset by `CAN_Initialize` on
    /// Linux, but counting from system start on Windows), so the offset is
    /// calibrated from the frames themselves rather than assumed.
    /// `null` until the first frame is read. There is no PCAN-Basic option
    /// to toggle the timestamp itself off: `CAN_Read` always fills it in.
    clock_offset_ns: ?i128 = null,
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
/// `allow_error_frames` controls whether bus errors and status changes are
/// delivered as (pseudo) frames, with `isError()` set (see `frameFromMsg`),
/// rather than dropped - same semantics as socketcan.zig's `openSocketCan`.
/// Returns CanError on failure.
pub fn openPcan(channel_name: []const u8, bitrate: u32, allow_error_frames: bool) !PcanHandle {
    var lib = try loadLib();
    errdefer lib.close();

    const channel = try channelFromName(channel_name);

    const initialize_fn = try lookupSymbol(&lib, InitializeFn, "CAN_Initialize");
    const uninitialize_fn = try lookupSymbol(&lib, UninitializeFn, "CAN_Uninitialize");
    const reset_fn = try lookupSymbol(&lib, ResetFn, "CAN_Reset");
    const get_status_fn = try lookupSymbol(&lib, GetStatusFn, "CAN_GetStatus");
    const read_fn = try lookupSymbol(&lib, ReadFn, "CAN_Read");
    const write_fn = try lookupSymbol(&lib, WriteFn, "CAN_Write");
    const get_value_fn = try lookupSymbol(&lib, GetValueFn, "CAN_GetValue");
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
        .get_value_fn = get_value_fn,
        .set_value_fn = set_value_fn,
        .get_error_text_fn = get_error_text_fn,
        .event_handle = if (is_windows) undefined else {},
    };

    if (is_windows) {
        // Auto-reset, initially-unsignaled event, registered with the
        // driver so it gets signaled whenever a frame lands in the receive
        // queue - see PCAN-Basic's PCAN_RECEIVE_EVENT documentation.
        var event_handle = CreateEventW(null, 0, 0, null) orelse {
            _ = handle.uninitialize_fn(handle.channel);
            return CanError.InitializationFailed;
        };
        const set_status = handle.set_value_fn(handle.channel, pcan_receive_event, @ptrCast(&event_handle), @sizeOf(HANDLE));
        if (set_status != pcan_error_ok) {
            debugPrint("PCAN CAN_SetValue(PCAN_RECEIVE_EVENT) failed with status 0x{x}", .{set_status});
            _ = CloseHandle(event_handle);
            _ = handle.uninitialize_fn(handle.channel);
            return CanError.InitializationFailed;
        }
        handle.event_handle = event_handle;
    }

    // Set explicitly both ways: PCAN-Basic delivers status frames by
    // default, which would otherwise leak through with
    // `allow_error_frames = false`.
    var error_frames_value: u32 = if (allow_error_frames) pcan_parameter_on else pcan_parameter_off;
    _ = handle.set_value_fn(handle.channel, pcan_allow_error_frames, @ptrCast(&error_frames_value), @sizeOf(u32));
    _ = handle.set_value_fn(handle.channel, pcan_allow_status_frames, @ptrCast(&error_frames_value), @sizeOf(u32));

    return handle;
}

pub fn closePcan(handle: *PcanHandle) void {
    _ = handle.uninitialize_fn(handle.channel);
    if (is_windows) {
        _ = CloseHandle(handle.event_handle);
    }
    handle.lib.close();
}

pub fn canSend(handle: *PcanHandle, frame: *const CanFrame) CanError!usize {
    const is_extended = frame.isExtended();

    var msgtype: TPCANMessageType = if (is_extended) pcan_message_extended else pcan_message_standard;
    if (frame.isRtr()) {
        msgtype |= pcan_message_rtr;
    }

    const msg = TPCANMsg{
        .id = frame.can_id(),
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

fn frameFromMsg(msg: TPCANMsg) CanFrame {
    // A bus error or status change (only possible when
    // `pcan_allow_error_frames` is on, see `openPcan`) is not a real CAN
    // frame: `msg.id` there holds a TPCANStatus error/status code, not a CAN
    // identifier, and the extended/RTR bits are meaningless. Tag it with
    // `can_err_flag` instead of letting it masquerade as an ordinary data
    // frame with a bogus id - mirrors how SocketCAN itself reports bus
    // errors as CAN_ERR_FLAG-tagged frames.
    if ((msg.msgtype & pcan_message_pseudo_mask) != 0) {
        return CanFrame{
            .raw_can_id = can_err_flag | (msg.id & can_eff_mask),
            .len = msg.len,
            .data = msg.data,
        };
    }

    var raw_can_id: u32 = msg.id;
    if ((msg.msgtype & pcan_message_extended) != 0) {
        raw_can_id |= can_eff_flag;
    }
    if ((msg.msgtype & pcan_message_rtr) != 0) {
        raw_can_id |= can_rtr_flag;
    }

    return CanFrame{
        .raw_can_id = raw_can_id,
        .len = msg.len,
        .data = msg.data,
    };
}

/// Converts a `TPCANTimestamp` (milliseconds + a 16-bit overflow counter +
/// sub-millisecond microseconds, from a driver-specific origin) into ns
/// since the Unix epoch. Must be called right after the frame is read: a
/// frame is always read after it was received, so `wall clock now - device
/// time` is an upper bound of the true offset between both clocks, and the
/// smallest one seen so far is kept as the best estimate (see
/// `PcanHandle.clock_offset_ns`). Drifts against wall-clock time over long
/// sessions (host clock vs. device oscillator) - fine for the inter-frame
/// timing this is meant to preserve, not a substitute for a precise
/// absolute clock.
fn timestampToNs(handle: *PcanHandle, timestamp: TPCANTimestamp) i128 {
    const elapsed_ms: u64 = @as(u64, timestamp.millis) + (@as(u64, timestamp.millis_overflow) << 32);
    const elapsed_ns: i128 = @as(i128, elapsed_ms) * std.time.ns_per_ms + @as(i128, timestamp.micros) * std.time.ns_per_us;
    const candidate_offset_ns = wallClockNs() - elapsed_ns;
    if (handle.clock_offset_ns == null or candidate_offset_ns < handle.clock_offset_ns.?) {
        handle.clock_offset_ns = candidate_offset_ns;
    }
    return elapsed_ns + handle.clock_offset_ns.?;
}

const RawMsg = struct { msg: TPCANMsg, timestamp: TPCANTimestamp };

/// Bounds how many consecutive bus-state reports `readMsg` skips in a single
/// call, so a bus stuck in an error condition can't make it spin forever.
const max_bus_state_reads = 8;

/// Single non-blocking `CAN_Read`. Returns `null` if the receive queue is
/// empty. Bus warnings (see `pcan_error_bus_warnings`) are logged and
/// skipped rather than failing the read: transient bus errors are expected
/// in normal operation (e.g. a node glitching the bus while resetting), and
/// frames may still be queued behind them.
fn readMsg(handle: *PcanHandle) CanError!?RawMsg {
    var raw: RawMsg = undefined;
    for (0..max_bus_state_reads) |_| {
        const status = handle.read_fn(handle.channel, &raw.msg, &raw.timestamp);
        if (status == pcan_error_ok) return raw;
        if ((status & pcan_error_qrcvempty) != 0) return null;
        if ((status & ~pcan_error_bus_warnings) != 0) {
            debugPrint("PCAN CAN_Read reported an error: status 0x{x}", .{status});
            return CanError.ReadFailed;
        }
        debugPrint("PCAN CAN_Read reported a bus warning: status 0x{x}", .{status});
    }
    return null;
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

    return frameFromMsg(msg);
}

/// Attempts a single, non-blocking read from the PCAN receive queue.
/// Returns `null` immediately if the queue is empty, without sleeping or
/// retrying - unlike `canRecv`, which polls forever. Intended to be paired
/// with `waitForReceiveEvent`: wait for the event to signal, then drain the
/// queue by calling `tryRecv` in a loop until it returns `null`, since one
/// signal can correspond to more than one queued frame.
pub fn tryRecv(handle: *PcanHandle) CanError!?CanFrame {
    const raw = try readMsg(handle) orelse return null;
    return frameFromMsg(raw.msg);
}

/// Same as `canRecv`, but also returns the frame's receive timestamp,
/// normalized to ns since the Unix epoch (see `timestampToNs`).
pub fn canRecvTimestamped(handle: *PcanHandle) definitions.TimestampedFrame {
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

    return .{
        .frame = frameFromMsg(msg),
        .timestamp = .{ .ns_since_epoch = timestampToNs(handle, timestamp) },
    };
}

/// Same as `tryRecv`, but also returns the frame's receive timestamp,
/// normalized to ns since the Unix epoch (see `timestampToNs`).
pub fn tryRecvTimestamped(handle: *PcanHandle) CanError!?definitions.TimestampedFrame {
    const raw = try readMsg(handle) orelse return null;
    return .{
        .frame = frameFromMsg(raw.msg),
        .timestamp = .{ .ns_since_epoch = timestampToNs(handle, raw.timestamp) },
    };
}

/// Waits up to `timeout_ms` milliseconds for the PCAN receive event to
/// signal. Windows only: backed by the Win32 event object registered via
/// CAN_SetValue(PCAN_RECEIVE_EVENT) in `openPcan`. Returns `true` if the
/// event signaled, `false` on timeout. On Linux, use `canRecv`/`tryRecv`
/// directly, or socketcan.zig with your own select/poll loop.
pub fn waitForReceiveEvent(handle: *PcanHandle, timeout_ms: u32) CanError!bool {
    if (!is_windows) {
        @compileError("waitForReceiveEvent is only available on Windows");
    }
    const wait_result = WaitForSingleObject(handle.event_handle, timeout_ms);
    return switch (wait_result) {
        wait_object_0 => true,
        wait_timeout => false,
        else => CanError.ReadFailed,
    };
}

/// Queries the current status of the PCAN channel (see PCAN_ERROR_* codes).
pub fn getStatus(handle: *PcanHandle) TPCANStatus {
    return handle.get_status_fn(handle.channel);
}
