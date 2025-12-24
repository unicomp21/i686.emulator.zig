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
            try executeTwoByteOpcode(cpu, opcode2);
        },

        // Group 1 (80-83)
        0x80, 0x81, 0x82, 0x83 => {
            try executeGroup1(cpu, opcode);
        },

        else => {
            return CpuError.InvalidOpcode;
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

        else => {
            return CpuError.InvalidOpcode;
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

// Helper functions

fn fetchByte(cpu: *Cpu) !u8 {
    const addr = cpu.getEffectiveAddress(cpu.segments.cs, cpu.eip);
    const byte = try cpu.mem.readByte(addr);
    cpu.eip +%= 1;
    return byte;
}

fn fetchWord(cpu: *Cpu) !u16 {
    const lo = try fetchByte(cpu);
    const hi = try fetchByte(cpu);
    return (@as(u16, hi) << 8) | lo;
}

fn fetchDword(cpu: *Cpu) !u32 {
    const lo = try fetchWord(cpu);
    const hi = try fetchWord(cpu);
    return (@as(u32, hi) << 16) | lo;
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
    return cpu.mem.readByte(addr);
}

fn readRM16(cpu: *Cpu, modrm: ModRM) !u16 {
    if (modrm.mod == 3) {
        return cpu.regs.getReg16(modrm.rm);
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    return cpu.mem.readWord(addr);
}

fn readRM32(cpu: *Cpu, modrm: ModRM) !u32 {
    if (modrm.mod == 3) {
        return cpu.regs.getReg32(modrm.rm);
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    return cpu.mem.readDword(addr);
}

fn writeRM8(cpu: *Cpu, modrm: ModRM, value: u8) !void {
    if (modrm.mod == 3) {
        cpu.regs.setReg8(modrm.rm, value);
        return;
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    try cpu.mem.writeByte(addr, value);
}

fn writeRM16(cpu: *Cpu, modrm: ModRM, value: u16) !void {
    if (modrm.mod == 3) {
        cpu.regs.setReg16(modrm.rm, value);
        return;
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    try cpu.mem.writeWord(addr, value);
}

fn writeRM32(cpu: *Cpu, modrm: ModRM, value: u32) !void {
    if (modrm.mod == 3) {
        cpu.regs.setReg32(modrm.rm, value);
        return;
    }
    const addr = try calculateEffectiveAddress(cpu, modrm);
    try cpu.mem.writeDword(addr, value);
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
    const new_ip = try cpu.mem.readWord(ivt_addr);
    const new_cs = try cpu.mem.readWord(ivt_addr + 2);

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
