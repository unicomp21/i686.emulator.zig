//! 8042 Keyboard Controller Emulation
//!
//! Emulates the Intel 8042 PS/2 keyboard controller used in PC systems.
//! Provides keyboard input, system control, and legacy compatibility.

const std = @import("std");

/// Standard port addresses
pub const DATA_PORT: u16 = 0x60;
pub const STATUS_PORT: u16 = 0x64;
pub const COMMAND_PORT: u16 = 0x64;

/// Status register bits (port 0x64 read)
pub const Status = struct {
    /// Bit 0: Output buffer full (data available to read from 0x60)
    pub const OUTPUT_BUFFER_FULL: u8 = 0x01;
    /// Bit 1: Input buffer full (data still being processed)
    pub const INPUT_BUFFER_FULL: u8 = 0x02;
    /// Bit 2: System flag (1 = system passed POST)
    pub const SYSTEM_FLAG: u8 = 0x04;
    /// Bit 3: Command/data (0 = data, 1 = command)
    pub const COMMAND_DATA: u8 = 0x08;
    /// Bit 4: Keyboard enabled (1 = enabled, 0 = disabled)
    pub const KEYBOARD_ENABLED: u8 = 0x10;
    /// Bit 5: Transmit timeout
    pub const TRANSMIT_TIMEOUT: u8 = 0x20;
    /// Bit 6: Receive timeout
    pub const RECEIVE_TIMEOUT: u8 = 0x40;
    /// Bit 7: Parity error
    pub const PARITY_ERROR: u8 = 0x80;
};

/// Controller commands (port 0x64 write)
pub const Command = enum(u8) {
    /// 0x20-0x3F: Read controller RAM byte N
    read_ram_base = 0x20,
    /// 0x60-0x7F: Write controller RAM byte N
    write_ram_base = 0x60,
    /// 0xA7: Disable mouse port
    disable_mouse = 0xA7,
    /// 0xA8: Enable mouse port
    enable_mouse = 0xA8,
    /// 0xA9: Test mouse port
    test_mouse = 0xA9,
    /// 0xAA: Self-test
    self_test = 0xAA,
    /// 0xAB: Test keyboard port
    test_keyboard = 0xAB,
    /// 0xAD: Disable keyboard
    disable_keyboard = 0xAD,
    /// 0xAE: Enable keyboard
    enable_keyboard = 0xAE,
    /// 0xC0: Read input port
    read_input_port = 0xC0,
    /// 0xD0: Read output port
    read_output_port = 0xD0,
    /// 0xD1: Write output port
    write_output_port = 0xD1,
    /// 0xFE: Pulse output line (CPU reset)
    pulse_output = 0xFE,
    _,
};

/// Output port bits (for 0xD0/0xD1 commands)
pub const OutputPort = struct {
    /// Bit 0: System reset (0 = reset)
    pub const SYSTEM_RESET: u8 = 0x01;
    /// Bit 1: A20 gate
    pub const A20_GATE: u8 = 0x02;
    /// Bit 4: Output buffer full (keyboard)
    pub const OUTPUT_FULL_KBD: u8 = 0x10;
    /// Bit 5: Output buffer full (mouse)
    pub const OUTPUT_FULL_MOUSE: u8 = 0x20;
    /// Bit 6: Keyboard clock
    pub const KEYBOARD_CLOCK: u8 = 0x40;
    /// Bit 7: Keyboard data
    pub const KEYBOARD_DATA: u8 = 0x80;
};

/// Self-test response codes
pub const SELF_TEST_PASSED: u8 = 0x55;
pub const SELF_TEST_FAILED: u8 = 0xFC;

/// Interface test response codes
pub const INTERFACE_TEST_PASSED: u8 = 0x00;
pub const INTERFACE_TEST_FAILED: u8 = 0x01;

