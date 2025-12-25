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

/// x86 Exception Vectors (Intel Vol 3, Section 6.3.1)
pub const Exception = enum(u8) {
    /// #DE - Divide Error
    divide_error = 0,
    /// #DB - Debug Exception
    debug = 1,
    /// NMI - Non-Maskable Interrupt
    nmi = 2,
    /// #BP - Breakpoint
    breakpoint = 3,
    /// #OF - Overflow
    overflow = 4,
    /// #BR - BOUND Range Exceeded
    bound_range = 5,
    /// #UD - Invalid Opcode
    invalid_opcode = 6,
    /// #NM - Device Not Available (No Math Coprocessor)
    device_not_available = 7,
    /// #DF - Double Fault (with error code)
    double_fault = 8,
    /// Coprocessor Segment Overrun (reserved)
    coprocessor_segment_overrun = 9,
    /// #TS - Invalid TSS (with error code)
    invalid_tss = 10,
    /// #NP - Segment Not Present (with error code)
    segment_not_present = 11,
    /// #SS - Stack-Segment Fault (with error code)
    stack_fault = 12,
    /// #GP - General Protection Fault (with error code)
    general_protection = 13,
    /// #PF - Page Fault (with error code)
    page_fault = 14,
    /// Reserved
    reserved_15 = 15,
    /// #MF - x87 FPU Floating-Point Error
    x87_fpu_error = 16,
    /// #AC - Alignment Check (with error code)
    alignment_check = 17,
    /// #MC - Machine Check
    machine_check = 18,
    /// #XM - SIMD Floating-Point Exception
    simd_floating_point = 19,
    /// #VE - Virtualization Exception
    virtualization_exception = 20,
    /// #CP - Control Protection Exception (with error code)
    control_protection = 21,
    // 22-31 reserved
    // 32-255 user-defined (maskable interrupts)

    /// Check if this exception pushes an error code
    pub fn hasErrorCode(self: Exception) bool {
        return switch (self) {
            .double_fault,
            .invalid_tss,
            .segment_not_present,
            .stack_fault,
            .general_protection,
            .page_fault,
            .alignment_check,
            .control_protection,
            => true,
            else => false,
        };
    }

    /// Get the exception vector number
    pub fn vector(self: Exception) u8 {
        return @intFromEnum(self);
    }
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

    /// Read word from I/O port
    pub fn inWord(self: *Self, port: u16) !u16 {
        return self.io_ctrl.readWord(port);
    }

    /// Write word to I/O port
    pub fn outWord(self: *Self, port: u16, value: u16) !void {
        try self.io_ctrl.writeWord(port, value);
    }

    /// Read dword from I/O port
    pub fn inDword(self: *Self, port: u16) !u32 {
        return self.io_ctrl.readDword(port);
    }

    /// Write dword to I/O port
    pub fn outDword(self: *Self, port: u16, value: u32) !void {
        try self.io_ctrl.writeDword(port, value);
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

    /// Raise an exception with optional error code
    /// This properly handles exceptions according to x86 architecture:
    /// - Sets CR2 for page faults
    /// - Pushes error code for exceptions that require it
    /// - Dispatches through IDT/IVT
    pub fn raiseException(self: *Self, exception: Exception, error_code: ?u32) !void {
        const vec = exception.vector();

        // Special handling for page faults: set CR2 to faulting address
        if (exception == .page_fault) {
            // CR2 should already be set by the code that detected the page fault
            // but we can set it here if error_code contains the faulting address
            // For now, we rely on the caller to have set CR2
        }

        if (self.mode == .protected) {
            // Protected mode: use IDT
            const offset = @as(u32, vec) * 8;

            // Check if exception descriptor is within IDT limit
            if (offset + 7 > self.system.idtr.limit) {
                // If we can't deliver the exception, it's a double fault
                if (exception != .double_fault) {
                    return self.raiseException(.double_fault, 0);
                }
                // Triple fault - halt the CPU
                self.halted = true;
                return CpuError.DoubleFault;
            }

            // Read 8-byte gate descriptor from IDT
            var bytes: [8]u8 = undefined;
            for (0..8) |i| {
                bytes[i] = try self.mem.readByte(self.system.idtr.base + offset + @as(u32, @intCast(i)));
            }

            const gate = protected_mode.GateDescriptor.fromBytes(bytes);

            // Check if gate is present
            if (!gate.isPresent()) {
                // Non-present exception handler causes double fault
                if (exception != .double_fault) {
                    return self.raiseException(.double_fault, 0);
                }
                // Triple fault
                self.halted = true;
                return CpuError.DoubleFault;
            }

            // Push EFLAGS, CS, EIP
            try self.push(self.flags.toU32());
            try self.push16(self.segments.cs);
            try self.push(self.eip);

            // Push error code if this exception has one
            if (exception.hasErrorCode()) {
                try self.push(error_code orelse 0);
            }

            // Load new CS:EIP from gate descriptor
            self.segments.cs = gate.selector;
            self.eip = gate.getOffset();

            // Clear IF flag for interrupt gates (not for trap gates)
            if (gate.isInterruptGate()) {
                self.flags.interrupt = false;
            }
        } else {
            // Real mode: use IVT at fixed location 0x00000000
            const vector_addr = @as(u32, vec) * 4;

            // Push flags, CS, IP
            try self.push(self.flags.toU32());
            try self.push16(self.segments.cs);
            try self.push(@truncate(self.eip));

            // In real mode, error codes are not pushed (they're a protected mode feature)
            // Some BIOS implementations might expect error codes, but standard real mode doesn't use them

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

test "exception vector constants" {
    // Verify exception vectors match x86 specification
    try std.testing.expectEqual(@as(u8, 0), Exception.divide_error.vector());
    try std.testing.expectEqual(@as(u8, 6), Exception.invalid_opcode.vector());
    try std.testing.expectEqual(@as(u8, 13), Exception.general_protection.vector());
    try std.testing.expectEqual(@as(u8, 14), Exception.page_fault.vector());
}

test "exception error code flags" {
    // Exceptions that should have error codes
    try std.testing.expect(Exception.double_fault.hasErrorCode());
    try std.testing.expect(Exception.invalid_tss.hasErrorCode());
    try std.testing.expect(Exception.segment_not_present.hasErrorCode());
    try std.testing.expect(Exception.stack_fault.hasErrorCode());
    try std.testing.expect(Exception.general_protection.hasErrorCode());
    try std.testing.expect(Exception.page_fault.hasErrorCode());
    try std.testing.expect(Exception.alignment_check.hasErrorCode());

    // Exceptions that should NOT have error codes
    try std.testing.expect(!Exception.divide_error.hasErrorCode());
    try std.testing.expect(!Exception.debug.hasErrorCode());
    try std.testing.expect(!Exception.breakpoint.hasErrorCode());
    try std.testing.expect(!Exception.overflow.hasErrorCode());
    try std.testing.expect(!Exception.bound_range.hasErrorCode());
    try std.testing.expect(!Exception.invalid_opcode.hasErrorCode());
    try std.testing.expect(!Exception.device_not_available.hasErrorCode());
}

test "raise exception in real mode" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 64 * 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);
    cpu.reset(0x0000, 0x1000);
    cpu.regs.esp = 0x1000;

    // Set up IVT entry for #UD (vector 6)
    // IVT is at 0x00000000, each entry is 4 bytes (offset:segment)
    try mem.writeWord(6 * 4, 0x2000); // IP
    try mem.writeWord(6 * 4 + 2, 0x0000); // CS

    const original_eip = cpu.eip;
    const original_cs = cpu.segments.cs;
    const original_flags = cpu.flags.toU32();

    // Raise #UD exception
    try cpu.raiseException(.invalid_opcode, null);

    // Check that exception was dispatched
    try std.testing.expectEqual(@as(u32, 0x2000), cpu.eip);
    try std.testing.expectEqual(@as(u16, 0x0000), cpu.segments.cs);

    // Check that flags, CS, and IP were pushed onto stack
    const pushed_ip = try mem.readWord(cpu.getEffectiveAddress(cpu.segments.ss, cpu.regs.esp));
    const pushed_cs = try mem.readWord(cpu.getEffectiveAddress(cpu.segments.ss, cpu.regs.esp + 2));
    const pushed_flags = try mem.readDword(cpu.getEffectiveAddress(cpu.segments.ss, cpu.regs.esp + 4));

    try std.testing.expectEqual(@as(u16, @truncate(original_eip)), pushed_ip);
    try std.testing.expectEqual(original_cs, pushed_cs);
    try std.testing.expectEqual(original_flags, pushed_flags);
}

test "raise exception in protected mode with error code" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 64 * 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);
    cpu.mode = .protected;
    cpu.system.cr0.pe = true;
    cpu.regs.esp = 0x1000;
    cpu.eip = 0x500;
    cpu.segments.cs = 0x08;

    // Set up IDT entry for #GP (vector 13)
    // IDT base at 0x2000
    cpu.system.idtr.base = 0x2000;
    cpu.system.idtr.limit = 0xFF;

    // Create interrupt gate descriptor for #GP
    // Offset = 0x00001000, Selector = 0x0008, DPL = 0, Present = 1, Type = 0xE (interrupt gate)
    const gate_offset = @as(u32, 13) * 8;
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 0, 0x00); // Offset low byte
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 1, 0x10); // Offset byte 2
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 2, 0x08); // Selector low
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 3, 0x00); // Selector high
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 4, 0x00); // Reserved
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 5, 0x8E); // P=1, DPL=0, Type=0xE
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 6, 0x00); // Offset byte 3
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 7, 0x00); // Offset high byte

    const original_eip = cpu.eip;
    const original_cs = cpu.segments.cs;
    const original_flags = cpu.flags.toU32();
    const error_code: u32 = 0x1234;

    // Raise #GP with error code
    try cpu.raiseException(.general_protection, error_code);

    // Check that exception was dispatched
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.eip);
    try std.testing.expectEqual(@as(u16, 0x0008), cpu.segments.cs);

    // Check that error code, EIP, CS, and EFLAGS were pushed
    const pushed_error_code = try mem.readDword(cpu.regs.esp);
    const pushed_eip = try mem.readDword(cpu.regs.esp + 4);
    const pushed_cs = try mem.readWord(cpu.regs.esp + 8);
    const pushed_flags = try mem.readDword(cpu.regs.esp + 10);

    try std.testing.expectEqual(error_code, pushed_error_code);
    try std.testing.expectEqual(original_eip, pushed_eip);
    try std.testing.expectEqual(original_cs, pushed_cs);
    try std.testing.expectEqual(original_flags, pushed_flags);
}

test "raise exception without error code in protected mode" {
    const allocator = std.testing.allocator;
    var mem = try memory.Memory.init(allocator, 64 * 1024);
    defer mem.deinit();
    var io_ctrl = io.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);
    cpu.mode = .protected;
    cpu.system.cr0.pe = true;
    cpu.regs.esp = 0x1000;
    cpu.eip = 0x500;
    cpu.segments.cs = 0x08;

    // Set up IDT entry for #UD (vector 6) - no error code
    cpu.system.idtr.base = 0x2000;
    cpu.system.idtr.limit = 0xFF;

    const gate_offset = @as(u32, 6) * 8;
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 0, 0x00);
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 1, 0x10);
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 2, 0x08);
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 3, 0x00);
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 4, 0x00);
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 5, 0x8E);
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 6, 0x00);
    try mem.writeByte(cpu.system.idtr.base + gate_offset + 7, 0x00);

    const original_esp = cpu.regs.esp;

    // Raise #UD (no error code)
    try cpu.raiseException(.invalid_opcode, null);

    // Stack should have EFLAGS(4) + CS(2) + EIP(4) = 10 bytes pushed
    // No error code for #UD
    try std.testing.expectEqual(original_esp - 10, cpu.regs.esp);
}
