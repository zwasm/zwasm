//! ARM64 cross-module import bridge thunk encoder
//! (ADR-0066 + Amendment §A1 + §A2 (D-144),
//! D-142 fix (A.2)).
//!
//! Each thunk is a 96-byte native code snippet that wraps a
//! call-and-return around the callee's JIT entry, **saving the
//! caller's six reserved-invariant callee-saved registers**
//! (X19/X24/X25/X26/X27/X28 per ADR-0017 + ADR-0018) across the
//! call so the importer's reserved-invariant view survives the
//! callee's prologue overwrite. D-144 found that
//! the prior §A1 56-byte shape saved only X19, leaving X24
//! (typeidx_base), X25 (table_size), X26 (funcptr_base), X27
//! (mem_limit), X28 (vm_base) corrupt across cross-module
//! returns — manifested as `imports.1.wasm print64` `call_indirect
//! sig` mismatch (kind=3) because X24 pointed at the callee's
//! (= imports.0's) typeidx_base instead of the caller's.
//!
//! Layout (120 bytes total):
//!
//! ```text
//! offset  encoding                          disassembly
//! 0x00    STP X29, X30, [SP, #-80]!         ; alloc 80-byte frame, save FP+LR
//! 0x04    MOV X29, SP  (ADD X29,SP,#0)      ; FP-link the thunk frame (ADR-0134 D1)
//! 0x08    STR X19, [SP, #16]                ; save caller's X19 = caller_rt
//! 0x0C    STR X24, [SP, #24]                ; save caller's X24 = typeidx_base
//! 0x10    STR X25, [SP, #32]                ; save caller's X25 = table_size (W-form low)
//! 0x14    STR X26, [SP, #40]                ; save caller's X26 = funcptr_base
//! 0x18    STR X27, [SP, #48]                ; save caller's X27 = mem_limit
//! 0x1C    STR X28, [SP, #56]                ; save caller's X28 = vm_base
//! 0x20    ADR X16, +72                      ; X16 ← literal pool base
//! 0x24    LDR X0,  [X16]                    ; X0  ← callee_rt
//! 0x28    STR X0,  [SP, #64]                ; #381: park callee_rt in the frame pad
//! 0x2C    STR XZR, [X0, #40]                ; #381 entry clear: callee trap_flag|kind
//! 0x30    LDR X16, [X16, #8]                ; X16 ← callee_entry
//! 0x34    BLR X16                           ; CALL (LR ← PC+4)
//! 0x38    LDR X19, [SP, #16]                ; RESTORE caller's X19
//! 0x3C    LDR X24, [SP, #24]                ; RESTORE caller's X24
//! 0x40    LDR X25, [SP, #32]                ; RESTORE caller's X25
//! 0x44    LDR X26, [SP, #40]                ; RESTORE caller's X26
//! 0x48    LDR X27, [SP, #48]                ; RESTORE caller's X27
//! 0x4C    LDR X28, [SP, #56]                ; RESTORE caller's X28
//! 0x50    LDR X16, [SP, #64]                ; #381 relay: X16 ← callee_rt
//! 0x54    LDR X17, [X16, #40]               ; X17 ← callee trap_flag|trap_kind
//! 0x58    CBZ X17, +2                       ; no trap → skip the store
//! 0x5C    STR X17, [X19, #40]               ; relay onto the CALLER's runtime
//! 0x60    LDP X29, X30, [SP], #80           ; restore FP+LR, pop frame
//! 0x64    RET                               ; return to importer
//! 0x68    .quad callee_rt                   ; literal pool
//! 0x70    .quad callee_entry
//! ```
//!
//! 26 × 4-byte instructions + 16-byte literal pool = 120 bytes total (the
//! entry-clear STR consumed the alignment pad the relay had needed, so the
//! size is unchanged). `ADR X16, +<offset>` resolves from the ADR's PC
//! (offset 0x20) to the literal pool base (0x68) — distance = 72 bytes.
//!
//! Entry clear (#381): the thunk IS a JIT entry into another instance's
//! runtime, and it was the only one that did not clear the trap fields on the
//! way in — `entry.zig` does it for every host-driven entry, precisely so a
//! previous run's flag cannot be read as this run's (#336 for the kind). The
//! callee's `trap_flag`/`trap_kind` therefore stayed set after a cross-module
//! trap, and once the relay below started READING them a later, successful
//! call into that same exporter reported the old trap. Clearing on the way in
//! is what makes the relay's read mean "this call".
//!
//! Trap relay (#381): a JIT trap is a FLAG, not an unwind — the trap stub
//! writes `[X19 + trap_flag_off]` and returns, and every call site re-reads
//! that flag afterwards (`arm64/op_call.zig:emitPostCallTrapCheck`,
//! ADR-0199 / D-468). X19 holds the CALLEE's runtime for the duration of the
//! call, so a trap raised in the callee landed in a runtime the importer
//! never reads: the call reported success and the importer ran on past a
//! call that returned nothing. The four instructions at 0x4C..0x5B copy the
//! callee's flag onto the caller AFTER X19 has been restored, so the
//! importer's existing post-call check fires unchanged — no call-site
//! codegen changes.
//!
//! `trap_flag` (u32 @40) and `trap_kind` (u32 @44) are adjacent, so ONE
//! 8-byte load/store carries both; the kind matters because a relay that
//! moved only the flag would report every cross-module trap as kind 0. The
//! adjacency is asserted at comptime below.
//!
//! `callee_rt` is parked at `[SP, #64]` (the frame's existing pad, see the
//! frame layout below) rather than re-derived from the literal pool: X16 is
//! corruptible across the call (AAPCS64 §6.4.1 IP0) and X0 carries the
//! return value. X16/X17 are free to clobber after the call; X0..X1 and
//! V0..V3 (the return-value registers) are untouched.
//!
//! AAPCS64 §6.4.1 invariant: X19..X28 are callee-saved. v2's
//! JIT prologue (per ADR-0017 sub-2d-ii) overwrites the six
//! reserved-invariant slots (X19 + X24..X28) with new values
//! derived from `*JitRuntime` WITHOUT first stack-saving the
//! caller's value. For same-module calls this is a no-op
//! (caller_rt ≡ callee_rt) but for cross-module bridge thunks
//! caller_rt ≠ callee_rt, so the bridge thunk pays the
//! save/restore cost on the caller's behalf. See
//! `.claude/rules/abi_callee_saved_pinning.md` Option A for
//! the full rationale.
//!
//! Frame layout: `[SP+0]=FP, [SP+8]=LR, [SP+16]=X19,
//! [SP+24]=X24, [SP+32]=X25, [SP+40]=X26, [SP+48]=X27,
//! [SP+56]=X28, [SP+64]=callee_rt (#381 relay), [SP+72]=padding`.
//! The 80-byte frame keeps
//! SP 16-byte-aligned per AAPCS64 §6.4.5.1; FP/LR sit at the
//! bottom matching the standard unwinder frame shape so a
//! debugger can walk past the thunk.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");
const inst = @import("inst.zig");
const jit_abi = @import("../shared/jit_abi.zig");

