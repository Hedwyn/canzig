///! Base structures for CAN signals and frames
const std = @import("std");

const Type = std.builtin.Type;
const StructErrors = error{
    NotByteAligned,
    DecodeOverflow,
    NotImplemented,
};

pub fn assertInteger(target_type: std.builtin.Type) void {
    switch (target_type) {
        .Int() => return,
        else => unreachable,
    }
}

pub const CanSignal = struct {
    position: usize,
    length: usize,
    signed: bool = false,
    scale: f64 = 1.0,
    offset: f64 = 0.0,
    name: []const u8,

    pub fn getMask(comptime self: CanSignal) usize {
        return ((1 << self.length) - 1);
    }

    pub fn getMaskShifted(comptime self: CanSignal) usize {
        return ((1 << self.length) - 1) << self.position;
    }

    pub fn getMaxAs(
        comptime self: CanSignal,
        comptime T: type,
    ) T {
        return comptime blk: {
            const exp = if (self.signed) (self.length - 1) else self.length;
            const raw_max: i128 = (1 << exp) - 1;

            if (self.isFloat()) {
                switch (@typeInfo(T)) {
                    .float => {},
                    else => @compileError("Signal is float, cannot get maximum as non-float type"),
                }
                const raw_max_as_float: f64 = @floatFromInt(raw_max);
                break :blk @as(T, self.applyScaling(raw_max_as_float));
            }
            break :blk @as(T, raw_max);
        };
    }

    pub inline fn applyScaling(self: CanSignal, value: f64) f64 {
        return value * self.scale + self.offset;
    }

    pub inline fn deapplyScaling(self: CanSignal, value: f64) f64 {
        return (value - self.offset) / self.scale;
    }

    pub fn isInteger(self: CanSignal) bool {
        return (self.scale == 1.0 and self.offset == 0.0);
    }

    pub fn isFloat(self: CanSignal) bool {
        return (self.scale != 1.0 or self.offset != 0.0);
    }

    /// Returns the type we should use to store the signal
    pub fn getType(comptime self: CanSignal) type {
        if (self.isFloat()) {
            return f64;
        }
        if (self.signed) {
            return switch (self.length) {
                0...16 => i16,
                17...32 => i32,
                33...64 => i64,
                else => @compileError("CAN max signal size is 64 bits"),
            };
        }
        return switch (self.length) {
            0...16 => u16,
            17...32 => u32,
            33...64 => u64,
            else => @compileError("CAN max signal size is 64 bits"),
        };
    }
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

pub fn CanFrame(
    comptime msg_name: []const u8,
    comptime msg_id: u32,
    comptime signals: []CanSignal,
) type {
    return struct {
        // return struct {
        comptime signals: []CanSignal = signals,

        const Self = @This();
        const _size = get_total_byte_size(signals) catch unreachable;

        pub inline fn get_byte_size(_: Self) usize {
            return _size;
        }
        const Container = Self.buildContainer();
        const name = msg_name;
        const id = msg_id;

        /// Builds a struct type out of the message definition
        pub fn buildContainer() type {
            var field_names: [signals.len + 1][:0]const u8 = undefined;
            var field_types: [signals.len + 1]type = undefined;
            var field_attrs: [signals.len + 1]Type.StructField.Attributes = undefined;
            inline for (0.., signals) |i, signal| {
                const field_type = signal.getType();
                field_names[i] = @ptrCast(signal.name);
                field_types[i] = field_type;
                field_attrs[i] = .{ .@"align" = @alignOf(field_type) };
            }
            field_names[signals.len] = "frame";
            field_types[signals.len] = type;
            field_attrs[signals.len] = .{
                .@"comptime" = true,
                .@"align" = @alignOf(type),
                .default_value_ptr = &Self,
            };

            return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
        }

        pub fn decode(data: u64, container: anytype) StructErrors!void {
            // const bitsize = _size * 8;
            inline for (0..signals.len) |i| {
                const signal = comptime signals[i];
                const signal_mask = ((1 << signal.length) - 1) << signal.position;
                const signal_data = (data & signal_mask) >> signal.position;

                const T = @TypeOf(@field(container, signal.name));
                // applying scale offset if necessary
                if (comptime signal.isFloat()) {
                    const float_value: f64 = @floatFromInt(signal_data);
                    const scaled_value = float_value * signal.scale + signal.offset;
                    @field(container, signal.name) = @floatCast(scaled_value);
                } else {
                    const casted_value = std.math.cast(T, signal_data) orelse return StructErrors.DecodeOverflow;
                    @field(container, signal.name) = casted_value;
                }
            }
        }

        pub fn decodeNew(data: u64, comptime T: type) StructErrors!T {
            // const bitsize = _size * 8;
            var container: T = undefined;
            try decode(data, &container);
            return container;
        }

        pub fn encode(container: anytype) StructErrors!u64 {
            var data: u64 = 0;

            inline for (0..signals.len) |i| {
                const signal = comptime signals[i];
                // const T = @TypeOf(@field(container, signal.name));
                const mask = comptime signal.getMask();

                // handle float and integer values differently
                if (comptime signal.isFloat()) {
                    const value: f64 = @field(container, signal.name);
                    const scaled_value = (value - signal.offset) / signal.scale;
                    const rounded_value: u64 = @intFromFloat(@round(scaled_value));
                    data += (rounded_value & mask) << signal.position;
                } else {
                    const value: u64 = @field(container, signal.name);
                    data += (value & mask) << signal.position;
                }
            }
            return data;
        }
    };
}

/// A union containing every possible message from a database
/// `frames` should be created by CanFrame(..)
pub fn AnyMessage(comptime frames: []const type) type {
    var union_names: [frames.len][:0]const u8 = undefined;
    var union_types: [frames.len]type = undefined;
    var union_attrs: [frames.len]Type.UnionField.Attributes = undefined;
    var tag_names: [frames.len][:0]const u8 = undefined;
    var tag_values: [frames.len]u16 = undefined;
    @setEvalBranchQuota(10_000);

    inline for (0.., frames) |i, frame| {
        union_names[i] = @ptrCast(frame.name);
        union_types[i] = frame.Container;
        union_attrs[i] = .{ .@"align" = 8 };

        tag_names[i] = @ptrCast(frame.name);
        tag_values[i] = i;
    }
    const tag_type = @Enum(u16, .exhaustive, &tag_names, &tag_values);
    return @Union(.auto, tag_type, &union_names, &union_types, &union_attrs);
}

pub fn Channel(db_name: []const u8, comptime frames: []const type) type {
    return struct {
        const name = db_name;
        const Message = AnyMessage(frames);

        pub fn decode(can_id: u32, data: u64) StructErrors!Message {
            inline for (frames) |frame| {
                if (frame.id == can_id) {
                    return @unionInit(
                        Message,
                        frame.name,
                        try frame.decodeNew(
                            data,
                            frame.Container,
                        ),
                    );
                }
            }
            @panic("No decoder found !");
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

test "get mask" {
    const signal = CanSignal{
        .length = 16,
        .position = 16,
        .name = "TestSignal",
    };
    // try std.testing.expectEqual(signal.getMask(), 0x00FF0000);
    try std.testing.expectEqual(0xFFFF0000, signal.getMaskShifted());
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

test "get max as [int]" {
    const int_signal = CanSignal{
        .length = 16,
        .position = 16,
        .name = "TestSignal",
        .signed = false,
    };
    try std.testing.expectEqual(65535, int_signal.getMaxAs(u16));
    try std.testing.expectEqual(65535, int_signal.getMaxAs(i32));
    try std.testing.expectEqual(65535, int_signal.getMaxAs(u32));
    try std.testing.expectEqual(65535, int_signal.getMaxAs(i64));
}

test "get max as [float]" {
    const int_signal = CanSignal{
        .length = 16,
        .position = 16,
        .name = "TestSignal",
        .scale = 0.5,
        .offset = 100.0,
        .signed = false,
    };
    try std.testing.expectEqual(32867.5, int_signal.getMaxAs(f64));
    try std.testing.expectEqual(32867.5, int_signal.getMaxAs(f32));
}

test "get type" {
    const Param = struct { length: usize, signed: bool, expects: type };
    const parameters = comptime [_]Param{
        // signed
        .{ .length = 8, .signed = false, .expects = u16 },
        .{ .length = 15, .signed = false, .expects = u16 },
        .{ .length = 16, .signed = false, .expects = u16 },
        .{ .length = 17, .signed = false, .expects = u32 },
        .{ .length = 32, .signed = false, .expects = u32 },
        .{ .length = 33, .signed = false, .expects = u64 },

        // unsigned
        .{ .length = 8, .signed = true, .expects = i16 },
        .{ .length = 15, .signed = true, .expects = i16 },
        .{ .length = 16, .signed = true, .expects = i16 },
        .{ .length = 17, .signed = true, .expects = i32 },
        .{ .length = 32, .signed = true, .expects = i32 },
        .{ .length = 33, .signed = true, .expects = i64 },
    };

    inline for (parameters) |param| {
        const int_signal = CanSignal{
            .length = param.length,
            .position = 0,
            .name = "TestSignal",
            .signed = param.signed,
        };
        std.testing.expectEqual(param.expects, int_signal.getType()) catch |e| {
            return e;
        };
    }
}

test "init message" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "TestSignal",
    }};
    const MyMessage = CanFrame("", 0, @constCast(&signal_array));
    _ = MyMessage;
}

test "any message" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "test_signal",
    }};
    const MyMessage = CanFrame("msg1", 0, @constCast(&signal_array));
    const MessageList = &.{MyMessage};
    const any_msg = AnyMessage(MessageList);
    const db_msg = any_msg{ .msg1 = .{ .test_signal = 42 } };
    try std.testing.expectEqual(42, db_msg.msg1.test_signal);
}

