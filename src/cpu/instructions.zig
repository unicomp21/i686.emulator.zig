//! i686 Instruction Decoder and Executor
//!
//! Implements the x86 instruction set for i686 processors.
//! Focus on instructions needed for running Linux kselftest.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const CpuError = cpu_mod.CpuError;
const Exception = cpu_mod.Exception;
const Flags = cpu_mod.Flags;

// Additional imports for tests
const memory = @import("../memory/memory.zig");
const Memory = memory.Memory;
const io_mod = @import("../io/io.zig");
const IoController = io_mod.IoController;

/// ModR/M byte decoding result
const ModRM = struct {
    mod: u2,
    reg: u3,
    rm: u3,
};

/// Decode ModR/M byte
fn decodeModRM(byte: u8) ModRM {
    return ModRM{
        .mod = @truncate((byte >> 6) & 0x3),
        .reg = @truncate((byte >> 3) & 0x7),
        .rm = @truncate(byte & 0x7),
    };
}

/// Determine if 32-bit operand size is in effect.
/// In real mode (16-bit default), the 0x66 prefix switches to 32-bit.
/// In protected mode, the D bit of the CS descriptor determines the default:
///   D=0 (16-bit): no override = 16-bit, override = 32-bit
///   D=1 (32-bit): no override = 32-bit, override = 16-bit
/// Note: VM86 mode is 16-bit like real mode.
fn use32BitOperand(cpu: *Cpu) bool {
    return switch (cpu.mode) {
        .real, .vm86 => cpu.prefix.operand_size_override,
        .protected => {
            // Check CS descriptor's D bit (size flag)
            // CS is cached at index 1
            const cs_is_32bit = cpu.seg_cache[1].flags.size;
            if (cs_is_32bit) {
                // 32-bit default: override switches to 16-bit
                return !cpu.prefix.operand_size_override;
            } else {
                // 16-bit default: override switches to 32-bit
                return cpu.prefix.operand_size_override;
            }
        },
    };
}

/// Descriptor table reference (base and limit)
const DescriptorTableRef = struct {
    base: u32,
    limit: u32,
};

/// Get the descriptor table (GDT or LDT) based on the TI bit in a selector
fn getDescriptorTable(cpu: *Cpu, selector: u16) ?DescriptorTableRef {
    const ti = (selector >> 2) & 1; // Table indicator: 0 = GDT, 1 = LDT

    if (ti == 0) {
        // Use GDT
        return DescriptorTableRef{
            .base = cpu.system.gdtr.base,
            .limit = cpu.system.gdtr.limit,
        };
    } else {
        // Use LDT - must have been loaded via LLDT
        if (cpu.system.ldtr == 0) {
            return null; // No LDT loaded
        }
        return DescriptorTableRef{
            .base = cpu.system.ldtr_base,
            .limit = cpu.system.ldtr_limit,
        };
    }
}

