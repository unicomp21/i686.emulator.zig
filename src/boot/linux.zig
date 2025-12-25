//! Linux boot protocol parser for bzImage direct boot
//!
//! This module parses the Linux x86 boot protocol header found at offset 0x1F1
//! in bzImage files. It supports boot protocol version 2.00 and later.
//!
//! Reference: Documentation/x86/boot.txt in the Linux kernel source tree

const std = @import("std");
const Memory = @import("../memory/memory.zig").Memory;
const Allocator = std.mem.Allocator;

/// E820 memory map entry types
pub const E820Type = enum(u32) {
    ram = 1,
    reserved = 2,
    acpi = 3,
    nvs = 4,
    unusable = 5,
};

/// E820 memory map entry (BIOS memory map)
pub const E820Entry = extern struct {
    addr: u64,
    size: u64,
    type: u32,

    /// Create a new E820 entry
    pub fn init(addr: u64, size: u64, entry_type: E820Type) E820Entry {
        return E820Entry{
            .addr = addr,
            .size = size,
            .type = @intFromEnum(entry_type),
        };
    }
};

/// Linux boot protocol setup header (at offset 0x1F1 in bzImage)
/// All multi-byte fields are little-endian
pub const SetupHeader = extern struct {
    setup_sects: u8, // 0x1F1: Number of setup sectors (512 bytes each)
    root_flags: u16, // 0x1F2: Root filesystem flags (obsolete)
    syssize: u32, // 0x1F4: Size of protected-mode code in 16-byte paragraphs
    ram_size: u16, // 0x1F8: DO NOT USE (obsolete)
    vid_mode: u16, // 0x1FA: Video mode control
    root_dev: u16, // 0x1FC: Default root device number
    boot_flag: u16, // 0x1FE: Boot signature (0xAA55)
    jump: u16, // 0x200: Jump instruction
    header: u32, // 0x202: Magic signature "HdrS" (0x53726448)
    version: u16, // 0x206: Boot protocol version (e.g., 0x020F = 2.15)
    realmode_swtch: u32, // 0x208: Real mode switch hook
    start_sys_seg: u16, // 0x20C: Obsolete
    kernel_version: u16, // 0x20E: Pointer to kernel version string
    type_of_loader: u8, // 0x210: Boot loader identifier
    loadflags: u8, // 0x211: Boot protocol flags
    setup_move_size: u16, // 0x212: Move-to-high memory size
    code32_start: u32, // 0x214: 32-bit code start address
    ramdisk_image: u32, // 0x218: initrd load address
    ramdisk_size: u32, // 0x21C: initrd size
    bootsect_kludge: u32, // 0x220: Obsolete
    heap_end_ptr: u16, // 0x224: Heap end pointer (relative to 0x9000)
    ext_loader_ver: u8, // 0x226: Extended boot loader version
    ext_loader_type: u8, // 0x227: Extended boot loader type
    cmd_line_ptr: u32, // 0x228: Command line pointer
    initrd_addr_max: u32, // 0x22C: Highest address for initrd
    kernel_alignment: u32, // 0x230: Physical address alignment
    relocatable_kernel: u8, // 0x234: Whether kernel is relocatable
    min_alignment: u8, // 0x235: Minimum alignment (power of 2)
    xloadflags: u16, // 0x236: Extended load flags
    cmdline_size: u32, // 0x238: Maximum command line size
    hardware_subarch: u32, // 0x23C: Hardware subarchitecture
    hardware_subarch_data: u64, // 0x240: Subarchitecture-specific data
    payload_offset: u32, // 0x248: Offset of kernel payload
    payload_length: u32, // 0x24C: Length of kernel payload
    setup_data: u64, // 0x250: Pointer to setup_data linked list
    pref_address: u64, // 0x258: Preferred loading address
    init_size: u32, // 0x260: Linear memory required during init
    handover_offset: u32, // 0x264: Handover protocol entry offset
    kernel_info_offset: u32, // 0x268: Kernel info structure offset
};

