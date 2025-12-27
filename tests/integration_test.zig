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

// Test: LEA instruction
test "integration: lea" {
    const allocator = std.testing.allocator;

    // Test LEA with [base + index*scale + disp]
    // lea eax, [ebx + ecx*4 + 0x100]
    // if eax == ebx + ecx*4 + 0x100, output 'L'
    const code = [_]u8{
        // mov ebx, 0x1000 - B8+3 = BB
        0xBB, 0x00, 0x10, 0x00, 0x00,
        // mov ecx, 0x10 - B8+1 = B9
        0xB9, 0x10, 0x00, 0x00, 0x00,
        // lea eax, [ebx + ecx*4 + 0x100] - 8D 84 8B 00 01 00 00
        // ModRM: mod=10 (disp32), reg=000 (eax), rm=100 (SIB)
        // SIB: scale=10 (4), index=001 (ecx), base=011 (ebx)
        0x8D, 0x84, 0x8B, 0x00, 0x01, 0x00, 0x00,
        // Expected: 0x1000 + 0x10*4 + 0x100 = 0x1000 + 0x40 + 0x100 = 0x1140
        // cmp eax, 0x1140 - 3D 40 11 00 00
        0x3D, 0x40, 0x11, 0x00, 0x00,
        // jne fail
        0x75, 0x09,
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'L'
        0xB0, 'L',
        // out dx, al
        0xEE,
        // hlt
        0xF4,
        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("L", output.?);
}

// Test: MOVZX and MOVSX instructions
test "integration: movzx movsx" {
    const allocator = std.testing.allocator;

    // Test MOVZX (zero extend) and MOVSX (sign extend)
    const code = [_]u8{
        // mov byte [0x100], 0x80 - C6 05 00 01 00 00 80
        0xC6, 0x05, 0x00, 0x01, 0x00, 0x00, 0x80,
        // movzx eax, byte [0x100] - 0F B6 05 00 01 00 00
        0x0F, 0xB6, 0x05, 0x00, 0x01, 0x00, 0x00,
        // cmp eax, 0x80 (should be 0x00000080)
        0x3D, 0x80, 0x00, 0x00, 0x00,
        // jne fail
        0x75, 0x1C,
        // movsx ebx, byte [0x100] - 0F BE 1D 00 01 00 00
        0x0F, 0xBE, 0x1D, 0x00, 0x01, 0x00, 0x00,
        // cmp ebx, 0xFFFFFF80 (sign extended -128)
        0x81, 0xFB, 0x80, 0xFF, 0xFF, 0xFF,
        // jne fail
        0x75, 0x0E,
        // success: output 'Z'
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'Z'
        0xB0, 'Z',
        // out dx, al
        0xEE,
        // hlt
        0xF4,
        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("Z", output.?);
}

// Test: Shift instructions (SHL, SHR, SAR)
test "integration: shifts" {
    const allocator = std.testing.allocator;

    // Test SHL, SHR, SAR
    const code = [_]u8{
        // mov eax, 1 - B8 01 00 00 00
        0xB8, 0x01, 0x00, 0x00, 0x00,
        // shl eax, 4 - C1 E0 04 (shift left by 4, result = 0x10)
        0xC1, 0xE0, 0x04,
        // cmp eax, 0x10
        0x3D, 0x10, 0x00, 0x00, 0x00,
        // jne fail
        0x75, 0x24,
        // mov ebx, 0x80 - BB 80 00 00 00
        0xBB, 0x80, 0x00, 0x00, 0x00,
        // shr ebx, 3 - C1 EB 03 (shift right by 3, result = 0x10)
        0xC1, 0xEB, 0x03,
        // cmp ebx, 0x10
        0x81, 0xFB, 0x10, 0x00, 0x00, 0x00,
        // jne fail
        0x75, 0x13,
        // mov ecx, 0xFFFFFF80 (-128) - B9 80 FF FF FF
        0xB9, 0x80, 0xFF, 0xFF, 0xFF,
        // sar ecx, 2 - C1 F9 02 (arithmetic shift right by 2)
        0xC1, 0xF9, 0x02,
        // cmp ecx, 0xFFFFFFE0 (-32) - 81 F9 E0 FF FF FF
        0x81, 0xF9, 0xE0, 0xFF, 0xFF, 0xFF,
        // jne fail
        0x75, 0x09,
        // success: output 'S'
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'S',
        0xEE,
        0xF4,
        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("S", output.?);
}

// Test: TEST instruction
test "integration: test instruction" {
    const allocator = std.testing.allocator;

    // Test the TEST instruction (AND that only affects flags)
    const code = [_]u8{
        // mov eax, 0x0F - B8 0F 00 00 00
        0xB8, 0x0F, 0x00, 0x00, 0x00,
        // test eax, 0x10 - A9 10 00 00 00 (should set ZF=1)
        0xA9, 0x10, 0x00, 0x00, 0x00,
        // jnz fail (if not zero, fail)
        0x75, 0x11,
        // test eax, 0x08 - A9 08 00 00 00 (should set ZF=0)
        0xA9, 0x08, 0x00, 0x00, 0x00,
        // jz fail (if zero, fail)
        0x74, 0x09,
        // success: output 'T'
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'T',
        0xEE,
        0xF4,
        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("T", output.?);
}

// Test: MUL and DIV instructions
test "integration: mul div" {
    const allocator = std.testing.allocator;

    // Test MUL and DIV
    const code = [_]u8{
        // mov eax, 100 - B8 64 00 00 00
        0xB8, 0x64, 0x00, 0x00, 0x00,
        // mov ecx, 5 - B9 05 00 00 00
        0xB9, 0x05, 0x00, 0x00, 0x00,
        // mul ecx - F7 E1 (edx:eax = eax * ecx = 500)
        0xF7, 0xE1,
        // cmp eax, 500 - 3D F4 01 00 00
        0x3D, 0xF4, 0x01, 0x00, 0x00,
        // jne fail
        0x75, 0x16,
        // Now divide 500 by 10
        // mov ecx, 10 - B9 0A 00 00 00
        0xB9, 0x0A, 0x00, 0x00, 0x00,
        // xor edx, edx - 31 D2
        0x31, 0xD2,
        // div ecx - F7 F1 (eax = 50, edx = 0)
        0xF7, 0xF1,
        // cmp eax, 50 - 3D 32 00 00 00
        0x3D, 0x32, 0x00, 0x00, 0x00,
        // jne fail
        0x75, 0x09,
        // success: output 'M'
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'M',
        0xEE,
        0xF4,
        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("M", output.?);
}

// Test: PUSHF/POPF flag preservation
test "integration: pushf popf" {
    const allocator = std.testing.allocator;

    // Test that PUSHF/POPF preserves flags correctly
    const code = [_]u8{
        // Setup stack
        // mov esp, 0x1000 - BC 00 10 00 00
        0xBC, 0x00, 0x10, 0x00, 0x00,
        // Set specific flags using arithmetic
        // mov al, 0xFF - B0 FF
        0xB0, 0xFF,
        // add al, 1 - 04 01 (this sets CF=1, ZF=1, AF=1, PF=1)
        0x04, 0x01,
        // pushfd - save flags to stack - 9C
        0x9C,
        // Modify flags
        // xor eax, eax - 31 C0 (this sets ZF=1, clears CF, SF, OF)
        0x31, 0xC0,
        // Now flags should be different
        // popfd - restore flags from stack - 9D
        0x9D,
        // If carry flag was restored, jump to success
        // jc success - 72 04
        0x72, 0x04,
        // fail: output 'F'
        // mov al, 'F' - B0 46
        0xB0, 'F',
        // jmp end - EB 02
        0xEB, 0x02,
        // success: output 'P' (for PUSHF/POPF)
        // mov al, 'P' - B0 50
        0xB0, 'P',
        // end: output character
        // mov edx, 0x3F8 - BA F8 03 00 00
        0xBA, 0xF8, 0x03, 0x00, 0x00,
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

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("P", output.?);
}

// Test: REP MOVSB - String copy with REP prefix
test "integration: rep movsb" {
    const allocator = std.testing.allocator;

    // Test REP MOVSB to copy a string from one location to another
    // Source string "HELLO" at 0x1000, copy to 0x2000
    const source_string = "HELLO";

    // Code to copy string using REP MOVSB
    const code = [_]u8{
        // Set up source and destination pointers
        // mov esi, 0x1000 - BE 00 10 00 00
        0xBE, 0x00, 0x10, 0x00, 0x00,
        // mov edi, 0x2000 - BF 00 20 00 00
        0xBF, 0x00, 0x20, 0x00, 0x00,
        // mov ecx, 5 (length of "HELLO") - B9 05 00 00 00
        0xB9, 0x05, 0x00, 0x00, 0x00,
        // cld (clear direction flag - forward copy) - FC
        0xFC,
        // rep movsb - F3 A4
        0xF3, 0xA4,

        // Now output the copied string via UART
        // mov esi, 0x2000 - BE 00 20 00 00
        0xBE, 0x00, 0x20, 0x00, 0x00,
        // mov ecx, 5 - B9 05 00 00 00
        0xB9, 0x05, 0x00, 0x00, 0x00,
        // mov edx, 0x3F8 - BA F8 03 00 00
        0xBA, 0xF8, 0x03, 0x00, 0x00,

        // loop_output: (offset 30)
        // lodsb - AC (load byte from [ESI] into AL, increment ESI)
        0xAC,
        // out dx, al - EE
        0xEE,
        // dec ecx - 49
        0x49,
        // jnz loop_output (-5 bytes) - 75 FB
        0x75, 0xFB,

        // hlt - F4
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Load source string at 0x1000
    try emu.loadBinary(source_string, 0x1000);
    // Load code at 0x0000
    try emu.loadBinary(&code, 0x0000);

    // Run with cycle limit to prevent infinite loops
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 1000) : (cycles += 1) {
        try emu.step();
    }

    // Verify the string was copied and output correctly
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("HELLO", output.?);
}

// Test: BSF and BSR instructions
test "integration: bsf bsr" {
    const allocator = std.testing.allocator;

    // Test BSF (bit scan forward) and BSR (bit scan reverse)
    const code = [_]u8{
        // Test BSF with value 0x00000120 (bits 5 and 8 set)
        // Expected: BSF finds bit 5 (lowest set bit)
        // mov eax, 0x120 - B8 20 01 00 00
        0xB8, 0x20, 0x01, 0x00, 0x00,
        // bsf ebx, eax - 0F BC D8
        0x0F, 0xBC, 0xD8,
        // cmp ebx, 5 - 83 FB 05
        0x83, 0xFB, 0x05,
        // jne fail
        0x75, 0x23,

        // Test BSR with same value 0x00000120
        // Expected: BSR finds bit 8 (highest set bit)
        // bsr ecx, eax - 0F BD C8
        0x0F, 0xBD, 0xC8,
        // cmp ecx, 8 - 83 F9 08
        0x83, 0xF9, 0x08,
        // jne fail
        0x75, 0x19,

        // Test BSF with 0 (should set ZF)
        // xor eax, eax - 31 C0
        0x31, 0xC0,
        // bsf edx, eax - 0F BC D0
        0x0F, 0xBC, 0xD0,
        // jnz fail (if ZF is not set, fail)
        0x75, 0x0F,

        // Test BSR with 1 (bit 0 only)
        // mov eax, 1 - B8 01 00 00 00
        0xB8, 0x01, 0x00, 0x00, 0x00,
        // bsr esi, eax - 0F BD F0
        0x0F, 0xBD, 0xF0,
        // cmp esi, 0 - 83 FE 00
        0x83, 0xFE, 0x00,
        // jne fail
        0x75, 0x09,

        // success: output 'B'
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'B',
        0xEE,
        0xF4,

        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("B", output.?);
}

// Test: INT 0x80 with IRET in protected mode
test "integration: int 0x80 with iret" {
    const allocator = std.testing.allocator;

    // Memory layout:
    // 0x0000 - 0x0FFF: Main code
    // 0x1000 - 0x1FFF: GDT
    // 0x2000 - 0x2FFF: IDT
    // 0x3000 - 0x3FFF: Interrupt handler code

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

    // IDT at 0x2000 - set up entry for interrupt 0x80
    // IDT entry format: offset_low (2), selector (2), reserved (1), type_attr (1), offset_high (2)
    // Handler at 0x3000, selector 0x08 (code segment), 32-bit interrupt gate
    // type_attr: present=1, DPL=0, gate_type=0xE (interrupt gate)
    // type_attr byte: 10001110 = 0x8E
    var idt: [2048]u8 = undefined;
    @memset(&idt, 0);

    // Entry for vector 0x80 at offset 0x80 * 8 = 0x400
    const handler_offset: u32 = 0x3000;
    const selector: u16 = 0x08;
    const type_attr: u8 = 0x8E; // Present, DPL=0, 32-bit interrupt gate

    idt[0x400 + 0] = @truncate(handler_offset); // offset_low low byte
    idt[0x400 + 1] = @truncate(handler_offset >> 8); // offset_low high byte
    idt[0x400 + 2] = @truncate(selector); // selector low byte
    idt[0x400 + 3] = @truncate(selector >> 8); // selector high byte
    idt[0x400 + 4] = 0; // reserved
    idt[0x400 + 5] = type_attr; // type_attr
    idt[0x400 + 6] = @truncate(handler_offset >> 16); // offset_high low byte
    idt[0x400 + 7] = @truncate(handler_offset >> 24); // offset_high high byte

    // IDTR structure at 0x0FE6
    const idtr = [_]u8{
        0xFF, 0x07, // limit = 2047 (256 entries * 8 - 1)
        0x00, 0x20, 0x00, 0x00, // base = 0x2000
    };

    // Interrupt handler at 0x3000
    // Outputs 'I' to UART and executes IRET
    const handler = [_]u8{
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'I'
        0xB0, 'I',
        // out dx, al
        0xEE,
        // iret
        0xCF,
    };

    // Main code at 0x0000
    const code = [_]u8{
        // Setup stack
        // mov esp, 0x8000
        0xBC, 0x00, 0x80, 0x00, 0x00,

        // Load GDT
        // lgdt [0x0FF6]
        0x0F, 0x01, 0x15, 0xF6, 0x0F, 0x00, 0x00,

        // Load IDT
        // lidt [0x0FE6]
        0x0F, 0x01, 0x1D, 0xE6, 0x0F, 0x00, 0x00,

        // Enable protected mode
        // mov eax, cr0
        0x0F, 0x20, 0xC0,
        // or al, 1
        0x0C, 0x01,
        // mov cr0, eax
        0x0F, 0x22, 0xC0,

        // Now in protected mode, execute INT 0x80
        // int 0x80
        0xCD, 0x80,

        // After returning from interrupt, output 'R'
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'R'
        0xB0, 'R',
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
    // Load GDTR at 0x0FF6
    try emu.loadBinary(&gdtr, 0x0FF6);
    // Load IDT at 0x2000
    try emu.loadBinary(&idt, 0x2000);
    // Load IDTR at 0x0FE6
    try emu.loadBinary(&idtr, 0x0FE6);
    // Load interrupt handler at 0x3000
    try emu.loadBinary(&handler, 0x3000);
    // Load main code at 0x0000
    try emu.loadBinary(&code, 0x0000);

    // Run with cycle limit
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 200) : (cycles += 1) {
        try emu.step();
    }

    // Verify protected mode was entered
    try std.testing.expect(emu.cpu_instance.mode == .protected);

    // Verify UART output is "IR" - 'I' from interrupt handler, 'R' from main code after return
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("IR", output.?);
}

test "integration: rdmsr and wrmsr" {
    const allocator = std.testing.allocator;

    // Program to write and read MSRs
    const program = [_]u8{
        // Write to IA32_SYSENTER_CS (0x174)
        // mov ecx, 0x174
        0xB9, 0x74, 0x01, 0x00, 0x00,
        // mov eax, 0x00000008 (CS selector value)
        0xB8, 0x08, 0x00, 0x00, 0x00,
        // mov edx, 0
        0xBA, 0x00, 0x00, 0x00, 0x00,
        // wrmsr
        0x0F, 0x30,

        // Write to IA32_SYSENTER_ESP (0x175)
        // mov ecx, 0x175
        0xB9, 0x75, 0x01, 0x00, 0x00,
        // mov eax, 0xC0000000 (kernel stack)
        0xB8, 0x00, 0x00, 0x00, 0xC0,
        // wrmsr
        0x0F, 0x30,

        // Write to IA32_SYSENTER_EIP (0x176)
        // mov ecx, 0x176
        0xB9, 0x76, 0x01, 0x00, 0x00,
        // mov eax, 0x80000000 (kernel entry)
        0xB8, 0x00, 0x00, 0x00, 0x80,
        // wrmsr
        0x0F, 0x30,

        // Read back IA32_SYSENTER_CS and verify
        // mov ecx, 0x174
        0xB9, 0x74, 0x01, 0x00, 0x00,
        // rdmsr
        0x0F, 0x32,
        // eax should now be 0x00000008
        // Compare with expected value
        // cmp eax, 0x00000008
        0x3D, 0x08, 0x00, 0x00, 0x00,
        // jne skip (skip UART output if not equal)
        0x75, 0x0D,

        // Output 'M' for MSR success
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'M'
        0xB0, 'M',
        // out dx, al
        0xEE,

        // hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{ .enable_uart = true });
    defer emu.deinit();

    try emu.loadBinary(&program, 0);
    try emu.run();

    // Verify MSR values were written
    try std.testing.expectEqual(@as(u32, 0x00000008), emu.cpu_instance.system.msr_sysenter_cs);
    try std.testing.expectEqual(@as(u32, 0xC0000000), emu.cpu_instance.system.msr_sysenter_esp);
    try std.testing.expectEqual(@as(u32, 0x80000000), emu.cpu_instance.system.msr_sysenter_eip);

    // Verify UART output 'M'
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("M", output.?);
}

test "integration: sysenter and sysexit" {
    const allocator = std.testing.allocator;

    // User code that calls into kernel
    const user_code = [_]u8{
        // Output 'U' from user mode
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'U'
        0xB0, 'U',
        // out dx, al
        0xEE,

        // Execute SYSENTER
        0x0F, 0x34,

        // This code executes after SYSEXIT returns
        // Output 'R' for return
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'R'
        0xB0, 'R',
        // out dx, al
        0xEE,

        // hlt
        0xF4,
    };

    // Kernel entry point code
    const kernel_code = [_]u8{
        // Output 'K' from kernel mode
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'K'
        0xB0, 'K',
        // out dx, al
        0xEE,

        // Set up return to user mode
        // mov ecx, user_stack (0x00001000)
        0xB9, 0x00, 0x10, 0x00, 0x00,
        // mov edx, user_eip (0x000A = after SYSENTER)
        0xBA, 0x0A, 0x00, 0x00, 0x00,

        // Execute SYSEXIT
        0x0F, 0x35,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Switch to protected mode for SYSENTER/SYSEXIT
    emu.cpu_instance.mode = .protected;

    // Configure SYSENTER MSRs
    emu.cpu_instance.system.msr_sysenter_cs = 0x0008; // Kernel CS
    emu.cpu_instance.system.msr_sysenter_esp = 0x00010000; // Kernel stack
    emu.cpu_instance.system.msr_sysenter_eip = 0x00020000; // Kernel entry

    // Set up user mode segments
    emu.cpu_instance.segments.cs = 0x001B; // User CS (RPL=3)
    emu.cpu_instance.segments.ss = 0x0023; // User SS (RPL=3)
    emu.cpu_instance.regs.esp = 0x00001000; // User stack

    // Load user code at 0x0000
    try emu.loadBinary(&user_code, 0x0000);

    // Load kernel code at 0x00020000
    try emu.loadBinary(&kernel_code, 0x00020000);

    // Run with cycle limit
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 100) : (cycles += 1) {
        try emu.step();
    }

    // Verify we're back in user mode
    try std.testing.expectEqual(@as(u16, 0x001B), emu.cpu_instance.segments.cs);

    // Verify UART output is "UKR" - U from user, K from kernel, R from user after return
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("UKR", output.?);
}

// Test: DAA - Decimal Adjust After Addition (BCD arithmetic)
test "integration: bcd arithmetic daa" {
    const allocator = std.testing.allocator;

    // Test DAA with packed BCD addition
    // Example: 0x19 + 0x28 = 0x41 (binary), should become 0x47 (BCD) after DAA
    const code = [_]u8{
        // mov al, 0x19 (BCD 19)
        0xB0, 0x19,
        // add al, 0x28 (BCD 28) - binary result is 0x41
        0x04, 0x28,
        // daa - adjust to BCD: 0x47 (BCD 47)
        0x27,

        // Verify result is 0x47
        // cmp al, 0x47
        0x3C, 0x47,
        // jne fail
        0x75, 0x1A,

        // Test another case: 0x09 + 0x08 = 0x11 (binary), should become 0x17 (BCD) after DAA
        // mov al, 0x09
        0xB0, 0x09,
        // add al, 0x08 - binary result is 0x11
        0x04, 0x08,
        // daa - adjust to BCD: 0x17
        0x27,

        // Verify result is 0x17
        // cmp al, 0x17
        0x3C, 0x17,
        // jne fail
        0x75, 0x09,

        // success: output 'D' for DAA
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'D',
        0xEE,
        0xF4,

        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("D", output.?);
}

// Test: CMPXCHG and XADD - Atomic operations
test "integration: atomic operations" {
    const allocator = std.testing.allocator;

    // Test CMPXCHG and XADD instructions
    const code = [_]u8{
        // Test CMPXCHG with matching value (exchange should happen)
        // mov eax, 100 - set accumulator
        0xB8, 0x64, 0x00, 0x00, 0x00,
        // mov ebx, 100 - set destination (same value)
        0xBB, 0x64, 0x00, 0x00, 0x00,
        // mov ecx, 200 - set source (new value to exchange)
        0xB9, 0xC8, 0x00, 0x00, 0x00,

        // cmpxchg ebx, ecx - if EAX == EBX, then EBX = ECX
        // 0F B1 CB (ModRM: mod=11, reg=001 (ecx), rm=011 (ebx))
        0x0F, 0xB1, 0xCB,

        // After CMPXCHG: EBX should be 200, ZF should be set
        // cmp ebx, 200
        0x81, 0xFB, 0xC8, 0x00, 0x00, 0x00,
        // jne fail
        0x75, 0x23,
        // jnz fail (check ZF was set)
        0x75, 0x21,

        // Test XADD - exchange and add
        // mov edx, 50
        0xBA, 0x32, 0x00, 0x00, 0x00,
        // mov esi, 30
        0xBE, 0x1E, 0x00, 0x00, 0x00,

        // xadd edx, esi - temp=EDX, EDX=EDX+ESI, ESI=temp
        // 0F C1 F2 (ModRM: mod=11, reg=110 (esi), rm=010 (edx))
        0x0F, 0xC1, 0xF2,

        // After XADD: EDX should be 80 (50+30), ESI should be 50
        // cmp edx, 80
        0x81, 0xFA, 0x50, 0x00, 0x00, 0x00,
        // jne fail
        0x75, 0x0E,
        // cmp esi, 50
        0x81, 0xFE, 0x32, 0x00, 0x00, 0x00,
        // jne fail
        0x75, 0x06,

        // success: output 'A' for Atomic
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'A',
        0xEE,
        0xF4,

        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("A", output.?);
}

// Test: FAR CALL and RETF - Far control flow
test "integration: far call and retf" {
    const allocator = std.testing.allocator;

    // Subroutine at 0x1000:0x0000 (linear address 0x10000)
    const subroutine = [_]u8{
        // Output 'F' to UART
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'F',
        0xEE,
        // Output 'C' to UART
        0xB0, 'C',
        0xEE,
        // RETF - far return
        0xCB,
    };

    // Main code at 0x0000
    const code = [_]u8{
        // Setup stack
        // mov esp, 0x8000
        0xBC, 0x00, 0x80, 0x00, 0x00,

        // FAR CALL to 0x1000:0x00000000
        // 9A <offset32> <segment16>
        // offset = 0x00000000, segment = 0x1000
        0x9A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,

        // After RETF, output 'O' and 'K'
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'O',
        0xEE,
        0xB0, 'K',
        0xEE,

        // hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Load subroutine at linear address 0x10000 (segment 0x1000, offset 0)
    try emu.loadBinary(&subroutine, 0x10000);
    // Load main code at 0x0000
    try emu.loadBinary(&code, 0x0000);

    // Run with cycle limit
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 200) : (cycles += 1) {
        try emu.step();
    }

    // Expected output: "FCOK"
    // 'F' and 'C' from subroutine, 'O' and 'K' from main after return
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("FCOK", output.?);
}

// Test: OUTSB with REP - String I/O
test "integration: rep outsb string output" {
    const allocator = std.testing.allocator;

    // String to output at 0x1000
    const test_string = "HELLO";

    // Code to output string using REP OUTSB
    const code = [_]u8{
        // Set up DS:ESI to point to string at 0x1000
        // mov esi, 0x1000
        0xBE, 0x00, 0x10, 0x00, 0x00,

        // Set up DX to UART port 0x3F8
        // mov edx, 0x3F8
        0xBA, 0xF8, 0x03, 0x00, 0x00,

        // Set up counter ECX
        // mov ecx, 5 (length of "HELLO")
        0xB9, 0x05, 0x00, 0x00, 0x00,

        // Clear direction flag (forward)
        // cld
        0xFC,

        // REP OUTSB - output ECX bytes from [DS:ESI] to port DX
        // F3 6E
        0xF3, 0x6E,

        // hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Load string at 0x1000
    try emu.loadBinary(test_string, 0x1000);
    // Load code at 0x0000
    try emu.loadBinary(&code, 0x0000);

    // Run with cycle limit
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 200) : (cycles += 1) {
        try emu.step();
    }

    // Verify string was output
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("HELLO", output.?);
}

// Test: Segment register operations
test "integration: segment register operations" {
    const allocator = std.testing.allocator;

    // Test MOV with segment registers
    const code = [_]u8{
        // Setup initial segment values
        // mov ax, 0x1234
        0xB8, 0x34, 0x12, 0x00, 0x00,
        // mov ds, ax - load DS with 0x1234
        // 8E D8 (ModRM: mod=11, reg=011 (DS), rm=000 (AX))
        0x8E, 0xD8,

        // Now read DS into BX
        // mov bx, ds
        // 8C DB (ModRM: mod=11, reg=011 (DS), rm=011 (BX))
        0x8C, 0xDB,

        // Verify BX == 0x1234
        // cmp bx, 0x1234
        0x66, 0x81, 0xFB, 0x34, 0x12,
        // jne fail
        0x75, 0x21,

        // Copy DS to ES using registers
        // mov ax, ds
        // 8C D8 (ModRM: mod=11, reg=011 (DS), rm=000 (AX))
        0x8C, 0xD8,
        // mov es, ax
        // 8E C0 (ModRM: mod=11, reg=000 (ES), rm=000 (AX))
        0x8E, 0xC0,

        // Verify ES == DS by reading ES
        // mov cx, es
        // 8C C1 (ModRM: mod=11, reg=000 (ES), rm=001 (CX))
        0x8C, 0xC1,

        // Compare CX with BX (both should be 0x1234)
        // cmp cx, bx
        0x66, 0x39, 0xD9,
        // jne fail
        0x75, 0x09,

        // success: output 'S' for Segment
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        0xB0, 'S',
        0xEE,
        0xF4,

        // fail: hlt
        0xF4,
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    // Verify segment registers were updated
    try std.testing.expectEqual(@as(u16, 0x1234), emu.cpu_instance.segments.ds);
    try std.testing.expectEqual(@as(u16, 0x1234), emu.cpu_instance.segments.es);

    // Verify UART output
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("S", output.?);
}

// Test: UD2 instruction raises #UD exception
test "integration: ud2 raises invalid opcode exception" {
    const allocator = std.testing.allocator;

    // Machine code:
    // Set up IVT handler for #UD (vector 6)
    // Then execute UD2 which should raise #UD
    // The handler will write 'X' to UART and halt
    const code = [_]u8{
        // Set up IVT entry 6 (offset 24) to point to handler at 0x0000:0x0100
        0xB8, 0x00, 0x01, 0x00, 0x00, // mov eax, 0x100 (handler offset)
        0xA3, 0x18, 0x00, 0x00, 0x00, // mov [0x18], eax (IVT entry 6 offset)
        0xB8, 0x00, 0x00, 0x00, 0x00, // mov eax, 0x0000 (handler segment)
        0xA3, 0x1C, 0x00, 0x00, 0x00, // mov [0x1C], eax (IVT entry 6 segment)

        // Execute UD2 - this should raise #UD and jump to handler
        0x0F, 0x0B, // ud2

        // Should never get here
        0xF4, // hlt

        // Fill to offset 0x100 for exception handler
        // Initial code is 23 bytes (5+5+5+5+2+1), need 233 NOPs to reach 0x100
    } ++ ([_]u8{0x90} ** (0x100 - 23)) ++ [_]u8{
        // Exception handler at offset 0x100
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8 (UART)
        0xB0, 'X', // mov al, 'X'
        0xEE, // out dx, al
        0xF4, // hlt
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    try emu.loadBinary(&code, 0x0000);
    try emu.run();

    // Verify that exception handler ran and wrote 'X'
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("X", output.?);
}

// Test: Protected mode #GP exception with error code
test "integration: protected mode general protection fault" {
    const allocator = std.testing.allocator;

    // This test sets up protected mode, IDT, and triggers a #GP
    // by attempting to load an invalid segment selector

    // Memory layout:
    // 0x0000 - 0x0FFF: unused
    // 0x1000 - 0x1017: GDT (3 entries × 8 bytes = 24 bytes)
    // 0x2000 - 0x2FFF: IDT (only entry 13 matters at 0x2068)
    // 0x3000 - 0x3FFF: Exception handler
    // 0x4000 - 0x4FFF: Main code and GDTR/IDTR

    // GDT at 0x1000
    const gdt = [_]u8{
        // GDT entry 0: null descriptor (required)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // GDT entry 1: code segment (selector 0x08)
        0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xCF, 0x00,
        // GDT entry 2: data segment (selector 0x10)
        0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00,
    };

    // IDT entry 13 at 0x2068 (#GP): interrupt gate to handler at 0x08:0x3000
    const idt_entry_13 = [_]u8{
        0x00, 0x30, // offset low (0x3000)
        0x08, 0x00, // selector (0x08)
        0x00, // reserved
        0x8E, // present, DPL=0, interrupt gate
        0x00, 0x00, // offset high
    };

    // Exception handler at 0x3000
    const handler = [_]u8{
        // Protected mode #GP handler at 0x3000
        // Pop error code
        0x58, // pop eax (error code)
        // Write 'E' to UART to indicate exception was caught
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        0xB0, 'E', // mov al, 'E'
        0xEE, // out dx, al
        0xF4, // hlt
    };

    // Main code at 0x4000
    const main_code = [_]u8{
        // Set up stack at 0x5000 (grows down)
        0xBC, 0x00, 0x50, 0x00, 0x00, // mov esp, 0x5000

        // Load GDT
        0x0F, 0x01, 0x15, 0xF0, 0x4F, 0x00, 0x00, // lgdt [0x4FF0]

        // Load IDT
        0x0F, 0x01, 0x1D, 0xF6, 0x4F, 0x00, 0x00, // lidt [0x4FF6]

        // Enter protected mode
        0x0F, 0x20, 0xC0, // mov eax, cr0
        0x0C, 0x01, // or al, 1
        0x0F, 0x22, 0xC0, // mov cr0, eax

        // Try to load invalid segment selector (will cause #GP)
        // Selector 0xFF is beyond GDT limit
        0xB8, 0xFF, 0x00, 0x00, 0x00, // mov eax, 0xFF
        0x8E, 0xD8, // mov ds, ax (this causes #GP)

        // Should never reach here
        0xF4, // hlt
    };

    // GDTR and IDTR at 0x4FF0
    const gdtr_idtr = [_]u8{
        // GDTR value at 0x4FF0
        0x17, 0x00, // limit (3 * 8 - 1 = 23 = 0x17)
        0x00, 0x10, 0x00, 0x00, // base (0x1000)

        // IDTR value at 0x4FF6
        0xFF, 0x00, // limit (256 entries)
        0x00, 0x20, 0x00, 0x00, // base (0x2000)
    };

    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024,
        .enable_uart = true,
    });
    defer emu.deinit();

    // Load each component at correct address
    try emu.loadBinary(&gdt, 0x1000);
    try emu.loadBinary(&idt_entry_13, 0x2068); // IDT entry 13 at offset 13*8 = 0x68 from base
    try emu.loadBinary(&handler, 0x3000);
    try emu.loadBinary(&main_code, 0x4000);
    try emu.loadBinary(&gdtr_idtr, 0x4FF0);

    // Start execution at 0x4000 where main code is
    emu.cpu_instance.eip = 0x4000;

    try emu.run();

    // Verify that #GP handler ran and wrote 'E'
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("E", output.?);
}

// Test: Complete real mode to protected mode boot sequence
// Simulates a bootloader transitioning from real mode to protected mode with paging
test "integration: real to protected mode boot" {
    const allocator = std.testing.allocator;

    // Memory layout:
    // 0x0000: Bootstrap code (jumps to boot sector)
    // 0x7000: Stack
    // 0x7C00: Boot sector code (standard BIOS boot address)
    // 0x8000: GDT
    // 0x8100: GDTR structure
    // 0x9000: Page Directory
    // 0xA000: Page Table 0 (identity maps first 4MB)

    // Bootstrap code at 0x0000 - jumps to boot sector at 0x7C00
    const bootstrap = [_]u8{
        // jmp 0x7C00 (near relative jump)
        // E9 <rel32> where rel32 = 0x7C00 - 0x0005 = 0x7BFB
        0xE9, 0xFB, 0x7B, 0x00, 0x00,
    };

    // Boot sector code at 0x7C00 (standard BIOS boot address)
    // This simulates a real bootloader sequence
    const boot_sector = [_]u8{
        // === Real Mode Setup ===
        // cli - clear interrupts
        0xFA,
        // mov esp, 0x7000 - set up stack below boot sector
        0xBC, 0x00, 0x70, 0x00, 0x00,

        // === Load GDT ===
        // lgdt [0x8100] - load GDT descriptor
        0x0F, 0x01, 0x15, 0x00, 0x81, 0x00, 0x00,

        // === Enable Protected Mode ===
        // mov eax, cr0 - get current CR0
        0x0F, 0x20, 0xC0,
        // or al, 1 - set PE bit (Protection Enable)
        0x0C, 0x01,
        // mov cr0, eax - enable protected mode
        0x0F, 0x22, 0xC0,

        // === FAR JMP to flush prefetch queue and load CS ===
        // This is critical! The far jump:
        // 1. Flushes the CPU prefetch queue
        // 2. Loads CS with the protected mode code selector (0x0008)
        // 3. Jumps to the protected mode entry point
        //
        // Format: 66 EA <offset32> <selector16>
        // offset = 0x7C1D (address of protected mode entry point)
        // selector = 0x0008 (code segment from GDT)
        0x66, 0xEA, 0x1D, 0x7C, 0x00, 0x00, 0x08, 0x00,

        // === Protected Mode Entry Point (0x7C1D) ===
        // Now we're in 32-bit protected mode!

        // Load all segment registers with data segment selector
        // mov eax, 0x10 - data segment selector from GDT
        0xB8, 0x10, 0x00, 0x00, 0x00,
        // mov ds, ax - load data segment
        0x8E, 0xD8,
        // mov es, ax - load extra segment
        0x8E, 0xC0,
        // mov ss, ax - load stack segment
        0x8E, 0xD0,

        // === Verify Protected Mode Entry ===
        // Output "PM" to UART to confirm protected mode
        // mov edx, 0x3F8 - UART COM1 port
        0xBA, 0xF8, 0x03, 0x00, 0x00,
        // mov al, 'P'
        0xB0, 'P',
        // out dx, al
        0xEE,
        // mov al, 'M'
        0xB0, 'M',
        // out dx, al
        0xEE,

        // Output "OK" to confirm successful setup
        // mov al, 'O'
        0xB0, 'O',
        // out dx, al
        0xEE,
        // mov al, 'K'
        0xB0, 'K',
        // out dx, al
        0xEE,

        // === Setup Paging ===
        // mov eax, 0x9000 - page directory physical address
        0xB8, 0x00, 0x90, 0x00, 0x00,
        // mov cr3, eax - load page directory base register
        0x0F, 0x22, 0xD8,

        // === Enable Paging ===
        // mov eax, cr0 - get current CR0
        0x0F, 0x20, 0xC0,
        // or eax, 0x80000000 - set PG bit (Paging Enable)
        0x0D, 0x00, 0x00, 0x00, 0x80,
        // mov cr0, eax - enable paging
        0x0F, 0x22, 0xC0,

        // === Verify Paging Enabled ===
        // Output "PG" to confirm paging is active
        // mov al, 'P'
        0xB0, 'P',
        // out dx, al
        0xEE,
        // mov al, 'G'
        0xB0, 'G',
        // out dx, al
        0xEE,

        // === Halt ===
        // hlt - halt the CPU
        0xF4,
    };

    // GDT at 0x8000
    // Three segment descriptors: null, code, data
    const gdt = [_]u8{
        // Entry 0 (0x00): Null descriptor (required by x86 architecture)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

        // Entry 1 (0x08): Code segment descriptor
        // Base = 0x00000000, Limit = 0xFFFFF (4GB with granularity)
        // Access = 0x9A: Present, Ring 0, Code, Execute/Read
        // Flags = 0xCF: 4KB granularity, 32-bit, limit high nibble = 0xF
        0xFF, 0xFF, // Limit low (0xFFFF)
        0x00, 0x00, // Base low (0x0000)
        0x00, // Base middle (0x00)
        0x9A, // Access byte: 1001 1010 = Present, DPL=0, Code, Exec/Read
        0xCF, // Flags + Limit high: 1100 1111 = 4KB gran, 32-bit, limit=0xF
        0x00, // Base high (0x00)

        // Entry 2 (0x10): Data segment descriptor
        // Base = 0x00000000, Limit = 0xFFFFF (4GB with granularity)
        // Access = 0x92: Present, Ring 0, Data, Read/Write
        // Flags = 0xCF: 4KB granularity, 32-bit, limit high nibble = 0xF
        0xFF, 0xFF, // Limit low (0xFFFF)
        0x00, 0x00, // Base low (0x0000)
        0x00, // Base middle (0x00)
        0x92, // Access byte: 1001 0010 = Present, DPL=0, Data, Read/Write
        0xCF, // Flags + Limit high: 1100 1111 = 4KB gran, 32-bit, limit=0xF
        0x00, // Base high (0x00)
    };

    // GDTR structure at 0x8100
    // Format: limit (2 bytes), base address (4 bytes)
    const gdtr = [_]u8{
        0x17, 0x00, // Limit = 23 (3 descriptors × 8 bytes - 1)
        0x00, 0x80, 0x00, 0x00, // Base = 0x8000 (GDT location)
    };

    // Page Directory at 0x9000
    // First entry points to Page Table 0 at 0xA000
    // Remaining 1023 entries are zero (not present)
    var page_dir: [4096]u8 = undefined;
    @memset(&page_dir, 0);
    // PDE 0: Page Table at 0xA000, Present=1, R/W=1, U/S=1
    // Format: bits 31-12 = page table base (0xA000 >> 12 = 0xA)
    //         bits 11-0 = flags (0x007 = present, r/w, user)
    const pde0: u32 = 0x0000A007;
    page_dir[0] = @truncate(pde0);
    page_dir[1] = @truncate(pde0 >> 8);
    page_dir[2] = @truncate(pde0 >> 16);
    page_dir[3] = @truncate(pde0 >> 24);

    // Page Table 0 at 0xA000
    // Identity maps first 4MB (1024 pages × 4KB each)
    // Each PTE maps virtual page N to physical page N
    var page_table: [4096]u8 = undefined;
    @memset(&page_table, 0);
    for (0..1024) |i| {
        // PTE: page frame = i << 12, Present=1, R/W=1, U/S=1
        // Format: bits 31-12 = physical page frame number
        //         bits 11-0 = flags (0x007 = present, r/w, user)
        const pte: u32 = (@as(u32, @intCast(i)) << 12) | 0x007;
        page_table[i * 4 + 0] = @truncate(pte);
        page_table[i * 4 + 1] = @truncate(pte >> 8);
        page_table[i * 4 + 2] = @truncate(pte >> 16);
        page_table[i * 4 + 3] = @truncate(pte >> 24);
    }

    // Create emulator instance
    var emu = try Emulator.init(allocator, .{
        .memory_size = 1024 * 1024, // 1MB memory
        .enable_uart = true, // Enable UART for output verification
    });
    defer emu.deinit();

    // Load all components into memory
    try emu.loadBinary(&bootstrap, 0x0000); // Bootstrap jump at 0x0000
    try emu.loadBinary(&boot_sector, 0x7C00); // Boot sector at standard address
    try emu.loadBinary(&gdt, 0x8000); // GDT
    try emu.loadBinary(&gdtr, 0x8100); // GDT descriptor
    try emu.loadBinary(&page_dir, 0x9000); // Page directory
    try emu.loadBinary(&page_table, 0xA000); // Page table

    // Execute the boot sequence
    // Use cycle limit to prevent infinite loops in case of errors
    var cycles: usize = 0;
    while (!emu.cpu_instance.isHalted() and cycles < 500) : (cycles += 1) {
        try emu.step();
    }

    // === Verification ===

    // 1. Verify we're in protected mode
    try std.testing.expect(emu.cpu_instance.mode == .protected);
    try std.testing.expect(emu.cpu_instance.system.cr0.pe); // Protection Enable bit

    // 2. Verify paging is enabled
    try std.testing.expect(emu.cpu_instance.system.cr0.pg); // Paging bit
    try std.testing.expectEqual(@as(u32, 0x9000), emu.cpu_instance.system.cr3.getPageDirectoryBase());

    // 3. Verify segment registers are loaded with protected mode selectors
    try std.testing.expectEqual(@as(u16, 0x0008), emu.cpu_instance.segments.cs); // Code segment
    try std.testing.expectEqual(@as(u16, 0x0010), emu.cpu_instance.segments.ds); // Data segment
    try std.testing.expectEqual(@as(u16, 0x0010), emu.cpu_instance.segments.es); // Extra segment
    try std.testing.expectEqual(@as(u16, 0x0010), emu.cpu_instance.segments.ss); // Stack segment

    // 4. Verify UART output sequence: "PMOKPG"
    // This confirms:
    // - "PM" = Successfully entered protected mode
    // - "OK" = Protected mode setup completed
    // - "PG" = Paging enabled successfully
    const output = emu.getUartOutput();
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("PMOKPG", output.?);

    // 5. Verify GDT was loaded correctly
    try std.testing.expectEqual(@as(u16, 23), emu.cpu_instance.system.gdtr.limit);
    try std.testing.expectEqual(@as(u32, 0x8000), emu.cpu_instance.system.gdtr.base);
}
