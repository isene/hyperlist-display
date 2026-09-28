; hyperlist-display.asm — render Claude Code answers as HyperList on screen.
;
; A MessageDisplay hook: reads the hook JSON on stdin, extracts message_text,
; converts the markdown structure to tab-indented HyperList, and writes the
; replacement JSON on stdout. Display-only, so the transcript and what Claude
; reads keep the original markdown.
;
; Exists because the Python version cost 52 ms per invocation, essentially all
; of it interpreter startup, and the hook may fire once per streamed chunk.
;
;   nasm -f elf64 hyperlist-display.asm -o hyperlist-display.o
;   ld hyperlist-display.o -o hyperlist-display
;
; Exit 1 anywhere means "show the original text" — Claude Code falls back on a
; failed hook, so every error path here is simply a jump to fail.

; Static non-PIE binary, so absolute addressing is what we want. Stating
; it explicitly silences NASM's implicit-DEFAULT-ABS deprecation warning.
default abs

%define SYS_READ      0
%define SYS_WRITE     1
%define SYS_OPEN      2
%define SYS_CLOSE     3
%define SYS_ACCESS   21
%define SYS_EXIT     60
%define F_OK          0
%define O_WRONLY_CREAT_TRUNC 577
%define STATE_MODE    0o600
%define STDIN         0
%define STDOUT        1

%define IN_MAX    (1 << 20)          ; raw hook JSON
%define MSG_MAX   (1 << 20)          ; unescaped message_text
%define OUT_MAX   (1 << 21)          ; JSON-escaped output body (worst case ~2x)
%define LINE_MAX  65536
%define PARA_MAX  65536
; One-byte style sentinels. displayContent reaches the terminal as plain
; text, not markdown, so emphasis must be real ANSI. Sentinels survive
; wrapping and expand at emit time, costing no display columns.
%define B_ON      0x01
%define B_OFF     0x02
%define I_ON      0x03
%define I_OFF     0x04
%define U_ON      0x05
%define U_OFF     0x06
; Colour sentinels. 0x09, 0x0a and 0x0d are skipped: tab, newline and carriage
; return are read as structure by the line machinery.
%define C_RED     0x07
%define C_GRN     0x08
%define C_BLU     0x0b
%define C_MAG     0x0c
%define C_CYN     0x0e
%define C_YEL     0x0f
%define C_ORG     0x10
%define C_OFF     0x11
%define S_MAX     0x11
%define MASK      0x12  ; stands in for a code-span byte during the markup passes
%define MAX_ITEMS 16384              ; emitted Items held for the multi-line pass
%define ITEMS_MAX (1 << 20)          ; their text
%define IND_W     4                  ; four spaces per level
%define DEF_WIDTH 150
%define HDR_MAX   1024              ; carried table header row
%define TAIL_MAX  4096              ; carried partial line
%define HDR_OFF   136               ; seventeen qwords of header in the state file
%define TAIL_OFF  (HDR_OFF + HDR_MAX)

section .data

key_str:      db '"delta"'
key_len       equ $ - key_str

out_prefix:   db '{"hookSpecificOutput":{"hookEventName":"MessageDisplay",'
              db '"displayContent":"'
out_prefix_len equ $ - out_prefix
out_suffix:   db '"}}'
out_suffix_len equ $ - out_suffix

home_str:     db 'HOME='
home_len      equ $ - home_str
off_suffix:   db '/.claude/hyperlist-display.off', 0
off_suffix_len equ $ - off_suffix

code_str:     db 'EXAMPLE:'
code_len      equ $ - code_str
hl_tag:       db 'hyperlist'
hl_tag_len    equ $ - hl_tag
colon_sp:     db ': '
cond_open:    db '[? '
cond_close:   db '] '
then_str:     db 'then '
if_str:       db 'If '

; The Multi-line Indicator. displayContent is markdown-rendered, so this shows
; on screen as a bullet rather than a literal "+". Escaping it as "\+" was
; tried and is worse: the renderer does not process escapes and printed the
; backslash.
plus_str:     db C_MAG, '+', ' ', C_OFF
nl_esc:       db '\n'
xdg_str:      db 'XDG_RUNTIME_DIR='
xdg_len       equ $ - xdg_str
state_suffix: db '/hyperlist-display.state', 0
state_suffix_len equ $ - state_suffix
tmp_prefix:   db '/tmp', 0
idx_key:      db '"index"'
idx_key_len   equ $ - idx_key
fin_key:      db '"final"'
fin_key_len   equ $ - fin_key

hlwidth_str:  db 'HL_WIDTH='
hlwidth_len   equ $ - hlwidth_str