// Compile-time assertion to ensure struct size is correct
comptime {
    const expected_size = 0x26C - 0x1F1; // from 0x1F1 to end of kernel_info_offset
    const actual_size = @sizeOf(SetupHeader);
    if (actual_size != expected_size) {
        @compileError(std.fmt.comptimePrint(
            "SetupHeader size mismatch: expected {d}, got {d}",
            .{ expected_size, actual_size },
        ));
    }
}

// ============================================================================
// bzImage Header Parsing
// ============================================================================

/// Load flags in SetupHeader.loadflags
pub const LOADED_HIGH: u8 = 0x01; // Protected mode code loaded at 0x100000
pub const KASLR_FLAG: u8 = 0x02; // Kernel supports KASLR
pub const QUIET_FLAG: u8 = 0x20; // Suppress early messages
pub const KEEP_SEGMENTS: u8 = 0x40; // Don't reload segment registers
pub const CAN_USE_HEAP: u8 = 0x80; // Heap end_ptr is valid

/// Extended load flags in SetupHeader.xloadflags
pub const XLF_KERNEL_64: u16 = 0x0001; // Kernel has legacy 64-bit entry
pub const XLF_CAN_BE_LOADED_ABOVE_4G: u16 = 0x0002; // Can be loaded above 4GB
pub const XLF_EFI_HANDOVER_32: u16 = 0x0004; // Has 32-bit EFI handover
pub const XLF_EFI_HANDOVER_64: u16 = 0x0008; // Has 64-bit EFI handover
pub const XLF_EFI_KEXEC: u16 = 0x0010; // Supports kexec EFI runtime

/// Boot protocol magic signature "HdrS"
pub const BOOT_HEADER_MAGIC: u32 = 0x53726448;

/// Boot sector signature
pub const BOOT_FLAG_MAGIC: u16 = 0xAA55;

/// Minimum supported boot protocol version (2.00)
pub const MIN_BOOT_PROTOCOL_VERSION: u16 = 0x0200;

/// Standard setup header offset in bzImage
pub const SETUP_HEADER_OFFSET: usize = 0x1F1;

/// Error set for boot header parsing
pub const BootHeaderError = error{
    InvalidBootSignature,
    InvalidHeaderMagic,
    UnsupportedProtocolVersion,
    BufferTooSmall,
    InvalidAlignment,
};

/// Parse Linux boot protocol header from bzImage data
///
/// Validates:
/// - Boot signature (0xAA55 at offset 0x1FE)
/// - Header magic ("HdrS" at offset 0x202)
/// - Protocol version (>= 2.00)
///
/// Returns the parsed setup header
pub fn parseBootHeader(data: []const u8) BootHeaderError!SetupHeader {
    // Check minimum size
    if (data.len < SETUP_HEADER_OFFSET + @sizeOf(SetupHeader)) {
        return BootHeaderError.BufferTooSmall;
    }

    // Parse header from offset 0x1F1
    const header_bytes = data[SETUP_HEADER_OFFSET..][0..@sizeOf(SetupHeader)];
    const header = @as(*align(1) const SetupHeader, @ptrCast(header_bytes)).*;

    // Validate boot signature (0xAA55 at offset 0x1FE)
    if (header.boot_flag != BOOT_FLAG_MAGIC) {
        return BootHeaderError.InvalidBootSignature;
    }

    // Validate header magic ("HdrS")
    if (header.header != BOOT_HEADER_MAGIC) {
        return BootHeaderError.InvalidHeaderMagic;
    }

    // Check protocol version (minimum 2.00)
    if (header.version < MIN_BOOT_PROTOCOL_VERSION) {
        return BootHeaderError.UnsupportedProtocolVersion;
    }

    return header;
}

/// Kernel loading information
pub const KernelInfo = struct {
    setup_size: u32, // Real-mode setup code size in bytes
    kernel_offset: u32, // Offset to protected-mode kernel in bzImage
    kernel_size: u32, // Protected-mode kernel size in bytes
    load_address: u32, // Physical address where kernel should be loaded
};

