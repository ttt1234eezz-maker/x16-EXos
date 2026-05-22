; ==================================================================
; x16-PRos -- PAINT. Very simple paint program.
; Tool modes: FREE / LINE / RECT
; Copyright (C) 2025-2026 PRoX2011
; ==================================================================

[BITS 16]
[ORG 0x8000]

; ==================================================================
; Canvas configuration (Fits standard Mode 13h: 320x200 256-color)
; ==================================================================
CANVAS_X        equ 0
CANVAS_Y        equ 20
CANVAS_W        equ 320
CANVAS_H        equ 160
CANVAS_RIGHT    equ CANVAS_X + CANVAS_W - 1
CANVAS_BOTTOM   equ CANVAS_Y + CANVAS_H - 1

MODE_FREE       equ 0
MODE_LINE       equ 1
MODE_RECT       equ 2
MODE_COL        equ 7

start:
    ; Switch to standard VGA Mode 13h (320x200, 256 colors)
    mov ax, 0x0013
    int 0x10

    ; Initialize application state variables
    mov byte [CurrentColor], 0x0F
    mov byte [BrushSize], 1
    mov byte [DrawMode], MODE_FREE
    mov byte [modified], 0
    mov byte [exit_after_save], 0
    mov byte [RectActive], 0
    mov byte [LineActive], 0

    call font_init

    ; Render UI scaffolding
    call draw_frame
    call draw_status

    call InitMouse
    call EnableMouse

; ==================================================================
; Main Input Poll Loop
; ==================================================================
main_loop:
    ; Check keystroke buffer status without blocking
    mov ah, 0x01
    int 0x16
    jz check_mouse

    ; Consume character from buffer
    mov ah, 0x00
    int 0x16

    ; Process Tab key to cycle through available modes
    cmp al, 0x09
    jne .keys
    inc byte [DrawMode]
    cmp byte [DrawMode], 3
    jb .ok
    mov byte [DrawMode], 0
.ok:
    call draw_status
    jmp main_loop

.keys:
    ; Palette color selection mapping (Keys '0'-'9')
    cmp al, '0'
    jb .other
    cmp al, '9'
    ja .other
    sub al, '0'
    mov bx, ColorTable
    xlatb
    mov [CurrentColor], al
    jmp main_loop

.other:
    ; Brush size modifiers (W=Increase, S=Decrease)
    cmp al, 'w'
    je inc_size
    cmp al, 'W'
    je inc_size
    cmp al, 's'
    je dec_size
    cmp al, 'S'
    je dec_size

    cmp al, 0x13          ; Ctrl+S keystroke catch
    jne .chk_esc
    call save_image
    jmp main_loop

.chk_esc:
    cmp al, 0x1B          ; Escape key processing
    je exit_paint
    jmp main_loop

inc_size:
    cmp byte [BrushSize], 9
    jae main_loop
    inc byte [BrushSize]
    jmp main_loop

dec_size:
    cmp byte [BrushSize], 1
    jbe main_loop
    dec byte [BrushSize]
    jmp main_loop

; ==================================================================
; Exit Routine with Dirty Bit Check
; ==================================================================
exit_paint:
    cmp byte [modified], 0
    je .exit_now

    ; Invoke UI confirmation dialog box
    mov ax, exit_q1
    mov bx, exit_q2
    xor cx, cx
    mov dx, 1
    call tui_dialog_box
    cmp ax, 0
    jne .exit_now

    mov byte [exit_after_save], 1
    call save_image

.exit_now:
    ; Restore text mode 80x25 to leave clean console state
    mov ax, 0x0003
    int 0x10
    ret

exit_q1 db 'Save this image before exit?', 0
exit_q2 db 'Unsaved changes will be lost.', 0

; ==================================================================
; Mouse Event Dispatcher
; ==================================================================
check_mouse:
    mov al, [ButtonStatus]
    test al, 1
    jz mouse_up

    ; Mouse button held down state
    cmp byte [DrawMode], MODE_FREE
    je free_paint
    cmp byte [DrawMode], MODE_LINE
    je line_down
    cmp byte [DrawMode], MODE_RECT
    je rect_drag
    jmp main_loop

