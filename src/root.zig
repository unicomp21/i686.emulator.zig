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
pub const boot = @import("boot/loader.zig");

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
    /// Enable keyboard controller (8042)
    enable_keyboard: bool = false,
    /// Enable debug mode
    debug_mode: bool = false,
    /// Dump CPU state on error (registers + last N instructions)
    dump_on_error: bool = false,
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
    /// Track if CPU pointers have been fixed after struct move
    pointers_fixed: bool,

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

        if (config.enable_keyboard) {
            io_ctrl.registerKeyboard();
        }

        // Create CPU with temporary pointers (will be fixed after struct is in final location)
        var cpu_instance = Cpu.init(&mem, &io_ctrl);
        cpu_instance.reset(config.initial_cs, @truncate(config.initial_ip));

        return Self{
            .cpu_instance = cpu_instance,
            .mem = mem,
            .io_ctrl = io_ctrl,
            .config = config,
            .allocator = allocator,
            .pointers_fixed = false,
        };
    }

    /// Fix CPU pointers to point to this struct's fields
    /// Must be called after struct is in its final memory location
    fn fixPointers(self: *Self) void {
        if (!self.pointers_fixed) {
            self.cpu_instance.mem = &self.mem;
            self.cpu_instance.io_ctrl = &self.io_ctrl;
            self.pointers_fixed = true;
        }
    }

    /// Clean up emulator resources
    pub fn deinit(self: *Self) void {
        self.io_ctrl.deinit();
        self.mem.deinit();
    }

    /// Execute a single instruction
    pub fn step(self: *Self) !void {
        self.fixPointers();
        try self.cpu_instance.step();
    }

    /// Run until halt or breakpoint
    pub fn run(self: *Self) !void {
        self.fixPointers();
        while (!self.cpu_instance.isHalted()) {
            self.cpu_instance.step() catch |err| {
                if (self.config.dump_on_error) {
                    std.debug.print("\n!!! CPU Error: {s} !!!\n", .{@errorName(err)});
                    self.cpu_instance.dumpState();
                }
                return err;
            };
        }
    }

    /// Run with a cycle limit (useful for testing)
    pub fn runCycles(self: *Self, max_cycles: usize) !void {
        self.fixPointers();
        var cycles: usize = 0;
        while (!self.cpu_instance.isHalted() and cycles < max_cycles) : (cycles += 1) {
            self.cpu_instance.step() catch |err| {
                if (self.config.dump_on_error) {
                    std.debug.print("\n!!! CPU Error: {s} !!!\n", .{@errorName(err)});
                    self.cpu_instance.dumpState();
                }
                return err;
            };
        }
    }

    /// Dump current CPU state (for debugging)
    pub fn dumpCpuState(self: *const Self) void {
        self.cpu_instance.dumpState();
    }

    /// Load binary code into memory at specified address
    pub fn loadBinary(self: *Self, data: []const u8, address: u32) !void {
        self.fixPointers();
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

    /// Queue keyboard scan code (for testing)
    pub fn queueKeyScanCode(self: *Self, scancode: u8) !void {
        if (self.io_ctrl.getKeyboard()) |kbd| {
            try kbd.queueScanCode(scancode);
        }
    }

    /// Queue multiple keyboard scan codes (for testing)
    pub fn queueKeyScanCodes(self: *Self, scancodes: []const u8) !void {
        if (self.io_ctrl.getKeyboard()) |kbd| {
            try kbd.queueScanCodes(scancodes);
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

    /// Load Linux kernel for direct boot
    /// Parses the kernel boot header, sets up boot parameters, and configures
    /// the CPU to begin execution at the kernel entry point.
    ///
    /// Parameters:
    ///   - kernel_data: Raw kernel image (bzImage format)
    ///   - cmdline: Kernel command line string (e.g., "console=ttyS0 root=/dev/sda1")
    ///   - initrd_data: Optional initrd/initramfs image
    ///
    /// The kernel will be loaded according to the Linux boot protocol:
    ///   - Boot parameters at 0x10000 (zero page)
    ///   - Command line at 0x20000
    ///   - Protected-mode kernel at 0x100000 (1 MB)
    ///   - Initrd at 0x7F00000 (if provided)
    ///   - CPU configured in protected mode with flat segments
    ///
    /// After calling this, use run() or step() to begin kernel execution.
    pub fn loadKernel(self: *Self, kernel_data: []const u8, cmdline: []const u8) !void {
        try self.loadKernelWithInitrd(kernel_data, cmdline, null);
    }

    /// Load Linux kernel with optional initrd for direct boot
    pub fn loadKernelWithInitrd(self: *Self, kernel_data: []const u8, cmdline: []const u8, initrd_data: ?[]const u8) !void {
        self.fixPointers();

        var direct_boot = try boot.DirectBoot.initFromMemory(self.allocator, kernel_data, cmdline);
        defer direct_boot.deinit();

        if (initrd_data) |initrd| {
            try direct_boot.setInitrdFromMemory(initrd);
        }

        try direct_boot.load(self);
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
