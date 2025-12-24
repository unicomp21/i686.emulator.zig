//! i686 CPU Emulation
//!
//! Emulates an Intel i686 (Pentium Pro/II/III) compatible processor.
//! Supports real mode and protected mode operation.

const std = @import("std");
const memory = @import("../memory/memory.zig");
const io = @import("../io/io.zig");
const instructions = @import("instructions.zig");
const registers = @import("registers.zig");
const protected_mode = @import("protected_mode.zig");

pub const Registers = registers.Registers;
pub const Flags = registers.Flags;
pub const SegmentRegisters = registers.SegmentRegisters;
pub const SystemRegisters = protected_mode.SystemRegisters;
pub const SegmentDescriptor = protected_mode.SegmentDescriptor;
pub const GateDescriptor = protected_mode.GateDescriptor;
pub const CR0 = protected_mode.CR0;
pub const CR3 = protected_mode.CR3;
pub const CR4 = protected_mode.CR4;
pub const PageDirectoryEntry = protected_mode.PageDirectoryEntry;
pub const PageTableEntry = protected_mode.PageTableEntry;
pub const PageFaultErrorCode = protected_mode.PageFaultErrorCode;
pub const PageTranslationResult = protected_mode.PageTranslationResult;
pub const PageTranslationError = protected_mode.PageTranslationError;

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

