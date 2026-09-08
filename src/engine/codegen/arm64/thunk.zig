//! ARM64 cross-module import bridge thunk encoder
//! (ADR-0066 + Amendment §A1 + §A2 (D-144), D-142 fix (A.2);
//! ADR-0228 D4 for the derived save block).
//!
//! Each thunk is a native code snippet that wraps a call-and-return around
//! the callee's JIT entry, **saving the caller's whole reserved-invariant
//! cohort** (`abi.reserved_invariant_gprs` per ADR-0017 + ADR-0018 + ADR-0027)
//! across the call so the importer's reserved-invariant view survives the
//! callee's prologue overwrite. The set is read from that array rather than
//! written out here: D-144 found the §A1 shape saved only X19, leaving X24
//! (typeidx_base), X25 (table_size), X26 (funcptr_base), X27 (mem_limit), X28
//! (vm_base) corrupt across cross-module returns — manifested as
//! `imports.1.wasm print64` `call_indirect sig` mismatch (kind=3) because X24
//! pointed at the callee's (= imports.0's) typeidx_base instead of the
//! caller's — and #413 found the enumeration it left behind had gone stale
//! again when ADR-0027 reserved X23 (globals_base).
//!
//! Shape. `N` = `abi.reserved_invariant_gprs.len`, and every offset below
//! follows from it — which is the point: a reservation change moves them all
//! with no edit here (#413).
//!
//! ```text
//!   STP X29, X30, [SP, #-frame]!      ; alloc the frame, save FP+LR
//!   MOV X29, SP  (ADD X29,SP,#0)      ; FP-link the thunk frame (ADR-0134 D1)
//!   STR Xn,  [SP, #16 + 8*i]          ; × N — save the caller's cohort
//!   ADR X16, +<literal pool>          ; X16 ← literal pool base
//!   LDR X0,  [X16]                    ; X0  ← callee_rt
//!   STR X0,  [SP, #callee_rt_slot]    ; #381: park callee_rt in the frame
//!   STR XZR, [X0, #trap_flag_off]     ; #381 entry clear: callee trap_flag|kind
//!   LDR X16, [X16, #8]                ; X16 ← callee_entry
//!   BLR X16                           ; CALL (LR ← PC+4)
//!   LDR Xn,  [SP, #16 + 8*i]          ; × N — restore the caller's cohort
//!   LDR X16, [SP, #callee_rt_slot]    ; #381 relay: X16 ← callee_rt
//!   LDR X17, [X16, #trap_flag_off]    ; X17 ← callee trap_flag|trap_kind
//!   CBZ X17, +2                       ; no trap → skip the store
//!   STR X17, [X19, #trap_flag_off]    ; relay onto the CALLER's runtime
//!   LDP X29, X30, [SP], #frame        ; restore FP+LR, pop frame
//!   RET                               ; return to importer
//!   .quad callee_rt                   ; literal pool
//!   .quad callee_entry
//! ```
//!
//! `2N + 14` instructions plus a 16-byte literal pool. The frame is
//! `[SP+0]=FP, [SP+8]=LR`, one slot per cohort register from `[SP+16]`, then
//! `callee_rt`, rounded up to AAPCS64's 16-byte SP alignment. X19 is the
//! cohort's first member and so sits at `[SP+16]`, which the trap relay below
//! and the `[X29,#16]` note above both rely on; a comptime check holds it.
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
//! call that returned nothing. The four instructions after the restore block
//! copy the callee's flag onto the caller AFTER X19 has been restored, so the
//! importer's existing post-call check fires unchanged — no call-site
//! codegen changes.
//!
//! `trap_flag` (u32 @40) and `trap_kind` (u32 @44) are adjacent, so ONE
//! 8-byte load/store carries both; the kind matters because a relay that
//! moved only the flag would report every cross-module trap as kind 0. The
//! adjacency is asserted at comptime below.
//!
//! `callee_rt` is parked in the frame slot after the cohort rather than
//! re-derived from the literal pool: X16 is
//! corruptible across the call (AAPCS64 §6.4.1 IP0) and X0 carries the
//! return value. X16/X17 are free to clobber after the call; X0..X1 and
//! V0..V3 (the return-value registers) are untouched.
//!
//! AAPCS64 §6.4.1 invariant: X19..X28 are callee-saved. v2's
//! JIT prologue (per ADR-0017 sub-2d-ii) installs the
//! reserved-invariant slots with new values derived from
//! `*JitRuntime` WITHOUT first stack-saving the
//! caller's value. For same-module calls this is a no-op
//! (caller_rt ≡ callee_rt) but for cross-module bridge thunks
//! caller_rt ≠ callee_rt, so the bridge thunk pays the
//! save/restore cost on the caller's behalf. See
//! `.claude/rules/abi_callee_saved_pinning.md` Option A for
//! the full rationale.
//!
//! FP/LR sit at the bottom of the frame, matching the standard unwinder
//! frame shape so a debugger can walk past the thunk.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");
const abi = @import("abi.zig");
const inst = @import("inst.zig");
const jit_abi = @import("../shared/jit_abi.zig");