test "decode message" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "test_signal",
    }};
    const test_data: u64 = 0x42;
    const MyMessage = CanFrame("", 0, @constCast(&signal_array));
    const Container = struct { test_signal: u8 };
    var container: Container = undefined;
    try MyMessage.decode(test_data, &container);
    try std.testing.expectEqual(container.test_signal, 0x42);
}

test "message container" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "test_signal",
    }};
    const test_data: u64 = 0x42;
    const MyMessage = CanFrame("", 0, @constCast(&signal_array));
    const Container = struct { test_signal: u8 };
    var container: Container = undefined;
    try MyMessage.decode(test_data, &container);
    try std.testing.expectEqual(container.test_signal, 0x42);
}

test "encode message" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "test_signal",
    }};
    // const test_data: u64 = 0x42;
    const MyMessage = CanFrame("", 0, @constCast(&signal_array));
    const Container = struct { test_signal: u8 };
    const container: Container = .{ .test_signal = 42 };
    const data = try MyMessage.encode(container);
    _ = data;
    // try my_message.decode(test_data, &container);
    // try std.testing.expectEqual(container.test_signal, 0x42);
}

test "decode float message" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .scale = 0.5,
        .offset = 1.5,
        .name = "test_signal",
    }};
    const test_data: u64 = 17;
    const MyMessage = CanFrame("", 0, @constCast(&signal_array));
    // const Container = struct { test_signal: f32 };
    var container: MyMessage.Container = undefined;
    try MyMessage.decode(test_data, &container);
    try std.testing.expectEqual(@TypeOf(container.test_signal), f64);
    try std.testing.expectEqual(
        10.0,
        container.test_signal,
    );
}

test "database decoder single msg" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "test_signal",
    }};
    const MyMessage = CanFrame("msg1", 123456, @constCast(&signal_array));
    const MessageList = &.{MyMessage};
    const TestDatabase = Channel("TestDb", MessageList);
    const decoded = try TestDatabase.decode(123456, 42);
    try std.testing.expectEqual(42, decoded.msg1.test_signal);
}

test "database decoder many msg" {
    const signal_array: [1]CanSignal = comptime .{.{
        .length = 8,
        .position = 0,
        .name = "test_signal",
    }};
    const N = 1000;
    comptime var _MessageList: [N]type = undefined;

    inline for (0.._MessageList.len) |i| {
        _MessageList[i] = CanFrame(
            std.fmt.comptimePrint("msg{d}", .{i}),
            i,
            @constCast(&signal_array),
        );
    }
    const MessageList = _MessageList;
    const TestDatabase = Channel("TestDb", MessageList[0..N]);
    const decoded = try TestDatabase.decode(123, 42);
    try std.testing.expectEqual(42, decoded.msg123.test_signal);
}
