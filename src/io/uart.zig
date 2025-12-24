//! UART (16550A) Emulation
//!
//! Emulates a 16550A-compatible UART for serial I/O.
//! Used for testing and debugging the emulator.

const std = @import("std");

/// UART register offsets
pub const UartRegister = enum(u3) {
    /// Receive Buffer / Transmit Holding Register (DLAB=0)
    RBR_THR = 0,
    /// Interrupt Enable Register (DLAB=0)
    IER = 1,
    /// Interrupt Identification / FIFO Control Register
    IIR_FCR = 2,
    /// Line Control Register
    LCR = 3,
    /// Modem Control Register
    MCR = 4,
    /// Line Status Register
    LSR = 5,
    /// Modem Status Register
    MSR = 6,
    /// Scratch Register
    SCR = 7,
};

/// Line Status Register bits
pub const LSR = struct {
    pub const DATA_READY: u8 = 0x01;
    pub const OVERRUN_ERROR: u8 = 0x02;
    pub const PARITY_ERROR: u8 = 0x04;
    pub const FRAMING_ERROR: u8 = 0x08;
    pub const BREAK_INTERRUPT: u8 = 0x10;
    pub const THR_EMPTY: u8 = 0x20;
    pub const TRANSMITTER_EMPTY: u8 = 0x40;
    pub const FIFO_ERROR: u8 = 0x80;
};

/// Line Control Register bits
pub const LCR = struct {
    pub const DLAB: u8 = 0x80;
};

/// UART emulation
pub const Uart = struct {
    /// Receive buffer (input from host)
    rx_buffer: std.ArrayList(u8),
    /// Transmit buffer (output to host)
    tx_buffer: std.ArrayList(u8),
    /// Interrupt Enable Register
    ier: u8,
    /// Line Control Register
    lcr: u8,
    /// Modem Control Register
    mcr: u8,
    /// Scratch Register
    scr: u8,
    /// Divisor Latch (low byte)
    dll: u8,
    /// Divisor Latch (high byte)
    dlh: u8,
    /// FIFO Control Register state
    fcr: u8,

    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize UART
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .rx_buffer = std.ArrayList(u8).init(allocator),
            .tx_buffer = std.ArrayList(u8).init(allocator),
            .ier = 0,
            .lcr = 0,
            .mcr = 0,
            .scr = 0,
            .dll = 0,
            .dlh = 0,
            .fcr = 0,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.rx_buffer.deinit();
        self.tx_buffer.deinit();
    }

    /// Reset UART to initial state
    pub fn reset(self: *Self) void {
        self.rx_buffer.clearRetainingCapacity();
        self.tx_buffer.clearRetainingCapacity();
        self.ier = 0;
        self.lcr = 0;
        self.mcr = 0;
        self.scr = 0;
        self.dll = 0;
        self.dlh = 0;
        self.fcr = 0;
    }

    /// Read from UART register
    pub fn readRegister(self: *Self, offset: u3) u8 {
        const dlab = (self.lcr & LCR.DLAB) != 0;

        return switch (@as(UartRegister, @enumFromInt(offset))) {
            .RBR_THR => {
                if (dlab) {
                    return self.dll;
                }
                // Read from receive buffer
                if (self.rx_buffer.items.len > 0) {
                    return self.rx_buffer.orderedRemove(0);
                }
                return 0;
            },
            .IER => {
                if (dlab) {
                    return self.dlh;
                }
                return self.ier;
            },
            .IIR_FCR => {
                // IIR: No interrupt pending, FIFO enabled
                return 0xC1;
            },
            .LCR => self.lcr,
            .MCR => self.mcr,
            .LSR => {
                var lsr: u8 = LSR.THR_EMPTY | LSR.TRANSMITTER_EMPTY;
                if (self.rx_buffer.items.len > 0) {
                    lsr |= LSR.DATA_READY;
                }
                return lsr;
            },
            .MSR => {
                // Modem status: CTS and DSR active
                return 0x30;
            },
            .SCR => self.scr,
        };
    }

    /// Write to UART register
    pub fn writeRegister(self: *Self, offset: u3, value: u8) void {
        const dlab = (self.lcr & LCR.DLAB) != 0;

        switch (@as(UartRegister, @enumFromInt(offset))) {
            .RBR_THR => {
                if (dlab) {
                    self.dll = value;
                } else {
                    // Write to transmit buffer
                    self.tx_buffer.append(value) catch {};
                }
            },
            .IER => {
                if (dlab) {
                    self.dlh = value;
                } else {
                    self.ier = value;
                }
            },
            .IIR_FCR => {
                self.fcr = value;
                // FIFO reset bits
                if ((value & 0x02) != 0) {
                    self.rx_buffer.clearRetainingCapacity();
                }
                if ((value & 0x04) != 0) {
                    self.tx_buffer.clearRetainingCapacity();
                }
            },
            .LCR => self.lcr = value,
            .MCR => self.mcr = value,
            .LSR => {}, // Read-only
            .MSR => {}, // Read-only
            .SCR => self.scr = value,
        }
    }

    /// Get output buffer (transmitted data)
    pub fn getOutputBuffer(self: *const Self) []const u8 {
        return self.tx_buffer.items;
    }

    /// Clear output buffer
    pub fn clearOutputBuffer(self: *Self) void {
        self.tx_buffer.clearRetainingCapacity();
    }

    /// Send input data (to be received by emulated code)
    pub fn sendInput(self: *Self, data: []const u8) !void {
        try self.rx_buffer.appendSlice(data);
    }

    /// Check if there's data available to read
    pub fn hasData(self: *const Self) bool {
        return self.rx_buffer.items.len > 0;
    }

    /// Get output as string (for testing)
    pub fn getOutputString(self: *const Self) []const u8 {
        return self.tx_buffer.items;
    }
};

