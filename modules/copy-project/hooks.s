| COPY PROJECT hooks -- CHANGE→FUNC+BANK LISTPOP label.

| Short "COPY" matches stock RENAME/DELETE tails (docs/firmware/PANEL.md).
        .global cp_zero, cp_lbl
        .equ    cp_zero, 0
        .section .rodata
        .balign 4
cp_lbl:
        .asciz  "COPY"
