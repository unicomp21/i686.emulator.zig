//! Protected Mode Support
//!
//! Implements GDT, IDT, segment descriptors, and control registers
//! required for i686 protected mode operation.

const std = @import("std");

/// Descriptor Table Register (GDTR/IDTR format)
pub const DescriptorTableRegister = struct {
    limit: u16,
    base: u32,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .limit = 0,
            .base = 0,
        };
    }
};

/// Segment Descriptor (8 bytes in GDT/LDT)
pub const SegmentDescriptor = struct {
    /// Segment base address (24 bits from bytes 2-4, 8 bits from byte 7)
    base: u32,
    /// Segment limit (16 bits from bytes 0-1, 4 bits from byte 6)
    limit: u20,
    /// Access byte
    access: AccessByte,
    /// Flags (4 bits from byte 6)
    flags: DescriptorFlags,

    const Self = @This();

    pub const AccessByte = packed struct {
        /// Accessed bit
        accessed: bool = false,
        /// Readable (code) / Writable (data)
        rw: bool = false,
        /// Direction/Conforming
        dc: bool = false,
        /// Executable (1 = code, 0 = data)
        executable: bool = false,
        /// Descriptor type (1 = code/data, 0 = system)
        descriptor_type: bool = true,
        /// Privilege level (0 = kernel, 3 = user)
        dpl: u2 = 0,
        /// Present bit
        present: bool = false,
    };

    pub const DescriptorFlags = packed struct {
        /// Reserved (always 0)
        reserved: u1 = 0,
        /// Long mode (64-bit)
        long_mode: bool = false,
        /// Size (0 = 16-bit, 1 = 32-bit)
        size: bool = false,
        /// Granularity (0 = byte, 1 = 4KB pages)
        granularity: bool = false,
    };

    /// Parse descriptor from 8 bytes
    pub fn fromBytes(bytes: [8]u8) Self {
        const limit_low: u16 = @as(u16, bytes[1]) << 8 | bytes[0];
        const limit_high: u4 = @truncate(bytes[6] & 0x0F);
        const limit: u20 = @as(u20, limit_high) << 16 | limit_low;

        const base_low: u16 = @as(u16, bytes[3]) << 8 | bytes[2];
        const base_mid: u8 = bytes[4];
        const base_high: u8 = bytes[7];
        const base: u32 = @as(u32, base_high) << 24 | @as(u32, base_mid) << 16 | base_low;

        return Self{
            .base = base,
            .limit = limit,
            .access = @bitCast(bytes[5]),
            .flags = @bitCast(@as(u4, @truncate(bytes[6] >> 4))),
        };
    }

    /// Get effective limit (considering granularity)
    pub fn getEffectiveLimit(self: Self) u32 {
        if (self.flags.granularity) {
            // 4KB granularity: limit * 4096 + 0xFFF
            return (@as(u32, self.limit) << 12) | 0xFFF;
        } else {
            return self.limit;
        }
    }

    /// Check if segment is present
    pub fn isPresent(self: Self) bool {
        return self.access.present;
    }

    /// Check if segment is a code segment
    pub fn isCode(self: Self) bool {
        return self.access.descriptor_type and self.access.executable;
    }

    /// Check if segment is a data segment
    pub fn isData(self: Self) bool {
        return self.access.descriptor_type and !self.access.executable;
    }

    /// Check if segment is readable (for code segments)
    pub fn isReadable(self: Self) bool {
        if (self.isCode()) {
            return self.access.rw; // For code, rw = readable
        }
        return true; // Data segments are always readable
    }

    /// Check if segment is writable (for data segments)
    pub fn isWritable(self: Self) bool {
        if (self.isData()) {
            return self.access.rw; // For data, rw = writable
        }
        return false; // Code segments are never writable
    }

    /// Null descriptor check
    pub fn isNull(self: Self) bool {
        return self.base == 0 and self.limit == 0 and
            @as(u8, @bitCast(self.access)) == 0 and
            @as(u4, @bitCast(self.flags)) == 0;
    }
};