// Tests
test "uart init and deinit" {
    const allocator = std.testing.allocator;
    var uart = Uart.init(allocator);
    defer uart.deinit();
}

test "uart transmit" {
    const allocator = std.testing.allocator;
    var uart = Uart.init(allocator);
    defer uart.deinit();

    // Write characters to THR
    uart.writeRegister(0, 'H');
    uart.writeRegister(0, 'i');
    uart.writeRegister(0, '!');

    const output = uart.getOutputBuffer();
    try std.testing.expectEqualStrings("Hi!", output);
}

test "uart receive" {
    const allocator = std.testing.allocator;
    var uart = Uart.init(allocator);
    defer uart.deinit();

    // Send input
    try uart.sendInput("Test");

    // Check LSR shows data ready
    const lsr = uart.readRegister(5);
    try std.testing.expect((lsr & LSR.DATA_READY) != 0);

    // Read characters
    try std.testing.expectEqual(@as(u8, 'T'), uart.readRegister(0));
    try std.testing.expectEqual(@as(u8, 'e'), uart.readRegister(0));
    try std.testing.expectEqual(@as(u8, 's'), uart.readRegister(0));
    try std.testing.expectEqual(@as(u8, 't'), uart.readRegister(0));
}

test "uart line status" {
    const allocator = std.testing.allocator;
    var uart = Uart.init(allocator);
    defer uart.deinit();

    // Initially, transmitter should be empty and ready
    var lsr = uart.readRegister(5);
    try std.testing.expect((lsr & LSR.THR_EMPTY) != 0);
    try std.testing.expect((lsr & LSR.DATA_READY) == 0);

    // Add receive data
    try uart.sendInput("X");
    lsr = uart.readRegister(5);
    try std.testing.expect((lsr & LSR.DATA_READY) != 0);
}

test "uart divisor latch" {
    const allocator = std.testing.allocator;
    var uart = Uart.init(allocator);
    defer uart.deinit();

    // Set DLAB
    uart.writeRegister(3, LCR.DLAB);

    // Write divisor
    uart.writeRegister(0, 0x01); // DLL
    uart.writeRegister(1, 0x00); // DLH

    try std.testing.expectEqual(@as(u8, 0x01), uart.dll);
    try std.testing.expectEqual(@as(u8, 0x00), uart.dlh);

    // Clear DLAB
    uart.writeRegister(3, 0);

    // Now writes should go to THR
    uart.writeRegister(0, 'A');
    try std.testing.expectEqual(@as(u8, 'A'), uart.tx_buffer.items[0]);
}
