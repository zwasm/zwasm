//! ARM64 cross-module import bridge thunk encoder
//! (ADR-0066 + Amendment §A1 + §A2 (D-144), D-142 fix (A.2), ADR-0228
//! signature-aware bridge).
//!
//! Each thunk is a fixed-size native code snippet (`thunk_bytes`) that wraps
//! a call-and-return around the callee's JIT entry, **saving the caller's
//! reserved-invariant cohort** (`abi.reserved_invariant_gprs`: X19 and
//! X23..X28, per ADR-0017 / ADR-0018 / ADR-0027) across the call so the
//! importer's view survives the callee's prologue overwrite, **copying the
//! importer's overflow (stack) arguments** into its own outgoing area so the
//! callee finds them at `[X29, #16 + …]` — directly above the frame of
//! whoever BLR'd it, which is this thunk, not the importer (ADR-0228, #390) —
//! and clearing + relaying the callee's trap fields (#381).
//!
//! The save block is DERIVED from `abi.reserved_invariant_gprs` (#413): the
//! hand-written six-register list it replaced skipped X23, the globals base,
//! so an importer that used globals read the exporter's globals after a
//! cross-module call to a callee that used its own. D-144 had found the same
//! shape for X24..X28 (`imports.1.wasm print64` `call_indirect sig`
//! mismatch: X24 pointed at the callee's typeidx_base). The cohort is the
//! array's, whatever it holds; the frame size follows it.
//!
//! Layout (`n` = overflow words per `op_call.computeCallOverflowBytes`,
//! `cb` = `n * 8` rounded up to 16; cohort `Ri` = `reserved_invariant_gprs[i]`):
//!
//! ```text
//! offset  encoding                          disassembly
//! 0x00    STP X29, X30, [SP, #-80]!         ; alloc 80-byte frame, save FP+LR
//! 0x04    MOV X29, SP  (ADD X29,SP,#0)      ; FP-link the thunk frame (ADR-0134 D1)
//! 0x08    STR R0, [SP, #16]                 ; save caller's cohort: X19 = caller_rt,
//! ..      STR Ri, [SP, #16 + 8*i]           ;   X23 globals_base, X24 typeidx_base,
//! 0x20    STR R6, [SP, #64]                 ;   X25 table_size, X26 funcptr_base, X27 mem_limit, X28 vm_base
//! 0x24    ADR X16, +116                     ; X16 ← literal pool base
//! 0x28    LDR X0,  [X16]                    ; X0  ← callee_rt
//! 0x2C    STR X0,  [SP, #72]                ; #381: park callee_rt in the frame
//! 0x30    STR XZR, [X0, #40]                ; #381 entry clear: callee trap_flag|kind
//! 0x34    LDR X16, [X16, #8]                ; X16 ← callee_entry
//! 0x38    SUB SP, SP, #cb                   ; outgoing area for the copied words
//! 0x3C    MOVZ X9, #n                       ; words left to copy
//! 0x40    CBZ  X9, +7                       ; n == 0 → BLR
//! 0x44    ADD  X10, X29, #80                ; importer's overflow word 0 (above this frame)
//! 0x48    ADD  X11, SP, #0                  ; this frame's word 0
//! 0x4C    SUB  X9, X9, #1                   ; loop:
//! 0x50    LDR  X17, [X10, X9, LSL #3]
//! 0x54    STR  X17, [X11, X9, LSL #3]
//! 0x58    CBNZ X9, -3                       ; until word 0 is copied
//! 0x5C    BLR X16                           ; CALL (LR ← PC+4)
//! 0x60    ADD SP, SP, #cb                   ; drop the outgoing area
//! 0x64    LDR R0, [SP, #16]                 ; RESTORE caller's cohort
//! ..      LDR Ri, [SP, #16 + 8*i]
//! 0x7C    LDR R6, [SP, #64]
//! 0x80    LDR X16, [SP, #72]                ; #381 relay: X16 ← callee_rt
//! 0x84    LDR X17, [X16, #40]               ; X17 ← callee trap_flag|trap_kind
//! 0x88    CBZ X17, +2                       ; no trap → skip the store
//! 0x8C    STR X17, [X19, #40]               ; relay onto the CALLER's runtime
//! 0x90    LDP X29, X30, [SP], #80           ; restore FP+LR, pop frame
//! 0x94    RET                               ; return to importer
//! 0x98    .quad callee_rt                   ; literal pool
//! 0xA0    .quad callee_entry
//! ```
//!
//! 38 × 4-byte instructions + 16-byte literal pool = 168 bytes. Every
//! per-signature difference is an immediate (`#n`, `#cb`), so ONE
//! `thunk_bytes` serves every callee and the arena stays slot-indexed. The
//! copy is a loop rather than `n` unrolled pairs for the same reason (the
//! arg cap is 128). `ADR X16, +<offset>` resolves from the ADR's PC (0x24)
//! to the literal pool (0x98) — distance = 116 bytes.
//!
//! Overflow copy (ADR-0228, #390 shape 1): the importer wrote overflow word
//! `k` at `[SP, #8k]` and BLR'd; this thunk's 80-byte frame now sits below
//! it, so it is at `[X29, #80 + 8k]` (`frame_bytes`, not the 16 of a plain
//! FP/LR frame — the aarch64-macos leg caught that one). The callee's
//! prologue (`STP X29, X30, [SP, #-16]!; MOV X29, SP`) reads word `k` at
//! `[X29_callee, #16 + 8k]` = `[SP_at_BLR, #8k]`, so the words are copied to
//! the bottom of this frame before the BLR. `n` counts 8-byte words per `computeCallOverflowBytes`;
//! on Apple targets the importer packs narrower scalars naturally
//! (`marshalCallArgs`), so `8n` is an upper bound of the region and the copy
//! carries the packed bytes unchanged — it is a byte copy, not a re-marshal.
//! SP stays 16-aligned because `cb` is.
//!
//! MEMORY-class (#390 shape 2): AAPCS64 passes the hidden result pointer in
//! X8, which the thunk never touches (X9..X11 and X16/X17 are its scratch),
//! and the runtime stays in X0 as for every callee; nothing to place.
//!
//! Entry clear + trap relay (#381): the thunk is a JIT entry into another
//! instance's runtime; it zeroes the callee's `trap_flag`/`trap_kind` pair on
//! the way in (while X0 holds callee_rt) so the relay reads THIS call's
//! outcome, and after the cohort restore copies a set pair onto the CALLER's
//! runtime (X19) so the importer's existing post-call check fires unchanged
//! (`op_call.zig:emitPostCallTrapCheck`). The two u32 fields are adjacent, so
//! one 8-byte load/store carries both — asserted at comptime.
//!
//! X9..X11, X16, X17 are caller-saved temporaries outside the regalloc pool
//! (`abi.zig`), spilled by the call site before the call
//! (`op_call.zig:spillHomedCallerSaved`), so the loop may clobber them. X0
//! carries callee_rt into the callee; X1..X7, V0..V7 and X8 are untouched.
//!
//! Frame layout: `[SP+0]=X29, [SP+8]=X30, [SP+16+8i]=cohort[i],
//! [SP+72]=callee_rt (#381 relay)`. 80 bytes keeps SP 16-byte-aligned per
//! AAPCS64 §6.4.5.1; FP/LR sit at the bottom matching the standard unwinder
//! frame shape so a debugger can walk past the thunk.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const op_call = @import("op_call.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const zir = @import("../../../ir/zir.zig");

