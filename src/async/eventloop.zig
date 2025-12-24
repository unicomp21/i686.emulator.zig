//! Event Loop
//!
//! Single-threaded event loop using epoll for timer and interrupt emulation.
//! Provides non-blocking I/O and scheduled events for the emulator.

const std = @import("std");
const builtin = @import("builtin");
const queue = @import("queue.zig");

pub const EventQueue = queue.EventQueue;
pub const EventType = queue.EventType;
pub const EventData = queue.EventData;

/// Timer handle
pub const TimerHandle = u32;

/// Timer callback type
pub const TimerCallback = *const fn (TimerHandle, ?*anyopaque) void;

/// Timer entry
const TimerEntry = struct {
    handle: TimerHandle,
    interval_ns: u64,
    next_fire: u64,
    repeat: bool,
    callback: TimerCallback,
    context: ?*anyopaque,
    active: bool,
};

/// Interrupt source
pub const InterruptSource = struct {
    vector: u8,
    pending: bool,
    masked: bool,
    edge_triggered: bool,
    level: bool,
};

/// Event loop for single-threaded emulator
pub const EventLoop = struct {
    /// Event queue for async events
    event_queue: EventQueue,
    /// Registered timers
    timers: std.ArrayList(TimerEntry),
    /// Next timer handle
    next_timer_handle: TimerHandle,
    /// Interrupt sources (256 vectors)
    interrupts: [256]InterruptSource,
    /// Interrupt mask register
    interrupt_mask: u256,
    /// Current time in nanoseconds
    current_time_ns: u64,
    /// Cycle-to-nanosecond ratio (e.g., 1000 for 1GHz CPU)
    ns_per_cycle: u64,
    /// Whether loop is running
    running: bool,
    /// Epoll file descriptor (Linux only)
    epoll_fd: ?std.posix.fd_t,
    /// Timer file descriptor (Linux only)
    timer_fd: ?std.posix.fd_t,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize event loop
    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .event_queue = EventQueue.init(allocator),
            .timers = std.ArrayList(TimerEntry).init(allocator),
            .next_timer_handle = 1,
            .interrupts = undefined,
            .interrupt_mask = 0,
            .current_time_ns = 0,
            .ns_per_cycle = 1000, // Default: 1GHz CPU
            .running = false,
            .epoll_fd = null,
            .timer_fd = null,
            .allocator = allocator,
        };

        // Initialize interrupt sources
        for (&self.interrupts) |*irq| {
            irq.* = .{
                .vector = 0,
                .pending = false,
                .masked = true,
                .edge_triggered = true,
                .level = false,
            };
        }

        // Set up epoll on Linux
        if (comptime builtin.os.tag == .linux) {
            self.epoll_fd = try std.posix.epoll_create1(.{ .CLOEXEC = true });
            errdefer if (self.epoll_fd) |fd| std.posix.close(fd);

            // Create timerfd for precise timing
            self.timer_fd = try createTimerFd();
            errdefer if (self.timer_fd) |fd| std.posix.close(fd);

            // Add timerfd to epoll
            if (self.epoll_fd) |epfd| {
                if (self.timer_fd) |tfd| {
                    var event = std.os.linux.epoll_event{
                        .events = std.os.linux.EPOLL.IN,
                        .data = .{ .fd = tfd },
                    };
                    try std.posix.epoll_ctl(epfd, .ADD, tfd, &event);
                }
            }
        }

        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.timer_fd) |fd| std.posix.close(fd);
            if (self.epoll_fd) |fd| std.posix.close(fd);
        }
        self.timers.deinit();
        self.event_queue.deinit();
    }

    /// Reset event loop state
    pub fn reset(self: *Self) void {
        self.timers.clearRetainingCapacity();
        self.next_timer_handle = 1;
        self.current_time_ns = 0;
        self.interrupt_mask = 0;
        for (&self.interrupts) |*irq| {
            irq.pending = false;
        }
        self.event_queue.reset();
    }

    /// Set CPU clock speed (Hz)
    pub fn setCpuSpeed(self: *Self, hz: u64) void {
        if (hz > 0) {
            self.ns_per_cycle = 1_000_000_000 / hz;
        }
    }

    /// Create a timer
    pub fn createTimer(
        self: *Self,
        interval_ns: u64,
        repeat: bool,
        callback: TimerCallback,
        context: ?*anyopaque,
    ) !TimerHandle {
        const handle = self.next_timer_handle;
        self.next_timer_handle += 1;

        try self.timers.append(.{
            .handle = handle,
            .interval_ns = interval_ns,
            .next_fire = self.current_time_ns + interval_ns,
            .repeat = repeat,
            .callback = callback,
            .context = context,
            .active = true,
        });

        return handle;
    }

    /// Create timer with millisecond interval
    pub fn createTimerMs(
        self: *Self,
        interval_ms: u64,
        repeat: bool,
        callback: TimerCallback,
        context: ?*anyopaque,
    ) !TimerHandle {
        return self.createTimer(interval_ms * 1_000_000, repeat, callback, context);
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *Self, handle: TimerHandle) void {
        for (self.timers.items) |*timer| {
            if (timer.handle == handle) {
                timer.active = false;
                return;
            }
        }
    }

    /// Advance time by CPU cycles
    pub fn advanceCycles(self: *Self, cycles: u64) void {
        self.current_time_ns += cycles * self.ns_per_cycle;
    }

    /// Process expired timers
    pub fn processTimers(self: *Self) !void {
        var i: usize = 0;
        while (i < self.timers.items.len) {
            var timer = &self.timers.items[i];

            if (!timer.active) {
                _ = self.timers.orderedRemove(i);
                continue;
            }

            if (self.current_time_ns >= timer.next_fire) {
                // Fire timer callback
                timer.callback(timer.handle, timer.context);

                // Queue timer event
                try self.event_queue.push(.{
                    .timer_tick = .{
                        .channel = @truncate(timer.handle),
                        .count = @truncate(timer.next_fire / 1_000_000),
                    },
                }, 5);

                if (timer.repeat) {
                    timer.next_fire = self.current_time_ns + timer.interval_ns;
                    i += 1;
                } else {
                    _ = self.timers.orderedRemove(i);
                }
            } else {
                i += 1;
            }
        }
    }

    /// Raise an interrupt
    pub fn raiseInterrupt(self: *Self, vector: u8) !void {
        self.interrupts[vector].pending = true;

        if (!self.interrupts[vector].masked) {
            try self.event_queue.push(.{
                .interrupt = .{
                    .vector = vector,
                    .is_hardware = true,
                },
            }, 1); // High priority
        }
    }

    /// Acknowledge (clear) an interrupt
    pub fn ackInterrupt(self: *Self, vector: u8) void {
        self.interrupts[vector].pending = false;
    }

    /// Mask an interrupt
    pub fn maskInterrupt(self: *Self, vector: u8) void {
        self.interrupts[vector].masked = true;
    }

    /// Unmask an interrupt
    pub fn unmaskInterrupt(self: *Self, vector: u8) void {
        self.interrupts[vector].masked = false;
    }

    /// Get pending interrupt (highest priority)
    pub fn getPendingInterrupt(self: *const Self) ?u8 {
        for (self.interrupts, 0..) |irq, i| {
            if (irq.pending and !irq.masked) {
                return @truncate(i);
            }
        }
        return null;
    }

    /// Poll for events (non-blocking)
    pub fn poll(self: *Self, timeout_ms: i32) !usize {
        if (comptime builtin.os.tag == .linux) {
            return self.pollEpoll(timeout_ms);
        } else {
            // Fallback: just process timers
            try self.processTimers();
            return self.event_queue.pending();
        }
    }

    /// Poll using epoll (Linux)
    fn pollEpoll(self: *Self, timeout_ms: i32) !usize {
        if (self.epoll_fd == null) return 0;

        var events: [16]std.os.linux.epoll_event = undefined;
        const count = std.posix.epoll_wait(self.epoll_fd.?, &events, timeout_ms);

        for (events[0..count]) |event| {
            if (self.timer_fd != null and event.data.fd == self.timer_fd.?) {
                // Timer fired - read to acknowledge
                var buf: [8]u8 = undefined;
                _ = std.posix.read(self.timer_fd.?, &buf) catch {};

                try self.processTimers();
            }
        }

        return self.event_queue.pending();
    }

    /// Run one iteration of the event loop
    pub fn runOnce(self: *Self, max_events: usize) !usize {
        // Process timers
        try self.processTimers();

        // Check for pending interrupts
        if (self.getPendingInterrupt()) |_| {
            // Interrupt handling would be triggered here
        }

        // Process event queue
        return try self.event_queue.processN(max_events);
    }

    /// Run the event loop (blocking)
    pub fn run(self: *Self) !void {
        self.running = true;
        while (self.running) {
            _ = try self.poll(10); // 10ms timeout
            _ = try self.runOnce(100);
        }
    }

    /// Stop the event loop
    pub fn stop(self: *Self) void {
        self.running = false;
    }

    /// Get current time in nanoseconds
    pub fn getCurrentTimeNs(self: *const Self) u64 {
        return self.current_time_ns;
    }

    /// Get current time in milliseconds
    pub fn getCurrentTimeMs(self: *const Self) u64 {
        return self.current_time_ns / 1_000_000;
    }
};

