//! i686 Emulator CLI
//!
//! Command-line interface for the i686 emulator.

const std = @import("std");
const root = @import("root.zig");

const Emulator = root.Emulator;
const Config = root.Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    var binary_path: ?[]const u8 = null;
    var debug_mode = false;

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
            config.debug_mode = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--memory")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --memory requires a value\n", .{});
                return;
            }
            config.memory_size = try std.fmt.parseInt(usize, args[i], 10);
        } else if (arg[0] != '-') {
            binary_path = arg;
        }
    }

    // Initialize emulator
    var emu = try Emulator.init(allocator, config);
    defer emu.deinit();

    // Load binary if specified
    if (binary_path) |path| {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(data);

        try emu.loadBinary(data, 0);
        std.debug.print("Loaded {d} bytes from {s}\n", .{ data.len, path });
    }

    if (debug_mode) {
        try runDebugMode(&emu, allocator);
    } else {
        try emu.run();
    }

    // Print UART output
    if (emu.getUartOutput()) |output| {
        if (output.len > 0) {
            std.debug.print("\n--- UART Output ---\n{s}\n", .{output});
        }
    }
}

fn printUsage() void {
    std.debug.print(
        \\i686 Emulator
        \\
        \\Usage: i686-emu [options] [binary]
        \\
        \\Options:
        \\  -h, --help      Show this help message
        \\  -d, --debug     Enable debug/stepping mode
        \\  -m, --memory N  Set memory size in bytes (default: 16MB)
        \\
        \\Examples:
        \\  i686-emu program.bin           Run a binary
        \\  i686-emu -d program.bin        Debug a binary
        \\  i686-emu -m 1048576 prog.bin   Run with 1MB memory
        \\
    , .{});
}

fn runDebugMode(emu: *Emulator, allocator: std.mem.Allocator) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("i686 Emulator Debug Mode\n", .{});
    try stdout.print("Commands: s(tep), r(un), q(uit), reg(isters), mem <addr>\n\n", .{});

    while (true) {
        try stdout.print("(dbg) ", .{});

        const line = stdin.readUntilDelimiterAlloc(allocator, '\n', 256) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer allocator.free(line);

        const cmd = std.mem.trim(u8, line, " \t\r");

        if (cmd.len == 0) continue;

        if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
            break;
        } else if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "step")) {
            emu.step() catch |err| {
                try stdout.print("Error: {}\n", .{err});
            };
            try printCpuState(emu, stdout);
        } else if (std.mem.eql(u8, cmd, "r") or std.mem.eql(u8, cmd, "run")) {
            emu.run() catch |err| {
                try stdout.print("Stopped: {}\n", .{err});
            };
            try printCpuState(emu, stdout);
        } else if (std.mem.eql(u8, cmd, "reg") or std.mem.eql(u8, cmd, "registers")) {
            try printCpuState(emu, stdout);
        } else if (std.mem.startsWith(u8, cmd, "mem ")) {
            const addr_str = std.mem.trim(u8, cmd[4..], " ");
            const addr = std.fmt.parseInt(u32, addr_str, 0) catch {
                try stdout.print("Invalid address\n", .{});
                continue;
            };
            try printMemory(emu, addr, stdout);
        } else {
            try stdout.print("Unknown command: {s}\n", .{cmd});
        }
    }
}

fn printCpuState(emu: *Emulator, writer: anytype) !void {
    const state = emu.getCpuState();
    try writer.print("EAX={x:0>8} EBX={x:0>8} ECX={x:0>8} EDX={x:0>8}\n", .{
        state.eax, state.ebx, state.ecx, state.edx,
    });
    try writer.print("ESI={x:0>8} EDI={x:0>8} EBP={x:0>8} ESP={x:0>8}\n", .{
        state.esi, state.edi, state.ebp, state.esp,
    });
    try writer.print("EIP={x:0>8} EFLAGS={x:0>8}\n", .{ state.eip, state.eflags });
    try writer.print("CS={x:0>4} DS={x:0>4} ES={x:0>4} SS={x:0>4}\n", .{
        state.cs, state.ds, state.es, state.ss,
    });
}

fn printMemory(emu: *Emulator, addr: u32, writer: anytype) !void {
    try writer.print("Memory at 0x{x:0>8}:\n", .{addr});
    var i: u32 = 0;
    while (i < 64) : (i += 16) {
        try writer.print("  {x:0>8}: ", .{addr + i});
        var j: u32 = 0;
        while (j < 16) : (j += 1) {
            const byte = emu.mem.readByte(addr + i + j) catch 0;
            try writer.print("{x:0>2} ", .{byte});
        }
        try writer.print("\n", .{});
    }
}

test "main module" {
    // Basic smoke test
    const allocator = std.testing.allocator;
    var emu = try Emulator.init(allocator, .{});
    defer emu.deinit();
}
