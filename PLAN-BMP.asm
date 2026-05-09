; ============================================================================
; PLAN-BMP.ASM (v 1.1) - BMP Image Viewer for Plantronics ColorPlus machines
; Plantronics ColorPlus 320x200x16 Graphics Mode
; Written for NASM - 8086/8088 code only
; Targets: Schneider EuroPC, Schneider EuroPC II, Amstrad PC1640
;          (any machine with a Plantronics-compatible CGA adapter)
; By Retro Erik - 2026 using VS Code with GitHub Copilot
;
; Supports: 4-bit (16-color) BMP files, 320x200, uncompressed (BI_RGB)
; Usage: PLAN-BMP filename.bmp
;        Enter toggles Sierra-style 2x2 checker dithering, other key exits
;
; Features:
;   - Text loading splash stays visible throughout decode (both builds)
;   - Both builds decode to offscreen buffer, then reveal in one VRAM blit
;   - C64-style border color cycling visible during decode (Plantronics build).
;     NOTE: 86Box does not faithfully render border-color writes during the
;     text-mode splash, so the loading flicker may appear absent in 86Box
;     even though the code is working. Verified visible on real EuroPC.
;   - Plantronics ColorPlus two-plane VRAM encoding (RG + IB planes)
;   - BMP bottom-up row order and dword row-padding handled correctly
;   - 320x200 BMP only (other widths/heights rejected)
;   - Saturation-aware nearest-color remap: dR^2+dG^2+dB^2 + 2*dMax^2.
;     Routes pure-RGB primaries (255,0,0) etc. to the intense CGA palette
;     while preserving exact matches on standard IBM CGA values.
;
; Version history:
;   v1.0 - Initial release. Plain Euclidean RGB nearest-color match.
;   v1.1 - Hardware-verified plane 1 encoding `(B<<1)|I` (corrected from
;          Sierra PCPLUS.DRV reference). Brown anchor fixed to IBM CGA value
;          (0,21,42 in BGR / 170,85,0 in RGB). Saturation-aware matcher with
;          extra 2*dMax^2 term so pure-RGB BMP palettes (255,0,0 / 0,255,0 /
;          0,0,255) map to light red / light green / light blue instead of
;          the dark variants.
;
; Build targets:
;   Plantronics (real hardware):
;     nasm -f bin PLAN-BMP.asm -o bin/PLAN-BMP.COM -l bin/PLAN-BMP.lst
;
;   Tandy/PCjr (DOSBox testing — requires machine=tandy in dosbox.conf):
;     nasm -f bin -DTANDY PLAN-BMP.asm -o bin/TDY-BMP.COM -l bin/TDY-BMP.lst
;
;   The Tandy build uses INT 10h mode 9 (320x200x16). The BMP 4-bit nibble
;   format is identical to Tandy VRAM format. Before decode, a software remap
;   table is built from the BMP palette so arbitrary 16-color BMPs map to the
;   nearest fixed CGA/Tandy/Plantronics RGBI colors.
;
; Plantronics ColorPlus memory layout:
;   Standard plane (RG bits): B800:0000h - B800:3FFFh (16 KB)
;   Extended plane (BI bits): B800:4000h - B800:7FFFh (16 KB)
;   CGA interlace: even rows at +0000h, odd rows at +2000h (per plane)
;   Each byte encodes 4 pixels × 2 bits
;   Bytes per row (per plane): 80
;
; Tandy/PCjr mode 9 memory layout:
;   VRAM at B800:0000h, 4-way interleave in 8KB banks:
;     row mod 4 = 0 -> +0000h
;     row mod 4 = 1 -> +2000h
;     row mod 4 = 2 -> +4000h
;     row mod 4 = 3 -> +6000h
;   Within each bank: offset = (row / 4) * 160
;   Each byte encodes 2 pixels (high nibble = left, low nibble = right)
;   50 rows per bank: 50 * 160 = 8000 bytes (< 8192)
;
; NOTE: Hardware palette programming is not used here (fixed RGBI hardware).
;       Instead, BMP palette entries are mapped in software to nearest CGA index.
; ============================================================================

[BITS 16]
[ORG 0x100]
CPU 8086

; ============================================================================
; Constants
; ============================================================================

; --- Plantronics VRAM ---
VRAM_SEG        equ 0xB800      ; Plantronics video RAM segment
VRAM_EXT_OFS    equ 0x4000      ; Extended plane offset within B800 segment
VRAM_ODD_OFS    equ 0x2000      ; CGA odd-row bank offset (per plane)

; --- CGA I/O Ports ---
PORT_MODE       equ 0x3D8       ; CGA Mode Control Register
PORT_COLOR      equ 0x3D9       ; CGA Color Select Register (border + palette)
PORT_STATUS     equ 0x3DA       ; CGA Status Register (VBlank / HBlank)
PORT_PLANTRONICS equ 0x3DD      ; Plantronics Mode Register

; --- BMP File Header offsets ---
BMP_SIGNATURE   equ 0           ; 'BM' signature (2 bytes)
BMP_FILESIZE    equ 2           ; File size (dword)
BMP_RESERVED    equ 6           ; Reserved (dword)
BMP_DATA_OFFSET equ 10          ; Offset to pixel data (dword)

; --- BMP Info Header offsets ---
BMP_HEADER_SIZE equ 14          ; Info header size (dword, value=40)
BMP_WIDTH       equ 18          ; Image width (dword)
BMP_HEIGHT      equ 22          ; Image height (dword)
BMP_PLANES      equ 26          ; Planes (word, should be 1)
BMP_BPP         equ 28          ; Bits per pixel (word)
BMP_COMPRESSION equ 30          ; Compression (dword, 0=none)
BMP_IMAGE_SIZE  equ 34          ; Image size (dword)
BMP_PALETTE_OFS equ 54          ; Palette starts here (16 colors × 4 bytes BGRA)

