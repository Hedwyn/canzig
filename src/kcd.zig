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

pub const SignalDefinition = struct {
    structure: CanSignal,
    next: ?*SignalDefinition = null,
};

const KcdParseErrors = error{
    // Bus errors
    NoBus,
    MultipleBuses,
    MissingMessageName,
    AttributeMissing,
    InvalidFloatValue,
    InvalidIntegerValue,
    SignalOutsideMessage,
    AllocatorError,
    MissingSignalProperties,
    EmptyDatabase,
    InvalidXml,
    FileTooBig,
};

const kcd_max_size = 16_000_000;

pub const SerializableMessage = struct {
    name: []const u8,
    id: u32,
    interval: ?f64 = null,
    length: usize,
    signals: []const CanSignal = &.{},
    doc: ?[]const u8 = null,
};

pub fn getAttributeAsMaybe(comptime T: type, comptime attr_name: []const u8, element: *Element) KcdParseErrors!?T {
    for (element.attributes) |attr| {
        if (std.mem.eql(u8, attr.name, attr_name)) {
            switch (@typeInfo(T)) {
                .int => {
                    var val = attr.value;
                    const is_hex = val.len >= 2 and val[0] == '0' and (val[1] == 'x' or val[1] == 'X');
                    const base: u8 = if (is_hex) 16 else 10;
                    val = if (is_hex) val[2..] else val;
                    return fmt.parseInt(T, val, base) catch {
                        return KcdParseErrors.InvalidIntegerValue;
                    };
                },
                .float => {
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
    return null;
}

pub fn getAttributeAsDefaulted(comptime T: type, comptime attr_name: []const u8, element: *Element, fallback: T) KcdParseErrors!T {
    return try getAttributeAsMaybe(T, attr_name, element) orelse fallback;
}

pub fn getAttributeAs(comptime T: type, comptime attr_name: []const u8, element: *Element) KcdParseErrors!T {
    return try getAttributeAsMaybe(T, attr_name, element) orelse KcdParseErrors.AttributeMissing;
}

pub fn getAttribute(comptime attr_name: []const u8, element: *Element, container: anytype) KcdParseErrors!void {
    const T = @TypeOf(@field(container, attr_name));
    for (element.attributes) |attr| {
        if (std.mem.eql(u8, attr.name, attr_name)) {
            switch (@typeInfo(T)) {
                .int => {
                    @field(container, attr_name) = fmt.parseInt(T, attr.value, 10) catch {
                        return KcdParseErrors.InvalidIntegerValue;
                    };
                },
                .float => {
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

const SignalData = struct {
    notes: ?[]const u8 = null,
    scale: f64 = 1.0,
    offset: f64 = 0.0,
};

pub const KcdDatabase = struct {
    document: xml.Document,
    allocator: Allocator,
    signals: ArrayList(CanSignal),
    messages: ArrayList(MessageDefinition),

    const MessageDefinition = struct {
        name: []const u8,
        id: u32,
        interval: ?f64 = null,
        length: usize,
        signals_start_idx: usize,
        signals_end_idx: usize,
    };

    pub fn serialize(self: KcdDatabase, allocator: Allocator) !ArrayList(SerializableMessage) {
        var messages = ArrayList(SerializableMessage).init(allocator);
        for (self.messages.items) |msg| {
            try messages.append(self.serializeMessage(msg));
        }
        return messages;
    }

    pub fn serializeMessage(self: KcdDatabase, msg: MessageDefinition) SerializableMessage {
        const signals_slice = self.signals.items[msg.signals_start_idx..msg.signals_end_idx];
        return .{
            .name = msg.name,
            .id = msg.id,
            .length = msg.length,
            .interval = msg.interval,
            .signals = signals_slice,
        };
    }

    const CursorIterator = struct {
        parser: *KcdDatabase,
        inner: xml.Element.ChildElementIterator,
        expected_tag: ?[]const u8 = null,

        pub fn next(self: CursorIterator) ?Element {
            while (self.inner.next()) |elem| {
                if (self.expected_tag) |tag| {
                    if (!std.mem.eql(u8, tag, elem.tag)) {
                        continue;
                    }
                }
                self.parser.current_element = elem;
                return elem;
            }
            return null;
        }
    };

    /// Moves the internal cursor to the next bus element
    fn getNextElement(current: *const Element, tag: []const u8) ?*Element {
        var it = current.tagged_elements(tag);
        return it.next();
    }

    pub fn deinit(self: *KcdDatabase) !void {
        self.document.deinit();
        self.messages.deinit();
        self.signals.deinit();
    }

    // Constructors

    pub fn parseXml(document: xml.Document, allocator: Allocator) !KcdDatabase {
        var db = KcdDatabase{
            .document = document,
            .allocator = allocator,
            .signals = .init(allocator),
            .messages = .init(allocator),
        };
        try db.inner_parse();
        return db;
    }

    pub fn parseString(xml_content: []const u8, allocator: Allocator) !KcdDatabase {
        const document = xml.parse(allocator, xml_content) catch return KcdParseErrors.InvalidXml;
        return KcdDatabase.parseXml(document, allocator);
    }

    pub fn parseFile(fpath: []const u8, allocator: Allocator) !KcdDatabase {
        const file = try std.fs.cwd().openFile(fpath, .{});

        const reader = file.reader();
        const buffer = reader.readAllAlloc(allocator, kcd_max_size) catch return KcdParseErrors.AllocatorError;
        defer allocator.free(buffer);
        return KcdDatabase.parseString(buffer, allocator);
    }

    fn inner_parse(self: *KcdDatabase) KcdParseErrors!void {
        const bus_element = getNextElement(self.document.root, "Bus") orelse return KcdParseErrors.EmptyDatabase;
        try self.parseMessages(bus_element);
    }

    pub fn parseMessages(self: *KcdDatabase, bus_element: *xml.Element) KcdParseErrors!void {
        var msg_it = bus_element.tagged_elements("Message");
        while (msg_it.next()) |msg| {
            try self.parseMessage(msg);
        }
    }

    pub fn parseMessage(self: *KcdDatabase, msg_element: *Element) KcdParseErrors!void {
        var signal_it = msg_element.tagged_elements("Signal");
        const signals_start_idx = self.signals.items.len;
        while (signal_it.next()) |signal_element| {
            try self.parseSignal(signal_element);
        }
        const signals_end_idx = self.signals.items.len;
        const new_msg = MessageDefinition{
            .name = try getAttributeAs([]const u8, "name", msg_element),
            .id = try getAttributeAs(u32, "id", msg_element),
            .length = getAttributeAs(usize, "length", msg_element) catch 8,
            .interval = getAttributeAs(f64, "interval", msg_element) catch null,
            .signals_start_idx = signals_start_idx,
            .signals_end_idx = signals_end_idx,
        };
        self.messages.append(new_msg) catch return KcdParseErrors.AllocatorError;
    }

    pub fn parseSignal(self: *KcdDatabase, signal_element: *Element) KcdParseErrors!void {
        const maybe_value = getNextElement(signal_element, "value");
        const scale = if (maybe_value) |v| try getAttributeAsDefaulted(f64, "slope", v, 1.0) else 1.0;
        const offset = if (maybe_value) |v| try getAttributeAsDefaulted(f64, "intercept", v, 0.0) else 0.0;

        const signal_struct = CanSignal{
            .position = try getAttributeAs(usize, "offset", signal_element),
            .length = try getAttributeAsDefaulted(usize, "length", signal_element, 1),
            // TODO: scale and offset
            .name = try getAttributeAs([]const u8, "name", signal_element),
            .offset = offset,
            .scale = scale,
        };
        self.signals.append(signal_struct) catch return KcdParseErrors.AllocatorError;
    }
};

test "parse string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const file = try std.fs.cwd().openFile("can_definition_sample.kcd", .{});

    const reader = file.reader();
    const buffer = try reader.readAllAlloc(allocator, 10_000_000);
    const database = try KcdDatabase.parseString(buffer, allocator);
    std.log.debug("Database = {}\n", .{database});
}

test "parse file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();
    const database = try KcdDatabase.parseFile("can_definition_sample.kcd", allocator);
    std.log.debug("Database = {}\n", .{database});
}
