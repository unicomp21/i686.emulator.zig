; test_boot.asm - Minimal boot sector test for i686 emulator
;
; This is a 512-byte boot sector that:
; 1. Prints "BOOT" in real mode via UART
; 2. Sets up a minimal GDT
; 3. Switches to protected mode
; 4. Prints "PROT" via UART in protected mode
; 5. Halts
;
; Assemble with: nasm -f bin -o test_boot.bin test_boot.asm
; Run with: zig build run -- tests/linux/build/test_boot.bin

BITS 16
ORG 0x0000

start:
    ; Initialize segments
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00      ; Stack just before boot sector

    ; Print "BOOT" in real mode via UART (COM1 = 0x3F8)
    mov dx, 0x3F8
    mov al, 'B'
    out dx, al
    mov al, 'O'
    out dx, al
    mov al, 'O'
    out dx, al
    mov al, 'T'
    out dx, al

    ; Load GDT
    lgdt [gdt_descriptor]

    ; Enable protected mode (set PE bit in CR0)
    mov eax, cr0
    or al, 1
    mov cr0, eax

    ; Far jump to protected mode code
    ; Segment 0x08 = code segment (index 1 in GDT)
    jmp 0x08:protected_mode

BITS 32
protected_mode:
    ; Set up data segments (0x10 = data segment, index 2 in GDT)
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x7C00

    ; Print "PROT" in protected mode via UART
    mov dx, 0x3F8
    mov al, 'P'
    out dx, al
    mov al, 'R'
    out dx, al
    mov al, 'O'
    out dx, al
    mov al, 'T'
    out dx, al

    ; Halt
    hlt
    jmp $               ; Infinite loop in case of spurious wake

; Global Descriptor Table (GDT)
align 8
gdt_start:
    ; Null descriptor (required)
    dq 0

gdt_code:
    ; Code segment descriptor
    ; Base=0, Limit=0xFFFFF, Access=0x9A (present, ring 0, code, readable)
    ; Flags=0xC (granularity=4KB, 32-bit)
    dw 0xFFFF           ; Limit 0:15
    dw 0x0000           ; Base 0:15
    db 0x00             ; Base 16:23
    db 0x9A             ; Access: present, ring 0, code, readable
    db 0xCF             ; Flags (4 bits) + Limit 16:19 (4 bits)
    db 0x00             ; Base 24:31

gdt_data:
    ; Data segment descriptor
    ; Base=0, Limit=0xFFFFF, Access=0x92 (present, ring 0, data, writable)
    ; Flags=0xC (granularity=4KB, 32-bit)
    dw 0xFFFF           ; Limit 0:15
    dw 0x0000           ; Base 0:15
    db 0x00             ; Base 16:23
    db 0x92             ; Access: present, ring 0, data, writable
    db 0xCF             ; Flags (4 bits) + Limit 16:19 (4 bits)
    db 0x00             ; Base 24:31

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1  ; GDT size - 1
    dd gdt_start                ; GDT base address

; Pad to 510 bytes and add boot signature
times 510-($-$$) db 0
dw 0xAA55                       ; Boot sector signature
