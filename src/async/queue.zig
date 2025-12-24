//! Async Event Queue
//!
//! Provides an async event queue for separating concerns in the emulator.
//! Allows decoupling of CPU execution from I/O handling, interrupts, and debugging.

const std = @import("std");

/// Event types for the emulator
pub const EventType = enum {
    /// CPU wants to read from I/O port
    io_read,
    /// CPU wants to write to I/O port
    io_write,
    /// Interrupt requested
    interrupt,
    /// Breakpoint hit
    breakpoint,
    /// CPU halted
    halt,
    /// Memory access (for debugging/tracing)
    memory_access,
    /// UART data received
    uart_rx,
    /// UART data transmitted
    uart_tx,
    /// Timer tick
    timer_tick,
    /// Custom event
    custom,
};

/// Event data payload
pub const EventData = union(EventType) {
    io_read: IoReadEvent,
    io_write: IoWriteEvent,
    interrupt: InterruptEvent,
    breakpoint: BreakpointEvent,
    halt: HaltEvent,
    memory_access: MemoryAccessEvent,
    uart_rx: UartEvent,
    uart_tx: UartEvent,
    timer_tick: TimerEvent,
    custom: CustomEvent,
};

pub const IoReadEvent = struct {
    port: u16,
    size: u8, // 1, 2, or 4 bytes
    result: ?u32 = null,
};

pub const IoWriteEvent = struct {
    port: u16,
    value: u32,
    size: u8,
};

pub const InterruptEvent = struct {
    vector: u8,
    is_hardware: bool,
};

pub const BreakpointEvent = struct {
    address: u32,
    hit_count: u32,
};

pub const HaltEvent = struct {
    reason: HaltReason,
    address: u32,
};

pub const HaltReason = enum {
    hlt_instruction,
    breakpoint,
    exception,
    external,
};

pub const MemoryAccessEvent = struct {
    address: u32,
    size: u8,
    is_write: bool,
    value: u32,
};

pub const UartEvent = struct {
    port_index: u8,
    data: u8,
};

pub const TimerEvent = struct {
    channel: u8,
    count: u16,
};

pub const CustomEvent = struct {
    id: u32,
    data: u64,
};

/// Event with metadata
pub const Event = struct {
    /// Event data
    data: EventData,
    /// Timestamp (cycle count)
    timestamp: u64,
    /// Priority (lower = higher priority)
    priority: u8,
    /// Callback ID for response routing
    callback_id: ?u32,
};

/// Event handler callback type
pub const EventHandler = *const fn (*Event, ?*anyopaque) void;

/// Handler registration
const HandlerEntry = struct {
    event_type: EventType,
    handler: EventHandler,
    context: ?*anyopaque,
    priority: u8,
};

