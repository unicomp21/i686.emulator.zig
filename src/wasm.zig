//! WebAssembly Interface
//!
//! Provides a WebAssembly-compatible interface for the i686 emulator.
//! Designed for browser-based emulation and testing.

const std = @import("std");
const root = @import("root.zig");

const Emulator = root.Emulator;
const Config = root.Config;

/// WASM-compatible allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

/// Global emulator instance (single instance for WASM)
var emulator: ?Emulator = null;

/// Memory buffer for passing data between JS and WASM
var io_buffer: [4096]u8 = undefined;

// ============================================
// Exported Functions
// ============================================

/// Initialize the emulator with default configuration
export fn init() i32 {
    return initWithConfig(16 * 1024 * 1024, 1, 0);
}

/// Initialize the emulator with custom configuration
export fn initWithConfig(memory_size: u32, enable_uart: u32, initial_ip: u32) i32 {
    if (emulator != null) {
        deinit();
    }

    emulator = Emulator.init(allocator, .{
        .memory_size = memory_size,
        .enable_uart = enable_uart != 0,
        .initial_ip = initial_ip,
    }) catch return -1;

    return 0;
}

/// Clean up emulator resources
export fn deinit() void {
    if (emulator) |*emu| {
        emu.deinit();
        emulator = null;
    }
}

/// Reset the emulator
export fn reset() void {
    if (emulator) |*emu| {
        emu.reset();
    }
}

/// Execute a single instruction
export fn step() i32 {
    if (emulator) |*emu| {
        emu.step() catch return -1;
        return 0;
    }
    return -1;
}

/// Run until halt or error
export fn run() i32 {
    if (emulator) |*emu| {
        emu.run() catch return -1;
        return 0;
    }
    return -1;
}

/// Run for a specified number of cycles
export fn runCycles(max_cycles: u32) i32 {
    if (emulator) |*emu| {
        var cycles: u32 = 0;
        while (cycles < max_cycles and !emu.cpu_instance.isHalted()) : (cycles += 1) {
            emu.step() catch return -1;
        }
        return @intCast(cycles);
    }
    return -1;
}

/// Check if CPU is halted
export fn isHalted() i32 {
    if (emulator) |*emu| {
        return if (emu.cpu_instance.isHalted()) 1 else 0;
    }
    return 1;
}

/// Get pointer to I/O buffer for data transfer
export fn getIoBuffer() [*]u8 {
    return &io_buffer;
}

/// Get I/O buffer size
export fn getIoBufferSize() u32 {
    return io_buffer.len;
}

/// Load binary data from I/O buffer into memory
export fn loadBinary(address: u32, length: u32) i32 {
    if (emulator) |*emu| {
        if (length > io_buffer.len) return -1;
        emu.loadBinary(io_buffer[0..length], address) catch return -1;
        return 0;
    }
    return -1;
}

/// Write byte to memory
export fn writeByte(address: u32, value: u8) i32 {
    if (emulator) |*emu| {
        emu.mem.writeByte(address, value) catch return -1;
        return 0;
    }
    return -1;
}

/// Read byte from memory
export fn readByte(address: u32) i32 {
    if (emulator) |*emu| {
        return emu.mem.readByte(address) catch return -1;
    }
    return -1;
}

/// Write dword to memory
export fn writeDword(address: u32, value: u32) i32 {
    if (emulator) |*emu| {
        emu.mem.writeDword(address, value) catch return -1;
        return 0;
    }
    return -1;
}

/// Read dword from memory
export fn readDword(address: u32) i32 {
    if (emulator) |*emu| {
        return @bitCast(emu.mem.readDword(address) catch return -1);
    }
    return -1;
}

// ============================================
// Register Access
// ============================================

/// Get EAX register
export fn getEax() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.eax;
    }
    return 0;
}

/// Set EAX register
export fn setEax(value: u32) void {
    if (emulator) |*emu| {
        emu.cpu_instance.regs.eax = value;
    }
}

/// Get EBX register
export fn getEbx() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.ebx;
    }
    return 0;
}

/// Set EBX register
export fn setEbx(value: u32) void {
    if (emulator) |*emu| {
        emu.cpu_instance.regs.ebx = value;
    }
}

/// Get ECX register
export fn getEcx() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.ecx;
    }
    return 0;
}

/// Set ECX register
export fn setEcx(value: u32) void {
    if (emulator) |*emu| {
        emu.cpu_instance.regs.ecx = value;
    }
}

/// Get EDX register
export fn getEdx() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.edx;
    }
    return 0;
}

/// Set EDX register
export fn setEdx(value: u32) void {
    if (emulator) |*emu| {
        emu.cpu_instance.regs.edx = value;
    }
}

/// Get ESP register
export fn getEsp() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.esp;
    }
    return 0;
}

/// Set ESP register
export fn setEsp(value: u32) void {
    if (emulator) |*emu| {
        emu.cpu_instance.regs.esp = value;
    }
}

/// Get EBP register
export fn getEbp() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.ebp;
    }
    return 0;
}

/// Get ESI register
export fn getEsi() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.esi;
    }
    return 0;
}

/// Get EDI register
export fn getEdi() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.regs.edi;
    }
    return 0;
}

/// Get EIP register
export fn getEip() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.eip;
    }
    return 0;
}

/// Set EIP register
export fn setEip(value: u32) void {
    if (emulator) |*emu| {
        emu.cpu_instance.eip = value;
    }
}

/// Get EFLAGS register
export fn getEflags() u32 {
    if (emulator) |*emu| {
        return emu.cpu_instance.flags.toU32();
    }
    return 0;
}

/// Get CS segment register
export fn getCs() u16 {
    if (emulator) |*emu| {
        return emu.cpu_instance.segments.cs;
    }
    return 0;
}

// ============================================
// UART Access
// ============================================

/// Get UART output length
export fn getUartOutputLength() u32 {
    if (emulator) |*emu| {
        if (emu.getUartOutput()) |output| {
            return @intCast(output.len);
        }
    }
    return 0;
}

/// Copy UART output to I/O buffer
export fn copyUartOutput() u32 {
    if (emulator) |*emu| {
        if (emu.getUartOutput()) |output| {
            const len = @min(output.len, io_buffer.len);
            @memcpy(io_buffer[0..len], output[0..len]);
            return @intCast(len);
        }
    }
    return 0;
}

/// Send input to UART from I/O buffer
export fn sendUartInput(length: u32) i32 {
    if (emulator) |*emu| {
        if (length > io_buffer.len) return -1;
        emu.sendUartInput(io_buffer[0..length]) catch return -1;
        return 0;
    }
    return -1;
}

/// Clear UART output buffer
export fn clearUartOutput() void {
    if (emulator) |*emu| {
        if (emu.io_ctrl.getUart(emu.config.uart_base)) |uart| {
            uart.clearOutputBuffer();
        }
    }
}

// ============================================
// Debug Functions
// ============================================

/// Get cycle count
export fn getCycles() u64 {
    if (emulator) |*emu| {
        return emu.cpu_instance.cycles;
    }
    return 0;
}

/// Get CPU mode (0=real, 1=protected, 2=vm86)
export fn getCpuMode() u32 {
    if (emulator) |*emu| {
        return @intFromEnum(emu.cpu_instance.mode);
    }
    return 0;
}
