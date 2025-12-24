//! i686 CPU Emulation
//!
//! Emulates an Intel i686 (Pentium Pro/II/III) compatible processor.
//! Supports real mode and protected mode operation.

const std = @import("std");
const memory = @import("../memory/memory.zig");
const io = @import("../io/io.zig");
const instructions = @import("instructions.zig");
const registers = @import("registers.zig");

pub const Registers = registers.Registers;
pub const Flags = registers.Flags;
pub const SegmentRegisters = registers.SegmentRegisters;

/// CPU execution mode
pub const CpuMode = enum {
    real,
    protected,
    vm86,
};

/// CPU state snapshot for debugging
pub const CpuState = struct {
    // General purpose registers
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    esi: u32,
    edi: u32,
    ebp: u32,
    esp: u32,
    // Instruction pointer
    eip: u32,
    // Flags
    eflags: u32,
    // Segment registers
    cs: u16,
    ds: u16,
    es: u16,
    fs: u16,
    gs: u16,
    ss: u16,
    // Mode
    mode: CpuMode,
};

/// CPU error types
pub const CpuError = error{
    InvalidOpcode,
    DivisionByZero,
    GeneralProtectionFault,
    PageFault,
    StackFault,
    InvalidTss,
    SegmentNotPresent,
    DoubleFault,
    Halted,
    MemoryError,
    IoError,
};