; ESC is written as the JSON escape \u001b, so out_esc_byte must not see it.
ansi_bon:     db '\u001b[1m'
ansi_bon_len  equ $ - ansi_bon
ansi_boff:    db '\u001b[22m'
ansi_boff_len equ $ - ansi_boff
ansi_ion:     db '\u001b[3m'
ansi_ion_len  equ $ - ansi_ion
ansi_ioff:    db '\u001b[23m'
ansi_ioff_len equ $ - ansi_ioff
ansi_uon:     db '\u001b[4m'
ansi_uon_len  equ $ - ansi_uon
ansi_uoff:    db '\u001b[24m'
ansi_uoff_len equ $ - ansi_uoff
; HyperList element colours. Operators sit on 33 rather than the TUI theme's
; 21 (#0000FF), which is unreadable on a dark terminal, so 27 here.
ansi_red:     db '\u001b[38;5;203m'
ansi_red_len  equ $ - ansi_red
ansi_grn:     db '\u001b[38;5;46m'
ansi_grn_len  equ $ - ansi_grn
ansi_blu:     db '\u001b[38;5;27m'
ansi_blu_len  equ $ - ansi_blu
ansi_mag:     db '\u001b[38;5;165m'
ansi_mag_len  equ $ - ansi_mag
ansi_cyn:     db '\u001b[38;5;51m'
ansi_cyn_len  equ $ - ansi_cyn
ansi_yel:     db '\u001b[38;5;226m'
ansi_yel_len  equ $ - ansi_yel
ansi_org:     db '\u001b[38;5;208m'
ansi_org_len  equ $ - ansi_org
ansi_coff:    db '\u001b[39m'
ansi_coff_len equ $ - ansi_coff
cls_oper:     db '_-() /'
cls_oper_len  equ $ - cls_oper
cls_prop:     db ',._&?!%= -/+<>#', 0x27, '"()*'
cls_prop_len  equ $ - cls_prop
cls_tag:      db '.:/_&?%=+-*'
cls_tag_len   equ $ - cls_tag
cls_ref:      db ',.:/ _~&@?%=+-*#'
cls_ref_len   equ $ - cls_ref
kw_skip:      db 'SKIP'
kw_end:       db 'END'

hexdig:       db '0123456789abcdef'

; Sentence-split guard. A candidate break is suppressed when the text just
; before the punctuation matches one of these, so "e.g. Foo" stays one item.
; Format: length byte, then the bytes. Terminated by a zero length.
abbrevs:
    db 4, 'e.g.'
    db 4, 'i.e.'
    db 4, 'etc.'
    db 3, 'vs.'
    db 3, 'cf.'
    db 3, 'Mr.'
    db 3, 'Dr.'
    db 3, 'No.'
    db 7, 'approx.'
    db 0

section .bss

in_buf:       resb IN_MAX
in_len:       resq 1
msg_buf:      resb MSG_MAX
msg_len:      resq 1
out_buf:      resb OUT_MAX
out_len:      resq 1

para_buf:     resb PARA_MAX
para_len:     resq 1
para_lvl:     resq 1                 ; depth from the paragraph's own indent

hdr_buf:      resb LINE_MAX          ; current table header row, inner content
hdr_len:      resq 1

line_buf:     resb LINE_MAX          ; inline_tr destination
line2_buf:    resb LINE_MAX          ; table header cell
line3_buf:    resb LINE_MAX          ; table data cell
tr_trim:      resq 1                 ; 0 while a segment is in flight
tr_dst:       resq 1                 ; driver's output base
masked_buf:   resb LINE_MAX          ; source with code spans masked out
mask_buf:     resb LINE_MAX          ; the bytes those masks stand for
mask_len:     resq 1
tmpa_buf:     resb LINE_MAX          ; inline_tr pass 1 -> 2
tmpb_buf:     resb LINE_MAX          ; inline_tr pass 2 -> 3

off_path:     resb 4096
home_ptr:     resq 1

base_ind:     resq 1                 ; indent contributed by current heading
kid_ind:      resq 1                 ; 1 while under a lone-Property parent
quote_ind:    resq 1                 ; quote level+1 while in a blockquote, 0 off
last_ind1:    resq 1                 ; last emitted indent+1; 0 = nothing yet
hoff:         resq 1                 ; heading offset from Property parents
enum_ind1:    resq 1                 ; last enumerator's indent+1, 0 = none
enum_shift:   resq 1                 ; engaged lift under that enumerator
pbase_ind1:   resq 1                 ; bold section head's level+1, 0 = none
prev_ind1:    resq 1                 ; previous rendered indent+1, 0 = none
dep_shift:    resq 1                 ; lift applied to an over-deep block
dep_origin:   resq 1                 ; indent that opened that lift
num_bold:     resq 1                 ; the enumerator was wrapped in "**"
q_off:        resq 1                 ; offset past a blockquote marker
para_items:   resq 1                 ; Items the current paragraph emitted
para_colon:   resq 1                 ; and whether the last one ended in ':'
shift_lvl:    resq 1                 ; shallowest heading level, shifted away
in_fence:     resq 1
fence_ind:    resq 1
fence_tag:    resq 1                 ; 1 = the opening fence carried a language
table_state:  resq 1                 ; 0 = none, 1 = header captured
sent_end:     resq 1                 ; last index belonging to the sentence
lead_nl:      resq 1                 ; blank-line structure of the incoming delta,
trail_nl:     resq 1                 ; preserved so chunks do not run together
delta_index:  resq 1                 ; 0 starts a fresh message, so state resets
state_path:   resb 4096
; base_ind, shift_lvl, stack depth, then (indent, wrapped) per level. The
; stack is what lets a sibling group survive a chunk boundary landing between
; two of its Items.
color_buf:    resb (LINE_MAX * 3)     ; colourised Item: 2 sentinels per span
color_len:    resq 1
state_io:     resb (TAIL_OFF + TAIL_MAX)
held_buf:     resb TAIL_MAX          ; partial line carried in from the last delta
held_len:     resq 1
tail_buf:     resb TAIL_MAX          ; partial line held back for the next one
tail_len:     resq 1
is_final:     resq 1                 ; the last delta flushes whatever is held
state_loaded: resq 1                 ; load_state already ran this invocation
carry_ind:    resq 16
carry_wrp:    resq 16
carry_depth:  resq 1

; Items are collected first and laid out afterwards, because the multi-line
; rule is a property of a whole sibling group: if one Item wraps, every Item
; in that group needs a Starter, and that is not known until the group ends.
items_ind:    resq MAX_ITEMS
items_off:    resq MAX_ITEMS
items_len:    resq MAX_ITEMS
items_lit:    resb MAX_ITEMS         ; literal (fenced code): never wrapped
items_gid:    resq MAX_ITEMS
grp_wrapped:  resb MAX_ITEMS         ; indexed by group id
item_count:   resq 1
items_buf:    resb ITEMS_MAX
items_used:   resq 1
next_is_lit:  resq 1                 ; set by emit_line_lit for the next add
gstk_ind:     resq 256               ; group-id stack: indent
gstk_gid:     resq 256
gstk_top:     resq 1
hl_width:     resq 1
wrap_buf:     resb LINE_MAX          ; "+ " prefix joined to the Item text
wrap_blen:    resq 1                 ; wrap state lives here rather than on the
wrap_start:   resq 1                 ; stack: syscalls clobber rcx/r11 and the
wrap_avail:   resq 1                 ; emit helpers below take their own args
wrap_cont:    resq 1
wrap_first:   resq 1

section .text
global _start

; ---------------------------------------------------------------------------
_start:
    mov rbp, rsp
    call find_home
    call check_off_flag             ; exits 0 if the off-flag exists
    call read_stdin
    call extract_message            ; msg_buf / msg_len, or jump to fail
    cmp qword [msg_len], 0
    je  done_quiet                  ; empty delta: emit nothing, succeed
    call extract_index
    call extract_final
    call carry_tail                 ; rejoin a line split across two deltas
    cmp qword [msg_len], 0
    je  done_held                   ; all of it held back: only the state moves
    call count_edge_newlines
    cmp qword [msg_len], 0
    je  done_blank                  ; nothing but newlines, but still a block end
    call convert
    cmp qword [out_len], 0
    jne .have_items
    mov qword [trail_nl], 0         ; no Items, no newline: a chunk that is
.have_items:                        ; only structure must not open a blank line
    call write_out
done_quiet:
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

; A chunk of nothing but newlines contributes no Item, but it still ENDS A
; BLOCK: a Property that closed the previous chunk has to become a parent
; here, or the blank line separating it from its children is the one chunk
; that never notices.
done_blank:
    cmp qword [in_fence], 0
    jne .keep                       ; blank lines inside a fence are content
    mov qword [kid_ind], 0
    mov qword [enum_ind1], 0        ; a blank chunk ends an enumerator's block
    mov qword [enum_shift], 0
    cmp qword [para_colon], 0
    je  .keep
    mov qword [kid_ind], 1
.keep:
    mov qword [para_colon], 0
    mov qword [quote_ind], 0        ; a blank chunk ends a quote too
    jmp done_held

; The whole chunk was an unterminated line, so it is held for the next delta.
; Still emit an empty body: silence would leave the raw markdown on screen.
done_held:
    call save_state
    mov qword [out_len], 0
    mov qword [lead_nl], 0
    mov qword [trail_nl], 0
    call write_out
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

fail:
    mov edi, 1
    mov eax, SYS_EXIT
    syscall

; Claude Code concatenates the rendered deltas, so a delta's own leading and
; trailing newlines carry the paragraph spacing between chunks. convert()
; drops blank lines, so count them here and re-emit them in write_out.
count_edge_newlines:
    mov qword [lead_nl], 0
    mov qword [trail_nl], 0
    xor rcx, rcx
.lead:
    cmp rcx, [msg_len]
    jae .all_blank
    cmp byte [msg_buf + rcx], 10
    jne .lead_done
    inc rcx
    jmp .lead
.lead_done:
    cmp rcx, 1
    jbe .lead_store
    mov ecx, 1                      ; one newline at most: no blank lines
.lead_store:
    ; Only a trailing newline is re-emitted. The held-tail carry means a chunk
    ; always ends on a line boundary and emits its own newline, so a leading
    ; one from the next chunk lands on top of it and opens a blank line.
    xor ecx, ecx
    mov [lead_nl], rcx
    mov rcx, [msg_len]
.trail:
    test rcx, rcx
    jz  .done
    cmp byte [msg_buf + rcx - 1], 10
    jne .trail_done
    dec rcx
    jmp .trail
.trail_done:
    mov rax, [msg_len]
    sub rax, rcx
    cmp rax, 1
    jbe .trail_store
    mov eax, 1                      ; likewise
.trail_store:
    mov [trail_nl], rax
.done:
    ret
.all_blank:
    ; nothing but newlines: markdown paragraph spacing, which HyperList does
    ; not use. Contribute nothing.
    mov qword [lead_nl], 0
    mov qword [msg_len], 0
    ret

; Deltas are converted one at a time, but the heading level a chunk sets has
; to survive into the next chunk or the indentation resets mid-list. Two
; values carry across: the current base indent and the heading shift. index 0
; means a new message, so start clean.
extract_index:
    mov qword [delta_index], 0
    mov r12, [in_len]
    cmp r12, idx_key_len
    jl  .ret
    sub r12, idx_key_len
    xor r13, r13
.scan:
    cmp r13, r12
    jg  .ret                        ; absent: treat as a fresh message
    lea rdi, [in_buf + r13]
    lea rsi, [idx_key]
    mov edx, idx_key_len
    push r12
    push r13
    call memcmp_n
    pop r13
    pop r12
    test eax, eax
    jz  .found
    inc r13
    jmp .scan
.found:
    lea rsi, [in_buf + r13 + idx_key_len]
    mov rbx, [in_len]
    lea rbx, [in_buf + rbx]
.skip:
    cmp rsi, rbx
    jae .ret
    mov al, [rsi]
    cmp al, ':'
    je  .adv
    cmp al, ' '
    je  .adv
    jmp .digits
.adv:
    inc rsi
    jmp .skip
.digits:
    xor ecx, ecx
.dloop:
    cmp rsi, rbx
    jae .store
    movzx eax, byte [rsi]
    cmp al, '0'
    jb  .store
    cmp al, '9'
    ja  .store
    sub eax, '0'
    imul rcx, rcx, 10
    add rcx, rax
    inc rsi
    jmp .dloop
.store:
    mov [delta_index], rcx
.ret:
    ret

; The last delta of a message flushes whatever partial line is held, or the
; text would sit in the state file until the next message discards it.
extract_final:
    mov qword [is_final], 0
    mov r12, [in_len]
    cmp r12, fin_key_len
    jl  .ret
    sub r12, fin_key_len
    xor r13, r13
.scan:
    cmp r13, r12
    jg  .ret                        ; absent: treat as not final
    lea rdi, [in_buf + r13]
    lea rsi, [fin_key]
    mov edx, fin_key_len
    push r12
    push r13
    call memcmp_n
    pop r13
    pop r12
    test eax, eax
    jz  .found
    inc r13
    jmp .scan
.found:
    lea rsi, [in_buf + r13 + fin_key_len]
    mov rbx, [in_len]
    lea rbx, [in_buf + rbx]
.skip:
    cmp rsi, rbx
    jae .ret
    mov al, [rsi]
    cmp al, ':'
    je  .adv
    cmp al, ' '
    je  .adv
    cmp al, 't'                     ; true, as opposed to false or null
    jne .ret
    mov qword [is_final], 1
    ret
.adv:
    inc rsi
    jmp .skip
.ret:
    ret

; A line split across two deltas has to be rejoined before it is measured.
; Converted apart, each half is under the width, so neither wraps and neither
; takes a Starter, yet the two land on one terminal row well past it. So an
; unterminated last line is held back and prepended to the next delta.
carry_tail:
    mov qword [tail_len], 0
    mov qword [held_len], 0
    cmp qword [delta_index], 0
    jne .resume
    mov qword [base_ind], 0         ; new message: the same clean start convert
    mov qword [shift_lvl], -1       ; makes, in case this chunk holds it all back
    mov qword [in_fence], 0
    mov qword [table_state], 0
    mov qword [hdr_len], 0
    jmp .split
.resume:
    call load_state
    mov rcx, [held_len]
    test rcx, rcx
    jz  .split
    mov rax, [msg_len]
    add rax, rcx
    cmp rax, MSG_MAX
    ja  .split                      ; pathological: render as-is, never truncate
    mov rdx, [msg_len]              ; shift right, backwards: the ranges overlap
.shift:
    test rdx, rdx
    jz  .shifted
    dec rdx
    mov al, [msg_buf + rdx]
    mov [msg_buf + rdx + rcx], al
    jmp .shift
.shifted:
    xor rdx, rdx
.copy_held:
    cmp rdx, rcx
    jae .held_done
    mov al, [held_buf + rdx]
    mov [msg_buf + rdx], al
    inc rdx
    jmp .copy_held
.held_done:
    add [msg_len], rcx
.split:
    cmp qword [is_final], 0
    jne .ret                        ; last delta: flush everything
    mov rcx, [msg_len]
    test rcx, rcx
    jz  .ret
    cmp byte [msg_buf + rcx - 1], 10
    je  .ret                        ; already ends on a line boundary
    mov rdx, rcx
.find_nl:
    test rdx, rdx
    jz  .cut_found                  ; no newline at all: hold the whole chunk
    dec rdx
    cmp byte [msg_buf + rdx], 10
    jne .find_nl
    inc rdx
.cut_found:
    mov rbx, rcx
    sub rbx, rdx
    cmp rbx, TAIL_MAX
    ja  .ret                        ; the TAIL exceeds the buffer: render as-is
    mov [tail_len], rbx
    xor rax, rax
.copy_tail:
    cmp rax, rbx
    jae .tail_done
    mov r8b, [msg_buf + rdx + rax]
    mov [tail_buf + rax], r8b
    inc rax
    jmp .copy_tail
.tail_done:
    mov [msg_len], rdx
.ret:
    ret

build_state_path:
    lea rdi, [xdg_str]
    mov esi, xdg_len
    call find_env
    test rax, rax
    jnz .have_dir
    lea rax, [tmp_prefix]
.have_dir:
    mov rsi, rax
    lea rdi, [state_path]
.copy_dir:
    mov al, [rsi]
    test al, al
    jz  .copy_suffix
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .copy_dir
.copy_suffix:
    lea rsi, [state_suffix]
    mov ecx, state_suffix_len
.cs:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec ecx
    jnz .cs
    ret

load_state:
    mov qword [base_ind], 0
    mov qword [shift_lvl], 0
    mov qword [table_state], 0
    mov qword [hdr_len], 0
    mov qword [held_len], 0
    mov qword [kid_ind], 0
    mov qword [para_colon], 0
    mov qword [quote_ind], 0
    mov qword [last_ind1], 0
    mov qword [hoff], 0
    mov qword [enum_ind1], 0
    mov qword [enum_shift], 0
    mov qword [pbase_ind1], 0
    mov qword [prev_ind1], 0
    mov qword [dep_shift], 0
    mov qword [dep_origin], 0
    mov qword [state_loaded], 1
    call build_state_path
    mov eax, SYS_OPEN
    lea rdi, [state_path]
    xor esi, esi                    ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js  .ret                        ; no state yet: zeros are the right default
    mov r12, rax
    mov eax, SYS_READ
    mov rdi, r12
    lea rsi, [state_io]
    mov rdx, TAIL_OFF + TAIL_MAX
    syscall
    cmp rax, HDR_OFF
    jl  .close
    mov rax, [state_io]
    mov [base_ind], rax
    mov rax, [state_io + 8]
    mov [shift_lvl], rax
    mov rax, [state_io + 16]
    mov [in_fence], rax             ; a code fence can span a chunk boundary
    mov rax, [state_io + 24]
    mov [fence_ind], rax
    ; the table header row, so a table split across deltas does not take its
    ; second chunk's first row as a new header
    mov rax, [state_io + 48]
    mov [kid_ind], rax              ; a Property parent spans chunks, and so
    mov rax, [state_io + 56]        ; does the colon that opens one
    mov [para_colon], rax
    mov rax, [state_io + 64]
    mov [quote_ind], rax            ; and so does a blockquote
    mov rax, [state_io + 72]
    mov [last_ind1], rax            ; the quote level derives from this
    mov rax, [state_io + 80]
    mov [hoff], rax                 ; and heading nesting from this
    mov rax, [state_io + 88]
    mov [enum_ind1], rax            ; an enumerator parents across chunks
    mov rax, [state_io + 96]
    mov [enum_shift], rax
    mov rax, [state_io + 104]
    mov [pbase_ind1], rax           ; a bold section head spans chunks
    mov rax, [state_io + 112]
    mov [prev_ind1], rax            ; and so does the one-level-at-a-time
    mov rax, [state_io + 120]       ; bookkeeping below it
    mov [dep_shift], rax
    mov rax, [state_io + 128]
    mov [dep_origin], rax
    mov rcx, [state_io + 32]
    cmp rcx, HDR_MAX
    jbe .hdr_ok
    mov ecx, HDR_MAX
.hdr_ok:
    mov [hdr_len], rcx
    test rcx, rcx
    jz  .no_hdr
    mov qword [table_state], 1
    xor rbx, rbx
.copy_hdr:
    cmp rbx, rcx
    jae .hdr_copied
    mov al, [state_io + HDR_OFF + rbx]
    mov [hdr_buf + rbx], al
    inc rbx
    jmp .copy_hdr
.no_hdr:
    mov qword [table_state], 0
.hdr_copied:
    ; the unterminated last line of the previous delta, so a sentence split
    ; across chunks is measured whole rather than as two short Items
    mov rcx, [state_io + 40]
    cmp rcx, TAIL_MAX
    jbe .tail_ok
    mov ecx, TAIL_MAX
.tail_ok:
    mov [held_len], rcx
    xor rbx, rbx
.copy_tail:
    cmp rbx, rcx
    jae .close
    mov al, [state_io + TAIL_OFF + rbx]
    mov [held_buf + rbx], al
    inc rbx
    jmp .copy_tail
.close:
    mov eax, SYS_CLOSE
    mov rdi, r12
    syscall
.ret:
    ret

save_state:
    call build_state_path
    mov rax, [base_ind]
    mov [state_io], rax
    mov rax, [shift_lvl]
    mov [state_io + 8], rax
    mov rax, [in_fence]
    mov [state_io + 16], rax
    mov rax, [fence_ind]
    mov [state_io + 24], rax
    xor rcx, rcx
    cmp qword [table_state], 0
    je  .hdr_done
    mov rcx, [hdr_len]
    cmp rcx, HDR_MAX
    jbe .hdr_done
    mov ecx, HDR_MAX
.hdr_done:
    mov [state_io + 32], rcx
    xor rbx, rbx
.pack:
    cmp rbx, rcx
    jae .packed
    mov al, [hdr_buf + rbx]
    mov [state_io + HDR_OFF + rbx], al
    inc rbx
    jmp .pack
.packed:
    mov rcx, [tail_len]
    cmp rcx, TAIL_MAX
    jbe .tail_ok
    mov ecx, TAIL_MAX
.tail_ok:
    mov [state_io + 40], rcx
    mov rax, [kid_ind]
    mov [state_io + 48], rax
    mov rax, [para_colon]
    mov [state_io + 56], rax
    mov rax, [quote_ind]
    mov [state_io + 64], rax
    mov rax, [last_ind1]
    mov [state_io + 72], rax
    mov rax, [hoff]
    mov [state_io + 80], rax
    mov rax, [enum_ind1]
    mov [state_io + 88], rax
    mov rax, [enum_shift]
    mov [state_io + 96], rax
    mov rax, [pbase_ind1]
    mov [state_io + 104], rax
    mov rax, [prev_ind1]
    mov [state_io + 112], rax
    mov rax, [dep_shift]
    mov [state_io + 120], rax
    mov rax, [dep_origin]
    mov [state_io + 128], rax
    xor rbx, rbx
.pack_tail:
    cmp rbx, rcx
    jae .tail_packed
    mov al, [tail_buf + rbx]
    mov [state_io + TAIL_OFF + rbx], al
    inc rbx
    jmp .pack_tail
.tail_packed:
    mov eax, SYS_OPEN
    lea rdi, [state_path]
    mov esi, O_WRONLY_CREAT_TRUNC
    mov edx, STATE_MODE
    syscall
    test rax, rax
    js  .ret
    mov r12, rax
    mov eax, SYS_WRITE
    mov rdi, r12
    lea rsi, [state_io]
    mov rdx, TAIL_OFF + TAIL_MAX
    syscall
    mov eax, SYS_CLOSE
    mov rdi, r12
    syscall
.ret:
    ret

; ---------------------------------------------------------------------------
; rdi = "NAME=" prefix, esi = its length. rax = pointer just past the prefix
; in the matching envp entry, or 0. rbp holds the original rsp, so the stack
; there is argc, argv[], NULL, envp[].
find_env:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    mov rcx, [rbp]                  ; argc
    lea rbx, [rbp + 8 + rcx*8 + 8]  ; skip argv and its NULL terminator
.next:
    mov rax, [rbx]
    test rax, rax
    jz  .none
    mov rdi, r12
    mov rsi, rax
    mov edx, r13d
    call memcmp_n
    test eax, eax
    jz  .found
    add rbx, 8
    jmp .next
.found:
    mov rax, [rbx]
    add rax, r13
    jmp .out
.none:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

find_home:
    lea rdi, [home_str]
    mov esi, home_len
    call find_env
    mov [home_ptr], rax
    ret

; HL_WIDTH overrides the wrap column. Anything unparseable leaves the default.
read_hl_width:
    mov qword [hl_width], DEF_WIDTH
    lea rdi, [hlwidth_str]
    mov esi, hlwidth_len
    call find_env
    test rax, rax
    jz  .ret
    mov rsi, rax
    xor ecx, ecx                    ; accumulated value
    xor edx, edx                    ; digit count
.digits:
    movzx eax, byte [rsi]
    cmp al, '0'
    jb  .end
    cmp al, '9'
    ja  .end
    sub eax, '0'
    imul rcx, rcx, 10
    add rcx, rax
    inc rsi
    inc edx
    cmp edx, 4
    jl  .digits
.end:
    test edx, edx
    jz  .ret                        ; no digits at all
    cmp rcx, 20
    jl  .ret                        ; absurdly narrow: keep the default
    mov [hl_width], rcx
.ret:
    ret

; rdi, rsi = buffers, edx = length. eax = 0 when equal.
memcmp_n:
    xor eax, eax
.loop:
    test edx, edx
    jz  .eq
    mov cl, [rdi]
    cmp cl, [rsi]
    jne .ne
    inc rdi
    inc rsi
    dec edx
    jmp .loop
.ne:
    mov eax, 1
.eq:
    ret

; ---------------------------------------------------------------------------
; access($HOME/.claude/hyperlist-display.off, F_OK) == 0 means "disabled".
; One syscall on the disabled path, then straight out.
check_off_flag:
    mov rsi, [home_ptr]
    test rsi, rsi
    jz  .ret                        ; no HOME: assume enabled
    lea rdi, [off_path]
.copy_home:
    mov al, [rsi]
    test al, al
    jz  .copy_suffix
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .copy_home
.copy_suffix:
    lea rsi, [off_suffix]
    mov ecx, off_suffix_len
.cs_loop:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec ecx
    jnz .cs_loop

    mov eax, SYS_ACCESS
    lea rdi, [off_path]
    xor esi, esi                    ; F_OK
    syscall
    test eax, eax
    jnz .ret                        ; missing: enabled
    xor edi, edi                    ; present: disabled, succeed silently
    mov eax, SYS_EXIT
    syscall
.ret:
    ret

; ---------------------------------------------------------------------------
read_stdin:
    xor r12, r12                    ; total
.loop:
    mov eax, SYS_READ
    mov edi, STDIN
    lea rsi, [in_buf]
    add rsi, r12
    mov rdx, IN_MAX
    sub rdx, r12
    jbe .done                       ; buffer full: take what we have
    syscall
    test rax, rax
    jz  .done                       ; EOF
    js  fail                        ; -errno
    add r12, rax
    jmp .loop
.done:
    mov [in_len], r12
    ret

; ---------------------------------------------------------------------------
; Find "message_text", step over : and the opening quote, then unescape the
; JSON string into msg_buf.
extract_message:
    mov qword [msg_len], 0
    mov r12, [in_len]
    cmp r12, key_len
    jl  fail
    sub r12, key_len                ; last valid start offset
    xor r13, r13
.scan:
    cmp r13, r12
    jg  fail
    lea rdi, [in_buf]
    add rdi, r13
    lea rsi, [key_str]
    mov edx, key_len
    push r12
    push r13
    call memcmp_n
    pop r13
    pop r12
    test eax, eax
    jz  .found
    inc r13
    jmp .scan
.found:
    lea rsi, [in_buf]
    add rsi, r13
    add rsi, key_len
    mov rbx, [in_len]
    lea rbx, [in_buf + rbx]         ; end pointer
.skip_ws1:
    cmp rsi, rbx
    jae fail
    mov al, [rsi]
    cmp al, ' '
    je  .adv1
    cmp al, 9
    je  .adv1
    cmp al, 10
    je  .adv1
    cmp al, 13
    je  .adv1
    jmp .want_colon
.adv1:
    inc rsi
    jmp .skip_ws1
.want_colon:
    cmp byte [rsi], ':'
    jne fail
    inc rsi
.skip_ws2:
    cmp rsi, rbx
    jae fail
    mov al, [rsi]
    cmp al, ' '
    je  .adv2
    cmp al, 9
    je  .adv2
    cmp al, 10
    je  .adv2
    cmp al, 13
    je  .adv2
    jmp .want_quote
.adv2:
    inc rsi
    jmp .skip_ws2
.want_quote:
    cmp byte [rsi], '"'
    jne .maybe_null
    inc rsi
    lea rdi, [msg_buf]
    call json_unescape              ; rax = length, or -1
    test rax, rax
    js  fail
    mov [msg_len], rax
    ret
.maybe_null:
    ; "message_text": null is legal input; nothing to render.
    mov qword [msg_len], 0
    ret

; rsi = first byte inside the string, rbx = hard end, rdi = dst.
; rax = bytes written, or -1 on malformed input.
json_unescape:
    mov r14, rdi                    ; dst start
.loop:
    cmp rsi, rbx
    jae .bad
    mov al, [rsi]
    cmp al, '"'
    je  .done
    cmp al, '\'
    je  .esc
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .loop
.esc:
    inc rsi
    cmp rsi, rbx
    jae .bad
    mov al, [rsi]
    inc rsi
    cmp al, 'n'
    je  .e_nl
    cmp al, 't'
    je  .e_tab
    cmp al, 'r'
    je  .e_cr
    cmp al, 'b'
    je  .e_bs
    cmp al, 'f'
    je  .e_ff
    cmp al, 'u'
    je  .e_u
    ; \" \\ \/ and anything else: the character itself
    mov [rdi], al
    inc rdi
    jmp .loop
.e_nl:
    mov byte [rdi], 10
    inc rdi
    jmp .loop
.e_tab:
    mov byte [rdi], 9
    inc rdi
    jmp .loop
.e_cr:
    mov byte [rdi], 13
    inc rdi
    jmp .loop
.e_bs:
    mov byte [rdi], 8
    inc rdi
    jmp .loop
.e_ff:
    mov byte [rdi], 12
    inc rdi
    jmp .loop
.e_u:
    call read_hex4                  ; eax = code point, rsi advanced
    test eax, eax
    js  .bad
    ; High surrogate: pair it with the following \uDC00..\uDFFF.
    cmp eax, 0xD800
    jl  .enc
    cmp eax, 0xDBFF
    jg  .enc
    lea rcx, [rsi + 1]
    cmp rcx, rbx
    jae .enc
    cmp byte [rsi], '\'
    jne .enc
    cmp byte [rsi + 1], 'u'
    jne .enc
    mov r15d, eax
    add rsi, 2
    call read_hex4
    test eax, eax
    js  .bad
    cmp eax, 0xDC00
    jl  .enc
    cmp eax, 0xDFFF
    jg  .enc
    sub r15d, 0xD800
    shl r15d, 10
    sub eax, 0xDC00
    add eax, r15d
    add eax, 0x10000
.enc:
    call utf8_emit                  ; writes at rdi, advances rdi
    jmp .loop
.done:
    mov rax, rdi
    sub rax, r14
    ret
.bad:
    mov rax, -1
    ret

; rsi -> 4 hex digits. eax = value, or -1. rsi advanced past them.
read_hex4:
    xor eax, eax
    mov ecx, 4
.loop:
    cmp rsi, rbx
    jae .bad
    movzx edx, byte [rsi]
    inc rsi
    shl eax, 4
    cmp dl, '0'
    jb  .bad
    cmp dl, '9'
    jbe .dig
    or  dl, 0x20                    ; fold to lower case
    cmp dl, 'a'
    jb  .bad
    cmp dl, 'f'
    ja  .bad
    sub edx, 'a' - 10
    jmp .add
.dig:
    sub edx, '0'
.add:
    add eax, edx
    dec ecx
    jnz .loop
    ret
.bad:
    mov eax, -1
    ret

; eax = code point, writes UTF-8 at rdi and advances rdi.
utf8_emit:
    cmp eax, 0x80
    jae .two
    mov [rdi], al
    inc rdi
    ret
.two:
    cmp eax, 0x800
    jae .three
    mov edx, eax
    shr edx, 6
    or  dl, 0xC0
    mov [rdi], dl
    and eax, 0x3F
    or  al, 0x80
    mov [rdi + 1], al
    add rdi, 2
    ret
.three:
    cmp eax, 0x10000
    jae .four
    mov edx, eax
    shr edx, 12
    or  dl, 0xE0
    mov [rdi], dl
    mov edx, eax
    shr edx, 6
    and dl, 0x3F
    or  dl, 0x80
    mov [rdi + 1], dl
    and eax, 0x3F
    or  al, 0x80
    mov [rdi + 2], al
    add rdi, 3
    ret
.four:
    mov edx, eax
    shr edx, 18
    or  dl, 0xF0
    mov [rdi], dl
    mov edx, eax
    shr edx, 12
    and dl, 0x3F
    or  dl, 0x80
    mov [rdi + 1], dl
    mov edx, eax
    shr edx, 6
    and dl, 0x3F
    or  dl, 0x80
    mov [rdi + 2], dl
    and eax, 0x3F
    or  al, 0x80
    mov [rdi + 3], al
    add rdi, 4
    ret

; ---------------------------------------------------------------------------
; Output helpers. out_buf accumulates the JSON string body already escaped,
; so there is no second escaping pass over the finished text.

; al = raw byte, appended with JSON escaping.
out_esc_byte:
    cmp al, S_MAX
    ja  .not_style
    test al, al
    jz  .not_style
    cmp al, 9                       ; tab, newline and carriage return are not
    je  .not_style                  ; sentinels: they carry real structure
    cmp al, 10
    je  .not_style
    cmp al, 13
    je  .not_style
    jmp emit_style                  ; 0x01..0x11 minus those three
.not_style:
    push rbx
    mov rbx, [out_len]
    cmp rbx, OUT_MAX - 16
    jae .full
    cmp al, '"'
    je  .backslash
    cmp al, '\'
    je  .backslash
    cmp al, 0x20
    jb  .ctrl
    mov [out_buf + rbx], al
    inc rbx
    jmp .store
.backslash:
    mov byte [out_buf + rbx], '\'
    mov [out_buf + rbx + 1], al
    add rbx, 2
    jmp .store
.ctrl:
    cmp al, 10
    je  .c_n
    cmp al, 9
    je  .c_t
    cmp al, 13
    je  .c_r
    ; \u00XX for the rest
    mov byte [out_buf + rbx], '\'
    mov byte [out_buf + rbx + 1], 'u'
    mov byte [out_buf + rbx + 2], '0'
    mov byte [out_buf + rbx + 3], '0'
    movzx edx, al
    mov ecx, edx
    shr ecx, 4
    mov cl, [hexdig + rcx]
    mov [out_buf + rbx + 4], cl
    and edx, 0x0F
    mov dl, [hexdig + rdx]
    mov [out_buf + rbx + 5], dl
    add rbx, 6
    jmp .store
.c_n:
    mov byte [out_buf + rbx], '\'
    mov byte [out_buf + rbx + 1], 'n'
    add rbx, 2
    jmp .store
.c_t:
    mov byte [out_buf + rbx], '\'
    mov byte [out_buf + rbx + 1], 't'
    add rbx, 2
    jmp .store
.c_r:
    mov byte [out_buf + rbx], '\'
    mov byte [out_buf + rbx + 1], 'r'
    add rbx, 2
.store:
    mov [out_len], rbx
.full:
    pop rbx
    ret

; al = a style sentinel. Appends its ANSI sequence verbatim, already in JSON
; escape form, so it is not re-escaped.
emit_style:
    push rbx
    push rsi
    push rdx
    push rcx
    movzx ecx, al
    lea rsi, [ansi_bon]
    mov edx, ansi_bon_len
    cmp ecx, B_ON
    je  .go
    lea rsi, [ansi_boff]
    mov edx, ansi_boff_len
    cmp ecx, B_OFF
    je  .go
    lea rsi, [ansi_ion]
    mov edx, ansi_ion_len
    cmp ecx, I_ON
    je  .go
    lea rsi, [ansi_ioff]
    mov edx, ansi_ioff_len
    cmp ecx, I_OFF
    je  .go
    lea rsi, [ansi_uon]
    mov edx, ansi_uon_len
    cmp ecx, U_ON
    je  .go
    lea rsi, [ansi_uoff]
    mov edx, ansi_uoff_len
    cmp ecx, U_OFF
    je  .go
    lea rsi, [ansi_red]
    mov edx, ansi_red_len
    cmp ecx, C_RED
    je  .go
    lea rsi, [ansi_grn]
    mov edx, ansi_grn_len
    cmp ecx, C_GRN
    je  .go
    lea rsi, [ansi_blu]
    mov edx, ansi_blu_len
    cmp ecx, C_BLU
    je  .go
    lea rsi, [ansi_mag]
    mov edx, ansi_mag_len
    cmp ecx, C_MAG
    je  .go
    lea rsi, [ansi_cyn]
    mov edx, ansi_cyn_len
    cmp ecx, C_CYN
    je  .go
    lea rsi, [ansi_yel]
    mov edx, ansi_yel_len
    cmp ecx, C_YEL
    je  .go
    lea rsi, [ansi_org]
    mov edx, ansi_org_len
    cmp ecx, C_ORG
    je  .go
    lea rsi, [ansi_coff]
    mov edx, ansi_coff_len
.go:
    mov rbx, [out_len]
    lea rax, [rbx + rdx]
    cmp rax, OUT_MAX - 16
    jae .full
.copy:
    mov al, [rsi]
    mov [out_buf + rbx], al
    inc rbx
    inc rsi
    dec rdx
    jnz .copy
    mov [out_len], rbx
.full:
    pop rcx
    pop rdx
    pop rsi
    pop rbx
    ret

; rsi = bytes, rdx = length.
out_esc_str:
    test rdx, rdx
    jz  .ret
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
.loop:
    mov al, [r12]
    call out_esc_byte
    inc r12
    dec r13
    jnz .loop
    pop r13
    pop r12
.ret:
    ret

; Append a two-byte JSON escape verbatim (al = the char after the backslash).
out_raw_esc:
    push rbx
    mov rbx, [out_len]
    cmp rbx, OUT_MAX - 8
    jae .full
    mov byte [out_buf + rbx], '\'
    mov [out_buf + rbx + 1], al
    add rbx, 2
    mov [out_len], rbx
.full:
    pop rbx
    ret

; r8 = indent, rsi = bytes, rdx = length, r9 = 1 to prepend one space.
; Writes one physical line. A multi-line Item's continuation lines sit at the
; same indent as the first with one added space, hence r9.
out_line:
    push r12
    push r13
    push r14
    push r15
    mov r13, rsi
    mov r14, rdx
    mov r12, r8
    mov r15, r9
    cmp qword [out_len], 0
    je  .no_nl
    mov al, 'n'
    call out_raw_esc
.no_nl:
    test r12, r12
    jz  .lead_space
.indent:
    mov ecx, IND_W
.spaces:
    push rcx
    mov al, ' '
    call out_esc_byte
    pop rcx
    dec ecx
    jnz .spaces
    dec r12
    jnz .indent
.lead_space:
    test r15, r15
    jz  .body
    mov al, ' '                     ; continuation: two spaces beyond the
    call out_esc_byte               ; Item's own indent (HyperList 2.8)
    mov al, ' '
    call out_esc_byte
.body:
    mov rsi, r13
    mov rdx, r14
    call out_esc_str
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; r8 = indent, rsi = bytes, rdx = length. Records an Item instead of emitting
; it. The multi-line rule is a property of a whole sibling group -- if one Item
; wraps, every Item in that group needs a Starter -- and that is not known
; until the group has ended. render_items does the layout.
emit_line_lit:
    mov qword [next_is_lit], 1
    jmp emit_line_common
emit_line:
    mov qword [next_is_lit], 0
    call colorize_buf               ; literals skip this: they enter below
emit_line_common:
    push rbx
    push r12
    push rdi
    mov rbx, [item_count]
    cmp rbx, MAX_ITEMS
    jae .full
    mov r12, [items_used]
    lea rax, [r12 + rdx]
    cmp rax, ITEMS_MAX
    jae .full
    mov [items_ind + rbx*8], r8
    mov [items_off + rbx*8], r12
    mov [items_len + rbx*8], rdx
    mov rax, [next_is_lit]
    mov [items_lit + rbx], al
    lea rdi, [items_buf + r12]
    call copy_n                     ; consumes rsi/rdx
    add r12, [items_len + rbx*8]
    mov [items_used], r12
    inc rbx
    mov [item_count], rbx
.full:
    pop rdi
    pop r12
    pop rbx
    ret

; Sibling groups. A group is a maximal run of Items at one indent under the
; same parent, so coming back to an indent after a shallower Item starts a new
; group: those Items have a different parent and are not siblings.
compute_groups:
    push rbx
    push r12
    push r13
    mov qword [gstk_top], 0
    xor r13, r13                    ; last issued group id
    ; seed from the previous delta so a group split across a chunk boundary
    ; stays one group and keeps whatever wrapped flag it already had
    xor rbx, rbx
.seed:
    cmp rbx, [carry_depth]
    jae .seeded
    inc r13
    mov rax, [carry_ind + rbx*8]
    mov [gstk_ind + rbx*8], rax
    mov [gstk_gid + rbx*8], r13
    mov rax, [carry_wrp + rbx*8]
    mov [grp_wrapped + r13], al
    inc rbx
    jmp .seed
.seeded:
    mov [gstk_top], rbx
    xor rbx, rbx
.loop:
    cmp rbx, [item_count]
    jae .done
    mov r12, [items_ind + rbx*8]
.pop:
    mov rcx, [gstk_top]
    test rcx, rcx
    jz  .need_new
    dec rcx
    cmp [gstk_ind + rcx*8], r12
    jbe .same_or_shallower
    mov [gstk_top], rcx             ; top is deeper than us: pop
    jmp .pop
.same_or_shallower:
    cmp [gstk_ind + rcx*8], r12
    je  .assign                     ; same indent, same parent: same group
.need_new:
    inc r13
    mov rcx, [gstk_top]
    cmp rcx, 256
    jae .assign                     ; stack full: stay in the current group
    mov [gstk_ind + rcx*8], r12
    mov [gstk_gid + rcx*8], r13
    inc rcx
    mov [gstk_top], rcx
.assign:
    mov rcx, [gstk_top]
    test rcx, rcx
    jz  .use_last
    dec rcx
    mov rax, [gstk_gid + rcx*8]
    jmp .store
.use_last:
    mov rax, r13
.store:
    mov [items_gid + rbx*8], rax
    inc rbx
    jmp .loop
.done:
    pop r13
    pop r12
    pop rbx
    ret

; If any Item in a group would run past the width, the whole group takes a
; Starter. Literal lines never count and are never wrapped.
mark_wraps:
    push rbx
    xor rbx, rbx
.loop:
    cmp rbx, [item_count]
    jae .done
    cmp byte [items_lit + rbx], 0
    jne .next
    mov rax, [items_ind + rbx*8]
    imul rax, rax, IND_W
    push rax
    mov rax, [items_off + rbx*8]
    lea rdi, [items_buf + rax]
    mov rsi, [items_len + rbx*8]
    call display_width              ; style sentinels take no columns
    pop rcx
    add rax, rcx
    add rax, 2                      ; the "+ " a wrap would add
    cmp rax, [hl_width]
    jbe .next
    mov rcx, [items_gid + rbx*8]
    mov byte [grp_wrapped + rcx], 1
.next:
    inc rbx
    jmp .loop
.done:
    pop rbx
    ret

; rdi = bytes, rsi = length -> rax = display columns, ignoring the one-byte
; style sentinels, which expand to zero-width ANSI at emit time.

; wrap_buf column arithmetic. The wrap budget is display columns: a UTF-8
; sequence is one column however many bytes it takes, and a style sentinel is
; none, so a styled line must not break earlier than a plain one.

; rax = display columns from wrap_start to wrap_blen.
cp_remaining:
    push rdi
    push rsi
    lea rdi, [wrap_buf]
    add rdi, [wrap_start]
    mov rsi, [wrap_blen]
    sub rsi, [wrap_start]
    call display_width
    pop rsi
    pop rdi
    ret

; rax = byte index reached after wrap_avail display columns from wrap_start,
; with trailing continuation and sentinel bytes riding along.
cp_advance:
    push rcx
    push rdx
    mov rax, [wrap_start]
    xor rcx, rcx                    ; columns consumed
.l:
    cmp rax, [wrap_blen]
    jae .d
    mov dl, [wrap_buf + rax]
    cmp dl, 0x80
    jb  .low
    cmp dl, 0xBF
    jbe .consume                    ; UTF-8 continuation: never a boundary
    jmp .occ
.low:
    test dl, dl
    jz  .occ
    cmp dl, 9
    je  .occ
    cmp dl, 10
    je  .occ
    cmp dl, 13
    je  .occ
    cmp dl, S_MAX
    jbe .consume                    ; sentinel: occupies no column, rides free
.occ:
    cmp rcx, [wrap_avail]
    jae .d                          ; budget spent and a new column starts here
    inc rcx
.consume:
    inc rax
    jmp .l
.d:
    pop rdx
    pop rcx
    ret

display_width:
    push rcx
    xor rax, rax
    xor rcx, rcx
.loop:
    cmp rcx, rsi
    jae .done
    mov dl, [rdi + rcx]
    inc rcx
    test dl, dl
    jz  .loop
    cmp dl, 9
    je  .count
    cmp dl, 10
    je  .count
    cmp dl, 13
    je  .count
    cmp dl, S_MAX
    jbe .loop                       ; sentinels occupy no display column
    cmp dl, 0x80
    jb  .count
    cmp dl, 0xBF
    jbe .loop                       ; UTF-8 continuation: not a new character
.count:
    inc rax
    jmp .loop
.done:
    pop rcx
    ret

; Emit wrap_buf[wrap_start .. wrap_start+rdx) at indent r12, then update the
; first-line flag. rdx = chunk length.
emit_chunk:
    push r12
    lea rsi, [wrap_buf]
    add rsi, [wrap_start]
    mov r8, r12
    mov r9, [wrap_first]
    xor r9, 1                       ; first line takes no leading spaces
    call out_line
    mov qword [wrap_first], 0
    pop r12
    ret

; Lay every Item out, wrapping where the multi-line rule requires it.
render_items:
    push rbx
    push r12
    push r13
    xor rbx, rbx
.item:
    cmp rbx, [item_count]
    jae .done
    mov r12, [items_ind + rbx*8]
    ; HyperList indents one level at a time: a child sits exactly one
    ; level under its parent. A jump of two has no parent to belong to,
    ; so lift the whole block by the same amount rather than clamping
    ; line by line, or siblings would drift apart. The lift holds until
    ; a line comes back shallower than the one that opened it.
    cmp qword [dep_shift], 0
    je  .li_set
    cmp r12, [dep_origin]
    jae .li_apply
    mov qword [dep_shift], 0
    mov qword [dep_origin], 0
.li_set:
    mov rax, [prev_ind1]
    cmp r12, rax
    jbe .li_apply
    mov rcx, r12
    sub rcx, rax
    mov [dep_shift], rcx
    mov [dep_origin], r12
.li_apply:
    sub r12, [dep_shift]
    lea rax, [r12 + 1]
    mov [prev_ind1], rax
    cmp byte [items_lit + rbx], 0
    je  .normal
    mov rax, [items_off + rbx*8]
    lea rsi, [items_buf + rax]
    mov rdx, [items_len + rbx*8]
    mov r8, r12
    xor r9, r9
    ; Literal lines reach the terminal inside a code span: its own inline
    ; markdown pass would otherwise pair a bare _ or * with one on a LATER
    ; line, eating both and italicising everything between. The delimiter
    ; run is one backtick longer than the longest run inside (codewrap).
    test rdx, rdx
    jz  .lit_out                    ; empty line: no span
    mov rax, rdx
    imul rax, rax, 3
    add rax, 2
    cmp rax, LINE_MAX
    ja  .lit_out                    ; absurd line: emit unwrapped
    xor r10, r10                    ; longest backtick run
    xor r11, r11                    ; current run
    xor rcx, rcx
.lit_run:
    cmp rcx, rdx
    jae .lit_scan_done
    cmp byte [rsi + rcx], '`'
    jne .lit_zero
    inc r11
    cmp r11, r10
    jbe .lit_adv
    mov r10, r11
    jmp .lit_adv
.lit_zero:
    xor r11, r11
.lit_adv:
    inc rcx
    jmp .lit_run
.lit_scan_done:
    inc r10                         ; delimiter run = longest + 1
    lea rdi, [wrap_buf]
    mov rcx, r10
.lit_open:
    mov byte [rdi], '`'
    inc rdi
    dec rcx
    jnz .lit_open
    call copy_n                     ; the text; advances rdi, eats rsi/rdx
    mov rcx, r10
.lit_close:
    mov byte [rdi], '`'
    inc rdi
    dec rcx
    jnz .lit_close
    lea rsi, [wrap_buf]
    mov rdx, rdi
    sub rdx, rsi
.lit_out:
    call out_line                   ; literal: verbatim, no Starter, no wrap
    jmp .next
.normal:
    ; HyperList 2.8: the Starter belongs to the Item that actually breaks,
    ; and to no other. Nothing about its siblings matters.
    mov rax, [items_ind + rbx*8]
    imul rax, rax, IND_W
    mov rcx, [hl_width]
    sub rcx, rax
    cmp rcx, 20
    jge .aok
    mov ecx, 20
.aok:
    mov [wrap_avail], rcx
    mov rax, [items_off + rbx*8]
    lea rdi, [items_buf + rax]
    mov rsi, [items_len + rbx*8]
    call display_width
    add rax, 2                      ; the "+ " a break would add
    lea rdi, [wrap_buf]
    cmp rax, [wrap_avail]
    jbe .no_plus
    ; One Starter per Item. An Item that already carries the neutral "- "
    ; turns that marker into the multi-line "+" rather than taking a second.
    mov rax, [items_off + rbx*8]
    lea rsi, [items_buf + rax]
    mov rdx, [items_len + rbx*8]
    cmp rdx, 4
    jb  .plain_plus
    cmp byte [rsi], C_MAG
    jne .plain_plus
    ; An Item opening with an Identifier already carries its line-leading
    ; marker, so it takes no Starter at all.
    mov al, [rsi + 1]
    cmp al, '0'
    jb  .not_ident
    cmp al, '9'
    jbe .no_plus
.not_ident:
    cmp byte [rsi + 1], '-'
    jne .plain_plus
    cmp byte [rsi + 2], ' '
    jne .plain_plus
    cmp byte [rsi + 3], C_OFF
    jne .plain_plus
    lea rsi, [plus_str]
    mov rdx, 4
    call copy_n
    mov rax, [items_off + rbx*8]
    lea rsi, [items_buf + rax + 4]  ; skip the neutral Starter it replaces
    mov rdx, [items_len + rbx*8]
    sub rdx, 4
    call copy_n
    jmp .body_done
.plain_plus:
    lea rsi, [plus_str]
    mov rdx, 4                      ; C_MAG '+' ' ' C_OFF, two display columns
    call copy_n
.no_plus:
    mov rax, [items_off + rbx*8]
    lea rsi, [items_buf + rax]
    mov rdx, [items_len + rbx*8]
    call copy_n
.body_done:
    lea rax, [wrap_buf]
    sub rdi, rax
    mov [wrap_blen], rdi
    mov rcx, [wrap_avail]
    sub rcx, 2                      ; continuations sit two spaces further in
    mov [wrap_cont], rcx
    mov qword [wrap_start], 0
    mov qword [wrap_first], 1
.wrap_loop:
    call cp_remaining               ; characters left, not bytes: a multi-byte
    cmp rax, [wrap_avail]           ; character is one column wide
    jle .last_chunk
    call cp_advance
    mov r13, rax                    ; last index the line could reach
.scan_back:
    cmp r13, [wrap_start]
    jle .hard_break
    cmp byte [wrap_buf + r13], ' '
    je  .found_space
    dec r13
    jmp .scan_back
.hard_break:
    call cp_advance
    mov r13, rax                    ; one word longer than the line: split it
    mov rdx, r13
    sub rdx, [wrap_start]
    call emit_chunk
    mov [wrap_start], r13
    jmp .advance
.found_space:
    mov rdx, r13
    sub rdx, [wrap_start]
    call emit_chunk
    inc r13                         ; the break consumes that space
    mov [wrap_start], r13
.advance:
    mov rax, [wrap_cont]
    mov [wrap_avail], rax
    jmp .wrap_loop
.last_chunk:
    mov rdx, [wrap_blen]
    sub rdx, [wrap_start]
    call emit_chunk
.next:
    inc rbx
    jmp .item
.done:
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; Character classes.

; al = byte. ZF set when it is a space or tab.
is_space:
    cmp al, ' '
    je  .yes
    cmp al, 9
    je  .yes
    ret                             ; ZF clear from the cmp
.yes:
    cmp al, al                      ; force ZF
    ret

; al = byte. eax = 1 when [A-Za-z0-9_] or a UTF-8 continuation/lead byte.
is_word:
    push rcx
    movzx ecx, al
    xor eax, eax
    cmp cl, '_'
    je  .yes
    cmp cl, 0x80
    jae .yes                        ; treat non-ASCII as word bytes
    cmp cl, '0'
    jb  .no
    cmp cl, '9'
    jbe .yes
    or  cl, 0x20
    cmp cl, 'a'
    jb  .no
    cmp cl, 'z'
    ja  .no
.yes:
    mov eax, 1
.no:
    pop rcx
    ret


; ---------------------------------------------------------------------------
; rsi/rdx = source, rdi = destination. rax = bytes written.
; Masks every code-span byte before the markup passes run and puts them back
; afterwards, so **`name` rewritten** still bolds while `*p` stays a
; dereference. MASK matches no rule and no pass deletes or reorders one, so
; the saved bytes go back in the order they came out. The trim happens here,
; after the restore, exactly as the Python reference strips after its join.
inline_tr:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [tr_dst], rdi
    mov r12, rsi
    mov r13, rdx
    xor r14, r14                    ; read cursor
    xor rbx, rbx                    ; saved-byte count
    xor r15, r15                    ; 1 while inside a code span
    xor r15, r15                    ; write cursor in masked_buf
.mask:
    cmp r14, r13
    jae .mask_done
    mov al, [r12 + r14]
    cmp al, '`'
    je  .mask_fence
.mask_plain:
    mov [masked_buf + r15], al
    inc r15
    inc r14
    jmp .mask
    ; A run of N backticks opens a span that ends at the next run of exactly
    ; N, as in markdown, so ``a `b` c`` can quote a backtick.
.mask_fence:
    mov rcx, r14
.mask_open:
    cmp rcx, r13
    jae .mask_run
    cmp byte [r12 + rcx], '`'
    jne .mask_run
    inc rcx
    jmp .mask_open
.mask_run:
    mov rdx, rcx
    sub rdx, r14                    ; rdx = run length
    mov r8, rcx                     ; r8 = scan cursor for the closer
.mask_find:
    cmp r8, r13
    jae .mask_unclosed
    cmp byte [r12 + r8], '`'
    je  .mask_cand
    inc r8
    jmp .mask_find
.mask_cand:
    mov r9, r8
.mask_cand_run:
    cmp r9, r13
    jae .mask_cand_done
    cmp byte [r12 + r9], '`'
    jne .mask_cand_done
    inc r9
    jmp .mask_cand_run
.mask_cand_done:
    mov rax, r9
    sub rax, r8
    cmp rax, rdx
    je  .mask_take
    mov r8, r9
    jmp .mask_find
.mask_unclosed:
    mov al, '`'                     ; no closer: the backticks are literal
    jmp .mask_plain
.mask_take:
    ; copy the opening run, mask the body, copy the closing run
    mov rax, r14
.mask_copy_open:
    cmp rax, rcx
    jae .mask_body
    mov dl, [r12 + rax]
    mov [masked_buf + r15], dl
    inc r15
    inc rax
    jmp .mask_copy_open
.mask_body:
    cmp rcx, r8
    jae .mask_copy_close
    mov dl, [r12 + rcx]
    mov [mask_buf + rbx], dl        ; remember it, emit the stand-in
    inc rbx
    mov byte [masked_buf + r15], MASK
    inc r15
    inc rcx
    jmp .mask_body
.mask_copy_close:
    cmp r8, r9
    jae .mask_next
    mov dl, [r12 + r8]
    mov [masked_buf + r15], dl
    inc r15
    inc r8
    jmp .mask_copy_close
.mask_next:
    mov r14, r9
    jmp .mask
.mask_done:
    mov r13, r15                    ; masked length, backticks kept as-is
    mov [mask_len], rbx
    mov qword [tr_trim], 0
    lea rsi, [masked_buf]
    mov rdx, r13
    mov rdi, [tr_dst]
    call inline_tr_seg
    mov qword [tr_trim], 1
    ; --- restore, in order
    mov r12, [tr_dst]
    xor r14, r14                    ; cursor in the output
    xor rbx, rbx                    ; next saved byte
.restore:
    cmp r14, rax
    jae .restore_done
    cmp byte [r12 + r14], MASK
    jne .restore_next
    cmp rbx, [mask_len]
    jae .restore_next
    mov cl, [mask_buf + rbx]
    mov [r12 + r14], cl
    inc rbx
.restore_next:
    inc r14
    jmp .restore
.restore_done:
    mov r15, r12
    ; --- trim, the two steps inline_tr_seg skipped
.tr_r:
    test rax, rax
    jz  .tr_l
    mov cl, [r15 + rax - 1]
    cmp cl, ' '
    je  .tr_r_do
    cmp cl, 9
    jne .tr_l
.tr_r_do:
    dec rax
    jmp .tr_r
.tr_l:
    xor rcx, rcx
.tr_l_scan:
    cmp rcx, rax
    jae .tr_l_done
    mov dl, [r15 + rcx]
    cmp dl, ' '
    je  .tr_l_next
    cmp dl, 9
    jne .tr_l_done
.tr_l_next:
    inc rcx
    jmp .tr_l_scan
.tr_l_done:
    test rcx, rcx
    jz  .tr_out
    sub rax, rcx
    push rax
    mov rdi, r15
    lea rsi, [r15 + rcx]
    mov rdx, rax
    call copy_n
    pop rax
.tr_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; inline_tr — markdown inline markup to HyperList inline markup.
;   rdi = dst, rsi = src, rdx = len -> rax = length written
; Three passes: links, then bold (parked on BOLD_MARK), then italic. Bold is
; parked because HyperList bold is *word*, exactly what the italic pass eats.
inline_tr_seg:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi                    ; final dst

    ; --- pass 1: [text](url) -> text <url>, and drop ~~
    lea rdi, [tmpa_buf]
    mov r12, rsi
    mov r13, rdx
    xor r14, r14                    ; index
.p1:
    cmp r14, r13
    jae .p1_done
    mov al, [r12 + r14]
    cmp al, '~'
    jne .p1_notilde
    lea rcx, [r14 + 1]
    cmp rcx, r13
    jae .p1_notilde
    cmp byte [r12 + rcx], '~'
    jne .p1_notilde
    add r14, 2
    jmp .p1
.p1_notilde:
    cmp al, '['
    jne .p1_copy
    ; look for ](  ... )
    lea rbx, [r14 + 1]
