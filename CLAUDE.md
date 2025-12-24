# CLAUDE.md - AI Assistant Guide for i686 Emulator

This document provides essential information for AI assistants working with the i686 emulator codebase.

## Project Overview

This is an i686 (Intel Pentium Pro/II/III compatible) CPU emulator written in Zig. The emulator supports:

- Real mode and protected mode operation
- Core x86 instruction set
- UART (16550A) serial I/O for testing
- Native and WebAssembly build targets
- Debug interface with breakpoints and tracing

**Long-term goal**: Run Linux kernel self-tests (kselftest) on the emulator.

## Repository Structure

```
i686.emulator.zig/
├── build.zig              # Build configuration (native + WASM)
├── CLAUDE.md              # This file - AI assistant guide
├── README.md              # User documentation
└── src/
    ├── main.zig           # CLI entry point
    ├── root.zig           # Library root and Emulator struct
    ├── wasm.zig           # WebAssembly interface
    ├── cpu/
    │   ├── cpu.zig        # CPU emulation core
    │   ├── registers.zig  # Register definitions (GPR, segments, flags)
    │   └── instructions.zig # Instruction decoder and executor
    ├── memory/
    │   └── memory.zig     # Memory subsystem
    ├── io/
    │   ├── io.zig         # I/O controller
    │   └── uart.zig       # UART 16550A emulation
    ├── async/
    │   ├── queue.zig      # Async event queue
    │   └── eventloop.zig  # epoll-based event loop
    └── debug/
        └── debugger.zig   # Debug interface
```

## Build Commands

```bash
# Build native executable
zig build

# Build and run
zig build run

# Build with arguments
zig build run -- program.bin

# Run all tests
zig build test

# Build WebAssembly library
zig build wasm

# Generate documentation
zig build docs

# Clean build artifacts
zig build clean

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Testing

The emulator uses UART for testing output. Tests are embedded in source files using Zig's built-in test framework.

### Running Tests

```bash
# Run all tests
zig build test

# Run tests in Docker (CI/CD)
docker build -f Dockerfile.cicd -t i686-emu-test .
docker run --rm i686-emu-test
```

### Test Categories

| Module | File | Test Focus |
|--------|------|------------|
| CPU | `src/cpu/cpu.zig` | CPU initialization, reset, state |
| Registers | `src/cpu/registers.zig` | 8/16/32-bit register access, flags |
| Instructions | `src/cpu/instructions.zig` | Individual instruction execution |
| Memory | `src/memory/memory.zig` | Read/write, bounds checking |
| I/O | `src/io/io.zig` | Port mapping, UART registration |
| UART | `src/io/uart.zig` | Serial I/O, register access |
| Event Queue | `src/async/queue.zig` | Event prioritization, handlers |
| Event Loop | `src/async/eventloop.zig` | Timers, interrupts, epoll |
| Debug | `src/debug/debugger.zig` | Breakpoints, tracing |

### UART Testing Pattern

Use UART output to verify emulator behavior:

```zig
// In test code
var emu = try Emulator.init(allocator, .{ .enable_uart = true });
defer emu.deinit();

// Load test program that writes to UART
try emu.loadBinary(test_program, 0);
try emu.run();