SCREEN_WIDTH    equ 320
SCREEN_HEIGHT   equ 200

; ============================================================================
; Entry Point
; ============================================================================
main:
    ; No arguments? Jump to usage (forward reference resolved via jmp)
    jmp .parse_cmdline

.show_usage:
    mov dx, msg_info
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

.parse_cmdline:
    ; Parse command line for filename
    mov si, 0x81            ; PSP command line starts at 0x81
    
    ; Skip leading spaces
.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D            ; End of command line?
    je .show_usage
    
    ; Check for /? or /h or /H
    cmp al, '/'
    jne .not_help
    lodsb
    cmp al, '?'
    je .show_usage
    cmp al, 'h'
    je .show_usage
    cmp al, 'H'
    je .show_usage
    dec si
    dec si
    jmp .save_filename
    
.not_help:
    dec si
    
.save_filename:
    ; Copy filename token to local buffer and auto-append .bmp when missing.
    ; This avoids modifying PSP command tail and allows: PLAN-BMP IMAGE
    mov di, filename_buf
    xor dl, dl              ; DL = dot-in-basename flag (0=no dot)

.copy_filename:
    lodsb
    cmp al, ' '
    je .copy_done
    cmp al, 0x0D
    je .copy_done

    ; Reset extension flag at path separators/drive delimiter.
    cmp al, 0x5C
    je .copy_sep
    cmp al, '/'
    je .copy_sep
    cmp al, ':'
    je .copy_sep

    ; Dot inside current basename means extension already provided.
    cmp al, '.'
    jne .copy_store
    mov dl, 1
    jmp .copy_store

.copy_sep:
    xor dl, dl

.copy_store:
    stosb
    jmp .copy_filename

.copy_done:
    ; Append default extension when basename has no dot.
    cmp dl, 0
    jne .copy_term
    mov al, '.'
    stosb
    mov al, 'b'
    stosb
    mov al, 'm'
    stosb
    mov al, 'p'
    stosb

.copy_term:
    xor al, al
    stosb
    mov word [filename_ptr], filename_buf

    ; Save current video mode (INT 10h AH=0Fh)
    mov ah, 0x0F
    int 0x10
    mov [saved_video_mode], al

    ; Open the BMP file
    mov dx, [filename_ptr]
    mov ax, 0x3D00          ; DOS Open File (read-only)
    int 0x21
    jc .file_error
    mov [file_handle], ax
    
    ; Read BMP file header + info header + palette = 118 bytes
    ; 14 (file hdr) + 40 (info hdr) + 64 (16 colors × 4 bytes BGRA)
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F
    int 0x21
    jc .file_error
    cmp ax, 118
    jb .file_error
    
    ; Verify BMP signature ('BM')
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp
    
    ; Check bits per pixel = 4
    cmp word [bmp_header + BMP_BPP], 4
    jne .wrong_format
    
    ; Check compression = 0 (uncompressed)
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format
    cmp word [bmp_header + BMP_COMPRESSION + 2], 0
    jne .wrong_format
    
    ; Check width = 320
    cmp word [bmp_header + BMP_WIDTH], SCREEN_WIDTH
    jne .wrong_size
    cmp word [bmp_header + BMP_WIDTH + 2], 0
    jne .wrong_size
    
    ; Check height = 200 (absolute value, may be negative for top-down)
    mov ax, [bmp_header + BMP_HEIGHT]
    cmp ax, SCREEN_HEIGHT
    je .height_ok
    neg ax
    cmp ax, SCREEN_HEIGHT
    jne .wrong_size
.height_ok:

    ; Build software palette remap from BMP palette entry RGB values.
    ; pal_remap[n] gives nearest CGA color index for BMP index n.
    ; Also builds secondary checkerboard pair tables for optional dithering.
    call build_palette_remap

    ; Seek to pixel data
    call seek_pixel_data
    jc .file_error

    ; Show ANSI splash screen (same style as PC1-BMP4)
    mov ax, 0x0003          ; Clear text mode screen
    int 0x10
    mov dx, msg_splash
    mov ah, 0x09
    int 0x21
    call set_splash_cursor

    ; Hardware palette programming is not used.
    ; The loaded BMP palette has already been converted into pal_remap[] by
    ; build_palette_remap and decode_bmp uses those remapped indexes.

    ; Decode to offscreen buffer while text splash remains visible.
    ; Same pattern as PC1-BMP4: real work happens before graphics mode switch.
    call decode_bmp

    ; Switch to graphics mode and reveal decoded image in one shot.
%ifdef TANDY
    call enable_graphics_mode
    call reveal_tandy_buffer
%else
    call enable_graphics_mode
    call reveal_plantronics_buffer

    ; Reset border to black after reveal
    xor al, al
    call set_border_color
%endif

    ; View loop:
    ;   Enter toggles Sierra-style 2x2 checkerboard dithering ON/OFF
    ;   Any other key exits
.view_loop:
    xor ah, ah
    int 0x16
    cmp al, 0x0D            ; Enter?
    jne .close_and_exit

    ; Toggle dithering and re-decode from BMP pixels
    xor byte [dither_enabled], 1
    call seek_pixel_data
    jc .close_and_exit
    call decode_bmp

%ifdef TANDY
    call reveal_tandy_buffer
