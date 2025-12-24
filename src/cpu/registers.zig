//! i686 Register Definitions
//!
//! Defines CPU registers including general purpose, segment, and flag registers.

const std = @import("std");

/// General purpose registers
pub const Registers = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    esi: u32,
    edi: u32,
    ebp: u32,
    esp: u32,

    const Self = @This();

    /// Initialize registers to zero
    pub fn init() Self {
        return Self{
            .eax = 0,
            .ebx = 0,
            .ecx = 0,
            .edx = 0,
            .esi = 0,
            .edi = 0,
            .ebp = 0,
            .esp = 0,
        };
    }

    /// Get 8-bit register by index (AL, CL, DL, BL, AH, CH, DH, BH)
    pub fn getReg8(self: *const Self, index: u3) u8 {
        return switch (index) {
            0 => @truncate(self.eax), // AL
            1 => @truncate(self.ecx), // CL
            2 => @truncate(self.edx), // DL
            3 => @truncate(self.ebx), // BL
            4 => @truncate(self.eax >> 8), // AH
            5 => @truncate(self.ecx >> 8), // CH
            6 => @truncate(self.edx >> 8), // DH
            7 => @truncate(self.ebx >> 8), // BH
        };
    }

    /// Set 8-bit register by index
    pub fn setReg8(self: *Self, index: u3, value: u8) void {
        switch (index) {
            0 => self.eax = (self.eax & 0xFFFFFF00) | value, // AL
            1 => self.ecx = (self.ecx & 0xFFFFFF00) | value, // CL
            2 => self.edx = (self.edx & 0xFFFFFF00) | value, // DL
            3 => self.ebx = (self.ebx & 0xFFFFFF00) | value, // BL
            4 => self.eax = (self.eax & 0xFFFF00FF) | (@as(u32, value) << 8), // AH
            5 => self.ecx = (self.ecx & 0xFFFF00FF) | (@as(u32, value) << 8), // CH
            6 => self.edx = (self.edx & 0xFFFF00FF) | (@as(u32, value) << 8), // DH
            7 => self.ebx = (self.ebx & 0xFFFF00FF) | (@as(u32, value) << 8), // BH
        }
    }

    /// Get 16-bit register by index (AX, CX, DX, BX, SP, BP, SI, DI)
    pub fn getReg16(self: *const Self, index: u3) u16 {
        return switch (index) {
            0 => @truncate(self.eax),
            1 => @truncate(self.ecx),
            2 => @truncate(self.edx),
            3 => @truncate(self.ebx),
            4 => @truncate(self.esp),
            5 => @truncate(self.ebp),
            6 => @truncate(self.esi),
            7 => @truncate(self.edi),
        };
    }

    /// Set 16-bit register by index
    pub fn setReg16(self: *Self, index: u3, value: u16) void {
        const ptr = switch (index) {
            0 => &self.eax,
            1 => &self.ecx,
            2 => &self.edx,
            3 => &self.ebx,
            4 => &self.esp,
            5 => &self.ebp,
            6 => &self.esi,
            7 => &self.edi,
        };
        ptr.* = (ptr.* & 0xFFFF0000) | value;
    }

    /// Get 32-bit register by index
    pub fn getReg32(self: *const Self, index: u3) u32 {
        return switch (index) {
            0 => self.eax,
            1 => self.ecx,
            2 => self.edx,
            3 => self.ebx,
            4 => self.esp,
            5 => self.ebp,
            6 => self.esi,
            7 => self.edi,
        };
    }

    /// Set 32-bit register by index
    pub fn setReg32(self: *Self, index: u3, value: u32) void {
        switch (index) {
            0 => self.eax = value,
            1 => self.ecx = value,
            2 => self.edx = value,
            3 => self.ebx = value,
            4 => self.esp = value,
            5 => self.ebp = value,
            6 => self.esi = value,
            7 => self.edi = value,
        }
    }
};

/// Segment registers
pub const SegmentRegisters = struct {
    cs: u16, // Code segment
    ds: u16, // Data segment
    es: u16, // Extra segment
    fs: u16, // Additional segment
    gs: u16, // Additional segment
    ss: u16, // Stack segment

    const Self = @This();

    /// Initialize segment registers
    pub fn init() Self {
        return Self{
            .cs = 0,
            .ds = 0,
            .es = 0,
            .fs = 0,
            .gs = 0,
            .ss = 0,
        };
    }

    /// Get segment register by index
    pub fn getSegment(self: *const Self, index: u3) u16 {
        return switch (index) {
            0 => self.es,
            1 => self.cs,
            2 => self.ss,
            3 => self.ds,
            4 => self.fs,
            5 => self.gs,
            else => 0,
        };
    }

    /// Set segment register by index
    pub fn setSegment(self: *Self, index: u3, value: u16) void {
        switch (index) {
            0 => self.es = value,
            1 => self.cs = value,
            2 => self.ss = value,
            3 => self.ds = value,
            4 => self.fs = value,
            5 => self.gs = value,
            else => {},
        }
    }
};

