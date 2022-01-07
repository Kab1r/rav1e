; Copyright © 2021-2022, VideoLAN and dav1d authors
; Copyright © 2021-2022, Two Orioles, LLC
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions are met:
;
; 1. Redistributions of source code must retain the above copyright notice, this
;    list of conditions and the following disclaimer.
;
; 2. Redistributions in binary form must reproduce the above copyright notice,
;    this list of conditions and the following disclaimer in the documentation
;    and/or other materials provided with the distribution.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
; ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
; DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
; ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
; (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
; ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%include "config.asm"
%include "ext/x86/x86inc.asm"

%if ARCH_X86_64

SECTION_RODATA 32
pb_mask: db 0, 0x80, 0x80, 0, 0x80, 0, 0, 0x80, 0x80, 0, 0, 0x80, 0, 0x80, 0x80, 0
gen_shufA:     db  0,  1,  2,  3,  2,  3,  4,  5,  4,  5,  6,  7,  6,  7,  8,  9
gen_shufB:     db  4,  5,  6,  7,  6,  7,  8,  9,  8,  9, 10, 11, 10, 11, 12, 13
rnd_next_upperbit_mask: dw 0x100B, 0x2016, 0x402C, 0x8058
pw_seed_xor:   times 2 dw 0xb524
               times 2 dw 0x49d8
gen_ar0_shift: times 4 db 128
               times 4 db 64
               times 4 db 32
               times 4 db 16
pd_16: dd 16
pb_1: times 4 db 1
hmul_bits: dw 32768, 16384, 8192, 4096
round: dw 2048, 1024, 512
mul_bits: dw 256, 128, 64, 32, 16
round_vals: dw 32, 64, 128, 256, 512, 1024
max: dw 256*4-1, 240*4, 235*4, 256*16-1, 240*16, 235*16
min: dw 0, 16*4, 16*16
pw_27_17_17_27: dw 27, 17, 17, 27
; these two should be next to each other
pw_4: times 2 dw 4
pw_16: times 2 dw 16
pw_23_22: dw 23, 22, 0, 32

%macro JMP_TABLE 1-*
    %xdefine %1_table %%table
    %xdefine %%base %1_table
    %xdefine %%prefix mangle(private_prefix %+ _%1)
    %%table:
    %rep %0 - 1
        dd %%prefix %+ .ar%2 - %%base
        %rotate 1
    %endrep
%endmacro

JMP_TABLE generate_grain_y_16bpc_avx2, 0, 1, 2, 3
JMP_TABLE generate_grain_uv_420_16bpc_avx2, 0, 1, 2, 3
JMP_TABLE generate_grain_uv_422_16bpc_avx2, 0, 1, 2, 3
JMP_TABLE generate_grain_uv_444_16bpc_avx2, 0, 1, 2, 3

struc FGData
    .seed:                      resd 1
    .num_y_points:              resd 1
    .y_points:                  resb 14 * 2
    .chroma_scaling_from_luma:  resd 1
    .num_uv_points:             resd 2
    .uv_points:                 resb 2 * 10 * 2
    .scaling_shift:             resd 1
    .ar_coeff_lag:              resd 1
    .ar_coeffs_y:               resb 24
    .ar_coeffs_uv:              resb 2 * 28 ; includes padding
    .ar_coeff_shift:            resq 1
    .grain_scale_shift:         resd 1
    .uv_mult:                   resd 2
    .uv_luma_mult:              resd 2
    .uv_offset:                 resd 2
    .overlap_flag:              resd 1
    .clip_to_restricted_range:  resd 1
endstruc

cextern gaussian_sequence

SECTION .text

%macro REPX 2-*
    %xdefine %%f(x) %1
%rep %0 - 1
    %rotate 1
    %%f(%1)
%endrep
%endmacro

%define m(x) mangle(private_prefix %+ _ %+ x %+ SUFFIX)

INIT_YMM avx2
cglobal generate_grain_y_16bpc, 3, 9, 14, buf, fg_data, bdmax
%define base r4-generate_grain_y_16bpc_avx2_table
    lea              r4, [generate_grain_y_16bpc_avx2_table]
    vpbroadcastw    xm0, [fg_dataq+FGData.seed]
    mov             r6d, [fg_dataq+FGData.grain_scale_shift]
    movq            xm1, [base+rnd_next_upperbit_mask]
    mov              r3, -73*82*2
    movsxd           r5, [fg_dataq+FGData.ar_coeff_lag]
    lea             r7d, [bdmaxq+1]
    movq            xm4, [base+mul_bits]
    shr             r7d, 11             ; 0 for 10bpc, 2 for 12bpc
    movq            xm5, [base+hmul_bits]
    sub              r6, r7
    mova            xm6, [base+pb_mask]
    sub            bufq, r3
    vpbroadcastw    xm7, [base+round+r6*2-2]
    lea              r6, [gaussian_sequence]
    movsxd           r5, [r4+r5*4]
.loop:
    pand            xm2, xm0, xm1
    psrlw           xm3, xm2, 10
    por             xm2, xm3            ; bits 0xf, 0x1e, 0x3c and 0x78 are set
    pmullw          xm2, xm4            ; bits 0x0f00 are set
    pmulhuw         xm0, xm5
    pshufb          xm3, xm6, xm2       ; set 15th bit for next 4 seeds
    psllq           xm2, xm3, 30
    por             xm2, xm3
    psllq           xm3, xm2, 15
    por             xm2, xm0            ; aggregate each bit into next seed's high bit
    por             xm3, xm2            ; 4 next output seeds
    pshuflw         xm0, xm3, q3333
    psrlw           xm3, 5
    pand            xm2, xm0, xm1
    movq             r7, xm3
    psrlw           xm3, xm2, 10
    por             xm2, xm3
    pmullw          xm2, xm4
    pmulhuw         xm0, xm5
    movzx           r8d, r7w
    pshufb          xm3, xm6, xm2
    psllq           xm2, xm3, 30
    por             xm2, xm3
    psllq           xm3, xm2, 15
    por             xm0, xm2
    movd            xm2, [r6+r8*2]
    rorx             r8, r7, 32
    por             xm3, xm0
    shr             r7d, 16
    pinsrw          xm2, [r6+r7*2], 1
    pshuflw         xm0, xm3, q3333
    movzx           r7d, r8w
    psrlw           xm3, 5
    pinsrw          xm2, [r6+r7*2], 2
    shr             r8d, 16
    movq             r7, xm3
    pinsrw          xm2, [r6+r8*2], 3
    movzx           r8d, r7w
    pinsrw          xm2, [r6+r8*2], 4
    rorx             r8, r7, 32
    shr             r7d, 16
    pinsrw          xm2, [r6+r7*2], 5
    movzx           r7d, r8w
    pinsrw          xm2, [r6+r7*2], 6
    shr             r8d, 16
    pinsrw          xm2, [r6+r8*2], 7
    paddw           xm2, xm2            ; otherwise bpc=12 w/ grain_scale_shift=0
    pmulhrsw        xm2, xm7            ; shifts by 0, which pmulhrsw does not support
    mova      [bufq+r3], xm2
    add              r3, 8*2
    jl .loop

    ; auto-regression code
    add              r5, r4
    jmp              r5

.ar1:
    DEFINE_ARGS buf, fg_data, max, shift, val3, min, cf3, x, val0
    mov          shiftd, [fg_dataq+FGData.ar_coeff_shift]
    movsx          cf3d, byte [fg_dataq+FGData.ar_coeffs_y+3]
    movd            xm4, [fg_dataq+FGData.ar_coeffs_y]
    DEFINE_ARGS buf, h, max, shift, val3, min, cf3, x, val0
    pinsrb          xm4, [base+pb_1], 3
    pmovsxbw        xm4, xm4
    pshufd          xm5, xm4, q1111
    pshufd          xm4, xm4, q0000
    vpbroadcastw    xm3, [base+round_vals+shiftq*2-12]    ; rnd
    sub            bufq, 2*(82*73-(82*3+79))
    mov              hd, 70
    sar            maxd, 1
    mov            mind, maxd
    xor            mind, -1
.y_loop_ar1:
    mov              xq, -76
    movsx         val3d, word [bufq+xq*2-2]
.x_loop_ar1:
    movu            xm0, [bufq+xq*2-82*2-2]     ; top/left
    psrldq          xm2, xm0, 2                 ; top
    psrldq          xm1, xm0, 4                 ; top/right
    punpcklwd       xm0, xm2
    punpcklwd       xm1, xm3
    pmaddwd         xm0, xm4
    pmaddwd         xm1, xm5
    paddd           xm0, xm1
.x_loop_ar1_inner:
    movd          val0d, xm0
    psrldq          xm0, 4
    imul          val3d, cf3d
    add           val3d, val0d
    sarx          val3d, val3d, shiftd
    movsx         val0d, word [bufq+xq*2]
    add           val3d, val0d
    cmp           val3d, maxd
    cmovg         val3d, maxd
    cmp           val3d, mind
    cmovl         val3d, mind
    mov word [bufq+xq*2], val3w
    ; keep val3d in-place as left for next x iteration
    inc              xq
    jz .x_loop_ar1_end
    test             xb, 3
    jnz .x_loop_ar1_inner
    jmp .x_loop_ar1
.x_loop_ar1_end:
    add            bufq, 82*2
    dec              hd
    jg .y_loop_ar1
.ar0:
    RET

.ar2:
    DEFINE_ARGS buf, fg_data, bdmax, shift
    mov          shiftd, [fg_dataq+FGData.ar_coeff_shift]
    movq            xm0, [fg_dataq+FGData.ar_coeffs_y+5]    ; cf5-11
    vinserti128      m0, [fg_dataq+FGData.ar_coeffs_y+0], 1 ; cf0-4
    vpbroadcastw   xm10, [base+round_vals-12+shiftq*2]
    pxor             m1, m1
    punpcklwd      xm10, xm1
    pcmpgtb          m1, m0
    punpcklbw        m0, m1                                 ; cf5-11,0-4
    vpermq           m1, m0, q3333                          ; cf4
    vbroadcasti128  m11, [base+gen_shufA]
    pshufd           m6, m0, q0000                          ; cf[5,6], cf[0-1]
    vbroadcasti128  m12, [base+gen_shufB]
    pshufd           m7, m0, q1111                          ; cf[7,8], cf[2-3]
    punpckhwd       xm1, xm0
    pshufhw         xm9, xm0, q2121
    pshufd          xm8, xm1, q0000                         ; cf[4,9]
    sar          bdmaxd, 1
    punpckhqdq      xm9, xm9                                ; cf[10,11]
    movd            xm4, bdmaxd                             ; max_grain
    pcmpeqd         xm5, xm5
    sub            bufq, 2*(82*73-(82*3+79))
    pxor            xm5, xm4                                ; min_grain
    DEFINE_ARGS buf, fg_data, h, x
    mov              hd, 70
.y_loop_ar2:
    mov              xq, -76
.x_loop_ar2:
    vbroadcasti128   m2, [bufq+xq*2-82*4-4]        ; y=-2,x=[-2,+5]
    vinserti128      m1, m2, [bufq+xq*2-82*2-4], 0 ; y=-1,x=[-2,+5]
    pshufb           m0, m1, m11                   ; y=-1/-2,x=[-2/-1,-1/+0,+0/+1,+1/+2]
    pmaddwd          m0, m6
    punpckhwd       xm2, xm1                       ; y=-2/-1 interleaved, x=[+2,+5]
    pshufb           m1, m12                       ; y=-1/-2,x=[+0/+1,+1/+2,+2/+3,+3/+4]
    pmaddwd          m1, m7
    pmaddwd         xm2, xm8
    paddd            m0, m1
    vextracti128    xm1, m0, 1
    paddd           xm0, xm10
    paddd           xm2, xm0
    movu            xm0, [bufq+xq*2-4]      ; y=0,x=[-2,+5]
    paddd           xm2, xm1
    pmovsxwd        xm1, [bufq+xq*2]        ; in dwords, y=0,x=[0,3]
.x_loop_ar2_inner:
    pmaddwd         xm3, xm9, xm0
    psrldq          xm0, 2
    paddd           xm3, xm2
    psrldq          xm2, 4                  ; shift top to next pixel
    psrad           xm3, [fg_dataq+FGData.ar_coeff_shift]
    ; skip packssdw because we only care about one value
    paddd           xm3, xm1
    pminsd          xm3, xm4
    psrldq          xm1, 4
    pmaxsd          xm3, xm5
    pextrw  [bufq+xq*2], xm3, 0
    punpcklwd       xm3, xm3
    pblendw         xm0, xm3, 0010b
    inc              xq
    jz .x_loop_ar2_end
    test             xb, 3
    jnz .x_loop_ar2_inner
    jmp .x_loop_ar2
.x_loop_ar2_end:
    add            bufq, 82*2
    dec              hd
    jg .y_loop_ar2
    RET

.ar3:
    DEFINE_ARGS buf, fg_data, bdmax, shift
    mov          shiftd, [fg_dataq+FGData.ar_coeff_shift]
    sar          bdmaxd, 1
    movq            xm7, [fg_dataq+FGData.ar_coeffs_y+ 0]    ; cf0-6
    movd            xm0, [fg_dataq+FGData.ar_coeffs_y+14]    ; cf14-16
    pinsrb          xm7, [fg_dataq+FGData.ar_coeffs_y+13], 7 ; cf0-6,13
    pinsrb          xm0, [base+pb_1], 3                      ; cf14-16,pb_1
    movd            xm1, [fg_dataq+FGData.ar_coeffs_y+21]    ; cf21-23
    vinserti128      m7, [fg_dataq+FGData.ar_coeffs_y+ 7], 1 ; cf7-13
    vinserti128      m0, [fg_dataq+FGData.ar_coeffs_y+17], 1 ; cf17-20
    vpbroadcastw   xm11, [base+round_vals+shiftq*2-12]
    movd           xm12, bdmaxd                              ; max_grain
    punpcklbw        m7, m7                                  ; sign-extension
    punpcklbw        m0, m0                                  ; sign-extension
    punpcklbw       xm1, xm1
    REPX   {psraw x, 8}, m7, m0, xm1
    pshufd           m4, m7, q0000                           ; cf[0,1] | cf[7,8]
    pshufd           m5, m7, q1111                           ; cf[2,3] | cf[9,10]
    pshufd           m6, m7, q2222                           ; cf[4,5] | cf[11,12]
    pshufd          xm7, xm7, q3333                          ; cf[6,13]
    pshufd           m8, m0, q0000                           ; cf[14,15] | cf[17,18]
    pshufd           m9, m0, q1111                           ; cf[16],pw_1 | cf[19,20]
    paddw           xm0, xm11, xm11
    pcmpeqd        xm13, xm13
    pblendw        xm10, xm1, xm0, 00001000b
    pxor           xm13, xm12                                ; min_grain
    DEFINE_ARGS buf, fg_data, h, x
    sub            bufq, 2*(82*73-(82*3+79))
    mov              hd, 70
.y_loop_ar3:
    mov              xq, -76
.x_loop_ar3:
    movu            xm0, [bufq+xq*2-82*6-6+ 0]      ; y=-3,x=[-3,+4]
    vinserti128      m0, [bufq+xq*2-82*4-6+ 0], 1   ; y=-3/-2,x=[-3,+4]
    movq            xm1, [bufq+xq*2-82*6-6+16]      ; y=-3,x=[+5,+8]
    vinserti128      m1, [bufq+xq*2-82*4-6+16], 1   ; y=-3/-2,x=[+5,+12]
    palignr          m3, m1, m0, 2                  ; y=-3/-2,x=[-2,+5]
    palignr          m1, m0, 12                     ; y=-3/-2,x=[+3,+6]
    punpckhwd        m2, m0, m3                     ; y=-3/-2,x=[+1/+2,+2/+3,+3/+4,+4/+5]
    punpcklwd        m0, m3                         ; y=-3/-2,x=[-3/-2,-2/-1,-1/+0,+0/+1]
    shufps           m3, m0, m2, q1032              ; y=-3/-2,x=[-1/+0,+0/+1,+1/+2,+2/+3]
    pmaddwd          m0, m4
    pmaddwd          m2, m6
    pmaddwd          m3, m5
    paddd            m0, m2
    movu            xm2, [bufq+xq*2-82*2-6+ 0]      ; y=-1,x=[-3,+4]
    vinserti128      m2, [bufq+xq*2-82*2-6+ 6], 1   ; y=-1,x=[+1,+8]
    paddd            m0, m3
    psrldq           m3, m2, 2
    punpcklwd        m3, m2, m3                     ; y=-1,x=[-3/-2,-2/-1,-1/+0,+0/+1]
    pmaddwd          m3, m8                         ;      x=[+0/+1,+1/+2,+2/+3,+3/+4]
    paddd            m0, m3
    psrldq           m3, m2, 4
    psrldq           m2, 6
    vpblendd         m2, m11, 0x0f                  ; rounding constant
    punpcklwd        m3, m2                         ; y=-1,x=[-1/rnd,+0/rnd,+1/rnd,+2/rnd]
    pmaddwd          m3, m9                         ;      x=[+2/+3,+3/+4,+4/+5,+5,+6]
    vextracti128    xm2, m1, 1
    punpcklwd       xm1, xm2
    pmaddwd         xm1, xm7                        ; y=-3/-2 interleaved,x=[+3,+4,+5,+6]
    paddd            m0, m3
    vextracti128    xm2, m0, 1
    paddd           xm0, xm1
    movu            xm1, [bufq+xq*2-6]        ; y=0,x=[-3,+4]
    paddd           xm0, xm2
.x_loop_ar3_inner:
    pmaddwd         xm2, xm1, xm10
    pshuflw         xm3, xm2, q1032
    paddd           xm2, xm0                ; add top
    paddd           xm2, xm3                ; left+cur
    psrldq          xm0, 4
    psrad           xm2, [fg_dataq+FGData.ar_coeff_shift]
    ; skip packssdw because we only care about one value
    pminsd          xm2, xm12
    pmaxsd          xm2, xm13
    pextrw  [bufq+xq*2], xm2, 0
    pslldq          xm2, 4
    psrldq          xm1, 2
    pblendw         xm1, xm2, 0100b
    inc              xq
    jz .x_loop_ar3_end
    test             xb, 3
    jnz .x_loop_ar3_inner
    jmp .x_loop_ar3
.x_loop_ar3_end:
    add            bufq, 82*2
    dec              hd
    jg .y_loop_ar3
    RET

%macro generate_grain_uv_fn 3 ; ss_name, ss_x, ss_y
INIT_XMM avx2
cglobal generate_grain_uv_%1_16bpc, 4, 11, 8, buf, bufy, fg_data, uv, bdmax
%define base r8-generate_grain_uv_%1_16bpc_avx2_table
    lea              r8, [generate_grain_uv_%1_16bpc_avx2_table]
    movifnidn    bdmaxd, bdmaxm
    vpbroadcastw    xm0, [fg_dataq+FGData.seed]
    mov             r5d, [fg_dataq+FGData.grain_scale_shift]
    movq            xm1, [base+rnd_next_upperbit_mask]
    lea             r6d, [bdmaxq+1]
    movq            xm4, [base+mul_bits]
    shr             r6d, 11             ; 0 for 10bpc, 2 for 12bpc
    movq            xm5, [base+hmul_bits]
    sub              r5, r6
    mova            xm6, [base+pb_mask]
    vpbroadcastd    xm2, [base+pw_seed_xor+uvq*4]
    vpbroadcastw    xm7, [base+round+r5*2-2]
    pxor            xm0, xm2
    lea              r6, [gaussian_sequence]
%if %2
    mov             r7d, 73-35*%3
    add            bufq, 44*2
.loop_y:
    mov              r5, -44*2
%else
    mov              r5, -82*73*2
    sub            bufq, r5
%endif
.loop_x:
    pand            xm2, xm0, xm1
    psrlw           xm3, xm2, 10
    por             xm2, xm3            ; bits 0xf, 0x1e, 0x3c and 0x78 are set
    pmullw          xm2, xm4            ; bits 0x0f00 are set
    pmulhuw         xm0, xm5
    pshufb          xm3, xm6, xm2       ; set 15th bit for next 4 seeds
    psllq           xm2, xm3, 30
    por             xm2, xm3
    psllq           xm3, xm2, 15
    por             xm2, xm0            ; aggregate each bit into next seed's high bit
    por             xm2, xm3            ; 4 next output seeds
    pshuflw         xm0, xm2, q3333
    psrlw           xm2, 5
    movq            r10, xm2
    movzx           r9d, r10w
    movd            xm2, [r6+r9*2]
    rorx             r9, r10, 32
    shr            r10d, 16
    pinsrw          xm2, [r6+r10*2], 1
    movzx          r10d, r9w
    pinsrw          xm2, [r6+r10*2], 2
    shr             r9d, 16
    pinsrw          xm2, [r6+r9*2], 3
    paddw           xm2, xm2            ; otherwise bpc=12 w/ grain_scale_shift=0
    pmulhrsw        xm2, xm7            ; shifts by 0, which pmulhrsw does not support
    movq      [bufq+r5], xm2
    add              r5, 8
    jl .loop_x
%if %2
    add            bufq, 82*2
    dec             r7d
    jg .loop_y
%endif

    ; auto-regression code
    movsxd           r6, [fg_dataq+FGData.ar_coeff_lag]
    movsxd           r6, [r8+r6*4]
    add              r6, r8
    jmp              r6

INIT_YMM avx2
.ar0:
    DEFINE_ARGS buf, bufy, fg_data, uv, bdmax, shift
    imul            uvd, 28
    mov          shiftd, [fg_dataq+FGData.ar_coeff_shift]
    vpbroadcastb     m0, [fg_dataq+FGData.ar_coeffs_uv+uvq]
    sar          bdmaxd, 1
    vpbroadcastd     m4, [base+gen_ar0_shift-24+shiftq*4]
    movd            xm6, bdmaxd
    pcmpeqw          m7, m7
    pmaddubsw        m4, m0  ; ar_coeff << (14 - shift)
    vpbroadcastw     m6, xm6 ; max_gain
    pxor             m7, m6  ; min_grain
    DEFINE_ARGS buf, bufy, h, x
%if %2
    vpbroadcastw     m5, [base+hmul_bits+2+%3*2]
    sub            bufq, 2*(82*(73-35*%3)+82-(82*3+41))
%else
    sub            bufq, 2*(82*70-3)
%endif
    add           bufyq, 2*(3+82*3)
    mov              hd, 70-35*%3
.y_loop_ar0:
%if %2
    ; first 32 pixels
    movu            xm0, [bufyq+16*0]
    vinserti128      m0, [bufyq+16*2], 1
    movu            xm1, [bufyq+16*1]
    vinserti128      m1, [bufyq+16*3], 1
%if %3
    movu            xm2, [bufyq+82*2+16*0]
    vinserti128      m2, [bufyq+82*2+16*2], 1
    movu            xm3, [bufyq+82*2+16*1]
    vinserti128      m3, [bufyq+82*2+16*3], 1
    paddw            m0, m2
    paddw            m1, m3
%endif
    phaddw           m0, m1
    movu            xm1, [bufyq+16*4]
    vinserti128      m1, [bufyq+16*6], 1
    movu            xm2, [bufyq+16*5]
    vinserti128      m2, [bufyq+16*7], 1
%if %3
    movu            xm3, [bufyq+82*2+16*4]
    vinserti128      m3, [bufyq+82*2+16*6], 1
    paddw            m1, m3
    movu            xm3, [bufyq+82*2+16*5]
    vinserti128      m3, [bufyq+82*2+16*7], 1
    paddw            m2, m3
%endif
    phaddw           m1, m2
    pmulhrsw         m0, m5
    pmulhrsw         m1, m5
%else
    xor              xd, xd
.x_loop_ar0:
    movu             m0, [bufyq+xq*2]
    movu             m1, [bufyq+xq*2+32]
%endif
    paddw            m0, m0
    paddw            m1, m1
    pmulhrsw         m0, m4
    pmulhrsw         m1, m4
%if %2
    paddw            m0, [bufq+ 0]
    paddw            m1, [bufq+32]
%else
    paddw            m0, [bufq+xq*2+ 0]
    paddw            m1, [bufq+xq*2+32]
%endif
    pminsw           m0, m6
    pminsw           m1, m6
    pmaxsw           m0, m7
    pmaxsw           m1, m7
%if %2
    movu      [bufq+ 0], m0
    movu      [bufq+32], m1

    ; last 6 pixels
    movu            xm0, [bufyq+32*4]
    movu            xm1, [bufyq+32*4+16]
%if %3
    paddw           xm0, [bufyq+32*4+82*2]
    paddw           xm1, [bufyq+32*4+82*2+16]
%endif
    phaddw          xm0, xm1
    movu            xm1, [bufq+32*2]
    pmulhrsw        xm0, xm5
    paddw           xm0, xm0
    pmulhrsw        xm0, xm4
    paddw           xm0, xm1
    pminsw          xm0, xm6
    pmaxsw          xm0, xm7
    vpblendd        xm0, xm1, 0x08
    movu    [bufq+32*2], xm0
%else
    movu [bufq+xq*2+ 0], m0
    movu [bufq+xq*2+32], m1
    add              xd, 32
    cmp              xd, 64
    jl .x_loop_ar0

    ; last 12 pixels
    movu             m0, [bufyq+64*2]
    movu             m1, [bufq+64*2]
    paddw            m0, m0
    pmulhrsw         m0, m4
    paddw            m0, m1
    pminsw           m0, m6
    pmaxsw           m0, m7
    vpblendd         m0, m1, 0xc0
    movu    [bufq+64*2], m0
%endif
    add            bufq, 82*2
    add           bufyq, 82*2<<%3
    dec              hd
    jg .y_loop_ar0
    RET

INIT_XMM avx2
.ar1:
    DEFINE_ARGS buf, bufy, fg_data, uv, max, cf3, min, val3, x, shift
    imul            uvd, 28
    mov          shiftd, [fg_dataq+FGData.ar_coeff_shift]
    movsx          cf3d, byte [fg_dataq+FGData.ar_coeffs_uv+uvq+3]
    movd            xm4, [fg_dataq+FGData.ar_coeffs_uv+uvq]
    pinsrb          xm4, [fg_dataq+FGData.ar_coeffs_uv+uvq+4], 3
    DEFINE_ARGS buf, bufy, h, val0, max, cf3, min, val3, x, shift
    pmovsxbw        xm4, xm4
    pshufd          xm5, xm4, q1111
    pshufd          xm4, xm4, q0000
    pmovsxwd        xm3, [base+round_vals+shiftq*2-12]    ; rnd
    vpbroadcastw    xm6, [base+hmul_bits+2+%3*2]
    vpbroadcastd    xm3, xm3
%if %2
    sub            bufq, 2*(82*(73-35*%3)+44-(82*3+41))
%else
    sub            bufq, 2*(82*69+3)
%endif
    add           bufyq, 2*(79+82*3)
    mov              hd, 70-35*%3
    sar            maxd, 1
    mov            mind, maxd
    xor            mind, -1
.y_loop_ar1:
    mov              xq, -(76>>%2)
    movsx         val3d, word [bufq+xq*2-2]
.x_loop_ar1:
    movu            xm0, [bufq+xq*2-82*2-2] ; top/left
%if %2
    movu            xm2, [bufyq+xq*4]
%else
    movq            xm2, [bufyq+xq*2]
%endif
%if %2
%if %3
    phaddw          xm2, [bufyq+xq*4+82*2]
    punpckhqdq      xm1, xm2, xm2
    paddw           xm2, xm1
%else
    phaddw          xm2, xm2
%endif
    pmulhrsw        xm2, xm6
%endif
    psrldq          xm1, xm0, 4             ; top/right
    punpcklwd       xm1, xm2
    psrldq          xm2, xm0, 2             ; top
    punpcklwd       xm0, xm2
    pmaddwd         xm1, xm5
    pmaddwd         xm0, xm4
    paddd           xm1, xm3
    paddd           xm0, xm1
.x_loop_ar1_inner:
    movd          val0d, xm0
    psrldq          xm0, 4
    imul          val3d, cf3d
    add           val3d, val0d
    sarx          val3d, val3d, shiftd
    movsx         val0d, word [bufq+xq*2]
    add           val3d, val0d
    cmp           val3d, maxd
    cmovg         val3d, maxd
    cmp           val3d, mind
    cmovl         val3d, mind
    mov word [bufq+xq*2], val3w
    ; keep val3d in-place as left for next x iteration
    inc              xq
    jz .x_loop_ar1_end
    test             xb, 3
    jnz .x_loop_ar1_inner
    jmp .x_loop_ar1
.x_loop_ar1_end:
    add            bufq, 82*2
    add           bufyq, 82*2<<%3
    dec              hd
    jg .y_loop_ar1
    RET

INIT_YMM avx2
.ar2:
%if WIN64
    ; xmm6 and xmm7 already saved
    %assign xmm_regs_used 13 + %2
    %assign stack_size_padded 136
    SUB             rsp, stack_size_padded
    movaps   [rsp+16*2], xmm8
    movaps   [rsp+16*3], xmm9
    movaps   [rsp+16*4], xmm10
    movaps   [rsp+16*5], xmm11
    movaps   [rsp+16*6], xmm12
%if %2
    movaps   [rsp+16*7], xmm13
%endif
%endif
    DEFINE_ARGS buf, bufy, fg_data, uv, bdmax, shift
    mov          shiftd, [fg_dataq+FGData.ar_coeff_shift]
    imul            uvd, 28
    vbroadcasti128  m10, [base+gen_shufA]
    sar          bdmaxd, 1
    vbroadcasti128  m11, [base+gen_shufB]
    movd            xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+ 5]
    pinsrb          xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+12], 4
    pinsrb          xm7, [base+pb_1], 5
    pinsrw          xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+10], 3
    movhps          xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+ 0]
    pinsrb          xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+ 9], 13
    pmovsxbw         m7, xm7
    movd            xm8, bdmaxd             ; max_grain
    pshufd           m4, m7, q0000
    vpbroadcastw   xm12, [base+round_vals-12+shiftq*2]
    pshufd           m5, m7, q1111
    pcmpeqd         xm9, xm9
    pshufd           m6, m7, q2222
    pxor            xm9, xm8                ; min_grain
    pshufd          xm7, xm7, q3333
    DEFINE_ARGS buf, bufy, fg_data, h, x
