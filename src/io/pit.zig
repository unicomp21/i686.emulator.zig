//! PIT (Programmable Interval Timer) 8254 Emulation
//!
//! Emulates an Intel 8254 Programmable Interval Timer with 3 channels.
//! The 8254 is used for system timing, speaker control, and other periodic tasks.
//!
//! Channel 0: Connected to IRQ0 for system timer
//! Channel 1: Historically used for DRAM refresh (mostly unused in modern systems)
//! Channel 2: Connected to PC speaker
//!
//! I/O Ports:
//! - 0x40: Channel 0 data port
//! - 0x41: Channel 1 data port
//! - 0x42: Channel 2 data port
//! - 0x43: Mode/Command register

const std = @import("std");

/// PIT channel operating modes
pub const Mode = enum(u3) {
    /// Mode 0: Interrupt on terminal count
    interrupt_on_terminal_count = 0,
    /// Mode 1: Hardware retriggerable one-shot
    hardware_one_shot = 1,
    /// Mode 2: Rate generator
    rate_generator = 2,
    /// Mode 3: Square wave generator
    square_wave = 3,
    /// Mode 4: Software triggered strobe
    software_strobe = 4,
    /// Mode 5: Hardware triggered strobe
    hardware_strobe = 5,
    // Modes 6 and 7 are aliases for 2 and 3
};

/// PIT channel access mode
pub const AccessMode = enum(u2) {
    /// Latch count value
    latch = 0,
    /// Read/write low byte only
    lobyte_only = 1,
    /// Read/write high byte only
    hibyte_only = 2,
    /// Read/write low byte then high byte
    lobyte_hibyte = 3,
};