comptime {
    // The relay below copies `trap_flag` and `trap_kind` as one 8-byte pair,
    // and `encLdrImm`/`encStrImm` require an 8-aligned byte offset.
    if (jit_abi.trap_kind_off != jit_abi.trap_flag_off + 4)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; they are no longer adjacent");
    if (jit_abi.trap_flag_off % 8 != 0)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; trap_flag_off is no longer 8-aligned");
    // The trap relay stores through the first saved register after restoring
    // it, so the cohort's head has to be the runtime pointer, and the
    // frame-layout note above puts it at [X29,#16].
    if (saved_gprs[0] != abi.runtime_ptr_save_gpr)
        @compileError("bridge thunk relays the trap through saved_gprs[0]; it is no longer runtime_ptr_save_gpr");
    if (slotOf(0) != 16)
        @compileError("the saved caller_rt must stay at [X29,#16]");
}

/// The registers the thunk saves across the call: the reserved-invariant set
/// itself, not a copy of it (ADR-0228 D4 — a copy is what #413 was).
const saved_gprs = abi.reserved_invariant_gprs;

/// First frame slot above the saved FP/LR pair.
const save_area_off: u15 = 16;

/// #381 — frame slot the thunk parks `callee_rt` in across the call, so the
/// trap relay can read the callee's runtime after X16/X0 are gone.
const callee_rt_slot: u15 = save_area_off + 8 * saved_gprs.len;

const frame_bytes: i10 = std.mem.alignForward(i10, callee_rt_slot + 8, 16);

/// 2 (frame setup) + N (saves) + 6 (literals, entry clear, call) + N
/// (restores) + 4 (trap relay) + 2 (epilogue). The 14 is the one hand count
/// left; adding an instruction to `emitThunk` means updating it, and the
/// round-trip test below is what catches a miss.
const instruction_count: usize = 2 * saved_gprs.len + 14;

/// Byte offset of the literal pool — the two quads sit after the last
/// instruction, which keeps them 8-aligned for as long as the count is even.
const literal_pool_off: usize = instruction_count * 4;

/// Total thunk size in bytes. One shape for every callee — which bounds what
/// the bridge can carry: a callee whose arguments overflow the registers reads
/// them at `[X29, #16 + 8*idx]` relative to its own frame, and this thunk's
/// frame sits in between. Same gap as the x86_64 encoder's; tracked there.
/// D-144 grew the thunk from 56 → 96 bytes to cover what was then the full
/// reserved-invariant cohort; #381's entry clear + trap relay grew it 96 →
/// 120; #413's missing seventh register 120 → 128.
pub const thunk_bytes: usize = literal_pool_off + 16;

comptime {
    if (literal_pool_off % 8 != 0)
        @compileError("bridge thunk literal pool must stay 8-aligned");
}

