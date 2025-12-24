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

// Test: LGDT and protected mode switch
test "integration: protected mode" {
    const allocator = std.testing.allocator;

    // GDT structure at 0x1000:
    // Entry 0: Null descriptor (8 bytes of 0)
    // Entry 1: Code segment (0x08): base=0, limit=0xFFFFF, 32-bit, execute/read
    // Entry 2: Data segment (0x10): base=0, limit=0xFFFFF, 32-bit, read/write
    const gdt = [_]u8{
        // Entry 0: Null descriptor
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Entry 1: Code segment (0x08) - base=0, limit=0xFFFFF, 32-bit code, DPL=0
        0xFF, 0xFF, // limit low
        0x00, 0x00, // base low
        0x00, // base mid
        0x9A, // access: present, ring 0, code, execute/read
        0xCF, // flags: 4KB granularity, 32-bit, limit high = 0xF
        0x00, // base high
        // Entry 2: Data segment (0x10) - base=0, limit=0xFFFFF, 32-bit data, DPL=0
        0xFF, 0xFF, // limit low
        0x00, 0x00, // base low
        0x00, // base mid
        0x92, // access: present, ring 0, data, read/write
        0xCF, // flags: 4KB granularity, 32-bit, limit high = 0xF
        0x00, // base high
    };

    // GDTR structure at 0x0FF6: limit (2 bytes), base (4 bytes)
    const gdtr = [_]u8{
        0x17, 0x00, // limit = 23 (3 entries * 8 - 1)
        0x00, 0x10, 0x00, 0x00, // base = 0x1000
    };

    // Code at 0x0000:
    // lgdt [0x0FF6]      ; Load GDT
    // mov eax, cr0       ; Get CR0
    // or al, 1           ; Set PE bit
    // mov cr0, eax       ; Enable protected mode
    // mov edx, 0x3F8     ; UART port
    // mov al, 'P'        ; 'P' for protected mode
    // out dx, al
    // hlt
    const code = [_]u8{
        // lgdt [0x0FF6] - 0F 01 15 <addr32>
        0x0F, 0x01, 0x15, 0xF6, 0x0F, 0x00, 0x00,
        // mov eax, cr0 - 0F 20 C0
        0x0F, 0x20, 0xC0,
        // or al, 1 - 0C 01
        0x0C, 0x01,
        // mov cr0, eax - 0F 22 C0
        0x0F, 0x22, 0xC0,
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'P'
        0xB0, 'P',
        // out dx, al
        0xEE,
        // hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Load GDT at 0x1000
    try emu.loadBinary(&gdt, 0x1000);
    // Load GDTR structure at 0x0FF6
    try emu.loadBinary(&gdtr, 0x0FF6);
    // Load code at 0x0000
    try emu.loadBinary(&code, 0x0000);

    // Run
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 100) : (cycles += 1) {
        try emu.step();
    }

    // Verify protected mode was entered
    try std.testing.expect(emu.cpu_instance.mode == .protected);
    try std.testing.expect(emu.cpu_instance.system.cr0.pe);

    // Verify UART output
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("P", output.?);
}

