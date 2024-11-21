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
    // message: CanMessage,
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

pub fn getAttributeAs(comptime T: type, comptime attr_name: []const u8, element: *Element) KcdParseErrors!T {
    for (element.attributes) |attr| {
        if (std.mem.eql(u8, attr.name, attr_name)) {
            switch (@typeInfo(T)) {
                .Int => {
                    return fmt.parseInt(T, attr.value, 10) catch {
                        return KcdParseErrors.InvalidIntegerValue;
                    };
                },
                .Float => {
                    return fmt.parseFloat(T, attr.value) catch {
                        return KcdParseErrors.InvalidFloatValue;
                    };
                },
                else => {
                    return attr.value;
                },
            }
        }
    }
    return KcdParseErrors.AttributeMissing;
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

pub fn buildContainerFromElement(comptime T: type, element: *Element) KcdParseErrors!T {
    var container: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        try getAttribute(field.name, element, &container);
    }
    return container;
}

pub fn processNextState(state: KcdFsm, next_element: *Element) KcdParseErrors!?KcdFsm {
    const tag = next_element.tag;
    switch (state) {
        .init => {
            if (!std.mem.eql(u8, tag, "Bus")) {
                std.log.debug("[State init] Ignoring tag {s}", .{tag});
                return null;
            }
            return KcdFsm{ .bus = try getAttributeAs([]const u8, "name", next_element) };
        },
        .bus => {
            if (!std.mem.eql(u8, tag, "Message")) {
                std.log.debug("[State bus] Ignoring tag {s}", .{tag});
                return null;
            }   
        }
        else => return KcdParseErrors.AttributeMissing,
    }
    return KcdParseErrors.AttributeMissing;
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

test "build container from attributes" {
    var attributes = [_]xml.Attribute{
        .{ .name = "an_attr", .value = "3.14" },
        .{ .name = "another_attr", .value = "42" },
    };
    var test_element: Element = .{
        .tag = "Test",
        .attributes = &attributes,
    };

    const ContainerType = struct {
        an_attr: f64,
        another_attr: i32,
    };
    const container = try buildContainerFromElement(ContainerType, &test_element);
    _ = container;
}

test "get attribute as" {
    var attributes = [_]xml.Attribute{
        .{ .name = "an_attr", .value = "3.14" },
        .{ .name = "another_attr", .value = "42" },
    };
    var test_element: Element = .{
        .tag = "Test",
        .attributes = &attributes,
    };
    const value = getAttributeAs(f64, "an_attr", &test_element);
    try std.testing.expectEqual(3.14, value);
}

test "test fsm parse state bus" {
    var attributes = [_]xml.Attribute{
        .{ .name = "name", .value = "TestBus" },
    };
    var test_element: Element = .{
        .tag = "Bus",
        .attributes = &attributes,
    };

    var state: KcdFsm = .init;
    state = try processNextState(state, &test_element) orelse state;
    std.debug.print("State={any}", .{state});
    try std.testing.expect(std.meta.eql(KcdFsm{ .bus = "TestBus" }, state));
}