%else
    call reveal_plantronics_buffer

    ; Keep border stable after reveal
    xor al, al
    call set_border_color
%endif
    jmp .view_loop

.close_and_exit:
    ; Close file
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21

    ; Disable Plantronics mode
    call disable_graphics_mode
    
    ; Restore original video mode
    mov al, [saved_video_mode]
    xor ah, ah
    int 0x10
    
    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

; --- Error handlers ---
.file_error:
    mov dx, msg_file_err
    jmp .print_exit
.not_bmp:
    mov dx, msg_not_bmp
    jmp .print_exit
.wrong_format:
    mov dx, msg_format
    jmp .print_exit
.wrong_size:
    mov dx, msg_size
    jmp .print_exit
.print_exit:
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; enable_graphics_mode - Set 320x200x16 graphics mode
;
; Plantronics build:
;   Sets CGA mode 4, then uses the portable PC1640 unlock sequence:
;     read 0x3D8 twice → OUT 0x3DB,0x40 → OUT 0x3DD,0x10
;   On EuroPC/plain Plantronics the extra steps are harmless no-ops.
;   Works on EuroPC, EuroPC II, and PC1640 (sw5=ON / CGA-compatible mode).
;   Single binary — no runtime detection needed.
;
; Tandy build (-DTANDY):
;   Uses INT 10h mode 9 (320x200x16 Tandy/PCjr). Requires machine=tandy in DOSBox.
; ============================================================================
enable_graphics_mode:
    push ax
    push dx

%ifdef TANDY
    ; Tandy/PCjr mode 9: 320x200x16 — BIOS sets everything up
    mov ax, 0x0009
    int 0x10
%else
    ; Set CGA mode 4 (320x200 graphics) via BIOS
    mov ax, 0x0004
    int 0x10

    ; Enable Plantronics extended plane — portable sequence:
    ;   PC1640 IGA needs: read 0x3D8 twice, OUT 0x3DB,0x40, then OUT 0x3DD,0x10
    ;   On EuroPC/plain Plantronics: the extra reads and OUT 0x3DB are harmless NOPs
    ;   One binary works on both machines (sw5=ON required on PC1640)
    ;   Ports > 255 require DX on 8086/8088 — cannot use immediate port form
    mov dx, 0x3D8
    in  al, dx              ; arm IGA ext-mode register (no-op on EuroPC)
    in  al, dx              ; second arm
    mov dx, 0x3DB
    mov al, 0x40
    out dx, al              ; enable 6845-compat mode on PC1640 (no-op on EuroPC)
    mov dx, PORT_PLANTRONICS
    mov al, 0x10
    out dx, al              ; enable Plantronics extended plane (both machines)
%endif

%ifndef TANDY
    ; Set border color = black (not needed in Tandy — BIOS handles it)
    xor al, al
    call set_border_color
%endif

    pop dx
    pop ax
    ret

; ============================================================================
; disable_graphics_mode - Disable hardware-specific graphics mode
; Plantronics: OUT 0x3DD, 0x00 disables the extended color plane.
; Tandy: nothing to do (video mode restored by caller via INT 10h).
; ============================================================================
disable_graphics_mode:
    push ax
    push dx

%ifndef TANDY
    ; Disable Plantronics extended plane
    mov dx, PORT_PLANTRONICS
    xor al, al
    out dx, al
%endif

    pop dx
    pop ax
    ret

; ============================================================================
; set_border_color - Set the CGA color/border register (0x3D9)
; Input: AL = new border color (0-15)
;
; NOTE: 0x3D9 is WRITE-ONLY on real CGA hardware; read-modify-write returns
; garbage on EuroPC and pins the border. We just write the low nibble; in
; Plantronics 320x200x16 mode the upper bits (palette select / bright bg)
; are unused, so writing 0 to them is harmless.
; ============================================================================
set_border_color:
    push ax
    push dx

    and al, 0x0F
    mov dx, PORT_COLOR
    out dx, al

    pop dx
    pop ax
    ret

%ifdef TANDY
; ============================================================================
; reveal_tandy_buffer - Copy offscreen Tandy backbuffer to VRAM
; ============================================================================
reveal_tandy_buffer:
    push ax
    push cx
    push di
    push si
    push es

    mov si, tandy_backbuf
    mov ax, VRAM_SEG
    mov es, ax
    xor di, di
    mov cx, 16384           ; 32 KB
    cld
    rep movsw

    pop es
    pop si
    pop di
    pop cx
    pop ax
    ret
%endif

%ifndef TANDY
; ============================================================================
; reveal_plantronics_buffer - Copy offscreen Plantronics buffer to VRAM
;
; Copies 32KB from plan_backbuf (DS segment) to B800:0000.
; Covers standard plane (0x0000-0x3FFF) and extended plane (0x4000-0x7FFF).
; Call AFTER enable_graphics_mode so the extended plane is active.
; ============================================================================
reveal_plantronics_buffer:
    push ax
    push cx
    push di
    push si
    push es

    mov ax, VRAM_SEG
    mov es, ax
    mov si, plan_backbuf
    xor di, di
    mov cx, 16384           ; 32 KB
    cld
    rep movsw

    pop es
    pop si
    pop di
    pop cx
    pop ax
    ret
%endif

; ============================================================================
; set_splash_cursor - Place cursor just after "Loading Image..."
; Row/Col are zero-based for INT 10h AH=02.
; ============================================================================
set_splash_cursor:
    push ax
    push bx
    push dx

    mov ah, 0x02
    xor bh, bh              ; page 0
    mov dh, 15              ; row 16 (one line up)
    mov dl, 48              ; col 49 (just after the last '.')
    int 0x10

    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; seek_pixel_data - Seek DOS file handle to BMP pixel data offset