/// Execute instruction based on opcode
pub fn execute(cpu: *Cpu, opcode: u8) !void {
    // Record instruction in history
    cpu.recordInstruction(opcode, 0, false);

    switch (opcode) {
        // ADD r/m8, r8
        0x00 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const result = addWithFlags8(cpu, dst, src);
            try writeRM8(cpu, modrm, result);
        },

        // ADD r/m16/32, r16/32
        0x01 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = addWithFlags16(cpu, dst, src);
                try writeRM16(cpu, modrm, result);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = addWithFlags32(cpu, dst, src);
                try writeRM32(cpu, modrm, result);
            }
        },

        // ADD r8, r/m8
        0x02 => {
            const modrm = try fetchModRM(cpu);
            const dst = cpu.regs.getReg8(modrm.reg);
            const src = try readRM8(cpu, modrm);
            const result = addWithFlags8(cpu, dst, src);
            cpu.regs.setReg8(modrm.reg, result);
        },

        // ADD r16/32, r/m16/32
        0x03 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = cpu.regs.getReg16(modrm.reg);
                const src = try readRM16(cpu, modrm);
                const result = addWithFlags16(cpu, dst, src);
                cpu.regs.setReg16(modrm.reg, result);
            } else {
                const dst = cpu.regs.getReg32(modrm.reg);
                const src = try readRM32(cpu, modrm);
                const result = addWithFlags32(cpu, dst, src);
                cpu.regs.setReg32(modrm.reg, result);
            }
        },

        // NOP
        0x90 => {},

        // XCHG EAX, r32 (91-97) - exchange register with EAX
        0x91...0x97 => {
            const reg: u3 = @truncate(opcode & 0x7);
            const temp = cpu.regs.eax;
            cpu.regs.eax = cpu.regs.getReg32(reg);
            cpu.regs.setReg32(reg, temp);
        },

        // CBW/CWDE - Sign extend AL to AX or AX to EAX
        0x98 => {
            if (cpu.prefix.operand_size_override) {
                // CBW: AL -> AX
                const al: i8 = @bitCast(@as(u8, @truncate(cpu.regs.eax)));
                cpu.regs.setReg16(0, @bitCast(@as(i16, al)));
            } else {
                // CWDE: AX -> EAX
                const ax: i16 = @bitCast(@as(u16, @truncate(cpu.regs.eax)));
                cpu.regs.eax = @bitCast(@as(i32, ax));
            }
        },

        // CWD/CDQ - Sign extend AX to DX:AX or EAX to EDX:EAX
        0x99 => {
            if (cpu.prefix.operand_size_override) {
                // CWD: AX -> DX:AX
                const ax: i16 = @bitCast(@as(u16, @truncate(cpu.regs.eax)));
                cpu.regs.setReg16(2, if (ax < 0) 0xFFFF else 0x0000);
            } else {
                // CDQ: EAX -> EDX:EAX
                const eax: i32 = @bitCast(cpu.regs.eax);
                cpu.regs.edx = if (eax < 0) 0xFFFFFFFF else 0x00000000;
            }
        },

        // CALL ptr16:16/ptr16:32 - Far call (direct)
        0x9A => {
            if (cpu.prefix.operand_size_override) {
                // 16-bit: CALL ptr16:16 (offset16, selector16)
                const offset = try fetchWord(cpu);
                const selector = try fetchWord(cpu);

                // Push current CS and IP
                try cpu.push16(cpu.segments.cs);
                try cpu.push16(@truncate(cpu.eip));

                // Load new CS and IP
                cpu.segments.cs = selector;
                cpu.eip = offset;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            } else {
                // 32-bit: CALL ptr16:32 (offset32, selector16)
                const offset = try fetchDword(cpu);
                const selector = try fetchWord(cpu);

                // Push current CS and EIP
                try cpu.push16(cpu.segments.cs);
                try cpu.push(cpu.eip);

                // Load new CS and EIP
                cpu.segments.cs = selector;
                cpu.eip = offset;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            }
        },

        // WAIT/FWAIT - Wait for FPU
        0x9B => {
            // Check for pending unmasked FPU exceptions
            // For our emulator without FPU, this is a no-op
            // But it's important for Linux compatibility
        },

        // PUSHF/PUSHFD - Push flags
        0x9C => {
            if (cpu.prefix.operand_size_override) {
                // PUSHF: Push 16-bit flags
                try cpu.push16(@truncate(cpu.flags.toU32()));
            } else {
                // PUSHFD: Push 32-bit EFLAGS
                try cpu.push(cpu.flags.toU32());
            }
        },

        // POPF/POPFD - Pop flags
        0x9D => {
            if (cpu.prefix.operand_size_override) {
                // POPF: Pop 16-bit flags
                const value = try cpu.pop16();
                // Preserve upper 16 bits, update lower 16 bits
                const current = cpu.flags.toU32();
                cpu.flags.fromU32((current & 0xFFFF0000) | value);
            } else {
                // POPFD: Pop 32-bit EFLAGS
                const value = try cpu.pop();
                cpu.flags.fromU32(value);
            }
        },

        // SAHF - Store AH into flags
        0x9E => {
            const ah: u8 = @truncate(cpu.regs.eax >> 8);
            cpu.flags.carry = (ah & 0x01) != 0;
            cpu.flags.parity = (ah & 0x04) != 0;
            cpu.flags.auxiliary = (ah & 0x10) != 0;
            cpu.flags.zero = (ah & 0x40) != 0;
            cpu.flags.sign = (ah & 0x80) != 0;
        },

        // LAHF - Load AH from flags
        0x9F => {
            var ah: u8 = 0x02; // Bit 1 is always 1
            if (cpu.flags.carry) ah |= 0x01;
            if (cpu.flags.parity) ah |= 0x04;
            if (cpu.flags.auxiliary) ah |= 0x10;
            if (cpu.flags.zero) ah |= 0x40;
            if (cpu.flags.sign) ah |= 0x80;
            cpu.regs.setReg8(4, ah); // AH
        },

        // INT1/ICEBP - Ice Breakpoint
        0xF1 => {
            // Raise #DB (debug exception, vector 1)
            try handleInterrupt(cpu, 1);
        },

        // HLT
        0xF4 => cpu.halt(),

        // CMC - Complement Carry Flag
        0xF5 => {
            cpu.flags.carry = !cpu.flags.carry;
        },

        // CLC - Clear Carry Flag
        0xF8 => {
            cpu.flags.carry = false;
        },

        // STC - Set Carry Flag
        0xF9 => {
            cpu.flags.carry = true;
        },

        // MOV r8, imm8 (B0-B7)
        0xB0...0xB7 => {
            const reg: u3 = @truncate(opcode & 0x7);
            const imm = try fetchByte(cpu);
            cpu.regs.setReg8(reg, imm);
        },

        // MOV r16/r32, imm16/imm32 (B8-BF)
        0xB8...0xBF => {
            const reg: u3 = @truncate(opcode & 0x7);
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                cpu.regs.setReg16(reg, imm);
            } else {
                const imm = try fetchDword(cpu);
                cpu.regs.setReg32(reg, imm);
            }
        },

        // MOV r/m8, r8
        0x88 => {
            const modrm = try fetchModRM(cpu);
            const value = cpu.regs.getReg8(modrm.reg);
            try writeRM8(cpu, modrm, value);
        },

        // MOV r/m16/32, r16/32
        0x89 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const value = cpu.regs.getReg16(modrm.reg);
                try writeRM16(cpu, modrm, value);
            } else {
                const value = cpu.regs.getReg32(modrm.reg);
                try writeRM32(cpu, modrm, value);
            }
        },

        // MOV r8, r/m8
        0x8A => {
            const modrm = try fetchModRM(cpu);
            const value = try readRM8(cpu, modrm);
            cpu.regs.setReg8(modrm.reg, value);
        },

        // MOV r16/32, r/m16/32
        0x8B => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const value = try readRM16(cpu, modrm);
                cpu.regs.setReg16(modrm.reg, value);
            } else {
                const value = try readRM32(cpu, modrm);
                cpu.regs.setReg32(modrm.reg, value);
            }
        },

        // MOV r/m16, Sreg - Store segment register to r/m16
        0x8C => {
            const modrm = try fetchModRM(cpu);
            const seg_value = cpu.segments.getSegment(modrm.reg);
            try writeRM16(cpu, modrm, seg_value);
        },

        // LEA r16/32, m
        0x8D => {
            const modrm = try fetchModRM(cpu);
            const addr = try calculateEffectiveAddress(cpu, modrm);
            if (cpu.prefix.operand_size_override) {
                cpu.regs.setReg16(modrm.reg, @truncate(addr));
            } else {
                cpu.regs.setReg32(modrm.reg, addr);
            }
        },

        // MOV Sreg, r/m16 - Load segment register from r/m16
        0x8E => {
            const modrm = try fetchModRM(cpu);
            // Cannot load CS with this instruction
            if (modrm.reg == 1) {
                cpu.exception_error_code = 0; // #GP(0) for invalid operation
                return CpuError.GeneralProtectionFault;
            }
            const value = try readRM16(cpu, modrm);
            cpu.segments.setSegment(modrm.reg, value);

            // In protected mode, load segment descriptor into cache
            if (cpu.mode == .protected) {
                try cpu.loadSegmentDescriptor(value, modrm.reg);
            }
        },

        // MOV AL, moffs8
        0xA0 => {
            const addr = try fetchDword(cpu);
            const value = try cpu.readMemByte(addr);
            cpu.regs.setReg8(0, value);
        },

        // MOV EAX, moffs32
        0xA1 => {
            const addr = try fetchDword(cpu);
            if (cpu.prefix.operand_size_override) {
                const value = try cpu.readMemWord(addr);
                cpu.regs.setReg16(0, value);
            } else {
                const value = try cpu.readMemDword(addr);
                cpu.regs.eax = value;
            }
        },

        // MOV moffs8, AL
        0xA2 => {
            const addr = try fetchDword(cpu);
            const value: u8 = @truncate(cpu.regs.eax);
            try cpu.writeMemByte(addr, value);
        },

        // MOV moffs32, EAX
        0xA3 => {
            const addr = try fetchDword(cpu);
            if (cpu.prefix.operand_size_override) {
                try cpu.writeMemWord(addr, @truncate(cpu.regs.eax));
            } else {
                try cpu.writeMemDword(addr, cpu.regs.eax);
            }
        },

        // MOV r/m8, imm8
        0xC6 => {
            const modrm = try fetchModRM(cpu);
            // Calculate effective address first (may consume displacement bytes)
            const addr = if (modrm.mod == 3) null else try calculateEffectiveAddress(cpu, modrm);
            const imm = try fetchByte(cpu);
            if (modrm.mod == 3) {
                cpu.regs.setReg8(modrm.rm, imm);
            } else {
                try cpu.writeMemByte(addr.?, imm);
            }
        },

        // MOV r/m32, imm32
        0xC7 => {
            const modrm = try fetchModRM(cpu);
            // Calculate effective address first (may consume displacement bytes)
            const addr = if (modrm.mod == 3) null else try calculateEffectiveAddress(cpu, modrm);
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                if (modrm.mod == 3) {
                    cpu.regs.setReg16(modrm.rm, imm);
                } else {
                    try cpu.writeMemWord(addr.?, imm);
                }
            } else {
                const imm = try fetchDword(cpu);
                if (modrm.mod == 3) {
                    cpu.regs.setReg32(modrm.rm, imm);
                } else {
                    try cpu.writeMemDword(addr.?, imm);
                }
            }
        },

        // PUSH r32 (50-57)
        0x50...0x57 => {
            const reg: u3 = @truncate(opcode & 0x7);
            const value = cpu.regs.getReg32(reg);
            try cpu.push(value);
        },

        // POP r32 (58-5F)
        0x58...0x5F => {
            const reg: u3 = @truncate(opcode & 0x7);
            const value = try cpu.pop();
            cpu.regs.setReg32(reg, value);
        },

        // PUSHA/PUSHAD - Push all general-purpose registers
        0x60 => {
            if (cpu.prefix.operand_size_override) {
                // PUSHA: Push 16-bit registers in order: AX, CX, DX, BX, SP, BP, SI, DI
                const sp_temp = cpu.regs.esp; // Save SP before any pushes
                try cpu.push16(@truncate(cpu.regs.eax)); // AX
                try cpu.push16(@truncate(cpu.regs.ecx)); // CX
                try cpu.push16(@truncate(cpu.regs.edx)); // DX
                try cpu.push16(@truncate(cpu.regs.ebx)); // BX
                try cpu.push16(@truncate(sp_temp)); // SP (original value)
                try cpu.push16(@truncate(cpu.regs.ebp)); // BP
                try cpu.push16(@truncate(cpu.regs.esi)); // SI
                try cpu.push16(@truncate(cpu.regs.edi)); // DI
            } else {
                // PUSHAD: Push 32-bit registers in order: EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI
                const esp_temp = cpu.regs.esp; // Save ESP before any pushes
                try cpu.push(cpu.regs.eax); // EAX
                try cpu.push(cpu.regs.ecx); // ECX
                try cpu.push(cpu.regs.edx); // EDX
                try cpu.push(cpu.regs.ebx); // EBX
                try cpu.push(esp_temp); // ESP (original value)
                try cpu.push(cpu.regs.ebp); // EBP
                try cpu.push(cpu.regs.esi); // ESI
                try cpu.push(cpu.regs.edi); // EDI
            }
        },

        // POPA/POPAD - Pop all general-purpose registers
        0x61 => {
            if (cpu.prefix.operand_size_override) {
                // POPA: Pop 16-bit registers in reverse order: DI, SI, BP, skip SP, BX, DX, CX, AX
                cpu.regs.setReg16(7, try cpu.pop16()); // DI
                cpu.regs.setReg16(6, try cpu.pop16()); // SI
                cpu.regs.setReg16(5, try cpu.pop16()); // BP
                _ = try cpu.pop16(); // Skip SP (discard value)
                cpu.regs.setReg16(3, try cpu.pop16()); // BX
                cpu.regs.setReg16(2, try cpu.pop16()); // DX
                cpu.regs.setReg16(1, try cpu.pop16()); // CX
                cpu.regs.setReg16(0, try cpu.pop16()); // AX
            } else {
                // POPAD: Pop 32-bit registers in reverse order: EDI, ESI, EBP, skip ESP, EBX, EDX, ECX, EAX
                cpu.regs.setReg32(7, try cpu.pop()); // EDI
                cpu.regs.setReg32(6, try cpu.pop()); // ESI
                cpu.regs.setReg32(5, try cpu.pop()); // EBP
                _ = try cpu.pop(); // Skip ESP (discard value)
                cpu.regs.setReg32(3, try cpu.pop()); // EBX
                cpu.regs.setReg32(2, try cpu.pop()); // EDX
                cpu.regs.setReg32(1, try cpu.pop()); // ECX
                cpu.regs.setReg32(0, try cpu.pop()); // EAX
            }
        },


        // BOUND r16/32, m16&16/m32&32 - Check Array Index Against Bounds
        0x62 => {
            const modrm = try fetchModRM(cpu);
            if (modrm.mod == 3) {
                // BOUND requires a memory operand
                return CpuError.InvalidOpcode;
            }
            const addr = try calculateEffectiveAddress(cpu, modrm);

            if (cpu.prefix.operand_size_override) {
                // 16-bit: Check if r16 is within bounds [lower:upper] in memory
                const index: i16 = @bitCast(cpu.regs.getReg16(modrm.reg));
                const lower: i16 = @bitCast(try cpu.readMemWord(addr));
                const upper: i16 = @bitCast(try cpu.readMemWord(addr + 2));

                // Raise #BR if index < lower or index > upper (for word/dword, it's upper + operand_size - 1)
                if (index < lower or index > upper) {
                    // In a real CPU, this would raise interrupt #BR (vector 5)
                    // For now, we return GP(0) as a placeholder
                    cpu.exception_error_code = 0;
                    return CpuError.GeneralProtectionFault;
                }
            } else {
                // 32-bit: Check if r32 is within bounds [lower:upper] in memory
                const index: i32 = @bitCast(cpu.regs.getReg32(modrm.reg));
                const lower: i32 = @bitCast(try cpu.readMemDword(addr));
                const upper: i32 = @bitCast(try cpu.readMemDword(addr + 4));

                if (index < lower or index > upper) {
                    cpu.exception_error_code = 0;
                    return CpuError.GeneralProtectionFault;
                }
            }
        },

        // ARPL r/m16, r16 - Adjust RPL Field of Segment Selector
        0x63 => {
            // ARPL is only valid in protected mode
            if (cpu.mode != .protected) {
                return CpuError.InvalidOpcode;
            }

            const modrm = try fetchModRM(cpu);
            // Always 16-bit operands, ignore operand size prefix
            const dest_selector = try readRM16(cpu, modrm);
            const src_selector = cpu.regs.getReg16(modrm.reg);

            // Extract RPL (bits 0-1) from both selectors
            const dest_rpl = dest_selector & 0x3;
            const src_rpl = src_selector & 0x3;

            if (dest_rpl < src_rpl) {
                // Adjust dest RPL to match src RPL
                const new_selector = (dest_selector & 0xFFFC) | src_rpl;
                try writeRM16(cpu, modrm, new_selector);
                cpu.flags.zero = true;
            } else {
                cpu.flags.zero = false;
            }
        },
        // IMUL r16/32, r/m16/32, imm16/32 - Three-operand signed multiply
        0x69 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                // 16-bit: IMUL r16, r/m16, imm16
                const rm_value: i16 = @bitCast(try readRM16(cpu, modrm));
                const imm_value: i16 = @bitCast(try fetchWord(cpu));
                const result: i32 = @as(i32, rm_value) * @as(i32, imm_value);
                const truncated: i16 = @truncate(result);

                // Set CF and OF if result doesn't fit in 16 bits (sign extension differs)
                const overflow = result != @as(i32, truncated);
                cpu.flags.carry = overflow;
                cpu.flags.overflow = overflow;

                cpu.regs.setReg16(modrm.reg, @bitCast(truncated));
            } else {
                // 32-bit: IMUL r32, r/m32, imm32
                const rm_value: i32 = @bitCast(try readRM32(cpu, modrm));
                const imm_value: i32 = @bitCast(try fetchDword(cpu));
                const result: i64 = @as(i64, rm_value) * @as(i64, imm_value);
                const truncated: i32 = @truncate(result);

                // Set CF and OF if result doesn't fit in 32 bits (sign extension differs)
                const overflow = result != @as(i64, truncated);
                cpu.flags.carry = overflow;
                cpu.flags.overflow = overflow;

                cpu.regs.setReg32(modrm.reg, @bitCast(truncated));
            }
        },

        // IMUL r16/32, r/m16/32, imm8 - Three-operand signed multiply with sign-extended imm8
        0x6B => {
            const modrm = try fetchModRM(cpu);
            const imm8: i8 = @bitCast(try fetchByte(cpu));

            if (cpu.prefix.operand_size_override) {
                // 16-bit: IMUL r16, r/m16, imm8 (sign-extended to 16 bits)
                const rm_value: i16 = @bitCast(try readRM16(cpu, modrm));
                const imm_value: i16 = imm8; // Sign extension from i8 to i16
                const result: i32 = @as(i32, rm_value) * @as(i32, imm_value);
                const truncated: i16 = @truncate(result);

                // Set CF and OF if result doesn't fit in 16 bits (sign extension differs)
                const overflow = result != @as(i32, truncated);
                cpu.flags.carry = overflow;
                cpu.flags.overflow = overflow;

                cpu.regs.setReg16(modrm.reg, @bitCast(truncated));
            } else {
                // 32-bit: IMUL r32, r/m32, imm8 (sign-extended to 32 bits)
                const rm_value: i32 = @bitCast(try readRM32(cpu, modrm));
                const imm_value: i32 = imm8; // Sign extension from i8 to i32
                const result: i64 = @as(i64, rm_value) * @as(i64, imm_value);
                const truncated: i32 = @truncate(result);

                // Set CF and OF if result doesn't fit in 32 bits (sign extension differs)
                const overflow = result != @as(i64, truncated);
                cpu.flags.carry = overflow;
                cpu.flags.overflow = overflow;

                cpu.regs.setReg32(modrm.reg, @bitCast(truncated));
            }
        },

        // INSB - Input byte from port DX to ES:[EDI]
        0x6C => {
            try execIns(cpu, 1);
        },

        // INSW/INSD - Input word/dword from port DX to ES:[EDI]
        0x6D => {
            if (cpu.prefix.operand_size_override) {
                try execIns(cpu, 2);
            } else {
                try execIns(cpu, 4);
            }
        },

        // OUTSB - Output byte from DS:[ESI] to port DX
        0x6E => {
            try execOuts(cpu, 1);
        },

        // OUTSW/OUTSD - Output word/dword from DS:[ESI] to port DX
        0x6F => {
            if (cpu.prefix.operand_size_override) {
                try execOuts(cpu, 2);
            } else {
                try execOuts(cpu, 4);
            }
        },

        // ADD AL, imm8
        0x04 => {
            const imm = try fetchByte(cpu);
            const result = addWithFlags8(cpu, @truncate(cpu.regs.eax), imm);
            cpu.regs.setReg8(0, result);
        },

        // ADD EAX, imm32
        0x05 => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                const result = addWithFlags16(cpu, @truncate(cpu.regs.eax), imm);
                cpu.regs.setReg16(0, result);
            } else {
                const imm = try fetchDword(cpu);
                const result = addWithFlags32(cpu, cpu.regs.eax, imm);
                cpu.regs.eax = result;
            }
        },

        // OR AL, imm8
        0x0C => {
            const imm = try fetchByte(cpu);
            const result = @as(u8, @truncate(cpu.regs.eax)) | imm;
            cpu.flags.updateArithmetic8(result, false, false);
            cpu.regs.setReg8(0, result);
        },

        // OR EAX, imm32
        0x0D => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                const result = @as(u16, @truncate(cpu.regs.eax)) | imm;
                cpu.flags.updateArithmetic16(result, false, false);
                cpu.regs.setReg16(0, result);
            } else {
                const imm = try fetchDword(cpu);
                const result = cpu.regs.eax | imm;
                cpu.flags.updateArithmetic32(result, false, false);
                cpu.regs.eax = result;
            }
        },

        // OR r/m8, r8
        0x08 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const result = dst | src;
            cpu.flags.updateArithmetic8(result, false, false);
            try writeRM8(cpu, modrm, result);
        },

        // OR r/m32, r32
        0x09 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = dst | src;
                cpu.flags.updateArithmetic16(result, false, false);
                try writeRM16(cpu, modrm, result);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = dst | src;
                cpu.flags.updateArithmetic32(result, false, false);
                try writeRM32(cpu, modrm, result);
            }
        },

        // ADC r/m8, r8
        0x10 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const result = adcWithFlags8(cpu, dst, src);
            try writeRM8(cpu, modrm, result);
        },

        // ADC r/m16/32, r16/32
        0x11 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = adcWithFlags16(cpu, dst, src);
                try writeRM16(cpu, modrm, result);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = adcWithFlags32(cpu, dst, src);
                try writeRM32(cpu, modrm, result);
            }
        },

        // ADC r8, r/m8
        0x12 => {
            const modrm = try fetchModRM(cpu);
            const dst = cpu.regs.getReg8(modrm.reg);
            const src = try readRM8(cpu, modrm);
            const result = adcWithFlags8(cpu, dst, src);
            cpu.regs.setReg8(modrm.reg, result);
        },

        // ADC r16/32, r/m16/32
        0x13 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = cpu.regs.getReg16(modrm.reg);
                const src = try readRM16(cpu, modrm);
                const result = adcWithFlags16(cpu, dst, src);
                cpu.regs.setReg16(modrm.reg, result);
            } else {
                const dst = cpu.regs.getReg32(modrm.reg);
                const src = try readRM32(cpu, modrm);
                const result = adcWithFlags32(cpu, dst, src);
                cpu.regs.setReg32(modrm.reg, result);
            }
        },

        // ADC AL, imm8
        0x14 => {
            const imm = try fetchByte(cpu);
            const result = adcWithFlags8(cpu, @truncate(cpu.regs.eax), imm);
            cpu.regs.setReg8(0, result);
        },

        // ADC EAX, imm16/32
        0x15 => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                const result = adcWithFlags16(cpu, @truncate(cpu.regs.eax), imm);
                cpu.regs.setReg16(0, result);
            } else {
                const imm = try fetchDword(cpu);
                const result = adcWithFlags32(cpu, cpu.regs.eax, imm);
                cpu.regs.eax = result;
            }
        },

        // SBB r/m8, r8
        0x18 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const result = sbbWithFlags8(cpu, dst, src);
            try writeRM8(cpu, modrm, result);
        },

        // SBB r/m16/32, r16/32
        0x19 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = sbbWithFlags16(cpu, dst, src);
                try writeRM16(cpu, modrm, result);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = sbbWithFlags32(cpu, dst, src);
                try writeRM32(cpu, modrm, result);
            }
        },

        // SBB r8, r/m8
        0x1A => {
            const modrm = try fetchModRM(cpu);
            const dst = cpu.regs.getReg8(modrm.reg);
            const src = try readRM8(cpu, modrm);
            const result = sbbWithFlags8(cpu, dst, src);
            cpu.regs.setReg8(modrm.reg, result);
        },

        // SBB r16/32, r/m16/32
        0x1B => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = cpu.regs.getReg16(modrm.reg);
                const src = try readRM16(cpu, modrm);
                const result = sbbWithFlags16(cpu, dst, src);
                cpu.regs.setReg16(modrm.reg, result);
            } else {
                const dst = cpu.regs.getReg32(modrm.reg);
                const src = try readRM32(cpu, modrm);
                const result = sbbWithFlags32(cpu, dst, src);
                cpu.regs.setReg32(modrm.reg, result);
            }
        },

        // SBB AL, imm8
        0x1C => {
            const imm = try fetchByte(cpu);
            const result = sbbWithFlags8(cpu, @truncate(cpu.regs.eax), imm);
            cpu.regs.setReg8(0, result);
        },

        // SBB EAX, imm16/32
        0x1D => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                const result = sbbWithFlags16(cpu, @truncate(cpu.regs.eax), imm);
                cpu.regs.setReg16(0, result);
            } else {
                const imm = try fetchDword(cpu);
                const result = sbbWithFlags32(cpu, cpu.regs.eax, imm);
                cpu.regs.eax = result;
            }
        },

        // AND AL, imm8
        0x24 => {
            const imm = try fetchByte(cpu);
            const result = @as(u8, @truncate(cpu.regs.eax)) & imm;
            cpu.flags.updateArithmetic8(result, false, false);
            cpu.regs.setReg8(0, result);
        },

        // AND EAX, imm32
        0x25 => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                const result = @as(u16, @truncate(cpu.regs.eax)) & imm;
                cpu.flags.updateArithmetic16(result, false, false);
                cpu.regs.setReg16(0, result);
            } else {
                const imm = try fetchDword(cpu);
                const result = cpu.regs.eax & imm;
                cpu.flags.updateArithmetic32(result, false, false);
                cpu.regs.eax = result;
            }
        },

        // DAA - Decimal Adjust AL after Addition
        0x27 => {
            var al = @as(u8, @truncate(cpu.regs.eax));
            const old_cf = cpu.flags.carry;
            const old_al = al;

            if ((al & 0x0F) > 9 or cpu.flags.auxiliary) {
                al +%= 6;
                cpu.flags.carry = old_cf or (al < 6);
                cpu.flags.auxiliary = true;
            } else {
                cpu.flags.auxiliary = false;
            }

            if (old_al > 0x99 or old_cf) {
                al +%= 0x60;
                cpu.flags.carry = true;
            } else {
                cpu.flags.carry = false;
            }

            cpu.regs.setReg8(0, al);
            // Update flags
            cpu.flags.zero = al == 0;
            cpu.flags.sign = (al & 0x80) != 0;
            cpu.flags.parity = @popCount(al) & 1 == 0;
        },

        // AND r/m8, r8
        0x20 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const result = dst & src;
            cpu.flags.updateArithmetic8(result, false, false);
            try writeRM8(cpu, modrm, result);
        },

        // AND r/m32, r32
        0x21 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = dst & src;
                cpu.flags.updateArithmetic16(result, false, false);
                try writeRM16(cpu, modrm, result);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = dst & src;
                cpu.flags.updateArithmetic32(result, false, false);
                try writeRM32(cpu, modrm, result);
            }
        },

        // SUB AL, imm8
        0x2C => {
            const imm = try fetchByte(cpu);
            const result = subWithFlags8(cpu, @truncate(cpu.regs.eax), imm);
            cpu.regs.setReg8(0, result);
        },

        // SUB EAX, imm32
        0x2D => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                const result = subWithFlags16(cpu, @truncate(cpu.regs.eax), imm);
                cpu.regs.setReg16(0, result);
            } else {
                const imm = try fetchDword(cpu);
                const result = subWithFlags32(cpu, cpu.regs.eax, imm);
                cpu.regs.eax = result;
            }
        },

        // DAS - Decimal Adjust AL after Subtraction
        0x2F => {
            var al = @as(u8, @truncate(cpu.regs.eax));
            const old_cf = cpu.flags.carry;
            const old_al = al;

            if ((al & 0x0F) > 9 or cpu.flags.auxiliary) {
                al -%= 6;
                cpu.flags.carry = old_cf or (old_al < 6);
                cpu.flags.auxiliary = true;
            } else {
                cpu.flags.auxiliary = false;
            }

            if (old_al > 0x99 or old_cf) {
                al -%= 0x60;
                cpu.flags.carry = true;
            } else {
                cpu.flags.carry = false;
            }

            cpu.regs.setReg8(0, al);
            // Update flags
            cpu.flags.zero = al == 0;
            cpu.flags.sign = (al & 0x80) != 0;
            cpu.flags.parity = @popCount(al) & 1 == 0;
        },


        // AAA - ASCII Adjust AL after Addition
        0x37 => {
            var al = @as(u8, @truncate(cpu.regs.eax));
            var ah = @as(u8, @truncate(cpu.regs.eax >> 8));

            if ((al & 0x0F) > 9 or cpu.flags.auxiliary) {
                al +%= 6;
                ah +%= 1;
                cpu.flags.auxiliary = true;
                cpu.flags.carry = true;
            } else {
                cpu.flags.auxiliary = false;
                cpu.flags.carry = false;
            }

            al &= 0x0F;
            cpu.regs.setReg8(0, al); // AL
            cpu.regs.setReg8(4, ah); // AH
        },

        // CMP r/m8, r8
        0x38 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            _ = subWithFlags8(cpu, dst, src);
        },

        // CMP r/m16/32, r16/32
        0x39 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                _ = subWithFlags16(cpu, dst, src);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                _ = subWithFlags32(cpu, dst, src);
            }
        },

        // CMP r8, r/m8
        0x3A => {
            const modrm = try fetchModRM(cpu);
            const dst = cpu.regs.getReg8(modrm.reg);
            const src = try readRM8(cpu, modrm);
            _ = subWithFlags8(cpu, dst, src);
        },

        // CMP r16/32, r/m16/32
        0x3B => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = cpu.regs.getReg16(modrm.reg);
                const src = try readRM16(cpu, modrm);
                _ = subWithFlags16(cpu, dst, src);
            } else {
                const dst = cpu.regs.getReg32(modrm.reg);
                const src = try readRM32(cpu, modrm);
                _ = subWithFlags32(cpu, dst, src);
            }
        },

        // CMP AL, imm8
        0x3C => {
            const imm = try fetchByte(cpu);
            _ = subWithFlags8(cpu, @truncate(cpu.regs.eax), imm);
        },

        // CMP EAX, imm32
        0x3D => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                _ = subWithFlags16(cpu, @truncate(cpu.regs.eax), imm);
            } else {
                const imm = try fetchDword(cpu);
                _ = subWithFlags32(cpu, cpu.regs.eax, imm);
            }
        },

        // AAS - ASCII Adjust AL after Subtraction
        0x3F => {
            var al = @as(u8, @truncate(cpu.regs.eax));
            var ah = @as(u8, @truncate(cpu.regs.eax >> 8));

            if ((al & 0x0F) > 9 or cpu.flags.auxiliary) {
                al -%= 6;
                ah -%= 1;
                cpu.flags.auxiliary = true;
                cpu.flags.carry = true;
            } else {
                cpu.flags.auxiliary = false;
                cpu.flags.carry = false;
            }

            al &= 0x0F;
            cpu.regs.setReg8(0, al); // AL
            cpu.regs.setReg8(4, ah); // AH
        },

        // XCHG r/m8, r8
        0x86 => {
            const modrm = try fetchModRM(cpu);
            const reg_val = cpu.regs.getReg8(modrm.reg);
            const rm_val = try readRM8(cpu, modrm);

            cpu.regs.setReg8(modrm.reg, rm_val);
            try writeRM8(cpu, modrm, reg_val);
        },

        // XCHG r/m32, r32
        0x87 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const reg_val = cpu.regs.getReg16(modrm.reg);
                const rm_val = try readRM16(cpu, modrm);
                cpu.regs.setReg16(modrm.reg, rm_val);
                try writeRM16(cpu, modrm, reg_val);
            } else {
                const reg_val = cpu.regs.getReg32(modrm.reg);
                const rm_val = try readRM32(cpu, modrm);
                cpu.regs.setReg32(modrm.reg, rm_val);
                try writeRM32(cpu, modrm, reg_val);
            }
        },

        // TEST r/m8, r8
        0x84 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const result = dst & src;
            cpu.flags.updateArithmetic8(result, false, false);
        },

        // TEST r/m16/32, r16/32
        0x85 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = dst & src;
                cpu.flags.updateArithmetic16(result, false, false);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = dst & src;
                cpu.flags.updateArithmetic32(result, false, false);
            }
        },

        // TEST AL, imm8
        0xA8 => {
            const imm = try fetchByte(cpu);
            const result = @as(u8, @truncate(cpu.regs.eax)) & imm;
            cpu.flags.updateArithmetic8(result, false, false);
        },

        // TEST EAX, imm32
        0xA9 => {
            if (cpu.prefix.operand_size_override) {
                const imm = try fetchWord(cpu);
                const result = @as(u16, @truncate(cpu.regs.eax)) & imm;
                cpu.flags.updateArithmetic16(result, false, false);
            } else {
                const imm = try fetchDword(cpu);
                const result = cpu.regs.eax & imm;
                cpu.flags.updateArithmetic32(result, false, false);
            }
        },

        // XOR r/m8, r8
        0x30 => {
            const modrm = try fetchModRM(cpu);
            const dst = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const result = dst ^ src;
            cpu.flags.updateArithmetic8(result, false, false);
            try writeRM8(cpu, modrm, result);
        },

        // XOR r/m32, r32
        0x31 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                const dst = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = dst ^ src;
                cpu.flags.updateArithmetic16(result, false, false);
                try writeRM16(cpu, modrm, result);
            } else {
                const dst = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = dst ^ src;
                cpu.flags.updateArithmetic32(result, false, false);
                try writeRM32(cpu, modrm, result);
            }
        },

        // INC r32 (40-47)
        0x40...0x47 => {
            const reg: u3 = @truncate(opcode & 0x7);
            const value = cpu.regs.getReg32(reg);
            const result = value +% 1;
            const overflow = (value & 0x80000000) == 0 and (result & 0x80000000) != 0;
            cpu.flags.updateArithmetic32(result, cpu.flags.carry, overflow);
            cpu.regs.setReg32(reg, result);
        },

        // DEC r32 (48-4F)
        0x48...0x4F => {
            const reg: u3 = @truncate(opcode & 0x7);
            const value = cpu.regs.getReg32(reg);
            const result = value -% 1;
            const overflow = (value & 0x80000000) != 0 and (result & 0x80000000) == 0;
            cpu.flags.updateArithmetic32(result, cpu.flags.carry, overflow);
            cpu.regs.setReg32(reg, result);
        },

        // JMP rel8
        0xEB => {
            const rel = try fetchByte(cpu);
            const offset: i8 = @bitCast(rel);
            cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
        },

        // JMP rel16/32
        0xE9 => {
            if (cpu.prefix.operand_size_override) {
                const rel = try fetchWord(cpu);
                const offset: i16 = @bitCast(rel);
                cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
            } else {
                const rel = try fetchDword(cpu);
                const offset: i32 = @bitCast(rel);
                cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
            }
        },

        // JMP ptr16:16/ptr16:32 - Far jump (direct)
        0xEA => {
            if (use32BitOperand(cpu)) {
                // 32-bit: JMP ptr16:32 (offset32, selector16)
                const offset = try fetchDword(cpu);
                const selector = try fetchWord(cpu);

                // Load new CS and EIP
                cpu.segments.cs = selector;
                cpu.eip = offset;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            } else {
                // 16-bit: JMP ptr16:16 (offset16, selector16)
                const offset = try fetchWord(cpu);
                const selector = try fetchWord(cpu);

                // Load new CS and IP
                cpu.segments.cs = selector;
                cpu.eip = offset;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            }
        },

        // Jcc rel8 (short conditional jumps)
        0x70 => try jccRel8(cpu, cpu.flags.overflow), // JO
        0x71 => try jccRel8(cpu, !cpu.flags.overflow), // JNO
        0x72 => try jccRel8(cpu, cpu.flags.carry), // JB/JNAE/JC
        0x73 => try jccRel8(cpu, !cpu.flags.carry), // JNB/JAE/JNC
        0x74 => try jccRel8(cpu, cpu.flags.zero), // JE/JZ
        0x75 => try jccRel8(cpu, !cpu.flags.zero), // JNE/JNZ
        0x76 => try jccRel8(cpu, cpu.flags.carry or cpu.flags.zero), // JBE/JNA
        0x77 => try jccRel8(cpu, !cpu.flags.carry and !cpu.flags.zero), // JNBE/JA
        0x78 => try jccRel8(cpu, cpu.flags.sign), // JS
        0x79 => try jccRel8(cpu, !cpu.flags.sign), // JNS
        0x7A => try jccRel8(cpu, cpu.flags.parity), // JP/JPE
        0x7B => try jccRel8(cpu, !cpu.flags.parity), // JNP/JPO
        0x7C => try jccRel8(cpu, cpu.flags.sign != cpu.flags.overflow), // JL/JNGE
        0x7D => try jccRel8(cpu, cpu.flags.sign == cpu.flags.overflow), // JGE/JNL
        0x7E => try jccRel8(cpu, cpu.flags.zero or (cpu.flags.sign != cpu.flags.overflow)), // JLE/JNG
        0x7F => try jccRel8(cpu, !cpu.flags.zero and (cpu.flags.sign == cpu.flags.overflow)), // JNLE/JG

        // CALL rel32
        0xE8 => {
            const rel = try fetchDword(cpu);
            const offset: i32 = @bitCast(rel);
            try cpu.push(cpu.eip);
            cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
        },

        // LES r16/32, m16:16/m16:32 - Load far pointer from memory into ES:r
        0xC4 => {
            const modrm = try fetchModRM(cpu);
            if (modrm.mod == 3) {
                // Invalid: LES requires a memory operand
                return CpuError.InvalidOpcode;
            }
            const addr = try calculateEffectiveAddress(cpu, modrm);

            if (cpu.prefix.operand_size_override) {
                // m16:16 - Load 16-bit offset and 16-bit segment
                const offset_val = try cpu.readMemWord(addr);
                const segment = try cpu.readMemWord(addr + 2);
                cpu.regs.setReg16(modrm.reg, offset_val);
                cpu.segments.es = segment;
            } else {
                // m16:32 - Load 32-bit offset and 16-bit segment
                const offset_val = try cpu.readMemDword(addr);
                const segment = try cpu.readMemWord(addr + 4);
                cpu.regs.setReg32(modrm.reg, offset_val);
                cpu.segments.es = segment;
            }

            // In protected mode, load segment descriptor into cache
            if (cpu.mode == .protected) {
                try cpu.loadSegmentDescriptor(cpu.segments.es, 0); // ES is index 0
            }
        },

        // LDS r16/32, m16:16/m16:32 - Load far pointer from memory into DS:r
        0xC5 => {
            const modrm = try fetchModRM(cpu);
            if (modrm.mod == 3) {
                // Invalid: LDS requires a memory operand
                return CpuError.InvalidOpcode;
            }
            const addr = try calculateEffectiveAddress(cpu, modrm);

            if (cpu.prefix.operand_size_override) {
                // m16:16 - Load 16-bit offset and 16-bit segment
                const offset_val = try cpu.readMemWord(addr);
                const segment = try cpu.readMemWord(addr + 2);
                cpu.regs.setReg16(modrm.reg, offset_val);
                cpu.segments.ds = segment;
            } else {
                // m16:32 - Load 32-bit offset and 16-bit segment
                const offset_val = try cpu.readMemDword(addr);
                const segment = try cpu.readMemWord(addr + 4);
                cpu.regs.setReg32(modrm.reg, offset_val);
                cpu.segments.ds = segment;
            }

            // In protected mode, load segment descriptor into cache
            if (cpu.mode == .protected) {
                try cpu.loadSegmentDescriptor(cpu.segments.ds, 3); // DS is index 3
            }
        },

        // RET
        0xC3 => {
            cpu.eip = try cpu.pop();
        },

        // RET imm16
        0xC2 => {
            const imm = try fetchWord(cpu);
            cpu.eip = try cpu.pop();
            cpu.regs.esp +%= imm;
        },

        // RETF - Far return
        0xCB => {
            if (cpu.prefix.operand_size_override) {
                // 16-bit: Pop IP and CS
                const new_ip = try cpu.pop16();
                const new_cs = try cpu.pop16();

                cpu.eip = new_ip;
                cpu.segments.cs = new_cs;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            } else {
                // 32-bit: Pop EIP and CS
                const new_eip = try cpu.pop();
                const new_cs = try cpu.pop16();

                cpu.eip = new_eip;
                cpu.segments.cs = new_cs;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            }
        },

        // RETF imm16 - Far return with stack cleanup
        0xCA => {
            const imm = try fetchWord(cpu);

            if (cpu.prefix.operand_size_override) {
                // 16-bit: Pop IP and CS, then adjust stack
                const new_ip = try cpu.pop16();
                const new_cs = try cpu.pop16();

                cpu.eip = new_ip;
                cpu.segments.cs = new_cs;
                cpu.regs.esp +%= imm;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            } else {
                // 32-bit: Pop EIP and CS, then adjust stack
                const new_eip = try cpu.pop();
                const new_cs = try cpu.pop16();

                cpu.eip = new_eip;
                cpu.segments.cs = new_cs;
                cpu.regs.esp +%= imm;

                // In protected mode, load segment descriptor into cache
                if (cpu.mode == .protected) {
                    try cpu.loadSegmentDescriptor(cpu.segments.cs, 1); // CS is index 1
                }
            }
        },

        // ENTER - High-level procedure entry (create stack frame)
        0xC8 => {
            const alloc_size = try fetchWord(cpu);
            const nesting_level = @min(try fetchByte(cpu), 31);

            if (cpu.prefix.operand_size_override) {
                // 16-bit: ENTER imm16, imm8
                const bp = cpu.regs.getReg16(5);
                try cpu.push16(bp);
                const frame_ptr = cpu.regs.getReg16(4); // sp

                if (nesting_level > 0) {
                    var level: u8 = 1;
                    while (level < nesting_level) : (level += 1) {
                        const offset = @as(u16, level) *% 2;
                        const addr = cpu.getEffectiveAddress(cpu.segments.ss, @as(u32, bp -% offset));
                        const value = try cpu.readMemWord(addr);
                        try cpu.push16(value);
                    }
                    try cpu.push16(frame_ptr);
                }

                cpu.regs.setReg16(5, frame_ptr); // bp = frame_ptr
                cpu.regs.setReg16(4, cpu.regs.getReg16(4) -% alloc_size); // sp -= alloc_size
            } else {
                // 32-bit: ENTER imm16, imm8
                const ebp = cpu.regs.ebp;
                try cpu.push(ebp);
                const frame_ptr = cpu.regs.esp;

                if (nesting_level > 0) {
                    var level: u8 = 1;
                    while (level < nesting_level) : (level += 1) {
                        const offset = @as(u32, level) *% 4;
                        const addr = cpu.getEffectiveAddress(cpu.segments.ss, ebp -% offset);
                        const value = try cpu.readMemDword(addr);
                        try cpu.push(value);
                    }
                    try cpu.push(frame_ptr);
                }

                cpu.regs.ebp = frame_ptr;
                cpu.regs.esp -%= alloc_size;
            }
        },

        // LEAVE - High-level procedure exit (mov esp, ebp; pop ebp)
        0xC9 => {
            if (cpu.prefix.operand_size_override) {
                // 16-bit: mov sp, bp; pop bp
                cpu.regs.setReg16(4, cpu.regs.getReg16(5)); // sp = bp
                const value = try cpu.pop16();
                cpu.regs.setReg16(5, value); // bp
            } else {
                // 32-bit: mov esp, ebp; pop ebp
                cpu.regs.esp = cpu.regs.ebp;
                cpu.regs.ebp = try cpu.pop();
            }
        },

        // INT3 - Breakpoint
        0xCC => {
            // Raise #BP (breakpoint exception, vector 3)
            try handleInterrupt(cpu, 3);
        },

        // INT imm8
        0xCD => {
            const vector = try fetchByte(cpu);
            try handleInterrupt(cpu, vector);
        },

        // INTO - Interrupt on overflow
        0xCE => {
            // If OF flag is set, raise INT 4
            if (cpu.flags.overflow) {
                try handleInterrupt(cpu, 4);
            }
        },

        // IRET/IRETD - Return from interrupt
        0xCF => {
            // Pop EIP, CS, EFLAGS from stack (in that order)
            // Handle both 16-bit (IRET) and 32-bit (IRETD) based on operand size
            if (cpu.prefix.operand_size_override) {
                // 16-bit: pop IP, CS, FLAGS
                const new_ip = try cpu.pop16();
                const new_cs = try cpu.pop16();
                const new_flags = try cpu.pop16();

                cpu.eip = new_ip;
                cpu.segments.cs = new_cs;
                cpu.flags.fromU32(@as(u32, new_flags));
            } else {
                // 32-bit: pop EIP, CS, EFLAGS
                const new_eip = try cpu.pop();
                const new_cs_u32 = try cpu.pop();
                const new_eflags = try cpu.pop();

                cpu.eip = new_eip;
                cpu.segments.cs = @truncate(new_cs_u32);
                cpu.flags.fromU32(new_eflags);
            }
        },

        // LOOPNE/LOOPNZ - Loop while not equal/not zero
        0xE0 => {
            const rel = try fetchByte(cpu);
            if (cpu.prefix.address_size_override) {
                const cx = cpu.regs.getReg16(1) -% 1;
                cpu.regs.setReg16(1, cx);
                if (cx != 0 and !cpu.flags.zero) {
                    const offset: i8 = @bitCast(rel);
                    cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
                }
            } else {
                cpu.regs.ecx -%= 1;
                if (cpu.regs.ecx != 0 and !cpu.flags.zero) {
                    const offset: i8 = @bitCast(rel);
                    cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
                }
            }
        },

        // LOOPE/LOOPZ - Loop while equal/zero
        0xE1 => {
            const rel = try fetchByte(cpu);
            if (cpu.prefix.address_size_override) {
                const cx = cpu.regs.getReg16(1) -% 1;
                cpu.regs.setReg16(1, cx);
                if (cx != 0 and cpu.flags.zero) {
                    const offset: i8 = @bitCast(rel);
                    cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
                }
            } else {
                cpu.regs.ecx -%= 1;
                if (cpu.regs.ecx != 0 and cpu.flags.zero) {
                    const offset: i8 = @bitCast(rel);
                    cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
                }
            }
        },

        // LOOP - Loop
        0xE2 => {
            const rel = try fetchByte(cpu);
            if (cpu.prefix.address_size_override) {
                const cx = cpu.regs.getReg16(1) -% 1;
                cpu.regs.setReg16(1, cx);
                if (cx != 0) {
                    const offset: i8 = @bitCast(rel);
                    cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
                }
            } else {
                cpu.regs.ecx -%= 1;
                if (cpu.regs.ecx != 0) {
                    const offset: i8 = @bitCast(rel);
                    cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
                }
            }
        },

        // JECXZ/JCXZ - Jump if ECX/CX is zero
        0xE3 => {
            const rel = try fetchByte(cpu);
            const should_jump = if (cpu.prefix.address_size_override)
                cpu.regs.getReg16(1) == 0 // JCXZ: test CX
            else
                cpu.regs.ecx == 0; // JECXZ: test ECX

            if (should_jump) {
                const offset: i8 = @bitCast(rel);
                cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
            }
        },

        // IN AL, imm8
        0xE4 => {
            const port = try fetchByte(cpu);
            const value = try cpu.inByte(port);
            cpu.regs.setReg8(0, value);
        },

        // IN AL, DX
        0xEC => {
            const port: u16 = @truncate(cpu.regs.edx);
            const value = try cpu.inByte(port);
            cpu.regs.setReg8(0, value);
        },

        // OUT imm8, AL
        0xE6 => {
            const port = try fetchByte(cpu);
            const value: u8 = @truncate(cpu.regs.eax);
            try cpu.outByte(port, value);
        },

        // OUT DX, AL
        0xEE => {
            const port: u16 = @truncate(cpu.regs.edx);
            const value: u8 = @truncate(cpu.regs.eax);
            try cpu.outByte(port, value);
        },

        // CLI
        0xFA => {
            cpu.flags.interrupt = false;
        },

        // STI
        0xFB => {
            cpu.flags.interrupt = true;
        },

        // CLD
        0xFC => {
            cpu.flags.direction = false;
        },

        // STD
        0xFD => {
            cpu.flags.direction = true;
        },

        // MOVSB - Move string byte
        0xA4 => {
            try execMovs(cpu, 1);
        },

        // MOVSD - Move string dword
        0xA5 => {
            if (cpu.prefix.operand_size_override) {
                try execMovs(cpu, 2);
            } else {
                try execMovs(cpu, 4);
            }
        },

        // CMPSB - Compare string byte
        0xA6 => {
            try execCmps(cpu, 1);
        },

        // CMPSD - Compare string dword
        0xA7 => {
            if (cpu.prefix.operand_size_override) {
                try execCmps(cpu, 2);
            } else {
                try execCmps(cpu, 4);
            }
        },

        // STOSB - Store string byte
        0xAA => {
            try execStos(cpu, 1);
        },

        // STOSD - Store string dword
        0xAB => {
            if (cpu.prefix.operand_size_override) {
                try execStos(cpu, 2);
            } else {
                try execStos(cpu, 4);
            }
        },

        // LODSB - Load string byte
        0xAC => {
            try execLods(cpu, 1);
        },

        // LODSD - Load string dword
        0xAD => {
            if (cpu.prefix.operand_size_override) {
                try execLods(cpu, 2);
            } else {
                try execLods(cpu, 4);
            }
        },

        // SCASB - Scan string byte
        0xAE => {
            try execScas(cpu, 1);
        },

        // SCASD - Scan string dword
        0xAF => {
            if (cpu.prefix.operand_size_override) {
                try execScas(cpu, 2);
            } else {
                try execScas(cpu, 4);
            }
        },

        // Two-byte opcodes (0F prefix)
        0x0F => {
            const opcode2 = try fetchByte(cpu);
            // Update history with full two-byte opcode
            cpu.instr_history[(cpu.instr_history_pos + 31) % 32].opcode2 = opcode2;
            cpu.instr_history[(cpu.instr_history_pos + 31) % 32].is_two_byte = true;
            try executeTwoByteOpcode(cpu, opcode2);
        },

        // Group 1 (80-83)
        0x80, 0x81, 0x82, 0x83 => {
            try executeGroup1(cpu, opcode);
        },


        // AAM - ASCII Adjust AX after Multiply
        0xD4 => {
            const base = try fetchByte(cpu);
            var al = @as(u8, @truncate(cpu.regs.eax));

            if (base == 0) {
                return CpuError.DivisionByZero;
            }

            const ah = al / base;
            al = al % base;

            cpu.regs.setReg8(0, al); // AL
            cpu.regs.setReg8(4, ah); // AH

            // Update flags
            cpu.flags.zero = al == 0;
            cpu.flags.sign = (al & 0x80) != 0;
            cpu.flags.parity = @popCount(al) & 1 == 0;
            // CF, OF, AF are undefined
        },

        // AAD - ASCII Adjust AX before Division
        0xD5 => {
            const base = try fetchByte(cpu);
            var al = @as(u8, @truncate(cpu.regs.eax));
            const ah = @as(u8, @truncate(cpu.regs.eax >> 8));

            al = (ah *% base) +% al;

            cpu.regs.setReg8(0, al); // AL
            cpu.regs.setReg8(4, 0);  // AH = 0

            // Update flags
            cpu.flags.zero = al == 0;
            cpu.flags.sign = (al & 0x80) != 0;
            cpu.flags.parity = @popCount(al) & 1 == 0;
            // CF, OF, AF are undefined
        },
        // SALC/SETALC - Set AL from carry (undocumented but used)
        0xD6 => {
            // AL = 0xFF if CF=1, else AL = 0x00
            cpu.regs.setReg8(0, if (cpu.flags.carry) 0xFF else 0x00);
        },

        // XLAT/XLATB - Table look-up translation
        0xD7 => {
            // AL = DS:[EBX + AL] (or DS:[BX + AL] with address size override)
            const al = cpu.regs.getReg8(0);
            const base = if (cpu.prefix.address_size_override)
                @as(u32, cpu.regs.getReg16(3)) // BX
            else
                cpu.regs.ebx; // EBX

            const seg = if (cpu.prefix.segment_override) |seg_idx|
                cpu.segments.getSegment(seg_idx)
            else
                cpu.segments.ds;

            const addr = cpu.getEffectiveAddress(seg, base +% al);
            const value = try cpu.readMemByte(addr);
            cpu.regs.setReg8(0, value);
        },

        // FPU ESC opcodes (0xD8-0xDF) - x87 FPU instructions
        0xD8...0xDF => {
            // These are FPU instructions. For now, implement as minimal stubs.
            // Full FPU emulation is complex and not needed for basic operation.
            // We need to skip the ModR/M byte to avoid crashes.
            const modrm = try fetchModRM(cpu);

            // If CR0.EM (emulation) bit is set, we should raise #NM (no math coprocessor)
            // For now, just skip the instruction (no-op)
            // In the future, we could check cpu.system.cr0.em and raise an exception
            _ = modrm;
        },

        // Group 2 - Shift/Rotate (C0, C1, D0, D1, D2, D3)
        0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3 => {
            try executeGroup2(cpu, opcode);
        },

        // Group 3 - Unary operations (F6, F7)
        0xF6, 0xF7 => {
            try executeGroup3(cpu, opcode);
        },

        else => {
            cpu.dumpInstructionHistory();
            std.debug.print("\nINVALID OPCODE: {X:02} at {X:04}:{X:08}\n", .{ opcode, cpu.current_instr_cs, cpu.current_instr_eip });
            std.debug.print("Registers: EAX={X:08} EBX={X:08} ECX={X:08} EDX={X:08}\n", .{ cpu.regs.eax, cpu.regs.ebx, cpu.regs.ecx, cpu.regs.edx });
            std.debug.print("           ESP={X:08} EBP={X:08} ESI={X:08} EDI={X:08}\n", .{ cpu.regs.esp, cpu.regs.ebp, cpu.regs.esi, cpu.regs.edi });
            @panic("Unhandled opcode");
        },
    }
}