/// Extract kernel loading information from setup header
///
/// Returns information needed to load the kernel into memory:
/// - setup_size: Size of real-mode setup code
/// - kernel_offset: Where protected-mode kernel starts in bzImage
/// - kernel_size: Size of protected-mode kernel code
/// - load_address: Physical address for kernel (0x100000 for LOADED_HIGH)
pub fn getKernelInfo(header: SetupHeader, data: []const u8) BootHeaderError!KernelInfo {
    // Setup sectors (512 bytes each) - if 0, default to 4
    const setup_sects = if (header.setup_sects == 0) 4 else header.setup_sects;

    // Real-mode setup size: (setup_sects + 1) * 512 bytes
    // The +1 accounts for the boot sector
    const setup_size: u32 = (@as(u32, setup_sects) + 1) * 512;

    // Protected-mode kernel starts after setup code
    const kernel_offset: u32 = setup_size;

    // Kernel size from syssize field (in 16-byte paragraphs)
    // syssize is the size of protected-mode code only
    const kernel_size: u32 = header.syssize * 16;

    // Determine load address based on LOADED_HIGH flag
    const load_address: u32 = if ((header.loadflags & LOADED_HIGH) != 0)
        0x100000 // Load at 1MB for protected mode
    else
        0x10000; // Load at 64KB for old-style loading (rarely used)

    // Sanity check: ensure we don't read past buffer
    if (kernel_offset + kernel_size > data.len) {
        return BootHeaderError.BufferTooSmall;
    }

    return KernelInfo{
        .setup_size = setup_size,
        .kernel_offset = kernel_offset,
        .kernel_size = kernel_size,
        .load_address = load_address,
    };
}

/// Get kernel version string from bzImage
///
/// Returns pointer to kernel version string if available, null otherwise
pub fn getKernelVersionString(header: SetupHeader, data: []const u8) ?[]const u8 {
    // kernel_version is offset from start of setup code (0x200)
    if (header.kernel_version == 0) return null;

    const version_offset = 0x200 + header.kernel_version;
    if (version_offset >= data.len) return null;

    // Find null terminator
    const start = data[version_offset..];
    for (start, 0..) |byte, i| {
        if (byte == 0) {
            return start[0..i];
        }
    }

    return null;
}

// ============================================================================
// Boot Parameters (Zero Page)
// ============================================================================