// Check UART output
const output = emu.getUartOutput();
try std.testing.expectEqualStrings("expected output", output.?);
```

## Key Modules

### Emulator (`src/root.zig`)

Main entry point for embedding. Provides:
- `Emulator.init(allocator, config)` - Create emulator instance
- `Emulator.step()` - Execute single instruction
- `Emulator.run()` - Run until halt
- `Emulator.loadBinary(data, address)` - Load code into memory
- `Emulator.getUartOutput()` - Get serial output
- `Emulator.getCpuState()` - Get CPU state snapshot

### CPU (`src/cpu/cpu.zig`)

Core CPU emulation:
- Real mode addressing (segment * 16 + offset)
- Prefix handling (operand/address size, segment override)
- Stack operations (push/pop)
- I/O port access (in/out)

### Instructions (`src/cpu/instructions.zig`)

Implemented instruction groups:
- **Data Movement**: MOV, PUSH, POP
- **Arithmetic**: ADD, SUB, INC, DEC, CMP
- **Logic**: XOR, AND, OR
- **Control Flow**: JMP, Jcc, CALL, RET, INT
- **I/O**: IN, OUT
- **System**: NOP, HLT, CLI, STI, CLD, STD
- **Special**: CPUID, RDTSC

### Memory (`src/memory/memory.zig`)

Linear address space with:
- Byte/word/dword access (little-endian)
- Bulk read/write operations
- Bounds checking

### UART (`src/io/uart.zig`)

16550A-compatible UART:
- Transmit/receive buffers
- Line status register (LSR)
- Divisor latch access
- Standard COM port addresses (0x3F8, 0x2F8, etc.)

### Event Queue (`src/async/queue.zig`)

Async event queue for separating concerns:
- Priority-based event processing
- Handler registration by event type
- Typed channels for communication
- Event types: I/O, interrupts, timers, UART, debug

### Event Loop (`src/async/eventloop.zig`)

Single-threaded event loop using epoll:
- Timer creation and management
- Interrupt source handling (256 vectors)
- Cycle-accurate time tracking
- Non-blocking I/O polling

## Architecture

### Threading Model

The emulator is **single-threaded** by design:

```
┌─────────────────────────────────────────────────────┐
│                    Event Loop                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │  Timers  │  │ Interrupts│  │  Event Queue     │  │
│  │  (epoll) │  │ (pending) │  │  (prioritized)   │  │
│  └────┬─────┘  └────┬─────┘  └────────┬─────────┘  │
│       │             │                  │            │
│       └─────────────┴──────────────────┘            │
│                      │                              │
│              ┌───────▼───────┐                      │
│              │      CPU      │                      │
│              │   (step())    │                      │
│              └───────┬───────┘                      │
│                      │                              │
│       ┌──────────────┼──────────────┐              │
│       │              │              │              │
│  ┌────▼────┐   ┌─────▼─────┐  ┌─────▼─────┐       │
│  │ Memory  │   │    I/O    │  │   UART    │       │
│  └─────────┘   └───────────┘  └───────────┘       │
└─────────────────────────────────────────────────────┘
```

Key design principles:
- All emulation runs in a single thread
- epoll (Linux) provides timer/event multiplexing
- Events are queued and processed by priority
- No mutexes or locks needed
- Deterministic execution for debugging

### Event Flow

1. **CPU Step**: Execute one instruction
2. **I/O Check**: Handle port read/write
3. **Timer Check**: Fire expired timers via epoll
4. **Interrupt Check**: Service pending interrupts
5. **Event Processing**: Handle queued events

```zig
// Typical main loop
while (running) {
    // Poll for external events (timers, etc.)
    _ = try event_loop.poll(0);

    // Execute CPU instruction
    try emulator.step();

    // Advance emulated time
    event_loop.advanceCycles(1);

    // Process any queued events
    _ = try event_loop.runOnce(10);
}
```

### Timer and Interrupt Emulation

Timers use epoll's timerfd (Linux) for accurate timing:

```zig
// Create a 10ms repeating timer
const timer = try event_loop.createTimerMs(10, true, callback, context);

// Raise hardware interrupt
try event_loop.raiseInterrupt(0x20);  // IRQ0 = timer

// Check for pending interrupts
if (event_loop.getPendingInterrupt()) |vector| {
    // Handle interrupt
}
```

## Code Conventions

### Zig Style

- Use `@truncate` for explicit narrowing conversions
- Use `+%` and `-%` for wrapping arithmetic
- Prefer `errdefer` for cleanup on error paths
- Use `const Self = @This()` in struct methods

### Error Handling

```zig
// Return errors for recoverable failures
pub fn readByte(self: *const Self, address: u32) MemoryError!u8 {
    if (address >= self.size) return MemoryError.OutOfBounds;
    return self.data[address];
}