/// Execute two-byte opcode (0F xx)
fn executeTwoByteOpcode(cpu: *Cpu, opcode: u8) !void {
    switch (opcode) {
        // CMOVcc r16/r32, r/m16/r/m32 (conditional move)
        0x40...0x4F => {
            const cc = opcode & 0x0F;
            const condition = checkCondition(cpu, cc);
            if (condition) {
                const modrm = try fetchModRM(cpu);
                if (cpu.prefix.operand_size_override) {
                    // 16-bit operand
                    const value = try readRM16(cpu, modrm);
                    cpu.regs.setReg16(modrm.reg, value);
                } else {
                    // 32-bit operand
                    const value = try readRM32(cpu, modrm);
                    cpu.regs.setReg32(modrm.reg, value);
                }
            } else {
                // Still need to fetch ModR/M to advance EIP correctly
                _ = try fetchModRM(cpu);
            }
        },

        // Jcc rel32 (long conditional jumps)
        0x80 => try jccRel32(cpu, cpu.flags.overflow),
        0x81 => try jccRel32(cpu, !cpu.flags.overflow),
        0x82 => try jccRel32(cpu, cpu.flags.carry),
        0x83 => try jccRel32(cpu, !cpu.flags.carry),
        0x84 => try jccRel32(cpu, cpu.flags.zero),
        0x85 => try jccRel32(cpu, !cpu.flags.zero),
        0x86 => try jccRel32(cpu, cpu.flags.carry or cpu.flags.zero),
        0x87 => try jccRel32(cpu, !cpu.flags.carry and !cpu.flags.zero),
        0x88 => try jccRel32(cpu, cpu.flags.sign),
        0x89 => try jccRel32(cpu, !cpu.flags.sign),
        0x8A => try jccRel32(cpu, cpu.flags.parity),
        0x8B => try jccRel32(cpu, !cpu.flags.parity),
        0x8C => try jccRel32(cpu, cpu.flags.sign != cpu.flags.overflow),
        0x8D => try jccRel32(cpu, cpu.flags.sign == cpu.flags.overflow),
        0x8E => try jccRel32(cpu, cpu.flags.zero or (cpu.flags.sign != cpu.flags.overflow)),
        0x8F => try jccRel32(cpu, !cpu.flags.zero and (cpu.flags.sign == cpu.flags.overflow)),

        // CPUID
        0xA2 => {
            // Basic CPUID emulation
            switch (cpu.regs.eax) {
                0 => {
                    cpu.regs.eax = 1; // Max supported function
                    cpu.regs.ebx = 0x756E6547; // "Genu"
                    cpu.regs.edx = 0x49656E69; // "ineI"
                    cpu.regs.ecx = 0x6C65746E; // "ntel"
                },
                1 => {
                    cpu.regs.eax = 0x00000633; // Family 6, Model 3, Stepping 3
                    cpu.regs.ebx = 0;
                    cpu.regs.ecx = 0;
                    cpu.regs.edx = 0x00000001; // FPU present
                },
                else => {
                    cpu.regs.eax = 0;
                    cpu.regs.ebx = 0;
                    cpu.regs.ecx = 0;
                    cpu.regs.edx = 0;
                },
            }
        },

        // RDTSC
        0x31 => {
            const tsc = cpu.cycles;
            cpu.regs.eax = @truncate(tsc);
            cpu.regs.edx = @truncate(tsc >> 32);
        },

        // WRMSR - Write to Model Specific Register
        0x30 => {
            const msr_index = cpu.regs.ecx;
            const value = (@as(u64, cpu.regs.edx) << 32) | cpu.regs.eax;
            switch (msr_index) {
                0x174 => cpu.system.msr_sysenter_cs = @truncate(value),
                0x175 => cpu.system.msr_sysenter_esp = @truncate(value),
                0x176 => cpu.system.msr_sysenter_eip = @truncate(value),
                else => {
                    // For unsupported MSRs, we just ignore writes (or could raise #GP)
                    // Real hardware would raise #GP(0) for unknown MSRs
                },
            }
        },

        // RDMSR - Read from Model Specific Register
        0x32 => {
            const msr_index = cpu.regs.ecx;
            const value: u64 = switch (msr_index) {
                0x174 => cpu.system.msr_sysenter_cs,
                0x175 => cpu.system.msr_sysenter_esp,
                0x176 => cpu.system.msr_sysenter_eip,
                else => 0, // For unsupported MSRs, return 0 (or could raise #GP)
            };
            cpu.regs.eax = @truncate(value);
            cpu.regs.edx = @truncate(value >> 32);
        },

        // SYSENTER - Fast System Call
        0x34 => {
            // SYSENTER behavior (Intel specification):
            // 1. Load CS from IA32_SYSENTER_CS (selector with RPL forced to 0)
            // 2. Load SS from IA32_SYSENTER_CS + 8
            // 3. Load ESP from IA32_SYSENTER_ESP
            // 4. Load EIP from IA32_SYSENTER_EIP
            // 5. Clear VM flag in EFLAGS
            // 6. CPL becomes 0 (kernel mode)

            const sysenter_cs = cpu.system.msr_sysenter_cs & 0xFFFC; // Clear RPL bits

            // Load CS (kernel code segment, RPL=0)
            cpu.segments.cs = @truncate(sysenter_cs);

            // Load SS (kernel data segment, RPL=0)
            // SS = CS + 8 per Intel spec
            cpu.segments.ss = @truncate(sysenter_cs + 8);

            // Load ESP
            cpu.regs.esp = cpu.system.msr_sysenter_esp;

            // Load EIP
            cpu.eip = cpu.system.msr_sysenter_eip;

            // Clear VM flag (if we supported VM86 mode)
            // For now, we just ensure we're in protected mode
            if (cpu.mode != .protected) {
                cpu.mode = .protected;
            }

            // Note: CPL becomes 0 (kernel mode) - tracked in segment selectors' RPL
        },

        // SYSEXIT - Fast Return from System Call
        0x35 => {
            // SYSEXIT behavior (Intel specification):
            // 1. Load CS from IA32_SYSENTER_CS + 16 (selector with RPL forced to 3)
            // 2. Load SS from IA32_SYSENTER_CS + 24 (selector with RPL forced to 3)
            // 3. Load ESP from ECX
            // 4. Load EIP from EDX
            // 5. CPL becomes 3 (user mode)

            const sysenter_cs = cpu.system.msr_sysenter_cs & 0xFFFC; // Clear RPL bits

            // Load CS (user code segment, RPL=3)
            // CS = CS_BASE + 16 + 3 (RPL=3 for user mode)
            cpu.segments.cs = @truncate(sysenter_cs + 16 + 3);

            // Load SS (user data segment, RPL=3)
            // SS = CS_BASE + 24 + 3
            cpu.segments.ss = @truncate(sysenter_cs + 24 + 3);

            // Load ESP from ECX
            cpu.regs.esp = cpu.regs.ecx;

            // Load EIP from EDX
            cpu.eip = cpu.regs.edx;

            // Note: CPL becomes 3 (user mode) - tracked in segment selectors' RPL
        },

        // Group 0 (SLDT, STR, LLDT, LTR, etc.)
        0x00 => {
            try executeGroup0(cpu);
        },

        // LAR r16/32, r/m16 - Load Access Rights
        0x02 => {
            const modrm = try fetchModRM(cpu);
            const selector = if (modrm.mod == 3)
                cpu.regs.getReg16(modrm.rm)
            else
                try readRM16(cpu, modrm);

            // LAR only works in protected mode
            if (cpu.mode != .protected) {
                cpu.flags.zero = false;
                return;
            }

            // Get descriptor table (GDT or LDT based on TI bit)
            const index = selector >> 3;
            const dtr = getDescriptorTable(cpu, selector) orelse {
                cpu.flags.zero = false;
                return;
            };

            // Check if selector is within table limit
            const offset = @as(u32, index) * 8;
            if (offset + 7 > dtr.limit or selector == 0) {
                // Invalid selector
                cpu.flags.zero = false;
                return;
            }

            // Read descriptor from memory
            var bytes: [8]u8 = undefined;
            for (0..8) |i| {
                bytes[i] = try cpu.readMemByte(dtr.base + offset + @as(u32, @intCast(i)));
            }

            const desc = cpu_mod.SegmentDescriptor.fromBytes(bytes);

            // Check if descriptor is valid and accessible
            if (!desc.isPresent()) {
                cpu.flags.zero = false;
                return;
            }

            // Load access rights into destination register
            // Access rights are in bits 8-23 of the descriptor (bytes 5-6 + lower nibble of byte 7)
            const access_rights: u32 = (@as(u32, bytes[6]) << 16) | (@as(u32, bytes[5]) << 8) | 0;

            if (cpu.prefix.operand_size_override) {
                // 16-bit: Load lower 16 bits
                cpu.regs.setReg16(modrm.reg, @truncate(access_rights >> 8));
            } else {
                // 32-bit: Load full access rights (bits 8-31, bits 0-7 are zero)
                cpu.regs.setReg32(modrm.reg, access_rights & 0x00FFFF00);
            }

            cpu.flags.zero = true;
        },

        // LSL r16/32, r/m16 - Load Segment Limit
        0x03 => {
            const modrm = try fetchModRM(cpu);
            const selector = if (modrm.mod == 3)
                cpu.regs.getReg16(modrm.rm)
            else
                try readRM16(cpu, modrm);

            // LSL only works in protected mode
            if (cpu.mode != .protected) {
                cpu.flags.zero = false;
                return;
            }

            // Get descriptor table (GDT or LDT based on TI bit)
            const index = selector >> 3;
            const dtr = getDescriptorTable(cpu, selector) orelse {
                cpu.flags.zero = false;
                return;
            };

            // Check if selector is within table limit
            const offset = @as(u32, index) * 8;
            if (offset + 7 > dtr.limit or selector == 0) {
                // Invalid selector
                cpu.flags.zero = false;
                return;
            }

            // Read descriptor from memory
            var bytes: [8]u8 = undefined;
            for (0..8) |i| {
                bytes[i] = try cpu.readMemByte(dtr.base + offset + @as(u32, @intCast(i)));
            }

            const desc = cpu_mod.SegmentDescriptor.fromBytes(bytes);

            // Check if descriptor is valid and accessible
            if (!desc.isPresent()) {
                cpu.flags.zero = false;
                return;
            }

            // Load effective segment limit
            const limit = desc.getEffectiveLimit();

            if (cpu.prefix.operand_size_override) {
                // 16-bit: Load lower 16 bits of limit
                cpu.regs.setReg16(modrm.reg, @truncate(limit));
            } else {
                // 32-bit: Load full limit
                cpu.regs.setReg32(modrm.reg, limit);
            }

            cpu.flags.zero = true;
        },


        // UD2 - Undefined Instruction (intentionally raises #UD)
        0x0B => {
            // Raise Invalid Opcode exception (#UD, vector 6)
            try cpu.raiseException(.invalid_opcode, null);
        },


        // Group 7 (LGDT, LIDT, etc.)
        0x01 => {
            try executeGroup7(cpu);
        },

        // CLTS - Clear Task-Switched flag in CR0
        0x06 => {
            cpu.system.cr0.ts = false;
        },

        // MOV r32, CRn
        0x20 => {
            const modrm = try fetchModRM(cpu);
            const value = switch (modrm.reg) {
                0 => cpu.system.cr0.toU32(),
                2 => cpu.system.cr2,
                3 => cpu.system.cr3.toU32(),
                4 => cpu.system.cr4.toU32(),
                else => return CpuError.InvalidOpcode,
            };
            cpu.regs.setReg32(modrm.rm, value);
        },

        // MOV CRn, r32
        0x22 => {
            const modrm = try fetchModRM(cpu);
            const value = cpu.regs.getReg32(modrm.rm);
            switch (modrm.reg) {
                0 => {
                    const old_pe = cpu.system.cr0.pe;
                    cpu.system.cr0 = cpu_mod.CR0.fromU32(value);
                    // Handle mode switch
                    if (!old_pe and cpu.system.cr0.pe) {
                        cpu.mode = .protected;
                    } else if (old_pe and !cpu.system.cr0.pe) {
                        cpu.mode = .real;
                    }
                },
                2 => cpu.system.cr2 = value,
                3 => cpu.system.cr3 = cpu_mod.CR3.fromU32(value),
                4 => cpu.system.cr4 = cpu_mod.CR4.fromU32(value),
                else => return CpuError.InvalidOpcode,
            }
        },

        // MOV r32, DRn - Move from debug register
        0x21 => {
            const modrm = try fetchModRM(cpu);
            const value = switch (modrm.reg) {
                0 => cpu.system.dr0,
                1 => cpu.system.dr1,
                2 => cpu.system.dr2,
                3 => cpu.system.dr3,
                4 => cpu.system.dr6, // DR4 is aliased to DR6
                5 => cpu.system.dr7, // DR5 is aliased to DR7
                6 => cpu.system.dr6,
                7 => cpu.system.dr7,
            };
            cpu.regs.setReg32(modrm.rm, value);
        },

        // MOV DRn, r32 - Move to debug register
        0x23 => {
            const modrm = try fetchModRM(cpu);
            const value = cpu.regs.getReg32(modrm.rm);
            switch (modrm.reg) {
                0 => cpu.system.dr0 = value,
                1 => cpu.system.dr1 = value,
                2 => cpu.system.dr2 = value,
                3 => cpu.system.dr3 = value,
                4 => cpu.system.dr6 = value, // DR4 is aliased to DR6
                5 => cpu.system.dr7 = value, // DR5 is aliased to DR7
                6 => cpu.system.dr6 = value,
                7 => cpu.system.dr7 = value,
            }
        },

        // MOV r32, TRn - Move from test register (obsolete, stub as no-op)
        0x24 => {
            const modrm = try fetchModRM(cpu);
            // Test registers are obsolete (only on 486 and earlier)
            // Return 0 for compatibility
            cpu.regs.setReg32(modrm.rm, 0);
        },

        // MOV TRn, r32 - Move to test register (obsolete, stub as no-op)
        0x26 => {
            _ = try fetchModRM(cpu);
            // Test registers are obsolete (only on 486 and earlier)
            // Ignore writes for compatibility
        },

        // WBINVD (Write-Back and Invalidate Cache)
        0x09 => {
            // No-op for emulator (no cache to invalidate)
        },

        // INVD (Invalidate Cache)
        0x08 => {
            // No-op for emulator
        },

        // CMPXCHG r/m8, r8 - Compare and exchange
        0xB0 => {
            const modrm = try fetchModRM(cpu);
            const dest = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);
            const accumulator = @as(u8, @truncate(cpu.regs.eax)); // AL

            // Compare AL with destination
            _ = subWithFlags8(cpu, accumulator, dest);

            if (accumulator == dest) {
                // ZF=1, source -> destination
                try writeRM8(cpu, modrm, src);
            } else {
                // ZF=0, destination -> AL
                cpu.regs.setReg8(0, dest);
            }
        },

        // CMPXCHG r/m16/32, r16/32 - Compare and exchange
        0xB1 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                // 16-bit operand
                const dest = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const accumulator = @as(u16, @truncate(cpu.regs.eax)); // AX

                // Compare AX with destination
                _ = subWithFlags16(cpu, accumulator, dest);

                if (accumulator == dest) {
                    // ZF=1, source -> destination
                    try writeRM16(cpu, modrm, src);
                } else {
                    // ZF=0, destination -> AX
                    cpu.regs.setReg16(0, dest);
                }
            } else {
                // 32-bit operand
                const dest = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const accumulator = cpu.regs.eax; // EAX

                // Compare EAX with destination
                _ = subWithFlags32(cpu, accumulator, dest);

                if (accumulator == dest) {
                    // ZF=1, source -> destination
                    try writeRM32(cpu, modrm, src);
                } else {
                    // ZF=0, destination -> EAX
                    cpu.regs.eax = dest;
                }
            }
        },

        // LSS r16/32, m16:16/m16:32 - Load far pointer from memory into SS:r
        0xB2 => {
            const modrm = try fetchModRM(cpu);
            if (modrm.mod == 3) {
                // Invalid: LSS requires a memory operand
                return CpuError.InvalidOpcode;
            }
            const addr = try calculateEffectiveAddress(cpu, modrm);

            if (cpu.prefix.operand_size_override) {
                // m16:16 - Load 16-bit offset and 16-bit segment
                const offset_val = try cpu.readMemWord(addr);
                const segment = try cpu.readMemWord(addr + 2);
                cpu.regs.setReg16(modrm.reg, offset_val);
                cpu.segments.ss = segment;
            } else {
                // m16:32 - Load 32-bit offset and 16-bit segment
                const offset_val = try cpu.readMemDword(addr);
                const segment = try cpu.readMemWord(addr + 4);
                cpu.regs.setReg32(modrm.reg, offset_val);
                cpu.segments.ss = segment;
            }

            // In protected mode, load segment descriptor into cache
            if (cpu.mode == .protected) {
                try cpu.loadSegmentDescriptor(cpu.segments.ss, 2); // SS is index 2
            }
        },

        // LFS r16/32, m16:16/m16:32 - Load far pointer from memory into FS:r
        0xB4 => {
            const modrm = try fetchModRM(cpu);
            if (modrm.mod == 3) {
                // Invalid: LFS requires a memory operand
                return CpuError.InvalidOpcode;
            }
            const addr = try calculateEffectiveAddress(cpu, modrm);

            if (cpu.prefix.operand_size_override) {
                // m16:16 - Load 16-bit offset and 16-bit segment
                const offset_val = try cpu.readMemWord(addr);
                const segment = try cpu.readMemWord(addr + 2);
                cpu.regs.setReg16(modrm.reg, offset_val);
                cpu.segments.fs = segment;
            } else {
                // m16:32 - Load 32-bit offset and 16-bit segment
                const offset_val = try cpu.readMemDword(addr);
                const segment = try cpu.readMemWord(addr + 4);
                cpu.regs.setReg32(modrm.reg, offset_val);
                cpu.segments.fs = segment;
            }

            // In protected mode, load segment descriptor into cache
            if (cpu.mode == .protected) {
                try cpu.loadSegmentDescriptor(cpu.segments.fs, 4); // FS is index 4
            }
        },

        // LGS r16/32, m16:16/m16:32 - Load far pointer from memory into GS:r
        0xB5 => {
            const modrm = try fetchModRM(cpu);
            if (modrm.mod == 3) {
                // Invalid: LGS requires a memory operand
                return CpuError.InvalidOpcode;
            }
            const addr = try calculateEffectiveAddress(cpu, modrm);

            if (cpu.prefix.operand_size_override) {
                // m16:16 - Load 16-bit offset and 16-bit segment
                const offset_val = try cpu.readMemWord(addr);
                const segment = try cpu.readMemWord(addr + 2);
                cpu.regs.setReg16(modrm.reg, offset_val);
                cpu.segments.gs = segment;
            } else {
                // m16:32 - Load 32-bit offset and 16-bit segment
                const offset_val = try cpu.readMemDword(addr);
                const segment = try cpu.readMemWord(addr + 4);
                cpu.regs.setReg32(modrm.reg, offset_val);
                cpu.segments.gs = segment;
            }

            // In protected mode, load segment descriptor into cache
            if (cpu.mode == .protected) {
                try cpu.loadSegmentDescriptor(cpu.segments.gs, 5); // GS is index 5
            }
        },

        // MOVZX r32, r/m8
        0xB6 => {
            const modrm = try fetchModRM(cpu);
            const value = try readRM8(cpu, modrm);
            if (cpu.prefix.operand_size_override) {
                cpu.regs.setReg16(modrm.reg, @as(u16, value));
            } else {
                cpu.regs.setReg32(modrm.reg, @as(u32, value));
            }
        },

        // MOVZX r32, r/m16
        0xB7 => {
            const modrm = try fetchModRM(cpu);
            const value = try readRM16(cpu, modrm);
            // Note: 0F B7 is always 32-bit destination (MOVZX r32, r/m16)
            cpu.regs.setReg32(modrm.reg, @as(u32, value));
        },

        // MOVSX r32, r/m8
        0xBE => {
            const modrm = try fetchModRM(cpu);
            const value: i8 = @bitCast(try readRM8(cpu, modrm));
            if (cpu.prefix.operand_size_override) {
                cpu.regs.setReg16(modrm.reg, @bitCast(@as(i16, value)));
            } else {
                cpu.regs.setReg32(modrm.reg, @bitCast(@as(i32, value)));
            }
        },

        // MOVSX r32, r/m16
        0xBF => {
            const modrm = try fetchModRM(cpu);
            const value: i16 = @bitCast(try readRM16(cpu, modrm));
            // Note: 0F BF is always 32-bit destination (MOVSX r32, r/m16)
            cpu.regs.setReg32(modrm.reg, @bitCast(@as(i32, value)));
        },

        // SETcc r/m8 (0x90-0x9F) - Set byte on condition
        0x90 => try setCC(cpu, cpu.flags.overflow), // SETO
        0x91 => try setCC(cpu, !cpu.flags.overflow), // SETNO
        0x92 => try setCC(cpu, cpu.flags.carry), // SETB/SETC/SETNAE
        0x93 => try setCC(cpu, !cpu.flags.carry), // SETAE/SETNB/SETNC
        0x94 => try setCC(cpu, cpu.flags.zero), // SETE/SETZ
        0x95 => try setCC(cpu, !cpu.flags.zero), // SETNE/SETNZ
        0x96 => try setCC(cpu, cpu.flags.carry or cpu.flags.zero), // SETBE/SETNA
        0x97 => try setCC(cpu, !cpu.flags.carry and !cpu.flags.zero), // SETA/SETNBE
        0x98 => try setCC(cpu, cpu.flags.sign), // SETS
        0x99 => try setCC(cpu, !cpu.flags.sign), // SETNS
        0x9A => try setCC(cpu, cpu.flags.parity), // SETP/SETPE
        0x9B => try setCC(cpu, !cpu.flags.parity), // SETNP/SETPO
        0x9C => try setCC(cpu, cpu.flags.sign != cpu.flags.overflow), // SETL/SETNGE
        0x9D => try setCC(cpu, cpu.flags.sign == cpu.flags.overflow), // SETGE/SETNL
        0x9E => try setCC(cpu, cpu.flags.zero or (cpu.flags.sign != cpu.flags.overflow)), // SETLE/SETNG
        0x9F => try setCC(cpu, !cpu.flags.zero and (cpu.flags.sign == cpu.flags.overflow)), // SETG/SETNLE

        // BT r/m32, r32 - Bit test
        0xA3 => {
            const modrm = try fetchModRM(cpu);
            const bit_pos = cpu.regs.getReg32(modrm.reg) & 31;
            const value = try readRM32(cpu, modrm);
            cpu.flags.carry = ((value >> @truncate(bit_pos)) & 1) != 0;
        },

        // SHLD r/m16/32, r16/32, imm8 - Shift left double
        0xA4 => {
            const modrm = try fetchModRM(cpu);
            const count = try fetchByte(cpu);
            if (cpu.prefix.operand_size_override) {
                const dest = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = shld16(cpu, dest, src, count);
                try writeRM16(cpu, modrm, result);
            } else {
                const dest = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = shld32(cpu, dest, src, count);
                try writeRM32(cpu, modrm, result);
            }
        },

        // SHLD r/m16/32, r16/32, CL - Shift left double
        0xA5 => {
            const modrm = try fetchModRM(cpu);
            const count = @as(u8, @truncate(cpu.regs.ecx));
            if (cpu.prefix.operand_size_override) {
                const dest = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = shld16(cpu, dest, src, count);
                try writeRM16(cpu, modrm, result);
            } else {
                const dest = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = shld32(cpu, dest, src, count);
                try writeRM32(cpu, modrm, result);
            }
        },

        // BTS r/m32, r32 - Bit test and set
        0xAB => {
            const modrm = try fetchModRM(cpu);
            const bit_pos = cpu.regs.getReg32(modrm.reg) & 31;
            const value = try readRM32(cpu, modrm);
            cpu.flags.carry = ((value >> @truncate(bit_pos)) & 1) != 0;
            const new_value = value | (@as(u32, 1) << @truncate(bit_pos));
            try writeRM32(cpu, modrm, new_value);
        },

        // SHRD r/m16/32, r16/32, imm8 - Shift right double
        0xAC => {
            const modrm = try fetchModRM(cpu);
            const count = try fetchByte(cpu);
            if (cpu.prefix.operand_size_override) {
                const dest = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = shrd16(cpu, dest, src, count);
                try writeRM16(cpu, modrm, result);
            } else {
                const dest = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = shrd32(cpu, dest, src, count);
                try writeRM32(cpu, modrm, result);
            }
        },

        // SHRD r/m16/32, r16/32, CL - Shift right double
        0xAD => {
            const modrm = try fetchModRM(cpu);
            const count = @as(u8, @truncate(cpu.regs.ecx));
            if (cpu.prefix.operand_size_override) {
                const dest = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);
                const result = shrd16(cpu, dest, src, count);
                try writeRM16(cpu, modrm, result);
            } else {
                const dest = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);
                const result = shrd32(cpu, dest, src, count);
                try writeRM32(cpu, modrm, result);
            }
        },

        // BTR r/m32, r32 - Bit test and reset
        0xB3 => {
            const modrm = try fetchModRM(cpu);
            const bit_pos = cpu.regs.getReg32(modrm.reg) & 31;
            const value = try readRM32(cpu, modrm);
            cpu.flags.carry = ((value >> @truncate(bit_pos)) & 1) != 0;
            const new_value = value & ~(@as(u32, 1) << @truncate(bit_pos));
            try writeRM32(cpu, modrm, new_value);
        },

        // BTC r/m32, r32 - Bit test and complement
        0xBB => {
            const modrm = try fetchModRM(cpu);
            const bit_pos = cpu.regs.getReg32(modrm.reg) & 31;
            const value = try readRM32(cpu, modrm);
            cpu.flags.carry = ((value >> @truncate(bit_pos)) & 1) != 0;
            const new_value = value ^ (@as(u32, 1) << @truncate(bit_pos));
            try writeRM32(cpu, modrm, new_value);
        },

        // BSF r32, r/m32 - Bit scan forward
        0xBC => {
            const modrm = try fetchModRM(cpu);
            const value = try readRM32(cpu, modrm);
            if (value == 0) {
                cpu.flags.zero = true;
                // Destination is undefined when ZF=1, but we leave it unchanged
            } else {
                cpu.flags.zero = false;
                // Find the lowest set bit (counting from bit 0)
                var bit_index: u32 = 0;
                while (bit_index < 32) : (bit_index += 1) {
                    if (((value >> @truncate(bit_index)) & 1) != 0) {
                        break;
                    }
                }
                cpu.regs.setReg32(modrm.reg, bit_index);
            }
        },

        // BSR r32, r/m32 - Bit scan reverse
        0xBD => {
            const modrm = try fetchModRM(cpu);
            const value = try readRM32(cpu, modrm);
            if (value == 0) {
                cpu.flags.zero = true;
                // Destination is undefined when ZF=1, but we leave it unchanged
            } else {
                cpu.flags.zero = false;
                // Find the highest set bit (counting from bit 0)
                var bit_index: u32 = 31;
                while (bit_index > 0) : (bit_index -= 1) {
                    if (((value >> @truncate(bit_index)) & 1) != 0) {
                        break;
                    }
                }
                cpu.regs.setReg32(modrm.reg, bit_index);
            }
        },

        // XADD r/m8, r8 - Exchange and add
        0xC0 => {
            const modrm = try fetchModRM(cpu);
            const dest = try readRM8(cpu, modrm);
            const src = cpu.regs.getReg8(modrm.reg);

            // TEMP = dest + src
            const sum = addWithFlags8(cpu, dest, src);

            // src = original dest, dest = TEMP
            cpu.regs.setReg8(modrm.reg, dest);
            try writeRM8(cpu, modrm, sum);
        },

        // XADD r/m16/32, r16/32 - Exchange and add
        0xC1 => {
            const modrm = try fetchModRM(cpu);
            if (cpu.prefix.operand_size_override) {
                // 16-bit operand
                const dest = try readRM16(cpu, modrm);
                const src = cpu.regs.getReg16(modrm.reg);

                // TEMP = dest + src
                const sum = addWithFlags16(cpu, dest, src);

                // src = original dest, dest = TEMP
                cpu.regs.setReg16(modrm.reg, dest);
                try writeRM16(cpu, modrm, sum);
            } else {
                // 32-bit operand
                const dest = try readRM32(cpu, modrm);
                const src = cpu.regs.getReg32(modrm.reg);

                // TEMP = dest + src
                const sum = addWithFlags32(cpu, dest, src);

                // src = original dest, dest = TEMP
                cpu.regs.setReg32(modrm.reg, dest);
                try writeRM32(cpu, modrm, sum);
            }
        },

        // CMPXCHG8B m64 - Compare and exchange 8 bytes
        0xC7 => {
            const modrm = try fetchModRM(cpu);
            // CMPXCHG8B only supports /1 encoding (modrm.reg == 1)
            if (modrm.reg != 1) {
                return CpuError.InvalidOpcode;
            }
            // Must be a memory operand
            if (modrm.mod == 3) {
                return CpuError.InvalidOpcode;
            }

            const addr = try calculateEffectiveAddress(cpu, modrm);

            // Read 8 bytes from memory (EDX:EAX)
            const mem_low = try cpu.readMemDword(addr);
            const mem_high = try cpu.readMemDword(addr + 4);

            // Compare EDX:EAX with m64
            if (cpu.regs.edx == mem_high and cpu.regs.eax == mem_low) {
                // ZF=1, ECX:EBX -> m64
                cpu.flags.zero = true;
                try cpu.writeMemDword(addr, cpu.regs.ebx);
                try cpu.writeMemDword(addr + 4, cpu.regs.ecx);
            } else {
                // ZF=0, m64 -> EDX:EAX
                cpu.flags.zero = false;
                cpu.regs.eax = mem_low;
                cpu.regs.edx = mem_high;
            }
        },

        else => return CpuError.InvalidOpcode,
    }
}

