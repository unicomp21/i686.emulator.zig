//! PIC 8259 (Programmable Interrupt Controller) Emulation
//!
//! Emulates the Intel 8259 PIC, which manages hardware interrupts.
//! The PC typically uses two PICs in cascade mode:
//! - Master PIC at ports 0x20-0x21
//! - Slave PIC at ports 0xA0-0xA1

const std = @import("std");

/// Initialization Command Word 1 bits
pub const ICW1 = struct {
    pub const ICW4_NEEDED: u8 = 0x01;
    pub const SINGLE_MODE: u8 = 0x02;
    pub const INTERVAL_4: u8 = 0x04;
    pub const LEVEL_TRIGGERED: u8 = 0x08;
    pub const INIT: u8 = 0x10;
};

/// Initialization Command Word 4 bits
pub const ICW4 = struct {
    pub const MODE_8086: u8 = 0x01;
    pub const AUTO_EOI: u8 = 0x02;
    pub const BUF_SLAVE: u8 = 0x08;
    pub const BUF_MASTER: u8 = 0x0C;
    pub const SFNM: u8 = 0x10;
};

/// Operational Command Word 2 bits
pub const OCW2 = struct {
    pub const EOI: u8 = 0x20;
    pub const SPECIFIC_EOI: u8 = 0x60;
    pub const ROTATE_AUTO_EOI: u8 = 0x80;
};

/// Operational Command Word 3 bits
pub const OCW3 = struct {
    pub const READ_IRR: u8 = 0x0A;
    pub const READ_ISR: u8 = 0x0B;
};

/// PIC initialization state
const InitState = enum {
    ready,
    wait_icw2,
    wait_icw3,
    wait_icw4,
};