; Uses BMP_DATA_OFFSET from already loaded file header.
; Returns CF set on DOS seek error.
; ============================================================================
seek_pixel_data:
    push ax
    push bx
    push cx
    push dx

    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200          ; Seek from beginning
    int 0x21

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; build_palette_remap - Build BMP index -> nearest CGA index mapping table
;
; Input:
;   bmp_header + BMP_PALETTE_OFS contains 16 * BGRA palette entries
;
; Output:
;   pal_remap[16]      : nearest CGA color index (primary)
;   pal_remap_alt[16]  : second-nearest CGA color index (secondary)
;   pal_dither_even[16]: map used for even checkerboard pixels
;   pal_dither_odd[16] : map used for odd checkerboard pixels
;
; Method:
;   For each BMP palette color, find nearest of 16 CGA RGBI colors using
;   squared distance in 6-bit RGB space (component >> 2) plus a saturation
;   term:
;
;       dist = dR^2 + dG^2 + dB^2 + 2 * dMax^2
;
;   where Max = max(R,G,B) for both the BMP color and the CGA anchor. The
;   extra dMax term penalizes anchors whose dominant channel is dimmer than
;   the input, so pure (255,0,0) maps to light red (255,85,85) rather than
;   dark red (170,0,0). For exact IBM CGA palette inputs dMax=0, so standard
;   palettes still match exactly.
; ============================================================================
build_palette_remap:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    xor si, si              ; SI = BMP palette index 0..15

.bmp_loop:
    ; Load BMP palette entry (BGRA), convert B,G,R to 6-bit values.
    mov bx, si
    shl bx, 1
    shl bx, 1               ; BX = index * 4

    mov al, [bmp_header + BMP_PALETTE_OFS + bx]      ; B
    shr al, 1
    shr al, 1
    mov [tmp_b], al

    mov al, [bmp_header + BMP_PALETTE_OFS + bx + 1]  ; G
    shr al, 1
    shr al, 1
    mov [tmp_g], al

    mov al, [bmp_header + BMP_PALETTE_OFS + bx + 2]  ; R
    shr al, 1
    shr al, 1
    mov [tmp_r], al

    ; Compute tmp_max = max(tmp_b, tmp_g, tmp_r) for saturation-aware match.
    mov al, [tmp_b]
    cmp al, [tmp_g]
    jae .max_skip_g
    mov al, [tmp_g]
.max_skip_g:
    cmp al, [tmp_r]
    jae .max_skip_r
    mov al, [tmp_r]
.max_skip_r:
    mov [tmp_max], al

    mov word [best_dist], 0xFFFF
    mov word [second_best_dist], 0xFFFF
    mov byte [best_idx], 0
    mov byte [second_idx], 0
    xor di, di              ; DI = candidate CGA index 0..15

.cga_loop:
    ; BX = candidate * 3 (B,G,R triplet offset)
    mov bx, di
    add bx, di
    add bx, di

    ; dist += (Bbmp - Bcga)^2
    mov al, [tmp_b]
    sub al, [cga_rgb6 + bx]
    jnc .b_abs
    neg al
.b_abs:
    xor ah, ah
    mul al
    mov cx, ax

    ; dist += (Gbmp - Gcga)^2
    mov al, [tmp_g]
    sub al, [cga_rgb6 + bx + 1]
    jnc .g_abs
    neg al
.g_abs:
    xor ah, ah
    mul al
    add cx, ax

    ; dist += (Rbmp - Rcga)^2
    mov al, [tmp_r]
    sub al, [cga_rgb6 + bx + 2]
    jnc .r_abs
    neg al
.r_abs:
    xor ah, ah
    mul al
    add cx, ax

    ; dist += 2 * (max_bmp - max_cga)^2  (saturation/brightness term)
    mov al, [tmp_max]
    sub al, [cga_max6 + di]
    jnc .m_abs
    neg al
.m_abs:
    xor ah, ah
    mul al
    add cx, ax
    add cx, ax

    cmp cx, [best_dist]
    jae .maybe_second

    ; New best: previous best becomes second-best.
    mov ax, [best_dist]
    mov [second_best_dist], ax
    mov al, [best_idx]
    mov [second_idx], al

    mov [best_dist], cx
    mov ax, di
    mov [best_idx], al
    jmp .next_cga

.maybe_second:
    cmp cx, [second_best_dist]
    jae .next_cga
    mov [second_best_dist], cx
    mov ax, di
    mov [second_idx], al

.next_cga:
    inc di
    cmp di, 16
    jb .cga_loop

    ; Use nearest-color match as-is; dithering enabled if distance > ~400


.save_pair:

    ; Save final remap pair for this BMP palette entry.
    mov al, [best_idx]
    mov [pal_remap + si], al
    mov [pal_dither_even + si], al

    mov al, [second_idx]
    mov [pal_remap_alt + si], al

    ; Enable dither pair only when primary is not an exact match.
    mov ax, [best_dist]
    or ax, ax
    jz .store_odd_as_primary
    mov al, [second_idx]
    jmp .store_odd_done

.store_odd_as_primary:
    mov al, [best_idx]