/// Execute Group 0 instructions (SLDT, STR, LLDT, LTR, VERR, VERW)
fn executeGroup0(cpu: *Cpu) !void {
    const modrm = try fetchModRM(cpu);

    switch (modrm.reg) {
        // SLDT - Store Local Descriptor Table Register
        0 => {
            if (modrm.mod == 3) {
                // Register operand
                cpu.regs.setReg16(modrm.rm, cpu.system.ldtr);
            } else {
                // Memory operand
                const addr = try calculateEffectiveAddress(cpu, modrm);
                try cpu.writeMemWord(addr, cpu.system.ldtr);
            }
        },
        // STR - Store Task Register
        1 => {
            if (modrm.mod == 3) {
                // Register operand
                cpu.regs.setReg16(modrm.rm, cpu.system.tr);
            } else {
                // Memory operand
                const addr = try calculateEffectiveAddress(cpu, modrm);
                try cpu.writeMemWord(addr, cpu.system.tr);
            }
        },
        // LLDT - Load Local Descriptor Table Register
        2 => {
            const selector = if (modrm.mod == 3)
                cpu.regs.getReg16(modrm.rm)
            else
                blk: {
                    const addr = try calculateEffectiveAddress(cpu, modrm);
                    break :blk try cpu.readMemWord(addr);
                };

            // Store the selector
            cpu.system.ldtr = selector;

            // If selector is null, just clear the LDT
            if (selector == 0) {
                cpu.system.ldtr_base = 0;
                cpu.system.ldtr_limit = 0;
            } else {
                // Look up the LDT descriptor in the GDT
                // Note: LLDT always uses GDT (LDT descriptors are in GDT)
                const index = selector >> 3;
                const offset = @as(u32, index) * 8;

                // Check if within GDT limit
                if (offset + 7 > cpu.system.gdtr.limit) {
                    cpu.exception_error_code = selector;
                    return CpuError.GeneralProtectionFault;
                }

                // Read the LDT descriptor from GDT
                var bytes: [8]u8 = undefined;
                for (0..8) |i| {
                    bytes[i] = try cpu.readMemByte(cpu.system.gdtr.base + offset + @as(u32, @intCast(i)));
                }

                const desc = cpu_mod.SegmentDescriptor.fromBytes(bytes);

                // Verify it's an LDT descriptor (system type 0x2)
                // Access byte should have descriptor_type = 0 (system) and type = 0010 (LDT)
                // For simplicity, just extract base and limit
                cpu.system.ldtr_base = desc.base;
                cpu.system.ldtr_limit = desc.getEffectiveLimit();
            }
        },
        // LTR - Load Task Register
        3 => {
            const value = if (modrm.mod == 3)
                cpu.regs.getReg16(modrm.rm)
            else
                blk: {
                    const addr = try calculateEffectiveAddress(cpu, modrm);
                    break :blk try cpu.readMemWord(addr);
                };
            cpu.system.tr = value;
        },
        // VERR - Verify Segment for Reading
        4 => {
            const selector = if (modrm.mod == 3)
                cpu.regs.getReg16(modrm.rm)
            else
                blk: {
                    const addr = try calculateEffectiveAddress(cpu, modrm);
                    break :blk try cpu.readMemWord(addr);
                };

            // In protected mode, check if segment is readable
            if (cpu.mode == .protected) {
                // Get descriptor table (GDT or LDT based on TI bit)
                const index = selector >> 3;
                const dtr = getDescriptorTable(cpu, selector) orelse {
                    cpu.flags.zero = false;
                    return;
                };

                // Check if selector is within table limit
                const offset = @as(u32, index) * 8;
                if (offset + 7 <= dtr.limit and selector != 0) {
                    // Read descriptor
                    var bytes: [8]u8 = undefined;
                    for (0..8) |i| {
                        bytes[i] = try cpu.readMemByte(dtr.base + offset + @as(u32, @intCast(i)));
                    }
                    const desc = cpu_mod.SegmentDescriptor.fromBytes(bytes);

                    // ZF=1 if segment is valid, present, and readable
                    if (desc.isPresent() and desc.isReadable()) {
                        cpu.flags.zero = true;
                    } else {
                        cpu.flags.zero = false;
                    }
                } else {
                    cpu.flags.zero = false;
                }
            } else {
                // In real mode, always readable
                cpu.flags.zero = true;
            }
        },
        // VERW - Verify Segment for Writing
        5 => {
            const selector = if (modrm.mod == 3)
                cpu.regs.getReg16(modrm.rm)
            else
                blk: {
                    const addr = try calculateEffectiveAddress(cpu, modrm);
                    break :blk try cpu.readMemWord(addr);
                };

            // In protected mode, check if segment is writable
            if (cpu.mode == .protected) {
                // Get descriptor table (GDT or LDT based on TI bit)
                const index = selector >> 3;
                const dtr = getDescriptorTable(cpu, selector) orelse {
                    cpu.flags.zero = false;
                    return;
                };

                // Check if selector is within table limit
                const offset = @as(u32, index) * 8;
                if (offset + 7 <= dtr.limit and selector != 0) {
                    // Read descriptor
                    var bytes: [8]u8 = undefined;
                    for (0..8) |i| {
                        bytes[i] = try cpu.readMemByte(dtr.base + offset + @as(u32, @intCast(i)));
                    }
                    const desc = cpu_mod.SegmentDescriptor.fromBytes(bytes);

                    // ZF=1 if segment is valid, present, and writable
                    if (desc.isPresent() and desc.isData() and desc.isWritable()) {
                        cpu.flags.zero = true;
                    } else {
                        cpu.flags.zero = false;
                    }
                } else {
                    cpu.flags.zero = false;
                }
            } else {
                // In real mode, always writable
                cpu.flags.zero = true;
            }
        },
        else => {
            cpu.dumpInstructionHistory();
            std.debug.print("\nINVALID GROUP 0 INSTRUCTION: 0F 00 /{d} at {X:04}:{X:08}\n", .{ modrm.reg, cpu.current_instr_cs, cpu.current_instr_eip });
            @panic("Unhandled Group 0 instruction");
        },
    }
}

/// Execute Group 7 instructions (LGDT, LIDT, SGDT, SIDT, etc.)
fn executeGroup7(cpu: *Cpu) !void {
    const modrm = try fetchModRM(cpu);

    switch (modrm.reg) {
        // SGDT - Store Global Descriptor Table Register
        0 => {
            const addr = try calculateEffectiveAddress(cpu, modrm);
            try cpu.writeMemWord(addr, cpu.system.gdtr.limit);
            try cpu.writeMemDword(addr + 2, cpu.system.gdtr.base);
        },
        // SIDT - Store Interrupt Descriptor Table Register
        1 => {
            const addr = try calculateEffectiveAddress(cpu, modrm);
            try cpu.writeMemWord(addr, cpu.system.idtr.limit);
            try cpu.writeMemDword(addr + 2, cpu.system.idtr.base);
        },
        // LGDT - Load Global Descriptor Table Register
        2 => {
            const addr = try calculateEffectiveAddress(cpu, modrm);
            cpu.system.gdtr.limit = try cpu.readMemWord(addr);
            cpu.system.gdtr.base = try cpu.readMemDword(addr + 2);
        },
        // LIDT - Load Interrupt Descriptor Table Register
        3 => {
            const addr = try calculateEffectiveAddress(cpu, modrm);
            cpu.system.idtr.limit = try cpu.readMemWord(addr);
            cpu.system.idtr.base = try cpu.readMemDword(addr + 2);
        },
        // SMSW - Store Machine Status Word
        4 => {
            const value: u16 = @truncate(cpu.system.cr0.toU32());
            if (modrm.mod == 3) {
                cpu.regs.setReg16(modrm.rm, value);
            } else {
                const addr = try calculateEffectiveAddress(cpu, modrm);
                try cpu.writeMemWord(addr, value);
            }
        },
        // LMSW - Load Machine Status Word
        6 => {
            var value: u16 = undefined;
            if (modrm.mod == 3) {
                value = cpu.regs.getReg16(modrm.rm);
            } else {
                const addr = try calculateEffectiveAddress(cpu, modrm);
                value = try cpu.readMemWord(addr);
            }
            // LMSW can only set PE, not clear it
            var cr0 = cpu.system.cr0;
            if (value & 1 != 0) {
                cr0.pe = true;
                cpu.mode = .protected;
            }
            cr0.mp = (value & 2) != 0;
            cr0.em = (value & 4) != 0;
            cr0.ts = (value & 8) != 0;
            cpu.system.cr0 = cr0;
        },
        // INVLPG - Invalidate TLB Entry
        7 => {
            // No-op for emulator (no TLB)
            _ = try calculateEffectiveAddress(cpu, modrm);
        },
        else => {
            cpu.dumpInstructionHistory();
            std.debug.print("\nINVALID GROUP 7 INSTRUCTION: 0F 01 /{d} at {X:04}:{X:08}\n", .{ modrm.reg, cpu.current_instr_cs, cpu.current_instr_eip });
            @panic("Unhandled Group 7 instruction");
        },
    }
}

/// Execute Group 1 instructions (immediate arithmetic)
fn executeGroup1(cpu: *Cpu, opcode: u8) !void {
    const modrm = try fetchModRM(cpu);

    switch (opcode) {
        0x80, 0x82 => {
            // r/m8, imm8
            const dst = try readRM8(cpu, modrm);
            const imm = try fetchByte(cpu);
            const result = switch (modrm.reg) {
                0 => addWithFlags8(cpu, dst, imm), // ADD
                1 => dst | imm, // OR
                2 => addWithFlags8(cpu, dst, imm +% @as(u8, @intFromBool(cpu.flags.carry))), // ADC
                3 => subWithFlags8(cpu, dst, imm +% @as(u8, @intFromBool(cpu.flags.carry))), // SBB
                4 => dst & imm, // AND
                5 => subWithFlags8(cpu, dst, imm), // SUB
                6 => dst ^ imm, // XOR
                7 => blk: {
                    _ = subWithFlags8(cpu, dst, imm); // CMP
                    break :blk dst;
                },
            };
            if (modrm.reg != 7) {
                try writeRM8(cpu, modrm, result);
            }
        },
        0x81 => {
            // r/m32, imm32
            const dst = try readRM32(cpu, modrm);
            const imm = try fetchDword(cpu);
            const result = switch (modrm.reg) {
                0 => addWithFlags32(cpu, dst, imm),
                1 => dst | imm,
                2 => addWithFlags32(cpu, dst, imm +% @as(u32, @intFromBool(cpu.flags.carry))),
                3 => subWithFlags32(cpu, dst, imm +% @as(u32, @intFromBool(cpu.flags.carry))),
                4 => dst & imm,
                5 => subWithFlags32(cpu, dst, imm),
                6 => dst ^ imm,
                7 => blk: {
                    _ = subWithFlags32(cpu, dst, imm);
                    break :blk dst;
                },
            };
            if (modrm.reg != 7) {
                try writeRM32(cpu, modrm, result);
            }
        },
        0x83 => {
            // r/m32, imm8 (sign-extended)
            const dst = try readRM32(cpu, modrm);
            const imm_byte: i8 = @bitCast(try fetchByte(cpu));
            const imm: u32 = @bitCast(@as(i32, imm_byte));
            const result = switch (modrm.reg) {
                0 => addWithFlags32(cpu, dst, imm),
                1 => dst | imm,
                2 => addWithFlags32(cpu, dst, imm +% @as(u32, @intFromBool(cpu.flags.carry))),
                3 => subWithFlags32(cpu, dst, imm +% @as(u32, @intFromBool(cpu.flags.carry))),
                4 => dst & imm,
                5 => subWithFlags32(cpu, dst, imm),
                6 => dst ^ imm,
                7 => blk: {
                    _ = subWithFlags32(cpu, dst, imm);
                    break :blk dst;
                },
            };
            if (modrm.reg != 7) {
                try writeRM32(cpu, modrm, result);
            }
        },
        else => {},
    }
}

/// Execute Group 2 instructions (shift/rotate)
fn executeGroup2(cpu: *Cpu, opcode: u8) !void {
    const modrm = try fetchModRM(cpu);

    // Get shift count
    const count: u5 = switch (opcode) {
        0xC0, 0xC1 => @truncate(try fetchByte(cpu)), // imm8
        0xD0, 0xD1 => 1, // shift by 1
        0xD2, 0xD3 => @truncate(cpu.regs.ecx), // CL
        else => unreachable,
    };

    // 8-bit or 32-bit operation
    const is_8bit = opcode == 0xC0 or opcode == 0xD0 or opcode == 0xD2;

    if (is_8bit) {
        const value = try readRM8(cpu, modrm);
        const result = shiftRotate8(cpu, modrm.reg, value, count);
        try writeRM8(cpu, modrm, result);
    } else {
        if (cpu.prefix.operand_size_override) {
            const value = try readRM16(cpu, modrm);
            const result = shiftRotate16(cpu, modrm.reg, value, count);
            try writeRM16(cpu, modrm, result);
        } else {
            const value = try readRM32(cpu, modrm);
            const result = shiftRotate32(cpu, modrm.reg, value, count);
            try writeRM32(cpu, modrm, result);
        }
    }
}

fn shiftRotate8(cpu: *Cpu, op: u3, value: u8, count: u5) u8 {
    if (count == 0) return value;

    var result: u8 = value;
    var cf = cpu.flags.carry;

    switch (op) {
        0 => { // ROL
            const masked = count & 7;
            result = (value << @truncate(masked)) | (value >> @truncate(8 - masked));
            cf = (result & 1) != 0;
        },
        1 => { // ROR
            const masked = count & 7;
            result = (value >> @truncate(masked)) | (value << @truncate(8 - masked));
            cf = (result & 0x80) != 0;
        },
        2 => { // RCL
            for (0..count) |_| {
                const new_cf = (result & 0x80) != 0;
                result = (result << 1) | @as(u8, @intFromBool(cf));
                cf = new_cf;
            }
        },
        3 => { // RCR
            for (0..count) |_| {
                const new_cf = (result & 1) != 0;
                result = (result >> 1) | (@as(u8, @intFromBool(cf)) << 7);
                cf = new_cf;
            }
        },
        4, 6 => { // SHL/SAL
            cf = (value >> @truncate(8 - count)) & 1 != 0;
            result = value << @truncate(count);
        },
        5 => { // SHR
            cf = (value >> @truncate(count - 1)) & 1 != 0;
            result = value >> @truncate(count);
        },
        7 => { // SAR
            cf = (value >> @truncate(count - 1)) & 1 != 0;
            const signed: i8 = @bitCast(value);
            result = @bitCast(signed >> @truncate(count));
        },
    }

    cpu.flags.carry = cf;
    // Update other flags for shift operations (not rotates)
    if (op >= 4) {
        cpu.flags.zero = result == 0;
        cpu.flags.sign = (result & 0x80) != 0;
        cpu.flags.parity = @popCount(result) % 2 == 0;
        if (count == 1) {
            // Overflow is defined only for 1-bit shifts
            cpu.flags.overflow = switch (op) {
                4, 6 => (result & 0x80) != (value & 0x80), // SHL
                5 => (value & 0x80) != 0, // SHR
                7 => false, // SAR never overflows
                else => false,
            };
        }
    }

    return result;
}

fn shiftRotate16(cpu: *Cpu, op: u3, value: u16, count: u5) u16 {
    if (count == 0) return value;

    var result: u16 = value;
    var cf = cpu.flags.carry;

    switch (op) {
        0 => { // ROL
            const masked = count & 15;
            result = (value << @truncate(masked)) | (value >> @truncate(16 - masked));
            cf = (result & 1) != 0;
        },
        1 => { // ROR
            const masked = count & 15;
            result = (value >> @truncate(masked)) | (value << @truncate(16 - masked));
            cf = (result & 0x8000) != 0;
        },
        2 => { // RCL
            for (0..count) |_| {
                const new_cf = (result & 0x8000) != 0;
                result = (result << 1) | @as(u16, @intFromBool(cf));
                cf = new_cf;
            }
        },
        3 => { // RCR
            for (0..count) |_| {
                const new_cf = (result & 1) != 0;
                result = (result >> 1) | (@as(u16, @intFromBool(cf)) << 15);
                cf = new_cf;
            }
        },
        4, 6 => { // SHL/SAL
            cf = (value >> @truncate(16 - count)) & 1 != 0;
            result = value << @truncate(count);
        },
        5 => { // SHR
            cf = (value >> @truncate(count - 1)) & 1 != 0;
            result = value >> @truncate(count);
        },
        7 => { // SAR
            cf = (value >> @truncate(count - 1)) & 1 != 0;
            const signed: i16 = @bitCast(value);
            result = @bitCast(signed >> @truncate(count));
        },
    }

    cpu.flags.carry = cf;
    if (op >= 4) {
        cpu.flags.zero = result == 0;
        cpu.flags.sign = (result & 0x8000) != 0;
        cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;
        if (count == 1) {
            cpu.flags.overflow = switch (op) {
                4, 6 => (result & 0x8000) != (value & 0x8000),
                5 => (value & 0x8000) != 0,
                7 => false,
                else => false,
            };
        }
    }

    return result;
}

fn shiftRotate32(cpu: *Cpu, op: u3, value: u32, count: u5) u32 {
    if (count == 0) return value;

    var result: u32 = value;
    var cf = cpu.flags.carry;

    switch (op) {
        0 => { // ROL
            result = (value << count) | (value >> @truncate(32 - @as(u6, count)));
            cf = (result & 1) != 0;
        },
        1 => { // ROR
            result = (value >> count) | (value << @truncate(32 - @as(u6, count)));
            cf = (result & 0x80000000) != 0;
        },
        2 => { // RCL
            for (0..count) |_| {
                const new_cf = (result & 0x80000000) != 0;
                result = (result << 1) | @as(u32, @intFromBool(cf));
                cf = new_cf;
            }
        },
        3 => { // RCR
            for (0..count) |_| {
                const new_cf = (result & 1) != 0;
                result = (result >> 1) | (@as(u32, @intFromBool(cf)) << 31);
                cf = new_cf;
            }
        },
        4, 6 => { // SHL/SAL
            cf = (value >> @truncate(32 - @as(u6, count))) & 1 != 0;
            result = value << count;
        },
        5 => { // SHR
            cf = (value >> @truncate(count - 1)) & 1 != 0;
            result = value >> count;
        },
        7 => { // SAR
            cf = (value >> @truncate(count - 1)) & 1 != 0;
            const signed: i32 = @bitCast(value);
            result = @bitCast(signed >> count);
        },
    }

    cpu.flags.carry = cf;
    if (op >= 4) {
        cpu.flags.zero = result == 0;
        cpu.flags.sign = (result & 0x80000000) != 0;
        cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;
        if (count == 1) {
            cpu.flags.overflow = switch (op) {
                4, 6 => (result & 0x80000000) != (value & 0x80000000),
                5 => (value & 0x80000000) != 0,
                7 => false,
                else => false,
            };
        }
    }

    return result;
}

/// SHLD - Shift left double (32-bit)
fn shld32(cpu: *Cpu, dest: u32, src: u32, count_in: u8) u32 {
    // Count is masked to 5 bits (0-31)
    const count = count_in & 0x1F;
    if (count == 0) return dest;

    var result: u32 = undefined;
    var cf: bool = undefined;

    if (count <= 32) {
        // Shift destination left by count, fill from source's high bits
        result = (dest << @truncate(count)) | (src >> @truncate(32 - count));
        // CF = last bit shifted out from dest
        cf = ((dest >> @truncate(32 - count)) & 1) != 0;
    } else {
        // Undefined behavior for count > 32, but we handle it anyway
        result = dest;
        cf = false;
    }

    cpu.flags.carry = cf;
    cpu.flags.zero = result == 0;
    cpu.flags.sign = (result & 0x80000000) != 0;
    cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;

    // OF is defined only for 1-bit shifts
    if (count == 1) {
        cpu.flags.overflow = (result & 0x80000000) != (dest & 0x80000000);
    }
    // OF is undefined for count > 1

    return result;
}

/// SHLD - Shift left double (16-bit)
fn shld16(cpu: *Cpu, dest: u16, src: u16, count_in: u8) u16 {
    // Count is masked to 5 bits, but only 0-15 are meaningful for 16-bit
    const count = count_in & 0x1F;
    if (count == 0) return dest;

    var result: u16 = undefined;
    var cf: bool = undefined;

    if (count <= 16) {
        // Shift destination left by count, fill from source's high bits
        result = (dest << @truncate(count)) | (src >> @truncate(16 - count));
        // CF = last bit shifted out from dest
        cf = ((dest >> @truncate(16 - count)) & 1) != 0;
    } else {
        // For count > 16, behavior continues with wrapping
        const effective_count = count & 0x0F; // Wrap around for 16-bit
        if (effective_count == 0) {
            result = dest;
            cf = (dest & 1) != 0;
        } else {
            result = (dest << @truncate(effective_count)) | (src >> @truncate(16 - effective_count));
            cf = ((dest >> @truncate(16 - effective_count)) & 1) != 0;
        }
    }

    cpu.flags.carry = cf;
    cpu.flags.zero = result == 0;
    cpu.flags.sign = (result & 0x8000) != 0;
    cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;

    if (count == 1) {
        cpu.flags.overflow = (result & 0x8000) != (dest & 0x8000);
    }

    return result;
}

/// SHRD - Shift right double (32-bit)
fn shrd32(cpu: *Cpu, dest: u32, src: u32, count_in: u8) u32 {
    // Count is masked to 5 bits (0-31)
    const count = count_in & 0x1F;
    if (count == 0) return dest;

    var result: u32 = undefined;
    var cf: bool = undefined;

    if (count <= 32) {
        // Shift destination right by count, fill from source's low bits
        result = (dest >> @truncate(count)) | (src << @truncate(32 - count));
        // CF = last bit shifted out from dest
        cf = ((dest >> @truncate(count - 1)) & 1) != 0;
    } else {
        // Undefined behavior for count > 32
        result = dest;
        cf = false;
    }

    cpu.flags.carry = cf;
    cpu.flags.zero = result == 0;
    cpu.flags.sign = (result & 0x80000000) != 0;
    cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;

    // OF is defined only for 1-bit shifts
    if (count == 1) {
        // OF = MSB changed
        cpu.flags.overflow = (result & 0x80000000) != (dest & 0x80000000);
    }

    return result;
}

/// SHRD - Shift right double (16-bit)
fn shrd16(cpu: *Cpu, dest: u16, src: u16, count_in: u8) u16 {
    // Count is masked to 5 bits
    const count = count_in & 0x1F;
    if (count == 0) return dest;

    var result: u16 = undefined;
    var cf: bool = undefined;

    if (count <= 16) {
        // Shift destination right by count, fill from source's low bits
        result = (dest >> @truncate(count)) | (src << @truncate(16 - count));
        // CF = last bit shifted out from dest
        cf = ((dest >> @truncate(count - 1)) & 1) != 0;
    } else {
        // For count > 16, behavior continues
        const effective_count = count & 0x0F;
        if (effective_count == 0) {
            result = dest;
            cf = (dest & 0x8000) != 0;
        } else {
            result = (dest >> @truncate(effective_count)) | (src << @truncate(16 - effective_count));
            cf = ((dest >> @truncate(effective_count - 1)) & 1) != 0;
        }
    }

    cpu.flags.carry = cf;
    cpu.flags.zero = result == 0;
    cpu.flags.sign = (result & 0x8000) != 0;
    cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;

    if (count == 1) {
        cpu.flags.overflow = (result & 0x8000) != (dest & 0x8000);
    }

    return result;
}

