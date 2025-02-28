///! Shared utilities for this package
/// String-related pritimives
const std = @import("std");
const StrError = error{
    BufferTooSmall,
};

pub fn Iterator(T: type) type {
    if (!@hasField(T, "next")) {
        @compileError("Struct passed to `Iterator` must have a `next` field");
    }
    return struct {
        head: ?*T,
        const Self = @This();

        pub fn next(self: *Self) ?*T {
            if (self.head) |head| {
                self.head = head.next;
            }
            return self.head;
        }
    };
}

pub fn findElementByField(comptime T: type, comptime field_type: type, array: []const T, comptime field: []const u8, value: field_type) ?T {
    const is_slice = switch (@typeInfo(field_type)) {
        .Pointer => |p| switch (p.size) {
            .Slice => true,
            else => false,
        },
        else => false,
    };
    for (array) |elem| {
        if (is_slice) {
            if (std.mem.eql(field_type, @field(elem, field), value)) {
                return elem;
            }
        } else {
            if (@field(elem, field) == value) {
                return elem;
            }
        }
    }
    return null;
}

/// Copies the characters from `input` to `output`
/// Returns StrError if output is too small
pub fn strcpy(input: []const u8, output: []u8) StrError!void {
    if (input.len > output.len) {
        std.debug.print("Input cannot fit into output", .{});
        return StrError.BufferTooSmall;
    }
    for (0..input.len) |i| {
        output[i] = input[i];
    }
}

test "strcpy" {
    var output = [_]u8{0} ** 16;
    const input = "can0";
    try strcpy(input, &output);
    for (0..input.len) |i| {
        try std.testing.expectEqual(input[i], output[i]);
    }
}

test "find element by name" {
    const Person = struct { name: []const u8, age: i32 };
    const array = [_]Person{
        .{ .name = "bob", .age = 42 },
        .{ .name = "jack", .age = 60 },
    };
    const elem = findElementByField(Person, []const u8, &array, "name", "bob");
    _ = elem;
}