%if %2
    vpbroadcastw   xm13, [base+hmul_bits+2+%3*2]
    sub            bufq, 2*(82*(73-35*%3)+44-(82*3+41))
%else
    sub            bufq, 2*(82*69+3)
%endif
    add           bufyq, 2*(79+82*3)
    mov              hd, 70-35*%3
.y_loop_ar2:
    mov              xq, -(76>>%2)
.x_loop_ar2:
    vbroadcasti128   m3, [bufq+xq*2-82*2-4]        ; y=-1,x=[-2,+5]
    vinserti128      m2, m3, [bufq+xq*2-82*4-4], 1 ; y=-2,x=[-2,+5]
    pshufb           m0, m2, m10                   ; y=-1/-2,x=[-2/-1,-1/+0,+0/+1,+1/+2]
    pmaddwd          m0, m4
    pshufb           m1, m2, m11                   ; y=-1/-2,x=[+0/+1,+1/+2,+2/+3,+3/+4]
    pmaddwd          m1, m5
    punpckhwd        m2, m3                        ; y=-2/-1 interleaved, x=[+2,+5]
%if %2
    movu            xm3, [bufyq+xq*4]
%if %3
    paddw           xm3, [bufyq+xq*4+82*2]
%endif
    phaddw          xm3, xm3
    pmulhrsw        xm3, xm13