.store_odd_done:
    mov [pal_dither_odd + si], al

    inc si
    cmp si, 16
    jb .bmp_loop

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; decode_bmp - Read BMP pixel data into offscreen buffer
;
; Both builds decode entirely in text mode while the splash is visible.
; After this returns, the caller switches to graphics mode and blits the buffer.
;
; BMP format: 4-bit packed nibbles, bottom-up, rows padded to dword boundary
; Each byte in the BMP holds 2 pixels: high nibble = left pixel, low = right
; Each nibble is a CGA color index 0-15 (IRGB)
;
; Plantronics encoding (per pixel, color = IRGB = bits 3,2,1,0):
;   Standard plane byte: encodes R (bit 2) and G (bit 1) for 4 pixels
;   Extended plane byte: encodes I (bit 3) and B (bit 0) for 4 pixels
;
;   For 4 pixels packed into one plane byte:
;     Standard plane:  [R3,G3, R2,G2, R1,G1, R0,G0]  (2 bits per pixel)
;     Extended plane:  [I3,B3, I2,B2, I1,B1, I0,B0]  (2 bits per pixel)
;
; CGA color encoding (IRGB nibble → plane bits, verified on real hardware):
;   Standard plane pixel bits = (R << 1) | G  = (color >> 1) & 3
;   Extended plane pixel bits = (B << 1) | I  = ((color & 1) << 1) | ((color >> 3) & 1)
;   where color = IRGB nibble (bit3=I, bit2=R, bit1=G, bit0=B)
;   Note: IB plane uses B as high bit on EuroPC/PC1640 hardware (verified by
;   PLAN-16COLORS test). This differs from some Sierra driver references.
;
; Row addressing (per plane):
;   Even row y: offset = (y / 2) * 80
;   Odd  row y: offset = 0x2000 + (y / 2) * 80
; ============================================================================
decode_bmp:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es
    push ds

%ifdef TANDY
    ; Tandy build: decode to offscreen aperture-sized buffer first,
    ; then copy full 32KB to VRAM at the end for instant reveal.
    push ds
    pop es

    mov di, tandy_backbuf
    mov cx, 16384           ; 32 KB
    xor ax, ax
    cld
    rep stosw
%else
    ; Plantronics build: decode to offscreen buffer in DS segment.
    ; Text splash remains visible throughout decode (graphics mode not yet active).
    push ds
    pop es                  ; ES = DS for stosw / [es:bx] writes

    mov di, plan_backbuf
    mov cx, 16384           ; 32 KB
    xor ax, ax
    cld
    rep stosw
%endif

    ; Calculate bytes per row in BMP file (with dword padding)
    ; For 4-bit 320px: raw bytes = 160, already dword-aligned (160 mod 4 = 0)
    mov word [bytes_per_row], 160

    ; BMP is stored bottom-up: start at row 199, count down to 0
    mov word [current_row], 199

.row_loop:
%ifndef TANDY
    ; C64-style border cycle: one step per BMP row (~200 steps over the
    ; whole decode -> visible color sweep without slowing things down).
    mov al, [border_ctr]
    call set_border_color
    inc byte [border_ctr]
    and byte [border_ctr], 0x0F
%endif
    ; --- Read one BMP scanline into row_buffer ---
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done

    ; Select per-row palette maps for optional 2x2 checkerboard dithering.
    ; If dithering is OFF, both pointers use pal_remap.
    cmp byte [dither_enabled], 0
    jne .dither_row_select
    mov word [map_even_ptr], pal_remap
    mov word [map_odd_ptr], pal_remap
    jmp .dither_map_ready

.dither_row_select:
    mov ax, [current_row]
    test al, 1
    jnz .dither_row_odd
    mov word [map_even_ptr], pal_dither_even
    mov word [map_odd_ptr], pal_dither_odd
    jmp .dither_map_ready

.dither_row_odd:
    mov word [map_even_ptr], pal_dither_odd
    mov word [map_odd_ptr], pal_dither_even

.dither_map_ready:

    ; --- Calculate VRAM row offset ---
    ; Plantronics: CGA interleave — even row = (y/2)*80, odd row = 0x2000 + (y/2)*80
    ;   Works because 100 rows × 80 bytes = 8000 < 8192 (0x2000) — no overlap.
    ;
    ; Tandy mode 9: 4-way scanline interleave in 8KB banks.
    ;   bank = row & 3, base = bank * 0x2000
    ;   intra-bank offset = (row >> 2) * 160
    ; This maps 200 rows as 4 banks × 50 rows/bank.
%ifdef TANDY
    mov ax, [current_row]
    mov bx, ax              ; BX = row number

    ; DI = (row >> 2) * 160
    shr ax, 1
    shr ax, 1               ; AX = row / 4
    mov dx, 160
    mul dx
    mov di, ax

    ; Add bank base by row mod 4: +0000/+2000/+4000/+6000
    mov ax, bx
    and ax, 3
    jz .tandy_bank_done
    cmp ax, 1
    je .tandy_bank_1
    cmp ax, 2
    je .tandy_bank_2
    ; ax == 3
    add di, 0x6000
    jmp .tandy_bank_done
.tandy_bank_1:
    add di, 0x2000
    jmp .tandy_bank_done
.tandy_bank_2:
    add di, 0x4000
.tandy_bank_done:
    add di, tandy_backbuf   ; Write to offscreen buffer, not live VRAM
%else
    mov ax, [current_row]
    mov bx, ax              ; BX = row number (save for odd/even test)
    shr ax, 1               ; AX = row / 2
    mov dx, 80
    mul dx                  ; AX = (row/2) * 80
    mov di, ax

    test bl, 1              ; Odd row?
    jz .is_even
    add di, VRAM_ODD_OFS    ; Add 0x2000 for odd rows