/// The registers saved around the call: the whole reserved-invariant set,
/// so a register added to it is saved here without anyone remembering (#413).
const cohort = abi.reserved_invariant_gprs;
/// Frame: FP/LR pair + one slot per cohort register + the parked callee_rt.
const cohort_base: u15 = 16;
/// #381 — frame slot the thunk parks `callee_rt` in across the call, so the
/// trap relay can read the callee's runtime after X16/X0 are gone.
const callee_rt_slot: u15 = cohort_base + 8 * @as(u15, cohort.len);
const frame_bytes: u15 = callee_rt_slot + 8;

comptime {
    // AAPCS64 §6.4.5.1 — SP stays 16-aligned; STP/LDP pre/post-index imm7.
    if (frame_bytes % 16 != 0) @compileError("bridge thunk frame is not a multiple of 16");
    if (frame_bytes > 504) @compileError("bridge thunk frame exceeds the STP pre-index range");
    // The relay below copies `trap_flag` and `trap_kind` as one 8-byte pair,
    // and `encLdrImm`/`encStrImm` require an 8-aligned byte offset.
    if (jit_abi.trap_kind_off != jit_abi.trap_flag_off + 4)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; they are no longer adjacent");
    if (jit_abi.trap_flag_off % 8 != 0)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; trap_flag_off is no longer 8-aligned");
    // The relay stores onto the CALLER's runtime through X19; the cohort
    // restore must have put it back, i.e. X19 must be in the cohort.
    if (abi.runtime_ptr_save_gpr != 19 or std.mem.findScalar(inst.Xn, &cohort, 19) == null)
        @compileError("bridge thunk relays onto X19 = runtime_ptr_save_gpr; it must be in the saved cohort");
}