.p1_find_rb:
    cmp rbx, r13
    jae .p1_copy
    cmp byte [r12 + rbx], ']'
    je  .p1_got_rb
    inc rbx
    jmp .p1_find_rb
.p1_got_rb:
    lea rcx, [rbx + 1]
    cmp rcx, r13
    jae .p1_copy
    cmp byte [r12 + rcx], '('
    jne .p1_copy
    ; text = r14+1 .. rbx-1
    lea rsi, [r12 + r14 + 1]
    mov rdx, rbx
    sub rdx, r14
    dec rdx
    call copy_n
    mov byte [rdi], ' '
    mov byte [rdi + 1], '<'
    add rdi, 2
    ; url = rcx+1 .. closing paren
    lea rbx, [rcx + 1]
.p1_find_rp:
    cmp rbx, r13
    jae .p1_url_end
    cmp byte [r12 + rbx], ')'
    je  .p1_url_end
    mov al, [r12 + rbx]
    mov [rdi], al
    inc rdi
    inc rbx
    jmp .p1_find_rp
.p1_url_end:
    mov byte [rdi], '>'
    inc rdi
    lea r14, [rbx + 1]
    jmp .p1
.p1_copy:
    mov [rdi], al
    inc rdi
    inc r14
    jmp .p1
.p1_done:
    lea rax, [tmpa_buf]
    sub rdi, rax
    mov r13, rdi                    ; length after pass 1

    ; --- pass 2: **bold** -> B_ON bold B_OFF
    lea rdi, [tmpb_buf]
    lea r12, [tmpa_buf]
    xor r14, r14
