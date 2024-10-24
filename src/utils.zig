///! Shared utilities for this package
/// String-related pritimives
const std = @import("std");
const StrError = error{
    BufferTooSmall,
};

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
