//! Kernel Boot Loader
//!
//! Implements Linux kernel direct boot protocol for loading and booting
//! bzImage kernels in the emulator. Supports both real-mode and protected-mode entry.
//!
//! Memory layout:
//! 0x00000 - 0x00FFF: Real-mode IVT (Interrupt Vector Table)
//! 0x10000 - 0x1FFFF: Boot parameters (zero page) - kernel setup header
//! 0x20000 - 0x2FFFF: Command line string
//! 0x90000 - 0x9FFFF: Real-mode kernel setup code (optional, for old kernels)
//! 0x100000+        : Protected-mode kernel image (bzImage payload)
//!
//! References:
//! - Linux Documentation/x86/boot.txt
//! - https://www.kernel.org/doc/html/latest/x86/boot.html

const std = @import("std");
const Emulator = @import("../root.zig").Emulator;
const Cpu = @import("../cpu/cpu.zig").Cpu;

/// Boot protocol magic numbers
pub const BOOT_SECTOR_MAGIC = 0xAA55;
pub const HDRS_MAGIC = 0x53726448; // "HdrS"

/// Boot protocol version (minimum supported: 2.00)
pub const MIN_BOOT_PROTOCOL = 0x0200;

/// Memory addresses for boot components
pub const BOOT_PARAMS_ADDR = 0x10000; // Zero page / boot parameters
pub const CMDLINE_ADDR = 0x20000; // Command line buffer
pub const REAL_MODE_KERNEL_ADDR = 0x90000; // Real-mode setup code (legacy)
pub const PROTECTED_MODE_KERNEL_ADDR = 0x100000; // 1 MB - protected mode kernel

/// Boot parameter offsets (from Linux boot.h)
pub const Offsets = struct {
    pub const SETUP_SECTS = 0x1F1; // Size of setup in 512-byte sectors
    pub const ROOT_FLAGS = 0x1F2;
    pub const SYSSIZE = 0x1F4; // Size of protected-mode code in 16-byte paragraphs
    pub const RAM_SIZE = 0x1F8;
    pub const VID_MODE = 0x1FA;
    pub const ROOT_DEV = 0x1FC;
    pub const BOOT_FLAG = 0x1FE; // 0xAA55
    pub const JUMP = 0x200; // Jump instruction
    pub const HEADER = 0x202; // "HdrS" magic
    pub const VERSION = 0x206; // Boot protocol version
    pub const REALMODE_SWTCH = 0x208;
    pub const START_SYS_SEG = 0x20C;
    pub const KERNEL_VERSION = 0x20E; // Pointer to kernel version string
    pub const TYPE_OF_LOADER = 0x210;
    pub const LOADFLAGS = 0x211;
    pub const SETUP_MOVE_SIZE = 0x212;
    pub const CODE32_START = 0x214; // Protected-mode entry point
    pub const RAMDISK_IMAGE = 0x218; // initrd address
    pub const RAMDISK_SIZE = 0x21C; // initrd size
    pub const BOOTSECT_KLUDGE = 0x220;
    pub const HEAP_END_PTR = 0x224;
    pub const EXT_LOADER_VER = 0x226;
    pub const EXT_LOADER_TYPE = 0x227;
    pub const CMD_LINE_PTR = 0x228; // 32-bit pointer to command line
    pub const INITRD_ADDR_MAX = 0x22C;
    pub const KERNEL_ALIGNMENT = 0x230;
    pub const RELOCATABLE_KERNEL = 0x234;
    pub const MIN_ALIGNMENT = 0x235;
    pub const XLOADFLAGS = 0x236;
    pub const CMDLINE_SIZE = 0x238;
    pub const HARDWARE_SUBARCH = 0x23C;
    pub const HARDWARE_SUBARCH_DATA = 0x240;
    pub const PAYLOAD_OFFSET = 0x248;
    pub const PAYLOAD_LENGTH = 0x24C;
};

/// Load flags bits
pub const LoadFlags = struct {
    pub const LOADED_HIGH: u8 = 1 << 0; // Protected-mode code loaded at 0x100000
    pub const KASLR_FLAG: u8 = 1 << 1; // KASLR enabled
    pub const QUIET_FLAG: u8 = 1 << 5; // Quiet boot (suppress output)
    pub const KEEP_SEGMENTS: u8 = 1 << 6; // Don't reload segment registers
    pub const CAN_USE_HEAP: u8 = 1 << 7; // Heap is available
};

/// Type of bootloader (we use 0xFF for "unknown/unregistered")
pub const LOADER_TYPE_UNDEFINED = 0xFF;