.is_even:
%endif
    
    ; --- Encode 160 BMP bytes → 80 standard-plane bytes + 80 extended-plane bytes ---
    ; Each BMP byte holds 2 pixels (high nibble left, low nibble right).
    ; We process 2 BMP bytes at a time → 4 pixels → 1 byte per plane.
    ;
    ; For 4 pixels (p0,p1,p2,p3) each being a nibble (0-15 = IRGB):
    ;   Standard plane byte:
    ;     bits 7-6 = RG of p0  = (p0 >> 1) & 3
    ;     bits 5-4 = RG of p1  = (p1 >> 1) & 3
    ;     bits 3-2 = RG of p2  = (p2 >> 1) & 3
    ;     bits 1-0 = RG of p3  = (p3 >> 1) & 3
    ;   Extended plane byte:
    ;     bits 7-6 = IB of p0  = ((p0 >> 2) & 2) | (p0 & 1)
    ;     bits 5-4 = IB of p1  = ((p1 >> 2) & 2) | (p1 & 1)
    ;     bits 3-2 = IB of p2  = ((p2 >> 2) & 2) | (p2 & 1)
    ;     bits 1-0 = IB of p3  = ((p3 >> 2) & 2) | (p3 & 1)
    
    mov si, row_buffer

%ifdef TANDY
    ; -----------------------------------------------------------------------
    ; Tandy/PCjr mode 9 with optional Sierra-style 2x2 checker dithering.
    ; High nibble = even x pixel, low nibble = odd x pixel.
    ; -----------------------------------------------------------------------
    mov cx, 160

.tandy_copy_loop:
    lodsb
    mov ah, al

    ; High nibble (left pixel)
    shr al, 1               ; shr al,4 split into 4x shr al,1 (8086-safe; CX=loop counter)
    shr al, 1
    shr al, 1
    shr al, 1
    mov bx, [map_even_ptr]
    xlat                    ; AL = mapped palette index for even-x pixel
    mov dl, al
    shl dl, 1
    shl dl, 1
    shl dl, 1
    shl dl, 1               ; DL = remapped high nibble << 4

    ; Low nibble (right pixel)
    mov al, ah
    and al, 0x0F
    mov bx, [map_odd_ptr]
    xlat                    ; AL = mapped palette index for odd-x pixel
    or al, dl
    stosb

    dec cx
    jnz .tandy_copy_loop
%else
    ; -----------------------------------------------------------------------
    ; Plantronics: split each 4-pixel group into RG plane + IB plane bytes.
    ; -----------------------------------------------------------------------
    mov cx, 80              ; 80 output bytes per plane (= 320 pixels / 4 per byte)

.encode_loop:
    ; Load 2 BMP bytes = 4 pixels
    lodsb
    mov bh, al              ; BH = byte0: [p0_nibble][p1_nibble]
    lodsb
    mov bl, al              ; BL = byte1: [p2_nibble][p3_nibble]
    
    ; Extract 4 nibbles: p0 = BH>>4, p1 = BH&0F, p2 = BL>>4, p3 = BL&0F
    ; Build standard plane byte (RG bits of each pixel = (color>>1) & 3)
    ; Build extended plane byte (IB bits = ((color>>2)&2) | (color&1))
    
    ; Use LUT lookup for each nibble via BX.
    ;   pal map (even/odd) chooses nearest or checkerboard pair color index.
    ;   pix_rg_tab[n] = RG bits = (n >> 1) & 3   (2-bit value)
    ;   pix_ib_tab[n] = IB bits = ((n >> 2) & 2) | (n & 1)  (2-bit value)
    ;
    ; BH/BL hold the two raw BMP bytes. We push them, use BX for LUT indexing,
    ; then restore via the stack. DL = standard plane byte, DH = extended plane byte.
    
    push bx                 ; save raw bytes [p0p1][p2p3]
    
    ; --- p0 (x even): high nibble of saved byte0 ---
    mov al, bh
    shr al, 1               ; shr al,4 split into 4x shr al,1 (8086-safe; CX=loop counter)
    shr al, 1
    shr al, 1
    shr al, 1
    mov bx, [map_even_ptr]
    xlat
    xor bx, bx
    mov bl, al              ; BX = mapped p0 color index
    mov dl, [pix_rg_tab + bx]  ; DL = RG(mapped p0)
    shl dl, 1
    shl dl, 1               ; DL <<= 2
    
    ; --- p1 (x odd): low nibble of saved byte0 ---
    pop bx                  ; restore [p0p1][p2p3]
    push bx
    mov al, bh
    and al, 0x0F
    mov bx, [map_odd_ptr]
    xlat
    xor bx, bx
    mov bl, al              ; BX = mapped p1 color index
    mov al, [pix_rg_tab + bx]
    or dl, al
    shl dl, 1
    shl dl, 1               ; DL <<= 2
    
    ; --- p2 (x even): high nibble of saved byte1 ---
    pop bx
    push bx
    mov al, bl
    shr al, 1               ; shr al,4 split into 4x shr al,1 (8086-safe; CX=loop counter)
    shr al, 1
    shr al, 1
    shr al, 1
    mov bx, [map_even_ptr]
    xlat
    xor bx, bx
    mov bl, al              ; BX = mapped p2 color index
    mov al, [pix_rg_tab + bx]
    or dl, al
    shl dl, 1
    shl dl, 1
    
    ; --- p3 (x odd): low nibble of saved byte1 ---
    pop bx
    push bx
    mov al, bl
    and al, 0x0F
    mov bx, [map_odd_ptr]
    xlat
    xor bx, bx
    mov bl, al              ; BX = mapped p3 color index
    mov al, [pix_rg_tab + bx]
    or dl, al               ; DL = standard plane byte [RG0,RG1,RG2,RG3]
    
    ; --- Build extended plane byte (IB bits) ---
    ; --- p0 again (x even) ---
    pop bx
    push bx
    mov al, bh
    shr al, 1               ; shr al,4 split into 4x shr al,1 (8086-safe; CX=loop counter)
    shr al, 1
    shr al, 1
    shr al, 1
    mov bx, [map_even_ptr]
    xlat
    xor bx, bx
    mov bl, al
    mov dh, [pix_ib_tab + bx]  ; DH = IB(mapped p0)
    shl dh, 1
    shl dh, 1
    
    ; --- p1 again (x odd) ---
    pop bx
    push bx
    mov al, bh
    and al, 0x0F
    mov bx, [map_odd_ptr]
    xlat
    xor bx, bx
    mov bl, al
    mov al, [pix_ib_tab + bx]
    or dh, al
    shl dh, 1
    shl dh, 1
    
    ; --- p2 again (x even) ---
    pop bx
    push bx
    mov al, bl
    shr al, 1               ; shr al,4 split into 4x shr al,1 (8086-safe; CX=loop counter)
    shr al, 1
    shr al, 1
    shr al, 1
    mov bx, [map_even_ptr]
    xlat
    xor bx, bx
    mov bl, al
    mov al, [pix_ib_tab + bx]
    or dh, al
    shl dh, 1
    shl dh, 1
    
    ; --- p3 again (x odd) ---
    pop bx
    mov al, bl
    and al, 0x0F
    mov bx, [map_odd_ptr]
    xlat
    xor bx, bx
    mov bl, al
    mov al, [pix_ib_tab + bx]
    or dh, al               ; DH = extended plane byte [IB0,IB1,IB2,IB3]
    
    ; --- Write to offscreen buffer (same layout as Plantronics VRAM) ---
    ; DI = row offset, CX = loop counter (80 down to 1)
    ; col_index = 80 - CX  (0..79)
    push cx
    mov ax, 80
    sub ax, cx              ; AX = column byte index (0-79)

    mov bx, di
    add bx, ax              ; BX = row offset + col
    add bx, plan_backbuf    ; BX = buffer address for standard plane area
    mov [bx], dl            ; Write RG byte to buffer standard area
    add bx, VRAM_EXT_OFS    ; Extended plane area = standard + 0x4000
    mov [bx], dh            ; Write IB byte to buffer extended area

    pop cx

    dec cx
    jz .encode_done
    jmp .encode_loop