// Test: LIDT instruction
test "integration: lidt" {
    const allocator = std.testing.allocator;

    // IDT pointer structure at 0x0100
    const idtr = [_]u8{
        0xFF, 0x07, // limit = 2047 (256 entries * 8 - 1)
        0x00, 0x20, 0x00, 0x00, // base = 0x2000
    };

    // Code to load IDT and verify
    const code = [_]u8{
        // lidt [0x0100] - 0F 01 1D <addr32>
        0x0F, 0x01, 0x1D, 0x00, 0x01, 0x00, 0x00,
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'I'
        0xB0, 'I',
        // out dx, al
        0xEE,
        // hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Load IDTR at 0x0100
    try emu.loadBinary(&idtr, 0x0100);
    // Load code at 0x0000
    try emu.loadBinary(&code, 0x0000);

    try emu.run();

    // Verify IDT was loaded
    try std.testing.expectEqual(@as(u16, 0x07FF), emu.cpu_instance.system.idtr.limit);
    try std.testing.expectEqual(@as(u32, 0x2000), emu.cpu_instance.system.idtr.base);

    // Verify UART output
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("I", output.?);
}

// Test: MOV CR0 read/write
test "integration: mov cr0" {
    const allocator = std.testing.allocator;

    const code = [_]u8{
        // mov eax, cr0 - read CR0 into EAX
        0x0F, 0x20, 0xC0,
        // mov ebx, eax - save original
        0x89, 0xC3,
        // or eax, 0x10 - set ET bit (bit 4, always 1 on i686)
        0x83, 0xC8, 0x10,
        // mov cr0, eax - write back
        0x0F, 0x22, 0xC0,
        // mov eax, cr0 - read again to verify
        0x0F, 0x20, 0xC0,
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'C'
        0xB0, 'C',
        // out dx, al
        0xEE,
        // hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    // Verify output
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("C", output.?);
}

// Test: Paging with identity mapping
test "integration: paging identity map" {
    const allocator = std.testing.allocator;

    // Memory layout:
    // 0x0000 - 0x0FFF: Code
    // 0x1000 - 0x1FFF: GDT
    // 0x2000 - 0x2FFF: Page Directory
    // 0x3000 - 0x3FFF: Page Table 0 (maps 0x00000000 - 0x003FFFFF)
    // 0x4000 - 0x4FFF: Page Table 1 (maps 0x00400000 - 0x007FFFFF) - not used
    // 0x5000: Test data location

    // GDT at 0x1000
    const gdt = [_]u8{
        // Entry 0: Null descriptor
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Entry 1: Code segment (0x08)
        0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xCF, 0x00,
        // Entry 2: Data segment (0x10)
        0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00,
    };

    // GDTR structure at 0x0FF6
    const gdtr = [_]u8{
        0x17, 0x00, // limit = 23 (3 entries * 8 - 1)
        0x00, 0x10, 0x00, 0x00, // base = 0x1000
    };

    // Page Directory at 0x2000 - first entry points to Page Table at 0x3000
    // PDE: present (1), r/w (1), user (1), page_table_base = 0x3000 >> 12 = 0x3
    // Value = 0x00003007 (little-endian: 07 30 00 00)
    var page_dir: [4096]u8 = undefined;
    @memset(&page_dir, 0);
    // PDE 0: page table at 0x3000, present, r/w, user
    page_dir[0] = 0x07;
    page_dir[1] = 0x30;
    page_dir[2] = 0x00;
    page_dir[3] = 0x00;

    // Page Table at 0x3000 - identity map first 1024 pages (4MB)
    var page_table: [4096]u8 = undefined;
    @memset(&page_table, 0);
    for (0..1024) |i| {
        // PTE: present (1), r/w (1), user (1), page_frame = i
        const pte: u32 = @as(u32, @intCast(i)) << 12 | 0x07;
        page_table[i * 4] = @truncate(pte);
        page_table[i * 4 + 1] = @truncate(pte >> 8);
        page_table[i * 4 + 2] = @truncate(pte >> 16);
        page_table[i * 4 + 3] = @truncate(pte >> 24);
    }

    // Code at 0x0000:
    // lgdt [0x0FF6]      ; Load GDT
    // mov eax, cr0
    // or eax, 1          ; Set PE bit
    // mov cr0, eax       ; Enable protected mode
    // mov eax, 0x2000
    // mov cr3, eax       ; Set page directory base
    // mov eax, cr0
    // or eax, 0x80000000 ; Set PG bit
    // mov cr0, eax       ; Enable paging
    // ; Now paging is active with identity mapping
    // mov dword [0x5000], 0x42424242  ; Write through paging
    // mov eax, [0x5000]  ; Read back through paging
    // mov edx, 0x3F8
    // cmp eax, 0x42424242
    // jne fail
    // mov al, 'G'        ; 'G' for good
    // out dx, al
    // hlt
    // fail:
    // mov al, 'F'        ; 'F' for fail
    // out dx, al
    // hlt
    const code = [_]u8{
        // lgdt [0x0FF6] - 0F 01 15 F6 0F 00 00
        0x0F, 0x01, 0x15, 0xF6, 0x0F, 0x00, 0x00,
        // mov eax, cr0 - 0F 20 C0
        0x0F, 0x20, 0xC0,
        // or eax, 1 - 83 C8 01
        0x83, 0xC8, 0x01,
        // mov cr0, eax - 0F 22 C0
        0x0F, 0x22, 0xC0,
        // mov eax, 0x2000 - B8 00 20 00 00
        0xB8, 0x00, 0x20, 0x00, 0x00,
        // mov cr3, eax - 0F 22 D8
        0x0F, 0x22, 0xD8,
        // mov eax, cr0 - 0F 20 C0
        0x0F, 0x20, 0xC0,
        // or eax, 0x80000000 - 0D 00 00 00 80
        0x0D, 0x00, 0x00, 0x00, 0x80,
        // mov cr0, eax - 0F 22 C0
        0x0F, 0x22, 0xC0,
        // Now paging is active!
        // mov dword [0x5000], 0x42424242 - C7 05 00 50 00 00 42 42 42 42
        0xC7, 0x05, 0x00, 0x50, 0x00, 0x00, 0x42, 0x42, 0x42, 0x42,
        // mov eax, [0x5000] - A1 00 50 00 00
        0xA1, 0x00, 0x50, 0x00, 0x00,
        // mov edx, 0x3F8 - BA F8 03 00 00
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // cmp eax, 0x42424242 - 3D 42 42 42 42
        0x3D, 0x42, 0x42, 0x42, 0x42,
        // jne fail (+5 bytes: mov al + out + hlt = 4) - 75 04
        0x75, 0x04,
        // mov al, 'G' - B0 47
        0xB0, 'G',
        // out dx, al - EE
        0xEE,
        // hlt - F4
        0xF4,
        // fail: mov al, 'F' - B0 46
        0xB0, 'F',
        // out dx, al - EE
        0xEE,
        // hlt - F4
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Load GDT at 0x1000
    try emu.loadBinary(&gdt, 0x1000);
    // Load GDTR at 0x0FF6
    try emu.loadBinary(&gdtr, 0x0FF6);
    // Load page directory at 0x2000
    try emu.loadBinary(&page_dir, 0x2000);
    // Load page table at 0x3000
    try emu.loadBinary(&page_table, 0x3000);
    // Load code at 0x0000
    try emu.loadBinary(&code, 0x0000);

    // Run with cycle limit
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 200) : (cycles += 1) {
        try emu.step();
    }

    // Verify paging was enabled
    try std.testing.expect(emu.cpu_instance.system.cr0.pg);
    try std.testing.expect(emu.cpu_instance.mode == .protected);

    // Verify UART output
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("G", output.?);
}