/// Direct boot configuration
pub const DirectBoot = struct {
    kernel_data: []const u8,
    cmdline: []const u8,
    initrd_data: ?[]const u8,
    allocator: std.mem.Allocator,

    /// Setup header information
    setup_sects: u8,
    protocol_version: u16,
    code32_start: u32,
    loadflags: u8,

    const Self = @This();

    /// Initialize direct boot from kernel file path
    pub fn init(allocator: std.mem.Allocator, kernel_path: []const u8, cmdline: []const u8) !Self {
        // Read kernel file
        const kernel_file = try std.fs.cwd().openFile(kernel_path, .{});
        defer kernel_file.close();

        const kernel_data = try kernel_file.readToEndAlloc(allocator, 100 * 1024 * 1024); // Max 100MB
        errdefer allocator.free(kernel_data);

        // Duplicate command line
        const cmdline_copy = try allocator.dupe(u8, cmdline);
        errdefer allocator.free(cmdline_copy);

        var boot = Self{
            .kernel_data = kernel_data,
            .cmdline = cmdline_copy,
            .initrd_data = null,
            .allocator = allocator,
            .setup_sects = 0,
            .protocol_version = 0,
            .code32_start = PROTECTED_MODE_KERNEL_ADDR,
            .loadflags = 0,
        };

        // Parse boot header
        try boot.parseBootHeader();

        return boot;
    }

    /// Initialize from in-memory kernel data
    pub fn initFromMemory(allocator: std.mem.Allocator, kernel_data: []const u8, cmdline: []const u8) !Self {
        const kernel_copy = try allocator.dupe(u8, kernel_data);
        errdefer allocator.free(kernel_copy);

        const cmdline_copy = try allocator.dupe(u8, cmdline);
        errdefer allocator.free(cmdline_copy);

        var boot = Self{
            .kernel_data = kernel_copy,
            .cmdline = cmdline_copy,
            .initrd_data = null,
            .allocator = allocator,
            .setup_sects = 0,
            .protocol_version = 0,
            .code32_start = PROTECTED_MODE_KERNEL_ADDR,
            .loadflags = 0,
        };

        try boot.parseBootHeader();

        return boot;
    }

    /// Set initrd/initramfs image from file path
    pub fn setInitrd(self: *Self, initrd_path: []const u8) !void {
        const initrd_file = try std.fs.cwd().openFile(initrd_path, .{});
        defer initrd_file.close();

        const initrd_data = try initrd_file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);

        if (self.initrd_data) |old_data| {
            self.allocator.free(old_data);
        }
        self.initrd_data = initrd_data;
    }

    /// Set initrd/initramfs image from memory (caller retains ownership)
    pub fn setInitrdFromMemory(self: *Self, data: []const u8) !void {
        // Make a copy since DirectBoot owns the initrd data
        const initrd_copy = try self.allocator.dupe(u8, data);

        if (self.initrd_data) |old_data| {
            self.allocator.free(old_data);
        }
        self.initrd_data = initrd_copy;
    }

    /// Parse boot header from kernel image
    fn parseBootHeader(self: *Self) !void {
        if (self.kernel_data.len < 0x400) {
            return error.InvalidKernel;
        }

        // Check boot sector magic (0xAA55 at offset 0x1FE)
        const boot_flag = std.mem.readInt(u16, self.kernel_data[Offsets.BOOT_FLAG..][0..2], .little);
        if (boot_flag != BOOT_SECTOR_MAGIC) {
            return error.InvalidBootSector;
        }

        // Check header magic "HdrS" (0x53726448)
        const header_magic = std.mem.readInt(u32, self.kernel_data[Offsets.HEADER..][0..4], .little);
        if (header_magic != HDRS_MAGIC) {
            return error.InvalidBootHeader;
        }

        // Read setup sectors count (defaults to 4 if 0)
        self.setup_sects = self.kernel_data[Offsets.SETUP_SECTS];
        if (self.setup_sects == 0) {
            self.setup_sects = 4;
        }

        // Read protocol version
        self.protocol_version = std.mem.readInt(u16, self.kernel_data[Offsets.VERSION..][0..2], .little);
        if (self.protocol_version < MIN_BOOT_PROTOCOL) {
            return error.UnsupportedBootProtocol;
        }

        // Read loadflags
        self.loadflags = self.kernel_data[Offsets.LOADFLAGS];

        // Read code32_start (protected-mode entry point)
        self.code32_start = std.mem.readInt(u32, self.kernel_data[Offsets.CODE32_START..][0..4], .little);

        // If code32_start is 0, use default
        if (self.code32_start == 0) {
            self.code32_start = PROTECTED_MODE_KERNEL_ADDR;
        }
    }

    /// Load kernel into emulator memory and setup boot parameters
    pub fn load(self: *Self, emulator: *Emulator) !void {
        // Calculate offsets in kernel image
        const setup_size = (@as(usize, self.setup_sects) + 1) * 512; // +1 for boot sector
        const kernel_start = setup_size;

        if (self.kernel_data.len < kernel_start) {
            return error.InvalidKernel;
        }

        // 1. Clear boot parameter area (zero page)
        try emulator.mem.fill(BOOT_PARAMS_ADDR, 0x1000, 0);

        // 2. Copy setup header to boot parameters
        // Copy the first 512 bytes of setup (boot sector + header)
        const header_size = @min(0x400, self.kernel_data.len);
        try emulator.mem.writeBytes(BOOT_PARAMS_ADDR, self.kernel_data[0..header_size]);

        // 3. Load protected-mode kernel at 1MB
        const kernel_payload = self.kernel_data[kernel_start..];
        try emulator.mem.writeBytes(PROTECTED_MODE_KERNEL_ADDR, kernel_payload);

        // 4. Copy command line to buffer
        if (self.cmdline.len > 0) {
            const max_cmdline = @min(self.cmdline.len, 0xFF); // Limit to 255 bytes for safety
            try emulator.mem.writeBytes(CMDLINE_ADDR, self.cmdline[0..max_cmdline]);
            // Null-terminate
            try emulator.mem.writeByte(CMDLINE_ADDR + @as(u32, @intCast(max_cmdline)), 0);

            // Set command line pointer in boot params
            try emulator.mem.writeDword(BOOT_PARAMS_ADDR + Offsets.CMD_LINE_PTR, CMDLINE_ADDR);
        }

        // 5. Load initrd if present
        if (self.initrd_data) |initrd| {
            // Load initrd at end of conventional memory (below kernel)
            // For safety, place it at a fixed location: 0x7F00000 (127 MB)
            const initrd_addr: u32 = 0x7F00000;
            try emulator.mem.writeBytes(initrd_addr, initrd);

            // Set initrd address and size in boot params
            try emulator.mem.writeDword(BOOT_PARAMS_ADDR + Offsets.RAMDISK_IMAGE, initrd_addr);
            try emulator.mem.writeDword(BOOT_PARAMS_ADDR + Offsets.RAMDISK_SIZE, @intCast(initrd.len));
        }

        // 6. Set boot parameters
        try self.setupBootParams(emulator);

        // 7. Setup CPU state for boot
        try setupCpuForBoot(&emulator.cpu_instance, BOOT_PARAMS_ADDR, self.code32_start, self.loadflags);
    }

    /// Setup boot parameters structure
    fn setupBootParams(self: *Self, emulator: *Emulator) !void {
        const base = BOOT_PARAMS_ADDR;

        // Type of loader (0xFF = undefined)
        try emulator.mem.writeByte(base + Offsets.TYPE_OF_LOADER, LOADER_TYPE_UNDEFINED);

        // Loadflags - set LOADED_HIGH since we load at 1MB
        var loadflags = self.loadflags;
        loadflags |= LoadFlags.LOADED_HIGH;
        loadflags |= LoadFlags.CAN_USE_HEAP; // Enable heap
        try emulator.mem.writeByte(base + Offsets.LOADFLAGS, loadflags);

        // Heap end pointer (relative to 0x10000)
        try emulator.mem.writeWord(base + Offsets.HEAP_END_PTR, 0xDE00);

        // Video mode (0xFFFF = normal)
        try emulator.mem.writeWord(base + Offsets.VID_MODE, 0xFFFF);

        // Code32 start address (protected-mode entry)
        try emulator.mem.writeDword(base + Offsets.CODE32_START, self.code32_start);

        // E820 memory map would go here in a real implementation
        // For now, we'll leave it empty and the kernel will probe
    }

    /// Free resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.kernel_data);
        self.allocator.free(self.cmdline);
        if (self.initrd_data) |initrd| {
            self.allocator.free(initrd);
        }
    }
};