/// i686 CPU emulator
pub const Cpu = struct {
    regs: Registers,
    segments: SegmentRegisters,
    flags: Flags,
    eip: u32,
    mode: CpuMode,
    halted: bool,
    mem: *memory.Memory,
    io_ctrl: *io.IoController,
    /// Instruction prefix state
    prefix: PrefixState,
    /// Cycle counter
    cycles: u64,

    const Self = @This();

    const PrefixState = struct {
        operand_size_override: bool = false,
        address_size_override: bool = false,
        segment_override: ?u3 = null,
        rep: RepPrefix = .none,
        lock: bool = false,

        const RepPrefix = enum { none, rep, repne };

        fn reset(self: *PrefixState) void {
            self.* = .{};
        }
    };

    /// Initialize CPU with memory and I/O controllers
    pub fn init(mem: *memory.Memory, io_ctrl: *io.IoController) Self {
        return Self{
            .regs = Registers.init(),
            .segments = SegmentRegisters.init(),
            .flags = Flags.init(),
            .eip = 0,
            .mode = .real,
            .halted = false,
            .mem = mem,
            .io_ctrl = io_ctrl,
            .prefix = .{},
            .cycles = 0,
        };
    }

    /// Reset CPU to initial state
    pub fn reset(self: *Self, cs: u16, ip: u16) void {
        self.regs = Registers.init();
        self.segments = SegmentRegisters.init();
        self.segments.cs = cs;
        self.flags = Flags.init();
        self.eip = ip;
        self.mode = .real;
        self.halted = false;
        self.prefix.reset();
        self.cycles = 0;
    }

    /// Check if CPU is halted
    pub fn isHalted(self: *const Self) bool {
        return self.halted;
    }

    /// Get current CPU state snapshot
    pub fn getState(self: *const Self) CpuState {
        return CpuState{
            .eax = self.regs.eax,
            .ebx = self.regs.ebx,
            .ecx = self.regs.ecx,
            .edx = self.regs.edx,
            .esi = self.regs.esi,
            .edi = self.regs.edi,
            .ebp = self.regs.ebp,
            .esp = self.regs.esp,
            .eip = self.eip,
            .eflags = self.flags.toU32(),
            .cs = self.segments.cs,
            .ds = self.segments.ds,
            .es = self.segments.es,
            .fs = self.segments.fs,
            .gs = self.segments.gs,
            .ss = self.segments.ss,
            .mode = self.mode,
        };
    }

    /// Calculate effective address in current mode
    pub fn getEffectiveAddress(self: *const Self, segment: u16, offset: u32) u32 {
        return switch (self.mode) {
            .real, .vm86 => (@as(u32, segment) << 4) + (offset & 0xFFFF),
            .protected => offset, // Simplified - should use segment descriptors
        };
    }

    /// Get current code address
    fn getCodeAddress(self: *const Self) u32 {
        return self.getEffectiveAddress(self.segments.cs, self.eip);
    }

    /// Fetch byte at EIP and advance
    fn fetchByte(self: *Self) !u8 {
        const addr = self.getCodeAddress();
        const byte = try self.mem.readByte(addr);
        self.eip +%= 1;
        return byte;
    }

    /// Fetch word at EIP and advance
    fn fetchWord(self: *Self) !u16 {
        const lo = try self.fetchByte();
        const hi = try self.fetchByte();
        return (@as(u16, hi) << 8) | lo;
    }

    /// Fetch dword at EIP and advance
    fn fetchDword(self: *Self) !u32 {
        const lo = try self.fetchWord();
        const hi = try self.fetchWord();
        return (@as(u32, hi) << 16) | lo;
    }

    /// Execute single instruction
    pub fn step(self: *Self) !void {
        if (self.halted) {
            return CpuError.Halted;
        }

        self.prefix.reset();

        // Decode and execute instruction
        try self.decodeAndExecute();

        self.cycles += 1;
    }

    /// Decode and execute current instruction
    fn decodeAndExecute(self: *Self) !void {
        const opcode = try self.fetchByte();

        // Handle prefixes
        switch (opcode) {
            0x66 => {
                self.prefix.operand_size_override = true;
                return self.decodeAndExecute();
            },
            0x67 => {
                self.prefix.address_size_override = true;
                return self.decodeAndExecute();
            },
            0x26 => {
                self.prefix.segment_override = 0; // ES
                return self.decodeAndExecute();
            },
            0x2E => {
                self.prefix.segment_override = 1; // CS
                return self.decodeAndExecute();
            },
            0x36 => {
                self.prefix.segment_override = 2; // SS
                return self.decodeAndExecute();
            },
            0x3E => {
                self.prefix.segment_override = 3; // DS
                return self.decodeAndExecute();
            },
            0x64 => {
                self.prefix.segment_override = 4; // FS
                return self.decodeAndExecute();
            },
            0x65 => {
                self.prefix.segment_override = 5; // GS
                return self.decodeAndExecute();
            },
            0xF0 => {
                self.prefix.lock = true;
                return self.decodeAndExecute();
            },
            0xF2 => {
                self.prefix.rep = .repne;
                return self.decodeAndExecute();
            },
            0xF3 => {
                self.prefix.rep = .rep;
                return self.decodeAndExecute();
            },
            else => {},
        }

        // Execute instruction
        try instructions.execute(self, opcode);
    }

    /// Push value onto stack
    pub fn push(self: *Self, value: u32) !void {
        self.regs.esp -%= 4;
        const addr = self.getEffectiveAddress(self.segments.ss, self.regs.esp);
        try self.mem.writeDword(addr, value);
    }

    /// Push 16-bit value onto stack
    pub fn push16(self: *Self, value: u16) !void {
        self.regs.esp -%= 2;
        const addr = self.getEffectiveAddress(self.segments.ss, self.regs.esp);
        try self.mem.writeWord(addr, value);
    }

    /// Pop value from stack
    pub fn pop(self: *Self) !u32 {
        const addr = self.getEffectiveAddress(self.segments.ss, self.regs.esp);
        const value = try self.mem.readDword(addr);
        self.regs.esp +%= 4;
        return value;
    }

    /// Pop 16-bit value from stack
    pub fn pop16(self: *Self) !u16 {
        const addr = self.getEffectiveAddress(self.segments.ss, self.regs.esp);
        const value = try self.mem.readWord(addr);
        self.regs.esp +%= 2;
        return value;
    }

    /// Read byte from I/O port
    pub fn inByte(self: *Self, port: u16) !u8 {
        return self.io_ctrl.readByte(port);
    }

    /// Write byte to I/O port
    pub fn outByte(self: *Self, port: u16, value: u8) !void {
        try self.io_ctrl.writeByte(port, value);
    }

    /// Halt the CPU
    pub fn halt(self: *Self) void {
        self.halted = true;
    }
};

// Tests
test "cpu initialization" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);
    try std.testing.expectEqual(@as(u32, 0), cpu.eip);
    try std.testing.expect(!cpu.halted);
}

test "cpu reset" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0x1234;
    cpu.regs.eax = 0xDEADBEEF;

    cpu.reset(0x1000, 0x0100);

    try std.testing.expectEqual(@as(u16, 0x1000), cpu.segments.cs);
    try std.testing.expectEqual(@as(u32, 0x0100), cpu.eip);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.eax);
}

test "cpu effective address calculation" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);

    // Real mode: segment * 16 + offset
    const addr = cpu.getEffectiveAddress(0x1000, 0x0100);
    try std.testing.expectEqual(@as(u32, 0x10100), addr);
}

test "cpu state snapshot" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);
    cpu.regs.eax = 0x12345678;
    cpu.segments.cs = 0x0800;
    cpu.eip = 0x0200;

    const state = cpu.getState();
    try std.testing.expectEqual(@as(u32, 0x12345678), state.eax);
    try std.testing.expectEqual(@as(u16, 0x0800), state.cs);
    try std.testing.expectEqual(@as(u32, 0x0200), state.eip);
}
