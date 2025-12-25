//! i686 Emulator CLI
//!
//! Command-line interface for the i686 emulator.

const std = @import("std");
const root = @import("root.zig");

const Emulator = root.Emulator;
const Config = root.Config;

/// Command-line arguments
const Args = struct {
    binary_path: ?[]const u8 = null,
    kernel_path: ?[]const u8 = null,
    cmdline: []const u8 = "console=ttyS0 earlyprintk=serial",
    initrd_path: ?[]const u8 = null,
    memory_mb: u32 = 128,
    debug: bool = false,
};

/// Parse command-line arguments
fn parseArgs(allocator: std.mem.Allocator) !Args {
    const process_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, process_args);

    var result = Args{};
    var i: usize = 1;

    while (i < process_args.len) : (i += 1) {
        const arg = process_args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--debug")) {
            result.debug = true;
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            i += 1;
            if (i >= process_args.len) {
                std.debug.print("Error: --kernel requires a path argument\n", .{});
                std.process.exit(1);
            }
            result.kernel_path = process_args[i];
        } else if (std.mem.eql(u8, arg, "--cmdline")) {
            i += 1;
            if (i >= process_args.len) {
                std.debug.print("Error: --cmdline requires a string argument\n", .{});
                std.process.exit(1);
            }
            result.cmdline = process_args[i];
        } else if (std.mem.eql(u8, arg, "--initrd")) {
            i += 1;
            if (i >= process_args.len) {
                std.debug.print("Error: --initrd requires a path argument\n", .{});
                std.process.exit(1);
            }
            result.initrd_path = process_args[i];
        } else if (std.mem.eql(u8, arg, "--memory")) {
            i += 1;
            if (i >= process_args.len) {
                std.debug.print("Error: --memory requires a size in MB\n", .{});
                std.process.exit(1);
            }
            result.memory_mb = try std.fmt.parseInt(u32, process_args[i], 10);
        } else if (arg[0] == '-') {
            std.debug.print("Error: unknown option '{s}'\n", .{arg});
            std.debug.print("Use --help for usage information\n", .{});
            std.process.exit(1);
        } else {
            // Positional argument - treat as binary path
            if (result.binary_path != null) {
                std.debug.print("Error: multiple binary paths specified\n", .{});
                std.process.exit(1);
            }
            result.binary_path = arg;
        }
    }

    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsed_args = try parseArgs(allocator);

    // Configure emulator
    var config = Config{
        .memory_size = parsed_args.memory_mb * 1024 * 1024,
        .enable_uart = true,
        .debug_mode = parsed_args.debug,
    };

    // Initialize emulator
    var emu = try Emulator.init(allocator, config);
    defer emu.deinit();

    // Determine boot mode and load code
    if (parsed_args.kernel_path) |kernel_path| {
        // Direct kernel boot mode
        std.debug.print("Loading kernel: {s}\n", .{kernel_path});
        std.debug.print("Kernel cmdline: {s}\n", .{parsed_args.cmdline});

        const kernel_file = try std.fs.cwd().openFile(kernel_path, .{});
        defer kernel_file.close();

        const kernel_data = try kernel_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(kernel_data);

        // Load initrd if specified
        var initrd_data: ?[]const u8 = null;
        defer if (initrd_data) |data| allocator.free(data);

        if (parsed_args.initrd_path) |initrd_path| {
            std.debug.print("Loading initrd: {s}\n", .{initrd_path});
            const initrd_file = try std.fs.cwd().openFile(initrd_path, .{});
            defer initrd_file.close();
            initrd_data = try initrd_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        }

        // TODO: Implement loadKernel() method in Emulator
        // For now, show a message that this feature is not yet implemented
        std.debug.print("\nDirect kernel boot is not yet implemented.\n", .{});
        std.debug.print("The --kernel option is available but requires implementation of:\n", .{});
        std.debug.print("  - Linux boot protocol (bzImage parsing)\n", .{});
        std.debug.print("  - Real mode setup (boot params, e820 map)\n", .{});
        std.debug.print("  - Protected mode kernel entry\n", .{});
        std.debug.print("\nSee CLAUDE.md for roadmap details.\n", .{});
        return;
    } else if (parsed_args.binary_path) |binary_path| {
        // Raw binary boot mode (existing behavior)
        const file = try std.fs.cwd().openFile(binary_path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(data);

        try emu.loadBinary(data, 0);
        std.debug.print("Loaded {d} bytes from {s}\n", .{ data.len, binary_path });
    } else {
        // No binary or kernel specified
        printUsage();
        return;
    }

    // Run emulator
    if (parsed_args.debug) {
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
        \\i686 Emulator - Intel Pentium Pro/II/III CPU Emulator
        \\
        \\Usage:
        \\  i686-emulator [options] [binary]
        \\  i686-emulator --kernel <bzImage> [--cmdline "..."]
        \\
        \\Options:
        \\  --kernel <path>    Linux kernel image (bzImage format)
        \\  --cmdline <args>   Kernel command line (default: "console=ttyS0 earlyprintk=serial")
        \\  --initrd <path>    Initial RAM disk image (optional)
        \\  --memory <MB>      Memory size in megabytes (default: 128)
        \\  -d, --debug        Enable debug/stepping mode
        \\  -h, --help         Show this help message
        \\
        \\Examples:
        \\  i686-emulator program.bin
        \\  i686-emulator --kernel bzImage --cmdline "console=ttyS0"
        \\  i686-emulator --kernel bzImage --initrd initrd.img --memory 256
        \\  i686-emulator -d program.bin
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