.encode_done:
%endif ; TANDY

.row_done:
    ; Move to previous BMP row (BMP is bottom-up)
    mov ax, [current_row]
    or ax, ax
    jz .decode_done
    dec ax
    mov [current_row], ax
    jmp .row_loop
    
.decode_done:
    pop ds
    pop es
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

%ifdef TANDY
msg_info    db 'TDY-BMP v1.1 - BMP Viewer (Tandy/PCjr DOSBox build)', 0x0D, 0x0A
            db 'Requires: DOSBox with machine=tandy', 0x0D, 0x0A
%else
msg_info    db 'PLAN-BMP v1.1 - BMP Image Viewer for Plantronics ColorPlus machines', 0x0D, 0x0A
            db 'Targets: Schneider EuroPC / EuroPC II, Amstrad PC1640 (sw5=ON)', 0x0D, 0x0A
%endif
            db 0x0D, 0x0A
            db 'Displays 320x200 BMP images in 16-color mode.', 0x0D, 0x0A
            db 'BMP must be: 4-bit (16 colors), 320x200, uncompressed.', 0x0D, 0x0A
            db 'Press Enter to toggle Sierra-style 2x2 checker dithering.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Usage: PLAN-BMP filename[.bmp]', 0x0D, 0x0A
            db '       PLAN-BMP /? or /h for this help', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'By RetroErik - 2026', 0x0D, 0x0A, '$'

msg_file_err db 'Error: Cannot open file', 0x0D, 0x0A, '$'
msg_not_bmp  db 'Error: Not a valid BMP file', 0x0D, 0x0A, '$'
msg_format   db 'Error: BMP must be 4-bit uncompressed', 0x0D, 0x0A, '$'
msg_size     db 'Error: BMP must be exactly 320x200', 0x0D, 0x0A, '$'