/// 8042 Keyboard Controller
pub const KeyboardController = struct {
    /// Input buffer (keyboard scan codes to be read by CPU)
    input_buffer: std.ArrayList(u8),
    /// Output buffer (single byte for commands that return data)
    output_buffer: ?u8,
    /// Status register
    status: u8,
    /// Output port state
    output_port: u8,
    /// Current command being processed
    pending_command: ?u8,
    /// Keyboard enabled state
    keyboard_enabled: bool,
    /// Mouse enabled state
    mouse_enabled: bool,
    /// Controller configuration byte
    config_byte: u8,
    /// Allocator for buffers
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize keyboard controller
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .input_buffer = std.ArrayList(u8).init(allocator),
            .output_buffer = null,
            .status = Status.SYSTEM_FLAG, // System passed POST
            .output_port = OutputPort.SYSTEM_RESET | OutputPort.A20_GATE, // Normal state
            .pending_command = null,
            .keyboard_enabled = true,
            .mouse_enabled = false,
            .config_byte = 0x00,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.input_buffer.deinit();
    }

    /// Reset controller to initial state
    pub fn reset(self: *Self) void {
        self.input_buffer.clearRetainingCapacity();
        self.output_buffer = null;
        self.status = Status.SYSTEM_FLAG;
        self.output_port = OutputPort.SYSTEM_RESET | OutputPort.A20_GATE;
        self.pending_command = null;
        self.keyboard_enabled = true;
        self.mouse_enabled = false;
        self.config_byte = 0x00;
    }

    /// Read from data port (0x60)
    pub fn readData(self: *Self) u8 {
        // If there's output buffer data (from a command), return it
        if (self.output_buffer) |value| {
            self.output_buffer = null;
            self.status &= ~Status.OUTPUT_BUFFER_FULL;
            return value;
        }

        // Otherwise, read from keyboard input buffer
        if (self.input_buffer.items.len > 0) {
            const value = self.input_buffer.orderedRemove(0);
            if (self.input_buffer.items.len == 0) {
                self.status &= ~Status.OUTPUT_BUFFER_FULL;
            }
            return value;
        }

        // No data available
        return 0x00;
    }

    /// Write to data port (0x60)
    pub fn writeData(self: *Self, value: u8) void {
        // Handle pending commands that expect data
        if (self.pending_command) |cmd| {
            self.handleCommandData(cmd, value);
            self.pending_command = null;
            self.status &= ~Status.INPUT_BUFFER_FULL;
            return;
        }

        // Otherwise, data is sent to the keyboard device
        // For now, we just clear the input buffer flag
        self.status &= ~Status.INPUT_BUFFER_FULL;
    }

    /// Read from status port (0x64)
    pub fn readStatus(self: *const Self) u8 {
        var status = self.status;

        // Update keyboard enabled bit
        if (self.keyboard_enabled) {
            status |= Status.KEYBOARD_ENABLED;
        } else {
            status &= ~Status.KEYBOARD_ENABLED;
        }

        // Update output buffer full bit
        if (self.output_buffer != null or self.input_buffer.items.len > 0) {
            status |= Status.OUTPUT_BUFFER_FULL;
        }

        return status;
    }

    /// Write to command port (0x64)
    pub fn writeCommand(self: *Self, value: u8) void {
        const cmd = @as(Command, @enumFromInt(value));

        // Mark input buffer as full while processing
        self.status |= Status.INPUT_BUFFER_FULL | Status.COMMAND_DATA;

        switch (cmd) {
            .self_test => {
                // Controller self-test: return 0x55 for success
                self.output_buffer = SELF_TEST_PASSED;
                self.status |= Status.OUTPUT_BUFFER_FULL;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .test_keyboard => {
                // Keyboard interface test: return 0x00 for success
                self.output_buffer = INTERFACE_TEST_PASSED;
                self.status |= Status.OUTPUT_BUFFER_FULL;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .test_mouse => {
                // Mouse interface test: return 0x00 for success
                self.output_buffer = INTERFACE_TEST_PASSED;
                self.status |= Status.OUTPUT_BUFFER_FULL;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .disable_keyboard => {
                self.keyboard_enabled = false;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .enable_keyboard => {
                self.keyboard_enabled = true;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .disable_mouse => {
                self.mouse_enabled = false;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .enable_mouse => {
                self.mouse_enabled = true;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .read_output_port => {
                // Return current output port state
                self.output_buffer = self.output_port;
                self.status |= Status.OUTPUT_BUFFER_FULL;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .write_output_port => {
                // Next byte written to 0x60 will be the output port value
                self.pending_command = value;
                // Keep INPUT_BUFFER_FULL set, will be cleared when data is written
            },
            .pulse_output => {
                // Pulse output line - typically used for CPU reset
                // In a real system, this would trigger a CPU reset
                // For emulation, we just acknowledge the command
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .read_ram_base => {
                // Read controller RAM byte 0 (configuration byte)
                const offset = value & 0x1F;
                if (offset == 0) {
                    self.output_buffer = self.config_byte;
                    self.status |= Status.OUTPUT_BUFFER_FULL;
                } else {
                    self.output_buffer = 0x00;
                    self.status |= Status.OUTPUT_BUFFER_FULL;
                }
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            .write_ram_base => {
                // Write controller RAM byte - next byte to 0x60 is the value
                self.pending_command = value;
                // Keep INPUT_BUFFER_FULL set
            },
            .read_input_port => {
                // Read input port - return 0x00 for now
                self.output_buffer = 0x00;
                self.status |= Status.OUTPUT_BUFFER_FULL;
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
            _ => {
                // Unknown command - ignore
                self.status &= ~Status.INPUT_BUFFER_FULL;
            },
        }
    }

    /// Handle data written after a command that expects data
    fn handleCommandData(self: *Self, cmd: u8, value: u8) void {
        if (cmd == @intFromEnum(Command.write_output_port)) {
            // Update output port
            self.output_port = value;
        } else if (cmd >= @intFromEnum(Command.write_ram_base) and cmd < @intFromEnum(Command.write_ram_base) + 0x20) {
            // Write to controller RAM
            const offset = cmd & 0x1F;
            if (offset == 0) {
                self.config_byte = value;
            }
            // Other RAM bytes are ignored for now
        }
    }

    /// Queue a keyboard scan code to be read by the CPU
    pub fn queueScanCode(self: *Self, scancode: u8) !void {
        if (!self.keyboard_enabled) {
            return; // Keyboard is disabled
        }

        try self.input_buffer.append(scancode);
        self.status |= Status.OUTPUT_BUFFER_FULL;
    }

    /// Queue multiple scan codes
    pub fn queueScanCodes(self: *Self, scancodes: []const u8) !void {
        if (!self.keyboard_enabled) {
            return;
        }

        try self.input_buffer.appendSlice(scancodes);
        if (self.input_buffer.items.len > 0) {
            self.status |= Status.OUTPUT_BUFFER_FULL;
        }
    }

    /// Check if keyboard is enabled
    pub fn isKeyboardEnabled(self: *const Self) bool {
        return self.keyboard_enabled;
    }

    /// Check if output buffer has data available
    pub fn hasData(self: *const Self) bool {
        return self.output_buffer != null or self.input_buffer.items.len > 0;
    }

    /// Get current A20 gate state
    pub fn getA20State(self: *const Self) bool {
        return (self.output_port & OutputPort.A20_GATE) != 0;
    }

    /// Get output port value
    pub fn getOutputPort(self: *const Self) u8 {
        return self.output_port;
    }
};

// Tests
test "keyboard controller init and deinit" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    try std.testing.expect(kbd.keyboard_enabled);
    try std.testing.expect(!kbd.mouse_enabled);
}

test "keyboard controller self-test" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Send self-test command
    kbd.writeCommand(@intFromEnum(Command.self_test));

    // Check status shows output buffer full
    const status = kbd.readStatus();
    try std.testing.expect((status & Status.OUTPUT_BUFFER_FULL) != 0);

    // Read result (should be 0x55 for success)
    const result = kbd.readData();
    try std.testing.expectEqual(SELF_TEST_PASSED, result);

    // Output buffer should now be empty
    const status2 = kbd.readStatus();
    try std.testing.expect((status2 & Status.OUTPUT_BUFFER_FULL) == 0);
}

test "keyboard controller interface test" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Send keyboard interface test command
    kbd.writeCommand(@intFromEnum(Command.test_keyboard));

    // Read result (should be 0x00 for success)
    const result = kbd.readData();
    try std.testing.expectEqual(INTERFACE_TEST_PASSED, result);
}

test "keyboard controller enable/disable" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Initially enabled
    try std.testing.expect(kbd.isKeyboardEnabled());

    // Disable keyboard
    kbd.writeCommand(@intFromEnum(Command.disable_keyboard));
    try std.testing.expect(!kbd.isKeyboardEnabled());

    // Enable keyboard
    kbd.writeCommand(@intFromEnum(Command.enable_keyboard));
    try std.testing.expect(kbd.isKeyboardEnabled());
}

test "keyboard controller status register" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Initial status should have system flag set
    var status = kbd.readStatus();
    try std.testing.expect((status & Status.SYSTEM_FLAG) != 0);
    try std.testing.expect((status & Status.KEYBOARD_ENABLED) != 0);

    // No data initially
    try std.testing.expect((status & Status.OUTPUT_BUFFER_FULL) == 0);

    // Queue a scan code
    try kbd.queueScanCode(0x1E); // 'A' key make code

    // Status should now show output buffer full
    status = kbd.readStatus();
    try std.testing.expect((status & Status.OUTPUT_BUFFER_FULL) != 0);

    // Read the scan code
    const scancode = kbd.readData();
    try std.testing.expectEqual(@as(u8, 0x1E), scancode);

    // Output buffer should be empty again
    status = kbd.readStatus();
    try std.testing.expect((status & Status.OUTPUT_BUFFER_FULL) == 0);
}

test "keyboard controller scan code queuing" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Queue multiple scan codes
    try kbd.queueScanCode(0x1E); // 'A' make
    try kbd.queueScanCode(0x9E); // 'A' break
    try kbd.queueScanCode(0x30); // 'B' make
    try kbd.queueScanCode(0xB0); // 'B' break

    // Read them back in order
    try std.testing.expectEqual(@as(u8, 0x1E), kbd.readData());
    try std.testing.expectEqual(@as(u8, 0x9E), kbd.readData());
    try std.testing.expectEqual(@as(u8, 0x30), kbd.readData());
    try std.testing.expectEqual(@as(u8, 0xB0), kbd.readData());

    // No more data
    try std.testing.expect(!kbd.hasData());
}

test "keyboard controller disabled scan codes" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Disable keyboard
    kbd.writeCommand(@intFromEnum(Command.disable_keyboard));

    // Try to queue a scan code (should be ignored)
    try kbd.queueScanCode(0x1E);

    // Should have no data
    try std.testing.expect(!kbd.hasData());
}

test "keyboard controller output port" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Read output port
    kbd.writeCommand(@intFromEnum(Command.read_output_port));
    const port_value = kbd.readData();

    // Should have system reset and A20 enabled by default
    try std.testing.expect((port_value & OutputPort.SYSTEM_RESET) != 0);
    try std.testing.expect((port_value & OutputPort.A20_GATE) != 0);

    // Write new output port value
    kbd.writeCommand(@intFromEnum(Command.write_output_port));
    kbd.writeData(0xFF); // Set all bits

    // Read it back
    kbd.writeCommand(@intFromEnum(Command.read_output_port));
    const new_port_value = kbd.readData();
    try std.testing.expectEqual(@as(u8, 0xFF), new_port_value);
}

test "keyboard controller A20 gate" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // A20 should be enabled by default
    try std.testing.expect(kbd.getA20State());

    // Disable A20 by writing to output port
    kbd.writeCommand(@intFromEnum(Command.write_output_port));
    kbd.writeData(OutputPort.SYSTEM_RESET); // No A20 bit

    // A20 should now be disabled
    try std.testing.expect(!kbd.getA20State());

    // Enable A20 again
    kbd.writeCommand(@intFromEnum(Command.write_output_port));
    kbd.writeData(OutputPort.SYSTEM_RESET | OutputPort.A20_GATE);

    // A20 should be enabled
    try std.testing.expect(kbd.getA20State());
}

test "keyboard controller configuration byte" {
    const allocator = std.testing.allocator;
    var kbd = KeyboardController.init(allocator);
    defer kbd.deinit();

    // Write configuration byte (RAM byte 0)
    kbd.writeCommand(0x60); // Write RAM byte 0
    kbd.writeData(0x47);

    // Read it back
    kbd.writeCommand(0x20); // Read RAM byte 0
    const config = kbd.readData();
    try std.testing.expectEqual(@as(u8, 0x47), config);
}