/// Execute Group 3 instructions (unary operations: TEST, NOT, NEG, MUL, IMUL, DIV, IDIV)
fn executeGroup3(cpu: *Cpu, opcode: u8) !void {
    const modrm = try fetchModRM(cpu);

    if (opcode == 0xF6) {
        // 8-bit operations
        switch (modrm.reg) {
            0, 1 => { // TEST r/m8, imm8
                const value = try readRM8(cpu, modrm);
                const imm = try fetchByte(cpu);
                const result = value & imm;
                cpu.flags.updateArithmetic8(result, false, false);
            },
            2 => { // NOT r/m8
                const value = try readRM8(cpu, modrm);
                try writeRM8(cpu, modrm, ~value);
            },
            3 => { // NEG r/m8
                const value = try readRM8(cpu, modrm);
                const result = 0 -% value;
                cpu.flags.carry = value != 0;
                cpu.flags.overflow = value == 0x80;
                cpu.flags.zero = result == 0;
                cpu.flags.sign = (result & 0x80) != 0;
                cpu.flags.parity = @popCount(result) % 2 == 0;
                try writeRM8(cpu, modrm, result);
            },
            4 => { // MUL AL, r/m8
                const value = try readRM8(cpu, modrm);
                const al: u8 = @truncate(cpu.regs.eax);
                const result: u16 = @as(u16, al) * @as(u16, value);
                cpu.regs.setReg16(0, result); // AX = AL * r/m8
                cpu.flags.carry = (result >> 8) != 0;
                cpu.flags.overflow = cpu.flags.carry;
            },
            5 => { // IMUL AL, r/m8
                const value: i8 = @bitCast(try readRM8(cpu, modrm));
                const al: i8 = @bitCast(@as(u8, @truncate(cpu.regs.eax)));
                const result: i16 = @as(i16, al) * @as(i16, value);
                cpu.regs.setReg16(0, @bitCast(result));
                const ah: i8 = @truncate(result >> 8);
                const sign_extended = (result >> 7) == 0 or (result >> 7) == -1;
                cpu.flags.carry = !sign_extended;
                cpu.flags.overflow = !sign_extended;
                _ = ah;
            },
            6 => { // DIV AX, r/m8
                const divisor = try readRM8(cpu, modrm);
                if (divisor == 0) return CpuError.DivisionByZero;
                const dividend: u16 = cpu.regs.getReg16(0);
                const quotient = dividend / @as(u16, divisor);
                const remainder = dividend % @as(u16, divisor);
                if (quotient > 0xFF) return CpuError.DivisionByZero; // Overflow
                cpu.regs.setReg8(0, @truncate(quotient)); // AL
                cpu.regs.setReg8(4, @truncate(remainder)); // AH
            },
            7 => { // IDIV AX, r/m8
                const divisor: i8 = @bitCast(try readRM8(cpu, modrm));
                if (divisor == 0) return CpuError.DivisionByZero;
                const dividend: i16 = @bitCast(cpu.regs.getReg16(0));
                const quotient = @divTrunc(dividend, @as(i16, divisor));
                const remainder = @rem(dividend, @as(i16, divisor));
                if (quotient > 127 or quotient < -128) return CpuError.DivisionByZero;
                cpu.regs.setReg8(0, @bitCast(@as(i8, @truncate(quotient)))); // AL
                cpu.regs.setReg8(4, @bitCast(@as(i8, @truncate(remainder)))); // AH
            },
        }
    } else {
        // 32-bit operations (or 16-bit with prefix)
        if (cpu.prefix.operand_size_override) {
            switch (modrm.reg) {
                0, 1 => { // TEST r/m16, imm16
                    const value = try readRM16(cpu, modrm);
                    const imm = try fetchWord(cpu);
                    const result = value & imm;
                    cpu.flags.updateArithmetic16(result, false, false);
                },
                2 => { // NOT r/m16
                    const value = try readRM16(cpu, modrm);
                    try writeRM16(cpu, modrm, ~value);
                },
                3 => { // NEG r/m16
                    const value = try readRM16(cpu, modrm);
                    const result = 0 -% value;
                    cpu.flags.carry = value != 0;
                    cpu.flags.overflow = value == 0x8000;
                    cpu.flags.zero = result == 0;
                    cpu.flags.sign = (result & 0x8000) != 0;
                    cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;
                    try writeRM16(cpu, modrm, result);
                },
                4 => { // MUL DX:AX, r/m16
                    const value = try readRM16(cpu, modrm);
                    const ax: u16 = cpu.regs.getReg16(0);
                    const result: u32 = @as(u32, ax) * @as(u32, value);
                    cpu.regs.setReg16(0, @truncate(result)); // AX
                    cpu.regs.setReg16(2, @truncate(result >> 16)); // DX
                    cpu.flags.carry = (result >> 16) != 0;
                    cpu.flags.overflow = cpu.flags.carry;
                },
                5 => { // IMUL DX:AX, r/m16
                    const value: i16 = @bitCast(try readRM16(cpu, modrm));
                    const ax: i16 = @bitCast(cpu.regs.getReg16(0));
                    const result: i32 = @as(i32, ax) * @as(i32, value);
                    cpu.regs.setReg16(0, @truncate(@as(u32, @bitCast(result)))); // AX
                    cpu.regs.setReg16(2, @truncate(@as(u32, @bitCast(result)) >> 16)); // DX
                    const sign_extended = (result >> 15) == 0 or (result >> 15) == -1;
                    cpu.flags.carry = !sign_extended;
                    cpu.flags.overflow = !sign_extended;
                },
                6 => { // DIV DX:AX, r/m16
                    const divisor = try readRM16(cpu, modrm);
                    if (divisor == 0) return CpuError.DivisionByZero;
                    const dividend: u32 = (@as(u32, cpu.regs.getReg16(2)) << 16) | @as(u32, cpu.regs.getReg16(0));
                    const quotient = dividend / @as(u32, divisor);
                    const remainder = dividend % @as(u32, divisor);
                    if (quotient > 0xFFFF) return CpuError.DivisionByZero;
                    cpu.regs.setReg16(0, @truncate(quotient)); // AX
                    cpu.regs.setReg16(2, @truncate(remainder)); // DX
                },
                7 => { // IDIV DX:AX, r/m16
                    const divisor: i16 = @bitCast(try readRM16(cpu, modrm));
                    if (divisor == 0) return CpuError.DivisionByZero;
                    const dividend: i32 = @bitCast((@as(u32, cpu.regs.getReg16(2)) << 16) | @as(u32, cpu.regs.getReg16(0)));
                    const quotient = @divTrunc(dividend, @as(i32, divisor));
                    const remainder = @rem(dividend, @as(i32, divisor));
                    if (quotient > 32767 or quotient < -32768) return CpuError.DivisionByZero;
                    cpu.regs.setReg16(0, @bitCast(@as(i16, @truncate(quotient)))); // AX
                    cpu.regs.setReg16(2, @bitCast(@as(i16, @truncate(remainder)))); // DX
                },
            }
        } else {
            switch (modrm.reg) {
                0, 1 => { // TEST r/m32, imm32
                    const value = try readRM32(cpu, modrm);
                    const imm = try fetchDword(cpu);
                    const result = value & imm;
                    cpu.flags.updateArithmetic32(result, false, false);
                },
                2 => { // NOT r/m32
                    const value = try readRM32(cpu, modrm);
                    try writeRM32(cpu, modrm, ~value);
                },
                3 => { // NEG r/m32
                    const value = try readRM32(cpu, modrm);
                    const result = 0 -% value;
                    cpu.flags.carry = value != 0;
                    cpu.flags.overflow = value == 0x80000000;
                    cpu.flags.zero = result == 0;
                    cpu.flags.sign = (result & 0x80000000) != 0;
                    cpu.flags.parity = @popCount(@as(u8, @truncate(result))) % 2 == 0;
                    try writeRM32(cpu, modrm, result);
                },
                4 => { // MUL EDX:EAX, r/m32
                    const value = try readRM32(cpu, modrm);
                    const result: u64 = @as(u64, cpu.regs.eax) * @as(u64, value);
                    cpu.regs.eax = @truncate(result);
                    cpu.regs.edx = @truncate(result >> 32);
                    cpu.flags.carry = cpu.regs.edx != 0;
                    cpu.flags.overflow = cpu.flags.carry;
                },
                5 => { // IMUL EDX:EAX, r/m32
                    const value: i32 = @bitCast(try readRM32(cpu, modrm));
                    const eax: i32 = @bitCast(cpu.regs.eax);
                    const result: i64 = @as(i64, eax) * @as(i64, value);
                    cpu.regs.eax = @truncate(@as(u64, @bitCast(result)));
                    cpu.regs.edx = @truncate(@as(u64, @bitCast(result)) >> 32);
                    const sign_extended = (result >> 31) == 0 or (result >> 31) == -1;
                    cpu.flags.carry = !sign_extended;
                    cpu.flags.overflow = !sign_extended;
                },
                6 => { // DIV EDX:EAX, r/m32
                    const divisor = try readRM32(cpu, modrm);
                    if (divisor == 0) return CpuError.DivisionByZero;
                    const dividend: u64 = (@as(u64, cpu.regs.edx) << 32) | @as(u64, cpu.regs.eax);
                    const quotient = dividend / @as(u64, divisor);
                    const remainder = dividend % @as(u64, divisor);
                    if (quotient > 0xFFFFFFFF) return CpuError.DivisionByZero;
                    cpu.regs.eax = @truncate(quotient);
                    cpu.regs.edx = @truncate(remainder);
                },
                7 => { // IDIV EDX:EAX, r/m32
                    const divisor: i32 = @bitCast(try readRM32(cpu, modrm));
                    if (divisor == 0) return CpuError.DivisionByZero;
                    const dividend: i64 = @bitCast((@as(u64, cpu.regs.edx) << 32) | @as(u64, cpu.regs.eax));
                    const quotient = @divTrunc(dividend, @as(i64, divisor));
                    const remainder = @rem(dividend, @as(i64, divisor));
                    if (quotient > 2147483647 or quotient < -2147483648) return CpuError.DivisionByZero;
                    cpu.regs.eax = @bitCast(@as(i32, @truncate(quotient)));
                    cpu.regs.edx = @bitCast(@as(i32, @truncate(remainder)));
                },
            }
        }
    }
}

// Helper functions

/// Fetch byte from instruction stream (uses paged memory)
fn fetchByte(cpu: *Cpu) !u8 {
    return cpu.fetchByte();
}

/// Fetch word from instruction stream (uses paged memory)
fn fetchWord(cpu: *Cpu) !u16 {
    return cpu.fetchWord();
}

/// Fetch dword from instruction stream (uses paged memory)
fn fetchDword(cpu: *Cpu) !u32 {
    return cpu.fetchDword();
}

fn fetchModRM(cpu: *Cpu) !ModRM {
    const byte = try fetchByte(cpu);
    return decodeModRM(byte);
}

fn readRM8(cpu: *Cpu, modrm: ModRM) !u8 {
    if (modrm.mod == 3) {
        return cpu.regs.getReg8(modrm.rm);
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    return cpu.readMemByte(addr);
}

fn readRM16(cpu: *Cpu, modrm: ModRM) !u16 {
    if (modrm.mod == 3) {
        return cpu.regs.getReg16(modrm.rm);
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    return cpu.readMemWord(addr);
}

fn readRM32(cpu: *Cpu, modrm: ModRM) !u32 {
    if (modrm.mod == 3) {
        return cpu.regs.getReg32(modrm.rm);
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    return cpu.readMemDword(addr);
}

fn writeRM8(cpu: *Cpu, modrm: ModRM, value: u8) !void {
    if (modrm.mod == 3) {
        cpu.regs.setReg8(modrm.rm, value);
        return;
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    try cpu.writeMemByte(addr, value);
}

fn writeRM16(cpu: *Cpu, modrm: ModRM, value: u16) !void {
    if (modrm.mod == 3) {
        cpu.regs.setReg16(modrm.rm, value);
        return;
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    try cpu.writeMemWord(addr, value);
}

fn writeRM32(cpu: *Cpu, modrm: ModRM, value: u32) !void {
    if (modrm.mod == 3) {
        cpu.regs.setReg32(modrm.rm, value);
        return;
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    try cpu.writeMemDword(addr, value);
}

fn calculateEffectiveAddress(cpu: *Cpu, modrm: ModRM) !u32 {
    // Simplified 32-bit addressing
    var base: u32 = 0;

    switch (modrm.rm) {
        0 => base = cpu.regs.eax,
        1 => base = cpu.regs.ecx,
        2 => base = cpu.regs.edx,
        3 => base = cpu.regs.ebx,
        4 => {
            // SIB byte
            const sib = try fetchByte(cpu);
            base = decodeSIB(cpu, sib);
        },
        5 => {
            if (modrm.mod == 0) {
                base = try fetchDword(cpu);
            } else {
                base = cpu.regs.ebp;
            }
        },
        6 => base = cpu.regs.esi,
        7 => base = cpu.regs.edi,
    }

    // Add displacement
    switch (modrm.mod) {
        0 => {},
        1 => {
            const disp: i8 = @bitCast(try fetchByte(cpu));
            base = @bitCast(@as(i32, @bitCast(base)) +% disp);
        },
        2 => {
            const disp: i32 = @bitCast(try fetchDword(cpu));
            base = @bitCast(@as(i32, @bitCast(base)) +% disp);
        },
        3 => {}, // Register direct, handled elsewhere
    }

    return base;
}

fn decodeSIB(cpu: *const Cpu, sib: u8) u32 {
    const scale: u2 = @truncate((sib >> 6) & 0x3);
    const index: u3 = @truncate((sib >> 3) & 0x7);
    const base_reg: u3 = @truncate(sib & 0x7);

    var base: u32 = cpu.regs.getReg32(base_reg);

    if (index != 4) {
        // ESP cannot be used as index
        const index_val = cpu.regs.getReg32(index);
        base +%= index_val << scale;
    }

    return base;
}

fn addWithFlags8(cpu: *Cpu, a: u8, b: u8) u8 {
    const result_full = @as(u16, a) + @as(u16, b);
    const result: u8 = @truncate(result_full);
    const carry = result_full > 0xFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x80) != 0;
    // Auxiliary flag: carry from bit 3 to bit 4
    cpu.flags.auxiliary = ((a & 0xF) + (b & 0xF)) > 0xF;
    cpu.flags.updateArithmetic8(result, carry, overflow);
    return result;
}

fn addWithFlags16(cpu: *Cpu, a: u16, b: u16) u16 {
    const result_full = @as(u32, a) + @as(u32, b);
    const result: u16 = @truncate(result_full);
    const carry = result_full > 0xFFFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x8000) != 0;
    // Auxiliary flag: carry from bit 3 to bit 4
    cpu.flags.auxiliary = ((a & 0xF) + (b & 0xF)) > 0xF;
    cpu.flags.updateArithmetic16(result, carry, overflow);
    return result;
}

fn addWithFlags32(cpu: *Cpu, a: u32, b: u32) u32 {
    const result_full = @as(u64, a) + @as(u64, b);
    const result: u32 = @truncate(result_full);
    const carry = result_full > 0xFFFFFFFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x80000000) != 0;
    // Auxiliary flag: carry from bit 3 to bit 4
    cpu.flags.auxiliary = ((a & 0xF) + (b & 0xF)) > 0xF;
    cpu.flags.updateArithmetic32(result, carry, overflow);
    return result;
}

fn subWithFlags8(cpu: *Cpu, a: u8, b: u8) u8 {
    const result = a -% b;
    const carry = a < b;
    const overflow = ((a ^ b) & (a ^ result) & 0x80) != 0;
    cpu.flags.updateArithmetic8(result, carry, overflow);
    return result;
}

fn subWithFlags16(cpu: *Cpu, a: u16, b: u16) u16 {
    const result = a -% b;
    const carry = a < b;
    const overflow = ((a ^ b) & (a ^ result) & 0x8000) != 0;
    cpu.flags.updateArithmetic16(result, carry, overflow);
    return result;
}

fn subWithFlags32(cpu: *Cpu, a: u32, b: u32) u32 {
    const result = a -% b;
    const carry = a < b;
    const overflow = ((a ^ b) & (a ^ result) & 0x80000000) != 0;
    cpu.flags.updateArithmetic32(result, carry, overflow);
    return result;
}


// ADC (Add with Carry) helpers
fn adcWithFlags8(cpu: *Cpu, a: u8, b: u8) u8 {
    const carry_in: u8 = if (cpu.flags.carry) 1 else 0;
    const result_full = @as(u16, a) + @as(u16, b) + @as(u16, carry_in);
    const result: u8 = @truncate(result_full);
    const carry = result_full > 0xFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x80) != 0;
    cpu.flags.updateArithmetic8(result, carry, overflow);
    // Set auxiliary flag for carry from bit 3 to bit 4
    cpu.flags.auxiliary = ((a & 0x0F) + (b & 0x0F) + carry_in) > 0x0F;
    return result;
}

fn adcWithFlags16(cpu: *Cpu, a: u16, b: u16) u16 {
    const carry_in: u16 = if (cpu.flags.carry) 1 else 0;
    const result_full = @as(u32, a) + @as(u32, b) + @as(u32, carry_in);
    const result: u16 = @truncate(result_full);
    const carry = result_full > 0xFFFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x8000) != 0;
    cpu.flags.updateArithmetic16(result, carry, overflow);
    // Set auxiliary flag for carry from bit 3 to bit 4
    cpu.flags.auxiliary = ((a & 0x0F) + (b & 0x0F) + carry_in) > 0x0F;
    return result;
}

fn adcWithFlags32(cpu: *Cpu, a: u32, b: u32) u32 {
    const carry_in: u32 = if (cpu.flags.carry) 1 else 0;
    const result_full = @as(u64, a) + @as(u64, b) + @as(u64, carry_in);
    const result: u32 = @truncate(result_full);
    const carry = result_full > 0xFFFFFFFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x80000000) != 0;
    cpu.flags.updateArithmetic32(result, carry, overflow);
    // Set auxiliary flag for carry from bit 3 to bit 4
    cpu.flags.auxiliary = ((a & 0x0F) + (b & 0x0F) + carry_in) > 0x0F;
    return result;
}

// SBB (Subtract with Borrow) helpers
fn sbbWithFlags8(cpu: *Cpu, a: u8, b: u8) u8 {
    const borrow_in: u8 = if (cpu.flags.carry) 1 else 0;
    const result = a -% b -% borrow_in;
    const carry = (@as(u16, a) < (@as(u16, b) + @as(u16, borrow_in)));
    const overflow = ((a ^ b) & (a ^ result) & 0x80) != 0;
    cpu.flags.updateArithmetic8(result, carry, overflow);
    // Set auxiliary flag for borrow from bit 4 to bit 3
    cpu.flags.auxiliary = (@as(i8, @bitCast(a & 0x0F)) - @as(i8, @bitCast(b & 0x0F)) - @as(i8, @bitCast(borrow_in))) < 0;
    return result;
}

fn sbbWithFlags16(cpu: *Cpu, a: u16, b: u16) u16 {
    const borrow_in: u16 = if (cpu.flags.carry) 1 else 0;
    const result = a -% b -% borrow_in;
    const carry = (@as(u32, a) < (@as(u32, b) + @as(u32, borrow_in)));
    const overflow = ((a ^ b) & (a ^ result) & 0x8000) != 0;
    cpu.flags.updateArithmetic16(result, carry, overflow);
    // Set auxiliary flag for borrow from bit 4 to bit 3
    cpu.flags.auxiliary = (@as(i16, @bitCast(a & 0x0F)) - @as(i16, @bitCast(b & 0x0F)) - @as(i16, @bitCast(borrow_in))) < 0;
    return result;
}

fn sbbWithFlags32(cpu: *Cpu, a: u32, b: u32) u32 {
    const borrow_in: u32 = if (cpu.flags.carry) 1 else 0;
    const result = a -% b -% borrow_in;
    const carry = (@as(u64, a) < (@as(u64, b) + @as(u64, borrow_in)));
    const overflow = ((a ^ b) & (a ^ result) & 0x80000000) != 0;
    cpu.flags.updateArithmetic32(result, carry, overflow);
    // Set auxiliary flag for borrow from bit 4 to bit 3
    cpu.flags.auxiliary = (@as(i32, @bitCast(a & 0x0F)) - @as(i32, @bitCast(b & 0x0F)) - @as(i32, @bitCast(borrow_in))) < 0;
    return result;
}
// String instruction helpers
fn execMovs(cpu: *Cpu, size: u8) !void {
    const rep_prefix = cpu.prefix.rep;
    const delta: i32 = if (cpu.flags.direction) -@as(i32, size) else @as(i32, size);

    switch (rep_prefix) {
        .rep, .repne => {
            // REP prefix - repeat while ECX != 0
            while (cpu.regs.ecx != 0) {
                // Move one element
                switch (size) {
                    1 => {
                        const value = try cpu.readMemByte(cpu.regs.esi);
                        try cpu.writeMemByte(cpu.regs.edi, value);
                    },
                    2 => {
                        const value = try cpu.readMemWord(cpu.regs.esi);
                        try cpu.writeMemWord(cpu.regs.edi, value);
                    },
                    4 => {
                        const value = try cpu.readMemDword(cpu.regs.esi);
                        try cpu.writeMemDword(cpu.regs.edi, value);
                    },
                    else => unreachable,
                }

                // Update pointers and counter
                cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
                cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
                cpu.regs.ecx -%= 1;
            }
        },
        .none => {
            // No REP prefix - execute once
            switch (size) {
                1 => {
                    const value = try cpu.readMemByte(cpu.regs.esi);
                    try cpu.writeMemByte(cpu.regs.edi, value);
                },
                2 => {
                    const value = try cpu.readMemWord(cpu.regs.esi);
                    try cpu.writeMemWord(cpu.regs.edi, value);
                },
                4 => {
                    const value = try cpu.readMemDword(cpu.regs.esi);
                    try cpu.writeMemDword(cpu.regs.edi, value);
                },
                else => unreachable,
            }

            // Update pointers
            cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
            cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
        },
    }
}

fn execCmps(cpu: *Cpu, size: u8) !void {
    const rep_prefix = cpu.prefix.rep;
    const delta: i32 = if (cpu.flags.direction) -@as(i32, size) else @as(i32, size);

    switch (rep_prefix) {
        .rep => {
            // REPE/REPZ - repeat while ECX != 0 and ZF = 1
            while (cpu.regs.ecx != 0) {
                switch (size) {
                    1 => {
                        const src = try cpu.readMemByte(cpu.regs.esi);
                        const dst = try cpu.readMemByte(cpu.regs.edi);
                        _ = subWithFlags8(cpu, src, dst);
                    },
                    2 => {
                        const src = try cpu.readMemWord(cpu.regs.esi);
                        const dst = try cpu.readMemWord(cpu.regs.edi);
                        _ = subWithFlags16(cpu, src, dst);
                    },
                    4 => {
                        const src = try cpu.readMemDword(cpu.regs.esi);
                        const dst = try cpu.readMemDword(cpu.regs.edi);
                        _ = subWithFlags32(cpu, src, dst);
                    },
                    else => unreachable,
                }

                cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
                cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
                cpu.regs.ecx -%= 1;

                // REPE: break if ZF = 0 (not equal)
                if (!cpu.flags.zero) break;
            }
        },
        .repne => {
            // REPNE/REPNZ - repeat while ECX != 0 and ZF = 0
            while (cpu.regs.ecx != 0) {
                switch (size) {
                    1 => {
                        const src = try cpu.readMemByte(cpu.regs.esi);
                        const dst = try cpu.readMemByte(cpu.regs.edi);
                        _ = subWithFlags8(cpu, src, dst);
                    },
                    2 => {
                        const src = try cpu.readMemWord(cpu.regs.esi);
                        const dst = try cpu.readMemWord(cpu.regs.edi);
                        _ = subWithFlags16(cpu, src, dst);
                    },
                    4 => {
                        const src = try cpu.readMemDword(cpu.regs.esi);
                        const dst = try cpu.readMemDword(cpu.regs.edi);
                        _ = subWithFlags32(cpu, src, dst);
                    },
                    else => unreachable,
                }

                cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
                cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
                cpu.regs.ecx -%= 1;

                // REPNE: break if ZF = 1 (equal)
                if (cpu.flags.zero) break;
            }
        },
        .none => {
            // No REP prefix - execute once
            switch (size) {
                1 => {
                    const src = try cpu.readMemByte(cpu.regs.esi);
                    const dst = try cpu.readMemByte(cpu.regs.edi);
                    _ = subWithFlags8(cpu, src, dst);
                },
                2 => {
                    const src = try cpu.readMemWord(cpu.regs.esi);
                    const dst = try cpu.readMemWord(cpu.regs.edi);
                    _ = subWithFlags16(cpu, src, dst);
                },
                4 => {
                    const src = try cpu.readMemDword(cpu.regs.esi);
                    const dst = try cpu.readMemDword(cpu.regs.edi);
                    _ = subWithFlags32(cpu, src, dst);
                },
                else => unreachable,
            }

            cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
            cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
        },
    }
}

fn execStos(cpu: *Cpu, size: u8) !void {
    const rep_prefix = cpu.prefix.rep;
    const delta: i32 = if (cpu.flags.direction) -@as(i32, size) else @as(i32, size);

    switch (rep_prefix) {
        .rep, .repne => {
            // REP prefix - repeat while ECX != 0
            while (cpu.regs.ecx != 0) {
                switch (size) {
                    1 => try cpu.writeMemByte(cpu.regs.edi, @truncate(cpu.regs.eax)),
                    2 => try cpu.writeMemWord(cpu.regs.edi, @truncate(cpu.regs.eax)),
                    4 => try cpu.writeMemDword(cpu.regs.edi, cpu.regs.eax),
                    else => unreachable,
                }

                cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
                cpu.regs.ecx -%= 1;
            }
        },
        .none => {
            // No REP prefix - execute once
            switch (size) {
                1 => try cpu.writeMemByte(cpu.regs.edi, @truncate(cpu.regs.eax)),
                2 => try cpu.writeMemWord(cpu.regs.edi, @truncate(cpu.regs.eax)),
                4 => try cpu.writeMemDword(cpu.regs.edi, cpu.regs.eax),
                else => unreachable,
            }

            cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
        },
    }
}

fn execLods(cpu: *Cpu, size: u8) !void {
    const rep_prefix = cpu.prefix.rep;
    const delta: i32 = if (cpu.flags.direction) -@as(i32, size) else @as(i32, size);

    switch (rep_prefix) {
        .rep, .repne => {
            // REP prefix - repeat while ECX != 0 (unusual but valid)
            while (cpu.regs.ecx != 0) {
                switch (size) {
                    1 => cpu.regs.setReg8(0, try cpu.readMemByte(cpu.regs.esi)),
                    2 => cpu.regs.setReg16(0, try cpu.readMemWord(cpu.regs.esi)),
                    4 => cpu.regs.eax = try cpu.readMemDword(cpu.regs.esi),
                    else => unreachable,
                }

                cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
                cpu.regs.ecx -%= 1;
            }
        },
        .none => {
            // No REP prefix - execute once (normal case)
            switch (size) {
                1 => cpu.regs.setReg8(0, try cpu.readMemByte(cpu.regs.esi)),
                2 => cpu.regs.setReg16(0, try cpu.readMemWord(cpu.regs.esi)),
                4 => cpu.regs.eax = try cpu.readMemDword(cpu.regs.esi),
                else => unreachable,
            }

            cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
        },
    }
}

fn execScas(cpu: *Cpu, size: u8) !void {
    const rep_prefix = cpu.prefix.rep;
    const delta: i32 = if (cpu.flags.direction) -@as(i32, size) else @as(i32, size);

    switch (rep_prefix) {
        .rep => {
            // REPE/REPZ - repeat while ECX != 0 and ZF = 1
            while (cpu.regs.ecx != 0) {
                switch (size) {
                    1 => {
                        const value = try cpu.readMemByte(cpu.regs.edi);
                        _ = subWithFlags8(cpu, @truncate(cpu.regs.eax), value);
                    },
                    2 => {
                        const value = try cpu.readMemWord(cpu.regs.edi);
                        _ = subWithFlags16(cpu, @truncate(cpu.regs.eax), value);
                    },
                    4 => {
                        const value = try cpu.readMemDword(cpu.regs.edi);
                        _ = subWithFlags32(cpu, cpu.regs.eax, value);
                    },
                    else => unreachable,
                }

                cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
                cpu.regs.ecx -%= 1;

                // REPE: break if ZF = 0 (not equal)
                if (!cpu.flags.zero) break;
            }
        },
        .repne => {
            // REPNE/REPNZ - repeat while ECX != 0 and ZF = 0
            while (cpu.regs.ecx != 0) {
                switch (size) {
                    1 => {
                        const value = try cpu.readMemByte(cpu.regs.edi);
                        _ = subWithFlags8(cpu, @truncate(cpu.regs.eax), value);
                    },
                    2 => {
                        const value = try cpu.readMemWord(cpu.regs.edi);
                        _ = subWithFlags16(cpu, @truncate(cpu.regs.eax), value);
                    },
                    4 => {
                        const value = try cpu.readMemDword(cpu.regs.edi);
                        _ = subWithFlags32(cpu, cpu.regs.eax, value);
                    },
                    else => unreachable,
                }

                cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
                cpu.regs.ecx -%= 1;

                // REPNE: break if ZF = 1 (equal)
                if (cpu.flags.zero) break;
            }
        },
        .none => {
            // No REP prefix - execute once
            switch (size) {
                1 => {
                    const value = try cpu.readMemByte(cpu.regs.edi);
                    _ = subWithFlags8(cpu, @truncate(cpu.regs.eax), value);
                },
                2 => {
                    const value = try cpu.readMemWord(cpu.regs.edi);
                    _ = subWithFlags16(cpu, @truncate(cpu.regs.eax), value);
                },
                4 => {
                    const value = try cpu.readMemDword(cpu.regs.edi);
                    _ = subWithFlags32(cpu, cpu.regs.eax, value);
                },
                else => unreachable,
            }

            cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
        },
    }
}



// I/O string operations

fn execIns(cpu: *Cpu, size: u8) !void {
    const rep_prefix = cpu.prefix.rep;
    const delta: i32 = if (cpu.flags.direction) -@as(i32, size) else @as(i32, size);
    const port: u16 = @truncate(cpu.regs.edx);

    switch (rep_prefix) {
        .rep, .repne => {
            // REP prefix - repeat while ECX != 0
            while (cpu.regs.ecx != 0) {
                // Read from I/O port DX
                const value = switch (size) {
                    1 => @as(u32, try cpu.inByte(port)),
                    2 => @as(u32, try cpu.inWord(port)),
                    4 => try cpu.inDword(port),
                    else => unreachable,
                };

                // Write to ES:[EDI]
                const addr = cpu.getEffectiveAddress(cpu.segments.es, cpu.regs.edi);
                switch (size) {
                    1 => try cpu.writeMemByte(addr, @truncate(value)),
                    2 => try cpu.writeMemWord(addr, @truncate(value)),
                    4 => try cpu.writeMemDword(addr, value),
                    else => unreachable,
                }

                // Update EDI and decrement ECX
                cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
                cpu.regs.ecx -%= 1;
            }
        },
        .none => {
            // No REP prefix - execute once
            // Read from I/O port DX
            const value = switch (size) {
                1 => @as(u32, try cpu.inByte(port)),
                2 => @as(u32, try cpu.inWord(port)),
                4 => try cpu.inDword(port),
                else => unreachable,
            };

            // Write to ES:[EDI]
            const addr = cpu.getEffectiveAddress(cpu.segments.es, cpu.regs.edi);
            switch (size) {
                1 => try cpu.writeMemByte(addr, @truncate(value)),
                2 => try cpu.writeMemWord(addr, @truncate(value)),
                4 => try cpu.writeMemDword(addr, value),
                else => unreachable,
            }

            // Update EDI
            cpu.regs.edi = @bitCast(@as(i32, @bitCast(cpu.regs.edi)) +% delta);
        },
    }
}

fn execOuts(cpu: *Cpu, size: u8) !void {
    const rep_prefix = cpu.prefix.rep;
    const delta: i32 = if (cpu.flags.direction) -@as(i32, size) else @as(i32, size);
    const port: u16 = @truncate(cpu.regs.edx);

    switch (rep_prefix) {
        .rep, .repne => {
            // REP prefix - repeat while ECX != 0
            while (cpu.regs.ecx != 0) {
                // Read from DS:[ESI]
                const addr = cpu.getEffectiveAddress(cpu.segments.ds, cpu.regs.esi);
                const value = switch (size) {
                    1 => @as(u32, try cpu.readMemByte(addr)),
                    2 => @as(u32, try cpu.readMemWord(addr)),
                    4 => try cpu.readMemDword(addr),
                    else => unreachable,
                };

                // Write to I/O port DX
                switch (size) {
                    1 => try cpu.outByte(port, @truncate(value)),
                    2 => try cpu.outWord(port, @truncate(value)),
                    4 => try cpu.outDword(port, value),
                    else => unreachable,
                }

                // Update ESI and decrement ECX
                cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
                cpu.regs.ecx -%= 1;
            }
        },
        .none => {
            // No REP prefix - execute once
            // Read from DS:[ESI]
            const addr = cpu.getEffectiveAddress(cpu.segments.ds, cpu.regs.esi);
            const value = switch (size) {
                1 => @as(u32, try cpu.readMemByte(addr)),
                2 => @as(u32, try cpu.readMemWord(addr)),
                4 => try cpu.readMemDword(addr),
                else => unreachable,
            };

            // Write to I/O port DX
            switch (size) {
                1 => try cpu.outByte(port, @truncate(value)),
                2 => try cpu.outWord(port, @truncate(value)),
                4 => try cpu.outDword(port, value),
                else => unreachable,
            }

            // Update ESI
            cpu.regs.esi = @bitCast(@as(i32, @bitCast(cpu.regs.esi)) +% delta);
        },
    }
}

