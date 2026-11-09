# 0236 — The interpreter's dispatch loop and every handler sit in one link section

- **Status**: Accepted (2026-11-10, on PR #708)
- **Date**: 2026-11-09
- **Author**: Junji Takakura
- **Tags**: interp, performance, build

## Context

The interpreter's speed moves with where its code falls, not only with what
it does. #541 found three placements that move it on Zen 3 and #544 pinned two:
`runFrame`'s loop (`noinline` + `align(64)`, up to 13%) and the dispatch table
(`align(4096)`, 11%). The third, where the handlers fall, stayed loose. They are
laid out after `runFrame` with ~200 unrelated functions between, so any of
those changing size shifts every handler against the loop (#548, 512-trip
per-call runner):

| handlers shifted by | interp |
|---|---|
| +0x10 | +3.0% |
| +0x30 | +12.2% |
| code before `runFrame` only | +0.3% |

#597 then reached the +0x30 row through code added in front of `runFrame`
alone: `heapsort` on the interpreter +10.5%, with the interpreter's machine code
unchanged.

## Decision

1. `runFrame` and every `InterpFn` handler carry
   `linksection(dispatch_table.text_section)`. The constant switches on
   `builtin.object_format`: ELF `zwasm_interp` (a C identifier, so the linker
   defines `__start_` / `__stop_` bounds), Mach-O `__TEXT,__zwasm_interp`, COFF
   `.text$zwasm_interp`. It lives in `ir/dispatch_table.zig`, next to `InterpFn`,
   because the handlers in `instruction/` are Zone 1. A factory puts it on the
   inner fn. `runFrame` keeps `noinline` + `align(64)`.
2. The handlers get no `align` of their own. LLVM already starts every one on a
   16-byte boundary, and `align(16)` on each measured the same as the section
   alone (per-call −1.0% against −1.1%) without moving `loopOp`.
3. A unit test on ELF checks that `runFrame` and every non-null
   `dispatchTable().interp` slot lie between `__start_zwasm_interp` and
   `__stop_zwasm_interp`. The attribute is the same source on every format, so
   the two Linux legs catch a handler without it; Mach-O and COFF only link.

Measured on x86_64-linux (Ryzen 7 5700X), ReleaseFast, interleaved, medians
of 3 rounds (per-call, 512 trips) and 2 (`heapsort`, hyperfine). A shift is
`align(64)` on one function: outside the section, `api.trap_surface.mapInterpTrap`
(laid out before the handlers on main); inside it, `array_ops.arrayInitElem`
(#548's +0x30 row). A shifted row is against its own unshifted build:

| build | per-call | `heapsort` |
|---|---|---|
| main | 28.53 µs | 32.20 s |
| section | −1.1% | −1.6% |
| main, outside shift | +2.0% | +3.9% |
| section, outside shift | −0.1% | −0.3% |
| main, inside shift | +2.0% | +1.1% |
| section, inside shift | +3.8% | +6.1% |

## Alternatives

- **Leave the handlers loose.** Any size change between `runFrame` and the
  handlers moves the interpreter by 3–12%; an unrelated PR's delta is unreadable.
- **A threaded dispatch** (#680 layer 2). It would replace the loop and the
  handler calling convention this pins, and is not decided.

## Consequences

- A new handler without the attribute fails the ELF test.
- The section pins the interpreter against code outside it, not against
  itself: a handler that changes size still moves the ones after it against
  the loop (the inside-shift row).
- Zig's Mach-O linker folds the section into `__text` as one contiguous run.
- If #680 replaces the dispatch shape, it may retire the section.

## Revision history

| Date       | SHA          | Note |
|------------|--------------|------|
| 2026-11-10 | —            | Initial, Accepted on PR #708. |