/// Gate Descriptor (for IDT)
pub const GateDescriptor = struct {
    /// Offset to handler (low 16 bits)
    offset_low: u16,
    /// Segment selector
    selector: u16,
    /// Reserved (always 0 for interrupt/trap gates)
    reserved: u8,
    /// Type and attributes
    type_attr: TypeAttr,
    /// Offset to handler (high 16 bits)
    offset_high: u16,

    const Self = @This();

    pub const TypeAttr = packed struct {
        /// Gate type (0xE = 32-bit interrupt, 0xF = 32-bit trap)
        gate_type: u4 = 0,
        /// Storage segment (0 for interrupt/trap gates)
        storage: bool = false,
        /// Descriptor privilege level
        dpl: u2 = 0,
        /// Present bit
        present: bool = false,
    };

    /// Parse gate from 8 bytes
    pub fn fromBytes(bytes: [8]u8) Self {
        return Self{
            .offset_low = @as(u16, bytes[1]) << 8 | bytes[0],
            .selector = @as(u16, bytes[3]) << 8 | bytes[2],
            .reserved = bytes[4],
            .type_attr = @bitCast(bytes[5]),
            .offset_high = @as(u16, bytes[7]) << 8 | bytes[6],
        };
    }

    /// Get full 32-bit offset
    pub fn getOffset(self: Self) u32 {
        return @as(u32, self.offset_high) << 16 | self.offset_low;
    }

    /// Check if gate is present
    pub fn isPresent(self: Self) bool {
        return self.type_attr.present;
    }

    /// Check if this is an interrupt gate (clears IF)
    pub fn isInterruptGate(self: Self) bool {
        return self.type_attr.gate_type == 0xE;
    }

    /// Check if this is a trap gate (doesn't clear IF)
    pub fn isTrapGate(self: Self) bool {
        return self.type_attr.gate_type == 0xF;
    }
};

/// Control Register 0
pub const CR0 = packed struct {
    /// Protection Enable
    pe: bool = false,
    /// Monitor Coprocessor
    mp: bool = false,
    /// Emulation
    em: bool = false,
    /// Task Switched
    ts: bool = false,
    /// Extension Type
    et: bool = true, // Always 1 on i686
    /// Numeric Error
    ne: bool = false,
    /// Reserved (bits 6-15)
    reserved1: u10 = 0,
    /// Write Protect
    wp: bool = false,
    /// Reserved (bit 17)
    reserved2: u1 = 0,
    /// Alignment Mask
    am: bool = false,
    /// Reserved (bits 19-28)
    reserved3: u10 = 0,
    /// Not Write-through
    nw: bool = false,
    /// Cache Disable
    cd: bool = false,
    /// Paging
    pg: bool = false,

    const Self = @This();

    pub fn toU32(self: Self) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(value: u32) Self {
        return @bitCast(value);
    }
};

/// Control Register 3 (Page Directory Base Register)
pub const CR3 = packed struct {
    /// Reserved (bits 0-2)
    reserved1: u3 = 0,
    /// Page-level Write-Through
    pwt: bool = false,
    /// Page-level Cache Disable
    pcd: bool = false,
    /// Reserved (bits 5-11)
    reserved2: u7 = 0,
    /// Page Directory Base (4KB aligned)
    pdb: u20 = 0,

    const Self = @This();

    pub fn toU32(self: Self) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(value: u32) Self {
        return @bitCast(value);
    }

    pub fn getPageDirectoryBase(self: Self) u32 {
        return @as(u32, self.pdb) << 12;
    }
};

/// Control Register 4
pub const CR4 = packed struct {
    /// Virtual-8086 Mode Extensions
    vme: bool = false,
    /// Protected-Mode Virtual Interrupts
    pvi: bool = false,
    /// Time Stamp Disable
    tsd: bool = false,
    /// Debugging Extensions
    de: bool = false,
    /// Page Size Extensions
    pse: bool = false,
    /// Physical Address Extension
    pae: bool = false,
    /// Machine-Check Enable
    mce: bool = false,
    /// Page Global Enable
    pge: bool = false,
    /// Performance-Monitoring Counter Enable
    pce: bool = false,
    /// OS Support for FXSAVE/FXRSTOR
    osfxsr: bool = false,
    /// OS Support for Unmasked SIMD Floating-Point Exceptions
    osxmmexcpt: bool = false,
    /// Reserved (bits 11-31)
    reserved: u21 = 0,

    const Self = @This();

    pub fn toU32(self: Self) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(value: u32) Self {
        return @bitCast(value);
    }
};

