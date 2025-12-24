//! Integration Test Suite
//!
//! Tests the emulator with actual binary programs.
//! Uses UART output to verify correct execution.

const std = @import("std");
const emulator = @import("emulator");

const Emulator = emulator.Emulator;

// Test: Simple UART output
// Program writes "OK" to UART and halts
test "integration: uart hello" {
    const allocator = std.testing.allocator;

    // Machine code (32-bit default operand size):
    // mov edx, 0x3F8   ; UART COM1
    // mov al, 'O'      ; character
    // out dx, al       ; write to UART
    // mov al, 'K'
    // out dx, al
    // hlt              ; halt
    const program = [_]u8{
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        0xB0, 'O', // mov al, 'O'
        0xEE, // out dx, al
        0xB0, 'K', // mov al, 'K'
        0xEE, // out dx, al
        0xF4, // hlt
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&program, 0);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("OK", output.?);
}

// Test: Arithmetic operations
// Tests ADD, SUB and verifies via UART output
test "integration: arithmetic" {
    const allocator = std.testing.allocator;

    // mov al, 5; add al, 3; add al, '0' -> '8'
    const program = [_]u8{
        0xB0, 5, // mov al, 5
        0x04, 3, // add al, 3 -> al = 8
        0x04, '0', // add al, '0' -> al = '8'
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        0xEE, // out dx, al
        0xF4, // hlt
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&program, 0);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("8", output.?);
}

// Test: Loop with counter
// Outputs "AAA" using a loop
test "integration: loop" {
    const allocator = std.testing.allocator;

    // Using manual dec + jnz
    const program = [_]u8{
        0xB9, 0x03, 0x00, 0x00, 0x00, // mov ecx, 3
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        // loop_start (offset 10):
        0xB0, 'A', // mov al, 'A'
        0xEE, // out dx, al
        0x49, // dec ecx
        0x75, 0xFA, // jnz -6 (back to mov al, 'A')
        0xF4, // hlt
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&program, 0);

    // Run with cycle limit to prevent infinite loops
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 1000) : (cycles += 1) {
        try emu.step();
    }

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("AAA", output.?);
}

// Test: Function call and return
test "integration: call and return" {
    const allocator = std.testing.allocator;

    // Setup stack and call a function that outputs 'X'
    const program = [_]u8{
        // mov esp, 0x1000
        0xBC, 0x00, 0x10, 0x00, 0x00,
        // call rel32 (offset to print_x: +1 byte after hlt)
        0xE8, 0x01, 0x00, 0x00, 0x00,
        // hlt
        0xF4,
        // print_x: (offset 11)
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        0xB0, 'X', // mov al, 'X'
        0xEE, // out dx, al
        0xC3, // ret
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&program, 0);

    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 100) : (cycles += 1) {
        try emu.step();
    }

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("X", output.?);
}

// Test: Register preservation across push/pop
test "integration: register preservation" {
    const allocator = std.testing.allocator;

    const program = [_]u8{
        0xB8, 'B', 0x00, 0x00, 0x00, // mov eax, 'B'
        0xBC, 0x00, 0x10, 0x00, 0x00, // mov esp, 0x1000
        0x50, // push eax
        0xB8, 0x00, 0x00, 0x00, 0x00, // mov eax, 0
        0x58, // pop eax
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        0xEE, // out dx, al
        0xF4, // hlt
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&program, 0);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("B", output.?);
}

// Test: XOR to zero register
test "integration: xor zero" {
    const allocator = std.testing.allocator;

    const program = [_]u8{
        0xB8, 0x78, 0x56, 0x34, 0x12, // mov eax, 0x12345678
        0x31, 0xC0, // xor eax, eax
        0x04, 'Z', // add al, 'Z'
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        0xEE, // out dx, al
        0xF4, // hlt
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&program, 0);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("Z", output.?);
}