.p2:
    cmp r14, r13
    jae .p2_done
    mov al, [r12 + r14]
    cmp al, '*'
    jne .p2_copy
    lea rcx, [r14 + 1]
    cmp rcx, r13
    jae .p2_copy
    cmp byte [r12 + rcx], '*'
    jne .p2_copy
    ; find the closing **
    lea rbx, [r14 + 2]
.p2_find:
    lea rcx, [rbx + 1]
    cmp rcx, r13
    jae .p2_copy
    cmp byte [r12 + rbx], '*'
    jne .p2_next
    cmp byte [r12 + rcx], '*'
    je  .p2_got
.p2_next:
    inc rbx
    jmp .p2_find
.p2_got:
    cmp rbx, r14
    jbe .p2_copy                    ; empty ****
    lea rsi, [r12 + r14 + 2]
    mov rdx, rbx
    sub rdx, r14
    sub rdx, 2
    call has_url
    jnz .p2_plain
    mov byte [rdi], B_ON
    inc rdi
    call copy_n
    mov byte [rdi], B_OFF
    inc rdi
    lea r14, [rbx + 2]
    jmp .p2
.p2_plain:                          ; a URL inside stays unstyled
    call copy_n
    lea r14, [rbx + 2]
    jmp .p2
.p2_copy:
    mov [rdi], al
    inc rdi
    inc r14
    jmp .p2
