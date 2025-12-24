//! i686 Emulator Library
//!
//! A cycle-accurate i686 (Intel Pentium Pro/II/III compatible) CPU emulator
//! written in Zig. Supports real mode, protected mode, and basic I/O
//! through a UART interface for testing and debugging.

const std = @import("std");

pub const cpu = @import("cpu/cpu.zig");
pub const memory = @import("memory/memory.zig");
pub const io = @import("io/io.zig");
pub const uart = @import("io/uart.zig");
pub const debug = @import("debug/debugger.zig");
pub const async_queue = @import("async/queue.zig");
pub const event_loop = @import("async/eventloop.zig");

/// CPU type aliases for convenience
pub const Cpu = cpu.Cpu;
pub const CpuState = cpu.CpuState;

/// Memory type aliases
pub const Memory = memory.Memory;
pub const MemoryError = memory.MemoryError;

/// I/O type aliases
pub const IoController = io.IoController;
pub const Uart = uart.Uart;

/// Async type aliases
pub const EventQueue = async_queue.EventQueue;
pub const EventType = async_queue.EventType;
pub const EventData = async_queue.EventData;
pub const Event = async_queue.Event;
pub const EventLoop = event_loop.EventLoop;

/// Emulator configuration
pub const Config = struct {
    /// Memory size in bytes (default 16MB)
    memory_size: usize = 16 * 1024 * 1024,
    /// Enable UART on COM1 (0x3F8)
    enable_uart: bool = true,
    /// UART base address
    uart_base: u16 = 0x3F8,
    /// Enable debug mode
    debug_mode: bool = false,
    /// Initial instruction pointer
    initial_ip: u32 = 0x0000_0000,
    /// Initial code segment (real mode)
    initial_cs: u16 = 0x0000,
};

/// Main emulator instance
pub const Emulator = struct {
    cpu_instance: Cpu,
    mem: Memory,
    io_ctrl: IoController,
    config: Config,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new emulator instance
    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        var mem = try Memory.init(allocator, config.memory_size);
        errdefer mem.deinit();

        var io_ctrl = IoController.init(allocator);
        errdefer io_ctrl.deinit();

        if (config.enable_uart) {
            try io_ctrl.registerUart(config.uart_base);
        }

        var cpu_instance = Cpu.init(&mem, &io_ctrl);
        cpu_instance.reset(config.initial_cs, @truncate(config.initial_ip));

        return Self{
            .cpu_instance = cpu_instance,
            .mem = mem,
            .io_ctrl = io_ctrl,
            .config = config,
            .allocator = allocator,
        };
    }

    /// Clean up emulator resources
    pub fn deinit(self: *Self) void {
        self.io_ctrl.deinit();
        self.mem.deinit();
    }

    /// Execute a single instruction
    pub fn step(self: *Self) !void {
        try self.cpu_instance.step();
    }

    /// Run until halt or breakpoint
    pub fn run(self: *Self) !void {
        while (!self.cpu_instance.isHalted()) {
            try self.step();
        }
    }

    /// Load binary code into memory at specified address
    pub fn loadBinary(self: *Self, data: []const u8, address: u32) !void {
        try self.mem.writeBytes(address, data);
    }

    /// Get UART output buffer (for testing)
    pub fn getUartOutput(self: *Self) ?[]const u8 {
        if (self.io_ctrl.getUart(self.config.uart_base)) |u| {
            return u.getOutputBuffer();
        }
        return null;
    }

    /// Send input to UART (for testing)
    pub fn sendUartInput(self: *Self, data: []const u8) !void {
        if (self.io_ctrl.getUart(self.config.uart_base)) |u| {
            try u.sendInput(data);
        }
    }

    /// Reset the emulator to initial state
    pub fn reset(self: *Self) void {
        self.cpu_instance.reset(self.config.initial_cs, @truncate(self.config.initial_ip));
        self.io_ctrl.reset();
    }

    /// Get current CPU state for debugging
    pub fn getCpuState(self: *const Self) CpuState {
        return self.cpu_instance.getState();
    }
};

test "emulator initialization" {
    const allocator = std.testing.allocator;
    var emu = try Emulator.init(allocator, .{});
    defer emu.deinit();

    const state = emu.getCpuState();
    try std.testing.expectEqual(@as(u32, 0), state.eip);
}

test "emulator with custom config" {
    const allocator = std.testing.allocator;
    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024, // 1MB
        .enable_uart = true,
        .debug_mode = true,
    });
    defer emu.deinit();

    try std.testing.expect(emu.config.debug_mode);
}