%else
    movq            xm3, [bufyq+xq*2]
%endif
    punpcklwd       xm3, xm12                   ; luma, round interleaved
    vpblendd         m2, m3, 0x0f
    pmaddwd          m2, m6
    paddd            m1, m0
    movu            xm0, [bufq+xq*2-4]      ; y=0,x=[-2,+5]
    paddd            m2, m1
    vextracti128    xm1, m2, 1
    paddd           xm2, xm1
    pshufd          xm1, xm0, q3321
    pmovsxwd        xm1, xm1                ; y=0,x=[0,3] in dword
.x_loop_ar2_inner:
    pmaddwd         xm3, xm7, xm0
    paddd           xm3, xm2
    psrldq          xm2, 4                  ; shift top to next pixel
    psrad           xm3, [fg_dataq+FGData.ar_coeff_shift]
    ; we do not need to packssdw since we only care about one value
    paddd           xm3, xm1
    psrldq          xm1, 4
    pminsd          xm3, xm8
    pmaxsd          xm3, xm9
    pextrw  [bufq+xq*2], xm3, 0
    psrldq          xm0, 2
    pslldq          xm3, 2
    pblendw         xm0, xm3, 00000010b
    inc              xq
    jz .x_loop_ar2_end
    test             xb, 3
    jnz .x_loop_ar2_inner
    jmp .x_loop_ar2
.x_loop_ar2_end:
    add            bufq, 82*2
    add           bufyq, 82*2<<%3
    dec              hd
    jg .y_loop_ar2
    RET