/// System Registers for protected mode
pub const SystemRegisters = struct {
    /// Global Descriptor Table Register
    gdtr: DescriptorTableRegister,
    /// Interrupt Descriptor Table Register
    idtr: DescriptorTableRegister,
    /// Local Descriptor Table Register (selector)
    ldtr: u16,
    /// Task Register (selector)
    tr: u16,
    /// Control Register 0
    cr0: CR0,
    /// Control Register 2 (Page Fault Linear Address)
    cr2: u32,
    /// Control Register 3 (Page Directory Base)
    cr3: CR3,
    /// Control Register 4
    cr4: CR4,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .gdtr = DescriptorTableRegister.init(),
            .idtr = DescriptorTableRegister.init(),
            .ldtr = 0,
            .tr = 0,
            .cr0 = .{},
            .cr2 = 0,
            .cr3 = .{},
            .cr4 = .{},
        };
    }

    /// Check if protected mode is enabled
    pub fn isProtectedMode(self: *const Self) bool {
        return self.cr0.pe;
    }

    /// Check if paging is enabled
    pub fn isPagingEnabled(self: *const Self) bool {
        return self.cr0.pg;
    }
};

// Tests
test "segment descriptor parsing" {
    // Null descriptor
    const null_desc = SegmentDescriptor.fromBytes([8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expect(null_desc.isNull());

    // Kernel code segment: base=0, limit=0xFFFFF, 32-bit, 4KB granularity
    // Bytes: limit_low=0xFFFF, base_low=0x0000, base_mid=0x00,
    //        access=0x9A (present, ring 0, code, readable),
    //        flags|limit_high=0xCF (granularity, 32-bit, limit_high=F),
    //        base_high=0x00
    const code_desc = SegmentDescriptor.fromBytes([8]u8{ 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xCF, 0x00 });
    try std.testing.expectEqual(@as(u32, 0), code_desc.base);
    try std.testing.expectEqual(@as(u20, 0xFFFFF), code_desc.limit);
    try std.testing.expect(code_desc.isPresent());
    try std.testing.expect(code_desc.isCode());
    try std.testing.expect(code_desc.flags.granularity);
    try std.testing.expect(code_desc.flags.size);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), code_desc.getEffectiveLimit());

    // Kernel data segment: base=0, limit=0xFFFFF, 32-bit, 4KB granularity
    const data_desc = SegmentDescriptor.fromBytes([8]u8{ 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00 });
    try std.testing.expect(data_desc.isPresent());
    try std.testing.expect(data_desc.isData());
    try std.testing.expect(data_desc.isWritable());
}

test "gate descriptor parsing" {
    // Interrupt gate: offset=0x00101000, selector=0x0008, DPL=0, present
    const gate = GateDescriptor.fromBytes([8]u8{ 0x00, 0x10, 0x08, 0x00, 0x00, 0x8E, 0x10, 0x00 });
    try std.testing.expectEqual(@as(u32, 0x00101000), gate.getOffset());
    try std.testing.expectEqual(@as(u16, 0x0008), gate.selector);
    try std.testing.expect(gate.isPresent());
    try std.testing.expect(gate.isInterruptGate());
}

test "cr0 register" {
    var cr0 = CR0{};
    try std.testing.expect(!cr0.pe);
    try std.testing.expect(!cr0.pg);

    cr0.pe = true;
    const value = cr0.toU32();
    try std.testing.expect(value & 1 != 0);

    const cr0_2 = CR0.fromU32(0x80000001);
    try std.testing.expect(cr0_2.pe);
    try std.testing.expect(cr0_2.pg);
}

test "system registers init" {
    const sys = SystemRegisters.init();
    try std.testing.expect(!sys.isProtectedMode());
    try std.testing.expect(!sys.isPagingEnabled());
}