.p2_done:
    lea rax, [tmpb_buf]
    sub rdi, rax
    mov r13, rdi                    ; length after pass 2

    ; --- pass 3: *italic* -> I_ON italic I_OFF, bold sentinels pass through
    lea rdi, [tmpa_buf]
    lea r12, [tmpb_buf]
    xor r14, r14
.p3:
    cmp r14, r13
    jae .p3_done
    mov al, [r12 + r14]
    cmp al, B_OFF
    ja  .p3_notmark
    test al, al
    jz  .p3_notmark
    mov [rdi], al                   ; a style sentinel: copy through
    inc rdi
    inc r14
    jmp .p3
.p3_notmark:
    cmp al, '*'
    jne .p3_copy
    ; opener: previous byte must not be a word byte, next must not be a space
    test r14, r14
    jz  .p3_open_ok
    mov al, [r12 + r14 - 1]
    call is_word
    test eax, eax
    jnz  .p3_copy_star
.p3_open_ok:
    lea rcx, [r14 + 1]
    cmp rcx, r13
    jae .p3_copy_star
    mov al, [r12 + rcx]
    call is_space
    je  .p3_copy_star
    mov al, [r12 + rcx]
    cmp al, '*'
    je  .p3_copy_star               ; the body needs a character, and not a '*'
    ; find a closer: '*' not preceded by a space, not followed by a word byte
    mov rbx, rcx
.p3_find:
    cmp rbx, r13
    jae .p3_copy_star
    mov al, [r12 + rbx]
    cmp al, B_OFF
    jbe .p3_ran_into_style
    cmp al, '*'
    jne .p3_fnext
    mov al, [r12 + rbx - 1]
    call is_space
    je  .p3_fnext
    lea rcx, [rbx + 1]
    cmp rcx, r13
    jae .p3_got
    mov al, [r12 + rcx]
    call is_word
    test eax, eax
    jnz  .p3_fnext
    jmp .p3_got
.p3_fnext:
    inc rbx
    jmp .p3_find
.p3_ran_into_style:
    test al, al
    jz  .p3_fnext
    jmp .p3_copy_star               ; ran into a bold span
.p3_got:
    lea rsi, [r12 + r14 + 1]
    mov rdx, rbx
    sub rdx, r14
    dec rdx
    call has_url
    jnz .p3_plain
    mov byte [rdi], I_ON
    inc rdi
    call copy_n
    mov byte [rdi], I_OFF
    inc rdi
    lea r14, [rbx + 1]
    jmp .p3
.p3_plain:                          ; a URL inside stays unstyled
    call copy_n
    lea r14, [rbx + 1]
    jmp .p3
.p3_copy_star:
    mov al, '*'
.p3_copy:
    mov [rdi], al
    inc rdi
    inc r14
    jmp .p3
.p3_done:
    lea rax, [tmpa_buf]
    sub rdi, rax
    mov r13, rdi                    ; length after pass 3

    ; --- pass 4: _underline_ -> U_ON underline U_OFF
    mov rdi, r15
    lea r12, [tmpa_buf]
    xor r14, r14
.p4:
    cmp r14, r13
    jae .p4_done
    mov al, [r12 + r14]
    cmp al, '_'
    jne .p4_copy
    test r14, r14
    jz  .p4_open_ok
    mov al, [r12 + r14 - 1]
    call is_word
    test eax, eax
    jnz .p4_copy_us
.p4_open_ok:
    lea rcx, [r14 + 1]
    cmp rcx, r13
    jae .p4_copy_us
    mov al, [r12 + rcx]
    call is_space
    je  .p4_copy_us
    mov rbx, rcx
.p4_find:
    cmp rbx, r13
    jae .p4_copy_us
    mov al, [r12 + rbx]
    cmp al, '_'
    jne .p4_fnext
    mov al, [r12 + rbx - 1]
    call is_space
    je  .p4_fnext
    lea rcx, [rbx + 1]
    cmp rcx, r13
    jae .p4_got
    mov al, [r12 + rcx]
    call is_word
    test eax, eax
    jnz .p4_fnext
    jmp .p4_got
.p4_fnext:
    inc rbx
    jmp .p4_find
.p4_got:
    mov byte [rdi], U_ON
    inc rdi
    lea rsi, [r12 + r14 + 1]
    mov rdx, rbx
    sub rdx, r14
    dec rdx
    call copy_n
    mov byte [rdi], U_OFF
    inc rdi
    lea r14, [rbx + 1]
    jmp .p4
.p4_copy_us:
    mov al, '_'
.p4_copy:
    mov [rdi], al
    inc rdi
    inc r14
    jmp .p4
.p4_done:
    mov rax, rdi
    sub rax, r15
    cmp qword [tr_trim], 0
    je  .out                        ; a code-span segment is trimmed by the
    ; trim trailing spaces          ; driver once, over the joined result
.trim_r:
    test rax, rax
    jz  .trim_l
    mov cl, [r15 + rax - 1]
    cmp cl, ' '
    je  .trim_r_do
    cmp cl, 9
    jne .trim_l
.trim_r_do:
    dec rax
    jmp .trim_r
.trim_l:
    xor rcx, rcx
.trim_l_scan:
    cmp rcx, rax
    jae .trim_l_done
    mov dl, [r15 + rcx]
    cmp dl, ' '
    je  .trim_l_next
    cmp dl, 9
    jne .trim_l_done
.trim_l_next:
    inc rcx
    jmp .trim_l_scan
.trim_l_done:
    test rcx, rcx
    jz  .out
    sub rax, rcx
    push rax
    mov rdi, r15
    lea rsi, [r15 + rcx]
    mov rdx, rax
    call copy_n
    pop rax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; apply_cond — rewrite "If X, then Y" in place as "[? X] Y".
; Brackets are Qualifiers in HyperList, and a leading If is the one construct a
; mechanical pass can spot without guessing at intent. The condition is capped
; at 120 bytes so an ordinary long sentence that merely contains a comma is
; left alone.
;   rsi = buffer, rdx = length -> rax = new length (rewritten in place)
apply_cond:
    push rbx
    push r12
    push r13
    push r14
    mov rax, rdx                    ; default: unchanged
    cmp rdx, 7
    jl  .out
    cmp byte [rsi], 'I'
    jne .out
    cmp byte [rsi + 1], 'f'
    jne .out
    cmp byte [rsi + 2], ' '
    jne .out
    ; first ", "
    mov rcx, 3
.find:
    lea rbx, [rcx + 1]
    cmp rbx, rdx
    jae .out
    cmp byte [rsi + rcx], ','
    jne .fnext
    cmp byte [rsi + rcx + 1], ' '
    je  .found
.fnext:
    inc rcx
    jmp .find
.found:
    mov r12, rcx
    sub r12, 3                      ; condition length
    test r12, r12
    jz  .out
    cmp r12, 120
    ja  .out
    lea r13, [rcx + 2]              ; start of the remainder
.skip_sp:
    cmp r13, rdx
    jae .out
    cmp byte [rsi + r13], ' '
    jne .chk_then
    inc r13
    jmp .skip_sp
.chk_then:
    ; drop a leading "then " so the qualifier reads cleanly
    lea rbx, [r13 + 5]
    cmp rbx, rdx
    ja  .no_then
    push rsi
    push rdx
    lea rdi, [rsi + r13]
    lea rsi, [then_str]
    mov edx, 5
    call memcmp_n
    pop rdx
    pop rsi
    test eax, eax
    jnz .no_then
    add r13, 5
.no_then:
    mov r14, rdx
    sub r14, r13                    ; remainder length
    jbe .out
    ; build "[? " + cond + "] " + rest in tmpa_buf (free after inline_tr)
    lea rdi, [tmpa_buf]
    push rsi
    lea rsi, [cond_open]
    mov rdx, 3
    call copy_n
    pop rsi
    push rsi
    add rsi, 3                      ; condition starts after "If "
    mov rdx, r12
    call copy_n
    pop rsi
    push rsi
    lea rsi, [cond_close]
    mov rdx, 2
    call copy_n
    pop rsi
    push rsi
    add rsi, r13
    mov rdx, r14
    call copy_n
    pop rsi
    lea rax, [tmpa_buf]
    sub rdi, rax                    ; rdi = assembled length
    mov r12, rdi                    ; condition length is finished with
    mov rdi, rsi                    ; dst = the caller's buffer
    lea rsi, [tmpa_buf]
    mov rdx, r12
    call copy_n
    mov rax, r12
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rdi = dst, rsi = src, rdx = len. Advances rdi. Preserves rax.
; has_url — rsi = text, rdx = length. ZF clear when it holds "://".
; Claude Code turns a URL into a link and takes a style code glued to its
; end into the link, so "**https://x/**" showed as "...x/[22m". Bold and
; italic spans with a URL are left unstyled. Keeps rsi and rdx.
has_url:
    push rcx
    xor eax, eax
    xor ecx, ecx
.hu_loop:
    lea r8, [rcx + 3]
    cmp r8, rdx
    ja  .hu_ret
    cmp byte [rsi + rcx], ':'
    jne .hu_next
    cmp word [rsi + rcx + 1], '//'
    je  .hu_yes
.hu_next:
    inc rcx
    jmp .hu_loop
.hu_yes:
    inc eax
.hu_ret:
    pop rcx
    test eax, eax
    ret

copy_n:
    push rax
    test rdx, rdx
    jz  .done
.loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rdx
    jnz .loop
.done:
    pop rax
    ret

; ---------------------------------------------------------------------------
; convert — msg_buf/msg_len to out_buf.
convert:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov qword [para_len], 0
    mov qword [out_len], 0
    mov qword [item_count], 0
    mov qword [items_used], 0
    call read_hl_width
    cmp qword [delta_index], 0
    jne .resume
    mov qword [base_ind], 0         ; new message: start clean
    mov qword [kid_ind], 0
    mov qword [quote_ind], 0
    mov qword [last_ind1], 0
    mov qword [hoff], 0
    mov qword [enum_ind1], 0
    mov qword [enum_shift], 0
    mov qword [pbase_ind1], 0
    mov qword [prev_ind1], 0
    mov qword [dep_shift], 0
    mov qword [dep_origin], 0
    mov qword [shift_lvl], -1       ; shift not established until a heading
    mov qword [in_fence], 0
    mov qword [table_state], 0
    call scan_shift
    jmp .state_ready
.resume:
    cmp qword [state_loaded], 0
    jne .have_state                 ; carry_tail already read it: no second open
    call load_state                 ; keep the previous chunk's heading level
.have_state:
    call scan_shift                 ; a later chunk may hold a shallower heading
.state_ready:

    lea r12, [msg_buf]
    mov r13, [msg_len]
    xor r14, r14                    ; cursor
.next_line:
    cmp r14, r13
    jae .finish
    mov r15, r14                    ; line start
.find_eol:
    cmp r14, r13
    jae .have_line
    cmp byte [r12 + r14], 10
    je  .have_line
    inc r14
    jmp .find_eol
.have_line:
    mov rbx, r14                    ; line end (exclusive)
    cmp r14, r13
    jae .no_nl_adv
    inc r14                         ; step past the newline
.no_nl_adv:
    ; strip trailing CR and spaces
.rstrip:
    cmp rbx, r15
    jbe .stripped
    mov al, [r12 + rbx - 1]
    cmp al, 13
    je  .rstrip_do
    cmp al, ' '
    je  .rstrip_do
    cmp al, 9
    jne .stripped
.rstrip_do:
    dec rbx
    jmp .rstrip
.stripped:
    ; rsi = line ptr, rdx = line len for the handlers below
    lea rsi, [r12 + r15]
    mov rdx, rbx
    sub rdx, r15
    call handle_line
    jmp .next_line
.finish:
    call flush_para
    call render_items
    call save_state
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Find the shallowest heading level so the whole tree can shift left.
; Does not initialise shift_lvl: the caller sets -1 for a new message, and a
; resumed chunk carries the value forward. A chunk with no headings must leave
; it alone, or a heading in a later chunk lands one level too deep.
scan_shift:
    push rbx
    push r12
    push r13
    mov r12, 99                     ; running minimum
    lea rbx, [msg_buf]
    mov r13, [msg_len]
    xor rcx, rcx
.line:
    cmp rcx, r13
    jae .done
    ; rcx is at a line start
    xor edx, edx                    ; hash count
.count:
    cmp rcx, r13
    jae .skip_rest
    cmp byte [rbx + rcx], '#'
    jne .after_hashes
    inc rcx
    inc edx
    cmp edx, 7
    jl  .count
    jmp .skip_rest
.after_hashes:
    test edx, edx
    jz  .skip_rest
    cmp byte [rbx + rcx], ' '
    jne .skip_rest
    dec edx
    movsx rax, edx
    cmp rax, r12
    jge .skip_rest
    mov r12, rax
.skip_rest:
    cmp rcx, r13
    jae .done
    cmp byte [rbx + rcx], 10
    je  .eol
    inc rcx
    jmp .skip_rest
.eol:
    inc rcx
    jmp .line
.done:
    cmp r12, 99
    je  .no_headings                ; nothing here fixes the shift
    cmp qword [shift_lvl], 0
    jl  .take_it                    ; -1 = not established yet
    cmp r12, [shift_lvl]
    jge .no_headings                ; keep the shallower one
.take_it:
    mov [shift_lvl], r12
    jmp .no_headings
.no_headings:
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; handle_line — rsi = line, rdx = length (already right-stripped).
handle_line:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx

    ; --- fenced code
    call line_is_fence
    test eax, eax
    jz  .not_fence
    cmp qword [in_fence], 0
    jne .fence_close
    call flush_para
    ; A fence after a pure Property is that Property's content, not an
    ; example of anything: "regenerate with:" then the command. Promote the
    ; Property to parent (keeping one already in force) and skip EXAMPLE:.
    cmp qword [para_colon], 0
    je  .no_promote
    mov qword [kid_ind], 1
    mov qword [para_colon], 0
.no_promote:
    mov qword [in_fence], 1
    ; A tagged fence elsewhere holds sample code: label it EXAMPLE: and nest
    ; it under that. A bare fence is the answer held verbatim, unlabelled.
    ; A hyperlist-tagged fence IS a HyperList: mode 2, no label, at base.
    mov rax, [base_ind]
    cmp qword [fence_tag], 2
    jne .not_hl_fence
    mov qword [in_fence], 2
    jmp .fence_bare
.not_hl_fence:
    cmp qword [fence_tag], 0
    je  .fence_bare
    cmp qword [kid_ind], 0
    jne .fence_bare                 ; parented: the code IS the child
    inc rax
    mov [fence_ind], rax
    mov r8, [base_ind]
    add r8, [kid_ind]
    lea rsi, [code_str]
    mov rdx, code_len
    call note_item
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax
    jmp .ret
.fence_bare:
    mov [fence_ind], rax
    jmp .ret
.fence_close:
    mov qword [in_fence], 0
    jmp .ret
.not_fence:
    cmp qword [in_fence], 0
    je  .not_in_fence
    cmp qword [in_fence], 2
    je  .hl_line
    mov r8, [fence_ind]
    add r8, [kid_ind]
    mov rsi, r12
    mov rdx, r13
    mov qword [para_colon], 0       ; code is never a Property parent
    call emit_line_lit              ; verbatim, no inline transform, no wrap
    jmp .ret
.hl_line:
    ; HyperList fence content: one leading tab per level, colorized and
    ; wrapped like any Item. Blank lines contribute nothing.
    xor rcx, rcx
.hl_tabs:
    cmp rcx, r13
    jae .ret                        ; empty or all-tab line: no Item
    cmp byte [r12 + rcx], 9
    jne .hl_body
    inc rcx
    jmp .hl_tabs
.hl_body:
    mov rax, rcx
.hl_chk:
    cmp rax, r13
    jae .ret                        ; only blanks after the tabs: no Item
    mov dl, [r12 + rax]
    cmp dl, ' '
    je  .hl_chk_adv
    cmp dl, 9
    jne .hl_go
.hl_chk_adv:
    inc rax
    jmp .hl_chk