/// Instruction count — see the layout table: 2 (frame) + cohort saves + 6
/// (pool, X0, park, clear, entry, SUB SP) + 2 (count, CBZ) + 2 (bases) + 4
/// (loop) + 2 (BLR, ADD SP) + cohort restores + 4 (relay) + 2 (LDP, RET).
const n_insns: usize = 2 + cohort.len + 6 + 2 + 2 + 4 + 2 + cohort.len + 4 + 2;
/// Total thunk size in bytes: the instructions + two quad literals.
pub const thunk_bytes: usize = n_insns * 4 + 16;

/// Emit one bridge thunk into `buf[0..thunk_bytes]` for a callee of
/// signature `sig`. `buf` MUST be exactly `thunk_bytes` long; the caller is
/// responsible for allocating it inside an RX-mappable arena.
///
/// `callee_rt`    — the callee instance's `*JitRuntime` value
///                  to install in X0 before the BLR.
/// `callee_entry` — the callee's JIT entry point.
/// `sig`          — the CALLEE's signature (`FuncImportTarget.sig`).
pub fn emitThunk(buf: []u8, callee_rt: usize, callee_entry: usize, sig: zir.FuncType) void {
    std.debug.assert(buf.len == thunk_bytes);
    const overflow_bytes: u32 = op_call.computeCallOverflowBytes(sig);
    const n_words: u32 = overflow_bytes / 8;
    const copy_bytes: u32 = (overflow_bytes + 15) & ~@as(u32, 15);
    // `marshalCallArgs` caps a call at 128 args, so both immediates fit
    // (MOVZ imm16, ADD/SUB imm12).
    std.debug.assert(n_words <= 0xFFFF and copy_bytes <= 4095);
    const flag_off: u15 = jit_abi.trap_flag_off;

    var off: usize = 0;
    const put = struct {
        fn put(b: []u8, o: *usize, word: u32) void {
            std.mem.writeInt(u32, b[o.*..][0..4], word, .little);
            o.* += 4;
        }
    }.put;

    // STP X29, X30, [SP, #-frame]! — allocate the frame + save caller's FP+LR.
    put(buf, &off, inst.encStpPreIdx(29, 30, inst.sp_reg, -@as(i10, frame_bytes)));
    // MOV X29, SP — FP-link the thunk's frame into the chain (ADR-0134 D1).
    // Without this the callee saves the CALLER's X29 with a saved-LR pointing
    // into the thunk, and the FP-walk unwinder reaches the caller frame
    // carrying a thunk PC instead of its call-site PC. SP is unchanged, so
    // the [SP,#N] cohort offsets below stay valid (and X29==SP makes the
    // saved caller_rt readable at [X29,#16]).
    put(buf, &off, inst.encAddImm12(29, inst.sp_reg, 0));
    // Save the reserved-invariant cohort (#413: the array, not a list).
    inline for (cohort, 0..) |reg, i| {
        put(buf, &off, inst.encStrImm(reg, inst.sp_reg, cohort_base + 8 * @as(u15, i)));
    }
    // ADR X16, +<pool> — the literal pool sits after the last instruction.
    const adr_at = off;
    put(buf, &off, inst.encAdr(16, @intCast(n_insns * 4 - adr_at)));
    // LDR X0, [X16] — X0 ← callee_rt.
    put(buf, &off, inst.encLdrImm(0, 16, 0));
    // STR X0, [SP, #slot] — #381: park callee_rt. X16 is corruptible across
    // the call and X0 returns the callee's result, so the relay cannot
    // recover it from either.
    put(buf, &off, inst.encStrImm(0, inst.sp_reg, callee_rt_slot));
    // STR XZR, [X0, #40] — #381 entry clear while X0 still holds callee_rt.
    put(buf, &off, inst.encStrImm(inst.xzr, 0, flag_off));
    // LDR X16, [X16, #8] — X16 ← callee_entry.
    put(buf, &off, inst.encLdrImm(16, 16, 8));
    // Overflow copy (ADR-0228): SUB SP for the words, then copy them from
    // the importer's outgoing area — above this frame, [X29, #frame ..] —
    // to this frame's ([SP ..]), highest word first, counting X9 down.
    // Skipped when n == 0.
    put(buf, &off, inst.encSubImm12(inst.sp_reg, inst.sp_reg, @intCast(copy_bytes)));
    put(buf, &off, inst.encMovzImm16(9, @intCast(n_words)));
    put(buf, &off, inst.encCbz(9, 7)); // → BLR
    put(buf, &off, inst.encAddImm12(10, 29, frame_bytes));
    put(buf, &off, inst.encAddImm12(11, inst.sp_reg, 0));
    put(buf, &off, inst.encSubImm12(9, 9, 1)); // loop:
    put(buf, &off, inst.encLdrXRegLsl3(17, 10, 9));
    put(buf, &off, inst.encStrXRegLsl3(17, 11, 9));
    put(buf, &off, inst.encCbnz(9, -3)); // → loop
    // BLR X16 — CALL.
    put(buf, &off, inst.encBlr(16));
    // ADD SP, SP, #cb — drop the outgoing area so the [SP,#N] slots line up.
    put(buf, &off, inst.encAddImm12(inst.sp_reg, inst.sp_reg, @intCast(copy_bytes)));
    // Restore the cohort.
    inline for (cohort, 0..) |reg, i| {
        put(buf, &off, inst.encLdrImm(reg, inst.sp_reg, cohort_base + 8 * @as(u15, i)));
    }
    // #381 trap relay — X19 now holds caller_rt again, so the store below
    // lands on the CALLER. Reading and writing the same 8-byte offset carries
    // trap_flag AND trap_kind. Conditional, so a clean return cannot clear a
    // flag the caller already holds.
    put(buf, &off, inst.encLdrImm(16, inst.sp_reg, callee_rt_slot));
    put(buf, &off, inst.encLdrImm(17, 16, flag_off));
    put(buf, &off, inst.encCbz(17, 2)); // → LDP
    put(buf, &off, inst.encStrImm(17, abi.runtime_ptr_save_gpr, flag_off));
    // LDP X29, X30, [SP], #frame — restore FP+LR, pop frame.
    put(buf, &off, inst.encLdpPostIdx(29, 30, inst.sp_reg, frame_bytes));
    // RET — return to importer's call site.
    put(buf, &off, inst.encRet(30));
    std.debug.assert(off == n_insns * 4);
    // Literal pool (8-aligned: every instruction is 4 bytes and the count
    // is even — asserted at comptime below).
    std.mem.writeInt(u64, buf[off..][0..8], callee_rt, .little);
    std.mem.writeInt(u64, buf[off + 8 ..][0..8], callee_entry, .little);
}