comptime {
    // The relay below copies `trap_flag` and `trap_kind` as one 8-byte pair,
    // and `encLdrImm`/`encStrImm` require an 8-aligned byte offset.
    if (jit_abi.trap_kind_off != jit_abi.trap_flag_off + 4)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; they are no longer adjacent");
    if (jit_abi.trap_flag_off % 8 != 0)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; trap_flag_off is no longer 8-aligned");
}

/// Total thunk size in bytes (26 instructions × 4 bytes + 2 quad
/// literals × 8 bytes = 120). Stable across all callee signatures.
/// D-144 grew the thunk from 56 → 96 bytes to cover the full
/// six-register reserved-invariant cohort; #381's entry clear + trap
/// relay grew it 96 → 120.
pub const thunk_bytes: usize = 120;

/// #381 — frame slot the thunk parks `callee_rt` in across the call, so the
/// trap relay can read the callee's runtime after X16/X0 are gone. Uses the
/// 80-byte frame's existing pad; the frame does not grow.
const callee_rt_slot: u15 = 64;

/// Emit one bridge thunk into `buf[0..thunk_bytes]`. `buf` MUST
/// be exactly `thunk_bytes` long; the caller is responsible for
/// allocating it inside an RX-mappable arena.
///
/// `callee_rt`    — the callee instance's `*JitRuntime` value
///                  to install in X0 before the BLR.
/// `callee_entry` — the callee's JIT entry point.
pub fn emitThunk(buf: []u8, callee_rt: usize, callee_entry: usize) void {
    std.debug.assert(buf.len == thunk_bytes);
    // STP X29, X30, [SP, #-80]! — allocate 80-byte frame +
    // save caller's FP+LR (D-144 — was -32 / 32-byte
    // frame, now -80 / 80-byte frame to accommodate the full
    // X19+X24..X28 reserved-invariant save area).
    std.mem.writeInt(u32, buf[0..4], inst.encStpPreIdx(29, 30, inst.sp_reg, -80), .little);
    // MOV X29, SP (= ADD X29, SP, #0) — FP-link the thunk's frame into
    // the chain (ADR-0134 D1). Without this the thunk frame is NOT a
    // chain link, so the callee saves the CALLER's X29 with a saved-LR
    // pointing into the thunk → the FP-walk unwinder reaches the caller
    // frame carrying a thunk PC instead of the caller's call-site PC,
    // and a cross-module throw can't find the caller's try_table. SP is
    // unchanged, so the STR/LDR [SP,#N] cohort offsets below stay valid
    // (and X29==SP makes the saved caller_rt readable at [X29,#16]).
    std.mem.writeInt(u32, buf[4..8], inst.encAddImm12(29, inst.sp_reg, 0), .little);
    // STR X19..X28 reserved-invariant save block.
    std.mem.writeInt(u32, buf[8..12], inst.encStrImm(19, inst.sp_reg, 16), .little);
    std.mem.writeInt(u32, buf[12..16], inst.encStrImm(24, inst.sp_reg, 24), .little);
    std.mem.writeInt(u32, buf[16..20], inst.encStrImm(25, inst.sp_reg, 32), .little);
    std.mem.writeInt(u32, buf[20..24], inst.encStrImm(26, inst.sp_reg, 40), .little);
    std.mem.writeInt(u32, buf[24..28], inst.encStrImm(27, inst.sp_reg, 48), .little);
    std.mem.writeInt(u32, buf[28..32], inst.encStrImm(28, inst.sp_reg, 56), .little);
    // ADR X16, +<offset> — literal pool starts at byte 0x68 from thunk
    // start. ADR instruction is at byte 0x20 (32). Distance =
    // 0x68 - 0x20 = 0x48 = 72 bytes (was 48 before the #381 relay).
    std.mem.writeInt(u32, buf[32..36], inst.encAdr(16, 72), .little);
    // LDR X0, [X16] — X0 ← callee_rt.
    std.mem.writeInt(u32, buf[36..40], inst.encLdrImm(0, 16, 0), .little);
    // STR X0, [SP, #64] — #381: park callee_rt in the frame's pad slot. X16
    // is corruptible across the call and X0 returns the callee's result, so
    // the relay below cannot recover it from either.
    std.mem.writeInt(u32, buf[40..44], inst.encStrImm(0, inst.sp_reg, callee_rt_slot), .little);
    const flag_off: u15 = jit_abi.trap_flag_off;
    // STR XZR, [X0, #40] — #381 entry clear: zero the callee's
    // trap_flag|trap_kind pair while X0 still holds callee_rt, so the relay
    // below reads THIS call's outcome and not a trap the exporter kept from
    // an earlier one.
    std.mem.writeInt(u32, buf[44..48], inst.encStrImm(inst.xzr, 0, flag_off), .little);
    // LDR X16, [X16, #8] — X16 ← callee_entry.
    std.mem.writeInt(u32, buf[48..52], inst.encLdrImm(16, 16, 8), .little);
    // BLR X16 — CALL.
    std.mem.writeInt(u32, buf[52..56], inst.encBlr(16), .little);
    // LDR X19..X28 — restore caller's reserved-invariant cohort.
    std.mem.writeInt(u32, buf[56..60], inst.encLdrImm(19, inst.sp_reg, 16), .little);
    std.mem.writeInt(u32, buf[60..64], inst.encLdrImm(24, inst.sp_reg, 24), .little);
    std.mem.writeInt(u32, buf[64..68], inst.encLdrImm(25, inst.sp_reg, 32), .little);
    std.mem.writeInt(u32, buf[68..72], inst.encLdrImm(26, inst.sp_reg, 40), .little);
    std.mem.writeInt(u32, buf[72..76], inst.encLdrImm(27, inst.sp_reg, 48), .little);
    std.mem.writeInt(u32, buf[76..80], inst.encLdrImm(28, inst.sp_reg, 56), .little);
    // #381 trap relay — X19 now holds caller_rt again, so the store below
    // lands on the CALLER. Reading and writing the same 8-byte offset carries
    // trap_flag AND trap_kind. Conditional, so a clean return cannot clear a
    // flag the caller already holds.
    std.mem.writeInt(u32, buf[80..84], inst.encLdrImm(16, inst.sp_reg, callee_rt_slot), .little);
    std.mem.writeInt(u32, buf[84..88], inst.encLdrImm(17, 16, flag_off), .little);
    std.mem.writeInt(u32, buf[88..92], inst.encCbz(17, 2), .little); // → LDP
    std.mem.writeInt(u32, buf[92..96], inst.encStrImm(17, 19, flag_off), .little);
    // LDP X29, X30, [SP], #80 — restore FP+LR, pop frame.
    std.mem.writeInt(u32, buf[96..100], inst.encLdpPostIdx(29, 30, inst.sp_reg, 80), .little);
    // RET — return to importer's call site.
    std.mem.writeInt(u32, buf[100..104], inst.encRet(30), .little);
    // Literal pool at offset 0x68 (= 104). The entry-clear STR consumed the
    // alignment pad the relay had needed, so the pool stays 8-aligned.
    std.mem.writeInt(u64, buf[104..112], callee_rt, .little);
    std.mem.writeInt(u64, buf[112..120], callee_entry, .little);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "emitThunk: encoding round-trip via helpers" {
    // Re-derive each instruction via the encoder helpers rather
    // than hardcoding byte sequences — keeps the test stable
    // across future thunk reshuffles (was bitten by the §A1 →
    // §A2 grow from 56 → 96 bytes).
    var buf: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    emitThunk(&buf, callee_rt, callee_entry);

    try testing.expectEqual(inst.encStpPreIdx(29, 30, inst.sp_reg, -80), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(inst.encAddImm12(29, inst.sp_reg, 0), std.mem.readInt(u32, buf[4..8], .little)); // MOV X29, SP (D1)
    try testing.expectEqual(inst.encStrImm(19, inst.sp_reg, 16), std.mem.readInt(u32, buf[8..12], .little));
    try testing.expectEqual(inst.encStrImm(24, inst.sp_reg, 24), std.mem.readInt(u32, buf[12..16], .little));
    try testing.expectEqual(inst.encStrImm(25, inst.sp_reg, 32), std.mem.readInt(u32, buf[16..20], .little));
    try testing.expectEqual(inst.encStrImm(26, inst.sp_reg, 40), std.mem.readInt(u32, buf[20..24], .little));
    try testing.expectEqual(inst.encStrImm(27, inst.sp_reg, 48), std.mem.readInt(u32, buf[24..28], .little));
    try testing.expectEqual(inst.encStrImm(28, inst.sp_reg, 56), std.mem.readInt(u32, buf[28..32], .little));
    try testing.expectEqual(inst.encAdr(16, 72), std.mem.readInt(u32, buf[32..36], .little));
    try testing.expectEqual(inst.encLdrImm(0, 16, 0), std.mem.readInt(u32, buf[36..40], .little));
    try testing.expectEqual(inst.encStrImm(0, inst.sp_reg, callee_rt_slot), std.mem.readInt(u32, buf[40..44], .little));
    // #381 entry clear.
    try testing.expectEqual(inst.encStrImm(inst.xzr, 0, jit_abi.trap_flag_off), std.mem.readInt(u32, buf[44..48], .little));
    try testing.expectEqual(inst.encLdrImm(16, 16, 8), std.mem.readInt(u32, buf[48..52], .little));
    try testing.expectEqual(inst.encBlr(16), std.mem.readInt(u32, buf[52..56], .little));
    try testing.expectEqual(inst.encLdrImm(19, inst.sp_reg, 16), std.mem.readInt(u32, buf[56..60], .little));
    try testing.expectEqual(inst.encLdrImm(24, inst.sp_reg, 24), std.mem.readInt(u32, buf[60..64], .little));
    try testing.expectEqual(inst.encLdrImm(25, inst.sp_reg, 32), std.mem.readInt(u32, buf[64..68], .little));
    try testing.expectEqual(inst.encLdrImm(26, inst.sp_reg, 40), std.mem.readInt(u32, buf[68..72], .little));
    try testing.expectEqual(inst.encLdrImm(27, inst.sp_reg, 48), std.mem.readInt(u32, buf[72..76], .little));
    try testing.expectEqual(inst.encLdrImm(28, inst.sp_reg, 56), std.mem.readInt(u32, buf[76..80], .little));
    // #381 trap relay.
    try testing.expectEqual(inst.encLdrImm(16, inst.sp_reg, callee_rt_slot), std.mem.readInt(u32, buf[80..84], .little));
    try testing.expectEqual(inst.encLdrImm(17, 16, jit_abi.trap_flag_off), std.mem.readInt(u32, buf[84..88], .little));
    try testing.expectEqual(inst.encCbz(17, 2), std.mem.readInt(u32, buf[88..92], .little));
    try testing.expectEqual(inst.encStrImm(17, 19, jit_abi.trap_flag_off), std.mem.readInt(u32, buf[92..96], .little));
    try testing.expectEqual(inst.encLdpPostIdx(29, 30, inst.sp_reg, 80), std.mem.readInt(u32, buf[96..100], .little));
    try testing.expectEqual(inst.encRet(30), std.mem.readInt(u32, buf[100..104], .little));
    try testing.expectEqual(callee_rt, std.mem.readInt(u64, buf[104..112], .little));
    try testing.expectEqual(callee_entry, std.mem.readInt(u64, buf[112..120], .little));
}

// #381 — the relay's meaning, apart from its byte offsets: it reads the
// CALLEE's runtime (parked in the frame) and writes the CALLER's (X19, already
// restored), at the same offset, and the CBZ lands on the epilogue rather than
// inside the store. A reshuffle that keeps the encodings but swaps the two
// runtimes would still report no trap; this is what catches that.
test "emitThunk: the trap relay reads the callee's runtime and writes the caller's (#381)" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0);
    const load = std.mem.readInt(u32, buf[84..88], .little);
    const store = std.mem.readInt(u32, buf[92..96], .little);
    // Load base = X16 (the parked callee_rt); store base = X19 (caller_rt).
    try testing.expectEqual(inst.encLdrImm(17, 16, jit_abi.trap_flag_off), load);
    try testing.expectEqual(inst.encStrImm(17, 19, jit_abi.trap_flag_off), store);
    // The X19 restore precedes the store — otherwise it would land on the callee.
    try testing.expectEqual(inst.encLdrImm(19, inst.sp_reg, 16), std.mem.readInt(u32, buf[56..60], .little));
    // CBZ +2 words from byte 88 = byte 96 = the LDP epilogue.
    try testing.expectEqual(inst.encLdpPostIdx(29, 30, inst.sp_reg, 80), std.mem.readInt(u32, buf[88 + 2 * 4 ..][0..4], .little));
    // The entry clear zeroes the CALLEE's pair (base X0 = callee_rt) before the
    // call, so the load above cannot see an earlier call's trap.
    try testing.expectEqual(inst.encStrImm(inst.xzr, 0, jit_abi.trap_flag_off), std.mem.readInt(u32, buf[44..48], .little));
}