/// PIT channel state
pub const Channel = struct {
    /// Reload value (count value written by software)
    count_value: u16,
    /// Current counter value (decrements on each tick)
    current_count: u16,
    /// Operating mode (0-5)
    mode: u3,
    /// Access mode (lobyte, hibyte, lobyte/hibyte)
    access_mode: u2,
    /// BCD mode (true = BCD, false = binary)
    bcd: bool,
    /// Current output state
    output: bool,
    /// Latched count value (for latch command)
    latched_count: ?u16,
    /// Read/write state for lobyte/hibyte mode
    rw_state: enum { lobyte, hibyte },
    /// Temporary storage for lobyte/hibyte writes
    temp_value: u8,
    /// Gate input (enables/disables counting)
    gate: bool,
    /// Null count flag (count not yet loaded)
    null_count: bool,

    const Self = @This();

    /// Initialize channel
    pub fn init() Self {
        return Self{
            .count_value = 0,
            .current_count = 0,
            .mode = 0,
            .access_mode = 0,
            .bcd = false,
            .output = false,
            .latched_count = null,
            .rw_state = .lobyte,
            .temp_value = 0,
            .gate = true,
            .null_count = true,
        };
    }

    /// Reset channel to initial state
    pub fn reset(self: *Self) void {
        self.count_value = 0;
        self.current_count = 0;
        self.mode = 0;
        self.access_mode = 0;
        self.bcd = false;
        self.output = false;
        self.latched_count = null;
        self.rw_state = .lobyte;
        self.temp_value = 0;
        self.gate = true;
        self.null_count = true;
    }

    /// Latch current count value
    pub fn latchCount(self: *Self) void {
        if (self.latched_count == null) {
            self.latched_count = self.current_count;
        }
    }

    /// Read count value
    pub fn readCount(self: *Self) u8 {
        const count = self.latched_count orelse self.current_count;

        return switch (@as(AccessMode, @enumFromInt(self.access_mode))) {
            .latch => unreachable, // Should not happen
            .lobyte_only => @truncate(count),
            .hibyte_only => @truncate(count >> 8),
            .lobyte_hibyte => blk: {
                const result = switch (self.rw_state) {
                    .lobyte => @as(u8, @truncate(count)),
                    .hibyte => @as(u8, @truncate(count >> 8)),
                };
                // Toggle state for next read
                self.rw_state = if (self.rw_state == .lobyte) .hibyte else .lobyte;
                // Clear latched value after reading both bytes
                if (self.rw_state == .lobyte and self.latched_count != null) {
                    self.latched_count = null;
                }
                break :blk result;
            },
        };
    }

    /// Write count value
    pub fn writeCount(self: *Self, value: u8) void {
        switch (@as(AccessMode, @enumFromInt(self.access_mode))) {
            .latch => unreachable, // Should not happen
            .lobyte_only => {
                self.count_value = value;
                self.loadCount();
            },
            .hibyte_only => {
                self.count_value = @as(u16, value) << 8;
                self.loadCount();
            },
            .lobyte_hibyte => {
                switch (self.rw_state) {
                    .lobyte => {
                        self.temp_value = value;
                        self.rw_state = .hibyte;
                    },
                    .hibyte => {
                        self.count_value = @as(u16, value) << 8 | self.temp_value;
                        self.rw_state = .lobyte;
                        self.loadCount();
                    },
                }
            },
        }
    }

    /// Load count value into current counter
    fn loadCount(self: *Self) void {
        // Treat 0 as 65536 in binary mode
        if (self.count_value == 0 and !self.bcd) {
            self.current_count = 0; // Will wrap to 65535 on first decrement
        } else {
            self.current_count = self.count_value;
        }
        self.null_count = false;

        // Update output based on mode
        switch (self.mode) {
            0 => self.output = false, // Mode 0: output low until terminal count
            1 => self.output = true, // Mode 1: output high during one-shot
            2, 3 => self.output = true, // Mode 2/3: output high initially
            4, 5 => self.output = true, // Mode 4/5: output high initially
            else => {},
        }
    }

    /// Tick the counter (decrement)
    pub fn tick(self: *Self) void {
        if (self.null_count or !self.gate) {
            return;
        }

        switch (self.mode) {
            0 => self.tickMode0(),
            1 => self.tickMode1(),
            2 => self.tickMode2(),
            3 => self.tickMode3(),
            4 => self.tickMode4(),
            5 => self.tickMode5(),
            else => {},
        }
    }

    /// Mode 0: Interrupt on terminal count
    fn tickMode0(self: *Self) void {
        if (self.current_count == 0) {
            self.current_count = 0xFFFF;
        } else {
            self.current_count -%= 1;
            if (self.current_count == 0) {
                self.output = true; // Output goes high on terminal count
            }
        }
    }

    /// Mode 1: Hardware retriggerable one-shot
    fn tickMode1(self: *Self) void {
        if (self.current_count > 0) {
            self.current_count -%= 1;
            if (self.current_count == 0) {
                self.output = true;
            } else {
                self.output = false;
            }
        }
    }

    /// Mode 2: Rate generator
    fn tickMode2(self: *Self) void {
        self.current_count -%= 1;
        if (self.current_count == 1) {
            self.output = false; // Output low for one cycle
        } else if (self.current_count == 0) {
            self.output = true;
            // Reload count
            self.current_count = self.count_value;
            if (self.current_count == 0) {
                self.current_count = 0; // Wrap to max on next tick
            }
        }
    }

    /// Mode 3: Square wave generator
    fn tickMode3(self: *Self) void {
        self.current_count -%= 2; // Decrement by 2 for square wave
        if (self.current_count <= 1) {
            self.output = !self.output; // Toggle output
            // Reload count
            self.current_count = self.count_value;
            if (self.current_count == 0) {
                self.current_count = 0; // Wrap to max on next tick
            }
        }
    }

    /// Mode 4: Software triggered strobe
    fn tickMode4(self: *Self) void {
        if (self.current_count == 0) {
            self.current_count = 0xFFFF;
        } else {
            self.current_count -%= 1;
            if (self.current_count == 0) {
                self.output = false; // Output low for one cycle
            } else {
                self.output = true;
            }
        }
    }

    /// Mode 5: Hardware triggered strobe
    fn tickMode5(self: *Self) void {
        // Similar to mode 4 but hardware triggered
        self.tickMode4();
    }
};