// Use try for propagation
const byte = try self.mem.readByte(addr);
```

### Naming Conventions

- Files: `snake_case.zig`
- Types: `PascalCase`
- Functions: `camelCase`
- Constants: `SCREAMING_SNAKE_CASE` or `snake_case`
- Enum variants: `snake_case`

### Module Organization

Each module should:
1. Have a doc comment explaining its purpose
2. Export public types and functions
3. Include unit tests at the bottom
4. Use explicit error types

## WebAssembly Interface

The WASM build (`src/wasm.zig`) exports C-compatible functions:

```javascript
// JavaScript usage example
const emu = await WebAssembly.instantiateStreaming(fetch('i686-emulator-wasm.wasm'));
const { init, step, getEax, getUartOutputLength, copyUartOutput } = emu.instance.exports;

init();
step();
console.log('EAX:', getEax());
```

Key exports:
- `init()`, `deinit()`, `reset()`
- `step()`, `run()`, `runCycles(n)`
- `getEax()`, `setEax(v)`, etc. (all registers)
- `readByte(addr)`, `writeByte(addr, val)`
- `loadBinary(addr, len)` (uses shared buffer)
- `getUartOutputLength()`, `copyUartOutput()`

## Adding New Instructions

1. Add opcode handler in `src/cpu/instructions.zig`:

```zig
// In execute() switch statement
0xXX => {
    // Decode operands if needed
    const modrm = try fetchModRM(cpu);

    // Execute instruction
    const result = // ... computation

    // Update flags if needed
    cpu.flags.updateArithmetic32(result, carry, overflow);

    // Write result
    try writeRM32(cpu, modrm, result);
},
```

2. Add tests for the instruction:

```zig
test "new instruction" {
    // Setup
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    // ... write instruction bytes

    // Execute
    try cpu.step();

    // Verify
    try std.testing.expectEqual(expected, cpu.regs.eax);
}
```

## Debugging Tips

### Using the Debug CLI

```bash
zig build run -- -d program.bin
```

Commands:
- `s` / `step` - Single step
- `r` / `run` - Run until halt
- `reg` - Show registers
- `mem <addr>` - Dump memory
- `q` / `quit` - Exit

### Adding Debug Output

```zig
// Temporary debug prints (remove before commit)
std.debug.print("EIP={x:08} opcode={x:02}\n", .{ cpu.eip, opcode });
```

### Common Issues

1. **Invalid opcode**: Check instruction encoding and prefix handling
2. **Memory bounds**: Verify address calculation in real/protected mode
3. **Flag corruption**: Ensure arithmetic instructions update correct flags
4. **Stack issues**: Check ESP manipulation and segment handling

## Future Development

### Priority Features for kselftest

1. **Protected Mode**
   - GDT/LDT support
   - Segment descriptor parsing
   - Privilege level handling

2. **System Instructions**
   - LGDT, LIDT, LLDT
   - MOV to/from control registers
   - SYSENTER/SYSEXIT

3. **Memory Management**
   - Paging support
   - Page fault handling
   - TLB emulation

4. **Interrupts**
   - IDT support
   - Hardware interrupt simulation
   - Exception handling

5. **Additional I/O**
   - PIC (8259) emulation
   - Timer (8254) emulation
   - Keyboard controller

## Performance Considerations

- Use `ReleaseSmall` for WASM builds
- Use `ReleaseFast` for native performance testing
- Avoid allocations in hot paths (instruction decode/execute)
- Consider instruction caching for repeated code

## Contributing

When making changes:

1. Run `zig build test` before committing
2. Add tests for new functionality
3. Update this document if adding new modules or conventions
4. Keep instruction implementations self-contained
5. Prefer clarity over cleverness in emulation code
