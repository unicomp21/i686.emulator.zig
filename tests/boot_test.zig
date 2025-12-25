//! Kernel Boot Loader Integration Tests
//!
//! Tests for the Linux kernel boot protocol implementation.

const std = @import("std");
const Emulator = @import("../src/root.zig").Emulator;
const boot = @import("../src/root.zig").boot;

test "boot: parse minimal kernel header" {
    const allocator = std.testing.allocator;

    // Create minimal valid bzImage header
    var kernel_data = try allocator.alloc(u8, 0x1000);
    defer allocator.free(kernel_data);
    @memset(kernel_data, 0);

    // Boot sector magic at 0x1FE
    kernel_data[0x1FE] = 0x55;
    kernel_data[0x1FF] = 0xAA;

    // Header magic "HdrS" at 0x202
    kernel_data[0x202] = 0x48; // 'H'
    kernel_data[0x203] = 0x64; // 'd'
    kernel_data[0x204] = 0x72; // 'r'
    kernel_data[0x205] = 0x53; // 'S'

    // Protocol version 2.10 at 0x206
    kernel_data[0x206] = 0x0A;
    kernel_data[0x207] = 0x02;

    // Setup sectors = 4
    kernel_data[0x1F1] = 4;

    // Loadflags - LOADED_HIGH
    kernel_data[0x211] = 0x01;

    // Code32 start = 0x100000
    kernel_data[0x214] = 0x00;
    kernel_data[0x215] = 0x00;
    kernel_data[0x216] = 0x10;
    kernel_data[0x217] = 0x00;

    // Create DirectBoot instance
    var direct_boot = try boot.DirectBoot.initFromMemory(
        allocator,
        kernel_data,
        "console=ttyS0",
    );
    defer direct_boot.deinit();

    // Verify parsed values
    try std.testing.expectEqual(@as(u8, 4), direct_boot.setup_sects);
    try std.testing.expectEqual(@as(u16, 0x020A), direct_boot.protocol_version);
    try std.testing.expectEqual(@as(u32, 0x100000), direct_boot.code32_start);
}

test "boot: load kernel into emulator memory" {
    const allocator = std.testing.allocator;

    // Create minimal kernel image with setup + payload
    const setup_size = 5 * 512; // 1 boot sector + 4 setup sectors
    const payload_size = 1024;
    const total_size = setup_size + payload_size;

    var kernel_data = try allocator.alloc(u8, total_size);
    defer allocator.free(kernel_data);
    @memset(kernel_data, 0);

    // Setup header
    kernel_data[0x1FE] = 0x55;
    kernel_data[0x1FF] = 0xAA;
    kernel_data[0x202] = 0x48;
    kernel_data[0x203] = 0x64;
    kernel_data[0x204] = 0x72;
    kernel_data[0x205] = 0x53;
    kernel_data[0x206] = 0x00;
    kernel_data[0x207] = 0x02;
    kernel_data[0x1F1] = 4;
    kernel_data[0x211] = 0x01; // LOADED_HIGH
    kernel_data[0x214] = 0x00;
    kernel_data[0x215] = 0x00;
    kernel_data[0x216] = 0x10;
    kernel_data[0x217] = 0x00;

    // Payload with recognizable pattern
    for (0..payload_size) |i| {
        kernel_data[setup_size + i] = @truncate(i & 0xFF);
    }

    // Create emulator with enough memory
    var emu = try Emulator.init(allocator, .{
        .memory_size = 128 * 1024 * 1024, // 128 MB
        .enable_uart = false,
    });
    defer emu.deinit();

    // Load kernel using the high-level API
    try emu.loadKernel(kernel_data, "console=ttyS0 quiet");

    // Verify boot params were written
    const boot_flag = try emu.mem.readWord(boot.BOOT_PARAMS_ADDR + 0x1FE);
    try std.testing.expectEqual(@as(u16, 0xAA55), boot_flag);

    // Verify header magic
    const header = try emu.mem.readDword(boot.BOOT_PARAMS_ADDR + 0x202);
    try std.testing.expectEqual(@as(u32, 0x53726448), header); // "HdrS"

    // Verify payload was loaded at 1MB
    const first_byte = try emu.mem.readByte(boot.PROTECTED_MODE_KERNEL_ADDR);
    try std.testing.expectEqual(@as(u8, 0), first_byte);

    const second_byte = try emu.mem.readByte(boot.PROTECTED_MODE_KERNEL_ADDR + 1);
    try std.testing.expectEqual(@as(u8, 1), second_byte);
}

