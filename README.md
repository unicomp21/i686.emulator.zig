# i686 Emulator

An i686 (Intel Pentium Pro/II/III compatible) CPU emulator written in Zig.

## Features

- Real mode and protected mode CPU emulation
- Core x86 instruction set
- UART (16550A) serial I/O for testing
- Native and WebAssembly build targets
- Debug interface with breakpoints and single-stepping
- Clean, modular architecture

## Building

### Prerequisites

- Zig 0.13.0 or later

### Native Build

```bash
# Build executable
zig build

# Build and run
zig build run

# Run with a binary file
zig build run -- program.bin

# Debug mode
zig build run -- -d program.bin
```

### WebAssembly Build

```bash
zig build wasm
```

Output: `zig-out/lib/i686-emulator-wasm.a`

### Running Tests

```bash
zig build test
```

## Usage

### Command Line

```bash
i686-emu [options] [binary]

Options:
  -h, --help      Show help message
  -d, --debug     Enable debug/stepping mode
  -m, --memory N  Set memory size in bytes (default: 16MB)
```

### Debug Mode Commands

- `s` / `step` - Execute single instruction
- `r` / `run` - Run until halt
- `reg` - Display registers
- `mem <addr>` - Dump memory at address
- `q` / `quit` - Exit debugger

### As a Library

```zig
const emu = @import("i686-emulator");

var emulator = try emu.Emulator.init(allocator, .{
    .memory_size = 1024 * 1024,  // 1MB
    .enable_uart = true,
});
defer emulator.deinit();

// Load binary
try emulator.loadBinary(code, 0x0000);

// Run
try emulator.run();

// Check UART output
if (emulator.getUartOutput()) |output| {
    std.debug.print("Output: {s}\n", .{output});
}
```

### WebAssembly

```javascript
const wasm = await WebAssembly.instantiateStreaming(
    fetch('i686-emulator-wasm.wasm')
);
const emu = wasm.instance.exports;

// Initialize
emu.init();

// Load program
const buffer = new Uint8Array(emu.memory.buffer, emu.getIoBuffer(), code.length);
buffer.set(code);
emu.loadBinary(0, code.length);

// Run
while (!emu.isHalted()) {
    emu.step();
}

// Get output
const outputLen = emu.copyUartOutput();
const output = new Uint8Array(emu.memory.buffer, emu.getIoBuffer(), outputLen);
console.log(new TextDecoder().decode(output));
```

## Architecture

```
src/
├── main.zig           # CLI entry point
├── root.zig           # Library root, Emulator struct
├── wasm.zig           # WebAssembly exports
├── cpu/
│   ├── cpu.zig        # CPU core
│   ├── registers.zig  # Register definitions
│   └── instructions.zig # Instruction decoder
├── memory/
│   └── memory.zig     # Memory subsystem
├── io/
│   ├── io.zig         # I/O controller
│   └── uart.zig       # UART 16550A
└── debug/
    └── debugger.zig   # Debug interface
```

## Supported Instructions

### Data Movement
- MOV (register, memory, immediate)
- PUSH, POP

### Arithmetic
- ADD, SUB, INC, DEC
- CMP

### Logic
- XOR, AND, OR

### Control Flow
- JMP (short, near)
- Jcc (all conditional jumps)
- CALL, RET
- INT

### I/O
- IN, OUT (immediate and DX)

### System
- NOP, HLT
- CLI, STI, CLD, STD
- CPUID, RDTSC

## Testing

The emulator uses UART output for testing. Write test programs that output results to the serial port:

```asm
; Output 'A' to UART (COM1 at 0x3F8)
mov dx, 0x3F8
mov al, 'A'
out dx, al
hlt
```

## Goals

The long-term goal is to run Linux kernel self-tests (kselftest) on the emulator, which requires implementing:

- Full protected mode support
- Paging and memory management
- System call handling
- Additional hardware emulation (PIC, timer, etc.)

## License

MIT License

## Contributing

See `CLAUDE.md` for development guidelines and conventions.