.hl_go:
    mov r8, [fence_ind]
    add r8, [kid_ind]
    add r8, rcx                     ; one level per leading tab
    lea rsi, [r12 + rcx]
    mov rdx, r13
    sub rdx, rcx
    call hl_boxes                   ; display the [_] checkbox as [ ]
    mov qword [para_colon], 0       ; fence content never parents
    call emit_line
    jmp .ret
.not_in_fence:

    ; --- blockquote: strip the marker, indent the quoted material one level.
    ; HyperList has no quote marker of its own; quoted text is a child of the
    ; Item that introduces it.
    xor rcx, rcx
.q_ws:
    cmp rcx, r13
    jae .not_quote
    mov al, [r12 + rcx]
    cmp al, ' '
    je  .q_adv
    cmp al, 9
    jne .q_check
.q_adv:
    inc rcx
    jmp .q_ws
.q_check:
    cmp al, '>'
    jne .not_quote
    inc rcx                         ; past the marker
    cmp rcx, r13
    jae .q_empty
    cmp byte [r12 + rcx], ' '
    jne .q_body
    inc rcx                         ; and the one space that may follow it
.q_body:
    mov [q_off], rcx                ; flush_para scribbles over rcx
    cmp qword [quote_ind], 0
    jne .q_open
    call flush_para
    call quote_level
.q_open:
    mov rcx, [q_off]
    mov rdx, r13
    sub rdx, rcx
    test rdx, rdx
    jz  .q_blank
    add r12, rcx                    ; para_append reads r12/r13, not rsi/rdx
    mov r13, rdx
    call para_append
    jmp .ret
.q_empty:
    cmp qword [quote_ind], 0
    jne .q_blank
    call flush_para
    call quote_level
.q_blank:
    call flush_para                 ; a bare ">" separates quoted paragraphs
    jmp .ret
.not_quote:
    cmp qword [quote_ind], 0
    je  .no_quote_end
    call flush_para
    mov qword [quote_ind], 0
.no_quote_end:

    ; --- blank line
    test r13, r13
    jnz .not_blank
    call end_block
    mov qword [table_state], 0
    jmp .ret
.not_blank:

    ; --- heading
    xor ecx, ecx
.h_count:
    cmp rcx, r13
    jae .not_heading
    cmp byte [r12 + rcx], '#'
    jne .h_after
    inc rcx
    cmp rcx, 7
    jl  .h_count
    jmp .not_heading
.h_after:
    test rcx, rcx
    jz  .not_heading
    cmp byte [r12 + rcx], ' '
    jne .not_heading
    mov r14, rcx                    ; hash count
    call flush_para
    cmp qword [kid_ind], 0
    je  .h_nokid
    inc qword [hoff]                ; the Property parents this whole section
    mov qword [kid_ind], 0
.h_nokid:
    mov qword [para_colon], 0
    mov qword [table_state], 0
    mov qword [enum_ind1], 0        ; a heading ends an enumerator's block
    mov qword [enum_shift], 0
    mov qword [pbase_ind1], 0       ; and any bold section head's reign
    inc r14                         ; skip the space
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    lea rdi, [line_buf]
    call inline_tr
    mov rdx, rax
    mov r8, r14
    dec r8                          ; hash count again
    dec r8                          ; level = hashes - 1
    mov rax, [shift_lvl]
    test rax, rax
    jns .h_have
    xor eax, eax                    ; -1 (unestablished) counts as 0
.h_have:
    sub r8, rax
    jns .h_ok
    xor r8, r8
.h_ok:
    add r8, [hoff]                  ; sibling headings stay level with each other
    lea rsi, [line_buf]
    call emit_line
    lea rax, [r8 + 1]
    mov [base_ind], rax
    mov [last_ind1], rax            ; encoded +1: the heading itself
    mov qword [para_colon], 0       ; same: a heading parents on its own
    jmp .ret
.not_heading:

    ; --- table row
    cmp byte [r12], '|'
    jne .not_table
    cmp r13, 2
    jl  .not_table
    cmp byte [r12 + r13 - 1], '|'
    jne .not_table
    call flush_para
    call table_is_separator
    test eax, eax
    jnz .ret                        ; the |---|---| rule
    cmp qword [table_state], 0
    jne .table_data
    ; header row: keep the inner content for the property names
    lea rdi, [hdr_buf]
    lea rsi, [r12 + 1]
    mov rdx, r13
    sub rdx, 2
    mov [hdr_len], rdx
    call copy_n
    mov qword [table_state], 1
    jmp .ret
.table_data:
    call emit_table_row
    jmp .ret
.not_table:
    mov qword [table_state], 0

    ; --- horizontal rule
    call line_is_rule
    test eax, eax
    jnz .ret

    ; --- bullet
    xor ecx, ecx
.b_ws:
    cmp rcx, r13
    jae .not_bullet
    mov al, [r12 + rcx]
    cmp al, ' '
    je  .b_ws_adv
    cmp al, 9
    jne .b_mark
.b_ws_adv:
    inc rcx
    jmp .b_ws
.b_mark:
    lea rdx, [rcx + 1]
    cmp rdx, r13
    jae .not_bullet
    cmp al, '-'
    je  .b_ok
    cmp al, '*'
    je  .b_ok
    cmp al, '+'
    jne .not_bullet
.b_ok:
    cmp byte [r12 + rdx], ' '
    jne .not_bullet
    mov r14, rcx                    ; leading whitespace count
    call attach_list
    lea rcx, [r14 + 2]              ; past marker and space
    lea rsi, [r12 + rcx]
    mov rdx, r13
    sub rdx, rcx
    lea rdi, [line_buf]
    call inline_tr
    lea rsi, [line_buf]
    mov rdx, rax
    call apply_cond
    mov rdx, rax
    mov rsi, r12
    mov rcx, r14
    call lead_cols                  ; r8 = leading columns, tabs expanded
    call nesting_depth
    add r8, [base_ind]
    add r8, [kid_ind]
    call apply_eshift
    lea rsi, [line_buf]
    call note_item
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax
    jmp .ret
.not_bullet:

    ; --- numbered item
    xor ecx, ecx
.n_ws:
    cmp rcx, r13
    jae .not_num
    mov al, [r12 + rcx]
    cmp al, ' '
    je  .n_ws_adv
    cmp al, 9
    jne .n_dig
.n_ws_adv:
    inc rcx
    jmp .n_ws
.n_dig:
    mov r14, rcx                    ; leading whitespace
    mov qword [num_bold], 0
    ; a bold-wrapped enumerator, "**1. Head**": the stars are not digits,
    ; and the bold reopens on the rest of the Item
    lea rax, [rcx + 2]
    cmp rax, r13
    ja  .n_nostar
    cmp byte [r12 + rcx], '*'
    jne .n_nostar
    cmp byte [r12 + rcx + 1], '*'
    jne .n_nostar
    add rcx, 2
    mov qword [num_bold], 1
.n_nostar:
    xor ebx, ebx                    ; digit count
.n_loop:
    cmp rcx, r13
    jae .not_num
    mov al, [r12 + rcx]
    cmp al, '0'
    jb  .n_after
    cmp al, '9'
    ja  .n_after
    inc rcx
    inc ebx
    jmp .n_loop
.n_after:
    test ebx, ebx
    jz  .not_num
    cmp al, '.'
    je  .n_sep
    cmp al, ')'
    jne .not_num
.n_sep:
    lea rdx, [rcx + 1]
    cmp rdx, r13
    jae .not_num
    cmp byte [r12 + rdx], ' '
    jne .not_num
    push rcx                        ; flush_para scribbles over rcx
    call attach_list
    pop rcx
    ; digits, then ". ", then the inline-transformed rest
    lea rdi, [line_buf]
    mov rax, [num_bold]
    add rax, rax                    ; skip the two stars before the digits
    add rax, r14
    lea rsi, [r12 + rax]
    mov rdx, rcx
    sub rdx, rax                    ; digits only
    call copy_n
    mov byte [rdi], '.'
    mov byte [rdi + 1], ' '
    add rdi, 2
    push rdi
    lea rsi, [r12 + rcx + 2]
    mov rdx, r13
    sub rdx, rcx
    sub rdx, 2
    cmp qword [num_bold], 0
    je  .n_plain
    ; reopen the bold: "**" + rest, staged so inline_tr sees one span
    mov byte [line2_buf], '*'
    mov byte [line2_buf + 1], '*'
    push rdx
    lea rdi, [line2_buf + 2]
    call copy_n
    pop rdx
    add rdx, 2
    lea rsi, [line2_buf]
.n_plain:
    lea rdi, [line3_buf]
    call inline_tr
    pop rdi
    lea rsi, [line3_buf]
    mov rdx, rax
    call copy_n
    lea rax, [line_buf]
    mov rdx, rdi
    sub rdx, rax
    mov rsi, r12
    mov rcx, r14
    call lead_cols                  ; r8 = leading columns, tabs expanded
    call nesting_depth
    add r8, [base_ind]
    add r8, [kid_ind]
    lea rsi, [line_buf]
    call note_item
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax
    ; the enumerator parents whatever block content follows it
    mov [enum_ind1], rax
    mov qword [enum_shift], 0
    jmp .ret
.not_num:

    ; --- a line that is entirely bold is a section head: Claude uses these
    ; as headings, so it parents everything until the next head. Unlike the
    ; enumerator rule this survives blank lines, as a real heading's base does.
    xor ecx, ecx
.bh_ws:                             ; stripped start
    cmp rcx, r13
    jae .not_bold_head
    mov al, [r12 + rcx]
    cmp al, ' '
    je  .bh_adv
    cmp al, 9
    jne .bh_start
.bh_adv:
    inc rcx
    jmp .bh_ws
.bh_start:
    mov r14, rcx
    mov rbx, r13                    ; stripped end, exclusive
.bh_rws:
    cmp rbx, r14
    jbe .not_bold_head
    mov al, [r12 + rbx - 1]
    cmp al, ' '
    je  .bh_radv
    cmp al, 9
    jne .bh_have
.bh_radv:
    dec rbx
    jmp .bh_rws
.bh_have:
    mov rax, rbx
    sub rax, r14
    cmp rax, 5                      ; "**x**" is the shortest head
    jb  .not_bold_head
    cmp byte [r12 + r14], '*'
    jne .not_bold_head
    cmp byte [r12 + r14 + 1], '*'
    jne .not_bold_head
    cmp byte [r12 + rbx - 1], '*'
    jne .not_bold_head
    cmp byte [r12 + rbx - 2], '*'
    jne .not_bold_head
    ; no stars inside, and something visible between the markers
    lea rcx, [r14 + 2]
    lea rdx, [rbx - 2]
    xor eax, eax                    ; saw a non-blank inner byte
.bh_mid:
    cmp rcx, rdx
    jae .bh_mid_done
    mov r8b, [r12 + rcx]
    cmp r8b, '*'
    je  .not_bold_head
    cmp r8b, ' '
    je  .bh_mid_adv
    cmp r8b, 9
    je  .bh_mid_adv
    mov eax, 1
.bh_mid_adv:
    inc rcx
    jmp .bh_mid
.bh_mid_done:
    test eax, eax
    jz  .not_bold_head
    call flush_para
    mov rax, [pbase_ind1]           ; pop back to the previous head's level
    test rax, rax
    jz  .bh_nopop
    dec rax
    mov [base_ind], rax
.bh_nopop:
    mov qword [kid_ind], 0
    mov qword [para_colon], 0
    mov qword [enum_ind1], 0
    mov qword [enum_shift], 0
    mov qword [table_state], 0
    lea rsi, [r12 + r14]
    mov rdx, rbx
    sub rdx, r14
    lea rdi, [line_buf]
    call inline_tr
    mov rdx, rax
    mov r8, [base_ind]
    lea rsi, [line_buf]
    call note_item
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax
    mov [pbase_ind1], rax           ; heads sit at this level from now on
    mov [base_ind], rax             ; and their block one level under
    mov qword [para_colon], 0       ; note_item may have seen a trailing
                                    ; colon; the head already parents
    jmp .ret
.not_bold_head:

    ; --- ordinary prose: each line is its own Item source. Claude writes
    ; one idea per line, so joining lines would merge deliberate Items, and
    ; the join would depend on where the delta boundaries fall. Only
    ; blockquotes still accumulate; a quoted passage is one Item.
    call flush_para
    call para_append
.ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; r8 = indent after the kid offset. A numbered item parents the block that
; follows it: content no deeper than the enumerator engages a lift to one
; level under it, and the lift holds until a blank line, a heading or the
; next enumerator. Content already deeper carries its own structure.
apply_eshift:
    push rax
    mov rax, [enum_ind1]
    test rax, rax
    jz  .ret
    cmp qword [enum_shift], 0
    jne .add
    cmp r8, rax
    jae .add                        ; not shallower: engages nothing
    sub rax, r8
    mov [enum_shift], rax
.add:
    add r8, [enum_shift]
.ret:
    pop rax
    ret

; r8 = leading spaces -> r8 = nesting level. Markdown nests lists with either
; two or four spaces per level; a multiple of four is read as four-space style
; so both conventions give one HyperList level per nesting level.
; Leading whitespace as columns: rsi = line, rcx = count of leading
; whitespace bytes. A tab advances to the next multiple of 4, as python's
; expandtabs(4) does, so a tab-indented child bullet is one level deeper
; and not, at one byte, a depth of zero. Returns r8; clobbers rax, r9.
; Preserves rdx/rdi and the callee-saved registers the callers rely on.
lead_cols:
    xor r8d, r8d
    xor r9d, r9d                    ; byte index
.lc_loop:
    cmp r9, rcx
    jae .lc_done
    mov al, [rsi + r9]
    inc r9
    cmp al, 9
    jne .lc_space
    or  r8, 3                       ; up to the next multiple of 4
    inc r8
    jmp .lc_loop
.lc_space:
    inc r8
    jmp .lc_loop
.lc_done:
    ret

nesting_depth:
    test r8, r8
    jz  .ret
    test r8, 3
    jnz .by_two
    shr r8, 2
    ret
.by_two:
    shr r8, 1
.ret:
    ret

; r12/r13 = line. eax = 1 when the line opens or closes a code fence.
; Also sets fence_tag to 1 when anything but whitespace follows the backticks,
; i.e. the fence carries a language tag and so holds sample code.
line_is_fence:
    push rcx
    push rdx
    xor ecx, ecx
.ws:
    cmp rcx, r13
    jae .no
    mov al, [r12 + rcx]
    cmp al, ' '
    je  .adv
    cmp al, 9
    jne .check
.adv:
    inc rcx
    jmp .ws
.check:
    lea rax, [rcx + 2]
    cmp rax, r13
    jae .no
    cmp byte [r12 + rcx], '`'
    jne .no
    cmp byte [r12 + rcx + 1], '`'
    jne .no
    cmp byte [r12 + rcx + 2], '`'
    jne .no
    ; scan past the backticks for a non-blank: that is the language tag
    add rcx, 3
    mov qword [fence_tag], 0
.tag:
    cmp rcx, r13
    jae .done
    mov dl, [r12 + rcx]
    cmp dl, ' '
    je  .tag_adv
    cmp dl, 9
    je  .tag_adv
    mov qword [fence_tag], 1
    ; the exact tag "hyperlist" (then end or blank) marks HyperList content,
    ; fence_tag = 2: rendered as real Items rather than labelled EXAMPLE:
    lea rax, [rcx + hl_tag_len]
    cmp rax, r13
    ja  .done
    push rbx
    lea rax, [r12 + rcx]
    xor ebx, ebx
.hlt_cmp:
    cmp rbx, hl_tag_len
    je  .hlt_end
    mov dl, [rax + rbx]
    cmp dl, [hl_tag + rbx]
    jne .hlt_no
    inc rbx
    jmp .hlt_cmp
.hlt_end:
    lea rax, [rcx + hl_tag_len]
    cmp rax, r13
    je  .hlt_yes                    ; the tag ends the line
    mov dl, [r12 + rcx + hl_tag_len]
    cmp dl, ' '
    je  .hlt_yes
    cmp dl, 9
    jne .hlt_no
.hlt_yes:
    mov qword [fence_tag], 2
.hlt_no:
    pop rbx
    jmp .done
.tag_adv:
    inc rcx
    jmp .tag
.done:
    mov eax, 1
    pop rdx
    pop rcx
    ret
.no:
    xor eax, eax
    pop rdx
    pop rcx
    ret

; rsi/rdx = text. Replaces every "[_]" with "[ ]" in place: the terminal's
; own markdown pass would pair the bare underscores across lines, eating
; them and italicising everything between.
hl_boxes:
    push rcx
    xor rcx, rcx