/// PIT (Programmable Interval Timer) 8254
pub const Pit = struct {
    /// Three channels
    channels: [3]Channel,

    const Self = @This();

    /// PIT I/O ports
    pub const CHANNEL0_PORT: u16 = 0x40;
    pub const CHANNEL1_PORT: u16 = 0x41;
    pub const CHANNEL2_PORT: u16 = 0x42;
    pub const COMMAND_PORT: u16 = 0x43;

    /// Initialize PIT
    pub fn init() Self {
        return Self{
            .channels = [_]Channel{
                Channel.init(),
                Channel.init(),
                Channel.init(),
            },
        };
    }

    /// Reset PIT to initial state
    pub fn reset(self: *Self) void {
        for (&self.channels) |*channel| {
            channel.reset();
        }
    }

    /// Read from PIT port
    pub fn readPort(self: *Self, port: u16) u8 {
        return switch (port) {
            CHANNEL0_PORT => self.channels[0].readCount(),
            CHANNEL1_PORT => self.channels[1].readCount(),
            CHANNEL2_PORT => self.channels[2].readCount(),
            COMMAND_PORT => 0xFF, // Command port is write-only
            else => 0xFF,
        };
    }

    /// Write to PIT port
    pub fn writePort(self: *Self, port: u16, value: u8) void {
        switch (port) {
            CHANNEL0_PORT => self.channels[0].writeCount(value),
            CHANNEL1_PORT => self.channels[1].writeCount(value),
            CHANNEL2_PORT => self.channels[2].writeCount(value),
            COMMAND_PORT => self.writeCommand(value),
            else => {},
        }
    }

    /// Write to command register
    fn writeCommand(self: *Self, value: u8) void {
        const channel_select = (value >> 6) & 0x3;
        const access_mode = (value >> 4) & 0x3;
        const operating_mode = (value >> 1) & 0x7;
        const bcd = (value & 0x1) != 0;

        // Read-back command (channel_select = 3)
        if (channel_select == 3) {
            // Read-back command not fully implemented
            return;
        }

        const channel = &self.channels[channel_select];

        // Latch command
        if (access_mode == 0) {
            channel.latchCount();
            return;
        }

        // Configure channel
        channel.access_mode = @truncate(access_mode);
        channel.mode = @truncate(if (operating_mode >= 6) operating_mode - 4 else operating_mode);
        channel.bcd = bcd;
        channel.rw_state = .lobyte;
        channel.null_count = true;

        // Initialize output state based on mode
        switch (channel.mode) {
            0 => channel.output = false,
            1 => channel.output = true,
            2, 3 => channel.output = true,
            4, 5 => channel.output = true,
            else => {},
        }
    }

    /// Tick all channels (decrement counters)
    pub fn tick(self: *Self) void {
        for (&self.channels) |*channel| {
            channel.tick();
        }
    }

    /// Get output state of a channel
    pub fn getOutput(self: *const Self, channel: u8) bool {
        if (channel < 3) {
            return self.channels[channel].output;
        }
        return false;
    }

    /// Set gate input for a channel
    pub fn setGate(self: *Self, channel: u8, state: bool) void {
        if (channel < 3) {
            self.channels[channel].gate = state;
        }
    }
};

// Tests
test "pit init and reset" {
    var pit = Pit.init();
    pit.reset();
    try std.testing.expect(pit.channels[0].count_value == 0);
}

test "pit control word parsing" {
    var pit = Pit.init();

    // Configure channel 0, lobyte/hibyte, mode 2, binary
    // Channel select: 00 (channel 0)
    // Access mode: 11 (lobyte/hibyte)
    // Operating mode: 010 (mode 2)
    // BCD: 0 (binary)
    const control = (0 << 6) | (3 << 4) | (2 << 1) | 0;
    pit.writePort(Pit.COMMAND_PORT, control);

    try std.testing.expectEqual(@as(u2, 3), pit.channels[0].access_mode);
    try std.testing.expectEqual(@as(u3, 2), pit.channels[0].mode);
    try std.testing.expectEqual(false, pit.channels[0].bcd);
}

test "pit count value write lobyte only" {
    var pit = Pit.init();

    // Configure channel 0, lobyte only, mode 2, binary
    const control = (0 << 6) | (1 << 4) | (2 << 1) | 0;
    pit.writePort(Pit.COMMAND_PORT, control);

    // Write count value
    pit.writePort(Pit.CHANNEL0_PORT, 0x10);

    try std.testing.expectEqual(@as(u16, 0x10), pit.channels[0].count_value);
    try std.testing.expectEqual(@as(u16, 0x10), pit.channels[0].current_count);
}