mouse_up:
    ; Line commit processing
    cmp byte [LineActive], 1
    jne .chk_rect
    mov si, [LineX1]
    mov di, [LineY1]
    mov ax, [MouseX]
    mov bx, [MouseY]
    sub bx, 2
    call draw_line
    mov byte [LineActive], 0
    mov byte [modified], 1
    jmp main_loop

.chk_rect:
    ; Rectangle commit processing
    cmp byte [RectActive], 1
    jne main_loop
    call rect_erase_preview
    call rect_draw_final
    mov byte [RectActive], 0
    mov byte [modified], 1
    jmp main_loop

free_paint:
    mov cx, [MouseX]
    mov dx, [MouseY]
    sub dx, 2
    call plot_brush
    mov byte [modified], 1
    jmp main_loop

line_down:
    cmp byte [LineActive], 1
    je main_loop
    mov ax, [MouseX]
    mov [LineX1], ax
    mov ax, [MouseY]
    sub ax, 2
    mov [LineY1], ax
    mov byte [LineActive], 1
    jmp main_loop

rect_drag:
    cmp byte [RectActive], 1
    je rect_update
    mov ax, [MouseX]
    mov [RectX1], ax
    mov ax, [MouseY]
    sub ax, 2
    mov [RectY1], ax
    mov byte [RectActive], 1
    jmp main_loop

rect_update:
    call rect_erase_preview
    mov ax, [MouseX]
    mov [RectX2], ax
    mov ax, [MouseY]
    sub ax, 2
    mov [RectY2], ax
    call rect_draw_preview
    jmp main_loop

rect_draw_preview:
    pusha
    mov byte [XorMode], 1
    call rect_draw_outline
    mov byte [XorMode], 0
    popa
    ret

rect_erase_preview:
    pusha
    mov byte [XorMode], 1
    call rect_draw_outline
    mov byte [XorMode], 0
    popa
    ret

rect_draw_final:
    pusha
    mov byte [XorMode], 0
    call rect_draw_outline
    popa
    ret

; ==================================================================
; Robust 16-bit Bresenham Line Implementation
; Input parameters: SI=X1, DI=Y1, AX=X2, BX=Y2
; ==================================================================
draw_line:
    pusha
    
    ; Compute absolute Delta X and step direction
    mov cx, ax
    sub cx, si          ; CX = X2 - X1
    mov dx, 1           ; DX = X_step (positive default)
    jns .calc_dy
    neg cx              ; absolute value optimization
    mov dx, -1
.calc_dy:
    ; Compute absolute Delta Y and step direction
    mov bp, bx
    sub bp, di          ; BP = Y2 - Y1
    push dx             ; Preserve X_step on stack frame
    mov dx, 1           ; DX = Y_step (positive default)
    jns .init_algo
    neg bp              ; absolute value optimization
    mov dx, -1
.init_algo:
    push dx             ; Preserve Y_step on stack frame
    
    ; Setup decision variable (Error context)
    ; CX = dX, BP = dY
    mov ax, cx
    sub ax, bp          ; AX = error = dX - dY
    
.line_loop:
    pusha
    mov cx, si          ; Transfer coordinates to plotter
    mov dx, di
    call plot_brush
    popa

    ; Terminate condition check loop
    cmp si, [esp+6]     ; Verify matching target context registers
    jne .step_pixels
    cmp di, [esp+4]
    je .line_done

.step_pixels:
    mov bx, ax          ; BX = temporary error holder (e2)
    shl bx, 1           ; e2 * 2
    
    ; Process X step condition
    mov dx, bp
    neg dx              ; DX = -dY
    cmp bx, dx
    jle .check_y_step
    sub ax, bp          ; error -= dY
    add si, [esp+2]     ; X1 += X_step

.check_y_step:
    ; Process Y step condition
    cmp bx, cx
    jge .line_loop
    add ax, cx          ; error += dX
    add di, [esp]       ; Y1 += Y_step
    jmp .line_loop

.line_done:
    add esp, 4          ; Clear structural steps from parameters stack
    popa
    ret

