const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;
const signals = @import("signals.zig");
const Element = xml.Element;
const fmt = std.fmt;

const assert = std.debug.assert;

const CanMessage = struct {
    id: u32,
    interval: f64,
};

const KcdFsm = union(enum) {
    init: void,
    bus: []const u8,
    message: CanMessage,
};

const KcdParseErrors = error{
    MissingMessageName,
    AttributeMissing,
    InvalidFloatValue,
    InvalidIntegerValue,
};

pub fn parseKcd(allocator: Allocator, xml_content: []u8) void {
    const document = try xml.parse(allocator, xml_content);
    defer document.deinit();
    // TODO
}

pub fn getAttribute(comptime attr_name: []const u8, element: *Element, container: anytype) KcdParseErrors!void {
    const T = @TypeOf(@field(container, attr_name));
    for (element.attributes) |attr| {
        if (std.mem.eql(u8, attr.name, attr_name)) {
            switch (@typeInfo(T)) {
                .Int => {
                    @field(container, attr_name) = fmt.parseInt(T, attr.value, 10) catch {
                        return KcdParseErrors.InvalidIntegerValue;
                    };
                },
                .Float => {
                    @field(container, attr_name) = fmt.parseFloat(T, attr.value) catch {
                        return KcdParseErrors.InvalidFloatValue;
                    };
                },
                else => {
                    @field(container, attr_name) = attr.value;
                },
            }
            return;
        }
    }
    return KcdParseErrors.AttributeMissing;
}

pub fn processNextState(state: KcdFsm, next_element: *Element) KcdParseErrors!?KcdFsm {
    const tag = next_element.tag;
    switch (state.*) {
        .init => {
            if (!std.mem.eql(u8, tag, "Bus")) {
                std.log.debug("[State init] Ignoring tag {s}", .{tag});
                return null;
            }
        },
    }
}

test "get attribute str" {
    var attributes = [_]xml.Attribute{
        .{ .name = "some_attr", .value = "3.14" },
        .{ .name = "useless", .value = "42" },
    };
    var test_element: Element = .{
        .tag = "Test",
        .attributes = &attributes,
    };

    const ContainerType = struct {
        some_attr: []const u8,
    };
    var container: ContainerType = undefined;
    try getAttribute("some_attr", &test_element, &container);
    // try std.testing.expectEqualStrings("3.14", container.some_attr);
    try std.testing.expectEqual("3.14", container.some_attr);
}

test "get attribute float" {
    var attributes = [_]xml.Attribute{
        .{ .name = "some_attr", .value = "3.14" },
        .{ .name = "useless", .value = "42" },
    };
    var test_element: Element = .{
        .tag = "Test",
        .attributes = &attributes,
    };

    const ContainerType = struct {
        some_attr: f64,
    };
    var container: ContainerType = undefined;
    try getAttribute("some_attr", &test_element, &container);
    try std.testing.expectEqual(3.14, container.some_attr);
}

test "get attribute int" {
    var attributes = [_]xml.Attribute{
        .{ .name = "some_attr", .value = "42" },
        .{ .name = "useless", .value = "3.14" },
    };
    var test_element: Element = .{
        .tag = "Test",
        .attributes = &attributes,
    };

    const ContainerType = struct {
        some_attr: i32,
    };
    var container: ContainerType = undefined;
    try getAttribute("some_attr", &test_element, &container);
    // try std.testing.expectEqualStrings("3.14", container.some_attr);
    try std.testing.expectEqual(42, container.some_attr);
}

test "get attribute not found" {
    var attributes = [_]xml.Attribute{
        .{ .name = "some_attr", .value = "42" },
        .{ .name = "useless", .value = "3.14" },
    };
    var test_element: Element = .{
        .tag = "Test",
        .attributes = &attributes,
    };

    const ContainerType = struct {
        does_not_exit: i32,
    };
    var container: ContainerType = undefined;
    try std.testing.expectEqual(KcdParseErrors.AttributeMissing, getAttribute("does_not_exit", &test_element, &container));
}

test "get attribute numeric parse errors" {
    var attributes = [_]xml.Attribute{
        .{ .name = "some_attr", .value = "42s" },
        .{ .name = "other_attr", .value = "3.1z4" },
    };
    var test_element: Element = .{
        .tag = "Test",
        .attributes = &attributes,
    };

    const ContainerType = struct {
        some_attr: i32,
        other_attr: f64,
    };
    var container: ContainerType = undefined;
    try std.testing.expectEqual(KcdParseErrors.InvalidIntegerValue, getAttribute("some_attr", &test_element, &container));
    try std.testing.expectEqual(KcdParseErrors.InvalidFloatValue, getAttribute("other_attr", &test_element, &container));
}