.ar3:
%if WIN64
    ; xmm6 and xmm7 already saved
    %assign stack_offset 32
    %assign xmm_regs_used 14 + %2
    %assign stack_size_padded 152
    SUB             rsp, stack_size_padded
    movaps   [rsp+16*2], xmm8
    movaps   [rsp+16*3], xmm9
    movaps   [rsp+16*4], xmm10
    movaps   [rsp+16*5], xmm11
    movaps   [rsp+16*6], xmm12
    movaps   [rsp+16*7], xmm13
%if %2
    movaps   [rsp+16*8], xmm14
%endif
%endif
    DEFINE_ARGS buf, bufy, fg_data, uv, bdmax, shift
    mov          shiftd, [fg_dataq+FGData.ar_coeff_shift]
    imul            uvd, 28
    vpbroadcastw   xm11, [base+round_vals-12+shiftq*2]
    sar          bdmaxd, 1
    movq            xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+ 0]
    pinsrb          xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+24], 7 ; luma
    movhps          xm7, [fg_dataq+FGData.ar_coeffs_uv+uvq+ 7]
    pmovsxbw         m7, xm7
%if %2
    vpbroadcastw   xm14, [base+hmul_bits+2+%3*2]
%endif
    pshufd           m4, m7, q0000
    pshufd           m5, m7, q1111
    pshufd           m6, m7, q2222
    pshufd           m7, m7, q3333
    movd            xm0, [fg_dataq+FGData.ar_coeffs_uv+uvq+14]
    pinsrb          xm0, [base+pb_1], 3
    pinsrd          xm0, [fg_dataq+FGData.ar_coeffs_uv+uvq+21], 1
    pinsrd          xm0, [fg_dataq+FGData.ar_coeffs_uv+uvq+17], 2
    pmovsxbw         m0, xm0
    movd           xm12, bdmaxd                 ; max_grain
    pshufd           m8, m0, q0000
    pshufd           m9, m0, q1111
    pcmpeqd        xm13, xm13
    punpckhqdq     xm10, xm0, xm0
    pxor           xm13, xm12                   ; min_grain
    pinsrw         xm10, [base+round_vals-10+shiftq*2], 3
    DEFINE_ARGS buf, bufy, fg_data, h, unused, x
%if %2
    sub            bufq, 2*(82*(73-35*%3)+44-(82*3+41))
%else
    sub            bufq, 2*(82*69+3)
%endif
    add           bufyq, 2*(79+82*3)
    mov              hd, 70-35*%3
.y_loop_ar3:
    mov              xq, -(76>>%2)
.x_loop_ar3:
    movu            xm2, [bufq+xq*2-82*6-6+ 0]    ; y=-3,x=[-3,+4]
    vinserti128      m2, [bufq+xq*2-82*4-6+ 0], 1 ; y=-3/-2,x=[-3,+4]
    movq            xm1, [bufq+xq*2-82*6-6+16]    ; y=-3,x=[+5,+8]
    vinserti128      m1, [bufq+xq*2-82*4-6+16], 1 ; y=-3/-2,x=[+5,+12]
    palignr          m3, m1, m2, 2                ; y=-3/-2,x=[-2,+5]
    palignr          m1, m2, 12                   ; y=-3/-2,x=[+3,+6]
    punpcklwd        m0, m2, m3                   ; y=-3/-2,x=[-3/-2,-2/-1,-1/+0,+0/+1]
    punpckhwd        m2, m3                       ; y=-3/-2,x=[+1/+2,+2/+3,+3/+4,+4/+5]
    shufps           m3, m0, m2, q1032            ; y=-3/-2,x=[-1/+0,+0/+1,+1/+2,+2/+3]
    pmaddwd          m0, m4
    pmaddwd          m2, m6
    pmaddwd          m3, m5
    paddd            m0, m2
    paddd            m0, m3
    movu            xm2, [bufq+xq*2-82*2-6+ 0]    ; y=-1,x=[-3,+4]
    vinserti128      m2, [bufq+xq*2-82*2-6+ 6], 1 ; y=-1,x=[+1,+8]
%if %2
    movu            xm3, [bufyq+xq*4]
%if %3
    paddw           xm3, [bufyq+xq*4+82*2]
%endif
    phaddw          xm3, xm3
    pmulhrsw        xm3, xm14
%else
    movq            xm3, [bufyq+xq*2]
%endif
    punpcklwd        m1, m3
    pmaddwd          m1, m7
    paddd            m0, m1
    psrldq           m1, m2, 4
    psrldq           m3, m2, 6
    vpblendd         m3, m11, 0x0f                ; rounding constant
    punpcklwd        m1, m3                       ; y=-1,x=[-1/rnd,+0/rnd,+1/rnd,+2/rnd]
    pmaddwd          m1, m9                       ;      x=[+2/+3,+3/+4,+4/+5,+5,+6]
    psrldq           m3, m2, 2
    punpcklwd        m2, m3                       ; y=-1,x=[-3/-2,-2/-1,-1/+0,+0/+1]
    pmaddwd          m2, m8                       ;      x=[+0/+1,+1/+2,+2/+3,+3/+4]
    paddd            m0, m1
    movu            xm1, [bufq+xq*2-6]            ; y=0,x=[-3,+4]
    paddd            m0, m2
    vextracti128    xm2, m0, 1
    paddd           xm0, xm2
.x_loop_ar3_inner:
    pmaddwd         xm2, xm1, xm10
    pshuflw         xm3, xm2, q1032
    paddd           xm2, xm0                      ; add top
    paddd           xm2, xm3                      ; left+cur
    psrldq          xm0, 4
    psrad           xm2, [fg_dataq+FGData.ar_coeff_shift]
    psrldq          xm1, 2
    ; no need to packssdw since we only care about one value
    pminsd          xm2, xm12
    pmaxsd          xm2, xm13
    pextrw  [bufq+xq*2], xm2, 0
    pslldq          xm2, 4
    pblendw         xm1, xm2, 00000100b
    inc              xq
    jz .x_loop_ar3_end
    test             xb, 3
    jnz .x_loop_ar3_inner
    jmp .x_loop_ar3
.x_loop_ar3_end:
    add            bufq, 82*2
    add           bufyq, 82*2<<%3
    dec              hd
    jg .y_loop_ar3
    RET
%endmacro

generate_grain_uv_fn 420, 1, 1
generate_grain_uv_fn 422, 1, 0
generate_grain_uv_fn 444, 0, 0

INIT_YMM avx2
cglobal fgy_32x32xn_16bpc, 6, 14, 16, dst, src, stride, fg_data, w, scaling, grain_lut
    mov             r7d, [fg_dataq+FGData.scaling_shift]
    lea              r8, [pb_mask]
%define base r8-pb_mask
    vpbroadcastw    m11, [base+mul_bits+r7*2-14]
    mov             r6d, [fg_dataq+FGData.clip_to_restricted_range]
    mov             r9d, r9m        ; bdmax
    sar             r9d, 11         ; is_12bpc
    shlx           r10d, r6d, r9d
    vpbroadcastw    m13, [base+min+r10*2]
    lea             r9d, [r9d*3]
    lea             r9d, [r6d*2+r9d]
    vpbroadcastw    m12, [base+max+r9*2]
    vpbroadcastw    m10, r9m
    pxor             m2, m2

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, unused1, \
                sby, see

    movifnidn      sbyd, sbym
    test           sbyd, sbyd
    setnz           r7b
    test            r7b, byte [fg_dataq+FGData.overlap_flag]
    jnz .vertical_overlap

    imul           seed, sbyd, (173 << 24) | 37
    add            seed, (105 << 24) | 178
    rol            seed, 8
    movzx          seed, seew
    xor            seed, [fg_dataq+FGData.seed]

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                unused1, unused2, see, src_bak

    lea        src_bakq, [srcq+wq*2]
    neg              wq
    sub            dstq, srcq

.loop_x:
    mov             r6d, seed
    or             seed, 0xEFF4
    shr             r6d, 1
    test           seeb, seeh
    lea            seed, [r6+0x8000]
    cmovp          seed, r6d                ; updated seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, src_bak

    mov           offxd, seed
    rorx          offyd, seed, 8
    shr           offxd, 12
    and           offyd, 0xf
    imul          offyd, 164
    lea           offyq, [offyq+offxq*2+747] ; offy*stride+offx

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, src_bak

    mov              hd, hm
    mov      grain_lutq, grain_lutmp
.loop_y:
    ; src
    pminuw           m0, m10, [srcq+ 0]
    pminuw           m1, m10, [srcq+32]          ; m0-1: src as word
    punpckhwd        m5, m0, m2
    punpcklwd        m4, m0, m2
    punpckhwd        m7, m1, m2
    punpcklwd        m6, m1, m2             ; m4-7: src as dword

    ; scaling[src]
    pcmpeqw          m3, m3
    mova             m9, m3
    vpgatherdd       m8, [scalingq+m4-3], m3
    vpgatherdd       m4, [scalingq+m5-3], m9
    pcmpeqw          m3, m3
    mova             m9, m3
    vpgatherdd       m5, [scalingq+m6-3], m3
    vpgatherdd       m6, [scalingq+m7-3], m9
    REPX  {psrld x, 24}, m8, m4, m5, m6
    packssdw         m8, m4
    packssdw         m5, m6

    ; grain = grain_lut[offy+y][offx+x]
    movu             m9, [grain_lutq+offxyq*2]
    movu             m3, [grain_lutq+offxyq*2+32]

    ; noise = round2(scaling[src] * grain, scaling_shift)
    REPX {pmullw x, m11}, m8, m5
    pmulhrsw         m9, m8
    pmulhrsw         m3, m5

    ; dst = clip_pixel(src, noise)
    paddw            m0, m9
    paddw            m1, m3
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova [dstq+srcq+ 0], m0
    mova [dstq+srcq+32], m1

    add            srcq, strideq
    add      grain_lutq, 82*2
    dec              hd
    jg .loop_y

    add              wq, 32
    jge .end
    lea            srcq, [src_bakq+wq*2]
    cmp byte [fg_dataq+FGData.overlap_flag], 0
    je .loop_x

    ; r8m = sbym
    movq           xm15, [pw_27_17_17_27]
    cmp       dword r8m, 0
    jne .loop_x_hv_overlap

    ; horizontal overlap (without vertical overlap)
    vpbroadcastd   xm14, [pd_16]
.loop_x_h_overlap:
    mov             r6d, seed
    or             seed, 0xEFF4
    shr             r6d, 1
    test           seeb, seeh
    lea            seed, [r6+0x8000]
    cmovp          seed, r6d                ; updated seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, src_bak, left_offxy

    lea     left_offxyd, [offyd+32]         ; previous column's offy*stride+offx
    mov           offxd, seed
    rorx          offyd, seed, 8
    shr           offxd, 12
    and           offyd, 0xf
    imul          offyd, 164
    lea           offyq, [offyq+offxq*2+747] ; offy*stride+offx

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, src_bak, left_offxy

    mov              hd, hm
    mov      grain_lutq, grain_lutmp