/// Linux boot parameters (zero page) at address 0x0 or 0x10000
pub const BootParams = extern struct {
    // 0x000-0x0EF: Legacy BIOS data
    screen_info: [64]u8, // 0x000
    apm_bios_info: [20]u8, // 0x040
    _pad1: [4]u8, // 0x054
    tboot_addr: u64, // 0x058
    ist_info: [16]u8, // 0x060
    acpi_rsdp_addr: u64, // 0x070
    _pad2: [8]u8, // 0x078
    hd0_info: [16]u8, // 0x080
    hd1_info: [16]u8, // 0x090
    sys_desc_table: [16]u8, // 0x0A0
    olpc_ofw_header: [16]u8, // 0x0B0
    ext_ramdisk_image: u32, // 0x0C0
    ext_ramdisk_size: u32, // 0x0C4
    ext_cmd_line_ptr: u32, // 0x0C8
    _pad3: [112]u8, // 0x0CC
    cc_blob_address: u32, // 0x13C
    edid_info: [128]u8, // 0x140
    efi_info: [32]u8, // 0x1C0
    alt_mem_k: u32, // 0x1E0
    scratch: u32, // 0x1E4
    e820_entries: u8, // 0x1E8
    eddbuf_entries: u8, // 0x1E9
    edd_mbr_sig_buf_entries: u8, // 0x1EA
    kbd_status: u8, // 0x1EB
    secure_boot: u8, // 0x1EC
    _pad4: [2]u8, // 0x1ED
    sentinel: u8, // 0x1EF
    _pad5: [1]u8, // 0x1F0

    // 0x1F1-0x26B: Setup header
    hdr: SetupHeader, // 0x1F1

    // 0x26C-0x28F: Padding after header
    _pad6: [36]u8,

    // 0x290-0x2CF: EDD MBR signature buffer
    edd_mbr_sig_buffer: [64]u8, // 0x290

    // 0x2D0-0xCCF: E820 memory map (128 entries max, 20 bytes each)
    e820_table: [2560]u8, // 0x2D0

    // 0xCD0-0xCFF: Padding
    _pad7: [48]u8,

    // 0xD00-0xEEB: EDD information
    eddbuf: [492]u8, // 0xD00

    // 0xEEC-0xFFF: Final padding to 4KB
    _pad8: [276]u8,

    /// Initialize a zero page with default values
    pub fn init() BootParams {
        var params: BootParams = std.mem.zeroes(BootParams);

        // Set boot flag magic number
        params.hdr.boot_flag = 0xAA55;

        // Set header magic "HdrS"
        params.hdr.header = 0x53726448;

        // Boot protocol version 2.15 (supports 64-bit entry point)
        params.hdr.version = 0x020F;

        // Type of loader: 0xFF = undefined (we're a custom emulator)
        params.hdr.type_of_loader = 0xFF;

        // Load flags: bit 0 = loaded high (1 GB)
        params.hdr.loadflags = 0x01;

        // Setup size
        params.hdr.setup_sects = 4; // 4 * 512 = 2KB setup

        // Video mode: 0xFFFF = normal VGA text mode
        params.hdr.vid_mode = 0xFFFF;

        // Code32 start address (where kernel protected mode code begins)
        params.hdr.code32_start = 0x100000; // 1 MB

        // Max command line size
        params.hdr.cmdline_size = 2048;

        // Kernel alignment (2 MB for modern kernels)
        params.hdr.kernel_alignment = 0x200000;

        // Relocatable kernel
        params.hdr.relocatable_kernel = 1;

        // Minimum alignment (21 = 2MB)
        params.hdr.min_alignment = 21;

        // Init size (estimated kernel size)
        params.hdr.init_size = 0x1000000; // 16 MB

        return params;
    }

    /// Add an E820 memory map entry
    pub fn addE820Entry(self: *BootParams, addr: u64, size: u64, entry_type: E820Type) !void {
        if (self.e820_entries >= 128) {
            return error.E820TableFull;
        }

        const offset = @as(usize, self.e820_entries) * @sizeOf(E820Entry);
        const entry = E820Entry.init(addr, size, entry_type);

        // Write entry to e820_table
        const bytes = std.mem.asBytes(&entry);
        @memcpy(self.e820_table[offset..][0..bytes.len], bytes);

        self.e820_entries += 1;
    }

    /// Set the command line pointer and copy command line to memory
    pub fn setCommandLine(self: *BootParams, cmdline_addr: u32, cmdline: []const u8) void {
        self.hdr.cmd_line_ptr = cmdline_addr;

        // Ensure we don't exceed max cmdline size
        const max_len = @min(cmdline.len, self.hdr.cmdline_size);
        _ = max_len;
    }

    /// Set ramdisk/initrd location
    pub fn setInitrd(self: *BootParams, addr: u32, size: u32) void {
        self.hdr.ramdisk_image = addr;
        self.hdr.ramdisk_size = size;
    }
};

/// Setup boot parameters for Linux kernel boot
pub fn setupBootParams(
    allocator: Allocator,
    header: SetupHeader,
    cmdline: []const u8,
    memory_size: u32,
) !*BootParams {
    const params = try allocator.create(BootParams);
    errdefer allocator.destroy(params);

    // Initialize with defaults
    params.* = BootParams.init();

    // Copy provided header fields (override defaults if needed)
    params.hdr = header;

    // Ensure boot flag is set
    if (params.hdr.boot_flag != 0xAA55) {
        params.hdr.boot_flag = 0xAA55;
    }

    // Ensure header magic is set
    if (params.hdr.header != 0x53726448) {
        params.hdr.header = 0x53726448;
    }

    // Set up E820 memory map
    // Entry 0: Low memory (0 - 640 KB)
    try params.addE820Entry(0x0, 0xA0000, .ram);

    // Entry 1: VGA/BIOS area (640 KB - 1 MB) - reserved
    try params.addE820Entry(0xA0000, 0x60000, .reserved);

    // Entry 2: Extended memory (1 MB - memory_size)
    if (memory_size > 0x100000) {
        const ext_mem_size = memory_size - 0x100000;
        try params.addE820Entry(0x100000, ext_mem_size, .ram);
    }

    // Set command line pointer (will be written to 0x20000)
    const cmdline_addr = 0x20000;
    params.setCommandLine(cmdline_addr, cmdline);

    // Set alt_mem_k (extended memory in KB, for old kernels)
    if (memory_size > 0x100000) {
        params.alt_mem_k = @intCast((memory_size - 0x100000) / 1024);
    }

    return params;
}

