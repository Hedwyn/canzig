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
/// A slice of an array given by indexes.
/// Max supported array size is 2 ** 16
const ArraySlice = struct {
    start: u16,
    length: u16,
};

const short_string_max_len = 12;

pub const ShortString = extern struct {
    len: u32,
    content: [short_string_max_len]u8,
};

const long_string_prefix_len = 4;
const german_string_max_len = 0xFFFF_FFFF;

pub const LongString = extern struct {
    len: u32,
    prefix: [long_string_prefix_len]u8,
    ptr: [*]u8,
};

const GermanString = extern union {
    short: ShortString,
    long: LongString,

    pub fn init(string: [*]const u8, len: usize) GermanString {
        if (len > german_string_max_len) {
            @panic("German strings max len needs to fit in 32 bits");
        }
        if (len <= short_string_max_len) {
            var short_str: ShortString = undefined;
            short_str.len = @intCast(len);
            for (0..len) |i| {
                short_str.content[i] = string[i];
            }
            return .{ .short = short_str };
        }
        var long_str: LongString = undefined;
        long_str.len = @intCast(len);
        for (0..long_string_prefix_len) |i| {
            long_str.prefix[i] = string[i];
        }
        long_str.ptr = @constCast(string);
        return .{ .long = long_str };
    }
    /// Gets a slice to the actual German String content,
    /// so that it can be used like a normal string.
    /// This should be the main method to interact with the string content
    pub fn toSlice(self: GermanString) []const u8 {
        const short_str = self.short;
        const len = short_str.len;
        std.debug.print("Len is {}\n", .{len});
        if (len <= short_string_max_len) {
            // short
            return short_str.content[0..len];
        }
        // long
        return self.long.ptr[0..len];
    }
    /// Wether this string is a short string
    /// Short strings feat entirely in this container
    pub inline fn isShort(self: GermanString) bool {
        return (self.short.len <= short_string_max_len);
    }

    /// Wether this string is a long string
    /// Long strings are pointing to another memory location
    pub inline fn isLong(self: GermanString) bool {
        return (self.short.len > short_string_max_len);
    }
    /// Equality comparison for german string.
    /// Does NOT consider encoding - only the raw bytes
    pub fn equals(self: GermanString, other: GermanString) bool {
        const len = self.short.len;
        if (len != other.short.len) {
            return false;
        }
        if (len <= short_string_max_len) {
            return (std.mem.eql(u8, std.mem.asBytes(&self), std.mem.asBytes(&other)));
        }
        if (!std.mem.eql(u8, &self.long.prefix, &other.long.prefix)) {
            // if (self.long.prefix != other.long.prefix) {
            return false;
        }
        return std.mem.eql(
            u8,
            self.long.ptr[short_string_max_len..len],
            other.long.ptr[short_string_max_len..len],
        );
    }

    /// Whether this string starts with the given prefix
    pub fn startsWith(self: GermanString, prefix: []const u8) bool {
        // Trivial cases
        if (prefix.len > self.short.len) {
            return false;
        }
        if (prefix.len == 0) {
            return true;
        }
        // short string case
        if (self.isShort()) {
            for (0..prefix.len) |i| {
                if (self.short.content[i] != prefix[i]) {
                    return false;
                }
            }
            return true;
        }
        // long string case: check if local prefix is enough
        for (0..long_string_prefix_len) |i| {
            if (self.long.prefix[i] != prefix[i]) {
                return false;
            }
            if (i == prefix.len - 1) {
                // we matched the whole prefix, done
                return true;
            }
        }

        // If we di not return yet we have to dereference
        // the long string to chech the remaining
        for (long_string_prefix_len..prefix.len) |i| {
            if (self.long.ptr[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }
};

test "german string short" {
    const test_case = "Hello World";
    const short = GermanString.init(test_case, test_case.len);
    try std.testing.expectEqualStrings(short.toSlice(), test_case);
    try std.testing.expectEqual(@sizeOf(GermanString), 16);
}

test "german string long" {
    const test_case = "This sentence does not fit in a short string";
    const long = GermanString.init(test_case, test_case.len);
    try std.testing.expectEqualStrings(long.toSlice(), test_case);
}

test "german string long equals" {
    const test_case = "This sentence does not fit in a short string";
    const long = GermanString.init(test_case, test_case.len);
    try std.testing.expect(long.equals(long));
    const not_equal = "This sentence does not fit in a shor string";
    const other = GermanString.init(not_equal, not_equal.len);
    try std.testing.expect(!long.equals(other));
}

test "german string short equals" {
    const test_case = "Hello World";
    const short = GermanString.init(test_case, test_case.len);
    try std.testing.expect(short.equals(short));
    const not_equal = "Hello Worldz";
    const other = GermanString.init(not_equal, not_equal.len);
    try std.testing.expect(!short.equals(other));
}

test "german long string startswith" {
    const candidate = "This sentence does not fit in a short string";
    const long = GermanString.init(candidate, candidate.len);
    const TestCase = struct { prefix: []const u8, expects: bool };
    const test_cases = [_]TestCase{
        .{ .prefix = "Thiz", .expects = false },
        .{ .prefix = "This", .expects = true },
        // Transition from 4 to 5 characters is prone to errors
        // as we now have to look beyond the prefix
        .{ .prefix = "This ", .expects = true },
        .{ .prefix = "Thiss", .expects = false },

        .{ .prefix = candidate ++ "00", .expects = false },
        .{ .prefix = "", .expects = true },
        .{ .prefix = "This sentence", .expects = true },
        .{ .prefix = "This sentence", .expects = true },
        .{ .prefix = "This sentnce", .expects = false },
    };
    for (test_cases) |test_case| {
        std.testing.expectEqual(long.startsWith(test_case.prefix), test_case.expects) catch |e| {
            std.debug.print(
                "--> Failed: `{s}`\n with prefix:`{s}`\n: expected {}",
                .{ candidate, test_case.prefix, test_case.expects },
            );
            return e;
        };
    }
}

test "german short string startswith" {
    const candidate = "Hello World";
    const long = GermanString.init(candidate, candidate.len);
    const TestCase = struct { prefix: []const u8, expects: bool };
    const test_cases = [_]TestCase{
        .{ .prefix = "Hello", .expects = true },
        .{ .prefix = "Helzo", .expects = false },
        .{ .prefix = candidate ++ "00", .expects = false },
        .{ .prefix = "", .expects = true },
    };
    for (test_cases) |test_case| {
        std.testing.expectEqual(long.startsWith(test_case.prefix), test_case.expects) catch |e| {
            std.debug.print(
                "--> Failed: `{s}`\n with prefix:`{s}`\n: expected {}",
                .{ candidate, test_case.prefix, test_case.expects },
            );
            return e;
        };
    }
}

pub fn findElementByField(
    comptime T: type,
    comptime field_type: type,
    array: []const T,
    comptime field: []const u8,
    value: field_type,
) ?T {
    const is_slice = switch (@typeInfo(field_type)) {
        .pointer => |p| switch (p.size) {
            .slice => true,
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

// test "find element by name" {
//     const Person = struct { name: []const u8, age: i32 };
//     const array = [_]Person{
//         .{ .name = "bob", .age = 42 },
//         .{ .name = "jack", .age = 60 },
//     };
//     const elem = findElementByField(Person, []const u8, &array, "name", "bob");
//     _ = elem;
// }
