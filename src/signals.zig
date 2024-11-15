///! Base structures for CAN signals and frames
const std = @import("std");

const StructErrors = error{
    NotByteAligned,
    Overflow,
};

pub fn assertInteger(target_type: std.builtin.Type) void {
    switch (target_type) {
        .Int() => return,
        else => unreachable,
    }
}

const CanSignal = struct {
    position: usize,
    length: usize,
    scale: f64 = 1.0,
    offset: f64 = 0.0,
    name: []const u8,
};

pub fn get_total_byte_size(signals: []CanSignal) StructErrors!usize {
    var ctr: usize = 0;
    for (signals) |signal| {
        ctr += signal.length;
    }
    if (ctr % 8 != 0) {
        return StructErrors.NotByteAligned;
    }
    return @divExact(ctr, 8);
}

pub fn CanFrame(comptime signals: []CanSignal) type {
    return struct {
        name: []const u8,
        comptime signals: []CanSignal = signals,

        const Self = @This();
        const _size = get_total_byte_size(signals) catch unreachable;

        pub inline fn get_byte_size(_: Self) usize {
            return _size;
        }

        pub fn decode(self: Self, data: u64, container: anytype) void {
            // const bitsize = _size * 8;
            inline for (0..signals.len) |i| {
                const signal = comptime self.signals[i];
                const signal_mask = ((1 << signal.length) - 1) << signal.position;
                const signal_data = (data & signal_mask) >> signal.position;
                const T = @TypeOf(@field(container, signal.name));
                @field(container, signal.name) = @as(T, @truncate(signal_data));
            }
        }
    };
}

test "init signal" {
    const signal = CanSignal{
        .length = 8,
        .position = 0,
        .name = "TestSignal",
    };
    _ = signal;
}

test "get signals size" {
    const signal_count = 8;
    var signal_array: [signal_count]CanSignal = undefined;
    for (0..signal_count) |i| {
        signal_array[i] = .{
            .length = 8,
            .position = 0,
            .name = "TestSignal",
        };
    }
    try std.testing.expectEqual(8, try get_total_byte_size(&signal_array));
}

test "get signals size not aligned" {
    const signal_count = 7;
    var signal_array: [signal_count]CanSignal = undefined;
    for (0..signal_count) |i| {
        signal_array[i] = .{
            .length = 7,
            .position = 0,
            .name = "TestSignal",
        };
    }
    try std.testing.expectEqual(StructErrors.NotByteAligned, get_total_byte_size(&signal_array));
}

test "init message" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "TestSignal",
    }};
    const MyMessage = CanFrame(@constCast(&signal_array));
    const my_message: MyMessage = .{ .name = "my_message" };
    _ = my_message;
}

test "decode message" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "test_signal",
    }};
    const test_data: u64 = 0x42;
    const MyMessage = CanFrame(@constCast(&signal_array));
    const my_message: MyMessage = .{ .name = "my_message" };
    const Container = struct { test_signal: u8 };
    var container: Container = undefined;
    my_message.decode(test_data, &container);
    try std.testing.expectEqual(container.test_signal, 0x42);
}