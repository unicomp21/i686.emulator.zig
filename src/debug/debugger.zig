//! Debug Interface
//!
//! Provides debugging capabilities for the i686 emulator including
//! breakpoints, single-stepping, and state inspection.

const std = @import("std");
const cpu_mod = @import("../cpu/cpu.zig");
const memory_mod = @import("../memory/memory.zig");

const Cpu = cpu_mod.Cpu;
const CpuState = cpu_mod.CpuState;
const Memory = memory_mod.Memory;

/// Breakpoint type
pub const Breakpoint = struct {
    address: u32,
    enabled: bool,
    hit_count: u32,
};

/// Debug event types
pub const DebugEvent = enum {
    breakpoint_hit,
    single_step,
    exception,
    halt,
};

/// Debugger interface
pub const Debugger = struct {
    breakpoints: std.ArrayList(Breakpoint),
    single_step: bool,
    trace_enabled: bool,
    trace_buffer: std.ArrayList(TraceEntry),
    max_trace_entries: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Trace entry for instruction history
    pub const TraceEntry = struct {
        eip: u32,
        cs: u16,
        opcode: u8,
        state: CpuState,
    };

    /// Initialize debugger
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .breakpoints = std.ArrayList(Breakpoint).init(allocator),
            .single_step = false,
            .trace_enabled = false,
            .trace_buffer = std.ArrayList(TraceEntry).init(allocator),
            .max_trace_entries = 1000,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.breakpoints.deinit();
        self.trace_buffer.deinit();
    }

    /// Add a breakpoint at the specified address
    pub fn addBreakpoint(self: *Self, address: u32) !void {
        // Check if breakpoint already exists
        for (self.breakpoints.items) |*bp| {
            if (bp.address == address) {
                bp.enabled = true;
                return;
            }
        }

        try self.breakpoints.append(Breakpoint{
            .address = address,
            .enabled = true,
            .hit_count = 0,
        });
    }

    /// Remove a breakpoint
    pub fn removeBreakpoint(self: *Self, address: u32) void {
        var i: usize = 0;
        while (i < self.breakpoints.items.len) {
            if (self.breakpoints.items[i].address == address) {
                _ = self.breakpoints.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Enable/disable a breakpoint
    pub fn setBreakpointEnabled(self: *Self, address: u32, enabled: bool) void {
        for (self.breakpoints.items) |*bp| {
            if (bp.address == address) {
                bp.enabled = enabled;
                return;
            }
        }
    }

    /// Check if address has an active breakpoint
    pub fn checkBreakpoint(self: *Self, address: u32) bool {
        for (self.breakpoints.items) |*bp| {
            if (bp.address == address and bp.enabled) {
                bp.hit_count += 1;
                return true;
            }
        }
        return false;
    }

    /// Enable single-step mode
    pub fn enableSingleStep(self: *Self) void {
        self.single_step = true;
    }

    /// Disable single-step mode
    pub fn disableSingleStep(self: *Self) void {
        self.single_step = false;
    }

    /// Enable instruction tracing
    pub fn enableTrace(self: *Self) void {
        self.trace_enabled = true;
    }

    /// Disable instruction tracing
    pub fn disableTrace(self: *Self) void {
        self.trace_enabled = false;
    }

    /// Record a trace entry
    pub fn recordTrace(self: *Self, cpu: *const Cpu, opcode: u8) !void {
        if (!self.trace_enabled) return;

        if (self.trace_buffer.items.len >= self.max_trace_entries) {
            _ = self.trace_buffer.orderedRemove(0);
        }

        try self.trace_buffer.append(TraceEntry{
            .eip = cpu.eip,
            .cs = cpu.segments.cs,
            .opcode = opcode,
            .state = cpu.getState(),
        });
    }

    /// Get trace buffer
    pub fn getTrace(self: *const Self) []const TraceEntry {
        return self.trace_buffer.items;
    }

    /// Clear trace buffer
    pub fn clearTrace(self: *Self) void {
        self.trace_buffer.clearRetainingCapacity();
    }

    /// List all breakpoints
    pub fn listBreakpoints(self: *const Self) []const Breakpoint {
        return self.breakpoints.items;
    }

    /// Disassemble memory at address (simplified)
    pub fn disassemble(mem: *const Memory, address: u32, count: usize, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var addr = address;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const opcode = mem.readByte(addr) catch break;

            // Simple opcode names
            const name = getOpcodeName(opcode);
            try result.writer().print("{x:0>8}: {x:0>2}  {s}\n", .{ addr, opcode, name });

            addr += 1;
        }

        return result.toOwnedSlice();
    }

    /// Get simple opcode name
    fn getOpcodeName(opcode: u8) []const u8 {
        return switch (opcode) {
            0x90 => "NOP",
            0xF4 => "HLT",
            0xB0...0xB7 => "MOV r8, imm8",
            0xB8...0xBF => "MOV r32, imm32",
            0x50...0x57 => "PUSH r32",
            0x58...0x5F => "POP r32",
            0x40...0x47 => "INC r32",
            0x48...0x4F => "DEC r32",
            0xEB => "JMP rel8",
            0xE9 => "JMP rel32",
            0xE8 => "CALL rel32",
            0xC3 => "RET",
            0xCD => "INT imm8",
            0xE4 => "IN AL, imm8",
            0xE6 => "OUT imm8, AL",
            0xEC => "IN AL, DX",
            0xEE => "OUT DX, AL",
            0xFA => "CLI",
            0xFB => "STI",
            0xFC => "CLD",
            0xFD => "STD",
            else => "???",
        };
    }

    /// Format CPU state for display
    pub fn formatCpuState(state: CpuState, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\EAX={x:0>8} EBX={x:0>8} ECX={x:0>8} EDX={x:0>8}
            \\ESI={x:0>8} EDI={x:0>8} EBP={x:0>8} ESP={x:0>8}
            \\EIP={x:0>8} EFLAGS={x:0>8}
            \\CS={x:0>4} DS={x:0>4} ES={x:0>4} SS={x:0>4} FS={x:0>4} GS={x:0>4}
        , .{
            state.eax, state.ebx, state.ecx, state.edx,
            state.esi, state.edi, state.ebp, state.esp,
            state.eip, state.eflags,
            state.cs,  state.ds,  state.es,  state.ss, state.fs, state.gs,
        });
    }
};

// Tests
test "debugger breakpoints" {
    const allocator = std.testing.allocator;
    var dbg = Debugger.init(allocator);
    defer dbg.deinit();

    try dbg.addBreakpoint(0x1000);
    try dbg.addBreakpoint(0x2000);

    try std.testing.expectEqual(@as(usize, 2), dbg.breakpoints.items.len);
    try std.testing.expect(dbg.checkBreakpoint(0x1000));
    try std.testing.expect(!dbg.checkBreakpoint(0x3000));

    dbg.removeBreakpoint(0x1000);
    try std.testing.expectEqual(@as(usize, 1), dbg.breakpoints.items.len);
}

test "debugger single step" {
    const allocator = std.testing.allocator;
    var dbg = Debugger.init(allocator);
    defer dbg.deinit();

    try std.testing.expect(!dbg.single_step);

    dbg.enableSingleStep();
    try std.testing.expect(dbg.single_step);

    dbg.disableSingleStep();
    try std.testing.expect(!dbg.single_step);
}

test "debugger trace" {
    const allocator = std.testing.allocator;
    var dbg = Debugger.init(allocator);
    defer dbg.deinit();

    dbg.enableTrace();
    try std.testing.expect(dbg.trace_enabled);

    dbg.disableTrace();
    try std.testing.expect(!dbg.trace_enabled);
}
