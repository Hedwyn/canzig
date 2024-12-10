const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;
const signals = @import("signals.zig");
const ArrayList = std.ArrayList;
const Element = xml.Element;
const Content = xml.Content;
const fmt = std.fmt;

const CanSignal = signals.CanSignal;

const assert = std.debug.assert;

const SignalDefinition = struct {
    structure: CanSignal,
    next: ?*SignalDefinition = null,
};

const MessageDefinition = struct {
    name: []const u8,
    id: u32,
    interval: ?f64 = null,
    length: usize,
    head: ?*SignalDefinition = null,

    pub fn addSignal(self: *MessageDefinition, signal: *SignalDefinition) void {
        const tail = if (self.head) |head| head else {
            self.head = signal;
            return;
        };
        var prev = tail;
        var next = tail.next;
        // finding the last slot
        while (next) |node| {
            prev = node;
            next = node.next;
        }
        prev.next = signal;
    }
};

const KcdDatabase = struct {
    messages: ArrayList(MessageDefinition),
};

const KcdTags = enum { Bus, Message, Signal };

const KcdElement = union(KcdTags) {
    Bus: []const u8,
    Message: *MessageDefinition,
    Signal: *SignalDefinition,

    pub fn free(self: *KcdElement, allocator: Allocator) void {
        switch (self.*) {
            .Message => |p| allocator.destroy(p),
            .Signal => |p| allocator.destroy(p),
            else => {},
        }
    }
};

const KcdParseErrors = error{
    MissingMessageName,
    AttributeMissing,
    InvalidFloatValue,
    InvalidIntegerValue,
    SignalOutsideMessage,
};

pub fn getTag(element: *Element) ?KcdTags {
    inline for (std.meta.fields(KcdTags)) |field| {
        if (std.mem.eql(u8, element.tag, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

pub fn parseKcd(allocator: Allocator, xml_content: []u8) !ArrayList(*MessageDefinition) {
    const document = try xml.parse(allocator, xml_content);
    defer document.deinit();
    return try processXmlElements(document.root, allocator);
}

pub fn getAttributeAs(comptime T: type, comptime attr_name: []const u8, element: *Element) KcdParseErrors!T {
    for (element.attributes) |attr| {
        if (std.mem.eql(u8, attr.name, attr_name)) {
            switch (@typeInfo(T)) {
                .Int => {
                    var val = attr.value;
                    const is_hex = val.len >= 2 and val[0] == '0' and (val[1] == 'x' or val[1] == 'X');
                    const base: u8 = if (is_hex) 16 else 10;
                    val = if (is_hex) val[2..] else val;
                    return fmt.parseInt(T, val, base) catch {
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
        getAttribute(field.name, element, &container) catch {};
    }
    return container;
}

pub fn extractKcdInfo(next_element: *Element, allocator: Allocator) KcdParseErrors!?KcdElement {
    const tag = if (getTag(next_element)) |t| t else {
        return null;
    };
    switch (tag) {
        .Bus => {
            return KcdElement{ .Bus = try getAttributeAs([]const u8, "name", next_element) };
        },
        .Message => {
            var definition = allocator.create(MessageDefinition) catch unreachable;
            definition.name = try getAttributeAs([]const u8, "name", next_element);
            definition.id = try getAttributeAs(u32, "id", next_element);
            definition.length = getAttributeAs(usize, "length", next_element) catch 1;
            definition.interval = getAttributeAs(f64, "interval", next_element) catch null;
            return KcdElement{ .Message = definition };
        },
        else => return null,
    }
}

fn processBusElement(bus: *Element, allocator: Allocator, database: *ArrayList(*MessageDefinition)) KcdParseErrors!void {
    var it = bus.iterator();
    var current_message: ?*MessageDefinition = null;
    while (it.next()) |content| {
        const element = switch (content.*) {
            .element => |e| e,
            else => continue,
        };
        const kcd_info = (try extractKcdInfo(element, allocator)) orelse continue;

        switch (kcd_info) {
            .Message => |m| {
                current_message = m;
                database.append(m) catch unreachable;
            },
            .Signal => |signal| {
                if (current_message) |msg| {
                    msg.addSignal(signal);
                } else {
                    return KcdParseErrors.SignalOutsideMessage;
                }
            },
            else => {},
        }
    }
}

pub fn processXmlElements(root: *Element, allocator: Allocator) KcdParseErrors!ArrayList(*MessageDefinition) {
    var database = ArrayList(*MessageDefinition).init(allocator);
    var it = root.iterator();
    while (it.next()) |content| {
        const element = switch (content.*) {
            .element => |e| e,
            else => continue,
        };
        const kcd_info = (try extractKcdInfo(element, allocator)) orelse continue;

        switch (kcd_info) {
            .Bus => |name| {
                std.log.info("Parsing bus {s}\n", .{name});
                try processBusElement(element, allocator, &database);
            },
            else => {},
        }
    }
    return database;
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

test "get tag" {
    var attributes = [_]xml.Attribute{
        .{ .name = "name", .value = "TestBus" },
    };
    var test_element: Element = .{
        .tag = "Bus",
        .attributes = &attributes,
    };

    try std.testing.expectEqual(getTag(&test_element).?, KcdTags.Bus);
}

test "test fsm get info" {
    var attributes = [_]xml.Attribute{
        .{ .name = "name", .value = "TestBus" },
    };
    var test_element: Element = .{
        .tag = "Bus",
        .attributes = &attributes,
    };
    const allocator = std.heap.page_allocator;
    var kcd_info = try extractKcdInfo(&test_element, allocator) orelse unreachable;
    defer kcd_info.free(allocator);
    try std.testing.expect(std.meta.eql(KcdElement{ .Bus = "TestBus" }, kcd_info));
}

test "test process elements" {
    var attributes = [_]xml.Attribute{
        .{ .name = "name", .value = "TestBus" },
    };
    var test_element: Element = .{
        .tag = "Bus",
        .attributes = &attributes,
    };
    var content = [_]Content{.{ .element = &test_element }};
    var root = Element{
        .tag = "root",
        .children = &content,
    };
    const allocator = std.heap.page_allocator;

    const database = try processXmlElements(&root, allocator);

    for (database.items) |msg| {
        std.log.debug("Msg = {any}", .{msg.*});
    }
}

test "parse kcd" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const file = try std.fs.cwd().openFile("can_definition_sample.kcd", .{});

    const reader = file.reader();
    const buffer = try reader.readAllAlloc(allocator, 10_000_000);
    const database = try parseKcd(allocator, buffer);
    std.log.debug("Database = {}\n", .{database});
}