/// Emit one bridge thunk into `buf[0..thunk_bytes]`. `buf` MUST
/// be exactly `thunk_bytes` long; the caller is responsible for
/// allocating it inside an RX-mappable arena.
///
/// `callee_rt`    — the callee instance's `*JitRuntime` value
///                  to install in X0 before the BLR.
/// `callee_entry` — the callee's JIT entry point.
pub fn emitThunk(buf: []u8, callee_rt: usize, callee_entry: usize) void {
    std.debug.assert(buf.len == thunk_bytes);
    var w = Writer{ .buf = buf };

    // STP X29, X30, [SP, #-frame]! — allocate the frame + save caller's FP+LR.
    w.put(inst.encStpPreIdx(29, 30, inst.sp_reg, -frame_bytes));
    // MOV X29, SP (= ADD X29, SP, #0) — FP-link the thunk's frame into
    // the chain (ADR-0134 D1). Without this the thunk frame is NOT a
    // chain link, so the callee saves the CALLER's X29 with a saved-LR
    // pointing into the thunk → the FP-walk unwinder reaches the caller
    // frame carrying a thunk PC instead of the caller's call-site PC,
    // and a cross-module throw can't find the caller's try_table. SP is
    // unchanged, so the STR/LDR [SP,#N] cohort offsets below stay valid
    // (and X29==SP makes the saved caller_rt readable at [X29,#16]).
    w.put(inst.encAddImm12(29, inst.sp_reg, 0));
    // Reserved-invariant save block.
    for (saved_gprs, 0..) |x, i| w.put(inst.encStrImm(x, inst.sp_reg, slotOf(i)));
    // ADR X16, +<distance> — X16 ← literal pool base.
    w.put(inst.encAdr(16, @intCast(literal_pool_off - w.off)));
    // LDR X0, [X16] — X0 ← callee_rt.
    w.put(inst.encLdrImm(0, 16, 0));
    // STR X0, [SP, #callee_rt_slot] — #381: park callee_rt in the frame. X16
    // is corruptible across the call and X0 returns the callee's result, so
    // the relay below cannot recover it from either.
    w.put(inst.encStrImm(0, inst.sp_reg, callee_rt_slot));
    const flag_off: u15 = jit_abi.trap_flag_off;
    // STR XZR, [X0, #flag_off] — #381 entry clear: zero the callee's
    // trap_flag|trap_kind pair while X0 still holds callee_rt, so the relay
    // below reads THIS call's outcome and not a trap the exporter kept from
    // an earlier one.
    w.put(inst.encStrImm(inst.xzr, 0, flag_off));
    // LDR X16, [X16, #8] — X16 ← callee_entry.
    w.put(inst.encLdrImm(16, 16, 8));
    // BLR X16 — CALL.
    w.put(inst.encBlr(16));
    // Restore the caller's cohort.
    for (saved_gprs, 0..) |x, i| w.put(inst.encLdrImm(x, inst.sp_reg, slotOf(i)));
    // #381 trap relay — X19 now holds caller_rt again, so the store below
    // lands on the CALLER. Reading and writing the same 8-byte offset carries
    // trap_flag AND trap_kind. Conditional, so a clean return cannot clear a
    // flag the caller already holds.
    w.put(inst.encLdrImm(16, inst.sp_reg, callee_rt_slot));
    w.put(inst.encLdrImm(17, 16, flag_off));
    w.put(inst.encCbz(17, 2)); // → LDP
    w.put(inst.encStrImm(17, abi.runtime_ptr_save_gpr, flag_off));
    // LDP X29, X30, [SP], #frame — restore FP+LR, pop frame.
    w.put(inst.encLdpPostIdx(29, 30, inst.sp_reg, frame_bytes));
    // RET — return to importer's call site.
    w.put(inst.encRet(30));

    std.debug.assert(w.off == literal_pool_off);
    std.mem.writeInt(u64, buf[literal_pool_off..][0..8], callee_rt, .little);
    std.mem.writeInt(u64, buf[literal_pool_off + 8 ..][0..8], callee_entry, .little);
}

/// Frame slot holding `saved_gprs[i]`.
fn slotOf(i: usize) u15 {
    return @intCast(save_area_off + 8 * i);
}

