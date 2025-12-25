# Linux Kernel Testing

This directory contains infrastructure for building and testing Linux on the i686 emulator.

## Current Status

**The emulator is approaching Linux boot readiness.** Core features are implemented:

| Feature | Status | Priority | Notes |
|---------|--------|----------|-------|
| Protected mode | ✓ Done | High | PE bit, segment descriptors, LGDT/LIDT |
| GDT/IDT | ✓ Done | High | Full descriptor parsing, SGDT/SIDT |
| Paging (CR0, CR3) | ✓ Done | High | 4KB pages, identity mapping, CR2 |
| Control registers | ✓ Done | High | CR0-CR4, LMSW/SMSW |
| System calls | ✓ Done | High | INT 0x80, SYSENTER/SYSEXIT, MSR support |
| Segment loading | ✓ Done | High | LES/LDS/LSS/LFS/LGS far pointers |
| Descriptor tables | ✓ Done | High | SLDT/STR/LLDT/LTR/VERR/VERW |
| More instructions | ✓ ~150 done | High | Data, arithmetic, logic, control flow |
| String operations | ✓ Done | High | REP MOVS/STOS/LODS/CMPS/SCAS |
| Stack frames | ✓ Done | High | ENTER/LEAVE with nesting |
| PIC (8259) | ✓ Done | Medium | Interrupt controller, IRQ masking |
| PIT (8254) | ✓ Done | Medium | Programmable timer, modes 0-3 |
| Keyboard (8042) | ✓ Done | Low | Scan codes, A20 gate |
| UART (16550A) | ✓ Done | Medium | Serial I/O for console |
| Event system | ✓ Done | Medium | Async queue, epoll event loop |

### Remaining Work for Linux Boot

1. **Additional Instructions**: ~200 more opcodes (x87 FPU, SSE if needed)
2. **Exception Handling**: #GP, #PF, #UD, etc. (partially done via IDT)
3. **BIOS Services**: INT 10h, INT 13h for boot sector (optional)
4. **Boot Protocol**: Linux boot header parsing and setup
5. **Testing**: Verify with actual kernel boot sequence

## Building Linux (for future use)

### Prerequisites

```bash
# Debian/Ubuntu
apt-get install build-essential flex bison libelf-dev libssl-dev bc

# For cross-compiling to i386
apt-get install gcc-i686-linux-gnu
```

### Build Commands

```bash
# Download kernel source
make download

# Configure for i686 emulator (serial console, no SMP)
make config

# Build kernel
make kernel

# Build kselftest
make kselftest
```

### Output

- `build/bzImage` - Compressed kernel image
- `build/kselftest/` - Kernel self-test binaries

## Boot Sector Test

A minimal boot sector test is provided to verify protected mode transition:

```bash
# Build and run the boot sector test
cd tests/linux
make test-boot
```

This test:
1. Prints "BOOT" in real mode via UART (COM1 port 0x3F8)
2. Sets up a minimal GDT with code and data segments
3. Switches to protected mode (sets CR0.PE)
4. Prints "PROT" in protected mode via UART
5. Halts successfully

Expected output: `BOOTPROT`

The boot sector is 512 bytes and includes the standard boot signature (0xAA55).

### Boot Sector Source (`test_boot.asm`)

The boot sector test is written in NASM assembly and demonstrates:

- **Real mode I/O**: Direct UART access without BIOS interrupts
- **GDT setup**: Minimal 3-entry GDT (null, code, data)
- **Mode transition**: CR0.PE bit setting and far jump
- **Protected mode I/O**: UART access with 32-bit protected mode
- **Proper boot sector**: 510 bytes of code + 0xAA55 signature

This serves as a minimal test case for the emulator's boot sequence handling.

## Direct Kernel Boot

When the emulator supports the Linux boot protocol, direct boot will work:

```bash
# Load kernel at 1MB, jump to entry point
zig build run -- --kernel build/bzImage --cmdline "console=ttyS0 earlyprintk=serial"
```

Note: This requires implementing the Linux boot protocol (reading boot header, setting up boot parameters, etc.).

## Kernel Configuration

The kernel is configured with:

- `CONFIG_SERIAL_8250=y` - UART driver
- `CONFIG_SERIAL_8250_CONSOLE=y` - Serial console
- `CONFIG_EARLY_PRINTK=y` - Early boot messages
- `CONFIG_SMP=n` - Single CPU (simpler)
- `CONFIG_MODULES=n` - Built-in only

## Testing Strategy

1. **Phase 1: Real Mode Tests** ✓
   - Simple programs using UART output
   - Basic instruction verification
   - Integration tests with machine code

2. **Phase 2: Protected Mode** ✓
   - GDT, segment descriptors
   - Mode switching tests
   - Control register manipulation

3. **Phase 3: Paging** ✓
   - Page table setup
   - Identity mapping
   - Virtual memory tests

4. **Phase 4: Boot Sector Tests** (current)
   - Minimal 512-byte boot programs
   - Real → Protected mode transition
   - UART output verification
   - See `test_boot.asm` for example

5. **Phase 5: Linux Boot Preparation**
   - Load bzImage format
   - Parse Linux boot header
   - Set up boot parameters
   - Execute kernel entry point

6. **Phase 6: Linux Kernel Boot**
   - Early kernel initialization
   - Serial console output
   - Verify boot messages

7. **Phase 7: kselftest**
   - Run individual self-tests
   - Full test suite execution
   - Automated test validation