/// Setup CPU state for kernel boot entry
pub fn setupCpuForBoot(cpu: *Cpu, boot_params_addr: u32, entry_point: u32, loadflags: u8) !void {
    // Check if we should enter in protected mode or real mode
    const loaded_high = (loadflags & LoadFlags.LOADED_HIGH) != 0;

    if (loaded_high) {
        // Enter directly in 32-bit protected mode
        // This is the modern path for bzImage kernels

        // Setup GDT for protected mode
        try setupMinimalGDT(cpu);

        // Enable protected mode
        cpu.mode = .protected;
        cpu.system.cr0.pe = true;

        // Set segment selectors to flat segments (index 1 = code, index 2 = data)
        cpu.segments.cs = 0x08; // GDT entry 1 (code)
        cpu.segments.ds = 0x10; // GDT entry 2 (data)
        cpu.segments.es = 0x10;
        cpu.segments.fs = 0x10;
        cpu.segments.gs = 0x10;
        cpu.segments.ss = 0x10;

        // Load segment descriptors into cache
        try cpu.loadSegmentDescriptor(cpu.segments.cs, 1);
        try cpu.loadSegmentDescriptor(cpu.segments.ds, 3);

        // Set registers according to 32-bit boot protocol:
        // ESI = boot_params (pointer to zero page)
        cpu.regs.esi = boot_params_addr;

        // Clear other registers
        cpu.regs.eax = 0;
        cpu.regs.ebx = 0;
        cpu.regs.ecx = 0;
        cpu.regs.edx = 0;
        cpu.regs.edi = 0;
        cpu.regs.ebp = 0;

        // Setup stack below boot params
        cpu.regs.esp = boot_params_addr - 0x1000; // Stack grows down from just below boot params

        // Jump to protected-mode kernel entry
        cpu.eip = entry_point;

        // Clear interrupts
        cpu.flags.interrupt = false;
        cpu.flags.direction = false;
    } else {
        // Enter in real mode (legacy path)
        // Setup would jump to real-mode code at 0x90000

        cpu.mode = .real;
        cpu.system.cr0.pe = false;

        // Setup segments for real mode
        // DS:SI should point to boot params
        const segment = @as(u16, @truncate(boot_params_addr >> 4));
        const offset = @as(u16, @truncate(boot_params_addr & 0x0F));

        cpu.segments.ds = segment;
        cpu.segments.es = segment;
        cpu.segments.fs = 0;
        cpu.segments.gs = 0;
        cpu.segments.ss = segment;
        cpu.segments.cs = @truncate(REAL_MODE_KERNEL_ADDR >> 4);

        cpu.regs.esi = offset;
        cpu.regs.esp = 0xFFF0; // Top of 64KB segment

        // Jump to real-mode setup code
        cpu.eip = 0x0000; // Offset within segment

        cpu.flags.interrupt = false;
        cpu.flags.direction = false;
    }
}