fn jccRel8(cpu: *Cpu, condition: bool) !void {
    const rel = try fetchByte(cpu);
    if (condition) {
        const offset: i8 = @bitCast(rel);
        cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
    }
}

fn jccRel32(cpu: *Cpu, condition: bool) !void {
    const rel = try fetchDword(cpu);
    if (condition) {
        const offset: i32 = @bitCast(rel);
        cpu.eip = @bitCast(@as(i32, @bitCast(cpu.eip)) +% offset);
    }
}

fn setCC(cpu: *Cpu, condition: bool) !void {
    const modrm = try fetchModRM(cpu);
    const value: u8 = if (condition) 1 else 0;
    try writeRM8(cpu, modrm, value);
}

/// Check condition code based on CPU flags (for CMOVcc, Jcc, SETcc)
fn checkCondition(cpu: *const Cpu, cc: u8) bool {
    return switch (cc) {
        0 => cpu.flags.overflow, // O
        1 => !cpu.flags.overflow, // NO
        2 => cpu.flags.carry, // B/C/NAE
        3 => !cpu.flags.carry, // AE/NB/NC
        4 => cpu.flags.zero, // E/Z
        5 => !cpu.flags.zero, // NE/NZ
        6 => cpu.flags.carry or cpu.flags.zero, // BE/NA
        7 => !cpu.flags.carry and !cpu.flags.zero, // A/NBE
        8 => cpu.flags.sign, // S
        9 => !cpu.flags.sign, // NS
        10 => cpu.flags.parity, // P/PE
        11 => !cpu.flags.parity, // NP/PO
        12 => cpu.flags.sign != cpu.flags.overflow, // L/NGE
        13 => cpu.flags.sign == cpu.flags.overflow, // GE/NL
        14 => cpu.flags.zero or (cpu.flags.sign != cpu.flags.overflow), // LE/NG
        15 => !cpu.flags.zero and (cpu.flags.sign == cpu.flags.overflow), // G/NLE
        else => unreachable,
    };
}

fn handleInterrupt(cpu: *Cpu, vector: u8) !void {
    // Dispatch interrupt through IDT (protected mode) or IVT (real mode)
    try cpu.dispatchInterrupt(vector);
}

// Tests
test "nop instruction" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    // Write NOP instruction
    try mem.writeByte(0, 0x90);

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 1), cpu.eip);
}

test "mov immediate instructions" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    // MOV AL, 0x42
    try mem.writeByte(0, 0xB0);
    try mem.writeByte(1, 0x42);

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    try cpu.step();

    try std.testing.expectEqual(@as(u8, 0x42), @as(u8, @truncate(cpu.regs.eax)));
}

test "enter instruction: simple (0, 0)" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.esp = 0x1000;
    cpu.regs.ebp = 0x2000;

    // ENTER 0, 0 (0xC8, 0x00, 0x00, 0x00)
    try mem.writeByte(0, 0xC8);
    try mem.writeByte(1, 0x00); // alloc_size low byte
    try mem.writeByte(2, 0x00); // alloc_size high byte
    try mem.writeByte(3, 0x00); // nesting_level

    const initial_esp = cpu.regs.esp;
    const initial_ebp = cpu.regs.ebp;

    try cpu.step();

    // ENTER 0, 0 should:
    // 1. Push EBP (esp -= 4)
    // 2. Set EBP = ESP (frame pointer)
    // 3. ESP -= 0 (no local space)
    try std.testing.expectEqual(initial_esp - 4, cpu.regs.ebp);
    try std.testing.expectEqual(initial_esp - 4, cpu.regs.esp);

    // Verify old EBP was pushed
    const pushed_ebp = try mem.readDword(cpu.regs.esp);
    try std.testing.expectEqual(initial_ebp, pushed_ebp);
}

test "enter instruction: with local space (16, 0)" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.esp = 0x1000;
    cpu.regs.ebp = 0x2000;

    // ENTER 16, 0 (0xC8, 0x10, 0x00, 0x00)
    try mem.writeByte(0, 0xC8);
    try mem.writeByte(1, 0x10); // alloc_size low byte (16)
    try mem.writeByte(2, 0x00); // alloc_size high byte
    try mem.writeByte(3, 0x00); // nesting_level

    const initial_esp = cpu.regs.esp;
    const initial_ebp = cpu.regs.ebp;

    try cpu.step();

    // ENTER 16, 0 should:
    // 1. Push EBP (esp -= 4)
    // 2. Set EBP = ESP (frame pointer)
    // 3. ESP -= 16 (allocate 16 bytes local space)
    try std.testing.expectEqual(initial_esp - 4, cpu.regs.ebp);
    try std.testing.expectEqual(initial_esp - 4 - 16, cpu.regs.esp);

    // Verify old EBP was pushed
    const pushed_ebp = try mem.readDword(cpu.regs.ebp);
    try std.testing.expectEqual(initial_ebp, pushed_ebp);
}

test "enter instruction: with nesting (8, 1)" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.esp = 0x1000;
    cpu.regs.ebp = 0x2000;

    // ENTER 8, 1 (0xC8, 0x08, 0x00, 0x01)
    try mem.writeByte(0, 0xC8);
    try mem.writeByte(1, 0x08); // alloc_size low byte (8)
    try mem.writeByte(2, 0x00); // alloc_size high byte
    try mem.writeByte(3, 0x01); // nesting_level = 1

    const initial_esp = cpu.regs.esp;
    const initial_ebp = cpu.regs.ebp;

    try cpu.step();

    // ENTER 8, 1 should:
    // 1. Push EBP (esp -= 4)                           esp = 0xFFC
    // 2. frame_ptr = ESP                               frame_ptr = 0xFFC
    // 3. Since nesting_level = 1, no additional pushes in the loop (level < 1 is false)
    // 4. Push frame_ptr (esp -= 4)                     esp = 0xFF8
    // 5. Set EBP = frame_ptr                           ebp = 0xFFC
    // 6. ESP -= 8 (allocate 8 bytes local space)      esp = 0xFF0

    try std.testing.expectEqual(initial_esp - 4, cpu.regs.ebp); // EBP = frame_ptr
    try std.testing.expectEqual(initial_esp - 4 - 4 - 8, cpu.regs.esp); // ESP after push + alloc

    // Verify old EBP was pushed at the top
    const pushed_ebp = try mem.readDword(cpu.regs.ebp);
    try std.testing.expectEqual(initial_ebp, pushed_ebp);

    // Verify frame_ptr was pushed (should be at ebp - 4)
    const pushed_frame_ptr = try mem.readDword(cpu.regs.ebp - 4);
    try std.testing.expectEqual(initial_esp - 4, pushed_frame_ptr);
}

test "enter and leave instruction pair" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.esp = 0x1000;
    cpu.regs.ebp = 0x2000;

    // ENTER 16, 0 followed by LEAVE
    try mem.writeByte(0, 0xC8); // ENTER
    try mem.writeByte(1, 0x10); // alloc_size = 16
    try mem.writeByte(2, 0x00);
    try mem.writeByte(3, 0x00); // nesting_level = 0
    try mem.writeByte(4, 0xC9); // LEAVE

    const initial_esp = cpu.regs.esp;
    const initial_ebp = cpu.regs.ebp;

    // Execute ENTER
    try cpu.step();

    // Execute LEAVE
    try cpu.step();

    // After ENTER + LEAVE, we should be back to initial state
    try std.testing.expectEqual(initial_esp, cpu.regs.esp);
    try std.testing.expectEqual(initial_ebp, cpu.regs.ebp);
}

test "wrmsr and rdmsr instructions" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Write test values to MSRs using WRMSR
    // Test IA32_SYSENTER_CS (0x174)
    cpu.regs.ecx = 0x174; // MSR index
    cpu.regs.eax = 0x12345678; // Low 32 bits
    cpu.regs.edx = 0; // High 32 bits

    // WRMSR: 0F 30
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x30);
    try cpu.step();

    // Verify the MSR was written
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.system.msr_sysenter_cs);

    // Reset EIP
    cpu.eip = 2;

    // Read back using RDMSR
    cpu.regs.ecx = 0x174; // Same MSR index
    cpu.regs.eax = 0; // Clear these
    cpu.regs.edx = 0;

    // RDMSR: 0F 32
    try mem.writeByte(2, 0x0F);
    try mem.writeByte(3, 0x32);
    try cpu.step();

    // Verify values were read correctly
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.regs.eax);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.edx);

    // Test IA32_SYSENTER_ESP (0x175)
    cpu.eip = 4;
    cpu.regs.ecx = 0x175;
    cpu.regs.eax = 0xABCDEF00;
    cpu.regs.edx = 0;

    try mem.writeByte(4, 0x0F);
    try mem.writeByte(5, 0x30);
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0xABCDEF00), cpu.system.msr_sysenter_esp);

    // Test IA32_SYSENTER_EIP (0x176)
    cpu.eip = 6;
    cpu.regs.ecx = 0x176;
    cpu.regs.eax = 0x00C0FFEE;
    cpu.regs.edx = 0;

    try mem.writeByte(6, 0x0F);
    try mem.writeByte(7, 0x30);
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0x00C0FFEE), cpu.system.msr_sysenter_eip);
}

test "sysenter instruction" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.mode = .protected; // SYSENTER requires protected mode

    // Set up SYSENTER MSRs
    cpu.system.msr_sysenter_cs = 0x0008; // Kernel code segment (selector 8)
    cpu.system.msr_sysenter_esp = 0xC0000000; // Kernel stack
    cpu.system.msr_sysenter_eip = 0x80000000; // Kernel entry point

    // Set up initial user-mode state
    cpu.segments.cs = 0x001B; // User code segment (RPL=3)
    cpu.segments.ss = 0x0023; // User stack segment (RPL=3)
    cpu.regs.esp = 0x7FFFFFFF; // User stack
    cpu.eip = 0x1000; // User code

    // SYSENTER: 0F 34
    try mem.writeByte(0x1000, 0x0F);
    try mem.writeByte(0x1001, 0x34);

    try cpu.step();

    // Verify SYSENTER behavior:
    // 1. CS should be loaded from MSR (with RPL=0)
    try std.testing.expectEqual(@as(u16, 0x0008), cpu.segments.cs);

    // 2. SS should be CS + 8
    try std.testing.expectEqual(@as(u16, 0x0010), cpu.segments.ss);

    // 3. ESP should be loaded from MSR
    try std.testing.expectEqual(@as(u32, 0xC0000000), cpu.regs.esp);

    // 4. EIP should be loaded from MSR
    try std.testing.expectEqual(@as(u32, 0x80000000), cpu.eip);

    // 5. Should be in protected mode
    try std.testing.expectEqual(cpu_mod.CpuMode.protected, cpu.mode);
}

test "sysexit instruction" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.mode = .protected;

    // Set up SYSENTER MSR (needed for SYSEXIT calculation)
    cpu.system.msr_sysenter_cs = 0x0008; // Kernel code segment

    // Set up kernel mode state
    cpu.segments.cs = 0x0008; // Kernel code segment (RPL=0)
    cpu.segments.ss = 0x0010; // Kernel stack segment (RPL=0)
    cpu.regs.esp = 0xC0000000; // Kernel stack
    cpu.eip = 0x80001000; // Kernel code

    // Set return addresses in ECX (ESP) and EDX (EIP)
    cpu.regs.ecx = 0x7FFFFFFF; // User stack to return to
    cpu.regs.edx = 0x00401000; // User code to return to

    // SYSEXIT: 0F 35
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x35);
    cpu.eip = 0; // Reset to execute our instruction

    try cpu.step();

    // Verify SYSEXIT behavior:
    // 1. CS should be MSR_CS + 16 + 3 (RPL=3)
    // 0x0008 + 16 + 3 = 0x001B
    try std.testing.expectEqual(@as(u16, 0x001B), cpu.segments.cs);

    // 2. SS should be MSR_CS + 24 + 3 (RPL=3)
    // 0x0008 + 24 + 3 = 0x0023
    try std.testing.expectEqual(@as(u16, 0x0023), cpu.segments.ss);

    // 3. ESP should be loaded from ECX
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), cpu.regs.esp);

    // 4. EIP should be loaded from EDX
    try std.testing.expectEqual(@as(u32, 0x00401000), cpu.eip);
}

test "sysenter and sysexit round trip" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.mode = .protected;

    // Configure MSRs
    cpu.system.msr_sysenter_cs = 0x0008;
    cpu.system.msr_sysenter_esp = 0xC0000000;
    cpu.system.msr_sysenter_eip = 0x80000000;

    // User mode initial state
    const user_cs: u16 = 0x001B;
    const user_ss: u16 = 0x0023;
    const user_esp: u32 = 0x7FFFFFFF;
    const user_eip: u32 = 0x1000;

    cpu.segments.cs = user_cs;
    cpu.segments.ss = user_ss;
    cpu.regs.esp = user_esp;

    // Write SYSENTER at user code location
    try mem.writeByte(user_eip, 0x0F);
    try mem.writeByte(user_eip + 1, 0x34);

    // Write SYSEXIT at kernel entry point
    // Kernel needs to set up ECX/EDX with return addresses first
    try mem.writeByte(0x80000000, 0xB9); // MOV ECX, imm32
    try mem.writeDword(0x80000001, user_esp); // User ESP
    try mem.writeByte(0x80000005, 0xBA); // MOV EDX, imm32
    try mem.writeDword(0x80000006, user_eip + 2); // User EIP (after SYSENTER)
    try mem.writeByte(0x8000000A, 0x0F); // SYSEXIT
    try mem.writeByte(0x8000000B, 0x35);

    cpu.eip = user_eip;

    // Execute SYSENTER
    try cpu.step();

    // Verify we're in kernel mode
    try std.testing.expectEqual(@as(u16, 0x0008), cpu.segments.cs);
    try std.testing.expectEqual(@as(u32, 0xC0000000), cpu.regs.esp);
    try std.testing.expectEqual(@as(u32, 0x80000000), cpu.eip);

    // Execute kernel code: MOV ECX, user_esp
    try cpu.step();
    try std.testing.expectEqual(user_esp, cpu.regs.ecx);

    // Execute: MOV EDX, user_eip + 2
    try cpu.step();
    try std.testing.expectEqual(user_eip + 2, cpu.regs.edx);

    // Execute SYSEXIT
    try cpu.step();

    // Verify we're back in user mode
    try std.testing.expectEqual(user_cs, cpu.segments.cs);
    try std.testing.expectEqual(user_ss, cpu.segments.ss);
    try std.testing.expectEqual(user_esp, cpu.regs.esp);
    try std.testing.expectEqual(user_eip + 2, cpu.eip); // After SYSENTER instruction
}

test "cmove instruction - condition true" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up registers
    cpu.regs.eax = 0x12345678;
    cpu.regs.ebx = 0xAABBCCDD;
    cpu.flags.zero = true; // Condition for CMOVE

    // CMOVE EAX, EBX: 0F 44 C3
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x44);
    try mem.writeByte(2, 0xC3); // ModR/M: mod=11 (register), reg=000 (EAX), rm=011 (EBX)

    try cpu.step();

    // EAX should be updated to EBX's value
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), cpu.regs.eax);
    // EBX should be unchanged
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), cpu.regs.ebx);
}

test "cmove instruction - condition false" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up registers
    cpu.regs.eax = 0x12345678;
    cpu.regs.ebx = 0xAABBCCDD;
    cpu.flags.zero = false; // Condition for CMOVE is false

    // CMOVE EAX, EBX: 0F 44 C3
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x44);
    try mem.writeByte(2, 0xC3);

    try cpu.step();

    // EAX should be unchanged
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.regs.eax);
    // EBX should be unchanged
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), cpu.regs.ebx);
}

test "cmovne instruction - condition true" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up registers
    cpu.regs.ecx = 0x11111111;
    cpu.regs.edx = 0x22222222;
    cpu.flags.zero = false; // Condition for CMOVNE

    // CMOVNE ECX, EDX: 0F 45 CA
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x45);
    try mem.writeByte(2, 0xCA); // ModR/M: mod=11, reg=001 (ECX), rm=010 (EDX)

    try cpu.step();

    // ECX should be updated to EDX's value
    try std.testing.expectEqual(@as(u32, 0x22222222), cpu.regs.ecx);
    // EDX should be unchanged
    try std.testing.expectEqual(@as(u32, 0x22222222), cpu.regs.edx);
}

test "cmovl instruction - condition true" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up registers
    cpu.regs.esi = 0x33333333;
    cpu.regs.edi = 0x44444444;
    // CMOVL: SF != OF
    cpu.flags.sign = true;
    cpu.flags.overflow = false;

    // CMOVL ESI, EDI: 0F 4C F7
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x4C);
    try mem.writeByte(2, 0xF7); // ModR/M: mod=11, reg=110 (ESI), rm=111 (EDI)

    try cpu.step();

    // ESI should be updated to EDI's value
    try std.testing.expectEqual(@as(u32, 0x44444444), cpu.regs.esi);
    // EDI should be unchanged
    try std.testing.expectEqual(@as(u32, 0x44444444), cpu.regs.edi);
}

test "cmovg instruction - condition true" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up registers
    cpu.regs.ebp = 0x55555555;
    cpu.regs.esp = 0x66666666;
    // CMOVG: ZF=0 and SF=OF
    cpu.flags.zero = false;
    cpu.flags.sign = true;
    cpu.flags.overflow = true;

    // CMOVG EBP, ESP: 0F 4F EC
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x4F);
    try mem.writeByte(2, 0xEC); // ModR/M: mod=11, reg=101 (EBP), rm=100 (ESP)

    try cpu.step();

    // EBP should be updated to ESP's value
    try std.testing.expectEqual(@as(u32, 0x66666666), cpu.regs.ebp);
    // ESP should be unchanged
    try std.testing.expectEqual(@as(u32, 0x66666666), cpu.regs.esp);
}

test "cmovg instruction - condition false" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up registers
    cpu.regs.ebp = 0x55555555;
    cpu.regs.esp = 0x66666666;
    // CMOVG: ZF=0 and SF=OF (make condition false by setting ZF=1)
    cpu.flags.zero = true; // Condition fails
    cpu.flags.sign = true;
    cpu.flags.overflow = true;

    // CMOVG EBP, ESP: 0F 4F EC
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x4F);
    try mem.writeByte(2, 0xEC);

    try cpu.step();

    // EBP should be unchanged
    try std.testing.expectEqual(@as(u32, 0x55555555), cpu.regs.ebp);
    // ESP should be unchanged
    try std.testing.expectEqual(@as(u32, 0x66666666), cpu.regs.esp);
}

test "cmov 16-bit operands" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up registers
    cpu.regs.eax = 0xAAAA1234;
    cpu.regs.ebx = 0xBBBB5678;
    cpu.flags.zero = true; // CMOVE condition true

    // 66 0F 44 C3: CMOVE AX, BX (16-bit operand size)
    try mem.writeByte(0, 0x66); // Operand size override prefix
    try mem.writeByte(1, 0x0F);
    try mem.writeByte(2, 0x44);
    try mem.writeByte(3, 0xC3);

    try cpu.step();

    // Only AX (low 16 bits of EAX) should be updated
    try std.testing.expectEqual(@as(u32, 0xAAAA5678), cpu.regs.eax);
    // EBX should be unchanged
    try std.testing.expectEqual(@as(u32, 0xBBBB5678), cpu.regs.ebx);
}

test "cmovs and cmovns instructions" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test CMOVS (move if sign)
    cpu.regs.eax = 0x11111111;
    cpu.regs.ebx = 0x22222222;
    cpu.flags.sign = true;

    // CMOVS EAX, EBX: 0F 48 C3
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x48);
    try mem.writeByte(2, 0xC3);

    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0x22222222), cpu.regs.eax);

    // Test CMOVNS (move if not sign)
    cpu.eip = 3;
    cpu.regs.ecx = 0x33333333;
    cpu.regs.edx = 0x44444444;
    cpu.flags.sign = false;

    // CMOVNS ECX, EDX: 0F 49 CA
    try mem.writeByte(3, 0x0F);
    try mem.writeByte(4, 0x49);
    try mem.writeByte(5, 0xCA);

    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0x44444444), cpu.regs.ecx);
}

test "loop instruction: basic countdown" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.ecx = 3;

    // LOOP -2 (loop back to address 0)
    // At address 0: 0xE2, 0xFE (-2 in two's complement)
    try mem.writeByte(0, 0xE2); // LOOP
    try mem.writeByte(1, 0xFE); // -2 offset (goes back to address 0)

    // First iteration: ECX=3, after decrement ECX=2, loop taken
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 0), cpu.eip); // Looped back

    // Second iteration: ECX=2, after decrement ECX=1, loop taken
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 0), cpu.eip); // Looped back

    // Third iteration: ECX=1, after decrement ECX=0, loop not taken
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 2), cpu.eip); // Fell through
}

test "loop instruction: with address size override (CX)" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.ecx = 0x00020003; // ECX high word = 2, CX = 3

    // 0x67 0xE2 0xFE - address size override + LOOP -2
    try mem.writeByte(0, 0x67); // Address size override
    try mem.writeByte(1, 0xE2); // LOOP
    try mem.writeByte(2, 0xFE); // -2 offset

    // First iteration: CX=3, after decrement CX=2, loop taken
    try cpu.step();
    try std.testing.expectEqual(@as(u16, 2), @as(u16, @truncate(cpu.regs.ecx)));
    try std.testing.expectEqual(@as(u32, 0x00020002), cpu.regs.ecx); // High word unchanged
    try std.testing.expectEqual(@as(u32, 0), cpu.eip); // Looped back
}

test "loope instruction: exits when ZF becomes 0" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.ecx = 5;
    cpu.flags.zero = true; // Start with ZF=1

    // LOOPE -2 (loop back to address 0)
    try mem.writeByte(0, 0xE1); // LOOPE/LOOPZ
    try mem.writeByte(1, 0xFE); // -2 offset

    // First iteration: ECX=5, ZF=1, after decrement ECX=4, loop taken
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 4), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 0), cpu.eip); // Looped back

    // Second iteration: ECX=4, ZF=1, after decrement ECX=3, loop taken
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 0), cpu.eip); // Looped back

    // Clear ZF to break the loop
    cpu.flags.zero = false;

    // Third iteration: ECX=3, ZF=0, after decrement ECX=2, loop NOT taken (ZF=0)
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 2), cpu.eip); // Fell through
}

test "loopne instruction: exits when ZF becomes 1" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.ecx = 5;
    cpu.flags.zero = false; // Start with ZF=0

    // LOOPNE -2 (loop back to address 0)
    try mem.writeByte(0, 0xE0); // LOOPNE/LOOPNZ
    try mem.writeByte(1, 0xFE); // -2 offset

    // First iteration: ECX=5, ZF=0, after decrement ECX=4, loop taken
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 4), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 0), cpu.eip); // Looped back

    // Second iteration: ECX=4, ZF=0, after decrement ECX=3, loop taken
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 0), cpu.eip); // Looped back

    // Set ZF to break the loop
    cpu.flags.zero = true;

    // Third iteration: ECX=3, ZF=1, after decrement ECX=2, loop NOT taken (ZF=1)
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 2), cpu.eip); // Fell through
}

test "les instruction: 32-bit far pointer" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up far pointer in memory at address 0x1000
    // Format: 32-bit offset (0x12345678) followed by 16-bit segment (0xABCD)
    try mem.writeDword(0x1000, 0x12345678);
    try mem.writeWord(0x1004, 0xABCD);

    // LES EAX, [0x1000]
    // 0xC4 0x05 (ModR/M: mod=00, reg=000 (EAX), rm=101 (disp32))
    try mem.writeByte(0, 0xC4);
    try mem.writeByte(1, 0x05);
    try mem.writeDword(2, 0x1000);

    cpu.eip = 0;
    try cpu.step();

    // Verify EAX got the offset
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.regs.eax);
    // Verify ES got the segment
    try std.testing.expectEqual(@as(u16, 0xABCD), cpu.segments.es);
}

test "lds instruction: 32-bit far pointer" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up far pointer in memory at address 0x2000
    // Format: 32-bit offset (0x87654321) followed by 16-bit segment (0x1234)
    try mem.writeDword(0x2000, 0x87654321);
    try mem.writeWord(0x2004, 0x1234);

    // LDS EBX, [0x2000]
    // 0xC5 0x1D (ModR/M: mod=00, reg=011 (EBX), rm=101 (disp32))
    try mem.writeByte(0, 0xC5);
    try mem.writeByte(1, 0x1D);
    try mem.writeDword(2, 0x2000);

    cpu.eip = 0;
    try cpu.step();

    // Verify EBX got the offset
    try std.testing.expectEqual(@as(u32, 0x87654321), cpu.regs.ebx);
    // Verify DS got the segment
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.segments.ds);
}

test "lss instruction: 32-bit far pointer" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up far pointer in memory at address 0x3000
    // Format: 32-bit offset (0xFEDCBA98) followed by 16-bit segment (0x5678)
    try mem.writeDword(0x3000, 0xFEDCBA98);
    try mem.writeWord(0x3004, 0x5678);

    // LSS ESP, [0x3000]
    // 0x0F 0xB2 0x25 (ModR/M: mod=00, reg=100 (ESP), rm=101 (disp32))
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xB2);
    try mem.writeByte(2, 0x25);
    try mem.writeDword(3, 0x3000);

    cpu.eip = 0;
    try cpu.step();

    // Verify ESP got the offset
    try std.testing.expectEqual(@as(u32, 0xFEDCBA98), cpu.regs.esp);
    // Verify SS got the segment
    try std.testing.expectEqual(@as(u16, 0x5678), cpu.segments.ss);
}

test "sldt and lldt instructions" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // LLDT AX (load LDTR from AX)
    // 0x0F 0x00 0xD0 (ModR/M: mod=11, reg=010 (LLDT), rm=000 (AX))
    cpu.regs.eax = 0x0028; // Set AX to 0x0028
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x00);
    try mem.writeByte(2, 0xD0);

    cpu.eip = 0;
    try cpu.step();

    // Verify LDTR was loaded
    try std.testing.expectEqual(@as(u16, 0x0028), cpu.system.ldtr);

    // SLDT BX (store LDTR to BX)
    // 0x0F 0x00 0xC3 (ModR/M: mod=11, reg=000 (SLDT), rm=011 (BX))
    try mem.writeByte(3, 0x0F);
    try mem.writeByte(4, 0x00);
    try mem.writeByte(5, 0xC3);

    cpu.eip = 3;
    try cpu.step();

    // Verify LDTR was stored to BX
    try std.testing.expectEqual(@as(u16, 0x0028), cpu.regs.getReg16(3)); // BX
}

test "str and ltr instructions" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // LTR CX (load TR from CX)
    // 0x0F 0x00 0xD9 (ModR/M: mod=11, reg=011 (LTR), rm=001 (CX))
    cpu.regs.ecx = 0x0040; // Set CX to 0x0040
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0x00);
    try mem.writeByte(2, 0xD9);

    cpu.eip = 0;
    try cpu.step();

    // Verify TR was loaded
    try std.testing.expectEqual(@as(u16, 0x0040), cpu.system.tr);

    // STR DX (store TR to DX)
    // 0x0F 0x00 0xCA (ModR/M: mod=11, reg=001 (STR), rm=010 (DX))
    try mem.writeByte(3, 0x0F);
    try mem.writeByte(4, 0x00);
    try mem.writeByte(5, 0xCA);

    cpu.eip = 3;
    try cpu.step();

    // Verify TR was stored to DX
    try std.testing.expectEqual(@as(u16, 0x0040), cpu.regs.getReg16(2)); // DX
}

test "cmpxchg instruction - equal (exchange happens)" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // CMPXCHG EBX, ECX (0x0F 0xB1 0xCB)
    // If EAX == EBX, then EBX = ECX
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xB1);
    try mem.writeByte(2, 0xCB); // ModR/M: mod=11, reg=001 (ECX), rm=011 (EBX)

    cpu.regs.eax = 0x12345678; // Accumulator
    cpu.regs.ebx = 0x12345678; // Destination (equal to EAX)
    cpu.regs.ecx = 0xABCDEF00; // Source

    cpu.eip = 0;
    try cpu.step();

    // Since EAX == EBX, EBX should be updated with ECX value
    try std.testing.expectEqual(@as(u32, 0xABCDEF00), cpu.regs.ebx);
    // EAX should remain unchanged
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.regs.eax);
    // ZF should be set
    try std.testing.expect(cpu.flags.zero);
}

