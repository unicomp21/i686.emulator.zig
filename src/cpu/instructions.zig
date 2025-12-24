//! i686 Instruction Decoder and Executor
//!
//! Implements the x86 instruction set for i686 processors.
//! Focus on instructions needed for running Linux kselftest.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const CpuError = cpu_mod.CpuError;

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

/// Execute instruction based on opcode
pub fn execute(cpu: *Cpu, opcode: u8) !void {
    // Record instruction in history
    cpu.recordInstruction(opcode, 0, false);

    switch (opcode) {
        // NOP
        0x90 => {},

        // HLT
        0xF4 => cpu.halt(),

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

        // INT imm8
        0xCD => {
            const vector = try fetchByte(cpu);
            try handleInterrupt(cpu, vector);
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

        // Group 7 (LGDT, LIDT, etc.)
        0x01 => {
            try executeGroup7(cpu);
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

        // WBINVD (Write-Back and Invalidate Cache)
        0x09 => {
            // No-op for emulator (no cache to invalidate)
        },

        // INVD (Invalidate Cache)
        0x08 => {
            // No-op for emulator
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

        else => {
            cpu.dumpInstructionHistory();
            std.debug.print("\nINVALID TWO-BYTE OPCODE: 0F {X:02} at {X:04}:{X:08}\n", .{ opcode, cpu.current_instr_cs, cpu.current_instr_eip });
            std.debug.print("Registers: EAX={X:08} EBX={X:08} ECX={X:08} EDX={X:08}\n", .{ cpu.regs.eax, cpu.regs.ebx, cpu.regs.ecx, cpu.regs.edx });
            @panic("Unhandled two-byte opcode");
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
    cpu.flags.updateArithmetic8(result, carry, overflow);
    return result;
}

fn addWithFlags16(cpu: *Cpu, a: u16, b: u16) u16 {
    const result_full = @as(u32, a) + @as(u32, b);
    const result: u16 = @truncate(result_full);
    const carry = result_full > 0xFFFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x8000) != 0;
    cpu.flags.updateArithmetic16(result, carry, overflow);
    return result;
}

fn addWithFlags32(cpu: *Cpu, a: u32, b: u32) u32 {
    const result_full = @as(u64, a) + @as(u64, b);
    const result: u32 = @truncate(result_full);
    const carry = result_full > 0xFFFFFFFF;
    const overflow = ((a ^ result) & (b ^ result) & 0x80000000) != 0;
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

fn handleInterrupt(cpu: *Cpu, vector: u8) !void {
    // Simplified interrupt handling - just push flags, CS, IP
    try cpu.push(cpu.flags.toU32());
    try cpu.push16(cpu.segments.cs);
    try cpu.push(@truncate(cpu.eip));

    // For now, just use a simple IVT lookup (real mode style)
    const ivt_addr = @as(u32, vector) * 4;
    const new_ip = try cpu.readMemWord(ivt_addr);
    const new_cs = try cpu.readMemWord(ivt_addr + 2);

    cpu.segments.cs = new_cs;
    cpu.eip = new_ip;
    cpu.flags.interrupt = false;
}

// Tests
test "nop instruction" {
    const allocator = std.testing.allocator;
    const memory = @import("../memory/memory.zig");
    const io_mod = @import("../io/io.zig");

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
    const memory = @import("../memory/memory.zig");
    const io_mod = @import("../io/io.zig");

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
