//! Memory Subsystem
//!
//! Provides memory management for the i686 emulator including
//! linear address space and memory-mapped I/O support.

const std = @import("std");

/// Memory access errors
pub const MemoryError = error{
    OutOfBounds,
    AllocationFailed,
    ReadOnly,
    NotMapped,
};

/// Main memory implementation
pub const Memory = struct {
    data: []u8,
    size: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize memory with given size
    pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
        const data = try allocator.alloc(u8, size);
        @memset(data, 0);

        return Self{
            .data = data,
            .size = size,
            .allocator = allocator,
        };
    }

    /// Free memory resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Read single byte
    pub fn readByte(self: *const Self, address: u32) MemoryError!u8 {
        if (address >= self.size) {
            return MemoryError.OutOfBounds;
        }
        return self.data[address];
    }

    /// Read 16-bit word (little-endian)
    pub fn readWord(self: *const Self, address: u32) MemoryError!u16 {
        if (address + 1 >= self.size) {
            return MemoryError.OutOfBounds;
        }
        const lo = self.data[address];
        const hi = self.data[address + 1];
        return (@as(u16, hi) << 8) | lo;
    }

    /// Read 32-bit dword (little-endian)
    pub fn readDword(self: *const Self, address: u32) MemoryError!u32 {
        if (address + 3 >= self.size) {
            return MemoryError.OutOfBounds;
        }
        const b0 = self.data[address];
        const b1 = self.data[address + 1];
        const b2 = self.data[address + 2];
        const b3 = self.data[address + 3];
        return (@as(u32, b3) << 24) | (@as(u32, b2) << 16) | (@as(u32, b1) << 8) | b0;
    }

    /// Write single byte
    pub fn writeByte(self: *Self, address: u32, value: u8) MemoryError!void {
        if (address >= self.size) {
            return MemoryError.OutOfBounds;
        }
        self.data[address] = value;
    }

    /// Write 16-bit word (little-endian)
    pub fn writeWord(self: *Self, address: u32, value: u16) MemoryError!void {
        if (address + 1 >= self.size) {
            return MemoryError.OutOfBounds;
        }
        self.data[address] = @truncate(value);
        self.data[address + 1] = @truncate(value >> 8);
    }

    /// Write 32-bit dword (little-endian)
    pub fn writeDword(self: *Self, address: u32, value: u32) MemoryError!void {
        if (address + 3 >= self.size) {
            return MemoryError.OutOfBounds;
        }
        self.data[address] = @truncate(value);
        self.data[address + 1] = @truncate(value >> 8);
        self.data[address + 2] = @truncate(value >> 16);
        self.data[address + 3] = @truncate(value >> 24);
    }

    /// Write multiple bytes
    pub fn writeBytes(self: *Self, address: u32, data: []const u8) MemoryError!void {
        if (address + data.len > self.size) {
            return MemoryError.OutOfBounds;
        }
        @memcpy(self.data[address..][0..data.len], data);
    }

    /// Read multiple bytes
    pub fn readBytes(self: *const Self, address: u32, len: usize) MemoryError![]const u8 {
        if (address + len > self.size) {
            return MemoryError.OutOfBounds;
        }
        return self.data[address..][0..len];
    }

    /// Get total memory size
    pub fn getSize(self: *const Self) usize {
        return self.size;
    }

    /// Clear all memory to zero
    pub fn clear(self: *Self) void {
        @memset(self.data, 0);
    }

    /// Fill memory region with value
    pub fn fill(self: *Self, address: u32, len: usize, value: u8) MemoryError!void {
        if (address + len > self.size) {
            return MemoryError.OutOfBounds;
        }
        @memset(self.data[address..][0..len], value);
    }
};

// Tests
test "memory init and deinit" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    try std.testing.expectEqual(@as(usize, 1024), mem.getSize());
}

test "memory byte read/write" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    try mem.writeByte(0, 0x42);
    try mem.writeByte(100, 0xFF);

    try std.testing.expectEqual(@as(u8, 0x42), try mem.readByte(0));
    try std.testing.expectEqual(@as(u8, 0xFF), try mem.readByte(100));
}

test "memory word read/write" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    try mem.writeWord(0, 0x1234);

    try std.testing.expectEqual(@as(u16, 0x1234), try mem.readWord(0));
    try std.testing.expectEqual(@as(u8, 0x34), try mem.readByte(0)); // Little endian
    try std.testing.expectEqual(@as(u8, 0x12), try mem.readByte(1));
}

test "memory dword read/write" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    try mem.writeDword(0, 0x12345678);

    try std.testing.expectEqual(@as(u32, 0x12345678), try mem.readDword(0));
    try std.testing.expectEqual(@as(u8, 0x78), try mem.readByte(0));
    try std.testing.expectEqual(@as(u8, 0x56), try mem.readByte(1));
    try std.testing.expectEqual(@as(u8, 0x34), try mem.readByte(2));
    try std.testing.expectEqual(@as(u8, 0x12), try mem.readByte(3));
}

test "memory out of bounds" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 100);
    defer mem.deinit();

    try std.testing.expectError(MemoryError.OutOfBounds, mem.readByte(100));
    try std.testing.expectError(MemoryError.OutOfBounds, mem.writeByte(100, 0));
    try std.testing.expectError(MemoryError.OutOfBounds, mem.readWord(99));
    try std.testing.expectError(MemoryError.OutOfBounds, mem.readDword(97));
}

test "memory write/read bytes" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try mem.writeBytes(10, &data);

    const read = try mem.readBytes(10, 4);
    try std.testing.expectEqualSlices(u8, &data, read);
}

test "memory fill" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    try mem.fill(0, 10, 0xAA);

    for (0..10) |i| {
        try std.testing.expectEqual(@as(u8, 0xAA), try mem.readByte(@intCast(i)));
    }
    try std.testing.expectEqual(@as(u8, 0x00), try mem.readByte(10));
}
