//! I/O Controller
//!
//! Manages I/O port access and peripheral devices for the i686 emulator.
//! Supports UART for testing and debugging output.

const std = @import("std");
const uart_mod = @import("uart.zig");

pub const Uart = uart_mod.Uart;

/// I/O access errors
pub const IoError = error{
    PortNotMapped,
    DeviceError,
};

/// I/O port handler function type
pub const PortHandler = struct {
    read: *const fn (u16) u8,
    write: *const fn (u16, u8) void,
};

/// I/O Controller manages all port-mapped I/O devices
pub const IoController = struct {
    /// UART devices (up to 4 COM ports)
    uarts: [4]?Uart,
    /// UART base addresses
    uart_bases: [4]u16,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Standard COM port base addresses
    pub const COM1_BASE: u16 = 0x3F8;
    pub const COM2_BASE: u16 = 0x2F8;
    pub const COM3_BASE: u16 = 0x3E8;
    pub const COM4_BASE: u16 = 0x2E8;

    /// Initialize I/O controller
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .uarts = [_]?Uart{ null, null, null, null },
            .uart_bases = [_]u16{ 0, 0, 0, 0 },
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        for (&self.uarts) |*uart_opt| {
            if (uart_opt.*) |*uart| {
                uart.deinit();
            }
        }
    }

    /// Reset all devices
    pub fn reset(self: *Self) void {
        for (&self.uarts) |*uart_opt| {
            if (uart_opt.*) |*uart| {
                uart.reset();
            }
        }
    }

    /// Register a UART at the specified base address
    pub fn registerUart(self: *Self, base: u16) !void {
        for (0..4) |i| {
            if (self.uart_bases[i] == 0) {
                self.uarts[i] = Uart.init(self.allocator);
                self.uart_bases[i] = base;
                return;
            }
        }
        return IoError.DeviceError;
    }

    /// Get UART by base address
    pub fn getUart(self: *Self, base: u16) ?*Uart {
        for (0..4) |i| {
            if (self.uart_bases[i] == base) {
                if (self.uarts[i] != null) {
                    return &self.uarts[i].?;
                }
            }
        }
        return null;
    }

    /// Find UART for a port address
    fn findUartForPort(self: *Self, port: u16) ?*Uart {
        for (0..4) |i| {
            const base = self.uart_bases[i];
            if (base != 0 and port >= base and port < base + 8) {
                if (self.uarts[i] != null) {
                    return &self.uarts[i].?;
                }
            }
        }
        return null;
    }

    /// Find UART base for a port
    fn findUartBase(self: *const Self, port: u16) ?u16 {
        for (0..4) |i| {
            const base = self.uart_bases[i];
            if (base != 0 and port >= base and port < base + 8) {
                return base;
            }
        }
        return null;
    }

    /// Read byte from I/O port
    pub fn readByte(self: *Self, port: u16) !u8 {
        // Check for UART
        if (self.findUartForPort(port)) |uart| {
            if (self.findUartBase(port)) |base| {
                const offset: u3 = @truncate(port - base);
                return uart.readRegister(offset);
            }
        }

        // Unhandled ports return 0xFF
        return 0xFF;
    }

    /// Write byte to I/O port
    pub fn writeByte(self: *Self, port: u16, value: u8) !void {
        // Check for UART
        if (self.findUartForPort(port)) |uart| {
            if (self.findUartBase(port)) |base| {
                const offset: u3 = @truncate(port - base);
                uart.writeRegister(offset, value);
                return;
            }
        }

        // Unhandled ports are ignored
    }
};

// Tests
test "io controller init" {
    const allocator = std.testing.allocator;
    var io = IoController.init(allocator);
    defer io.deinit();
}

test "io controller uart registration" {
    const allocator = std.testing.allocator;
    var io = IoController.init(allocator);
    defer io.deinit();

    try io.registerUart(IoController.COM1_BASE);

    const uart = io.getUart(IoController.COM1_BASE);
    try std.testing.expect(uart != null);
}

test "io controller uart read/write" {
    const allocator = std.testing.allocator;
    var io = IoController.init(allocator);
    defer io.deinit();

    try io.registerUart(IoController.COM1_BASE);

    // Write to THR (transmit)
    try io.writeByte(IoController.COM1_BASE, 'A');

    // Check UART received the data
    const uart = io.getUart(IoController.COM1_BASE);
    try std.testing.expect(uart != null);
    if (uart) |u| {
        const output = u.getOutputBuffer();
        try std.testing.expectEqual(@as(usize, 1), output.len);
        try std.testing.expectEqual(@as(u8, 'A'), output[0]);
    }
}