test "cmpxchg instruction - not equal (accumulator updated)" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // CMPXCHG EBX, ECX (0x0F 0xB1 0xCB)
    // If EAX != EBX, then EAX = EBX
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xB1);
    try mem.writeByte(2, 0xCB); // ModR/M: mod=11, reg=001 (ECX), rm=011 (EBX)

    cpu.regs.eax = 0x12345678; // Accumulator
    cpu.regs.ebx = 0x87654321; // Destination (not equal to EAX)
    cpu.regs.ecx = 0xABCDEF00; // Source

    cpu.eip = 0;
    try cpu.step();

    // Since EAX != EBX, EAX should be updated with EBX value
    try std.testing.expectEqual(@as(u32, 0x87654321), cpu.regs.eax);
    // EBX should remain unchanged
    try std.testing.expectEqual(@as(u32, 0x87654321), cpu.regs.ebx);
    // ZF should be clear
    try std.testing.expect(!cpu.flags.zero);
}

test "cmpxchg8 instruction" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // CMPXCHG BL, CL (0x0F 0xB0 0xCB)
    // If AL == BL, then BL = CL
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xB0);
    try mem.writeByte(2, 0xCB); // ModR/M: mod=11, reg=001 (CL), rm=011 (BL)

    cpu.regs.eax = 0x00000042; // AL = 0x42
    cpu.regs.ebx = 0x00000042; // BL = 0x42 (equal to AL)
    cpu.regs.ecx = 0x000000AA; // CL = 0xAA

    cpu.eip = 0;
    try cpu.step();

    // Since AL == BL, BL should be updated with CL value
    try std.testing.expectEqual(@as(u8, 0xAA), cpu.regs.getReg8(3)); // BL
    // AL should remain unchanged
    try std.testing.expectEqual(@as(u8, 0x42), cpu.regs.getReg8(0)); // AL
    // ZF should be set
    try std.testing.expect(cpu.flags.zero);
}

test "xadd instruction - register exchange and add" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // XADD EBX, ECX (0x0F 0xC1 0xCB)
    // TEMP = EBX + ECX, ECX = EBX, EBX = TEMP
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xC1);
    try mem.writeByte(2, 0xCB); // ModR/M: mod=11, reg=001 (ECX), rm=011 (EBX)

    cpu.regs.ebx = 0x00000010; // Destination
    cpu.regs.ecx = 0x00000005; // Source

    cpu.eip = 0;
    try cpu.step();

    // EBX should contain sum (0x10 + 0x05 = 0x15)
    try std.testing.expectEqual(@as(u32, 0x00000015), cpu.regs.ebx);
    // ECX should contain original EBX value (0x10)
    try std.testing.expectEqual(@as(u32, 0x00000010), cpu.regs.ecx);
    // Flags should be updated based on the addition
    try std.testing.expect(!cpu.flags.zero);
    try std.testing.expect(!cpu.flags.carry);
}

test "xadd8 instruction - byte exchange and add" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // XADD BL, CL (0x0F 0xC0 0xCB)
    // TEMP = BL + CL, CL = BL, BL = TEMP
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xC0);
    try mem.writeByte(2, 0xCB); // ModR/M: mod=11, reg=001 (CL), rm=011 (BL)

    cpu.regs.ebx = 0x00000020; // BL = 0x20
    cpu.regs.ecx = 0x00000015; // CL = 0x15

    cpu.eip = 0;
    try cpu.step();

    // BL should contain sum (0x20 + 0x15 = 0x35)
    try std.testing.expectEqual(@as(u8, 0x35), cpu.regs.getReg8(3)); // BL
    // CL should contain original BL value (0x20)
    try std.testing.expectEqual(@as(u8, 0x20), cpu.regs.getReg8(1)); // CL
}

test "cmpxchg8b instruction - equal (exchange happens)" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // CMPXCHG8B [0x100] (0x0F 0xC7 0x0D 0x00 0x01 0x00 0x00)
    // ModR/M: mod=00, reg=001 (CMPXCHG8B), rm=101 (disp32)
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xC7);
    try mem.writeByte(2, 0x0D); // ModR/M: mod=00, reg=001, rm=101
    try mem.writeByte(3, 0x00); // disp32 low byte
    try mem.writeByte(4, 0x01); // disp32
    try mem.writeByte(5, 0x00); // disp32
    try mem.writeByte(6, 0x00); // disp32 high byte

    // Setup memory at 0x100 with 64-bit value 0x87654321_12345678
    try mem.writeDword(0x100, 0x12345678); // Low dword
    try mem.writeDword(0x104, 0x87654321); // High dword

    // Setup registers: EDX:EAX = 0x87654321_12345678 (equal to memory)
    cpu.regs.eax = 0x12345678; // Low dword
    cpu.regs.edx = 0x87654321; // High dword
    // ECX:EBX = 0xAABBCCDD_11223344 (value to write)
    cpu.regs.ebx = 0x11223344; // Low dword
    cpu.regs.ecx = 0xAABBCCDD; // High dword

    cpu.eip = 0;
    try cpu.step();

    // Since EDX:EAX == memory, memory should be updated with ECX:EBX
    try std.testing.expectEqual(@as(u32, 0x11223344), try mem.readDword(0x100));
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), try mem.readDword(0x104));
    // EDX:EAX should remain unchanged
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.regs.eax);
    try std.testing.expectEqual(@as(u32, 0x87654321), cpu.regs.edx);
    // ZF should be set
    try std.testing.expect(cpu.flags.zero);
}

test "cmpxchg8b instruction - not equal (accumulator updated)" {
    const allocator = std.testing.allocator;
    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();

    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // CMPXCHG8B [0x100] (0x0F 0xC7 0x0D 0x00 0x01 0x00 0x00)
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xC7);
    try mem.writeByte(2, 0x0D); // ModR/M: mod=00, reg=001, rm=101
    try mem.writeByte(3, 0x00); // disp32 low byte
    try mem.writeByte(4, 0x01); // disp32
    try mem.writeByte(5, 0x00); // disp32
    try mem.writeByte(6, 0x00); // disp32 high byte

    // Setup memory at 0x100 with 64-bit value 0xFFEEDDCC_AABBCCDD
    try mem.writeDword(0x100, 0xAABBCCDD); // Low dword
    try mem.writeDword(0x104, 0xFFEEDDCC); // High dword

    // Setup registers: EDX:EAX = 0x87654321_12345678 (NOT equal to memory)
    cpu.regs.eax = 0x12345678; // Low dword
    cpu.regs.edx = 0x87654321; // High dword
    // ECX:EBX = 0x11111111_22222222 (value to write - won't be used)
    cpu.regs.ebx = 0x22222222; // Low dword
    cpu.regs.ecx = 0x11111111; // High dword

    cpu.eip = 0;
    try cpu.step();

    // Since EDX:EAX != memory, EDX:EAX should be updated with memory value
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), cpu.regs.eax);
    try std.testing.expectEqual(@as(u32, 0xFFEEDDCC), cpu.regs.edx);
    // Memory should remain unchanged
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), try mem.readDword(0x100));
    try std.testing.expectEqual(@as(u32, 0xFFEEDDCC), try mem.readDword(0x104));
    // ZF should be clear
    try std.testing.expect(!cpu.flags.zero);
}

test "pushad and popad round-trip" {
    const allocator = std.testing.allocator;

    var mem = try Memory.init(allocator, 1024 * 1024);
    defer mem.deinit();

    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set initial register values
    cpu.regs.eax = 0x11111111;
    cpu.regs.ecx = 0x22222222;
    cpu.regs.edx = 0x33333333;
    cpu.regs.ebx = 0x44444444;
    cpu.regs.esp = 0x1000;
    cpu.regs.ebp = 0x55555555;
    cpu.regs.esi = 0x66666666;
    cpu.regs.edi = 0x77777777;

    const original_esp = cpu.regs.esp;

    // PUSHAD (0x60)
    try mem.writeByte(0, 0x60);

    cpu.eip = 0;
    try cpu.step();

    // Verify ESP decreased by 32 bytes (8 registers * 4 bytes)
    try std.testing.expectEqual(original_esp - 32, cpu.regs.esp);

    // Modify registers to verify POPAD restores them
    cpu.regs.eax = 0xAAAAAAAA;
    cpu.regs.ecx = 0xBBBBBBBB;
    cpu.regs.edx = 0xCCCCCCCC;
    cpu.regs.ebx = 0xDDDDDDDD;
    cpu.regs.ebp = 0xEEEEEEEE;
    cpu.regs.esi = 0xFFFFFFFF;
    cpu.regs.edi = 0x12345678;

    // POPAD (0x61)
    try mem.writeByte(1, 0x61);

    cpu.eip = 1;
    try cpu.step();

    // Verify all registers restored (except ESP which should be back to original)
    try std.testing.expectEqual(@as(u32, 0x11111111), cpu.regs.eax);
    try std.testing.expectEqual(@as(u32, 0x22222222), cpu.regs.ecx);
    try std.testing.expectEqual(@as(u32, 0x33333333), cpu.regs.edx);
    try std.testing.expectEqual(@as(u32, 0x44444444), cpu.regs.ebx);
    try std.testing.expectEqual(@as(u32, 0x55555555), cpu.regs.ebp);
    try std.testing.expectEqual(@as(u32, 0x66666666), cpu.regs.esi);
    try std.testing.expectEqual(@as(u32, 0x77777777), cpu.regs.edi);

    // ESP should be back to original value
    try std.testing.expectEqual(original_esp, cpu.regs.esp);
}

test "pusha with 16-bit operand size" {
    const allocator = std.testing.allocator;

    var mem = try Memory.init(allocator, 1024 * 1024);
    defer mem.deinit();

    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set initial register values (only low 16 bits matter for PUSHA)
    cpu.regs.eax = 0xDEAD1111;
    cpu.regs.ecx = 0xBEEF2222;
    cpu.regs.edx = 0xCAFE3333;
    cpu.regs.ebx = 0xFACE4444;
    cpu.regs.esp = 0x1000;
    cpu.regs.ebp = 0xABCD5555;
    cpu.regs.esi = 0x12346666;
    cpu.regs.edi = 0x56787777;

    const original_esp = cpu.regs.esp;

    // 0x66 0x60 (operand size override + PUSHA)
    try mem.writeByte(0, 0x66); // Operand size override prefix
    try mem.writeByte(1, 0x60); // PUSHA

    cpu.eip = 0;
    try cpu.step();

    // Verify ESP decreased by 16 bytes (8 registers * 2 bytes)
    try std.testing.expectEqual(original_esp - 16, cpu.regs.esp);

    // POPA (0x66 0x61)
    try mem.writeByte(2, 0x66); // Operand size override prefix
    try mem.writeByte(3, 0x61); // POPA

    cpu.eip = 2;
    try cpu.step();

    // Verify low 16 bits of all registers restored
    try std.testing.expectEqual(@as(u16, 0x1111), cpu.regs.getReg16(0)); // AX
    try std.testing.expectEqual(@as(u16, 0x2222), cpu.regs.getReg16(1)); // CX
    try std.testing.expectEqual(@as(u16, 0x3333), cpu.regs.getReg16(2)); // DX
    try std.testing.expectEqual(@as(u16, 0x4444), cpu.regs.getReg16(3)); // BX
    try std.testing.expectEqual(@as(u16, 0x5555), cpu.regs.getReg16(5)); // BP
    try std.testing.expectEqual(@as(u16, 0x6666), cpu.regs.getReg16(6)); // SI
    try std.testing.expectEqual(@as(u16, 0x7777), cpu.regs.getReg16(7)); // DI

    // ESP should be back to original value
    try std.testing.expectEqual(original_esp, cpu.regs.esp);
}

test "popad does not modify esp from stack" {
    const allocator = std.testing.allocator;

    var mem = try Memory.init(allocator, 1024 * 1024);
    defer mem.deinit();

    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    cpu.regs.esp = 0x1000;

    // PUSHAD
    try mem.writeByte(0, 0x60);

    cpu.eip = 0;
    try cpu.step();

    const after_pushad_esp = cpu.regs.esp;

    // Manually modify the ESP value on the stack (4th dword pushed)
    // Stack layout after PUSHAD: [EDI, ESI, EBP, ESP, EBX, EDX, ECX, EAX]
    // ESP is at offset +12 from current ESP
    try mem.writeDword(after_pushad_esp + 12, 0x99999999);

    // POPAD
    try mem.writeByte(1, 0x61);

    cpu.eip = 1;
    try cpu.step();

    // ESP should be restored to original value (0x1000), not the modified value (0x99999999)
    // This is because POPAD skips the ESP value from the stack
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.regs.esp);
}

test "bswap instruction" {
    const allocator = std.testing.allocator;

    var mem = try Memory.init(allocator, 1024 * 1024);
    defer mem.deinit();

    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test BSWAP EAX (0F C8)
    cpu.regs.eax = 0x12345678;
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xC8);

    cpu.eip = 0;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0x78563412), cpu.regs.eax);

    // Test BSWAP ECX (0F C9)
    cpu.regs.ecx = 0xAABBCCDD;
    try mem.writeByte(2, 0x0F);
    try mem.writeByte(3, 0xC9);

    cpu.eip = 2;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0xDDCCBBAA), cpu.regs.ecx);

    // Test BSWAP EDX (0F CA)
    cpu.regs.edx = 0x11223344;
    try mem.writeByte(4, 0x0F);
    try mem.writeByte(5, 0xCA);

    cpu.eip = 4;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0x44332211), cpu.regs.edx);

    // Test BSWAP EBX (0F CB)
    cpu.regs.ebx = 0xFFEEDDCC;
    try mem.writeByte(6, 0x0F);
    try mem.writeByte(7, 0xCB);

    cpu.eip = 6;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0xCCDDEEFF), cpu.regs.ebx);

    // Test BSWAP ESP (0F CC)
    cpu.regs.esp = 0x01020304;
    try mem.writeByte(8, 0x0F);
    try mem.writeByte(9, 0xCC);

    cpu.eip = 8;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0x04030201), cpu.regs.esp);

    // Test BSWAP EBP (0F CD)
    cpu.regs.ebp = 0xDEADBEEF;
    try mem.writeByte(10, 0x0F);
    try mem.writeByte(11, 0xCD);

    cpu.eip = 10;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0xEFBEADDE), cpu.regs.ebp);

    // Test BSWAP ESI (0F CE)
    cpu.regs.esi = 0xCAFEBABE;
    try mem.writeByte(12, 0x0F);
    try mem.writeByte(13, 0xCE);

    cpu.eip = 12;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0xBEBAFECA), cpu.regs.esi);

    // Test BSWAP EDI (0F CF)
    cpu.regs.edi = 0x13579BDF;
    try mem.writeByte(14, 0x0F);
    try mem.writeByte(15, 0xCF);

    cpu.eip = 14;
    try cpu.step();

    try std.testing.expectEqual(@as(u32, 0xDF9B5713), cpu.regs.edi);
}

test "shld instruction: immediate count" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test SHLD EAX, EBX, 4
    // EAX = 0x12345678, EBX = 0xABCDEF00
    // Result: shift EAX left by 4, fill from high bits of EBX
    // EAX should become 0x23456780 | 0x0000000A = 0x2345678A
    cpu.regs.eax = 0x12345678;
    cpu.regs.ebx = 0xABCDEF00;

    // 0F A4 C3 04: SHLD EBX, EAX, 4
    // ModR/M: 0xC3 = mod=11 (register), reg=000 (EAX), rm=011 (EBX)
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xA4);
    try mem.writeByte(2, 0xC3); // ModR/M: dest=EBX, src=EAX
    try mem.writeByte(3, 0x04); // count=4

    cpu.eip = 0;
    try cpu.step();

    // EBX = 0xABCDEF00 << 4 | 0x12345678 >> 28
    // EBX = 0xBCDEF000 | 0x00000001 = 0xBCDEF001
    try std.testing.expectEqual(@as(u32, 0xBCDEF001), cpu.regs.ebx);

    // CF should be set to the last bit shifted out from EBX
    // Bit 27 (32-4-1) of EBX should be checked
    // 0xABCDEF00 bit 27 = (0xABCDEF00 >> 27) & 1 = 0x55 >> 3 & 1 = 1
    try std.testing.expect(cpu.flags.carry);
}

test "shld instruction: CL count" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test SHLD EDX, ESI, CL with CL=8
    cpu.regs.edx = 0x11223344;
    cpu.regs.esi = 0x55667788;
    cpu.regs.ecx = 8; // CL = 8

    // 0F A5 F2: SHLD EDX, ESI, CL
    // ModR/M: 0xF2 = mod=11, reg=110 (ESI), rm=010 (EDX)
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xA5);
    try mem.writeByte(2, 0xF2);

    cpu.eip = 0;
    try cpu.step();

    // EDX = 0x11223344 << 8 | 0x55667788 >> 24
    // EDX = 0x22334400 | 0x00000055 = 0x22334455
    try std.testing.expectEqual(@as(u32, 0x22334455), cpu.regs.edx);
    try std.testing.expect(cpu.flags.carry);
}

test "shld instruction: 16-bit operand" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test SHLD AX, BX, 4 with operand size override
    cpu.regs.eax = 0x00001234;
    cpu.regs.ebx = 0x0000ABCD;

    // 66 0F A4 C3 04: SHLD BX, AX, 4 (with 0x66 prefix)
    try mem.writeByte(0, 0x66); // Operand size override
    try mem.writeByte(1, 0x0F);
    try mem.writeByte(2, 0xA4);
    try mem.writeByte(3, 0xC3); // ModR/M: dest=BX, src=AX
    try mem.writeByte(4, 0x04); // count=4

    cpu.eip = 0;
    try cpu.step();

    // BX = 0xABCD << 4 | 0x1234 >> 12
    // BX = 0xBCD0 | 0x0001 = 0xBCD1
    const result = cpu.regs.getReg16(3); // BX
    try std.testing.expectEqual(@as(u16, 0xBCD1), result);
}

test "shrd instruction: immediate count" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test SHRD EAX, EBX, 4
    cpu.regs.eax = 0x12345678;
    cpu.regs.ebx = 0xABCDEF00;

    // 0F AC C3 04: SHRD EBX, EAX, 4
    // ModR/M: 0xC3 = mod=11, reg=000 (EAX), rm=011 (EBX)
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xAC);
    try mem.writeByte(2, 0xC3);
    try mem.writeByte(3, 0x04); // count=4

    cpu.eip = 0;
    try cpu.step();

    // EBX = 0xABCDEF00 >> 4 | 0x12345678 << 28
    // EBX = 0x0ABCDEF0 | 0x80000000 = 0x8ABCDEF0
    try std.testing.expectEqual(@as(u32, 0x8ABCDEF0), cpu.regs.ebx);

    // CF should be the last bit shifted out (bit 3 of original EBX)
    // We need to check if this is set correctly
}

test "shrd instruction: CL count" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test SHRD EDI, ECX, CL with CL=12
    cpu.regs.edi = 0xFEDCBA98;
    cpu.regs.ecx = 0x13579BDF; // Also sets CL=0xDF, but we'll mask it
    cpu.regs.ecx = 12; // Set CL=12

    // 0F AD CF: SHRD EDI, ECX, CL
    // ModR/M: 0xCF = mod=11, reg=001 (ECX), rm=111 (EDI)
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xAD);
    try mem.writeByte(2, 0xCF);

    cpu.eip = 0;
    try cpu.step();

    // EDI = 0xFEDCBA98 >> 12 | 0x0000000C << 20
    // EDI = 0x000FEDCB | 0x0C000000 = 0x0CFEDCB (wait, ECX=12, not 0x0C)
    // EDI = 0xFEDCBA98 >> 12 | 12 << 20
    // EDI = 0x000FEDCB | 0x00C00000 = 0x00CFEDCB
    try std.testing.expectEqual(@as(u32, 0x00CFEDCB), cpu.regs.edi);
}

test "shrd instruction: verify carry flag" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test SHRD with count=1 to verify CF
    cpu.regs.eax = 0xFFFFFFFF;
    cpu.regs.ebx = 0x00000000;

    // SHRD EAX, EBX, 1
    try mem.writeByte(0, 0x0F);
    try mem.writeByte(1, 0xAC);
    try mem.writeByte(2, 0xC0); // ModR/M: dest=EAX, src=EAX
    try mem.writeByte(3, 0x01);

    cpu.eip = 0;
    try cpu.step();

    // EAX bit 0 should be shifted into CF
    try std.testing.expect(cpu.flags.carry);
    // Result should be 0x7FFFFFFF (shifted right by 1, high bit from EBX=0)
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), cpu.regs.eax);
}

test "mov segment to register: MOV AX, DS" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set DS to a test value
    cpu.segments.ds = 0x1234;

    // MOV AX, DS (0x8C /r with reg=3 for DS, r/m=0 for AX)
    // ModR/M: mod=11 (register), reg=011 (DS), rm=000 (AX)
    try mem.writeByte(0, 0x8C);
    try mem.writeByte(1, 0xD8); // 11 011 000

    cpu.eip = 0;
    try cpu.step();

    try std.testing.expectEqual(@as(u16, 0x1234), cpu.regs.getReg16(0)); // AX
}

test "mov register to segment: MOV DS, AX" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set AX to a test value
    cpu.regs.setReg16(0, 0x5678);

    // MOV DS, AX (0x8E /r with reg=3 for DS, r/m=0 for AX)
    // ModR/M: mod=11 (register), reg=011 (DS), rm=000 (AX)
    try mem.writeByte(0, 0x8E);
    try mem.writeByte(1, 0xD8); // 11 011 000

    cpu.eip = 0;
    try cpu.step();

    try std.testing.expectEqual(@as(u16, 0x5678), cpu.segments.ds);
}

test "mov segment to memory: MOV [0x1000], ES" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set ES to a test value
    cpu.segments.es = 0xABCD;

    // MOV [0x1000], ES (0x8C /r with reg=0 for ES, memory addressing)
    // ModR/M: mod=00 (indirect), reg=000 (ES), rm=101 (disp32)
    try mem.writeByte(0, 0x8C);
    try mem.writeByte(1, 0x05); // 00 000 101
    try mem.writeDword(2, 0x1000); // displacement

    cpu.eip = 0;
    try cpu.step();

    const value = try mem.readWord(0x1000);
    try std.testing.expectEqual(@as(u16, 0xABCD), value);
}

test "mov memory to segment: MOV SS, [0x2000]" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Write test value to memory
    try mem.writeWord(0x2000, 0x9876);

    // MOV SS, [0x2000] (0x8E /r with reg=2 for SS, memory addressing)
    // ModR/M: mod=00 (indirect), reg=010 (SS), rm=101 (disp32)
    try mem.writeByte(0, 0x8E);
    try mem.writeByte(1, 0x15); // 00 010 101
    try mem.writeDword(2, 0x2000); // displacement

    cpu.eip = 0;
    try cpu.step();

    try std.testing.expectEqual(@as(u16, 0x9876), cpu.segments.ss);
}

test "mov cs to register fails: cannot load CS with MOV" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set AX to a test value
    cpu.regs.setReg16(0, 0x1234);

    // Try MOV CS, AX (0x8E /r with reg=1 for CS, r/m=0 for AX)
    // ModR/M: mod=11 (register), reg=001 (CS), rm=000 (AX)
    try mem.writeByte(0, 0x8E);
    try mem.writeByte(1, 0xC8); // 11 001 000

    cpu.eip = 0;
    const result = cpu.step();

    try std.testing.expectError(CpuError.GeneralProtectionFault, result);
}

test "far jmp: JMP ptr16:32 in real mode" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set initial CS:EIP
    cpu.segments.cs = 0x0000;
    cpu.eip = 0;

    // JMP 0x2000:0x00001234 (far jump in 32-bit mode)
    // Opcode: 0xEA, offset32, selector16
    try mem.writeByte(0, 0xEA); // JMP far
    try mem.writeDword(1, 0x00001234); // offset32
    try mem.writeWord(5, 0x2000); // selector16

    try cpu.step();

    try std.testing.expectEqual(@as(u16, 0x2000), cpu.segments.cs);
    try std.testing.expectEqual(@as(u32, 0x00001234), cpu.eip);
}

test "far jmp: JMP ptr16:16 in 16-bit mode" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set initial CS:EIP
    cpu.segments.cs = 0x0000;
    cpu.eip = 0;

    // JMP 0x3000:0x5678 (far jump in 16-bit mode)
    // Opcode: 0x66 (operand size override), 0xEA, offset16, selector16
    try mem.writeByte(0, 0x66); // operand size override
    try mem.writeByte(1, 0xEA); // JMP far
    try mem.writeWord(2, 0x5678); // offset16
    try mem.writeWord(4, 0x3000); // selector16

    try cpu.step();

    try std.testing.expectEqual(@as(u16, 0x3000), cpu.segments.cs);
    try std.testing.expectEqual(@as(u32, 0x5678), cpu.eip);
}

test "far call and retf: round trip in real mode" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set initial CS:EIP
    cpu.segments.cs = 0x1000;
    cpu.eip = 0x100;
    cpu.regs.esp = 0x8000; // Set up stack

    // CALL 0x2000:0x00000200 (far call in 32-bit mode)
    // Opcode: 0x9A, offset32, selector16
    try mem.writeByte(0x10100, 0x9A); // CALL far (at CS:EIP = 0x1000:0x100 -> linear 0x10100)
    try mem.writeDword(0x10101, 0x00000200); // offset32
    try mem.writeWord(0x10105, 0x2000); // selector16

    // Execute far call
    try cpu.step();

    // Verify we jumped to new location
    try std.testing.expectEqual(@as(u16, 0x2000), cpu.segments.cs);
    try std.testing.expectEqual(@as(u32, 0x00000200), cpu.eip);

    // Verify return address was pushed (CS, then EIP)
    // Stack grows down: first push CS (2 bytes), then push EIP (4 bytes)
    const saved_cs = try mem.readWord(0x8000 - 6); // First push
    const saved_eip = try mem.readDword(0x8000 - 4); // Second push
    try std.testing.expectEqual(@as(u16, 0x1000), saved_cs);
    try std.testing.expectEqual(@as(u32, 0x10107), saved_eip); // Return address after 7-byte instruction

    // Put RETF instruction at target location
    try mem.writeByte(0x20200, 0xCB); // RETF (at CS:EIP = 0x2000:0x200 -> linear 0x20200)

    // Execute far return
    try cpu.step();

    // Verify we returned to original location
    try std.testing.expectEqual(@as(u16, 0x1000), cpu.segments.cs);
    try std.testing.expectEqual(@as(u32, 0x10107), cpu.eip);
    try std.testing.expectEqual(@as(u32, 0x8000), cpu.regs.esp); // Stack pointer restored
}

test "retf with stack cleanup: RETF imm16" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up stack with return address
    cpu.regs.esp = 0x8000;

    // Push CS and EIP onto stack manually
    cpu.regs.esp -= 6;
    try mem.writeWord(cpu.regs.esp, 0x1234); // Return CS
    try mem.writeDword(cpu.regs.esp + 2, 0x56789ABC); // Return EIP

    // RETF 0x10 - far return and clean up 16 bytes
    try mem.writeByte(0, 0xCA); // RETF imm16
    try mem.writeWord(1, 0x10); // Clean up 16 bytes

    cpu.eip = 0;
    try cpu.step();

    // Verify we returned to saved location
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.segments.cs);
    try std.testing.expectEqual(@as(u32, 0x56789ABC), cpu.eip);

    // Verify stack was cleaned up (6 bytes popped + 16 bytes added)
    try std.testing.expectEqual(@as(u32, 0x8000 + 0x10), cpu.regs.esp);
}

test "jecxz: jump when ecx is zero" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set ECX to 0
    cpu.regs.ecx = 0;
    cpu.eip = 0;

    // JECXZ +10 (jump forward 10 bytes)
    try mem.writeByte(0, 0xE3); // JECXZ
    try mem.writeByte(1, 0x0A); // rel8 = +10

    try cpu.step();

    // Jump should be taken: EIP = 2 (after instruction) + 10 = 12
    try std.testing.expectEqual(@as(u32, 12), cpu.eip);
}

test "jecxz: no jump when ecx is non-zero" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set ECX to non-zero
    cpu.regs.ecx = 5;
    cpu.eip = 0;

    // JECXZ +10
    try mem.writeByte(0, 0xE3); // JECXZ
    try mem.writeByte(1, 0x0A); // rel8 = +10

    try cpu.step();

    // Jump should NOT be taken: EIP = 2 (after instruction)
    try std.testing.expectEqual(@as(u32, 2), cpu.eip);
}

