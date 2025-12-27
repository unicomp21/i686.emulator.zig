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
├── Dockerfile.cicd        # Docker image for CI/CD testing
├── src/
│   ├── main.zig           # CLI entry point
│   ├── root.zig           # Library root and Emulator struct
│   ├── wasm.zig           # WebAssembly interface
│   ├── cpu/
│   │   ├── cpu.zig        # CPU emulation core
│   │   ├── registers.zig  # Register definitions (GPR, segments, flags)
│   │   └── instructions.zig # Instruction decoder and executor
│   ├── memory/
│   │   └── memory.zig     # Memory subsystem
│   ├── io/
│   │   ├── io.zig         # I/O controller
│   │   └── uart.zig       # UART 16550A emulation
│   ├── boot/
│   │   └── loader.zig     # Linux kernel boot loader
│   ├── async/
│   │   ├── queue.zig      # Async event queue
│   │   └── eventloop.zig  # epoll-based event loop
│   └── debug/
│       └── debugger.zig   # Debug interface
└── tests/
    ├── integration_test.zig  # Integration tests with machine code
    ├── boot_test.zig         # Kernel boot loader tests
    └── linux/
        ├── Makefile          # Linux kernel build infrastructure
        └── README.md         # kselftest roadmap and status
```

## Build Commands

```bash
# Build native executable
zig build

# Build and run
zig build run

# Build with arguments
zig build run -- program.bin

# Run all tests (unit + integration)
zig build test

# Run only integration tests
zig build test-integ

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

### Test Status

All tests currently pass (100+):

| Test Suite | Tests | Status |
|------------|-------|--------|
| Root module | 2 | ✓ Pass |
| Main/CLI | 1 | ✓ Pass |
| Registers | 4 | ✓ Pass |
| Memory | 6 | ✓ Pass |
| UART | 5 | ✓ Pass |
| Event Queue | 4 | ✓ Pass |
| CPU (via root) | 4 | ✓ Pass |
| I/O (via root) | 6 | ✓ Pass |
| Keyboard | 10 | ✓ Pass |
| Protected Mode | 8 | ✓ Pass |
| Instructions | 20 | ✓ Pass |
| Integration | 22 | ✓ Pass |

### Test Categories

| Module | File | Test Focus |
|--------|------|------------|
| CPU | `src/cpu/cpu.zig` | CPU initialization, reset, state |
| Registers | `src/cpu/registers.zig` | 8/16/32-bit register access, flags |
| Instructions | `src/cpu/instructions.zig` | Individual instruction execution |
| Protected Mode | `src/cpu/protected_mode.zig` | GDT/IDT, CR0-CR4, segment descriptors, paging |
| Memory | `src/memory/memory.zig` | Read/write, bounds checking |
| I/O | `src/io/io.zig` | Port mapping, UART/Keyboard registration |
| UART | `src/io/uart.zig` | Serial I/O, register access |
| Keyboard | `src/io/keyboard.zig` | 8042 controller, A20 gate, scan codes |
| Event Queue | `src/async/queue.zig` | Event prioritization, handlers |
| Event Loop | `src/async/eventloop.zig` | Timers, interrupts, epoll |
| Debug | `src/debug/debugger.zig` | Breakpoints, tracing |
| Boot Loader | `src/boot/loader.zig` | Kernel loading, boot protocol parsing |
| Integration | `tests/integration_test.zig` | End-to-end with real machine code |
| Boot Tests | `tests/boot_test.zig` | Kernel boot and setup verification |

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

### Integration Tests

Integration tests (`tests/integration_test.zig`) execute real x86 machine code and verify results via UART output:

```zig
test "integration: uart hello" {
    const program = [_]u8{
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov edx, 0x3F8
        0xB0, 'O',                     // mov al, 'O'
        0xEE,                          // out dx, al
        0xB0, 'K',                     // mov al, 'K'
        0xEE,                          // out dx, al
        0xF4,                          // hlt
    };

    var emu = try Emulator.init(allocator, .{ .enable_uart = true });
    defer emu.deinit();
    try emu.loadBinary(&program, 0);
    try emu.run();

    try std.testing.expectEqualStrings("OK", emu.getUartOutput().?);
}
```

Run integration tests with:
```bash
zig build test-integ
```