comptime {
    if ((n_insns * 4) % 8 != 0) @compileError("bridge thunk literal pool is not 8-aligned");
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const i32s = [_]zir.ValType{.i32} ** 12;
const one = [_]zir.ValType{.i32};
const three = [_]zir.ValType{ .i32, .i32, .i32 };

fn sigOf(params: []const zir.ValType, results: []const zir.ValType) zir.FuncType {
    return .{ .params = params, .results = results };
}

fn wordAt(buf: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
}

test "thunk_bytes: 38 instructions + 16-byte pool for the seven-register cohort" {
    try testing.expectEqual(@as(usize, 7), cohort.len);
    try testing.expectEqual(@as(usize, 168), thunk_bytes);
    try testing.expectEqual(@as(u15, 80), frame_bytes);
    try testing.expectEqual(@as(u15, 72), callee_rt_slot);
}

test "emitThunk: encoding round-trip via helpers" {
    // Re-derive each instruction via the encoder helpers rather than
    // hardcoding byte sequences — keeps the test stable across thunk
    // reshuffles (was bitten by the §A1 → §A2 grow from 56 → 96 bytes).
    var buf: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    emitThunk(&buf, callee_rt, callee_entry, sigOf(&.{}, &one));

    var i: usize = 0;
    try testing.expectEqual(inst.encStpPreIdx(29, 30, inst.sp_reg, -80), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encAddImm12(29, inst.sp_reg, 0), wordAt(&buf, i)); // MOV X29, SP (D1)
    i += 1;
    inline for (cohort, 0..) |reg, k| {
        try testing.expectEqual(inst.encStrImm(reg, inst.sp_reg, 16 + 8 * k), wordAt(&buf, i));
        i += 1;
    }
    try testing.expectEqual(inst.encAdr(16, 116), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encLdrImm(0, 16, 0), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encStrImm(0, inst.sp_reg, callee_rt_slot), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encStrImm(inst.xzr, 0, jit_abi.trap_flag_off), wordAt(&buf, i)); // #381 entry clear
    i += 1;
    try testing.expectEqual(inst.encLdrImm(16, 16, 8), wordAt(&buf, i));
    i += 1;
    // No overflow: SUB SP, #0; MOVZ X9, #0; the CBZ jumps to the BLR.
    try testing.expectEqual(inst.encSubImm12(inst.sp_reg, inst.sp_reg, 0), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encMovzImm16(9, 0), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encCbz(9, 7), wordAt(&buf, i));
    const cbz_at = i;
    i += 1;
    try testing.expectEqual(inst.encAddImm12(10, 29, frame_bytes), wordAt(&buf, i)); // importer's words sit ABOVE this frame
    i += 1;
    try testing.expectEqual(inst.encAddImm12(11, inst.sp_reg, 0), wordAt(&buf, i));
    i += 1;
    const loop_at = i;
    try testing.expectEqual(inst.encSubImm12(9, 9, 1), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encLdrXRegLsl3(17, 10, 9), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encStrXRegLsl3(17, 11, 9), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encCbnz(9, -3), wordAt(&buf, i));
    try testing.expectEqual(loop_at, i - 3);
    i += 1;
    try testing.expectEqual(inst.encBlr(16), wordAt(&buf, i));
    try testing.expectEqual(cbz_at + 7, i);
    i += 1;
    try testing.expectEqual(inst.encAddImm12(inst.sp_reg, inst.sp_reg, 0), wordAt(&buf, i));
    i += 1;
    inline for (cohort, 0..) |reg, k| {
        try testing.expectEqual(inst.encLdrImm(reg, inst.sp_reg, 16 + 8 * k), wordAt(&buf, i));
        i += 1;
    }
    // #381 trap relay.
    try testing.expectEqual(inst.encLdrImm(16, inst.sp_reg, callee_rt_slot), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encLdrImm(17, 16, jit_abi.trap_flag_off), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encCbz(17, 2), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encStrImm(17, 19, jit_abi.trap_flag_off), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encLdpPostIdx(29, 30, inst.sp_reg, 80), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(inst.encRet(30), wordAt(&buf, i));
    i += 1;
    try testing.expectEqual(n_insns, i);
    try testing.expectEqual(callee_rt, std.mem.readInt(u64, buf[i * 4 ..][0..8], .little));
    try testing.expectEqual(callee_entry, std.mem.readInt(u64, buf[i * 4 + 8 ..][0..8], .little));
}

// #413 — the save block is the whole reserved-invariant set, X23 included,
// and every saved register is restored from the same slot.
test "emitThunk: saves and restores every abi.reserved_invariant_gprs register, X23 included (#413)" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0, sigOf(&.{}, &one));
    var saved: [32]bool = .{false} ** 32;
    var restored: [32]bool = .{false} ** 32;
    var i: usize = 0;
    while (i < n_insns) : (i += 1) {
        const w = wordAt(&buf, i);
        inline for (abi.reserved_invariant_gprs, 0..) |reg, k| {
            if (w == inst.encStrImm(reg, inst.sp_reg, 16 + 8 * k)) saved[reg] = true;
            if (w == inst.encLdrImm(reg, inst.sp_reg, 16 + 8 * k)) restored[reg] = true;
        }
    }
    for (abi.reserved_invariant_gprs) |reg| {
        try testing.expect(saved[reg]);
        try testing.expect(restored[reg]);
    }
    try testing.expect(saved[abi.globals_base_save_gpr]);
    try testing.expect(restored[abi.globals_base_save_gpr]);
}