.loop_y_h_overlap:
    ; src
    pminuw           m0, m10, [srcq+ 0]
    pminuw           m1, m10, [srcq+32]          ; m0-1: src as word
    punpckhwd        m5, m0, m2
    punpcklwd        m4, m0, m2
    punpckhwd        m7, m1, m2
    punpcklwd        m6, m1, m2             ; m4-7: src as dword

    ; scaling[src]
    pcmpeqw          m3, m3
    mova             m9, m3
    vpgatherdd       m8, [scalingq+m4-3], m3
    vpgatherdd       m4, [scalingq+m5-3], m9
    pcmpeqw          m3, m3
    mova             m9, m3
    vpgatherdd       m5, [scalingq+m6-3], m3
    vpgatherdd       m6, [scalingq+m7-3], m9
    REPX  {psrld x, 24}, m8, m4, m5, m6
    packssdw         m8, m4
    packssdw         m5, m6

    ; grain = grain_lut[offy+y][offx+x]
    movu             m9, [grain_lutq+offxyq*2]
    movd            xm7, [grain_lutq+left_offxyq*2]
    punpcklwd       xm7, xm9
    pmaddwd         xm7, xm15
    paddd           xm7, xm14
    psrad           xm7, 5
    packssdw        xm7, xm7
    vpblendd         m9, m7, 00000001b
    pcmpeqw          m3, m3
    psraw            m7, m10, 1             ; max_grain
    pxor             m3, m7                 ; min_grain
    pminsw           m9, m7
    pmaxsw           m9, m3
    movu             m3, [grain_lutq+offxyq*2+32]

    ; noise = round2(scaling[src] * grain, scaling_shift)
    REPX {pmullw x, m11}, m8, m5
    pmulhrsw         m9, m8
    pmulhrsw         m3, m5

    ; dst = clip_pixel(src, noise)
    paddw            m0, m9
    paddw            m1, m3
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova [dstq+srcq+ 0], m0
    mova [dstq+srcq+32], m1

    add            srcq, strideq
    add      grain_lutq, 82*2
    dec              hd
    jg .loop_y_h_overlap

    add              wq, 32
    jge .end
    lea            srcq, [src_bakq+wq*2]

    ; r8m = sbym
    cmp       dword r8m, 0
    jne .loop_x_hv_overlap
    jmp .loop_x_h_overlap

.end:
    RET

.vertical_overlap:
    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, unused1, \
                sby, see

    movzx          sbyd, sbyb
    imul           seed, [fg_dataq+FGData.seed], 0x00010001
    imul            r7d, sbyd, 173 * 0x00010001
    imul           sbyd, 37 * 0x01000100
    add             r7d, (105 << 16) | 188
    add            sbyd, (178 << 24) | (141 << 8)
    and             r7d, 0x00ff00ff
    and            sbyd, 0xff00ff00
    xor            seed, r7d
    xor            seed, sbyd               ; (cur_seed << 16) | top_seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                unused1, unused2, see, src_bak

    lea        src_bakq, [srcq+wq*2]
    neg              wq
    sub            dstq, srcq

    vpbroadcastd    m14, [pd_16]
.loop_x_v_overlap:
    vpbroadcastd    m15, [pw_27_17_17_27]

    ; we assume from the block above that bits 8-15 of r7d are zero'ed
    mov             r6d, seed
    or             seed, 0xeff4eff4
    test           seeb, seeh
    setp            r7b                     ; parity of top_seed
    shr            seed, 16
    shl             r7d, 16
    test           seeb, seeh
    setp            r7b                     ; parity of cur_seed
    or              r6d, 0x00010001
    xor             r7d, r6d
    rorx           seed, r7d, 1             ; updated (cur_seed << 16) | top_seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, src_bak, unused, top_offxy

    rorx          offyd, seed, 8
    rorx          offxd, seed, 12
    and           offyd, 0xf000f
    and           offxd, 0xf000f
    imul          offyd, 164
    ; offxy=offy*stride+offx, (cur_offxy << 16) | top_offxy
    lea           offyq, [offyq+offxq*2+0x10001*747+32*82]

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, src_bak, unused, top_offxy

    movzx    top_offxyd, offxyw
    shr          offxyd, 16

    mov              hd, hm
    mov      grain_lutq, grain_lutmp
.loop_y_v_overlap:
    ; grain = grain_lut[offy+y][offx+x]
    movu             m3, [grain_lutq+offxyq*2]
    movu             m7, [grain_lutq+top_offxyq*2]
    punpckhwd        m9, m7, m3
    punpcklwd        m7, m3
    REPX {pmaddwd x, m15}, m9, m7
    REPX {paddd   x, m14}, m9, m7
    REPX {psrad   x, 5}, m9, m7
    packssdw         m7, m9
    pcmpeqw          m0, m0
    psraw            m1, m10, 1             ; max_grain
    pxor             m0, m1                 ; min_grain
    pminsw           m7, m1
    pmaxsw           m7, m0
    movu             m3, [grain_lutq+offxyq*2+32]
    movu             m8, [grain_lutq+top_offxyq*2+32]
    punpckhwd        m9, m8, m3
    punpcklwd        m8, m3
    REPX {pmaddwd x, m15}, m9, m8
    REPX {paddd   x, m14}, m9, m8
    REPX {psrad   x, 5}, m9, m8
    packssdw         m8, m9
    pminsw           m8, m1
    pmaxsw           m8, m0

    ; src
    pminuw           m0, m10, [srcq+ 0]          ; m0-1: src as word
    punpckhwd        m5, m0, m2
    punpcklwd        m4, m0, m2

    ; scaling[src]
    pcmpeqw          m3, m3
    mova             m9, m3
    vpgatherdd       m6, [scalingq+m4-3], m3
    vpgatherdd       m4, [scalingq+m5-3], m9
    REPX  {psrld x, 24}, m6, m4
    packssdw         m6, m4

    ; noise = round2(scaling[src] * grain, scaling_shift)
    pmullw           m6, m11
    pmulhrsw         m6, m7

    ; same for the other half
    pminuw           m1, m10, [srcq+32]          ; m0-1: src as word
    punpckhwd        m9, m1, m2
    punpcklwd        m4, m1, m2             ; m4-7: src as dword
    pcmpeqw          m3, m3
    mova             m7, m3
    vpgatherdd       m5, [scalingq+m4-3], m3
    vpgatherdd       m4, [scalingq+m9-3], m7
    REPX  {psrld x, 24}, m5, m4
    packssdw         m5, m4

    pmullw           m5, m11
    pmulhrsw         m5, m8

    ; dst = clip_pixel(src, noise)
    paddw            m0, m6
    paddw            m1, m5
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova [dstq+srcq+ 0], m0
    mova [dstq+srcq+32], m1

    vpbroadcastd    m15, [pw_27_17_17_27+4] ; swap weights for second v-overlap line
    add            srcq, strideq
    add      grain_lutq, 82*2
    dec              hw
    jz .end_y_v_overlap
    ; 2 lines get vertical overlap, then fall back to non-overlap code for
    ; remaining (up to) 30 lines
    xor              hd, 0x10000
    test             hd, 0x10000
    jnz .loop_y_v_overlap
    jmp .loop_y

.end_y_v_overlap:
    add              wq, 32
    jge .end_hv
    lea            srcq, [src_bakq+wq*2]

    ; since fg_dataq.overlap is guaranteed to be set, we never jump
    ; back to .loop_x_v_overlap, and instead always fall-through to
    ; h+v overlap

    movq           xm15, [pw_27_17_17_27]
.loop_x_hv_overlap:
    vpbroadcastd     m8, [pw_27_17_17_27]

    ; we assume from the block above that bits 8-15 of r7d are zero'ed
    mov             r6d, seed
    or             seed, 0xeff4eff4
    test           seeb, seeh
    setp            r7b                     ; parity of top_seed
    shr            seed, 16
    shl             r7d, 16
    test           seeb, seeh
    setp            r7b                     ; parity of cur_seed
    or              r6d, 0x00010001
    xor             r7d, r6d
    rorx           seed, r7d, 1             ; updated (cur_seed << 16) | top_seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, src_bak, left_offxy, top_offxy, topleft_offxy

    lea  topleft_offxyq, [top_offxyq+32]
    lea     left_offxyq, [offyq+32]
    rorx          offyd, seed, 8
    rorx          offxd, seed, 12
    and           offyd, 0xf000f
    and           offxd, 0xf000f
    imul          offyd, 164
    ; offxy=offy*stride+offx, (cur_offxy << 16) | top_offxy
    lea           offyq, [offyq+offxq*2+0x10001*747+32*82]

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, src_bak, left_offxy, top_offxy, topleft_offxy

    movzx    top_offxyd, offxyw
    shr          offxyd, 16

    mov              hd, hm
    mov      grain_lutq, grain_lutmp
.loop_y_hv_overlap:
    ; grain = grain_lut[offy+y][offx+x]
    movu             m3, [grain_lutq+offxyq*2]
    movu             m0, [grain_lutq+offxyq*2+32]
    movu             m6, [grain_lutq+top_offxyq*2]
    movu             m1, [grain_lutq+top_offxyq*2+32]
    movd            xm4, [grain_lutq+left_offxyq*2]
    movd            xm7, [grain_lutq+topleft_offxyq*2]
    ; do h interpolation first (so top | top/left -> top, left | cur -> cur)
    punpcklwd       xm4, xm3
    punpcklwd       xm7, xm6
    REPX {pmaddwd x, xm15}, xm4, xm7
    REPX {paddd   x, xm14}, xm4, xm7
    REPX {psrad   x, 5}, xm4, xm7
    REPX {packssdw x, x}, xm4, xm7
    pcmpeqw          m5, m5
    psraw            m9, m10, 1             ; max_grain
    pxor             m5, m9                 ; min_grain
    REPX {pminsw x, xm9}, xm4, xm7
    REPX {pmaxsw x, xm5}, xm4, xm7
    vpblendd         m3, m4, 00000001b
    vpblendd         m6, m7, 00000001b
    ; followed by v interpolation (top | cur -> cur)
    punpckhwd        m7, m6, m3
    punpcklwd        m6, m3
    punpckhwd        m3, m1, m0
    punpcklwd        m1, m0
    REPX {pmaddwd x, m8}, m7, m6, m3, m1
    REPX {paddd   x, m14}, m7, m6, m3, m1
    REPX {psrad   x, 5}, m7, m6, m3, m1
    packssdw         m7, m6, m7
    packssdw         m3, m1, m3
    REPX {pminsw x, m9}, m7, m3
    REPX {pmaxsw x, m5}, m7, m3

    ; src
    pminuw           m0, m10, [srcq+ 0]
    pminuw           m1, m10, [srcq+32]          ; m0-1: src as word
    punpckhwd        m5, m0, m2
    punpcklwd        m4, m0, m2

    ; scaling[src]
    pcmpeqw          m9, m9
    vpgatherdd       m6, [scalingq+m4-3], m9
    pcmpeqw          m9, m9
    vpgatherdd       m4, [scalingq+m5-3], m9
    REPX  {psrld x, 24}, m6, m4
    packssdw         m6, m4

    ; noise = round2(scaling[src] * grain, scaling_shift)
    pmullw           m6, m11
    pmulhrsw         m7, m6

    ; other half
    punpckhwd        m5, m1, m2
    punpcklwd        m4, m1, m2             ; m4-7: src as dword

    ; scaling[src]
    pcmpeqw          m6, m6
    vpgatherdd       m9, [scalingq+m4-3], m6
    pcmpeqw          m6, m6
    vpgatherdd       m4, [scalingq+m5-3], m6
    REPX  {psrld x, 24}, m9, m4
    packssdw         m9, m4

    ; noise = round2(scaling[src] * grain, scaling_shift)
    pmullw           m9, m11
    pmulhrsw         m3, m9

    ; dst = clip_pixel(src, noise)
    paddw            m0, m7
    paddw            m1, m3
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova [dstq+srcq+ 0], m0
    mova [dstq+srcq+32], m1

    vpbroadcastd     m8, [pw_27_17_17_27+4] ; swap weights for second v-overlap line
    add            srcq, strideq
    add      grain_lutq, 82*2
    dec              hw
    jz .end_y_hv_overlap
    ; 2 lines get vertical overlap, then fall back to non-overlap code for
    ; remaining (up to) 30 lines
    xor              hd, 0x10000
    test             hd, 0x10000
    jnz .loop_y_hv_overlap
    jmp .loop_y_h_overlap