/// Write boot parameters to emulator memory at specified address
pub fn writeBootParams(memory: *Memory, params: *const BootParams, base_addr: u32) !void {
    const params_bytes = std.mem.asBytes(params);

    // Ensure we have enough memory
    if (base_addr + params_bytes.len > memory.getSize()) {
        return error.OutOfBounds;
    }

    // Write the entire structure
    try memory.writeBytes(base_addr, params_bytes);
}

/// Write command line string to memory
pub fn writeCommandLine(memory: *Memory, cmdline: []const u8, addr: u32) !void {
    // Ensure null-terminated
    try memory.writeBytes(addr, cmdline);
    try memory.writeByte(addr + @as(u32, @intCast(cmdline.len)), 0);
}

/// Complete setup: write boot params, command line, etc.
pub fn setupLinuxBoot(
    memory: *Memory,
    allocator: Allocator,
    cmdline: []const u8,
    memory_size: u32,
    boot_params_addr: u32,
) !void {
    // Create default header
    const header = std.mem.zeroes(SetupHeader);

    // Setup boot parameters
    const params = try setupBootParams(allocator, header, cmdline, memory_size);
    defer allocator.destroy(params);

    // Write boot parameters to memory
    try writeBootParams(memory, params, boot_params_addr);

    // Write command line to memory at 0x20000
    try writeCommandLine(memory, cmdline, 0x20000);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "SetupHeader size" {
    // Header should be from 0x1F1 to 0x26B (end of kernel_info_offset)
    const expected: usize = 0x26C - 0x1F1;
    try testing.expectEqual(expected, @sizeOf(SetupHeader));
}

test "parseBootHeader: valid header" {
    // Create minimal valid bzImage header
    var data: [0x26C]u8 = [_]u8{0} ** 0x26C;

    // Set boot signature at 0x1FE (offset from 0x1F1 = 0x0D)
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    // Set header magic at 0x202 (offset from 0x1F1 = 0x11)
    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48; // 'H'
    data[0x1F1 + header_offset + 1] = 0x64; // 'd'
    data[0x1F1 + header_offset + 2] = 0x72; // 'r'
    data[0x1F1 + header_offset + 3] = 0x53; // 'S'

    // Set version at 0x206 (offset from 0x1F1 = 0x15)
    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x0F; // 2.15
    data[0x1F1 + version_offset + 1] = 0x02;

    const header = try parseBootHeader(&data);
    try testing.expectEqual(BOOT_FLAG_MAGIC, header.boot_flag);
    try testing.expectEqual(BOOT_HEADER_MAGIC, header.header);
    try testing.expectEqual(@as(u16, 0x020F), header.version);
}

test "parseBootHeader: invalid boot signature" {
    var data: [0x26C]u8 = [_]u8{0} ** 0x26C;

    // Set wrong boot signature
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x00;
    data[0x1F1 + boot_flag_offset + 1] = 0x00;

    // Set valid header magic
    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48;
    data[0x1F1 + header_offset + 1] = 0x64;
    data[0x1F1 + header_offset + 2] = 0x72;
    data[0x1F1 + header_offset + 3] = 0x53;

    // Set valid version
    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x00;
    data[0x1F1 + version_offset + 1] = 0x02;

    const result = parseBootHeader(&data);
    try testing.expectError(BootHeaderError.InvalidBootSignature, result);
}

test "parseBootHeader: invalid header magic" {
    var data: [0x26C]u8 = [_]u8{0} ** 0x26C;

    // Set valid boot signature
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    // Set wrong header magic
    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x00;
    data[0x1F1 + header_offset + 1] = 0x00;
    data[0x1F1 + header_offset + 2] = 0x00;
    data[0x1F1 + header_offset + 3] = 0x00;

    // Set valid version
    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x00;
    data[0x1F1 + version_offset + 1] = 0x02;

    const result = parseBootHeader(&data);
    try testing.expectError(BootHeaderError.InvalidHeaderMagic, result);
}

test "parseBootHeader: unsupported version" {
    var data: [0x26C]u8 = [_]u8{0} ** 0x26C;

    // Set valid boot signature
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    // Set valid header magic
    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48;
    data[0x1F1 + header_offset + 1] = 0x64;
    data[0x1F1 + header_offset + 2] = 0x72;
    data[0x1F1 + header_offset + 3] = 0x53;

    // Set old version (1.99)
    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x99;
    data[0x1F1 + version_offset + 1] = 0x01;

    const result = parseBootHeader(&data);
    try testing.expectError(BootHeaderError.UnsupportedProtocolVersion, result);
}

test "parseBootHeader: buffer too small" {
    const data: [10]u8 = [_]u8{0} ** 10;
    const result = parseBootHeader(&data);
    try testing.expectError(BootHeaderError.BufferTooSmall, result);
}

test "getKernelInfo: loaded high" {
    var data: [0x10000]u8 = [_]u8{0} ** 0x10000;

    // Create valid header
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48;
    data[0x1F1 + header_offset + 1] = 0x64;
    data[0x1F1 + header_offset + 2] = 0x72;
    data[0x1F1 + header_offset + 3] = 0x53;

    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x0F;
    data[0x1F1 + version_offset + 1] = 0x02;

    // Set setup_sects = 15 (at offset 0x1F1)
    data[0x1F1] = 15;

    // Set syssize = 0x1000 (16-byte paragraphs) at 0x1F4
    const syssize_offset = 0x1F4 - 0x1F1;
    data[0x1F1 + syssize_offset] = 0x00;
    data[0x1F1 + syssize_offset + 1] = 0x10;
    data[0x1F1 + syssize_offset + 2] = 0x00;
    data[0x1F1 + syssize_offset + 3] = 0x00;

    // Set loadflags = LOADED_HIGH at 0x211
    const loadflags_offset = 0x211 - 0x1F1;
    data[0x1F1 + loadflags_offset] = LOADED_HIGH;

    const header = try parseBootHeader(&data);
    const info = try getKernelInfo(header, &data);

    // Expected: (15 + 1) * 512 = 8192 bytes setup
    try testing.expectEqual(@as(u32, 8192), info.setup_size);
    try testing.expectEqual(@as(u32, 8192), info.kernel_offset);
    try testing.expectEqual(@as(u32, 0x1000 * 16), info.kernel_size);
    try testing.expectEqual(@as(u32, 0x100000), info.load_address);
}

test "getKernelInfo: loaded low (legacy)" {
    var data: [0x10000]u8 = [_]u8{0} ** 0x10000;

    // Create valid header (similar to previous test)
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48;
    data[0x1F1 + header_offset + 1] = 0x64;
    data[0x1F1 + header_offset + 2] = 0x72;
    data[0x1F1 + header_offset + 3] = 0x53;

    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x00;
    data[0x1F1 + version_offset + 1] = 0x02;

    // Set setup_sects = 4
    data[0x1F1] = 4;

    // Set syssize = 0x100
    const syssize_offset = 0x1F4 - 0x1F1;
    data[0x1F1 + syssize_offset] = 0x00;
    data[0x1F1 + syssize_offset + 1] = 0x01;
    data[0x1F1 + syssize_offset + 2] = 0x00;
    data[0x1F1 + syssize_offset + 3] = 0x00;

    // Set loadflags = 0 (not LOADED_HIGH)
    const loadflags_offset = 0x211 - 0x1F1;
    data[0x1F1 + loadflags_offset] = 0;

    const header = try parseBootHeader(&data);
    const info = try getKernelInfo(header, &data);

    // Expected: (4 + 1) * 512 = 2560 bytes setup
    try testing.expectEqual(@as(u32, 2560), info.setup_size);
    try testing.expectEqual(@as(u32, 2560), info.kernel_offset);
    try testing.expectEqual(@as(u32, 0x100 * 16), info.kernel_size);
    try testing.expectEqual(@as(u32, 0x10000), info.load_address); // Low load
}

test "getKernelInfo: default setup_sects" {
    var data: [0x10000]u8 = [_]u8{0} ** 0x10000;

    // Create valid header
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48;
    data[0x1F1 + header_offset + 1] = 0x64;
    data[0x1F1 + header_offset + 2] = 0x72;
    data[0x1F1 + header_offset + 3] = 0x53;

    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x00;
    data[0x1F1 + version_offset + 1] = 0x02;

    // Set setup_sects = 0 (should default to 4)
    data[0x1F1] = 0;

    // Set syssize = 0x100
    const syssize_offset = 0x1F4 - 0x1F1;
    data[0x1F1 + syssize_offset] = 0x00;
    data[0x1F1 + syssize_offset + 1] = 0x01;
    data[0x1F1 + syssize_offset + 2] = 0x00;
    data[0x1F1 + syssize_offset + 3] = 0x00;

    const header = try parseBootHeader(&data);
    const info = try getKernelInfo(header, &data);

    // Expected: default (4 + 1) * 512 = 2560 bytes
    try testing.expectEqual(@as(u32, 2560), info.setup_size);
}

test "getKernelVersionString: valid version" {
    var data: [0x400]u8 = [_]u8{0} ** 0x400;

    // Create valid header
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48;
    data[0x1F1 + header_offset + 1] = 0x64;
    data[0x1F1 + header_offset + 2] = 0x72;
    data[0x1F1 + header_offset + 3] = 0x53;

    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x0F;
    data[0x1F1 + version_offset + 1] = 0x02;

    // Set kernel_version pointer at 0x20E (offset 0x30 from setup start)
    const kernel_version_offset = 0x20E - 0x1F1;
    data[0x1F1 + kernel_version_offset] = 0x30;
    data[0x1F1 + kernel_version_offset + 1] = 0x00;

    // Write version string at 0x200 + 0x30 = 0x230
    const version_string = "6.1.0-test";
    @memcpy(data[0x230..][0..version_string.len], version_string);
    data[0x230 + version_string.len] = 0; // Null terminator

    const header = try parseBootHeader(&data);
    const version_str = getKernelVersionString(header, &data);

    try testing.expect(version_str != null);
    try testing.expectEqualStrings(version_string, version_str.?);
}

test "getKernelVersionString: no version" {
    var data: [0x26C]u8 = [_]u8{0} ** 0x26C;

    // Create valid header with kernel_version = 0
    const boot_flag_offset = 0x1FE - 0x1F1;
    data[0x1F1 + boot_flag_offset] = 0x55;
    data[0x1F1 + boot_flag_offset + 1] = 0xAA;

    const header_offset = 0x202 - 0x1F1;
    data[0x1F1 + header_offset] = 0x48;
    data[0x1F1 + header_offset + 1] = 0x64;
    data[0x1F1 + header_offset + 2] = 0x72;
    data[0x1F1 + header_offset + 3] = 0x53;

    const version_offset = 0x206 - 0x1F1;
    data[0x1F1 + version_offset] = 0x00;
    data[0x1F1 + version_offset + 1] = 0x02;

    // kernel_version = 0 at 0x20E
    const kernel_version_offset = 0x20E - 0x1F1;
    data[0x1F1 + kernel_version_offset] = 0x00;
    data[0x1F1 + kernel_version_offset + 1] = 0x00;

    const header = try parseBootHeader(&data);
    const version_str = getKernelVersionString(header, &data);

    try testing.expect(version_str == null);
}

test "E820Entry initialization" {
    const entry = E820Entry.init(0x100000, 0x1000000, .ram);

    try testing.expectEqual(@as(u64, 0x100000), entry.addr);
    try testing.expectEqual(@as(u64, 0x1000000), entry.size);
    try testing.expectEqual(@as(u32, 1), entry.type);
}

test "BootParams initialization" {
    const params = BootParams.init();

    try testing.expectEqual(@as(u16, 0xAA55), params.hdr.boot_flag);
    try testing.expectEqual(@as(u32, 0x53726448), params.hdr.header);
    try testing.expectEqual(@as(u16, 0x020F), params.hdr.version);
    try testing.expectEqual(@as(u8, 0), params.e820_entries);
}

test "BootParams add E820 entries" {
    var params = BootParams.init();

    try params.addE820Entry(0x0, 0xA0000, .ram);
    try params.addE820Entry(0x100000, 0x1000000, .ram);

    try testing.expectEqual(@as(u8, 2), params.e820_entries);

    // Verify first entry
    const entry1_bytes = params.e820_table[0..@sizeOf(E820Entry)];
    const entry1 = std.mem.bytesAsValue(E820Entry, entry1_bytes[0..@sizeOf(E820Entry)]);
    try testing.expectEqual(@as(u64, 0x0), entry1.addr);
    try testing.expectEqual(@as(u64, 0xA0000), entry1.size);
}

test "setupBootParams with memory map" {
    const allocator = testing.allocator;

    const header = std.mem.zeroes(SetupHeader);
    const cmdline = "console=ttyS0";
    const memory_size = 16 * 1024 * 1024; // 16 MB

    const params = try setupBootParams(allocator, header, cmdline, memory_size);
    defer allocator.destroy(params);

    // Should have 3 E820 entries (low mem, reserved, high mem)
    try testing.expectEqual(@as(u8, 3), params.e820_entries);

    // Verify boot flag and header
    try testing.expectEqual(@as(u16, 0xAA55), params.hdr.boot_flag);
    try testing.expectEqual(@as(u32, 0x53726448), params.hdr.header);

    // Verify command line pointer
    try testing.expectEqual(@as(u32, 0x20000), params.hdr.cmd_line_ptr);
}

test "writeBootParams to memory" {
    const allocator = testing.allocator;

    var mem = try Memory.init(allocator, 64 * 1024); // 64 KB
    defer mem.deinit();

    var params = BootParams.init();
    try params.addE820Entry(0x0, 0xA0000, .ram);

    try writeBootParams(&mem, &params, 0x0);

    // Verify boot flag was written correctly
    const boot_flag = try mem.readWord(0x1FE);
    try testing.expectEqual(@as(u16, 0xAA55), boot_flag);

    // Verify header magic
    const header_magic = try mem.readDword(0x202);
    try testing.expectEqual(@as(u32, 0x53726448), header_magic);

    // Verify e820_entries count
    const e820_count = try mem.readByte(0x1E8);
    try testing.expectEqual(@as(u8, 1), e820_count);
}

test "writeCommandLine to memory" {
    const allocator = testing.allocator;

    var mem = try Memory.init(allocator, 64 * 1024);
    defer mem.deinit();

    const cmdline = "console=ttyS0 root=/dev/sda1";
    try writeCommandLine(&mem, cmdline, 0x20000);

    // Verify command line was written
    const read_cmdline = try mem.readBytes(0x20000, cmdline.len);
    try testing.expectEqualStrings(cmdline, read_cmdline);

    // Verify null terminator
    const null_byte = try mem.readByte(0x20000 + @as(u32, @intCast(cmdline.len)));
    try testing.expectEqual(@as(u8, 0), null_byte);
}

test "setupLinuxBoot complete setup" {
    const allocator = testing.allocator;

    var mem = try Memory.init(allocator, 256 * 1024); // 256 KB
    defer mem.deinit();

    const cmdline = "console=ttyS0";
    const memory_size = 16 * 1024 * 1024;
    const boot_params_addr = 0x10000; // 64 KB (common location)

    try setupLinuxBoot(&mem, allocator, cmdline, memory_size, boot_params_addr);

    // Verify boot params were written
    const boot_flag = try mem.readWord(boot_params_addr + 0x1FE);
    try testing.expectEqual(@as(u16, 0xAA55), boot_flag);

    // Verify command line was written
    const read_cmdline = try mem.readBytes(0x20000, cmdline.len);
    try testing.expectEqualStrings(cmdline, read_cmdline);

    // Verify E820 entries count
    const e820_count = try mem.readByte(boot_params_addr + 0x1E8);
    try testing.expectEqual(@as(u8, 3), e820_count);
}