/// Create a timerfd (Linux only)
fn createTimerFd() !std.posix.fd_t {
    if (comptime builtin.os.tag != .linux) {
        return error.UnsupportedPlatform;
    }

    const fd = std.os.linux.timerfd_create(.MONOTONIC, .{
        .CLOEXEC = true,
        .NONBLOCK = true,
    });

    if (fd < 0) {
        return error.TimerFdCreationFailed;
    }

    return @intCast(fd);
}

// Tests
test "event loop init and deinit" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator);
    defer loop.deinit();
}

test "timer creation and firing" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator);
    defer loop.deinit();

    var fired = false;

    const callback = struct {
        fn cb(_: TimerHandle, ctx: ?*anyopaque) void {
            if (ctx) |c| {
                const flag: *bool = @ptrCast(@alignCast(c));
                flag.* = true;
            }
        }
    }.cb;

    _ = try loop.createTimer(1000, false, callback, &fired);

    // Advance time past timer
    loop.current_time_ns = 2000;
    try loop.processTimers();

    try std.testing.expect(fired);
}

test "interrupt handling" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator);
    defer loop.deinit();

    // Unmask interrupt 0x20
    loop.unmaskInterrupt(0x20);

    // Raise interrupt
    try loop.raiseInterrupt(0x20);

    // Should have pending interrupt
    const pending = loop.getPendingInterrupt();
    try std.testing.expect(pending != null);
    try std.testing.expectEqual(@as(u8, 0x20), pending.?);

    // Acknowledge
    loop.ackInterrupt(0x20);
    try std.testing.expect(loop.getPendingInterrupt() == null);
}

test "cpu speed setting" {
    const allocator = std.testing.allocator;
    var loop = try EventLoop.init(allocator);
    defer loop.deinit();

    // Set to 100MHz
    loop.setCpuSpeed(100_000_000);
    try std.testing.expectEqual(@as(u64, 10), loop.ns_per_cycle);

    // Advance 100 cycles = 1000ns
    loop.advanceCycles(100);
    try std.testing.expectEqual(@as(u64, 1000), loop.current_time_ns);
}
