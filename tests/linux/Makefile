# Linux Kernel Build for i686 Emulator Testing
#
# This Makefile downloads and builds a minimal Linux kernel
# configured for the i686 emulator with kselftest support.
#
# Prerequisites:
#   - gcc, make, flex, bison, libelf-dev, libssl-dev
#   - For cross-compiling: gcc-i686-linux-gnu
#
# Usage:
#   make download    # Download Linux kernel source
#   make config      # Configure for i686 emulator
#   make kernel      # Build the kernel
#   make kselftest   # Build kselftest
#   make clean       # Clean build artifacts

LINUX_VERSION ?= 6.6.10
LINUX_URL = https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(LINUX_VERSION).tar.xz
LINUX_DIR = linux-$(LINUX_VERSION)

# Cross-compile settings for i686
ARCH = i386
CROSS_COMPILE ?=

# Output directories
BUILD_DIR = build
KSELFTEST_DIR = $(BUILD_DIR)/kselftest

.PHONY: all download config kernel kselftest clean help test-boot

all: kernel

help:
	@echo "Linux Kernel Build for i686 Emulator"
	@echo ""
	@echo "Targets:"
	@echo "  download    - Download Linux $(LINUX_VERSION) source"
	@echo "  config      - Configure kernel for i686 emulator"
	@echo "  kernel      - Build the kernel (bzImage)"
	@echo "  kselftest   - Build kernel self-tests"
	@echo "  test-boot   - Build and run boot sector test"
	@echo "  test-kernel - Run full kernel (when ready)"
	@echo "  clean       - Remove build artifacts"
	@echo ""
	@echo "The emulator now supports protected mode and paging!"
	@echo "Working on boot sector tests before full kernel boot."

download: $(LINUX_DIR)

$(LINUX_DIR):
	@echo "Downloading Linux $(LINUX_VERSION)..."
	curl -L -o linux-$(LINUX_VERSION).tar.xz $(LINUX_URL)
	tar xf linux-$(LINUX_VERSION).tar.xz
	rm linux-$(LINUX_VERSION).tar.xz

config: $(LINUX_DIR)
	@echo "Configuring kernel for i686..."
	cd $(LINUX_DIR) && make ARCH=$(ARCH) i386_defconfig
	cd $(LINUX_DIR) && ./scripts/config --enable CONFIG_SERIAL_8250
	cd $(LINUX_DIR) && ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
	cd $(LINUX_DIR) && ./scripts/config --enable CONFIG_EARLY_PRINTK
	cd $(LINUX_DIR) && ./scripts/config --disable CONFIG_SMP
	cd $(LINUX_DIR) && ./scripts/config --disable CONFIG_MODULES
	cd $(LINUX_DIR) && make ARCH=$(ARCH) olddefconfig

kernel: config
	@echo "Building kernel..."
	mkdir -p $(BUILD_DIR)
	cd $(LINUX_DIR) && make ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) -j$$(nproc) bzImage
	cp $(LINUX_DIR)/arch/x86/boot/bzImage $(BUILD_DIR)/

kselftest: kernel
	@echo "Building kselftest..."
	mkdir -p $(KSELFTEST_DIR)
	cd $(LINUX_DIR) && make ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) -C tools/testing/selftests
	cp -r $(LINUX_DIR)/tools/testing/selftests $(KSELFTEST_DIR)/

clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(LINUX_DIR)

# Boot sector test for emulator development
$(BUILD_DIR)/test_boot.bin: test_boot.asm
	@echo "Building boot sector test..."
	@mkdir -p $(BUILD_DIR)
	@if command -v nasm >/dev/null 2>&1; then \
		nasm -f bin -o $(BUILD_DIR)/test_boot.bin test_boot.asm; \
		echo "Boot sector built: $(BUILD_DIR)/test_boot.bin"; \
	else \
		echo "NASM not found. Install with: apt-get install nasm"; \
		echo "Or use the pre-assembled binary if available."; \
		exit 1; \
	fi

test-boot: $(BUILD_DIR)/test_boot.bin
	@echo "Running boot sector test on emulator..."
	cd ../.. && zig build run -- tests/linux/$(BUILD_DIR)/test_boot.bin

# Full kernel boot (when ready)
test-kernel: $(BUILD_DIR)/bzImage
	@echo "Running Linux kernel on emulator..."
	@echo "Note: This requires full boot protocol support."
	cd ../.. && zig build run -- tests/linux/$(BUILD_DIR)/bzImage