.end_y_hv_overlap:
    add              wq, 32
    lea            srcq, [src_bakq+wq*2]
    jl .loop_x_hv_overlap

.end_hv:
    RET

%macro FGUV_FN 3 ; name, ss_hor, ss_ver
cglobal fguv_32x32xn_i%1_16bpc, 6, 15, 16, dst, src, stride, fg_data, w, scaling, \
                                      grain_lut, h, sby, luma, lstride, uv_pl, is_id
%define base r8-pb_mask
    lea              r8, [pb_mask]
    mov             r7d, [fg_dataq+FGData.scaling_shift]
    vpbroadcastw    m11, [base+mul_bits+r7*2-14]
    mov             r6d, [fg_dataq+FGData.clip_to_restricted_range]
    mov             r9d, r13m               ; bdmax
    sar             r9d, 11                 ; is_12bpc
    shlx           r10d, r6d, r9d
    vpbroadcastw    m13, [base+min+r10*2]
    lea            r10d, [r9d*3]
    mov            r11d, is_idm
    shlx            r6d, r6d, r11d
    add            r10d, r6d
    vpbroadcastw    m12, [base+max+r10*2]
    vpbroadcastw    m10, r13m
    pxor             m2, m2

    cmp byte [fg_dataq+FGData.chroma_scaling_from_luma], 0
    jne .csfl

%macro %%FGUV_32x32xN_LOOP 3 ; not-csfl, ss_hor, ss_ver
    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, unused, sby, see, overlap

%if %1
    mov             r7d, r11m
    vpbroadcastw     m0, [fg_dataq+FGData.uv_mult+r7*4]
    vpbroadcastw     m1, [fg_dataq+FGData.uv_luma_mult+r7*4]
    punpcklwd       m14, m1, m0
    vpbroadcastw    m15, [fg_dataq+FGData.uv_offset+r7*4]
    vpbroadcastd     m9, [base+pw_4+r9*4]
    pmullw          m15, m9
%else
    vpbroadcastd    m14, [pd_16]
%if %2
    vpbroadcastq    m15, [pw_23_22]
%else
    vpbroadcastq    m15, [pw_27_17_17_27]
%endif
%endif

    movifnidn      sbyd, sbym
    test           sbyd, sbyd
    setnz           r7b
    test            r7b, byte [fg_dataq+FGData.overlap_flag]
    jnz %%vertical_overlap

    imul           seed, sbyd, (173 << 24) | 37
    add            seed, (105 << 24) | 178
    rol            seed, 8
    movzx          seed, seew
    xor            seed, [fg_dataq+FGData.seed]

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                unused2, unused3, see, unused4, unused5, unused6, luma, lstride

    mov           lumaq, r9mp
    mov        lstrideq, r10mp
    lea             r10, [srcq+wq*2]
    lea             r11, [dstq+wq*2]
    lea             r12, [lumaq+wq*(2<<%2)]
    mov           r10mp, r10
    mov           r11mp, r11
    mov           r12mp, r12
    neg              wq

%%loop_x:
    mov             r6d, seed
    or             seed, 0xEFF4
    shr             r6d, 1
    test           seeb, seeh
    lea            seed, [r6+0x8000]
    cmovp          seed, r6d               ; updated seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, unused1, unused2, unused3, luma, lstride

    mov           offxd, seed
    rorx          offyd, seed, 8
    shr           offxd, 12
    and           offyd, 0xf
    imul          offyd, 164>>%3
    lea           offyq, [offyq+offxq*(2-%2)+(3+(6>>%3))*82+(3+(6>>%2))]  ; offy*stride+offx

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, unused1, unused2, unused3, luma, lstride

    mov              hd, hm
    mov      grain_lutq, grain_lutmp
%%loop_y:
    ; src
    mova             m0, [srcq]
%if %2
    mova             m1, [srcq+strideq]     ; m0-1: src as word
%else
    mova             m1, [srcq+32]
%endif

    ; luma_src
%if %2
    mova            xm4, [lumaq+lstrideq*0+ 0]
    mova            xm7, [lumaq+lstrideq*0+16]
    vinserti128      m4, [lumaq+lstrideq*0+32], 1
    vinserti128      m7, [lumaq+lstrideq*0+48], 1
    mova            xm6, [lumaq+lstrideq*(1<<%3)+ 0]
    mova            xm8, [lumaq+lstrideq*(1<<%3)+16]
    vinserti128      m6, [lumaq+lstrideq*(1<<%3)+32], 1
    vinserti128      m8, [lumaq+lstrideq*(1<<%3)+48], 1
    phaddw           m4, m7
    phaddw           m6, m8
    pavgw            m4, m2
    pavgw            m6, m2
%else
    mova             m4, [lumaq]
    mova             m6, [lumaq+32]
%endif

%if %1
    punpckhwd        m3, m4, m0
    punpcklwd        m4, m0
    punpckhwd        m5, m6, m1
    punpcklwd        m6, m1                 ; { luma, chroma }
    REPX {pmaddwd x, m14}, m3, m4, m5, m6
    REPX {psrad   x, 6}, m3, m4, m5, m6
    packssdw         m4, m3
    packssdw         m6, m5
    REPX {paddw x, m15}, m4, m6
    REPX {pmaxsw x, m2}, m4, m6
    REPX {pminsw x, m10}, m4, m6             ; clip_pixel()
%else
    REPX {pminuw x, m10}, m4, m6
%endif

    punpckhwd        m5, m4, m2
    punpcklwd        m4, m2
    punpckhwd        m7, m6, m2
    punpcklwd        m6, m2                 ; m4-7: luma_src as dword

    ; scaling[luma_src]
    pcmpeqw          m3, m3
    mova             m9, m3
    vpgatherdd       m8, [scalingq+m4-3], m3
    vpgatherdd       m4, [scalingq+m5-3], m9
    pcmpeqw          m3, m3
    mova             m9, m3
    vpgatherdd       m5, [scalingq+m6-3], m3
    vpgatherdd       m6, [scalingq+m7-3], m9
    REPX  {psrld x, 24}, m8, m4, m5, m6
    packssdw         m8, m4
    packssdw         m5, m6

    ; grain = grain_lut[offy+y][offx+x]
    movu             m9, [grain_lutq+offxyq*2]
%if %2
    movu             m3, [grain_lutq+offxyq*2+82*2]
%else
    movu             m3, [grain_lutq+offxyq*2+32]
%endif

    ; noise = round2(scaling[luma_src] * grain, scaling_shift)
    REPX {pmullw x, m11}, m8, m5
    pmulhrsw         m9, m8
    pmulhrsw         m3, m5

    ; dst = clip_pixel(src, noise)
    paddw            m0, m9
    paddw            m1, m3
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova         [dstq], m0
%if %2
    mova [dstq+strideq], m1

    lea            srcq, [srcq+strideq*2]
    lea            dstq, [dstq+strideq*2]
    lea           lumaq, [lumaq+lstrideq*(2<<%3)]
%else
    mova      [dstq+32], m1
    add            srcq, strideq
    add            dstq, strideq
    add           lumaq, lstrideq
%endif
    add      grain_lutq, 82*(2<<%2)
%if %2
    sub              hb, 2
%else
    dec              hb
%endif
    jg %%loop_y

    add              wq, 32>>%2
    jge %%end
    mov            srcq, r10mp
    mov            dstq, r11mp
    mov           lumaq, r12mp
    lea            srcq, [srcq+wq*2]
    lea            dstq, [dstq+wq*2]
    lea           lumaq, [lumaq+wq*(2<<%2)]
    cmp byte [fg_dataq+FGData.overlap_flag], 0
    je %%loop_x

    ; r8m = sbym
    cmp       dword r8m, 0
    jne %%loop_x_hv_overlap

    ; horizontal overlap (without vertical overlap)
%%loop_x_h_overlap:
    mov             r6d, seed
    or             seed, 0xEFF4
    shr             r6d, 1
    test           seeb, seeh
    lea            seed, [r6+0x8000]
    cmovp          seed, r6d               ; updated seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, left_offxy, unused1, unused2, luma, lstride

    lea     left_offxyd, [offyd+(32>>%2)]         ; previous column's offy*stride+offx
    mov           offxd, seed
    rorx          offyd, seed, 8
    shr           offxd, 12
    and           offyd, 0xf
    imul          offyd, 164>>%3
    lea           offyq, [offyq+offxq*(2-%2)+(3+(6>>%3))*82+3+(6>>%2)]  ; offy*stride+offx

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, left_offxy, unused1, unused2, luma, lstride

    mov              hd, hm
    mov      grain_lutq, grain_lutmp
%%loop_y_h_overlap:
    mova             m0, [srcq]
%if %2
    mova             m1, [srcq+strideq]

    ; luma_src
    mova            xm4, [lumaq+lstrideq*0+ 0]
    mova            xm7, [lumaq+lstrideq*0+16]
    vinserti128      m4, [lumaq+lstrideq*0+32], 1
    vinserti128      m7, [lumaq+lstrideq*0+48], 1
    mova            xm6, [lumaq+lstrideq*(1<<%3)+ 0]
    mova            xm8, [lumaq+lstrideq*(1<<%3)+16]
    vinserti128      m6, [lumaq+lstrideq*(1<<%3)+32], 1
    vinserti128      m8, [lumaq+lstrideq*(1<<%3)+48], 1
    phaddw           m4, m7
    phaddw           m6, m8
    pavgw            m4, m2
    pavgw            m6, m2
%else
    mova             m1, [srcq+32]

    ; luma_src
    mova             m4, [lumaq]
    mova             m6, [lumaq+32]
%endif

%if %1
    punpckhwd        m3, m4, m0
    punpcklwd        m4, m0
    punpckhwd        m5, m6, m1
    punpcklwd        m6, m1                 ; { luma, chroma }
    REPX {pmaddwd x, m14}, m3, m4, m5, m6
    REPX {psrad   x, 6}, m3, m4, m5, m6
    packssdw         m4, m3
    packssdw         m6, m5
    REPX {paddw x, m15}, m4, m6
    REPX {pmaxsw x, m2}, m4, m6
    REPX {pminsw x, m10}, m4, m6             ; clip_pixel()
%else
    REPX {pminuw x, m10}, m4, m6