test "boot: CPU configured for protected mode entry" {
    const allocator = std.testing.allocator;

    // Minimal kernel
    var kernel_data = try allocator.alloc(u8, 0x1000);
    defer allocator.free(kernel_data);
    @memset(kernel_data, 0);

    kernel_data[0x1FE] = 0x55;
    kernel_data[0x1FF] = 0xAA;
    kernel_data[0x202] = 0x48;
    kernel_data[0x203] = 0x64;
    kernel_data[0x204] = 0x72;
    kernel_data[0x205] = 0x53;
    kernel_data[0x206] = 0x00;
    kernel_data[0x207] = 0x02;
    kernel_data[0x1F1] = 4;
    kernel_data[0x211] = 0x01; // LOADED_HIGH
    kernel_data[0x214] = 0x00;
    kernel_data[0x215] = 0x00;
    kernel_data[0x216] = 0x10;
    kernel_data[0x217] = 0x00;

    var emu = try Emulator.init(allocator, .{
        .memory_size = 128 * 1024 * 1024,
    });
    defer emu.deinit();

    try emu.loadKernel(kernel_data, "");

    // Check CPU state
    const state = emu.getCpuState();

    // Should be in protected mode
    try std.testing.expectEqual(@import("../src/cpu/cpu.zig").CpuMode.protected, state.mode);

    // EIP should point to kernel entry (0x100000)
    try std.testing.expectEqual(@as(u32, 0x100000), state.eip);

    // ESI should point to boot params
    try std.testing.expectEqual(@as(u32, boot.BOOT_PARAMS_ADDR), state.esi);

    // CS should be kernel code segment (0x08)
    try std.testing.expectEqual(@as(u16, 0x08), state.cs);

    // DS should be kernel data segment (0x10)
    try std.testing.expectEqual(@as(u16, 0x10), state.ds);

    // ESP should be set up
    try std.testing.expect(state.esp > 0);
    try std.testing.expect(state.esp < boot.BOOT_PARAMS_ADDR);
}

test "boot: command line setup" {
    const allocator = std.testing.allocator;

    var kernel_data = try allocator.alloc(u8, 0x1000);
    defer allocator.free(kernel_data);
    @memset(kernel_data, 0);

    kernel_data[0x1FE] = 0x55;
    kernel_data[0x1FF] = 0xAA;
    kernel_data[0x202] = 0x48;
    kernel_data[0x203] = 0x64;
    kernel_data[0x204] = 0x72;
    kernel_data[0x205] = 0x53;
    kernel_data[0x206] = 0x00;
    kernel_data[0x207] = 0x02;
    kernel_data[0x1F1] = 4;
    kernel_data[0x211] = 0x01;
    kernel_data[0x214] = 0x00;
    kernel_data[0x215] = 0x00;
    kernel_data[0x216] = 0x10;
    kernel_data[0x217] = 0x00;

    var emu = try Emulator.init(allocator, .{
        .memory_size = 128 * 1024 * 1024,
    });
    defer emu.deinit();

    const cmdline = "console=ttyS0 root=/dev/sda1";
    try emu.loadKernel(kernel_data, cmdline);

    // Verify command line was written
    const cmdline_ptr = try emu.mem.readDword(boot.BOOT_PARAMS_ADDR + 0x228);
    try std.testing.expectEqual(boot.CMDLINE_ADDR, cmdline_ptr);

    // Verify command line content
    for (cmdline, 0..) |char, i| {
        const byte = try emu.mem.readByte(boot.CMDLINE_ADDR + @as(u32, @intCast(i)));
        try std.testing.expectEqual(char, byte);
    }

    // Verify null terminator
    const null_byte = try emu.mem.readByte(boot.CMDLINE_ADDR + @as(u32, @intCast(cmdline.len)));
    try std.testing.expectEqual(@as(u8, 0), null_byte);
}

test "boot: GDT setup for flat memory model" {
    const allocator = std.testing.allocator;

    var kernel_data = try allocator.alloc(u8, 0x1000);
    defer allocator.free(kernel_data);
    @memset(kernel_data, 0);

    kernel_data[0x1FE] = 0x55;
    kernel_data[0x1FF] = 0xAA;
    kernel_data[0x202] = 0x48;
    kernel_data[0x203] = 0x64;
    kernel_data[0x204] = 0x72;
    kernel_data[0x205] = 0x53;
    kernel_data[0x206] = 0x00;
    kernel_data[0x207] = 0x02;
    kernel_data[0x1F1] = 4;
    kernel_data[0x211] = 0x01;
    kernel_data[0x214] = 0x00;
    kernel_data[0x215] = 0x00;
    kernel_data[0x216] = 0x10;
    kernel_data[0x217] = 0x00;

    var emu = try Emulator.init(allocator, .{
        .memory_size = 128 * 1024 * 1024,
    });
    defer emu.deinit();

    try emu.loadKernel(kernel_data, "");

    // Verify GDTR is set up
    try std.testing.expectEqual(@as(u32, 0x1F000), emu.cpu_instance.system.gdtr.base);
    try std.testing.expect(emu.cpu_instance.system.gdtr.limit > 0);

    // Verify null descriptor (entry 0)
    const null_desc = try emu.mem.readDword(0x1F000);
    try std.testing.expectEqual(@as(u32, 0), null_desc);

    // Verify code segment descriptor (entry 1) has correct access byte
    const code_access = try emu.mem.readByte(0x1F000 + 8 + 5);
    try std.testing.expectEqual(@as(u8, 0x9A), code_access); // Present, DPL=0, executable, readable

    // Verify data segment descriptor (entry 2) has correct access byte
    const data_access = try emu.mem.readByte(0x1F000 + 16 + 5);
    try std.testing.expectEqual(@as(u8, 0x92), data_access); // Present, DPL=0, writable
}