test "emitThunk: round-trip literals at zero" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[104..112], .little));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[112..120], .little));
    // Instruction prefix unchanged regardless of literals.
    try testing.expectEqual(inst.encStpPreIdx(29, 30, inst.sp_reg, -80), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(inst.encRet(30), std.mem.readInt(u32, buf[100..104], .little));
}

test "emitThunk: instruction prefix is constant across two distinct callees" {
    var buf_a: [thunk_bytes]u8 = undefined;
    var buf_b: [thunk_bytes]u8 = undefined;
    emitThunk(&buf_a, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888);
    emitThunk(&buf_b, 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111);
    // First 80 bytes (20 instrs, no pad) must match — only the
    // literal pool differs between thunks.
    try testing.expectEqualSlices(u8, buf_a[0..80], buf_b[0..80]);
}

test "emitThunk: saves/restores X19+X24..X28 around BLR" {
    // Structural assertion: between the BLR and the LDP epilogue,
    // the thunk re-loads each of the six reserved-invariant
    // callee-saved registers (X19 + X24..X28) from the frame.
    // This is the load-bearing invariant that closes the D-144
    // cross-module sig-mismatch chain. If future encoder reshuffles
    // drop any save/restore, this test fails before the runtime
    // call_indirect kind=3 trap would.
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0xDEADBEEF, 0xCAFEBABE);
    // Pre-BLR saves at offsets 8..32 (shifted +4 by the MOV X29,SP at 4).
    try testing.expectEqual(inst.encStrImm(19, inst.sp_reg, 16), std.mem.readInt(u32, buf[8..12], .little));
    try testing.expectEqual(inst.encStrImm(24, inst.sp_reg, 24), std.mem.readInt(u32, buf[12..16], .little));
    try testing.expectEqual(inst.encStrImm(28, inst.sp_reg, 56), std.mem.readInt(u32, buf[28..32], .little));
    // Post-BLR restores at offsets 56..80 (shifted +8 by the two #381 stores).
    try testing.expectEqual(inst.encLdrImm(19, inst.sp_reg, 16), std.mem.readInt(u32, buf[56..60], .little));
    try testing.expectEqual(inst.encLdrImm(24, inst.sp_reg, 24), std.mem.readInt(u32, buf[60..64], .little));
    try testing.expectEqual(inst.encLdrImm(28, inst.sp_reg, 56), std.mem.readInt(u32, buf[76..80], .little));
}