%endif

    ; grain = grain_lut[offy+y][offx+x]
    movu             m9, [grain_lutq+offxyq*2]
%if %2
    movu             m3, [grain_lutq+offxyq*2+82*2]
%else
    movu             m3, [grain_lutq+offxyq*2+32]
%endif
    movd            xm5, [grain_lutq+left_offxyq*2+ 0]
%if %2
    pinsrw          xm5, [grain_lutq+left_offxyq*2+82*2], 2 ; {left0, left1}
    punpckldq       xm7, xm9, xm3           ; {cur0, cur1}
    punpcklwd       xm5, xm7                ; {left0, cur0, left1, cur1}
%else
    punpcklwd       xm5, xm9
%endif
%if %1
%if %2
    vpbroadcastq    xm8, [pw_23_22]
%else
    movq            xm8, [pw_27_17_17_27]
%endif
    pmaddwd         xm5, xm8
    vpbroadcastd    xm8, [pd_16]
    paddd           xm5, xm8
%else
    pmaddwd         xm5, xm15
    paddd           xm5, xm14
%endif
    psrad           xm5, 5
    packssdw        xm5, xm5
    pcmpeqw         xm8, xm8
    psraw           xm7, xm10, 1
    pxor            xm8, xm7
    pmaxsw          xm5, xm8
    pminsw          xm5, xm7
    vpblendd         m9, m9, m5, 00000001b
%if %2
    psrldq          xm5, 4
    vpblendd         m3, m3, m5, 00000001b
%endif

    ; scaling[luma_src]
    punpckhwd        m5, m4, m2
    punpcklwd        m4, m2
    pcmpeqw          m7, m7
    vpgatherdd       m8, [scalingq+m4-3], m7
    pcmpeqw          m7, m7
    vpgatherdd       m4, [scalingq+m5-3], m7
    REPX  {psrld x, 24}, m8, m4
    packssdw         m8, m4

    ; noise = round2(scaling[luma_src] * grain, scaling_shift)
    pmullw           m8, m11
    pmulhrsw         m9, m8

    ; same for the other half
    punpckhwd        m7, m6, m2
    punpcklwd        m6, m2                 ; m4-7: luma_src as dword
    pcmpeqw          m8, m8
    mova             m4, m8
    vpgatherdd       m5, [scalingq+m6-3], m8
    vpgatherdd       m6, [scalingq+m7-3], m4
    REPX  {psrld x, 24}, m5, m6
    packssdw         m5, m6

    ; noise = round2(scaling[luma_src] * grain, scaling_shift)
    pmullw           m5, m11
    pmulhrsw         m3, m5

    ; dst = clip_pixel(src, noise)
    paddw            m0, m9
    paddw            m1, m3
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova         [dstq], m0
%if %2
    mova [dstq+strideq], m1

    lea            srcq, [srcq+strideq*2]
    lea            dstq, [dstq+strideq*2]
    lea           lumaq, [lumaq+lstrideq*(2<<%3)]
%else
    mova      [dstq+32], m1

    add            srcq, strideq
    add            dstq, strideq
    add           lumaq, lstrideq
%endif

    add      grain_lutq, 82*(2<<%2)
%if %2
    sub              hb, 2
%else
    dec              hb
%endif
    jg %%loop_y_h_overlap

    add              wq, 32>>%2
    jge %%end
    mov            srcq, r10mp
    mov            dstq, r11mp
    mov           lumaq, r12mp
    lea            srcq, [srcq+wq*2]
    lea            dstq, [dstq+wq*2]
    lea           lumaq, [lumaq+wq*(2<<%2)]

    ; r8m = sbym
    cmp       dword r8m, 0
    jne %%loop_x_hv_overlap
    jmp %%loop_x_h_overlap

%%end:
    RET

%%vertical_overlap:
    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, unused, \
                sby, see, unused1, unused2, unused3, lstride

    movzx          sbyd, sbyb
    imul           seed, [fg_dataq+FGData.seed], 0x00010001
    imul            r7d, sbyd, 173 * 0x00010001
    imul           sbyd, 37 * 0x01000100
    add             r7d, (105 << 16) | 188
    add            sbyd, (178 << 24) | (141 << 8)
    and             r7d, 0x00ff00ff
    and            sbyd, 0xff00ff00
    xor            seed, r7d
    xor            seed, sbyd               ; (cur_seed << 16) | top_seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                unused1, unused2, see, unused3, unused4, unused5, luma, lstride

    mov           lumaq, r9mp
    mov        lstrideq, r10mp
    lea             r10, [srcq+wq*2]
    lea             r11, [dstq+wq*2]
    lea             r12, [lumaq+wq*(2<<%2)]
    mov           r10mp, r10
    mov           r11mp, r11
    mov           r12mp, r12
    neg              wq

%%loop_x_v_overlap:
    ; we assume from the block above that bits 8-15 of r7d are zero'ed
    mov             r6d, seed
    or             seed, 0xeff4eff4
    test           seeb, seeh
    setp            r7b                     ; parity of top_seed
    shr            seed, 16
    shl             r7d, 16
    test           seeb, seeh
    setp            r7b                     ; parity of cur_seed
    or              r6d, 0x00010001
    xor             r7d, r6d
    rorx           seed, r7d, 1             ; updated (cur_seed << 16) | top_seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, unused1, top_offxy, unused2, luma, lstride

    rorx          offyd, seed, 8
    rorx          offxd, seed, 12
    and           offyd, 0xf000f
    and           offxd, 0xf000f
    imul          offyd, 164>>%3
    ; offxy=offy*stride+offx, (cur_offxy << 16) | top_offxy
    lea           offyq, [offyq+offxq*(2-%2)+0x10001*((3+(6>>%3))*82+3+(6>>%2))+(32>>%3)*82]

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, unused1, top_offxy, unused2, luma, lstride

    movzx    top_offxyd, offxyw
    shr          offxyd, 16

%if %2 == 0
    lea             r10, [pw_27_17_17_27]
%endif
    mov              hd, hm
    mov      grain_lutq, grain_lutmp
%%loop_y_v_overlap:
    ; src
    mova             m0, [srcq]
%if %2
    mova             m1, [srcq+strideq]

    ; luma_src
    mova            xm4, [lumaq+lstrideq*0+ 0]
    mova            xm7, [lumaq+lstrideq*0+16]
    vinserti128      m4, [lumaq+lstrideq*0+32], 1
    vinserti128      m7, [lumaq+lstrideq*0+48], 1
    mova            xm6, [lumaq+lstrideq*(1<<%3)+ 0]
    mova            xm8, [lumaq+lstrideq*(1<<%3)+16]
    vinserti128      m6, [lumaq+lstrideq*(1<<%3)+32], 1
    vinserti128      m8, [lumaq+lstrideq*(1<<%3)+48], 1
    phaddw           m4, m7
    phaddw           m6, m8
    pavgw            m4, m2
    pavgw            m6, m2
%else
    mova             m1, [srcq+32]

    ; luma_src
    mova             m4, [lumaq]
    mova             m6, [lumaq+32]
%endif

%if %1
    punpckhwd        m3, m4, m0
    punpcklwd        m4, m0
    punpckhwd        m5, m6, m1
    punpcklwd        m6, m1                 ; { luma, chroma }
    REPX {pmaddwd x, m14}, m3, m4, m5, m6
    REPX {psrad   x, 6}, m3, m4, m5, m6
    packssdw         m4, m3
    packssdw         m6, m5
    REPX {paddw x, m15}, m4, m6
    REPX {pmaxsw x, m2}, m4, m6
    REPX {pminsw x, m10}, m4, m6             ; clip_pixel()
%else
    REPX {pminuw x, m10}, m4, m6
%endif

    ; grain = grain_lut[offy+y][offx+x]
    movu             m9, [grain_lutq+offxyq*2]
    movu             m5, [grain_lutq+top_offxyq*2]
    punpckhwd        m7, m5, m9
    punpcklwd        m5, m9                 ; {top/cur interleaved}
%if %3
    vpbroadcastd     m3, [pw_23_22]
%elif %2
    vpbroadcastd     m3, [pw_27_17_17_27]
%else
    vpbroadcastd     m3, [r10]
%endif
    REPX {pmaddwd x, m3}, m7, m5
%if %1
    vpbroadcastd     m8, [pd_16]
    REPX  {paddd x, m8}, m7, m5
%else
    REPX {paddd x, m14}, m7, m5
%endif
    REPX   {psrad x, 5}, m7, m5
    packssdw         m9, m5, m7
%if %2
    movu             m3, [grain_lutq+offxyq*2+82*2]
%else
    movu             m3, [grain_lutq+offxyq*2+32]
%endif
%if %3 == 0
%if %2
    movu             m5, [grain_lutq+top_offxyq*2+82*2]
%else
    movu             m5, [grain_lutq+top_offxyq*2+32]
%endif
    punpckhwd        m7, m5, m3
    punpcklwd        m5, m3                 ; {top/cur interleaved}
%if %2
    vpbroadcastd     m3, [pw_27_17_17_27+4]
%else
    vpbroadcastd     m3, [r10]
%endif
    REPX {pmaddwd x, m3}, m7, m5
%if %1
    REPX  {paddd x, m8}, m7, m5
%else
    REPX {paddd x, m14}, m7, m5
%endif
    REPX   {psrad x, 5}, m7, m5
    packssdw         m3, m5, m7
%endif ; %3 == 0
    pcmpeqw          m7, m7
    psraw            m5, m10, 1
    pxor             m7, m5
%if %3
    pmaxsw           m9, m7
    pminsw           m9, m5
%else
    REPX {pmaxsw x, m7}, m9, m3
    REPX {pminsw x, m5}, m9, m3
%endif

    ; scaling[luma_src]
    punpckhwd        m5, m4, m2
    punpcklwd        m4, m2
    pcmpeqw          m7, m7
    vpgatherdd       m8, [scalingq+m4-3], m7
    pcmpeqw          m7, m7
    vpgatherdd       m4, [scalingq+m5-3], m7
    REPX  {psrld x, 24}, m8, m4
    packssdw         m8, m4

    ; noise = round2(scaling[luma_src] * grain, scaling_shift)
    pmullw           m8, m11
    pmulhrsw         m9, m8

    ; scaling for the other half
    punpckhwd        m7, m6, m2
    punpcklwd        m6, m2                 ; m4-7: luma_src as dword
    pcmpeqw          m8, m8
    mova             m4, m8
    vpgatherdd       m5, [scalingq+m6-3], m8
    vpgatherdd       m6, [scalingq+m7-3], m4
    REPX  {psrld x, 24}, m5, m6
    packssdw         m5, m6

    ; noise = round2(scaling[luma_src] * grain, scaling_shift)
    pmullw           m5, m11
    pmulhrsw         m3, m5

    ; dst = clip_pixel(src, noise)
    paddw            m0, m9
    paddw            m1, m3
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova         [dstq], m0
%if %2
    mova [dstq+strideq], m1

    sub              hb, 2
%else
    mova      [dstq+32], m1
    dec              hb
%endif
    jle %%end_y_v_overlap
%if %2
    lea            srcq, [srcq+strideq*2]
    lea            dstq, [dstq+strideq*2]
    lea           lumaq, [lumaq+lstrideq*(2<<%3)]