/// Setup minimal GDT for protected mode boot
/// Creates a flat memory model with code and data segments covering 4GB
fn setupMinimalGDT(cpu: *Cpu) !void {
    // GDT location: just above boot params at 0x1F000
    const gdt_addr: u32 = 0x1F000;
    const gdt_size: u16 = 8 * 4 - 1; // 4 entries (null, code, data, data) - 1

    // Entry 0: Null descriptor
    try cpu.mem.writeDword(gdt_addr + 0, 0);
    try cpu.mem.writeDword(gdt_addr + 4, 0);

    // Entry 1: Code segment (0x08) - base=0, limit=0xFFFFF, 32-bit, executable, readable
    // Limit 15:0 = 0xFFFF, Base 15:0 = 0x0000
    try cpu.mem.writeWord(gdt_addr + 8, 0xFFFF);
    try cpu.mem.writeWord(gdt_addr + 10, 0x0000);
    // Base 23:16 = 0x00, Access = 0x9A (present, ring 0, code, executable, readable)
    try cpu.mem.writeByte(gdt_addr + 12, 0x00);
    try cpu.mem.writeByte(gdt_addr + 13, 0x9A);
    // Flags + Limit 19:16 = 0xCF (4KB granularity, 32-bit, limit=0xF)
    try cpu.mem.writeByte(gdt_addr + 14, 0xCF);
    // Base 31:24 = 0x00
    try cpu.mem.writeByte(gdt_addr + 15, 0x00);

    // Entry 2: Data segment (0x10) - base=0, limit=0xFFFFF, 32-bit, writable
    try cpu.mem.writeWord(gdt_addr + 16, 0xFFFF);
    try cpu.mem.writeWord(gdt_addr + 18, 0x0000);
    try cpu.mem.writeByte(gdt_addr + 20, 0x00);
    try cpu.mem.writeByte(gdt_addr + 21, 0x92); // present, ring 0, data, writable
    try cpu.mem.writeByte(gdt_addr + 22, 0xCF);
    try cpu.mem.writeByte(gdt_addr + 23, 0x00);

    // Entry 3: Data segment (0x18) - duplicate for safety
    try cpu.mem.writeWord(gdt_addr + 24, 0xFFFF);
    try cpu.mem.writeWord(gdt_addr + 26, 0x0000);
    try cpu.mem.writeByte(gdt_addr + 28, 0x00);
    try cpu.mem.writeByte(gdt_addr + 29, 0x92);
    try cpu.mem.writeByte(gdt_addr + 30, 0xCF);
    try cpu.mem.writeByte(gdt_addr + 31, 0x00);

    // Load GDTR
    cpu.system.gdtr.base = gdt_addr;
    cpu.system.gdtr.limit = gdt_size;
}