/// Append-only instruction cursor, so the thunk's offsets are counted rather
/// than written down.
const Writer = struct {
    buf: []u8,
    off: usize = 0,

    fn put(w: *Writer, word: u32) void {
        std.mem.writeInt(u32, w.buf[w.off..][0..4], word, .little);
        w.off += 4;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Instruction word `i` of the emitted thunk.
fn wordAt(buf: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
}

/// Index of the first instruction after the save block — the ADR that loads
/// the literal pool base. Everything before it is frame setup + saves.
const adr_idx: usize = 2 + saved_gprs.len;
/// Index of the BLR: ADR, LDR X0, STR X0, STR XZR, LDR X16, then the call.
const blr_idx: usize = adr_idx + 5;
/// Index of the first restore.
const restore_idx: usize = blr_idx + 1;
/// Index of the trap relay's first instruction.
const relay_idx: usize = restore_idx + saved_gprs.len;

test "emitThunk: encoding round-trip via helpers" {
    // Re-derive each instruction via the encoder helpers rather
    // than hardcoding byte sequences — keeps the test stable
    // across future thunk reshuffles (was bitten by the §A1 →
    // §A2 grow from 56 → 96 bytes).
    var buf: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    emitThunk(&buf, callee_rt, callee_entry);

    try testing.expectEqual(inst.encStpPreIdx(29, 30, inst.sp_reg, -frame_bytes), wordAt(&buf, 0));
    try testing.expectEqual(inst.encAddImm12(29, inst.sp_reg, 0), wordAt(&buf, 1)); // MOV X29, SP (D1)
    for (saved_gprs, 0..) |x, i| {
        try testing.expectEqual(inst.encStrImm(x, inst.sp_reg, slotOf(i)), wordAt(&buf, 2 + i));
        try testing.expectEqual(inst.encLdrImm(x, inst.sp_reg, slotOf(i)), wordAt(&buf, restore_idx + i));
    }
    try testing.expectEqual(inst.encAdr(16, @intCast(literal_pool_off - adr_idx * 4)), wordAt(&buf, adr_idx));
    try testing.expectEqual(inst.encLdrImm(0, 16, 0), wordAt(&buf, adr_idx + 1));
    try testing.expectEqual(inst.encStrImm(0, inst.sp_reg, callee_rt_slot), wordAt(&buf, adr_idx + 2));
    // #381 entry clear.
    try testing.expectEqual(inst.encStrImm(inst.xzr, 0, jit_abi.trap_flag_off), wordAt(&buf, adr_idx + 3));
    try testing.expectEqual(inst.encLdrImm(16, 16, 8), wordAt(&buf, adr_idx + 4));
    try testing.expectEqual(inst.encBlr(16), wordAt(&buf, blr_idx));
    // #381 trap relay.
    try testing.expectEqual(inst.encLdrImm(16, inst.sp_reg, callee_rt_slot), wordAt(&buf, relay_idx));
    try testing.expectEqual(inst.encLdrImm(17, 16, jit_abi.trap_flag_off), wordAt(&buf, relay_idx + 1));
    try testing.expectEqual(inst.encCbz(17, 2), wordAt(&buf, relay_idx + 2));
    try testing.expectEqual(inst.encStrImm(17, 19, jit_abi.trap_flag_off), wordAt(&buf, relay_idx + 3));
    try testing.expectEqual(inst.encLdpPostIdx(29, 30, inst.sp_reg, frame_bytes), wordAt(&buf, relay_idx + 4));
    try testing.expectEqual(inst.encRet(30), wordAt(&buf, relay_idx + 5));
    try testing.expectEqual(callee_rt, std.mem.readInt(u64, buf[literal_pool_off..][0..8], .little));
    try testing.expectEqual(callee_entry, std.mem.readInt(u64, buf[literal_pool_off + 8 ..][0..8], .little));
}

// #413 — the property the layout above is only one expression of: the emitted
// bytes save and restore EVERY register `abi.zig` reserves, each in a frame
// slot of its own, around the call. Read out of the instruction stream rather
// than off known offsets. A new reservation is carried by construction now, so
// what this holds down is the way back: an emit that writes the cohort out
// again reddens here instead of waiting for a cross-module program that
// happens to use the register it dropped. Pure encoding, so an x86_64 host
// runs it too.
test "emitThunk: the save set is abi.reserved_invariant_gprs, not a copy of it (#413)" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0xDEADBEEF, 0xCAFEBABE);

    var blr_at: ?usize = null;
    for (0..instruction_count) |i| {
        if (wordAt(&buf, i) == inst.encBlr(16)) blr_at = i;
    }
    const call = blr_at orelse return error.TestUnexpectedResult;

    var slot_taken = [_]bool{false} ** saved_gprs.len;
    for (abi.reserved_invariant_gprs) |x| {
        var saved_at: ?u15 = null;
        for (0..call) |i| {
            for (0..saved_gprs.len) |slot| {
                const off = slotOf(slot);
                if (wordAt(&buf, i) == inst.encStrImm(x, inst.sp_reg, off)) {
                    try testing.expectEqual(@as(?u15, null), saved_at); // one slot, not two
                    saved_at = off;
                }
            }
        }
        // A register the callee's prologue may overwrite, never stacked.
        const off = saved_at orelse return error.TestUnexpectedResult;
        // Two registers in one slot restores one of them with the other's
        // value, which is #413 again with a different register.
        const slot = (off - save_area_off) / 8;
        try testing.expect(!slot_taken[slot]);
        slot_taken[slot] = true;
        var restored = false;
        for (call + 1..instruction_count) |i| {
            if (wordAt(&buf, i) == inst.encLdrImm(x, inst.sp_reg, off)) restored = true;
        }
        // Saved on the way in and dropped on the way out is the same corruption.
        try testing.expect(restored);
    }
}