.scan:
    lea rax, [rcx + 2]
    cmp rax, rdx
    jae .out
    cmp byte [rsi + rcx], '['
    jne .adv
    cmp byte [rsi + rcx + 1], '_'
    jne .adv
    cmp byte [rsi + rcx + 2], ']'
    jne .adv
    mov byte [rsi + rcx + 1], ' '
    add rcx, 3
    jmp .scan
.adv:
    inc rcx
    jmp .scan
.out:
    pop rcx
    ret

; eax = 1 when the line is --- / === / ___ (three or more, nothing else).
line_is_rule:
    push rcx
    push rdx
    cmp r13, 3
    jl  .no
    mov dl, [r12]
    cmp dl, '-'
    je  .scan
    cmp dl, '='
    je  .scan
    cmp dl, '_'
    jne .no
.scan:
    xor ecx, ecx
.loop:
    cmp rcx, r13
    jae .yes
    cmp [r12 + rcx], dl
    jne .no
    inc rcx
    jmp .loop
.yes:
    mov eax, 1
    pop rdx
    pop rcx
    ret
.no:
    xor eax, eax
    pop rdx
    pop rcx
    ret

; eax = 1 when the table row is the |---|:--:| rule.
table_is_separator:
    push rcx
    xor ecx, ecx
.loop:
    cmp rcx, r13
    jae .yes
    mov al, [r12 + rcx]
    inc rcx
    cmp al, '|'
    je  .loop
    cmp al, '-'
    je  .loop
    cmp al, ':'
    je  .loop
    cmp al, ' '
    je  .loop
    cmp al, 9
    je  .loop
    xor eax, eax
    pop rcx
    ret
.yes:
    mov eax, 1
    pop rcx
    ret

; Split a row on '|'. rdi = cursor variable holding the offset into the
; buffer, rsi = buffer, rdx = length. Returns rax = cell ptr, rcx = cell len,
; and advances the cursor. Sets rax = 0 when the row is exhausted.
next_cell:
    push r8
    push r9
    mov r8, [rdi]
    cmp r8, rdx
    jae .none
    mov r9, r8                      ; cell start
.scan:
    cmp r8, rdx
    jae .end
    cmp byte [rsi + r8], '|'
    je  .end
    inc r8
    jmp .scan
.end:
    mov rcx, r8
    sub rcx, r9
    lea rax, [rsi + r9]
    inc r8                          ; step past the separator
    mov [rdi], r8
    ; trim
.triml:
    test rcx, rcx
    jz  .done
    mov dl, [rax]
    cmp dl, ' '
    je  .triml_do
    cmp dl, 9
    jne .trimr
.triml_do:
    inc rax
    dec rcx
    jmp .triml
.trimr:
    test rcx, rcx
    jz  .done
    mov dl, [rax + rcx - 1]
    cmp dl, ' '
    je  .trimr_do
    cmp dl, 9
    jne .done
.trimr_do:
    dec rcx
    jmp .trimr
.done:
    pop r9
    pop r8
    ret
.none:
    xor eax, eax
    xor ecx, ecx
    pop r9
    pop r8
    ret

; Emit a table data row: first cell becomes the item, the rest become
; "Header: value" Properties one level deeper.
emit_table_row:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov qword [rsp], 0              ; row cursor
    mov qword [rsp + 8], 0          ; header cursor

    ; row inner content: skip the leading and trailing '|'
    lea r14, [r12 + 1]
    mov r15, r13
    sub r15, 2

    ; first cell -> the item line
    mov rdi, rsp
    mov rsi, r14
    mov rdx, r15
    call next_cell
    test rax, rax
    jz  .done
    mov rsi, rax
    mov rdx, rcx
    lea rdi, [line_buf]
    call inline_tr
    mov rdx, rax
    mov r8, [base_ind]
    add r8, [kid_ind]
    call apply_eshift
    lea rsi, [line_buf]
    call note_item
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax

    ; header's first cell is consumed to stay in step
    lea rdi, [rsp + 8]
    lea rsi, [hdr_buf]
    mov rdx, [hdr_len]
    call next_cell

.pair:
    lea rdi, [rsp + 8]
    lea rsi, [hdr_buf]
    mov rdx, [hdr_len]
    call next_cell
    mov r13, rax                    ; header cell ptr (0 when exhausted)
    mov rbx, rcx                    ; header cell len

    mov rdi, rsp
    mov rsi, r14
    mov rdx, r15
    call next_cell
    test rax, rax
    jz  .done
    test rcx, rcx
    jz  .pair                       ; empty value: skip the property
    ; value
    mov rsi, rax
    mov rdx, rcx
    lea rdi, [line3_buf]
    call inline_tr
    mov r12, rax                    ; value length
    ; header
    test r13, r13
    jz  .no_hdr
    mov rsi, r13
    mov rdx, rbx
    lea rdi, [line2_buf]
    call inline_tr
    mov rbx, rax
    jmp .build
.no_hdr:
    xor ebx, ebx
.build:
    lea rdi, [line_buf]
    lea rsi, [line2_buf]
    mov rdx, rbx
    call copy_n
    lea rsi, [colon_sp]
    mov rdx, 2
    call copy_n
    lea rsi, [line3_buf]
    mov rdx, r12
    call copy_n
    lea rax, [line_buf]
    mov rdx, rdi
    sub rdx, rax
    mov r8, [base_ind]
    inc r8
    add r8, [kid_ind]
    call apply_eshift
    lea rsi, [line_buf]
    call note_item
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax
    jmp .pair
.done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; Paragraph accumulation. Lines join with a single space; the flush splits the
; result into one item per sentence, which is closer to HyperList than one
; item per paragraph.

; rsi/rdx from handle_line (r12/r13 hold the same).
para_append:
    push rcx
    push rdi
    push rsi
    push r8
    mov rcx, [para_len]
    test rcx, rcx
    jnz .lvl_have
    ; Paragraph start: its own indentation carries its depth, exactly as a
    ; bullet's does. A paragraph indented under a list item is that item's
    ; content. Column count with tabs expanding to the next multiple of 4.
    xor edi, edi
    xor r8d, r8d
.lvl_ws:
    cmp rdi, r13
    jae .lvl_done
    mov al, [r12 + rdi]
    cmp al, ' '
    je  .lvl_sp
    cmp al, 9
    jne .lvl_done
    and r8, -4
    add r8, 4
    inc rdi
    jmp .lvl_ws
.lvl_sp:
    inc r8
    inc rdi
    jmp .lvl_ws
.lvl_done:
    call nesting_depth
    mov [para_lvl], r8
.lvl_have:
    pop r8
    mov rcx, [para_len]
    test rcx, rcx
    jz  .no_space
    cmp rcx, PARA_MAX - 2
    jae .full
    mov byte [para_buf + rcx], ' '
    inc rcx
.no_space:
    ; left-trim the incoming line
    xor rdi, rdi
.ltrim:
    cmp rdi, r13
    jae .copy_done
    mov al, [r12 + rdi]
    cmp al, ' '
    je  .ltrim_adv
    cmp al, 9
    jne .copy
.ltrim_adv:
    inc rdi
    jmp .ltrim
.copy:
    cmp rdi, r13
    jae .copy_done
    cmp rcx, PARA_MAX - 2
    jae .copy_done
    mov al, [r12 + rdi]
    mov [para_buf + rcx], al
    inc rcx
    inc rdi
    jmp .copy
.copy_done:
    mov [para_len], rcx
.full:
    pop rsi
    pop rdi
    pop rcx
    ret




; Set quote_ind to (level of the quoted material)+1: one level under the last
; emitted item, or base itself when the quote opens the message.
quote_level:
    mov rax, [last_ind1]
    test rax, rax
    jnz .have
    mov rax, [base_ind]
    inc rax
    mov [quote_ind], rax
    ret
.have:
    inc rax                         ; last_ind+1, stored +1
    mov [quote_ind], rax
    ret

; r12 = para_buf, rbx = index of sentence punctuation. eax = 1 when it closes
; a bare enumerator like "1." or "**3." — an Identifier-to-be, not a sentence
; end. Splitting there would orphan the number from its Item.
bare_number_at:
    push rcx
    push rdx
    cmp byte [r12 + rbx], '.'
    jne .no
    mov rcx, rbx
    xor edx, edx                    ; digits seen
.dig:
    test rcx, rcx
    jz  .end_run
    mov al, [r12 + rcx - 1]
    cmp al, '0'
    jb  .end_run
    cmp al, '9'
    ja  .end_run
    inc edx
    dec rcx
    jmp .dig
.end_run:
    test edx, edx
    jz  .no
.stars:
    test rcx, rcx
    jz  .yes
    mov al, [r12 + rcx - 1]
    cmp al, '*'
    jne .edge
    dec rcx
    jmp .stars
.edge:
    cmp al, ' '
    je  .yes
    cmp al, 9
    je  .yes
.no:
    xor eax, eax
    pop rdx
    pop rcx
    ret
.yes:
    mov eax, 1
    pop rdx
    pop rcx
    ret

; r12 = para_buf, rbx = index. eax = 1 when an odd number of double quotes
; precede it, i.e. the index sits inside an open quotation.
quote_parity:
    push rcx
    push rdx
    xor eax, eax
    xor rcx, rcx
.l:
    cmp rcx, rbx
    jae .d
    mov dl, [r12 + rcx]
    cmp dl, '"'
    jne .n
    xor eax, 1
.n:
    inc rcx
    jmp .l
.d:
    pop rdx
    pop rcx
    ret

; rsi/rdx = an Item about to be emitted. Counts it and remembers whether its
; visible text ends in a colon, style sentinels being invisible.
note_item:
    push rax
    push rcx
    mov qword [para_colon], 0
    mov rcx, rdx
.back:
    test rcx, rcx
    jz  .out
    dec rcx
    mov al, [rsi + rcx]
    call is_sentinel_al
    test eax, eax
    jnz .back
    mov al, [rsi + rcx]
    cmp al, ':'
    jne .out
    mov qword [para_colon], 1
.out:
    pop rcx
    pop rax
    ret


; A pure Property, "What went:", is a parent in HyperList: it names what
; follows and cannot stand childless. Markdown gives it no nesting, so when a
; block ends on one the next block is indented under it, whether that block is
; a paragraph or a list. Scope is one block, which stops the rule swallowing
; the rest of the answer.
end_block:
    call flush_para
    mov qword [kid_ind], 0
    cmp qword [para_colon], 0
    je  .reset
    mov qword [kid_ind], 1
.reset:
    mov qword [para_colon], 0
    mov qword [enum_ind1], 0        ; a blank line ends an enumerator's block
    mov qword [enum_shift], 0
    ret

; A list that follows a prose line with no blank line between is that
; line's content: "Two paths:" or "Recommendation: X." and then the
; bullets. Markdown leaves them level; HyperList puts the list one level
; under the line that introduced it. A blank line breaks the attachment
; (end_block then decides on the colon alone), so one intro never
; swallows every list after it. Called by the bullet and numbered
; branches in place of flush_para. Preserves what flush_para preserves.
attach_list:
    push rbx
    mov rbx, [para_len]             ; was a paragraph pending?
    call flush_para
    test rbx, rbx
    jz  .al_done
    inc qword [kid_ind]
    mov qword [para_colon], 0
.al_done:
    pop rbx
    ret

flush_para:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r13, [para_len]
    test r13, r13
    jz  .empty                      ; no paragraph: the parent flag stands
    mov qword [para_len], 0
    lea r12, [para_buf]
    ; Quoted material carries visible quotation marks (unless already
    ; quoted); the splitter then keeps the whole passage as one opaque Item.
    cmp qword [quote_ind], 0
    je  .no_wrap
    cmp r13, 2
    jb  .do_wrap
    cmp byte [r12], '"'
    jne .do_wrap
    cmp byte [r12 + r13 - 1], '"'
    je  .no_wrap
.do_wrap:
    lea rax, [r13 + 2]
    cmp rax, PARA_MAX
    ja  .no_wrap
    mov rcx, r13
.shift_q:
    test rcx, rcx
    jz  .shifted_q
    mov al, [r12 + rcx - 1]
    mov [r12 + rcx], al
    dec rcx
    jmp .shift_q
.shifted_q:
    mov byte [r12], '"'
    mov byte [r12 + r13 + 1], '"'
    add r13, 2
.no_wrap:
    xor r14, r14                    ; sentence start
    xor rbx, rbx                    ; cursor
.scan:
    cmp rbx, r13
    jae .last
    mov al, [r12 + rbx]
    cmp al, '.'
    je  .cand
    cmp al, '!'
    je  .cand
    cmp al, '?'
    je  .cand
    inc rbx
    jmp .scan
.cand:
    call bare_number_at             ; "1." is an Identifier-to-be, not an end
    test eax, eax
    jnz .no_split
    ; optional closing quote or bracket, then whitespace, then upper/digit
    mov [sent_end], rbx             ; punctuation is the last char by default
    lea rcx, [rbx + 1]
    cmp rcx, r13
    jae .last
    mov al, [r12 + rcx]
    cmp al, '"'
    je  .cand_skip
    cmp al, 0x27
    je  .cand_skip
    cmp al, ')'
    je  .cand_skip
    cmp al, ']'
    je  .cand_skip
    jmp .cand_ws
.cand_skip:
    mov [sent_end], rcx             ; the quote belongs to this sentence, not the next
    inc rcx
    cmp rcx, r13
    jae .last
.cand_ws:
    ; Never split inside an open quotation. Parity is judged after the
    ; sentence end, so a closing quote that wraps the punctuation counts.
    push rbx
    push rcx
    mov rbx, [sent_end]
    inc rbx
    call quote_parity
    pop rcx
    pop rbx
    test eax, eax
    jnz .no_split
    mov al, [r12 + rcx]
    cmp al, ' '
    jne .no_split
.eat_ws:
    inc rcx
    cmp rcx, r13
    jae .last
    mov al, [r12 + rcx]
    cmp al, ' '
    je  .eat_ws
    ; next must start a new sentence, which an opening quote or bracket may
    ; precede: 'He left. "Fine," she said.' is two sentences
    cmp al, '"'
    je  .open_skip
    cmp al, 0x27
    je  .open_skip
    cmp al, '('
    je  .open_skip
    cmp al, '['
    je  .open_skip
    jmp .cap_test
.open_skip:
    lea rdx, [rcx + 1]
    cmp rdx, r13
    jae .no_split
    mov al, [r12 + rdx]
.cap_test:
    cmp al, 'A'
    jb  .maybe_digit
    cmp al, 'Z'
    jbe .check_abbrev
.maybe_digit:
    cmp al, '0'
    jb  .no_split
    cmp al, '9'
    ja  .no_split
.check_abbrev:
    mov r15, rcx                    ; remember where the next sentence starts
    call ends_with_abbrev           ; rbx = punctuation index
    test eax, eax
    jnz .no_split
    ; emit para_buf[r14 .. rbx] inclusive of the punctuation
    lea rsi, [r12 + r14]
    mov rdx, [sent_end]
    inc rdx
    sub rdx, r14
    lea rdi, [line_buf]
    call inline_tr
    test rax, rax
    jz  .after_emit
    lea rsi, [line_buf]
    mov rdx, rax
    call apply_cond
    mov rdx, rax
    lea rsi, [line_buf]
    call note_item
    mov r8, [quote_ind]
    test r8, r8
    jz  .q_fp1
    dec r8                          ; quoted: absolute level, no kid
    mov qword [para_colon], 0       ; quoted text never parents
    jmp .g_fp1
.q_fp1:
    mov r8, [base_ind]
    add r8, [kid_ind]
    add r8, [para_lvl]
    call apply_eshift
.g_fp1:
    lea rsi, [line_buf]
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax
.after_emit:
    mov r14, r15
    mov rbx, r15
    jmp .scan
.no_split:
    inc rbx
    jmp .scan
.last:
    cmp r14, r13
    jae .ret
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    lea rdi, [line_buf]
    call inline_tr
    test rax, rax
    jz  .ret
    lea rsi, [line_buf]
    mov rdx, rax
    call apply_cond
    mov rdx, rax
    lea rsi, [line_buf]
    call note_item
    mov r8, [quote_ind]
    test r8, r8
    jz  .q_fp2
    dec r8                          ; quoted: absolute level, no kid
    mov qword [para_colon], 0       ; quoted text never parents
    jmp .g_fp2
.q_fp2:
    mov r8, [base_ind]
    add r8, [kid_ind]
    add r8, [para_lvl]
    call apply_eshift