/// Load kernel into emulator (helper function)
pub fn loadKernel(emulator: *Emulator, kernel_data: []const u8) !void {
    var boot = try DirectBoot.initFromMemory(emulator.allocator, kernel_data, "");
    defer boot.deinit();

    try boot.load(emulator);
}

// Tests
test "boot header parsing" {
    const allocator = std.testing.allocator;

    // Create a minimal valid kernel header
    var kernel_data = try allocator.alloc(u8, 0x400);
    defer allocator.free(kernel_data);
    @memset(kernel_data, 0);

    // Boot sector magic at 0x1FE
    kernel_data[Offsets.BOOT_FLAG] = 0x55;
    kernel_data[Offsets.BOOT_FLAG + 1] = 0xAA;

    // Header magic "HdrS" at 0x202
    kernel_data[Offsets.HEADER] = 0x48; // 'H'
    kernel_data[Offsets.HEADER + 1] = 0x64; // 'd'
    kernel_data[Offsets.HEADER + 2] = 0x72; // 'r'
    kernel_data[Offsets.HEADER + 3] = 0x53; // 'S'

    // Protocol version 2.00 at 0x206
    kernel_data[Offsets.VERSION] = 0x00;
    kernel_data[Offsets.VERSION + 1] = 0x02;

    // Setup sectors
    kernel_data[Offsets.SETUP_SECTS] = 4;

    // Loadflags
    kernel_data[Offsets.LOADFLAGS] = LoadFlags.LOADED_HIGH;

    // Code32 start
    kernel_data[Offsets.CODE32_START] = 0x00;
    kernel_data[Offsets.CODE32_START + 1] = 0x00;
    kernel_data[Offsets.CODE32_START + 2] = 0x10;
    kernel_data[Offsets.CODE32_START + 3] = 0x00;

    var boot = try DirectBoot.initFromMemory(allocator, kernel_data, "console=ttyS0");
    defer boot.deinit();

    try std.testing.expectEqual(@as(u8, 4), boot.setup_sects);
    try std.testing.expectEqual(@as(u16, 0x0200), boot.protocol_version);
    try std.testing.expectEqual(@as(u32, 0x100000), boot.code32_start);
    try std.testing.expectEqual(LoadFlags.LOADED_HIGH, boot.loadflags);
}

test "minimal GDT setup" {
    const Memory = @import("../memory/memory.zig").Memory;
    const IoController = @import("../io/io.zig").IoController;

    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024 * 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);

    try setupMinimalGDT(&cpu);

    // Check GDTR
    try std.testing.expectEqual(@as(u32, 0x1F000), cpu.system.gdtr.base);
    try std.testing.expectEqual(@as(u16, 31), cpu.system.gdtr.limit);

    // Check null descriptor
    const null_desc = try mem.readDword(0x1F000);
    try std.testing.expectEqual(@as(u32, 0), null_desc);

    // Check code segment descriptor
    const code_access = try mem.readByte(0x1F000 + 8 + 5);
    try std.testing.expectEqual(@as(u8, 0x9A), code_access);
}

test "CPU setup for protected mode boot" {
    const Memory = @import("../memory/memory.zig").Memory;
    const IoController = @import("../io/io.zig").IoController;

    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 16 * 1024 * 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = Cpu.init(&mem, &io_ctrl);

    try setupCpuForBoot(&cpu, BOOT_PARAMS_ADDR, PROTECTED_MODE_KERNEL_ADDR, LoadFlags.LOADED_HIGH);

    // Check protected mode enabled
    try std.testing.expectEqual(Cpu.CpuMode.protected, cpu.mode);
    try std.testing.expect(cpu.system.cr0.pe);

    // Check segment selectors
    try std.testing.expectEqual(@as(u16, 0x08), cpu.segments.cs);
    try std.testing.expectEqual(@as(u16, 0x10), cpu.segments.ds);

    // Check ESI points to boot params
    try std.testing.expectEqual(BOOT_PARAMS_ADDR, cpu.regs.esi);

    // Check EIP at kernel entry
    try std.testing.expectEqual(PROTECTED_MODE_KERNEL_ADDR, cpu.eip);
}