// ADR-0228 / #390 shape 1 — the copy is sized by the call site's own rule,
// SP stays 16-aligned, and the count immediate is the word count.
test "emitThunk: the overflow copy follows computeCallOverflowBytes and keeps SP 16-aligned (#390)" {
    var n_params: usize = 0;
    while (n_params <= 12) : (n_params += 1) {
        for ([_]zir.FuncType{ sigOf(i32s[0..n_params], &one), sigOf(i32s[0..n_params], &three) }) |sig| {
            var buf: [thunk_bytes]u8 = undefined;
            emitThunk(&buf, 0, 0, sig);
            const overflow = op_call.computeCallOverflowBytes(sig);
            const cb: u12 = @intCast((overflow + 15) & ~@as(u32, 15));
            try testing.expectEqual(@as(u32, 0), cb % 16);
            // SUB SP / MOVZ sit right after the entry LDR (index 2 + cohort + 5).
            const at = 2 + cohort.len + 5;
            try testing.expectEqual(inst.encSubImm12(inst.sp_reg, inst.sp_reg, cb), wordAt(&buf, at));
            try testing.expectEqual(inst.encMovzImm16(9, @intCast(overflow / 8)), wordAt(&buf, at + 1));
            // ...and the ADD after the BLR undoes exactly the SUB.
            try testing.expectEqual(inst.encAddImm12(inst.sp_reg, inst.sp_reg, cb), wordAt(&buf, at + 10));
        }
    }
    // Seven ints fit X1..X7; the eighth is the first word.
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0, sigOf(i32s[0..8], &one));
    try testing.expectEqual(inst.encMovzImm16(9, 1), wordAt(&buf, 2 + cohort.len + 6));
}

test "emitThunk: distinct callee pairs differ only in the literal pool" {
    var a: [thunk_bytes]u8 = undefined;
    var b: [thunk_bytes]u8 = undefined;
    emitThunk(&a, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888, sigOf(&.{}, &one));
    emitThunk(&b, 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111, sigOf(&.{}, &one));
    try testing.expectEqualSlices(u8, a[0 .. n_insns * 4], b[0 .. n_insns * 4]);
    try testing.expect(!std.mem.eql(u8, a[n_insns * 4 ..], b[n_insns * 4 ..]));
}
