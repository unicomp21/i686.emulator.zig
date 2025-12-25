const std = @import("std");

pub fn build(b: *std.Build) void {
    // Native target options
    const native_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================
    // Native Build
    // ============================================

    // Main emulator library (native)
    const lib = b.addStaticLibrary(.{
        .name = "i686-emulator",
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Main executable (native)
    const exe = b.addExecutable(.{
        .name = "i686-emu",
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_cmd.step);

    // ============================================
    // WebAssembly Build
    // ============================================

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // WASM library
    const wasm_lib = b.addStaticLibrary(.{
        .name = "i686-emulator-wasm",
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_lib.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm_lib, .{});
    const wasm_step = b.step("wasm", "Build WebAssembly library");
    wasm_step.dependOn(&install_wasm.step);

    // ============================================
    // Tests
    // ============================================

    // Run all tests through root module (handles cross-module imports)
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Standalone module tests (no cross-module dependencies)
    const register_tests = b.addTest(.{
        .root_source_file = b.path("src/cpu/registers.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_register_tests = b.addRunArtifact(register_tests);

    const memory_tests = b.addTest(.{
        .root_source_file = b.path("src/memory/memory.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_memory_tests = b.addRunArtifact(memory_tests);

    const uart_tests = b.addTest(.{
        .root_source_file = b.path("src/io/uart.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_uart_tests = b.addRunArtifact(uart_tests);

    const queue_tests = b.addTest(.{
        .root_source_file = b.path("src/async/queue.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_queue_tests = b.addRunArtifact(queue_tests);

    const boot_loader_tests = b.addTest(.{
        .root_source_file = b.path("src/boot/loader.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_boot_loader_tests = b.addRunArtifact(boot_loader_tests);

    const boot_linux_tests = b.addTest(.{
        .root_source_file = b.path("src/boot/linux.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_boot_linux_tests = b.addRunArtifact(boot_linux_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_register_tests.step);
    test_step.dependOn(&run_memory_tests.step);
    test_step.dependOn(&run_uart_tests.step);
    test_step.dependOn(&run_queue_tests.step);
    test_step.dependOn(&run_boot_loader_tests.step);
    test_step.dependOn(&run_boot_linux_tests.step);

    // ============================================
    // Integration Tests
    // ============================================

    const integration_tests = b.addTest(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    // Add emulator module dependency
    integration_tests.root_module.addImport("emulator", &lib.root_module);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Boot loader integration tests
    const boot_integration_tests = b.addTest(.{
        .root_source_file = b.path("tests/boot_test.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_boot_integration_tests = b.addRunArtifact(boot_integration_tests);

    const integ_step = b.step("test-integ", "Run integration tests");
    integ_step.dependOn(&run_integration_tests.step);
    integ_step.dependOn(&run_boot_integration_tests.step);

    // Add integration tests to main test step
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_boot_integration_tests.step);

    // ============================================
    // Documentation
    // ============================================

    const lib_docs = b.addStaticLibrary(.{
        .name = "i686-emulator",
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // ============================================
    // Clean
    // ============================================

    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.install_path).step);
    if (b.cache_root.path) |cache_path| {
        clean_step.dependOn(&b.addRemoveDirTree(cache_path).step);
    }
}