/// Instruction history entry for debugging
pub const InstrHistoryEntry = struct {
    eip: u32,
    cs: u16,
    opcode: u8,
    opcode2: u8, // For two-byte opcodes
    is_two_byte: bool,
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
    /// System registers (GDTR, IDTR, CR0-CR4, etc.)
    system: SystemRegisters,
    /// Cached segment descriptors for performance
    seg_cache: [6]SegmentDescriptor,
    /// Instruction history buffer (circular, last 32 instructions)
    instr_history: [32]InstrHistoryEntry,
    /// Current position in history buffer
    instr_history_pos: usize,
    /// Current instruction being decoded (for history)
    current_instr_eip: u32,
    current_instr_cs: u16,

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
            .system = SystemRegisters.init(),
            .seg_cache = [_]SegmentDescriptor{SegmentDescriptor.fromBytes([8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 })} ** 6,
            .instr_history = [_]InstrHistoryEntry{.{ .eip = 0, .cs = 0, .opcode = 0, .opcode2 = 0, .is_two_byte = false }} ** 32,
            .instr_history_pos = 0,
            .current_instr_eip = 0,
            .current_instr_cs = 0,
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
        self.system = SystemRegisters.init();
        self.seg_cache = [_]SegmentDescriptor{SegmentDescriptor.fromBytes([8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 })} ** 6;
        self.instr_history = [_]InstrHistoryEntry{.{ .eip = 0, .cs = 0, .opcode = 0, .opcode2 = 0, .is_two_byte = false }} ** 32;
        self.instr_history_pos = 0;
    }

    /// Record instruction in history buffer
    pub fn recordInstruction(self: *Self, opcode: u8, opcode2: u8, is_two_byte: bool) void {
        self.instr_history[self.instr_history_pos] = .{
            .eip = self.current_instr_eip,
            .cs = self.current_instr_cs,
            .opcode = opcode,
            .opcode2 = opcode2,
            .is_two_byte = is_two_byte,
        };
        self.instr_history_pos = (self.instr_history_pos + 1) % 32;
    }

    /// Dump instruction history (for debugging)
    pub fn dumpInstructionHistory(self: *const Self) void {
        std.debug.print("\n=== INSTRUCTION HISTORY (last 32) ===\n", .{});
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const idx = (self.instr_history_pos + i) % 32;
            const entry = self.instr_history[idx];
            if (entry.eip != 0 or entry.opcode != 0) {
                if (entry.is_two_byte) {
                    std.debug.print("  [{d:2}] {X:04}:{X:08}  0F {X:02}\n", .{ i, entry.cs, entry.eip, entry.opcode2 });
                } else {
                    std.debug.print("  [{d:2}] {X:04}:{X:08}  {X:02}\n", .{ i, entry.cs, entry.eip, entry.opcode });
                }
            }
        }
        std.debug.print("=====================================\n", .{});
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
            .protected => {
                // In protected mode, use segment descriptor base
                const seg_index = self.getSegmentIndex(segment);
                if (seg_index) |idx| {
                    return self.seg_cache[idx].base +% offset;
                }
                return offset; // Fallback for invalid segment
            },
        };
    }

    /// Get segment cache index from segment register value
    fn getSegmentIndex(self: *const Self, segment: u16) ?usize {
        if (segment == self.segments.es) return 0;
        if (segment == self.segments.cs) return 1;
        if (segment == self.segments.ss) return 2;
        if (segment == self.segments.ds) return 3;
        if (segment == self.segments.fs) return 4;
        if (segment == self.segments.gs) return 5;
        return null;
    }

    /// Load segment descriptor from GDT/LDT into cache
    pub fn loadSegmentDescriptor(self: *Self, selector: u16, cache_index: usize) !void {
        if (selector == 0) {
            // Null selector - create null descriptor
            self.seg_cache[cache_index] = SegmentDescriptor.fromBytes([8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
            return;
        }

        // Get descriptor table base and limit
        const ti = (selector >> 2) & 1; // Table indicator: 0 = GDT, 1 = LDT
        const index = selector >> 3; // Descriptor index
        const dtr = if (ti == 0) self.system.gdtr else self.system.gdtr; // TODO: LDT support

        // Check if index is within table limit
        const offset = @as(u32, index) * 8;
        if (offset + 7 > dtr.limit) {
            return CpuError.GeneralProtectionFault;
        }

        // Read 8-byte descriptor from memory
        var bytes: [8]u8 = undefined;
        for (0..8) |i| {
            bytes[i] = try self.mem.readByte(dtr.base + offset + @as(u32, @intCast(i)));
        }

        self.seg_cache[cache_index] = SegmentDescriptor.fromBytes(bytes);

        // Check if segment is present
        if (!self.seg_cache[cache_index].isPresent() and selector != 0) {
            return CpuError.SegmentNotPresent;
        }
    }

    /// Switch to protected mode
    pub fn enterProtectedMode(self: *Self) void {
        self.mode = .protected;
        self.system.cr0.pe = true;
    }

    /// Switch back to real mode
    pub fn enterRealMode(self: *Self) void {
        self.mode = .real;
        self.system.cr0.pe = false;
    }

    /// Translate linear address to physical address through paging
    /// Returns the physical address or a page fault error
    pub fn translateLinearToPhysical(self: *Self, linear_address: u32, is_write: bool, is_user: bool) !u32 {
        // If paging is not enabled, linear = physical
        if (!self.system.cr0.pg) {
            return linear_address;
        }

        // Extract page directory index (bits 31:22), page table index (bits 21:12), offset (bits 11:0)
        const pde_index = (linear_address >> 22) & 0x3FF;
        const pte_index = (linear_address >> 12) & 0x3FF;
        const offset = linear_address & 0xFFF;

        // Get page directory base from CR3
        const pdb = self.system.cr3.getPageDirectoryBase();

        // Read page directory entry
        const pde_addr = pdb + (pde_index * 4);
        const pde_raw = try self.mem.readDword(pde_addr);
        const pde = PageDirectoryEntry.fromU32(pde_raw);

        // Check if PDE is present
        if (!pde.present) {
            // Page fault - page directory entry not present
            self.system.cr2 = linear_address;
            return CpuError.PageFault;
        }

        // Check for 4MB page (PSE)
        if (pde.ps and self.system.cr4.pse) {
            // 4MB page - use bits 31:22 from PDE, bits 21:0 from linear address
            const physical_base = pde.get4MBPageAddress() & 0xFFC00000;
            const page_offset = linear_address & 0x003FFFFF;

            // Check permissions
            if (is_write and !pde.rw) {
                if (self.system.cr0.wp or is_user) {
                    self.system.cr2 = linear_address;
                    return CpuError.PageFault;
                }
            }
            if (is_user and !pde.us) {
                self.system.cr2 = linear_address;
                return CpuError.PageFault;
            }

            // Set accessed bit (would normally be done by hardware)
            // For now, we skip this to avoid complexity

            return physical_base | page_offset;
        }

        // 4KB page - read page table entry
        const pt_addr = pde.getPageTableAddress();
        const pte_addr = pt_addr + (pte_index * 4);
        const pte_raw = try self.mem.readDword(pte_addr);
        const pte = PageTableEntry.fromU32(pte_raw);

        // Check if PTE is present
        if (!pte.present) {
            // Page fault - page table entry not present
            self.system.cr2 = linear_address;
            return CpuError.PageFault;
        }

        // Check permissions (combine PDE and PTE)
        // Write protection: if either PDE or PTE has R/W=0, page is read-only
        const page_writable = pde.rw and pte.rw;
        // User access: if either PDE or PTE has U/S=0, page is supervisor-only
        const page_user = pde.us and pte.us;

        if (is_write and !page_writable) {
            // WP (Write Protect) in CR0 controls supervisor writes to read-only pages
            if (self.system.cr0.wp or is_user) {
                self.system.cr2 = linear_address;
                return CpuError.PageFault;
            }
        }
        if (is_user and !page_user) {
            self.system.cr2 = linear_address;
            return CpuError.PageFault;
        }

        // Calculate physical address
        const physical_address = pte.getPageFrameAddress() | offset;
        return physical_address;
    }

    /// Read byte from memory, going through paging if enabled
    pub fn readMemByte(self: *Self, linear_address: u32) !u8 {
        const physical = try self.translateLinearToPhysical(linear_address, false, false);
        return self.mem.readByte(physical);
    }

    /// Read word from memory, going through paging if enabled
    pub fn readMemWord(self: *Self, linear_address: u32) !u16 {
        // For simplicity, assume no page boundary crossing
        const physical = try self.translateLinearToPhysical(linear_address, false, false);
        return self.mem.readWord(physical);
    }

    /// Read dword from memory, going through paging if enabled
    pub fn readMemDword(self: *Self, linear_address: u32) !u32 {
        // For simplicity, assume no page boundary crossing
        const physical = try self.translateLinearToPhysical(linear_address, false, false);
        return self.mem.readDword(physical);
    }

    /// Write byte to memory, going through paging if enabled
    pub fn writeMemByte(self: *Self, linear_address: u32, value: u8) !void {
        const physical = try self.translateLinearToPhysical(linear_address, true, false);
        try self.mem.writeByte(physical, value);
    }

    /// Write word to memory, going through paging if enabled
    pub fn writeMemWord(self: *Self, linear_address: u32, value: u16) !void {
        const physical = try self.translateLinearToPhysical(linear_address, true, false);
        try self.mem.writeWord(physical, value);
    }

    /// Write dword to memory, going through paging if enabled
    pub fn writeMemDword(self: *Self, linear_address: u32, value: u32) !void {
        const physical = try self.translateLinearToPhysical(linear_address, true, false);
        try self.mem.writeDword(physical, value);
    }

    /// Get current code address (linear)
    fn getCodeAddress(self: *const Self) u32 {
        return self.getEffectiveAddress(self.segments.cs, self.eip);
    }

    /// Fetch byte at EIP and advance (goes through paging)
    pub fn fetchByte(self: *Self) !u8 {
        const linear_addr = self.getCodeAddress();
        const byte = try self.readMemByte(linear_addr);
        self.eip +%= 1;
        return byte;
    }

    /// Fetch word at EIP and advance (goes through paging)
    pub fn fetchWord(self: *Self) !u16 {
        const lo = try self.fetchByte();
        const hi = try self.fetchByte();
        return (@as(u16, hi) << 8) | lo;
    }

    /// Fetch dword at EIP and advance (goes through paging)
    pub fn fetchDword(self: *Self) !u32 {
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

        // Save current instruction position for history
        self.current_instr_eip = self.eip;
        self.current_instr_cs = self.segments.cs;

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
        try self.writeMemDword(addr, value);
    }

    /// Push 16-bit value onto stack
    pub fn push16(self: *Self, value: u16) !void {
        self.regs.esp -%= 2;
        const addr = self.getEffectiveAddress(self.segments.ss, self.regs.esp);
        try self.writeMemWord(addr, value);
    }

    /// Pop value from stack
    pub fn pop(self: *Self) !u32 {
        const addr = self.getEffectiveAddress(self.segments.ss, self.regs.esp);
        const value = try self.readMemDword(addr);
        self.regs.esp +%= 4;
        return value;
    }

    /// Pop 16-bit value from stack
    pub fn pop16(self: *Self) !u16 {
        const addr = self.getEffectiveAddress(self.segments.ss, self.regs.esp);
        const value = try self.readMemWord(addr);
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

    /// Dispatch interrupt through IDT (protected mode) or IVT (real mode)
    pub fn dispatchInterrupt(self: *Self, vector: u8) !void {
        if (self.mode == .protected) {
            // Protected mode: use IDT
            const offset = @as(u32, vector) * 8;

            // Check if interrupt descriptor is within IDT limit
            if (offset + 7 > self.system.idtr.limit) {
                return CpuError.GeneralProtectionFault;
            }

            // Read 8-byte gate descriptor from IDT
            var bytes: [8]u8 = undefined;
            for (0..8) |i| {
                bytes[i] = try self.mem.readByte(self.system.idtr.base + offset + @as(u32, @intCast(i)));
            }

            const gate = protected_mode.GateDescriptor.fromBytes(bytes);

            // Check if gate is present
            if (!gate.isPresent()) {
                return CpuError.GeneralProtectionFault;
            }

            // Push EFLAGS, CS, EIP
            try self.push(self.flags.toU32());
            try self.push16(self.segments.cs);
            try self.push(self.eip);

            // Load new CS:EIP from gate descriptor
            self.segments.cs = gate.selector;
            self.eip = gate.getOffset();

            // Clear IF flag for interrupt gates (not for trap gates)
            if (gate.isInterruptGate()) {
                self.flags.interrupt = false;
            }
        } else {
            // Real mode: use IVT at fixed location 0x00000000
            const vector_addr = @as(u32, vector) * 4;

            // Push flags, CS, IP
            try self.push(self.flags.toU32());
            try self.push16(self.segments.cs);
            try self.push(@truncate(self.eip));

            // Read new IP and CS from IVT
            const new_ip = try self.mem.readWord(vector_addr);
            const new_cs = try self.mem.readWord(vector_addr + 2);

            self.eip = new_ip;
            self.segments.cs = new_cs;
            self.flags.interrupt = false;
        }
    }
};

// Tests
test "cpu initialization" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    const cpu = Cpu.init(&mem, &io_ctrl);
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