// #381 — the relay's meaning, apart from its byte offsets: it reads the
// CALLEE's runtime (parked in the frame) and writes the CALLER's (X19, already
// restored), at the same offset, and the CBZ lands on the epilogue rather than
// inside the store. A reshuffle that keeps the encodings but swaps the two
// runtimes would still report no trap; this is what catches that.
test "emitThunk: the trap relay reads the callee's runtime and writes the caller's (#381)" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0);
    // Load base = X16 (the parked callee_rt); store base = X19 (caller_rt).
    try testing.expectEqual(inst.encLdrImm(17, 16, jit_abi.trap_flag_off), wordAt(&buf, relay_idx + 1));
    try testing.expectEqual(inst.encStrImm(17, 19, jit_abi.trap_flag_off), wordAt(&buf, relay_idx + 3));
    // The X19 restore precedes the store — otherwise it would land on the callee.
    try testing.expectEqual(inst.encLdrImm(19, inst.sp_reg, slotOf(0)), wordAt(&buf, restore_idx));
    // CBZ +2 words from the CBZ = the LDP epilogue.
    try testing.expectEqual(inst.encLdpPostIdx(29, 30, inst.sp_reg, frame_bytes), wordAt(&buf, relay_idx + 2 + 2));
    // The entry clear zeroes the CALLEE's pair (base X0 = callee_rt) before the
    // call, so the load above cannot see an earlier call's trap.
    try testing.expectEqual(inst.encStrImm(inst.xzr, 0, jit_abi.trap_flag_off), wordAt(&buf, adr_idx + 3));
}

test "emitThunk: round-trip literals at zero" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[literal_pool_off..][0..8], .little));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[literal_pool_off + 8 ..][0..8], .little));
    // Instruction prefix unchanged regardless of literals.
    try testing.expectEqual(inst.encStpPreIdx(29, 30, inst.sp_reg, -frame_bytes), wordAt(&buf, 0));
    try testing.expectEqual(inst.encRet(30), wordAt(&buf, instruction_count - 1));
}

test "emitThunk: instruction prefix is constant across two distinct callees" {
    var buf_a: [thunk_bytes]u8 = undefined;
    var buf_b: [thunk_bytes]u8 = undefined;
    emitThunk(&buf_a, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888);
    emitThunk(&buf_b, 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111);
    // Every instruction must match — only the literal pool differs between
    // thunks.
    try testing.expectEqualSlices(u8, buf_a[0..literal_pool_off], buf_b[0..literal_pool_off]);
}

// The layout the derived constants produce today, written down so that a
// change to any of them has to be deliberate. The emit shares those constants,
// so nothing else in this file states the frame's shape as a number.
test "emitThunk: the current frame layout (#413)" {
    try testing.expectEqual(@as(i10, 80), frame_bytes);
    try testing.expectEqual(@as(u15, 72), callee_rt_slot);
    try testing.expectEqual(@as(u15, 16), slotOf(0));
    try testing.expectEqual(@as(usize, 112), literal_pool_off);
}
