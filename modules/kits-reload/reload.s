| KITS RELOAD -- the bridge that lets MIDI SCENES' Part Reload run beside
| Octakit's kit reload. Linked into the platform runtime beside his units,
| so his symbols (rel_after, apply_ret) resolve directly; hers arrive as
| link-time values (RELOAD_FMT_NEXT, schema.Override).
|
| His `reload` stub sat on the two stock `jsr 0x4004aab4` sites, swapped
| the site's return address for `rel_after` (the post-reload MSC restore)
| and jumped into the stock reload. Her replacement of 0x4004aab4
| (gk_stock_part_saved_to_working_reload) reads that return address and
| accepts only the two stock sites' -- anything else is her `illegal`
| trap: VEC:04 at gk_stock_part_saved_to_working_reload_report_fatal with
| D0 = rel_after, the screen his unit showed on 14 Sep 2026.
|
| So the stock jsr stays stock (his two detours are overridden) and his
| post-work moves to the RETURN sites, where the stack is exactly what
| rel_after expects: the part index at (sp), and apply_ret naming where
| to go when it is done.
        .text

| 0x4002dd5c, menu path: her reload has returned, (sp) = the part index
| stock pushed at 0x4002dd50, d0 = her result (rel_after preserves it).
        .global menu_after
menu_after:
        move.l  #menu_cont,%d1                | d1: dead at 0x4002dd64, rel_after restores it
        move.l  %d1,(apply_ret).l
        jmp     (rel_after).l
menu_cont:
        addq.l  #4,%sp                        | displaced
        lea     (0x40013a08).l,%a0            | displaced
        jmp     (0x4002dd64).l

| 0x4005e05a, FUNC+CUE path, the call: stock pushed the part index from
| 0x80000003 (mvz.b at 0x4005e03c) and pops it at 0x4005e060, so it is
| gone by the return site -- and the reload moves that byte (his apply
| bridge rewrites it from the engine's part on the way; measured under
| the port, 0 -> 1 on the RIG fixture), so re-reading it afterwards is
| not what his build gave rel_after. Park it, then call her with the
| site's own return address.
        .global shortcut_call
shortcut_call:
        move.l  (%sp),(reload_arg).l
        pea     (0x4005e060).l                | the return her caller check wants
        jmp     (0x4004aab4).l

| 0x4005e062, FUNC+CUE path, the return: (sp) is past the popped index;
| push the parked one for rel_after. The two displaced instructions
| computed d1 = fp-32 for the stock formatter her reload-shortcut-format
| write replaces; her routine reads fp itself, so d1 is not rebuilt.
        .global shortcut_after
shortcut_after:
        move.l  (reload_arg).l,-(%sp)
        move.l  #shortcut_cont,%d1
        move.l  %d1,(apply_ret).l
        jmp     (rel_after).l
shortcut_cont:
        addq.l  #4,%sp
        jmp     (RELOAD_FMT_NEXT).l           | hers: the format, then 0x4005e09c

| in .text like his state words: a .data section would land on the
| linker's next 8 KB boundary and grow the packed runtime for nothing
        .align  2
reload_arg:
        .long   0