Current integration tests:
- **uart hello**: Basic UART output
- **arithmetic**: ADD instruction and result verification
- **loop**: Looping with DEC + JNZ
- **call and return**: CALL/RET stack operations
- **register preservation**: PUSH/POP register save/restore
- **xor zero**: XOR r,r to zero register
- **protected mode**: LGDT + CR0.PE mode switch
- **lidt**: Load Interrupt Descriptor Table
- **mov cr0**: Control register read/write
- **paging identity map**: Enable paging with identity-mapped page tables
- **lea**: LEA with SIB addressing modes
- **movzx movsx**: Zero and sign extension instructions
- **shifts**: SHL, SHR, SAR with immediate count
- **test instruction**: TEST with flag verification
- **mul div**: MUL and DIV arithmetic operations
- **rep movsb**: REP MOVSB string copy operation
- **pushf popf**: Flag save/restore operations
- **bsf bsr**: Bit scan forward/reverse operations

## Key Modules

### Emulator (`src/root.zig`)

Main entry point for embedding. Provides:
- `Emulator.init(allocator, config)` - Create emulator instance
- `Emulator.step()` - Execute single instruction
- `Emulator.run()` - Run until halt
- `Emulator.loadBinary(data, address)` - Load code into memory
- `Emulator.loadKernel(kernel_data, cmdline)` - Load Linux kernel for direct boot
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
- **Data Movement**: MOV, LEA, PUSH, POP, MOVZX, MOVSX, XCHG, LAHF, SAHF, XLAT, CMOVcc
- **Segment Operations**: MOV Sreg, LES, LDS, LSS, LFS, LGS, ARPL
- **Arithmetic**: ADD, ADC, SUB, SBB, INC, DEC, CMP, MUL, IMUL (1/2/3-op), DIV, IDIV, NEG, CBW/CWDE, CWD/CDQ
- **BCD Arithmetic**: DAA, DAS, AAA, AAS, AAM, AAD
- **Logic**: XOR, AND, OR, NOT, TEST
- **Shift/Rotate**: SHL, SHR, SAR, ROL, ROR, RCL, RCR, SHLD, SHRD
- **Bit Manipulation**: BT, BTS, BTR, BTC, BSF, BSR, SETcc, BSWAP
- **String Operations**: MOVS, STOS, LODS, CMPS, SCAS, INS, OUTS (with REP/REPNE)
- **Control Flow**: JMP, Jcc, JECXZ, LOOP/LOOPE/LOOPNE, CALL, RET, INT, INTO, IRET, LEAVE, FAR JMP/CALL, RETF
- **Stack/Flags**: PUSHF, POPF, PUSHA, POPA, CLC, STC, CMC
- **I/O**: IN, OUT, INS, OUTS (byte/word/dword)
- **Atomic**: CMPXCHG, CMPXCHG8B, XADD
- **System**: NOP, HLT, CLI, STI, CLD, STD, CLTS, WAIT, BOUND, UD2, INVLPG, WBINVD
- **Descriptors**: LGDT, LIDT, SGDT, SIDT, SLDT, STR, LLDT, LTR, LAR, LSL, VERR, VERW, LMSW, SMSW
- **Registers**: MOV CRn, MOV DRn, RDMSR, WRMSR, SYSENTER, SYSEXIT
- **Special**: CPUID, RDTSC, INT3, INT1, SALC

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

### Boot Loader (`src/boot/loader.zig`)

Linux kernel direct boot implementation:
- Parses bzImage boot protocol headers
- Sets up boot parameters structure (zero page)
- Loads kernel at 1MB physical address
- Configures CPU for protected-mode entry
- Supports command line and initrd

Memory layout for kernel boot:
```
0x00000 - 0x00FFF: Real-mode IVT
0x10000 - 0x1FFFF: Boot parameters (zero page)
0x20000 - 0x2FFFF: Command line
0x100000+        : Protected-mode kernel
```

Usage:
```zig
// Load and boot kernel
try emu.loadKernel(kernel_data, "console=ttyS0 root=/dev/sda1");
try emu.run(); // Begin kernel execution
```

The boot loader implements the Linux x86 boot protocol (version 2.00+):
- `DirectBoot.init()` - Parse kernel from file path
- `DirectBoot.initFromMemory()` - Parse kernel from memory
- `DirectBoot.load()` - Load kernel into emulator
- `setupCpuForBoot()` - Configure CPU state for entry
- `setupMinimalGDT()` - Create flat GDT for protected mode

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

### Roadmap to Linux kselftest

The long-term goal is running Linux kernel self-tests. Current progress:

| Component | Status | Notes |
|-----------|--------|-------|
| Real mode | ✓ Done | Segment * 16 + offset addressing |
| Protected mode | ✓ Done | GDT/IDT, CR0-CR4, mode switching |
| Paging | ✓ Done | 4KB pages, identity mapping, CR3/PG support |
| Core instructions | ✓ Done | MOV, LEA, PUSH/POP, arithmetic, logic, jumps |
| Extended instructions | ✓ Done | MOVZX/MOVSX, CMOVcc, SETcc, bit ops |
| String operations | ✓ Done | REP MOVS/STOS/LODS/CMPS/SCAS/INS/OUTS |
| BCD arithmetic | ✓ Done | DAA, DAS, AAA, AAS, AAM, AAD |
| Atomic operations | ✓ Done | CMPXCHG, CMPXCHG8B, XADD |
| Stack frames | ✓ Done | ENTER/LEAVE, PUSHA/POPA |
| Far control flow | ✓ Done | FAR JMP, FAR CALL, RETF |
| System calls | ✓ Done | INT, IRET, SYSENTER/SYSEXIT |
| Segment operations | ✓ Done | MOV Sreg, LxS, ARPL, LAR, LSL |
| Descriptor tables | ✓ Done | LGDT/LIDT/SGDT/SIDT, LLDT/LTR, VERR/VERW |
| Control/Debug regs | ✓ Done | MOV CRn, MOV DRn, LMSW/SMSW |
| MSR support | ✓ Done | RDMSR/WRMSR, CPUID, RDTSC |
| UART I/O | ✓ Done | 16550A for test output |
| Keyboard I/O | ✓ Done | 8042 controller, A20 gate |
| PIC/PIT | ✓ Done | 8259 interrupt controller, 8254 timer |
| Event system | ✓ Done | Async queue + epoll event loop |
| FPU stubs | ✓ Done | WAIT, ESC opcodes (no full FPU) |
| Linux boot | ⚡ WIP | CLI ready, needs testing with real kernel |

### Protected Mode Support

The emulator now supports protected mode with:

- **GDT/IDT**: LGDT, LIDT, SGDT, SIDT instructions
- **Control Registers**: CR0, CR2, CR3, CR4 (MOV to/from)
- **Mode Switching**: PE bit in CR0 enables protected mode
- **Segment Descriptors**: Full parsing of base, limit, access, flags
- **LMSW/SMSW**: Load/Store Machine Status Word

Example protected mode switch:
```zig
const code = [_]u8{
    0x0F, 0x01, 0x15, 0xF6, 0x0F, 0x00, 0x00, // lgdt [0x0FF6]
    0x0F, 0x20, 0xC0,                         // mov eax, cr0
    0x0C, 0x01,                               // or al, 1
    0x0F, 0x22, 0xC0,                         // mov cr0, eax
    // Now in protected mode
};
```

### Paging Support

The emulator now supports x86 paging with:

- **Page Directory/Table Entries**: Full parsing of PDE and PTE structures
- **CR3**: Page directory base register with proper bit field handling
- **CR0.PG**: Enables/disables paging
- **Address Translation**: Linear-to-physical address translation through page tables
- **4KB Pages**: Standard 4KB page size with identity mapping support
- **Page Fault (#PF)**: CR2 stores faulting address on page fault
- **Permission Checking**: Present, R/W, and U/S bit checking

Example paging setup:
```zig
// Enable paging after protected mode
const code = [_]u8{
    0xB8, 0x00, 0x20, 0x00, 0x00,             // mov eax, 0x2000 (page dir)
    0x0F, 0x22, 0xD8,                         // mov cr3, eax
    0x0F, 0x20, 0xC0,                         // mov eax, cr0
    0x0D, 0x00, 0x00, 0x00, 0x80,             // or eax, 0x80000000 (PG bit)
    0x0F, 0x22, 0xC0,                         // mov cr0, eax
    // Paging is now active
};
```

Page table structure (set up in physical memory before enabling):
- Page Directory at CR3: 1024 4-byte entries (covers 4GB)
- Each PDE points to a Page Table with 1024 4-byte entries
- Each PTE points to a 4KB page frame

### Priority Features for kselftest

1. **Interrupts & Exceptions**
   - IDT-based interrupt dispatch (partially done)
   - Hardware interrupt simulation
   - Exception handling (#GP, #PF, #UD, etc.)

2. **More Instructions**
   - CMOVcc (conditional move)
   - XADD, CMPXCHG (atomic operations)
   - Additional x87 FPU instructions
   - SSE/MMX instructions (if needed)

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
