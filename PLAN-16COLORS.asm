; ============================================================================
; PLAN-16COLORS.ASM - 16-color Plantronics test chart
; Written for NASM - 8086/8088 code only
; Shows the 16 CGA RGBI colors as a 4x4 block grid in Plantronics mode.
; Press ESC to exit.
; ============================================================================

[BITS 16]
[ORG 0x100]
CPU 8086

VRAM_SEG         equ 0xB800
VRAM_EXT_OFS     equ 0x4000

PORT_MODE        equ 0x3D8
PORT_COLOR       equ 0x3D9
PORT_IGA_EXT     equ 0x3DB
PORT_PLANTRONICS equ 0x3DD

main:
    mov ah, 0x0F
    int 0x10
    mov [old_mode], al

    mov ax, 0x0004
    int 0x10

    mov dx, PORT_MODE
    in al, dx
    in al, dx
    mov dx, PORT_IGA_EXT
    mov al, 0x40
    out dx, al
    mov dx, PORT_PLANTRONICS
    mov al, 0x10
    out dx, al

    mov dx, PORT_COLOR
    xor al, al
    out dx, al

    call draw_grid

.wait_key:
    xor ah, ah
    int 0x16
    cmp al, 0x1B
    jne .wait_key

    mov ah, 0x00
    mov al, [old_mode]
    int 0x10

    mov ax, 0x4C00
    int 0x21

draw_grid:
    push es
    mov ax, VRAM_SEG
    mov es, ax

    xor bx, bx                  ; row 0..199
.row_loop:
    cmp bx, 200
    jge .done

    mov ax, bx
    xor dx, dx
    mov si, 50
    div si                      ; AX = block row, DX = row within block
    mov bp, ax                  ; BP = block row 0..3

    mov ax, bx
    shr ax, 1
    mov cx, 80
    mul cx                      ; AX = (row / 2) * 80
    mov di, ax
    test bl, 1
    jz .row_base_ok
    add di, 0x2000
.row_base_ok:

    xor dx, dx                  ; cell index 0..3
.cell_loop:
    mov si, bp
    shl si, 1
    shl si, 1                   ; SI = block_row * 4
    add si, dx                  ; SI = color index 0..15

    mov al, [rg_tab + si]
    mov ah, [ib_tab + si]

    push bx
    push di
    mov bx, di
    add bx, VRAM_EXT_OFS
    mov cx, 20                  ; 20 bytes = 80 pixels per cell
.fill_cell:
    mov [es:di], al
    mov [es:bx], ah
    inc di
    inc bx
    loop .fill_cell
    pop di
    pop bx

    add di, 20
    inc dx
    cmp dx, 4
    jb .cell_loop

    inc bx
    jmp .row_loop

.done:
    pop es
    ret

old_mode db 0

; Plantronics plane encoding (per pixel, 2 bits per plane) — verified on hardware:
;   plane0 (RG) = (R << 1) | G   where R = bit2, G = bit1 of IRGB nibble
;   plane1 (IB) = (B << 1) | I   where B = bit0, I = bit3 of IRGB nibble
; A whole byte filled with same 2-bit value: 0=0x00, 1=0x55, 2=0xAA, 3=0xFF
rg_tab:
    ; n=0..7: I=0
    db 0,    0,    055h, 055h, 0AAh, 0AAh, 0FFh, 0FFh
    ; n=8..15: I=1 (RG bits unchanged)
    db 0,    0,    055h, 055h, 0AAh, 0AAh, 0FFh, 0FFh

ib_tab:
    ; n=0..7: I=0  ->  IB = (B<<1)  (0 or 2)
    db 0,    0AAh, 0,    0AAh, 0,    0AAh, 0,    0AAh
    ; n=8..15: I=1 ->  IB = (B<<1)|1  (1 or 3)
    db 055h, 0FFh, 055h, 0FFh, 055h, 0FFh, 055h, 0FFh