test "pit count value write lobyte/hibyte" {
    var pit = Pit.init();

    // Configure channel 0, lobyte/hibyte, mode 2, binary
    const control = (0 << 6) | (3 << 4) | (2 << 1) | 0;
    pit.writePort(Pit.COMMAND_PORT, control);

    // Write count value (lobyte then hibyte)
    pit.writePort(Pit.CHANNEL0_PORT, 0x34); // Low byte
    pit.writePort(Pit.CHANNEL0_PORT, 0x12); // High byte

    try std.testing.expectEqual(@as(u16, 0x1234), pit.channels[0].count_value);
    try std.testing.expectEqual(@as(u16, 0x1234), pit.channels[0].current_count);
}

test "pit count value read lobyte/hibyte" {
    var pit = Pit.init();

    // Configure channel 0, lobyte/hibyte, mode 2, binary
    const control = (0 << 6) | (3 << 4) | (2 << 1) | 0;
    pit.writePort(Pit.COMMAND_PORT, control);

    // Write count value
    pit.writePort(Pit.CHANNEL0_PORT, 0x78); // Low byte
    pit.writePort(Pit.CHANNEL0_PORT, 0x56); // High byte

    // Read count value
    const lo = pit.readPort(Pit.CHANNEL0_PORT);
    const hi = pit.readPort(Pit.CHANNEL0_PORT);

    try std.testing.expectEqual(@as(u8, 0x78), lo);
    try std.testing.expectEqual(@as(u8, 0x56), hi);
}

test "pit countdown mode 2" {
    var pit = Pit.init();

    // Configure channel 0, lobyte/hibyte, mode 2 (rate generator), binary
    const control = (0 << 6) | (3 << 4) | (2 << 1) | 0;
    pit.writePort(Pit.COMMAND_PORT, control);

    // Set count to 5
    pit.writePort(Pit.CHANNEL0_PORT, 5); // Low byte
    pit.writePort(Pit.CHANNEL0_PORT, 0); // High byte

    try std.testing.expectEqual(@as(u16, 5), pit.channels[0].current_count);
    try std.testing.expectEqual(true, pit.channels[0].output);

    // Tick 4 times
    pit.tick();
    try std.testing.expectEqual(@as(u16, 4), pit.channels[0].current_count);
    try std.testing.expectEqual(true, pit.channels[0].output);

    pit.tick();
    try std.testing.expectEqual(@as(u16, 3), pit.channels[0].current_count);
    try std.testing.expectEqual(true, pit.channels[0].output);

    pit.tick();
    try std.testing.expectEqual(@as(u16, 2), pit.channels[0].current_count);
    try std.testing.expectEqual(true, pit.channels[0].output);

    pit.tick();
    try std.testing.expectEqual(@as(u16, 1), pit.channels[0].current_count);
    try std.testing.expectEqual(false, pit.channels[0].output); // Output low for 1 cycle

    // Next tick should reload
    pit.tick();
    try std.testing.expectEqual(@as(u16, 5), pit.channels[0].current_count);
    try std.testing.expectEqual(true, pit.channels[0].output);
}

test "pit latch count" {
    var pit = Pit.init();

    // Configure channel 0, lobyte/hibyte, mode 2, binary
    const control = (0 << 6) | (3 << 4) | (2 << 1) | 0;
    pit.writePort(Pit.COMMAND_PORT, control);

    // Set count to 100
    pit.writePort(Pit.CHANNEL0_PORT, 100);
    pit.writePort(Pit.CHANNEL0_PORT, 0);

    // Tick a few times
    pit.tick();
    pit.tick();
    pit.tick();

    // Latch count (access mode 0)
    const latch_cmd = (0 << 6) | (0 << 4) | (0 << 1) | 0;
    pit.writePort(Pit.COMMAND_PORT, latch_cmd);

    const latched_count = pit.channels[0].current_count;

    // Continue ticking
    pit.tick();
    pit.tick();

    // Read latched value (should be the value when latch was issued)
    const lo = pit.readPort(Pit.CHANNEL0_PORT);
    const hi = pit.readPort(Pit.CHANNEL0_PORT);
    const read_count = @as(u16, hi) << 8 | lo;

    try std.testing.expectEqual(latched_count, read_count);
}