/// EFLAGS register
pub const Flags = struct {
    carry: bool, // CF - bit 0
    parity: bool, // PF - bit 2
    auxiliary: bool, // AF - bit 4
    zero: bool, // ZF - bit 6
    sign: bool, // SF - bit 7
    trap: bool, // TF - bit 8
    interrupt: bool, // IF - bit 9
    direction: bool, // DF - bit 10
    overflow: bool, // OF - bit 11
    iopl: u2, // IOPL - bits 12-13
    nested: bool, // NT - bit 14
    resume_flag: bool, // RF - bit 16
    vm86: bool, // VM - bit 17
    alignment: bool, // AC - bit 18
    vif: bool, // VIF - bit 19
    vip: bool, // VIP - bit 20
    id: bool, // ID - bit 21

    const Self = @This();

    /// Initialize flags (bit 1 is always 1)
    pub fn init() Self {
        return Self{
            .carry = false,
            .parity = false,
            .auxiliary = false,
            .zero = false,
            .sign = false,
            .trap = false,
            .interrupt = false,
            .direction = false,
            .overflow = false,
            .iopl = 0,
            .nested = false,
            .resume_flag = false,
            .vm86 = false,
            .alignment = false,
            .vif = false,
            .vip = false,
            .id = false,
        };
    }

    /// Convert flags to 32-bit EFLAGS value
    pub fn toU32(self: *const Self) u32 {
        var flags: u32 = 0x02; // Bit 1 is always 1
        if (self.carry) flags |= (1 << 0);
        if (self.parity) flags |= (1 << 2);
        if (self.auxiliary) flags |= (1 << 4);
        if (self.zero) flags |= (1 << 6);
        if (self.sign) flags |= (1 << 7);
        if (self.trap) flags |= (1 << 8);
        if (self.interrupt) flags |= (1 << 9);
        if (self.direction) flags |= (1 << 10);
        if (self.overflow) flags |= (1 << 11);
        flags |= (@as(u32, self.iopl) << 12);
        if (self.nested) flags |= (1 << 14);
        if (self.resume_flag) flags |= (1 << 16);
        if (self.vm86) flags |= (1 << 17);
        if (self.alignment) flags |= (1 << 18);
        if (self.vif) flags |= (1 << 19);
        if (self.vip) flags |= (1 << 20);
        if (self.id) flags |= (1 << 21);
        return flags;
    }

    /// Set flags from 32-bit EFLAGS value
    pub fn fromU32(self: *Self, value: u32) void {
        self.carry = (value & (1 << 0)) != 0;
        self.parity = (value & (1 << 2)) != 0;
        self.auxiliary = (value & (1 << 4)) != 0;
        self.zero = (value & (1 << 6)) != 0;
        self.sign = (value & (1 << 7)) != 0;
        self.trap = (value & (1 << 8)) != 0;
        self.interrupt = (value & (1 << 9)) != 0;
        self.direction = (value & (1 << 10)) != 0;
        self.overflow = (value & (1 << 11)) != 0;
        self.iopl = @truncate((value >> 12) & 0x3);
        self.nested = (value & (1 << 14)) != 0;
        self.resume_flag = (value & (1 << 16)) != 0;
        self.vm86 = (value & (1 << 17)) != 0;
        self.alignment = (value & (1 << 18)) != 0;
        self.vif = (value & (1 << 19)) != 0;
        self.vip = (value & (1 << 20)) != 0;
        self.id = (value & (1 << 21)) != 0;
    }

    /// Update flags after arithmetic operation (8-bit)
    pub fn updateArithmetic8(self: *Self, result: u8, carry: bool, overflow: bool) void {
        self.zero = result == 0;
        self.sign = (result & 0x80) != 0;
        self.parity = @popCount(result) & 1 == 0;
        self.carry = carry;
        self.overflow = overflow;
    }

    /// Update flags after arithmetic operation (16-bit)
    pub fn updateArithmetic16(self: *Self, result: u16, carry: bool, overflow: bool) void {
        self.zero = result == 0;
        self.sign = (result & 0x8000) != 0;
        self.parity = @popCount(@as(u8, @truncate(result))) & 1 == 0;
        self.carry = carry;
        self.overflow = overflow;
    }

    /// Update flags after arithmetic operation (32-bit)
    pub fn updateArithmetic32(self: *Self, result: u32, carry: bool, overflow: bool) void {
        self.zero = result == 0;
        self.sign = (result & 0x80000000) != 0;
        self.parity = @popCount(@as(u8, @truncate(result))) & 1 == 0;
        self.carry = carry;
        self.overflow = overflow;
    }
};

// Tests
test "registers 8-bit access" {
    var regs = Registers.init();
    regs.eax = 0x12345678;

    try std.testing.expectEqual(@as(u8, 0x78), regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x56), regs.getReg8(4)); // AH

    regs.setReg8(0, 0xAB); // AL
    try std.testing.expectEqual(@as(u32, 0x123456AB), regs.eax);

    regs.setReg8(4, 0xCD); // AH
    try std.testing.expectEqual(@as(u32, 0x1234CDAB), regs.eax);
}

test "registers 16-bit access" {
    var regs = Registers.init();
    regs.eax = 0x12345678;

    try std.testing.expectEqual(@as(u16, 0x5678), regs.getReg16(0)); // AX

    regs.setReg16(0, 0xABCD); // AX
    try std.testing.expectEqual(@as(u32, 0x1234ABCD), regs.eax);
}

test "flags to/from u32" {
    var flags = Flags.init();
    flags.carry = true;
    flags.zero = true;
    flags.sign = true;

    const value = flags.toU32();
    try std.testing.expect(value & 1 != 0); // CF
    try std.testing.expect(value & (1 << 6) != 0); // ZF
    try std.testing.expect(value & (1 << 7) != 0); // SF

    var flags2 = Flags.init();
    flags2.fromU32(value);
    try std.testing.expect(flags2.carry);
    try std.testing.expect(flags2.zero);
    try std.testing.expect(flags2.sign);
}

test "segment registers" {
    var segs = SegmentRegisters.init();
    segs.setSegment(1, 0x0800); // CS
    segs.setSegment(3, 0x1000); // DS

    try std.testing.expectEqual(@as(u16, 0x0800), segs.getSegment(1));
    try std.testing.expectEqual(@as(u16, 0x1000), segs.getSegment(3));
}