test "jcxz: jump when cx is zero (with address size override)" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set ECX so that CX (low word) is 0, but high word is not
    cpu.regs.ecx = 0x12340000; // CX = 0, but ECX != 0
    cpu.eip = 0;

    // JCXZ +10 (with address size override)
    try mem.writeByte(0, 0x67); // Address size override prefix
    try mem.writeByte(1, 0xE3); // JCXZ
    try mem.writeByte(2, 0x0A); // rel8 = +10

    try cpu.step();

    // Jump should be taken because CX == 0: EIP = 3 (after instruction) + 10 = 13
    try std.testing.expectEqual(@as(u32, 13), cpu.eip);
}

test "imul r32, r32, imm8: basic multiplication" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set EBX = 10
    cpu.regs.ebx = 10;
    cpu.eip = 0;

    // IMUL EAX, EBX, 5 (EAX = EBX * 5 = 50)
    // Opcode: 0x6B, ModR/M: 11 000 011 (mod=11, reg=EAX, rm=EBX), imm8=5
    try mem.writeByte(0, 0x6B); // IMUL r32, r/m32, imm8
    try mem.writeByte(1, 0xC3); // ModR/M: EAX, EBX
    try mem.writeByte(2, 0x05); // imm8 = 5

    try cpu.step();

    try std.testing.expectEqual(@as(u32, 50), cpu.regs.eax);
    // No overflow, so CF and OF should be clear
    try std.testing.expectEqual(false, cpu.flags.carry);
    try std.testing.expectEqual(false, cpu.flags.overflow);
}

test "imul r32, r32, imm8: with overflow" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set EBX to a large value that will overflow when multiplied
    cpu.regs.ebx = 0x10000000; // 268435456
    cpu.eip = 0;

    // IMUL EAX, EBX, 16 (will overflow 32-bit signed)
    try mem.writeByte(0, 0x6B); // IMUL r32, r/m32, imm8
    try mem.writeByte(1, 0xC3); // ModR/M: EAX, EBX
    try mem.writeByte(2, 0x10); // imm8 = 16

    try cpu.step();

    // Result will be truncated, but CF and OF should be set
    try std.testing.expectEqual(true, cpu.flags.carry);
    try std.testing.expectEqual(true, cpu.flags.overflow);
}

test "imul r32, r32, imm32: basic multiplication" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set ECX = 100
    cpu.regs.ecx = 100;
    cpu.eip = 0;

    // IMUL EDX, ECX, 1000 (EDX = ECX * 1000 = 100000)
    // Opcode: 0x69, ModR/M: 11 010 001 (mod=11, reg=EDX, rm=ECX), imm32=1000
    try mem.writeByte(0, 0x69); // IMUL r32, r/m32, imm32
    try mem.writeByte(1, 0xD1); // ModR/M: EDX, ECX
    try mem.writeDword(2, 1000); // imm32 = 1000

    try cpu.step();

    try std.testing.expectEqual(@as(u32, 100000), cpu.regs.edx);
    // No overflow, so CF and OF should be clear
    try std.testing.expectEqual(false, cpu.flags.carry);
    try std.testing.expectEqual(false, cpu.flags.overflow);
}

test "imul r16, r16, imm16: 16-bit multiplication" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set BX = 20
    cpu.regs.ebx = 20;
    cpu.eip = 0;

    // IMUL AX, BX, 300 (AX = BX * 300 = 6000)
    // With operand size override prefix (0x66)
    try mem.writeByte(0, 0x66); // Operand size override
    try mem.writeByte(1, 0x69); // IMUL r16, r/m16, imm16
    try mem.writeByte(2, 0xC3); // ModR/M: AX, BX
    try mem.writeWord(3, 300); // imm16 = 300

    try cpu.step();

    try std.testing.expectEqual(@as(u16, 6000), @as(u16, @truncate(cpu.regs.eax)));
    // No overflow for 16-bit signed value 6000
    try std.testing.expectEqual(false, cpu.flags.carry);
    try std.testing.expectEqual(false, cpu.flags.overflow);
}

test "clts: clear task-switched flag" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set CR0.TS to true
    cpu.system.cr0.ts = true;
    cpu.eip = 0;

    // CLTS (0x0F 0x06)
    try mem.writeByte(0, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(1, 0x06); // CLTS

    try cpu.step();

    // CR0.TS should now be false
    try std.testing.expectEqual(false, cpu.system.cr0.ts);
}

test "mov debug registers: write and read" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // MOV DR0, EAX - Write 0x12345678 to DR0
    cpu.regs.eax = 0x12345678;
    try mem.writeByte(0, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(1, 0x23); // MOV DRn, r32
    try mem.writeByte(2, 0xC0); // ModR/M: DR0, EAX (11 000 000)

    try cpu.step();
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.system.dr0);

    // MOV EBX, DR0 - Read DR0 into EBX
    cpu.eip = 3;
    try mem.writeByte(3, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(4, 0x21); // MOV r32, DRn
    try mem.writeByte(5, 0xC3); // ModR/M: DR0, EBX (11 000 011)

    try cpu.step();
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.regs.ebx);
}

test "mov debug registers: DR6 and DR7 power-up values" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    const cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Check power-up values per Intel spec
    try std.testing.expectEqual(@as(u32, 0xFFFF0FF0), cpu.system.dr6);
    try std.testing.expectEqual(@as(u32, 0x00000400), cpu.system.dr7);
}

test "mov debug registers: DR4 and DR5 aliases" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // MOV DR4, EAX (should write to DR6)
    cpu.regs.eax = 0xAABBCCDD;
    try mem.writeByte(0, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(1, 0x23); // MOV DRn, r32
    try mem.writeByte(2, 0xE0); // ModR/M: DR4, EAX (11 100 000)

    try cpu.step();
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), cpu.system.dr6);

    // MOV DR5, EDX (should write to DR7)
    cpu.eip = 3;
    cpu.regs.edx = 0x11223344;
    try mem.writeByte(3, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(4, 0x23); // MOV DRn, r32
    try mem.writeByte(5, 0xEA); // ModR/M: DR5, EDX (11 101 010)

    try cpu.step();
    try std.testing.expectEqual(@as(u32, 0x11223344), cpu.system.dr7);
}

test "clc: clear carry flag" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // Set carry flag
    cpu.flags.carry = true;

    // CLC (0xF8)
    try mem.writeByte(0, 0xF8);

    try cpu.step();
    try std.testing.expectEqual(false, cpu.flags.carry);
}

test "stc: set carry flag" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // Clear carry flag
    cpu.flags.carry = false;

    // STC (0xF9)
    try mem.writeByte(0, 0xF9);

    try cpu.step();
    try std.testing.expectEqual(true, cpu.flags.carry);
}

test "cmc: complement carry flag" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // Set carry flag
    cpu.flags.carry = true;

    // CMC (0xF5) - should complement to false
    try mem.writeByte(0, 0xF5);
    try cpu.step();
    try std.testing.expectEqual(false, cpu.flags.carry);

    // CMC (0xF5) - should complement to true
    cpu.eip = 1;
    try mem.writeByte(1, 0xF5);
    try cpu.step();
    try std.testing.expectEqual(true, cpu.flags.carry);
}

test "multi-byte nop: 0F 1F" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // Save initial state
    const initial_eax = cpu.regs.eax;

    // Multi-byte NOP: 0x0F 0x1F with ModR/M
    try mem.writeByte(0, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(1, 0x1F); // Hint NOP
    try mem.writeByte(2, 0xC0); // ModR/M (required, but ignored)

    try cpu.step();

    // Verify it's a true NOP - no register changes
    try std.testing.expectEqual(initial_eax, cpu.regs.eax);
    try std.testing.expectEqual(@as(u32, 3), cpu.eip);
}

test "prefetch nop: 0F 0D" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // Prefetch NOP: 0x0F 0x0D with ModR/M
    try mem.writeByte(0, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(1, 0x0D); // PREFETCH
    try mem.writeByte(2, 0xC0); // ModR/M (required, but ignored)

    try cpu.step();

    // Verify it advanced EIP correctly
    try std.testing.expectEqual(@as(u32, 3), cpu.eip);
}

test "mov test registers: obsolete no-ops" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.eip = 0;

    // MOV r32, TRn - should return 0
    try mem.writeByte(0, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(1, 0x24); // MOV r32, TRn
    try mem.writeByte(2, 0xC0); // ModR/M: TR0, EAX

    cpu.regs.eax = 0xFFFFFFFF;
    try cpu.step();
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.eax);

    // MOV TRn, r32 - should be no-op
    cpu.eip = 3;
    cpu.regs.ebx = 0x12345678;
    try mem.writeByte(3, 0x0F); // Two-byte opcode prefix
    try mem.writeByte(4, 0x26); // MOV TRn, r32
    try mem.writeByte(5, 0xC3); // ModR/M: TR0, EBX

    try cpu.step();
    // Just verify it doesn't crash and advances EIP
    try std.testing.expectEqual(@as(u32, 6), cpu.eip);
}
test "insb: input byte from UART to memory" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    // Register UART at port 0x3F8
    try io_ctrl.registerUart(io_mod.IoController.COM1_BASE);

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.edx = 0x3F8; // Port in DX
    cpu.regs.edi = 0x100; // Destination address
    cpu.segments.es = 0; // ES segment

    // Write test data to UART input
    if (io_ctrl.getUart(io_mod.IoController.COM1_BASE)) |uart| {
        try uart.rx_buffer.append('T');
        uart.lsr.data_ready = true;
    }

    // INSB: 0x6C
    try mem.writeByte(0, 0x6C);

    try cpu.step();

    // Verify byte was read from port and written to ES:[EDI]
    const result = try mem.readByte(0x100);
    try std.testing.expectEqual(@as(u8, 'T'), result);
    // Verify EDI was incremented
    try std.testing.expectEqual(@as(u32, 0x101), cpu.regs.edi);
}

test "outsb: output byte from memory to UART" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    // Register UART at port 0x3F8
    try io_ctrl.registerUart(io_mod.IoController.COM1_BASE);

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.edx = 0x3F8; // Port in DX
    cpu.regs.esi = 0x100; // Source address
    cpu.segments.ds = 0; // DS segment

    // Write test data to memory
    try mem.writeByte(0x100, 'X');

    // OUTSB: 0x6E
    try mem.writeByte(0, 0x6E);

    try cpu.step();

    // Verify byte was written to UART
    if (io_ctrl.getUart(io_mod.IoController.COM1_BASE)) |uart| {
        const output = uart.getOutputBuffer();
        try std.testing.expectEqual(@as(usize, 1), output.len);
        try std.testing.expectEqual(@as(u8, 'X'), output[0]);
    }
    // Verify ESI was incremented
    try std.testing.expectEqual(@as(u32, 0x101), cpu.regs.esi);
}

test "rep insb: input multiple bytes from UART" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    // Register UART at port 0x3F8
    try io_ctrl.registerUart(io_mod.IoController.COM1_BASE);

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.edx = 0x3F8; // Port in DX
    cpu.regs.edi = 0x200; // Destination address
    cpu.regs.ecx = 4; // Read 4 bytes
    cpu.segments.es = 0; // ES segment

    // REP prefix (0xF3) + INSB (0x6C)
    try mem.writeByte(0, 0xF3);
    try mem.writeByte(1, 0x6C);

    // Note: In real usage, the UART would provide data.
    // For this test, we'll get 0xFF from uninitialized UART reads
    try cpu.step();

    // Verify ECX was decremented to 0
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.ecx);
    // Verify EDI was incremented by 4
    try std.testing.expectEqual(@as(u32, 0x204), cpu.regs.edi);
}

test "rep outsw: output multiple words to port" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    // Register UART at port 0x3F8
    try io_ctrl.registerUart(io_mod.IoController.COM1_BASE);

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.edx = 0x3F8; // Port in DX
    cpu.regs.esi = 0x300; // Source address
    cpu.regs.ecx = 2; // Write 2 words
    cpu.segments.ds = 0; // DS segment

    // Write test data to memory
    try mem.writeWord(0x300, 0x4142); // "BA" in little-endian
    try mem.writeWord(0x302, 0x4344); // "DC" in little-endian

    // REP prefix (0xF3) + Operand size override (0x66) + OUTSW (0x6F)
    try mem.writeByte(0, 0xF3);
    try mem.writeByte(1, 0x66);
    try mem.writeByte(2, 0x6F);

    try cpu.step();

    // Verify ECX was decremented to 0
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.ecx);
    // Verify ESI was incremented by 4 (2 words)
    try std.testing.expectEqual(@as(u32, 0x304), cpu.regs.esi);

    // Verify bytes were written to UART (as individual byte writes)
    if (io_ctrl.getUart(io_mod.IoController.COM1_BASE)) |uart| {
        const output = uart.getOutputBuffer();
        try std.testing.expectEqual(@as(usize, 4), output.len);
        try std.testing.expectEqual(@as(u8, 0x42), output[0]); // Low byte of first word
        try std.testing.expectEqual(@as(u8, 0x41), output[1]); // High byte of first word
        try std.testing.expectEqual(@as(u8, 0x44), output[2]); // Low byte of second word
        try std.testing.expectEqual(@as(u8, 0x43), output[3]); // High byte of second word
    }
}

test "insw with direction flag: decrement EDI" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.regs.edx = 0x60; // Arbitrary port
    cpu.regs.edi = 0x400; // Destination address
    cpu.segments.es = 0; // ES segment
    cpu.flags.direction = true; // Set direction flag (decrement)

    // Operand size override (0x66) + INSW (0x6D)
    try mem.writeByte(0, 0x66);
    try mem.writeByte(1, 0x6D);

    try cpu.step();

    // Verify EDI was decremented by 2 (word size)
    try std.testing.expectEqual(@as(u32, 0x3FE), cpu.regs.edi);
}


test "bound: index within bounds (16-bit)" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up bounds in memory at address 0x1000
    // Lower bound: 10, Upper bound: 100
    try mem.writeWord(0x1000, 10); // lower
    try mem.writeWord(0x1002, 100); // upper

    // Set up BOUND instruction: 0x66 0x62 /r (16-bit)
    // BOUND AX, [0x1000]
    // ModR/M: mod=00 (memory, no displacement), reg=000 (AX), rm=110 (disp16)
    cpu.regs.eax = 50; // AX = 50 (within bounds [10, 100])
    try mem.writeByte(0, 0x66); // Operand size override
    try mem.writeByte(1, 0x62); // BOUND opcode
    try mem.writeByte(2, 0x06); // ModR/M: mod=00, reg=000, rm=110
    try mem.writeWord(3, 0x1000); // 16-bit displacement

    cpu.eip = 0;
    // Should not raise error when index is within bounds
    try cpu.step();

    // CPU should have advanced past the instruction
    try std.testing.expectEqual(@as(u32, 5), cpu.eip);
}

test "bound: index out of bounds raises error (32-bit)" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up bounds in memory at address 0x1000
    // Lower bound: 100, Upper bound: 200
    try mem.writeDword(0x1000, 100); // lower
    try mem.writeDword(0x1004, 200); // upper

    // Set up BOUND instruction: 0x62 /r (32-bit)
    // BOUND EAX, [0x1000]
    cpu.regs.eax = 300; // EAX = 300 (out of bounds, > 200)
    try mem.writeByte(0, 0x62); // BOUND opcode
    try mem.writeByte(1, 0x06); // ModR/M: mod=00, reg=000 (EAX), rm=110 (disp16)
    try mem.writeWord(2, 0x1000); // 16-bit displacement

    cpu.eip = 0;
    // Should raise GeneralProtectionFault when index is out of bounds
    try std.testing.expectError(cpu_mod.CpuError.GeneralProtectionFault, cpu.step());
}

test "arpl: adjust RPL when dest < src" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.mode = .protected; // ARPL only works in protected mode

    // ARPL BX, AX
    // AX = selector with RPL=3 (0x0003)
    // BX = selector with RPL=1 (0x0011)
    cpu.regs.eax = 0x0003; // Selector with RPL=3
    cpu.regs.ebx = 0x0011; // Selector 0x0010 with RPL=1

    // ARPL r/m16, r16: 0x63 /r
    // ModR/M: mod=11 (register), reg=000 (AX), rm=011 (BX)
    try mem.writeByte(0, 0x63); // ARPL opcode
    try mem.writeByte(1, 0xC3); // ModR/M: 11 000 011

    cpu.eip = 0;
    try cpu.step();

    // BX should now have RPL=3 (adjusted from 1 to 3)
    try std.testing.expectEqual(@as(u16, 0x0013), cpu.regs.getReg16(3)); // BX = 0x0013
    // ZF should be set because adjustment occurred
    try std.testing.expect(cpu.flags.zero);
}

test "arpl: no adjustment when dest >= src" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 16 * 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);
    cpu.mode = .protected; // ARPL only works in protected mode

    // ARPL BX, AX
    // AX = selector with RPL=1 (0x0001)
    // BX = selector with RPL=3 (0x0013)
    cpu.regs.eax = 0x0001; // Selector with RPL=1
    cpu.regs.ebx = 0x0013; // Selector 0x0010 with RPL=3

    // ARPL r/m16, r16: 0x63 /r
    try mem.writeByte(0, 0x63); // ARPL opcode
    try mem.writeByte(1, 0xC3); // ModR/M: 11 000 011 (AX, BX)

    cpu.eip = 0;
    try cpu.step();

    // BX should remain unchanged (RPL=3 >= RPL=1)
    try std.testing.expectEqual(@as(u16, 0x0013), cpu.regs.getReg16(3)); // BX unchanged
    // ZF should be clear because no adjustment occurred
    try std.testing.expect(!cpu.flags.zero);
}

test "xlat: table lookup translation" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up a translation table at DS:EBX
    const table_base: u32 = 0x1000;
    cpu.regs.ebx = table_base;
    cpu.segments.ds = 0x0000;

    // Write translation table values
    // Table[0] = 'A', Table[1] = 'B', Table[2] = 'C', etc.
    try mem.writeByte(table_base + 0, 'A');
    try mem.writeByte(table_base + 1, 'B');
    try mem.writeByte(table_base + 2, 'C');
    try mem.writeByte(table_base + 3, 'D');
    try mem.writeByte(table_base + 10, 'X');

    // Test 1: AL = 0, should load 'A'
    cpu.regs.setReg8(0, 0); // AL = 0
    cpu.eip = 0;
    try mem.writeByte(0, 0xD7); // XLAT
    try cpu.step();
    try std.testing.expectEqual(@as(u8, 'A'), cpu.regs.getReg8(0));

    // Test 2: AL = 2, should load 'C'
    cpu.regs.setReg8(0, 2); // AL = 2
    cpu.eip = 1;
    try mem.writeByte(1, 0xD7); // XLAT
    try cpu.step();
    try std.testing.expectEqual(@as(u8, 'C'), cpu.regs.getReg8(0));

    // Test 3: AL = 10, should load 'X'
    cpu.regs.setReg8(0, 10); // AL = 10
    cpu.eip = 2;
    try mem.writeByte(2, 0xD7); // XLAT
    try cpu.step();
    try std.testing.expectEqual(@as(u8, 'X'), cpu.regs.getReg8(0));
}

test "wait: fpu wait instruction" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // WAIT is a no-op in our emulator (no FPU)
    // Just verify it executes without error
    cpu.eip = 0;
    try mem.writeByte(0, 0x9B); // WAIT

    const eip_before = cpu.eip;
    try cpu.step();
    const eip_after = cpu.eip;

    // EIP should have advanced by 1 (consumed the WAIT opcode)
    try std.testing.expectEqual(eip_before + 1, eip_after);
}

test "into: interrupt on overflow when OF=1" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Set up IVT entry for INT 4 at address 0x10 (4 * 4 = 16 = 0x10)
    // IVT format: offset (2 bytes), segment (2 bytes)
    try mem.writeWord(0x10, 0x0100); // IP = 0x0100
    try mem.writeWord(0x12, 0x0000); // CS = 0x0000

    // Test 1: OF=1, should trigger interrupt
    cpu.flags.overflow = true;
    cpu.eip = 0;
    cpu.regs.esp = 0x1000; // Set up stack
    try mem.writeByte(0, 0xCE); // INTO

    try cpu.step();

    // Should have jumped to INT 4 handler at CS:IP = 0000:0100
    try std.testing.expectEqual(@as(u32, 0x0100), cpu.eip);
    try std.testing.expectEqual(@as(u16, 0x0000), cpu.segments.cs);
}

test "into: no interrupt when OF=0" {
    const allocator = std.testing.allocator;



    var mem = try memory.Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = io_mod.IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test 2: OF=0, should not trigger interrupt
    cpu.flags.overflow = false;
    cpu.eip = 0;
    try mem.writeByte(0, 0xCE); // INTO

    try cpu.step();

    // Should have simply advanced EIP by 1
    try std.testing.expectEqual(@as(u32, 1), cpu.eip);
}

test "adc instruction: 8-bit with carry" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // ADC AL, 0x05 with CF=1
    cpu.regs.eax = 0x10; // AL = 0x10
    cpu.flags.carry = true;

    try mem.writeByte(0, 0x14); // ADC AL, imm8
    try mem.writeByte(1, 0x05);

    cpu.eip = 0;
    try cpu.step();

    // Result should be 0x10 + 0x05 + 1 (carry) = 0x16
    try std.testing.expectEqual(@as(u8, 0x16), cpu.regs.getReg8(0)); // AL
    try std.testing.expect(!cpu.flags.carry);
    try std.testing.expect(cpu.flags.auxiliary);
}

test "adc instruction: 32-bit with carry" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // ADC EAX, imm32 with CF=1
    cpu.regs.eax = 0xFFFFFFFF;
    cpu.flags.carry = true;

    try mem.writeByte(0, 0x15); // ADC EAX, imm32
    try mem.writeDword(1, 0x00000000);

    cpu.eip = 0;
    try cpu.step();

    // Result should be 0xFFFFFFFF + 0 + 1 (carry) = 0x00000000 with carry set
    try std.testing.expectEqual(@as(u32, 0x00000000), cpu.regs.eax);
    try std.testing.expect(cpu.flags.carry);
    try std.testing.expect(cpu.flags.zero);
}

test "sbb instruction: 8-bit with borrow" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // SBB AL, 0x05 with CF=1 (borrow)
    cpu.regs.eax = 0x10; // AL = 0x10
    cpu.flags.carry = true;

    try mem.writeByte(0, 0x1C); // SBB AL, imm8
    try mem.writeByte(1, 0x05);

    cpu.eip = 0;
    try cpu.step();

    // Result should be 0x10 - 0x05 - 1 (borrow) = 0x0A
    try std.testing.expectEqual(@as(u8, 0x0A), cpu.regs.getReg8(0)); // AL
    try std.testing.expect(!cpu.flags.carry);
}

test "sbb instruction: 32-bit underflow with borrow" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // SBB EAX, imm32 with CF=1
    cpu.regs.eax = 0x00000005;
    cpu.flags.carry = true;

    try mem.writeByte(0, 0x1D); // SBB EAX, imm32
    try mem.writeDword(1, 0x00000005);

    cpu.eip = 0;
    try cpu.step();

    // Result should be 5 - 5 - 1 (borrow) = 0xFFFFFFFF with carry set
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), cpu.regs.eax);
    try std.testing.expect(cpu.flags.carry);
}

test "daa instruction: after addition" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test DAA with AL = 0x1C (low nibble > 9)
    cpu.regs.eax = 0x1C; // AL = 0x1C
    cpu.flags.auxiliary = false;
    cpu.flags.carry = false;

    try mem.writeByte(0, 0x27); // DAA

    cpu.eip = 0;
    try cpu.step();

    // After DAA: AL should be 0x22 (0x1C + 0x06)
    try std.testing.expectEqual(@as(u8, 0x22), cpu.regs.getReg8(0)); // AL
    try std.testing.expect(!cpu.flags.carry);
}

test "daa instruction: with carry" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test DAA with AL = 0xA5 (high nibble > 9)
    cpu.regs.eax = 0xA5; // AL = 0xA5
    cpu.flags.auxiliary = false;
    cpu.flags.carry = false;

    try mem.writeByte(0, 0x27); // DAA

    cpu.eip = 0;
    try cpu.step();

    // After DAA: AL should be 0x05 with carry set (0xA5 + 0x60 = 0x105)
    try std.testing.expectEqual(@as(u8, 0x05), cpu.regs.getReg8(0)); // AL
    try std.testing.expect(cpu.flags.carry);
}

test "das instruction: after subtraction" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test DAS with AL = 0x1C (low nibble > 9)
    cpu.regs.eax = 0x1C; // AL = 0x1C
    cpu.flags.auxiliary = false;
    cpu.flags.carry = false;

    try mem.writeByte(0, 0x2F); // DAS

    cpu.eip = 0;
    try cpu.step();

    // After DAS: AL should be 0x16 (0x1C - 0x06)
    try std.testing.expectEqual(@as(u8, 0x16), cpu.regs.getReg8(0)); // AL
}

test "aaa instruction: adjust after addition" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test AAA with AL = 0x0C (low nibble > 9)
    cpu.regs.eax = 0x0C; // AL = 0x0C, AH = 0x00

    try mem.writeByte(0, 0x37); // AAA

    cpu.eip = 0;
    try cpu.step();

    // After AAA: AL = 0x02 (0x0C + 6 = 0x12, masked to 0x02), AH = 0x01
    try std.testing.expectEqual(@as(u8, 0x02), cpu.regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x01), cpu.regs.getReg8(4)); // AH
    try std.testing.expect(cpu.flags.carry);
    try std.testing.expect(cpu.flags.auxiliary);
}

test "aaa instruction: no adjustment needed" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test AAA with AL = 0x05 (low nibble <= 9)
    cpu.regs.eax = 0x0105; // AL = 0x05, AH = 0x01

    try mem.writeByte(0, 0x37); // AAA

    cpu.eip = 0;
    try cpu.step();

    // After AAA: AL = 0x05, AH = 0x01 (no change)
    try std.testing.expectEqual(@as(u8, 0x05), cpu.regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x01), cpu.regs.getReg8(4)); // AH
    try std.testing.expect(!cpu.flags.carry);
}

test "aas instruction: adjust after subtraction" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test AAS with AL = 0x0C (low nibble > 9)
    cpu.regs.eax = 0x020C; // AL = 0x0C, AH = 0x02

    try mem.writeByte(0, 0x3F); // AAS

    cpu.eip = 0;
    try cpu.step();

    // After AAS: AL = 0x06 (0x0C - 6 = 0x06, masked to 0x06), AH = 0x01
    try std.testing.expectEqual(@as(u8, 0x06), cpu.regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x01), cpu.regs.getReg8(4)); // AH
    try std.testing.expect(cpu.flags.carry);
}

test "aam instruction: basic operation" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test AAM with AL = 0x2D (45 decimal)
    cpu.regs.eax = 0x2D; // AL = 45

    try mem.writeByte(0, 0xD4); // AAM
    try mem.writeByte(1, 0x0A); // base = 10

    cpu.eip = 0;
    try cpu.step();

    // After AAM: AH = 45 / 10 = 4, AL = 45 % 10 = 5
    try std.testing.expectEqual(@as(u8, 0x05), cpu.regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x04), cpu.regs.getReg8(4)); // AH
    try std.testing.expect(!cpu.flags.zero);
}

test "aam instruction: with different base" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test AAM with AL = 0x10 (16 decimal), base = 4
    cpu.regs.eax = 0x10; // AL = 16

    try mem.writeByte(0, 0xD4); // AAM
    try mem.writeByte(1, 0x04); // base = 4

    cpu.eip = 0;
    try cpu.step();

    // After AAM: AH = 16 / 4 = 4, AL = 16 % 4 = 0
    try std.testing.expectEqual(@as(u8, 0x00), cpu.regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x04), cpu.regs.getReg8(4)); // AH
    try std.testing.expect(cpu.flags.zero);
}

test "aad instruction: basic operation" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test AAD with AH = 0x04, AL = 0x05 (BCD 45)
    cpu.regs.eax = 0x0405; // AH = 4, AL = 5

    try mem.writeByte(0, 0xD5); // AAD
    try mem.writeByte(1, 0x0A); // base = 10

    cpu.eip = 0;
    try cpu.step();

    // After AAD: AL = 4 * 10 + 5 = 45 (0x2D), AH = 0
    try std.testing.expectEqual(@as(u8, 0x2D), cpu.regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x00), cpu.regs.getReg8(4)); // AH
    try std.testing.expect(!cpu.flags.zero);
}

test "aad instruction: with different base" {
    const allocator = std.testing.allocator;





    var mem = try Memory.init(allocator, 1024);
    defer mem.deinit();
    var io_ctrl = IoController.init(allocator);
    defer io_ctrl.deinit();

    var cpu = cpu_mod.Cpu.init(&mem, &io_ctrl);

    // Test AAD with AH = 0x03, AL = 0x02, base = 5
    cpu.regs.eax = 0x0302; // AH = 3, AL = 2

    try mem.writeByte(0, 0xD5); // AAD
    try mem.writeByte(1, 0x05); // base = 5

    cpu.eip = 0;
    try cpu.step();

    // After AAD: AL = 3 * 5 + 2 = 17 (0x11), AH = 0
    try std.testing.expectEqual(@as(u8, 0x11), cpu.regs.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x00), cpu.regs.getReg8(4)); // AH
}
