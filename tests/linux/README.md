# Linux Kernel Testing

This directory contains infrastructure for building and testing Linux on the i686 emulator.

## Current Status

**The emulator cannot yet boot Linux.** The following features are required:

| Feature | Status | Priority |
|---------|--------|----------|
| Protected mode | Not implemented | High |
| GDT/IDT | Not implemented | High |
| Paging (CR0, CR3) | Not implemented | High |
| More instructions | Partial (~50 of ~350) | High |
| PIC (8259) | Not implemented | Medium |
| PIT (8254) | Not implemented | Medium |
| Keyboard (8042) | Not implemented | Low |

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

## Direct Boot

When the emulator supports protected mode, direct boot will work:

```bash
# Load kernel at 1MB, jump to entry point
zig build run -- --kernel build/bzImage --cmdline "console=ttyS0 earlyprintk=serial"
```

## Kernel Configuration

The kernel is configured with:

- `CONFIG_SERIAL_8250=y` - UART driver
- `CONFIG_SERIAL_8250_CONSOLE=y` - Serial console
- `CONFIG_EARLY_PRINTK=y` - Early boot messages
- `CONFIG_SMP=n` - Single CPU (simpler)
- `CONFIG_MODULES=n` - Built-in only

## Testing Strategy

1. **Phase 1: Real Mode Tests** (current)
   - Simple programs using UART output
   - Basic instruction verification

2. **Phase 2: Protected Mode**
   - Implement GDT, segment descriptors
   - Test mode switching

3. **Phase 3: Paging**
   - Implement page tables
   - Test virtual memory

4. **Phase 4: Linux Boot**
   - Load bzImage
   - Execute kernel entry

5. **Phase 5: kselftest**
   - Run individual self-tests
   - Verify via serial output