%else
    add            srcq, strideq
    add            dstq, strideq
    add           lumaq, lstrideq
%endif
    add      grain_lutq, 82*(2<<%2)
%if %2
    jmp %%loop_y
%else
    btc              hd, 16
    jc %%loop_y
    add             r10, 4
    jmp %%loop_y_v_overlap
%endif

%%end_y_v_overlap:
    add              wq, 32>>%2
    jge %%end_hv
    mov            srcq, r10mp
    mov            dstq, r11mp
    mov           lumaq, r12mp
    lea            srcq, [srcq+wq*2]
    lea            dstq, [dstq+wq*2]
    lea           lumaq, [lumaq+wq*(2<<%2)]

    ; since fg_dataq.overlap is guaranteed to be set, we never jump
    ; back to .loop_x_v_overlap, and instead always fall-through to
    ; h+v overlap

%%loop_x_hv_overlap:
    ; we assume from the block above that bits 8-15 of r7d are zero'ed
    mov             r6d, seed
    or             seed, 0xeff4eff4
    test           seeb, seeh
    setp            r7b                     ; parity of top_seed
    shr            seed, 16
    shl             r7d, 16
    test           seeb, seeh
    setp            r7b                     ; parity of cur_seed
    or              r6d, 0x00010001
    xor             r7d, r6d
    rorx           seed, r7d, 1             ; updated (cur_seed << 16) | top_seed

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                offx, offy, see, left_offxy, top_offxy, topleft_offxy, luma, lstride

%if %2 == 0
    lea             r12, [pw_27_17_17_27]
    mov           r13mp, r12
%endif
    lea  topleft_offxyq, [top_offxyq+(32>>%2)]
    lea     left_offxyq, [offyq+(32>>%2)]
    rorx          offyd, seed, 8
    rorx          offxd, seed, 12
    and           offyd, 0xf000f
    and           offxd, 0xf000f
    imul          offyd, 164>>%3
    ; offxy=offy*stride+offx, (cur_offxy << 16) | top_offxy
    lea           offyq, [offyq+offxq*(2-%2)+0x10001*((3+(6>>%3))*82+3+(6>>%2))+(32>>%3)*82]

    DEFINE_ARGS dst, src, stride, fg_data, w, scaling, grain_lut, \
                h, offxy, see, left_offxy, top_offxy, topleft_offxy, luma, lstride

    movzx    top_offxyd, offxyw
    shr          offxyd, 16

    mov              hd, hm
    mov      grain_lutq, grain_lutmp
%%loop_y_hv_overlap:
    ; grain = grain_lut[offy+y][offx+x]
    movd            xm5, [grain_lutq+left_offxyq*2]
%if %2
    pinsrw          xm5, [grain_lutq+left_offxyq*2+82*2], 2
%if %3
    vinserti128      m5, [grain_lutq+topleft_offxyq*2], 1   ; { left0, left1, top/left }
%else
    ; insert both top/left lines
    movd            xm9, [grain_lutq+topleft_offxyq*2+82*2]
    pinsrw          xm9, [grain_lutq+topleft_offxyq*2], 2
    vinserti128      m5, xm9, 1
%endif
%else
    pinsrd          xm5, [grain_lutq+topleft_offxyq*2], 1
%endif
    movu             m9, [grain_lutq+offxyq*2]
%if %2
    movu             m3, [grain_lutq+offxyq*2+82*2]
%else
    movu             m3, [grain_lutq+offxyq*2+32]
%endif
    movu             m8, [grain_lutq+top_offxyq*2]
%if %2
    punpckldq       xm7, xm9, xm3           ; { cur0, cur1 }
%if %3
    vinserti128      m7, xm8, 1             ; { cur0, cur1, top0 }
%else
    ; insert both top lines
    movu             m1, [grain_lutq+top_offxyq*2+82*2]
    punpckldq       xm0, xm1, xm8
    vinserti128      m7, xm0, 1
%endif
%else
    movu             m1, [grain_lutq+top_offxyq*2+32]
    punpckldq       xm7, xm9, xm8
%endif
    punpcklwd        m5, m7                 ; { cur/left } interleaved
%if %2
%if %1
    vpbroadcastq     m0, [pw_23_22]
    pmaddwd          m5, m0
    vpbroadcastd     m0, [pd_16]
    paddd            m5, m0
%else
    pmaddwd          m5, m15
    paddd            m5, m14
%endif
    psrad            m5, 5
    vextracti128    xm0, m5, 1
    packssdw        xm5, xm0
%else
%if %1
    movddup         xm0, [pw_27_17_17_27]
    pmaddwd         xm5, xm0
    vpbroadcastd     m0, [pd_16]
    paddd           xm5, xm0
%else
    pmaddwd         xm5, xm15
    paddd           xm5, xm14
%endif
    psrad           xm5, 5
    packssdw        xm5, xm5
%endif
    pcmpeqw          m0, m0
    psraw            m7, m10, 1
    pxor             m0, m7
    pminsw          xm5, xm7
    pmaxsw          xm5, xm0
    vpblendd         m9, m9, m5, 00000001b
%if %2
    psrldq          xm5, 4
    vpblendd         m3, m3, m5, 00000001b
%if %3 == 0
    psrldq          xm5, 4
    vpblendd         m1, m1, m5, 00000001b
%endif
%endif
    psrldq          xm5, 4
    vpblendd         m5, m8, m5, 00000001b

    punpckhwd        m8, m5, m9
    punpcklwd        m5, m9                 ; {top/cur interleaved}
%if %3
    vpbroadcastd     m9, [pw_23_22]
%elif %2
    vpbroadcastd     m9, [pw_27_17_17_27]
%else
    xchg            r12, r13mp
    vpbroadcastd     m9, [r12]
%endif
    REPX {pmaddwd x, m9}, m8, m5
%if %1
    vpbroadcastd     m4, [pd_16]
    REPX  {paddd x, m4}, m8, m5
%else
    REPX {paddd x, m14}, m8, m5
%endif
    REPX   {psrad x, 5}, m8, m5
    packssdw         m9, m5, m8
%if %3
    pminsw           m9, m7
    pmaxsw           m9, m0
%else
    punpckhwd        m8, m1, m3
    punpcklwd        m1, m3                 ; {top/cur interleaved}
%if %2
    vpbroadcastd     m3, [pw_27_17_17_27+4]
%else
    vpbroadcastd     m3, [r12]
    xchg            r12, r13mp
%endif
    REPX {pmaddwd x, m3}, m8, m1
%if %1
    REPX  {paddd x, m4}, m8, m1
%else
    REPX {paddd x, m14}, m8, m1
%endif
    REPX   {psrad x, 5}, m8, m1
    packssdw         m3, m1, m8
    REPX {pminsw x, m7}, m9, m3
    REPX {pmaxsw x, m0}, m9, m3
%endif

    ; src
    mova             m0, [srcq]
%if %2
    mova             m1, [srcq+strideq]
%else
    mova             m1, [srcq+32]
%endif

    ; luma_src
%if %2
    mova            xm4, [lumaq+lstrideq*0+ 0]
    mova            xm7, [lumaq+lstrideq*0+16]
    vinserti128      m4, [lumaq+lstrideq*0+32], 1
    vinserti128      m7, [lumaq+lstrideq*0+48], 1
    mova            xm6, [lumaq+lstrideq*(1<<%3)+ 0]
    mova            xm8, [lumaq+lstrideq*(1<<%3)+16]
    vinserti128      m6, [lumaq+lstrideq*(1<<%3)+32], 1
    vinserti128      m8, [lumaq+lstrideq*(1<<%3)+48], 1
    phaddw           m4, m7
    phaddw           m6, m8
    pavgw            m4, m2
    pavgw            m6, m2
%else
    mova             m4, [lumaq]
    mova             m6, [lumaq+32]
%endif

%if %1
    punpckhwd        m8, m4, m0
    punpcklwd        m4, m0
    punpckhwd        m5, m6, m1
    punpcklwd        m6, m1                 ; { luma, chroma }
    REPX {pmaddwd x, m14}, m8, m4, m5, m6
    REPX {psrad   x, 6}, m8, m4, m5, m6
    packssdw         m4, m8
    packssdw         m6, m5
    REPX {paddw x, m15}, m4, m6
    REPX {pmaxsw x, m2}, m4, m6
    REPX {pminsw x, m10}, m4, m6             ; clip_pixel()
%else
    REPX {pminuw x, m10}, m4, m6
%endif

    ; scaling[luma_src]
    punpckhwd        m5, m4, m2
    punpcklwd        m4, m2
    pcmpeqw          m7, m7
    vpgatherdd       m8, [scalingq+m4-3], m7
    pcmpeqw          m7, m7
    vpgatherdd       m4, [scalingq+m5-3], m7
    REPX  {psrld x, 24}, m8, m4
    packssdw         m8, m4

    ; noise = round2(scaling[luma_src] * grain, scaling_shift)
    pmullw           m8, m11
    pmulhrsw         m9, m8

    ; same for the other half
    punpckhwd        m7, m6, m2
    punpcklwd        m6, m2                 ; m4-7: luma_src as dword
    pcmpeqw          m8, m8
    mova             m4, m8
    vpgatherdd       m5, [scalingq+m6-3], m8
    vpgatherdd       m6, [scalingq+m7-3], m4
    REPX  {psrld x, 24}, m5, m6
    packssdw         m5, m6

    ; noise = round2(scaling[luma_src] * grain, scaling_shift)
    pmullw           m5, m11
    pmulhrsw         m3, m5

    ; dst = clip_pixel(src, noise)
    paddw            m0, m9
    paddw            m1, m3
    pmaxsw           m0, m13
    pmaxsw           m1, m13
    pminsw           m0, m12
    pminsw           m1, m12
    mova         [dstq], m0
%if %2
    mova [dstq+strideq], m1

    lea            srcq, [srcq+strideq*2]
    lea            dstq, [dstq+strideq*2]
    lea           lumaq, [lumaq+lstrideq*(2<<%3)]
%else
    mova      [dstq+32], m1

    add            srcq, strideq
    add            dstq, strideq
    add           lumaq, lstrideq
%endif
    add      grain_lutq, 82*(2<<%2)
%if %2
    sub              hb, 2
    jg %%loop_y_h_overlap
%else
    dec              hb
    jle %%end_y_hv_overlap
    btc              hd, 16
    jc %%loop_y_h_overlap
    add           r13mp, 4
    jmp %%loop_y_hv_overlap
%endif

%%end_y_hv_overlap:
    add              wq, 32>>%2
    jge %%end_hv
    mov            srcq, r10mp
    mov            dstq, r11mp
    mov           lumaq, r12mp
    lea            srcq, [srcq+wq*2]
    lea            dstq, [dstq+wq*2]
    lea           lumaq, [lumaq+wq*(2<<%2)]
    jmp %%loop_x_hv_overlap

%%end_hv:
    RET
%endmacro

    %%FGUV_32x32xN_LOOP 1, %2, %3
.csfl:
    %%FGUV_32x32xN_LOOP 0, %2, %3
%endmacro

FGUV_FN 420, 1, 1
FGUV_FN 422, 1, 0
FGUV_FN 444, 0, 0
%endif ; ARCH_X86_64