/// Async event queue for the emulator
pub const EventQueue = struct {
    /// Pending events
    events: std.ArrayList(Event),
    /// Registered handlers
    handlers: std.ArrayList(HandlerEntry),
    /// Current cycle count
    cycle_count: u64,
    /// Whether queue is processing
    is_processing: bool,
    /// Max events before forcing drain
    max_pending: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize event queue
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .events = std.ArrayList(Event).init(allocator),
            .handlers = std.ArrayList(HandlerEntry).init(allocator),
            .cycle_count = 0,
            .is_processing = false,
            .max_pending = 1000,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.events.deinit();
        self.handlers.deinit();
    }

    /// Reset queue state
    pub fn reset(self: *Self) void {
        self.events.clearRetainingCapacity();
        self.cycle_count = 0;
        self.is_processing = false;
    }

    /// Register an event handler
    pub fn registerHandler(
        self: *Self,
        event_type: EventType,
        handler: EventHandler,
        context: ?*anyopaque,
        priority: u8,
    ) !void {
        try self.handlers.append(.{
            .event_type = event_type,
            .handler = handler,
            .context = context,
            .priority = priority,
        });

        // Sort by priority
        std.mem.sort(HandlerEntry, self.handlers.items, {}, struct {
            fn lessThan(_: void, a: HandlerEntry, b: HandlerEntry) bool {
                return a.priority < b.priority;
            }
        }.lessThan);
    }

    /// Unregister all handlers for an event type
    pub fn unregisterHandlers(self: *Self, event_type: EventType) void {
        var i: usize = 0;
        while (i < self.handlers.items.len) {
            if (self.handlers.items[i].event_type == event_type) {
                _ = self.handlers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Push an event onto the queue
    pub fn push(self: *Self, data: EventData, priority: u8) !void {
        try self.events.append(.{
            .data = data,
            .timestamp = self.cycle_count,
            .priority = priority,
            .callback_id = null,
        });

        // Auto-drain if too many events
        if (self.events.items.len >= self.max_pending) {
            try self.processAll();
        }
    }

    /// Push event with callback ID for response routing
    pub fn pushWithCallback(self: *Self, data: EventData, priority: u8, callback_id: u32) !void {
        try self.events.append(.{
            .data = data,
            .timestamp = self.cycle_count,
            .priority = priority,
            .callback_id = callback_id,
        });
    }

    /// Pop and return next event (by priority, then timestamp)
    pub fn pop(self: *Self) ?Event {
        if (self.events.items.len == 0) return null;

        // Find highest priority (lowest number) event
        var best_idx: usize = 0;
        var best_priority: u8 = self.events.items[0].priority;
        var best_timestamp: u64 = self.events.items[0].timestamp;

        for (self.events.items, 0..) |event, i| {
            if (event.priority < best_priority or
                (event.priority == best_priority and event.timestamp < best_timestamp))
            {
                best_idx = i;
                best_priority = event.priority;
                best_timestamp = event.timestamp;
            }
        }

        return self.events.orderedRemove(best_idx);
    }

    /// Peek at next event without removing
    pub fn peek(self: *const Self) ?*const Event {
        if (self.events.items.len == 0) return null;
        return &self.events.items[0];
    }

    /// Process a single event
    pub fn processOne(self: *Self) !bool {
        const event = self.pop() orelse return false;

        var event_copy = event;
        for (self.handlers.items) |entry| {
            if (entry.event_type == std.meta.activeTag(event.data)) {
                entry.handler(&event_copy, entry.context);
            }
        }

        return true;
    }

    /// Process all pending events
    pub fn processAll(self: *Self) !void {
        if (self.is_processing) return; // Prevent re-entrancy

        self.is_processing = true;
        defer self.is_processing = false;

        while (try self.processOne()) {}
    }

    /// Process events up to a limit
    pub fn processN(self: *Self, max_events: usize) !usize {
        if (self.is_processing) return 0;

        self.is_processing = true;
        defer self.is_processing = false;

        var processed: usize = 0;
        while (processed < max_events) : (processed += 1) {
            if (!try self.processOne()) break;
        }
        return processed;
    }

    /// Get number of pending events
    pub fn pending(self: *const Self) usize {
        return self.events.items.len;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.events.items.len == 0;
    }

    /// Update cycle count (call this each CPU cycle)
    pub fn tick(self: *Self) void {
        self.cycle_count += 1;
    }

    /// Get current cycle count
    pub fn getCycleCount(self: *const Self) u64 {
        return self.cycle_count;
    }

    /// Clear all pending events
    pub fn clear(self: *Self) void {
        self.events.clearRetainingCapacity();
    }

    /// Filter events by type
    pub fn filterByType(self: *const Self, event_type: EventType, allocator: std.mem.Allocator) ![]Event {
        var result = std.ArrayList(Event).init(allocator);
        errdefer result.deinit();

        for (self.events.items) |event| {
            if (std.meta.activeTag(event.data) == event_type) {
                try result.append(event);
            }
        }

        return result.toOwnedSlice();
    }
};

/// Channel for typed async communication
pub fn Channel(comptime T: type) type {
    return struct {
        buffer: std.ArrayList(T),
        closed: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .buffer = std.ArrayList(T).init(allocator),
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn send(self: *Self, value: T) !void {
            if (self.closed) return error.ChannelClosed;
            try self.buffer.append(value);
        }

        pub fn receive(self: *Self) ?T {
            if (self.buffer.items.len == 0) return null;
            return self.buffer.orderedRemove(0);
        }

        pub fn tryReceive(self: *Self) !?T {
            if (self.closed and self.buffer.items.len == 0) {
                return error.ChannelClosed;
            }
            return self.receive();
        }

        pub fn close(self: *Self) void {
            self.closed = true;
        }

        pub fn len(self: *const Self) usize {
            return self.buffer.items.len;
        }
    };
}

// Tests
test "event queue basic operations" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    try queue.push(.{ .halt = .{
        .reason = .hlt_instruction,
        .address = 0x1000,
    } }, 1);

    try std.testing.expectEqual(@as(usize, 1), queue.pending());

    const event = queue.pop();
    try std.testing.expect(event != null);
    try std.testing.expect(queue.isEmpty());
}

test "event queue priority ordering" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    // Push low priority first
    try queue.push(.{ .timer_tick = .{ .channel = 0, .count = 100 } }, 10);
    // Push high priority second
    try queue.push(.{ .interrupt = .{ .vector = 0, .is_hardware = true } }, 1);

    // Should get high priority first
    const event1 = queue.pop();
    try std.testing.expect(event1 != null);
    try std.testing.expectEqual(EventType.interrupt, std.meta.activeTag(event1.?.data));

    const event2 = queue.pop();
    try std.testing.expect(event2 != null);
    try std.testing.expectEqual(EventType.timer_tick, std.meta.activeTag(event2.?.data));
}

test "event queue handler registration" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    var handler_called = false;

    const handler = struct {
        fn handle(event: *Event, ctx: ?*anyopaque) void {
            _ = event;
            if (ctx) |c| {
                const flag: *bool = @ptrCast(@alignCast(c));
                flag.* = true;
            }
        }
    }.handle;

    try queue.registerHandler(.halt, handler, &handler_called, 0);

    try queue.push(.{ .halt = .{
        .reason = .hlt_instruction,
        .address = 0,
    } }, 0);

    try queue.processAll();

    try std.testing.expect(handler_called);
}

test "typed channel" {
    const allocator = std.testing.allocator;
    var channel = Channel(u32).init(allocator);
    defer channel.deinit();

    try channel.send(42);
    try channel.send(100);

    try std.testing.expectEqual(@as(usize, 2), channel.len());
    try std.testing.expectEqual(@as(?u32, 42), channel.receive());
    try std.testing.expectEqual(@as(?u32, 100), channel.receive());
    try std.testing.expectEqual(@as(?u32, null), channel.receive());
}

test "channel close" {
    const allocator = std.testing.allocator;
    var channel = Channel(u8).init(allocator);
    defer channel.deinit();

    try channel.send(1);
    channel.close();

    // Can still receive buffered data
    try std.testing.expectEqual(@as(?u8, 1), try channel.tryReceive());

    // After buffer empty, returns error
    try std.testing.expectError(error.ChannelClosed, channel.tryReceive());
}