/// PIC 8259 emulation
pub const Pic = struct {
    /// Interrupt Request Register - pending interrupts
    irr: u8,
    /// In-Service Register - interrupts being serviced
    isr: u8,
    /// Interrupt Mask Register - masked interrupts (1 = masked)
    imr: u8,
    /// Vector base offset (from ICW2)
    vector_base: u8,
    /// ICW1 value
    icw1: u8,
    /// ICW2 value
    icw2: u8,
    /// ICW3 value (cascade mode)
    icw3: u8,
    /// ICW4 value
    icw4: u8,
    /// Initialization state
    init_state: InitState,
    /// Read register select (IRR or ISR)
    read_isr: bool,
    /// Auto EOI mode
    auto_eoi: bool,
    /// Priority rotation base
    priority_base: u3,

    const Self = @This();

    /// Initialize PIC
    pub fn init() Self {
        return Self{
            .irr = 0,
            .isr = 0,
            .imr = 0xFF, // All interrupts masked by default
            .vector_base = 0,
            .icw1 = 0,
            .icw2 = 0,
            .icw3 = 0,
            .icw4 = 0,
            .init_state = .ready,
            .read_isr = false,
            .auto_eoi = false,
            .priority_base = 0,
        };
    }

    /// Reset PIC to initial state
    pub fn reset(self: *Self) void {
        self.* = init();
    }

    /// Read from PIC port
    pub fn readPort(self: *Self, port_offset: u1) u8 {
        return switch (port_offset) {
            0 => { // Command port (0x20 or 0xA0)
                // Return IRR or ISR based on OCW3 read command
                if (self.read_isr) {
                    return self.isr;
                } else {
                    return self.irr;
                }
            },
            1 => { // Data port (0x21 or 0xA1)
                // Return IMR
                return self.imr;
            },
        };
    }

    /// Write to PIC port
    pub fn writePort(self: *Self, port_offset: u1, value: u8) void {
        switch (port_offset) {
            0 => { // Command port (0x20 or 0xA0)
                if ((value & ICW1.INIT) != 0) {
                    // ICW1 - Start initialization sequence
                    self.icw1 = value;
                    self.init_state = .wait_icw2;
                    self.imr = 0xFF; // Mask all interrupts during init
                    self.isr = 0;
                    self.irr = 0;
                } else if ((value & 0x08) != 0) {
                    // OCW3 - Read command
                    if ((value & 0x03) == 0x02) {
                        self.read_isr = false; // Read IRR
                    } else if ((value & 0x03) == 0x03) {
                        self.read_isr = true; // Read ISR
                    }
                } else {
                    // OCW2 - EOI and rotation commands
                    if ((value & OCW2.EOI) != 0) {
                        if ((value & 0x40) != 0) {
                            // Specific EOI
                            const irq: u3 = @truncate(value & 0x07);
                            self.isr &= ~(@as(u8, 1) << irq);
                        } else {
                            // Non-specific EOI - clear highest priority ISR bit
                            if (self.isr != 0) {
                                // Find highest priority (lowest bit number)
                                var irq: u4 = 0;
                                while (irq < 8) : (irq += 1) {
                                    const rotated: u3 = @truncate((irq +% self.priority_base) % 8);
                                    if ((self.isr & (@as(u8, 1) << rotated)) != 0) {
                                        self.isr &= ~(@as(u8, 1) << rotated);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    // Handle rotation commands if needed
                    if ((value & 0x80) != 0) {
                        self.auto_eoi = true;
                    }
                }
            },
            1 => { // Data port (0x21 or 0xA1)
                switch (self.init_state) {
                    .ready => {
                        // OCW1 - Set IMR
                        self.imr = value;
                    },
                    .wait_icw2 => {
                        // ICW2 - Vector base
                        self.icw2 = value;
                        self.vector_base = value;

                        // Check if we need ICW3 (cascade mode, not single)
                        if ((self.icw1 & ICW1.SINGLE_MODE) != 0) {
                            // Single mode - check if ICW4 needed
                            if ((self.icw1 & ICW1.ICW4_NEEDED) != 0) {
                                self.init_state = .wait_icw4;
                            } else {
                                self.init_state = .ready;
                                self.imr = 0xFF; // Keep all masked until explicitly unmasked
                            }
                        } else {
                            self.init_state = .wait_icw3;
                        }
                    },
                    .wait_icw3 => {
                        // ICW3 - Cascade configuration
                        self.icw3 = value;

                        // Check if ICW4 needed
                        if ((self.icw1 & ICW1.ICW4_NEEDED) != 0) {
                            self.init_state = .wait_icw4;
                        } else {
                            self.init_state = .ready;
                            self.imr = 0xFF; // Keep all masked until explicitly unmasked
                        }
                    },
                    .wait_icw4 => {
                        // ICW4 - Special modes
                        self.icw4 = value;
                        self.auto_eoi = (value & ICW4.AUTO_EOI) != 0;
                        self.init_state = .ready;
                        self.imr = 0xFF; // Keep all masked until explicitly unmasked
                    },
                }
            },
        }
    }

    /// Raise an IRQ line (set bit in IRR)
    pub fn raiseIRQ(self: *Self, irq: u3) void {
        self.irr |= @as(u8, 1) << irq;
    }

    /// Lower an IRQ line (clear bit in IRR)
    pub fn lowerIRQ(self: *Self, irq: u3) void {
        self.irr &= ~(@as(u8, 1) << irq);
    }

    /// Get highest priority pending interrupt
    /// Returns the interrupt vector number, or null if no interrupt pending
    pub fn getInterruptVector(self: *Self) ?u8 {
        // Check for pending unmasked interrupts
        const pending = self.irr & ~self.imr;
        if (pending == 0) {
            return null;
        }

        // Find highest priority IRQ (considering rotation)
        var irq: u4 = 0;
        while (irq < 8) : (irq += 1) {
            const rotated: u3 = @truncate((irq +% self.priority_base) % 8);
            if ((pending & (@as(u8, 1) << rotated)) != 0) {
                // Move to ISR and clear from IRR
                self.isr |= @as(u8, 1) << rotated;
                self.irr &= ~(@as(u8, 1) << rotated);

                // Return interrupt vector
                return self.vector_base + rotated;
            }
        }

        return null;
    }

    /// Check if any interrupt is pending (for testing)
    pub fn hasPendingInterrupt(self: *const Self) bool {
        const pending = self.irr & ~self.imr;
        return pending != 0;
    }

    /// Get IRR value (for testing)
    pub fn getIRR(self: *const Self) u8 {
        return self.irr;
    }

    /// Get ISR value (for testing)
    pub fn getISR(self: *const Self) u8 {
        return self.isr;
    }

    /// Get IMR value (for testing)
    pub fn getIMR(self: *const Self) u8 {
        return self.imr;
    }
};

// Tests
test "pic init" {
    const pic = Pic.init();
    try std.testing.expectEqual(@as(u8, 0), pic.irr);
    try std.testing.expectEqual(@as(u8, 0), pic.isr);
    try std.testing.expectEqual(@as(u8, 0xFF), pic.imr); // All masked
}

test "pic initialization sequence" {
    var pic = Pic.init();

    // Standard PC PIC initialization:
    // Master PIC: vector base 0x20

    // ICW1: Init + ICW4 needed
    pic.writePort(0, ICW1.INIT | ICW1.ICW4_NEEDED);

    // ICW2: Vector base 0x20
    pic.writePort(1, 0x20);

    // ICW3: Slave on IRQ2 (master = 0x04)
    pic.writePort(1, 0x04);

    // ICW4: 8086 mode
    pic.writePort(1, ICW4.MODE_8086);

    try std.testing.expectEqual(@as(u8, 0x20), pic.vector_base);
    try std.testing.expectEqual(InitState.ready, pic.init_state);
}

test "pic irq raising and masking" {
    var pic = Pic.init();

    // Initialize PIC
    pic.writePort(0, ICW1.INIT | ICW1.ICW4_NEEDED);
    pic.writePort(1, 0x20); // Vector base
    pic.writePort(1, 0x04); // ICW3
    pic.writePort(1, ICW4.MODE_8086);

    // Raise IRQ 1
    pic.raiseIRQ(1);
    try std.testing.expectEqual(@as(u8, 0x02), pic.irr);

    // IRQ is masked, so no interrupt should be pending
    try std.testing.expect(!pic.hasPendingInterrupt());

    // Unmask IRQ 1
    pic.writePort(1, 0xFD); // All masked except bit 1

    // Now interrupt should be pending
    try std.testing.expect(pic.hasPendingInterrupt());
}

test "pic get interrupt vector" {
    var pic = Pic.init();

    // Initialize PIC with vector base 0x20
    pic.writePort(0, ICW1.INIT | ICW1.ICW4_NEEDED);
    pic.writePort(1, 0x20);
    pic.writePort(1, 0x04);
    pic.writePort(1, ICW4.MODE_8086);

    // Unmask all interrupts
    pic.writePort(1, 0x00);

    // Raise IRQ 1
    pic.raiseIRQ(1);

    // Get interrupt vector - should be 0x20 + 1 = 0x21
    const vector = pic.getInterruptVector();
    try std.testing.expect(vector != null);
    try std.testing.expectEqual(@as(u8, 0x21), vector.?);

    // IRQ should now be in ISR and cleared from IRR
    try std.testing.expectEqual(@as(u8, 0x00), pic.irr);
    try std.testing.expectEqual(@as(u8, 0x02), pic.isr);
}

test "pic eoi command" {
    var pic = Pic.init();

    // Initialize
    pic.writePort(0, ICW1.INIT | ICW1.ICW4_NEEDED);
    pic.writePort(1, 0x20);
    pic.writePort(1, 0x04);
    pic.writePort(1, ICW4.MODE_8086);
    pic.writePort(1, 0x00); // Unmask all

    // Raise and get IRQ 1
    pic.raiseIRQ(1);
    _ = pic.getInterruptVector();

    // ISR should have bit 1 set
    try std.testing.expectEqual(@as(u8, 0x02), pic.isr);

    // Send EOI
    pic.writePort(0, OCW2.EOI);

    // ISR should be cleared
    try std.testing.expectEqual(@as(u8, 0x00), pic.isr);
}

test "pic read irr and isr" {
    var pic = Pic.init();

    // Initialize
    pic.writePort(0, ICW1.INIT | ICW1.ICW4_NEEDED);
    pic.writePort(1, 0x20);
    pic.writePort(1, 0x04);
    pic.writePort(1, ICW4.MODE_8086);

    // Raise IRQ 3
    pic.raiseIRQ(3);

    // Read IRR (default)
    const irr = pic.readPort(0);
    try std.testing.expectEqual(@as(u8, 0x08), irr);

    // Unmask and get interrupt
    pic.writePort(1, 0x00);
    _ = pic.getInterruptVector();

    // Read ISR via OCW3
    pic.writePort(0, OCW3.READ_ISR);
    const isr = pic.readPort(0);
    try std.testing.expectEqual(@as(u8, 0x08), isr);
}