.g_fp2:
    lea rsi, [line_buf]
    call emit_line
    lea rax, [r8 + 1]
    mov [last_ind1], rax
.ret:
.empty:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rbx = index of the punctuation in para_buf, r12 = para_buf.
; eax = 1 when the text ending there is a known abbreviation.
ends_with_abbrev:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [abbrevs]
.entry:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz  .no
    inc rsi                         ; rsi -> the bytes
    ; the entry must fit before rbx+1
    lea rdx, [rbx + 1]
    cmp rdx, rcx
    jb  .next
    sub rdx, rcx                    ; start offset in para_buf
    lea rdi, [r12 + rdx]
    push rsi
    push rcx
    mov edx, ecx
    call memcmp_n
    pop rcx
    pop rsi
    test eax, eax
    jz  .yes
.next:
    add rsi, rcx
    jmp .entry
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret


; ---------------------------------------------------------------------------
; rsi/rdx = Item text. Paints the HyperList element classes into color_buf and
; returns rsi/rdx pointing at it. Character classes follow hyperlist.vim, the
; authoritative syntax. Two deliberate departures, both because an Item here
; is a whole line rather than a buffer region: the colon of an Operator or
; Property may be followed by end-of-item as well as whitespace, and a
; Property is only recognised at the start of an Item, since vim's mid-line
; rule would paint most prose red.
;
; r12 = input ptr, r13 = input len, r14 = read cursor, r15 = scratch.
colorize_buf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    mov r13, rdx
    mov qword [color_len], 0
    xor r14, r14

    ; An Item that opens with a quotation is quoted material: nothing inside
    ; it is an Operator, Identifier or Property of THIS list, so the head
    ; scans are skipped and the pair rule below paints the quote cyan.
    xor rcx, rcx
.qh_scan:
    cmp rcx, r13
    jae .qh_no
    mov al, [r12 + rcx]
    call is_sentinel_al
    test eax, eax
    jz  .qh_chk
    inc rcx
    jmp .qh_scan
.qh_chk:
    mov al, [r12 + rcx]
    cmp al, '"'
    je  .head_done
.qh_no:

    ; --- Operator: two or more of [A-Z_-() /] or non-ASCII, then ':'
    xor rcx, rcx
    xor r15, r15                    ; class members seen, sentinels excluded
.op_scan:
    cmp rcx, r13
    jae .op_fail
    mov al, [r12 + rcx]
    call is_sentinel_al             ; style markers are invisible: skip them
    test eax, eax
    jnz .op_adv
    mov al, [r12 + rcx]
    cmp al, ':'
    je  .op_colon
    call is_upper_al
    test eax, eax
    jnz .op_member
    mov al, [r12 + rcx]
    lea rsi, [cls_oper]
    mov edx, cls_oper_len
    call in_class
    test eax, eax
    jz  .op_fail
.op_member:
    inc r15
.op_adv:
    inc rcx
    jmp .op_scan
.op_colon:
    cmp r15, 2
    jb  .op_fail
    call after_colon                ; rcx = colon index
    test eax, eax
    jz  .op_fail
    mov al, C_BLU
    call cb_put
    lea r14, [rcx + 1]
    call copy_head
    jmp .head_done
.op_fail:

    ; --- Identifier: digits and dots only, then whitespace
    xor rcx, rcx
    xor r15, r15
.id_scan:
    cmp rcx, r13
    jae .id_fail
    mov al, [r12 + rcx]
    call is_sentinel_al
    test eax, eax
    jnz .id_adv
    mov al, [r12 + rcx]
    cmp al, '.'
    je  .id_member
    call is_digit_al
    test eax, eax
    jz  .id_end
.id_member:
    inc r15
.id_adv:
    inc rcx
    jmp .id_scan
.id_end:
    test r15, r15
    jz  .id_fail
    mov al, [r12 + rcx]
    call is_space_al
    test eax, eax
    jz  .id_fail
    ; A genuine Identifier carries a dot: "1." or "1.1.1". A bare number is
    ; prose that merely starts with a figure, "259 tests passing", and reading
    ; it as a numbering is wrong. Give that the neutral Starter instead, which
    ; is what 2.8 added it for: the Item no longer begins with a number, and
    ; the digits stay plain.
    xor r15, r15
.id_dot:
    cmp r15, rcx
    jae .id_starter
    cmp byte [r12 + r15], '.'
    je  .id_ident
    inc r15
    jmp .id_dot
.id_ident:
    mov al, C_MAG
    call cb_put
    mov r14, rcx
    call copy_head
    jmp .head_done
.id_starter:
    mov al, C_MAG
    call cb_put
    mov al, '-'
    call cb_put
    mov al, ' '
    call cb_put
    mov al, C_OFF
    call cb_put
    xor r14, r14                    ; the number itself stays in the body
    jmp .head_done
.id_fail:

    ; --- Property: two or more letters, digits or [,._&?!%= -/+], then ':'
    xor rcx, rcx
    xor r15, r15
.pr_scan:
    cmp rcx, r13
    jae .head_done
    mov al, [r12 + rcx]
    call is_sentinel_al
    test eax, eax
    jnz .pr_adv
    mov al, [r12 + rcx]
    cmp al, ':'
    je  .pr_colon
    call is_letter_al
    test eax, eax
    jnz .pr_member
    mov al, [r12 + rcx]
    call is_digit_al
    test eax, eax
    jnz .pr_member
    mov al, [r12 + rcx]
    lea rsi, [cls_prop]
    mov edx, cls_prop_len
    call in_class
    test eax, eax
    jz  .head_done
.pr_member:
    inc r15
.pr_adv:
    inc rcx
    jmp .pr_scan
.pr_colon:
    cmp r15, 2
    jb  .head_done
    call after_colon
    test eax, eax
    jz  .head_done
    mov al, C_RED
    call cb_put
    lea r14, [rcx + 1]
    call copy_head

.head_done:
    xor rbx, rbx                    ; rbx = 1 inside a code span
.body:
    cmp r14, r13
    jae .finish
    mov al, [r12 + r14]

    cmp al, '`'                     ; a code span is literal: no rule fires
    jne .not_tick
    xor rbx, 1
    jmp .plain
.not_tick:
    test rbx, rbx
    jnz .plain

    ; paired delimiters: first closer wins, no nesting
    cmp al, '<'
    je  .ref
    mov cl, ']'
    mov ch, C_GRN
    cmp al, '['
    je  .pair
    mov cl, ')'
    mov ch, C_CYN
    cmp al, '('
    je  .pair
    mov cl, '}'
    mov ch, C_YEL
    cmp al, '{'
    je  .pair
    mov cl, '"'
    mov ch, C_CYN
    cmp al, '"'
    je  .pair
    jmp .not_pair
.pair:
    lea rdx, [r14 + 1]
.pair_find:
    cmp rdx, r13
    jae .not_pair                   ; unmatched opener: leave it plain
    mov al, [r12 + rdx]
    cmp al, cl
    je  .pair_take
    inc rdx
    jmp .pair_find
.pair_take:
    mov al, ch
    call cb_put
    mov r15, r14
.pair_copy:
    cmp r15, rdx
    ja  .pair_done
    mov al, [r12 + r15]
    call cb_put
    inc r15
    jmp .pair_copy
.pair_done:
    mov al, C_OFF
    call cb_put
    lea r14, [rdx + 1]
    jmp .body

    ; --- Reference: <...> or <<...>>, over a restricted charset
.ref:
    lea rdx, [r14 + 1]
.ref_scan:
    cmp rdx, r13
    jae .not_pair
    mov al, [r12 + rdx]
    cmp al, '>'
    je  .ref_close
    cmp al, '<'
    je  .ref_adv
    call is_letter_al
    test eax, eax
    jnz .ref_adv
    mov al, [r12 + rdx]
    call is_digit_al
    test eax, eax
    jnz .ref_adv
    mov al, [r12 + rdx]
    lea rsi, [cls_ref]
    push rdx
    mov edx, cls_ref_len
    call in_class
    pop rdx
    test eax, eax
    jz  .not_pair
.ref_adv:
    inc rdx
    jmp .ref_scan
.ref_close:
    lea rax, [r14 + 1]
    cmp rdx, rax
    jbe .not_pair                   ; "<>" is not a Reference
.ref_more:
    lea rax, [rdx + 1]
    cmp rax, r13
    jae .ref_take
    cmp byte [r12 + rax], '>'
    jne .ref_take
    mov rdx, rax
    jmp .ref_more
.ref_take:
    mov al, C_MAG
    call cb_put
    mov r15, r14
.ref_copy:
    cmp r15, rdx
    ja  .ref_done
    mov al, [r12 + r15]
    call cb_put
    inc r15
    jmp .ref_copy
.ref_done:
    mov al, C_OFF
    call cb_put
    lea r14, [rdx + 1]
    jmp .body
.not_pair:

    mov al, [r12 + r14]
    cmp al, '#'
    jne .not_tag
    lea rdx, [r14 + 1]
.tag_scan:
    cmp rdx, r13
    jae .tag_end
    mov al, [r12 + rdx]
    call is_letter_al
    test eax, eax
    jnz .tag_adv
    mov al, [r12 + rdx]
    call is_digit_al
    test eax, eax
    jnz .tag_adv
    mov al, [r12 + rdx]
    lea rsi, [cls_tag]
    push rdx                        ; the cursor, saved before edx takes the
    mov edx, cls_tag_len            ; class length
    call in_class
    pop rdx
    test eax, eax
    jz  .tag_end
.tag_adv:
    inc rdx
    jmp .tag_scan
.tag_end:
    lea rax, [r14 + 1]
    cmp rdx, rax
    jbe .plain                      ; a bare "#" is not a Tag
    mov al, C_ORG
    call cb_put
    mov r15, r14
.tag_copy:
    cmp r15, rdx
    jae .tag_done
    mov al, [r12 + r15]
    call cb_put
    inc r15
    jmp .tag_copy
.tag_done:
    mov al, C_OFF
    call cb_put
    mov r14, rdx
    jmp .body
.not_tag:

    cmp al, ';'
    jne .not_semi
    mov al, C_GRN
    call cb_put
    mov al, ';'
    call cb_put
    mov al, C_OFF
    call cb_put
    inc r14
    jmp .body
.not_semi:

    ; keywords SKIP / END, on word boundaries
    cmp al, 'S'
    je  .kw
    cmp al, 'E'
    jne .plain
.kw:
    test r14, r14
    jz  .kw_try
    mov al, [r12 + r14 - 1]
    call is_alnum_al
    test eax, eax
    jnz .plain
.kw_try:
    lea rsi, [kw_skip]
    mov rdx, 4
    call kw_match
    test eax, eax
    jnz .kw_take
    lea rsi, [kw_end]
    mov rdx, 3
    call kw_match
    test eax, eax
    jz  .plain
.kw_take:
    mov al, C_MAG
    call cb_put
    mov r15, r14
    add rdx, r14
.kw_copy:
    cmp r15, rdx
    jae .kw_done
    mov al, [r12 + r15]
    call cb_put
    inc r15
    jmp .kw_copy
.kw_done:
    mov al, C_OFF
    call cb_put
    mov r14, rdx
    jmp .body

.plain:
    mov al, [r12 + r14]
    call cb_put
    inc r14
    jmp .body

.finish:
    lea rsi, [color_buf]
    mov rdx, [color_len]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Copies input[0 .. r14) into color_buf and closes the colour. Used by the
; three head classes, which all colour a prefix of the Item.
copy_head:
    push rbx
    xor rbx, rbx
.l:
    cmp rbx, r14
    jae .d
    mov al, [r12 + rbx]
    call cb_put
    inc rbx
    jmp .l
.d:
    mov al, C_OFF
    call cb_put
    pop rbx
    ret

; rcx = index of a colon in the Item. eax = 1 when only invisible sentinels
; stand between it and whitespace or the end of the Item.
after_colon:
    push rcx
    inc rcx
.l:
    cmp rcx, r13
    jae .yes
    mov al, [r12 + rcx]
    call is_sentinel_al
    test eax, eax
    jz  .ws
    inc rcx
    jmp .l
.ws:
    mov al, [r12 + rcx]
    cmp al, ' '
    je  .yes
    cmp al, 9
    je  .yes
    xor eax, eax
    pop rcx
    ret
.yes:
    mov eax, 1
    pop rcx
    ret

; al = byte, rsi/edx = class string and its length. eax = 1 when al is in it.
in_class:
    push rcx
    xor ecx, ecx
.l:
    cmp ecx, edx
    jae .no
    cmp al, [rsi + rcx]
    je  .yes
    inc ecx
    jmp .l
.yes:
    mov eax, 1
    pop rcx
    ret
.no:
    xor eax, eax
    pop rcx
    ret

; al = byte. eax = 1 for A-Z or any byte above ASCII, which is how the Nordic
; and accented capitals in vim's class are accepted without a codepoint table.
is_upper_al:
    cmp al, 'A'
    jb  .no
    cmp al, 'Z'
    jbe .yes
    cmp al, 0x80
    jae .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; al = byte. eax = 1 for A-Za-z or any byte above ASCII.
is_letter_al:
    cmp al, 'A'
    jb  .high
    cmp al, 'Z'
    jbe .yes
    cmp al, 'a'
    jb  .high
    cmp al, 'z'
    jbe .yes
.high:
    cmp al, 0x80
    jae .yes
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; al = byte. eax = 1 for 0-9.
is_digit_al:
    cmp al, '0'
    jb  .no
    cmp al, '9'
    ja  .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; al = byte. eax = 1 for a style or colour sentinel.
is_sentinel_al:
    test al, al
    jz  .no
    cmp al, S_MAX
    ja  .no
    cmp al, 9
    je  .no
    cmp al, 10
    je  .no
    cmp al, 13
    je  .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; al = byte. eax = 1 for space, tab, newline or carriage return.
is_space_al:
    cmp al, ' '
    je  .yes
    cmp al, 9
    je  .yes
    cmp al, 10
    je  .yes
    cmp al, 13
    je  .yes
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; al = byte. eax = 1 for ASCII alphanumeric.
is_alnum_al:
    cmp al, '0'
    jb  .no
    cmp al, '9'
    jbe .yes
    cmp al, 'A'
    jb  .no
    cmp al, 'Z'
    jbe .yes
    cmp al, 'a'
    jb  .no
    cmp al, 'z'
    jbe .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; rsi = keyword, rdx = its length, r12/r13/r14 = text/len/cursor.
; eax = 1 when the keyword sits at the cursor and ends on a word boundary.
kw_match:
    push rbx
    push rcx
    push rdi
    lea rdi, [r12 + r14]
    lea rcx, [r14 + rdx]
    cmp rcx, r13
    ja  .no
    xor rbx, rbx
.cmp:
    cmp rbx, rdx
    jae .tail
    mov al, [rdi + rbx]
    cmp al, [rsi + rbx]
    jne .no
    inc rbx
    jmp .cmp
.tail:
    cmp rcx, r13
    je  .yes
    mov al, [r12 + rcx]
    call is_alnum_al
    test eax, eax
    jnz .no
.yes:
    mov eax, 1
    pop rdi
    pop rcx
    pop rbx
    ret
.no:
    xor eax, eax
    pop rdi
    pop rcx
    pop rbx
    ret

; al = byte, appended to color_buf.
cb_put:
    push rcx
    mov rcx, [color_len]
    cmp rcx, LINE_MAX * 3 - 1
    jae .full
    mov [color_buf + rcx], al
    inc rcx
    mov [color_len], rcx
.full:
    pop rcx
    ret

; ---------------------------------------------------------------------------
write_out:
    lea rsi, [out_prefix]
    mov rdx, out_prefix_len
    call write_all
    mov rcx, [lead_nl]
    call write_newlines
    lea rsi, [out_buf]
    mov rdx, [out_len]
    call write_all
    mov rcx, [trail_nl]
    call write_newlines
    lea rsi, [out_suffix]
    mov rdx, out_suffix_len
    call write_all
    ret

; rcx = how many escaped newlines to emit.
write_newlines:
    test rcx, rcx
    jz  .ret
.loop:
    push rcx
    lea rsi, [nl_esc]
    mov rdx, 2
    call write_all
    pop rcx
    dec rcx
    jnz .loop
.ret:
    ret

; rsi = bytes, rdx = length.
write_all:
    test rdx, rdx
    jz  .ret
.loop:
    mov eax, SYS_WRITE
    mov edi, STDOUT
    syscall
    test rax, rax
    jle fail
    add rsi, rax
    sub rdx, rax
    jnz .loop
.ret:
    ret