; Splash screen with ANSI color escape codes (ESC = 0x1B)
; ANSI: ESC[<attr>m  where 1=bold, 0=reset, 3x=fg color, 9x=bright fg
;   30=black 31=red 32=green 33=yellow 34=blue 35=magenta 36=cyan 37=white
msg_splash   db 0x1B, '[2J', 0x1B, '[H'
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                             '
             db 0x1B, '[1;36m'
             db 'BMP Images viewer for'
             db 0x1B, '[0m', 0x0D, 0x0A
             db '                             '
             db 0x1B, '[1;33m'
             db 'Plantronics and Tandy'
             db 0x1B, '[0m', 0x0D, 0x0A
             db '                        '
             db 0x1B, '[1;37m'
             db 'BMP: '
             db 0x1B, '[1;32m'
             db '320x200'
             db 0x1B, '[1;37m'
             db ', 4-bit (16 colors)'
             db 0x1B, '[0m', 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                                 '
             db 0x1B, '[1;35m'
             db 'RetroErik'
             db 0x1B, '[0m'
             db ' 2026', 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                                '
             db 0x1B, '[1;33m'
             db 'Loading Image...'
             db 0x1B, '[0m', 0x0D, 0x0A, '$'

filename_ptr        dw 0
file_handle         dw 0
filename_buf:       times 132 db 0
saved_video_mode    db 0
bytes_per_row       dw 0
current_row         dw 0
border_ctr          db 0    ; C64-style border cycling counter (0-15)
dither_enabled      db 0    ; 0=off, 1=Sierra-style 2x2 checkerboard on
tmp_b               db 0
tmp_g               db 0
tmp_r               db 0
tmp_max             db 0    ; max(B,G,R) of current BMP entry, for saturation-aware match
best_dist           dw 0
second_best_dist    dw 0
best_idx            db 0
second_idx          db 0
map_even_ptr        dw 0
map_odd_ptr         dw 0
pal_remap:          times 16 db 0
pal_remap_alt:      times 16 db 0
pal_dither_even:    times 16 db 0
pal_dither_odd:     times 16 db 0

; CGA RGBI palette in 6-bit B,G,R order (0..63). Used for nearest-color match.
; Values are the IBM CGA standard palette divided by 4 (>> 2) to fit 6 bits:
;   0..7  : non-intense (component values 0, 42=168/4, 21=84/4)
;   8..15 : intense    (component values 21, 42, 63)
; Brown (#6) uses (0,21,42) BGR == RGB(170,85,0) per IBM CGA spec — NOT
; (0,42,42) which would be olive/yellow.
cga_rgb6:
    db  0,  0,  0    ; 0  black
    db 42,  0,  0    ; 1  blue
    db  0, 42,  0    ; 2  green
    db 42, 42,  0    ; 3  cyan
    db  0,  0, 42    ; 4  red       (170,  0,  0)
    db 42,  0, 42    ; 5  magenta   (170,  0,170)
    db  0, 21, 42    ; 6  brown     (170, 85,  0)  -- CGA brown = R=170,G=85,B=0
    db 42, 42, 42    ; 7  light gray (170,170,170)
    db 21, 21, 21    ; 8  dark gray
    db 63, 21, 21    ; 9  light blue
    db 21, 63, 21    ; 10 light green
    db 63, 63, 21    ; 11 light cyan
    db 21, 21, 63    ; 12 light red
    db 63, 21, 63    ; 13 light magenta
    db 21, 63, 63    ; 14 yellow
    db 63, 63, 63    ; 15 white

; Per-anchor max(B,G,R) for the saturation/brightness term in the matcher.
; Indices match cga_rgb6 above.
cga_max6:
    db  0, 42, 42, 42, 42, 42, 42, 42
    db 21, 63, 63, 63, 63, 63, 63, 63

; ============================================================================
; Plantronics pixel encoding lookup tables
;
; For each CGA color index n (0-15, stored as IRGB nibble):
;
; pix_rg_tab[n] = RG plane bits = (n >> 1) & 3
;   Encodes the R (bit 2) and G (bit 1) components as a 2-bit value.
;
; pix_ib_tab[n] = IB plane bits = ((n >> 2) & 2) | (n & 1)
;   Encodes the I (bit 3) and B (bit 0) components as a 2-bit value.
;
; These match the foss_sci_drivers PCPLUS.DRV pix_fmt_lut encoding.
; ============================================================================

; pix_rg_tab: index = color nibble (0-15), value = 2-bit RG value (0-3)
; Plantronics plane0 pixel = (R << 1) | G   where R = bit2, G = bit1 of IRGB nibble
; Equivalent: RG = (n >> 1) & 3 — matches Sierra PCPLUS.DRV and verified on real
; EuroPC / PC1640 hardware (red BMP pixels render red, green renders green).
;   n= 0(0000)        -> 0   n= 1(0001 B   ) -> 0
;   n= 2(0010 G   )   -> 1   n= 3(0011 GB  ) -> 1
;   n= 4(0100 R   )   -> 2   n= 5(0101 RB  ) -> 2
;   n= 6(0110 RG  )   -> 3   n= 7(0111 RGB ) -> 3
;   n= 8..15: intensity bit ignored, same RG pattern as 0..7
pix_rg_tab:
    db 0,0,1,1, 2,2,3,3, 0,0,1,1, 2,2,3,3

; pix_ib_tab: index = color nibble (0-15), value = 2-bit IB value (0-3)
; Plantronics plane1 pixel = (B << 1) | I   where B = bit0, I = bit3 of IRGB nibble
; Verified on real EuroPC / PC1640 hardware via PLAN-16COLORS test.
;   n= 0(0000)        -> 0   n= 1(0001 B   ) -> 2
;   n= 2(0010 G   )   -> 0   n= 3(0011 GB  ) -> 2
;   n= 4(0100 R   )   -> 0   n= 5(0101 RB  ) -> 2
;   n= 6(0110 RG  )   -> 0   n= 7(0111 RGB ) -> 2
;   n= 8(1000 I   )   -> 1   n= 9(1001 IB  ) -> 3
;   n=10(1010 IG  )   -> 1   n=11(1011 IGB ) -> 3
;   n=12(1100 IR  )   -> 1   n=13(1101 IRB ) -> 3
;   n=14(1110 IRG )   -> 1   n=15(1111 IRGB) -> 3
pix_ib_tab:
    db 0,2,0,2, 0,2,0,2, 1,3,1,3, 1,3,1,3

%ifdef TANDY
; Offscreen decode buffer for instant reveal in mode 9
tandy_backbuf:   times 32768 db 0
%else
; Offscreen decode buffer for Plantronics build.
; Decoded here while text splash is shown, then blitted to VRAM in one shot.
plan_backbuf:    times 32768 db 0
%endif

; Reserve space for BMP header (file hdr + info hdr + palette)
bmp_header:     times 128 db 0
row_buffer:     times 164 db 0  ; 160 bytes + 4 padding safety