; ==================================================================
; Rectangular Box Contour Plotter
; ==================================================================
rect_draw_outline:
    ; Top edge line segment
    mov si, [RectX1]
    mov di, [RectY1]
    mov ax, [RectX2]
    mov bx, [RectY1]
    call draw_line

    ; Bottom edge line segment
    mov si, [RectX1]
    mov di, [RectY2]
    mov ax, [RectX2]
    mov bx, [RectY2]
    call draw_line

    ; Left edge line segment
    mov si, [RectX1]
    mov di, [RectY1]
    mov ax, [RectX1]
    mov bx, [RectY2]
    call draw_line

    ; Right edge line segment
    mov si, [RectX2]
    mov di, [RectY1]
    mov ax, [RectX2]
    mov bx, [RectY2]
    call draw_line
    ret

; ==================================================================
; Safe Canvas-bounded Pixel Drawing
; ==================================================================
plot_brush:
    pusha
    
    ; Boundary clip validation guards
    cmp cx, CANVAS_X
    jl .skip
    cmp cx, CANVAS_RIGHT
    jg .skip
    cmp dx, CANVAS_Y
    jl .skip
    cmp dx, CANVAS_BOTTOM
    jg .skip

    ; Check if XOR preview mode is enabled
    cmp byte [XorMode], 1
    jne .standard_plot

    ; Read back current state to process color masking inversion
    mov ah, 0x0D
    int 0x10
    xor al, [CurrentColor]

.standard_plot:
    mov ah, 0x0C
    mov al, [CurrentColor]
    int 0x10
.skip:
    popa
    ret

; ==================================================================
; Bottom Status Bar Renderer
; ==================================================================
draw_status:
    pusha
    mov al, 0x07
    mov ch, 24          ; Bound UI positioning row context
    call font_fill_row
    
    mov si, status_text
    mov cl, 0
    mov ch, 24
    mov bl, 0x70
    call font_print_string
    
    mov si, mode_free_str
    cmp byte [DrawMode], MODE_LINE
    jne .chk
    mov si, mode_line_str
    jmp .show
.chk:
    cmp byte [DrawMode], MODE_RECT
    jne .show
    mov si, mode_rect_str
.show:
    mov cl, MODE_COL
    mov ch, 24
    mov bl, 0x4F
    call font_print_string
    popa
    ret

; ==================================================================
; Top Frame Container Boundary Wrapper
; ==================================================================
draw_frame:
    pusha
    ; Vertical canvas top header line divider split
    mov si, 0
    mov di, CANVAS_Y - 1
    mov ax, 319
    mov bx, CANVAS_Y - 1
    call draw_line
    popa
    ret

; ==================================================================
; Hardware Graphics Storage Writer Interface
; ==================================================================
save_image:
    call DisableMouse
    call HideCursor
    
    ; TODO: Insert actual disk storage serialization engine hook
    
    mov byte [modified], 0
    call EnableMouse
    ret

; ==================================================================
; Global Static App Data Definitions
; ==================================================================
CurrentColor    db 0
BrushSize       db 1
DrawMode        db 0
modified        db 0
exit_after_save db 0
XorMode         db 0

LineX1          dw 0
LineY1          dw 0
LineActive      db 0

RectX1          dw 0
RectY1          dw 0
RectX2          dw 0
RectY2          dw 0
RectActive      db 0

; 16-color legacy fallback direct index translation array
ColorTable      db 0x00, 0x0F, 0x01, 0x03, 0x02, 0x04, 0x05, 0x0E, 0x07, 0x08

welcome_msg     db 'EXos Paint | 1-9: Color | W,S: Size', 13, 10, 0
status_text     db ' Mode:       | TAB: Toggle | Ctrl+S: Save | ESC: Exit', 0
mode_free_str   db 'FREE', 0
mode_line_str   db 'LINE', 0
mode_rect_str   db 'RECT', 0

save_prompt     db 'Save as (e.g. PAINT.BMP):', 0
save_filename_buf times 17 db 0

%include "programs/lib/font.inc"
%include "programs/lib/tui.inc"
section .text
%include "src/drivers/ps2_mouse.asm"
