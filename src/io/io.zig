//! I/O Controller
//!
//! Manages I/O port access and peripheral devices for the i686 emulator.
//! Supports UART for testing and debugging output, PIT for system timing, and PIC for interrupt management.

const std = @import("std");
const uart_mod = @import("uart.zig");
const pit_mod = @import("pit.zig");
const pic_mod = @import("pic.zig");

pub const Uart = uart_mod.Uart;
pub const Pit = pit_mod.Pit;
pub const Pic = pic_mod.Pic;

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
    /// PIT (Programmable Interval Timer) 8254
    pit: ?Pit,
    /// Master PIC (8259) at 0x20-0x21
    master_pic: ?Pic,
    /// Slave PIC (8259) at 0xA0-0xA1
    slave_pic: ?Pic,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Standard COM port base addresses
    pub const COM1_BASE: u16 = 0x3F8;
    pub const COM2_BASE: u16 = 0x2F8;
    pub const COM3_BASE: u16 = 0x3E8;
    pub const COM4_BASE: u16 = 0x2E8;

    /// PIC port addresses
    pub const MASTER_PIC_CMD: u16 = 0x20;
    pub const MASTER_PIC_DATA: u16 = 0x21;
    pub const SLAVE_PIC_CMD: u16 = 0xA0;
    pub const SLAVE_PIC_DATA: u16 = 0xA1;

    /// Initialize I/O controller
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .uarts = [_]?Uart{ null, null, null, null },
            .uart_bases = [_]u16{ 0, 0, 0, 0 },
            .pit = null,
            .master_pic = null,
            .slave_pic = null,
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
        if (self.pit) |*pit| {
            pit.reset();
        }
        if (self.master_pic) |*pic| {
            pic.reset();
        }
        if (self.slave_pic) |*pic| {
            pic.reset();
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

    /// Register the PIT (Programmable Interval Timer)
    pub fn registerPit(self: *Self) void {
        self.pit = Pit.init();
    }

    /// Get PIT
    pub fn getPit(self: *Self) ?*Pit {
        if (self.pit != null) {
            return &self.pit.?;
        }
        return null;
    }

    /// Register the master PIC (8259) at ports 0x20-0x21
    pub fn registerMasterPic(self: *Self) void {
        self.master_pic = Pic.init();
    }

    /// Register the slave PIC (8259) at ports 0xA0-0xA1
    pub fn registerSlavePic(self: *Self) void {
        self.slave_pic = Pic.init();
    }

    /// Get master PIC
    pub fn getMasterPic(self: *Self) ?*Pic {
        if (self.master_pic != null) {
            return &self.master_pic.?;
        }
        return null;
    }

    /// Get slave PIC
    pub fn getSlavePic(self: *Self) ?*Pic {
        if (self.slave_pic != null) {
            return &self.slave_pic.?;
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
        // Check for master PIC (0x20-0x21)
        if (port == MASTER_PIC_CMD or port == MASTER_PIC_DATA) {
            if (self.master_pic) |*pic| {
                const offset: u1 = @truncate(port - MASTER_PIC_CMD);
                return pic.readPort(offset);
            }
        }

        // Check for slave PIC (0xA0-0xA1)
        if (port == SLAVE_PIC_CMD or port == SLAVE_PIC_DATA) {
            if (self.slave_pic) |*pic| {
                const offset: u1 = @truncate(port - SLAVE_PIC_CMD);
                return pic.readPort(offset);
            }
        }

        // Check for PIT (0x40-0x43)
        if (port >= 0x40 and port <= 0x43) {
            if (self.pit) |*pit| {
                return pit.readPort(port);
            }
        }

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
        // Check for master PIC (0x20-0x21)
        if (port == MASTER_PIC_CMD or port == MASTER_PIC_DATA) {
            if (self.master_pic) |*pic| {
                const offset: u1 = @truncate(port - MASTER_PIC_CMD);
                pic.writePort(offset, value);
                return;
            }
        }

        // Check for slave PIC (0xA0-0xA1)
        if (port == SLAVE_PIC_CMD or port == SLAVE_PIC_DATA) {
            if (self.slave_pic) |*pic| {
                const offset: u1 = @truncate(port - SLAVE_PIC_CMD);
                pic.writePort(offset, value);
                return;
            }
        }

        // Check for PIT (0x40-0x43)
        if (port >= 0x40 and port <= 0x43) {
            if (self.pit) |*pit| {
                pit.writePort(port, value);
                return;
            }
        }

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

test "io controller pit registration" {
    const allocator = std.testing.allocator;
    var io = IoController.init(allocator);
    defer io.deinit();

    io.registerPit();

    const pit = io.getPit();
    try std.testing.expect(pit != null);
}

test "io controller pit read/write" {
    const allocator = std.testing.allocator;
    var io = IoController.init(allocator);
    defer io.deinit();

    io.registerPit();

    // Configure channel 0, lobyte only, mode 2, binary
    const control = (0 << 6) | (1 << 4) | (2 << 1) | 0;
    try io.writeByte(0x43, control);

    // Write count value
    try io.writeByte(0x40, 0x50);

    // Read count value
    const count = try io.readByte(0x40);
    try std.testing.expectEqual(@as(u8, 0x50), count);
}

test "io controller pic registration" {
    const allocator = std.testing.allocator;
    var io = IoController.init(allocator);
    defer io.deinit();

    // Register both PICs
    io.registerMasterPic();
    io.registerSlavePic();

    const master = io.getMasterPic();
    const slave = io.getSlavePic();
    try std.testing.expect(master != null);
    try std.testing.expect(slave != null);
}

test "io controller pic initialization" {
    const allocator = std.testing.allocator;
    var io = IoController.init(allocator);
    defer io.deinit();

    // Register master PIC
    io.registerMasterPic();

    // Standard PC PIC initialization: master at 0x20, slave at 0x28
    const ICW1_INIT = 0x10;
    const ICW1_ICW4 = 0x01;
    const ICW4_8086 = 0x01;

    // Initialize master PIC with vector base 0x20
    try io.writeByte(IoController.MASTER_PIC_CMD, ICW1_INIT | ICW1_ICW4);
    try io.writeByte(IoController.MASTER_PIC_DATA, 0x20); // ICW2: vector base
    try io.writeByte(IoController.MASTER_PIC_DATA, 0x04); // ICW3: slave on IRQ2
    try io.writeByte(IoController.MASTER_PIC_DATA, ICW4_8086); // ICW4: 8086 mode

    // Check that PIC is initialized
    const master = io.getMasterPic();
    try std.testing.expect(master != null);
    if (master) |pic| {
        try std.testing.expectEqual(@as(u8, 0x20), pic.vector_base);
    }
}
