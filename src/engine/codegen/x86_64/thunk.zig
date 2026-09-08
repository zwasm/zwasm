//! x86_64 cross-module import bridge thunk encoder
//! (ADR-0066 + Amendment §A1, D-142 fix (A.3), D-238/ADR-0185 (a) RBP
//! frame-link, ADR-0228 signature-aware bridge).
//!
//! Each thunk is a fixed-size native code snippet (`thunk_bytes`) that wraps
//! a call-and-return around the callee's JIT entry. It: **(1)** establishes
//! a standard `PUSH RBP; MOV RBP,RSP` frame so the cross-instance EH unwinder
//! can walk THROUGH the thunk (D-238 — `[RBP,0]`=saved importer RBP,
//! `[RBP,8]`=importer return address, making the thunk frame a chain link);
//! **(2)** saves the caller's R15 (`runtime_ptr_save_gpr`) across the CALL;
//! **(3)** copies the importer's overflow (stack) arguments into its own
//! outgoing area, so the callee finds them where its prologue looks
//! (`emit.zig`: `[RBP + 16 + r15_save + 8*slot]`, i.e. directly above the
//! frame of whoever CALLed it — which is this thunk, not the importer);
//! **(4)** installs the callee's runtime in the slot the callee's signature
//! reserves for it — entry-arg0 normally, arg1 when the return is
//! MEMORY-class and entry-arg0 carries the hidden result-buffer pointer the
//! importer LEA'd (`op_call.zig:emitCall`); **(5)** clears and relays the
//! callee's trap fields (#381); **(6)** keeps `CALL RAX` 16-byte aligned.
//! Mirrors the arm64 thunk (`arm64/thunk.zig`).
//!
//! Layout (`sh` = `shadow_space_bytes`: 0 SysV / 32 Win64; `n` = overflow
//! words per `op_call.computeCallOverflowBytesCc`; `ap` = 8 when `n` is
//! even, 0 when odd; `rt` = the runtime's register, see (4)):
//!
//! ```text
//! offset  encoding                            disassembly
//! 0x00    55                                  PUSH RBP           ; frame link (saved importer RBP)
//! 0x01    48 89 E5                            MOV  RBP, RSP      ; [RBP,8] = importer retaddr
//! 0x04    41 57                               PUSH R15           ; save caller's R15 (= caller_rt)
//! 0x06    48 81 EC <ap LE4>                   SUB  RSP, ap       ; parity pad: n pushes + ap → 16-aligned
//! 0x0D    4C 8D 9D <16+sh LE4>                LEA  R11, [RBP+16+sh]     ; importer's overflow word 0
//! 0x14    4C 8D 95 <16+sh+8n LE4>             LEA  R10, [RBP+16+sh+8n]  ; one past its last word
//! 0x1B    4D 39 DA                            CMP  R10, R11
//! 0x1E    74 0F                               JE   +15           ; n == 0 → no copy
//! 0x20    49 81 C2 F8 FF FF FF                ADD  R10, -8       ; loop: previous word
//! 0x27    41 FF 32                            PUSH qword [R10]   ; copy it down (highest first)
//! 0x2A    4D 39 DA                            CMP  R10, R11
//! 0x2D    75 F1                               JNE  -15           ; until word 0 is pushed
//! 0x2F    48 81 EC <sh LE4>                   SUB  RSP, sh       ; Win64 home area below the copy
//! 0x36    45 31 D2                            XOR  R10D, R10D    ; #381 entry clear
//! 0x39    48 B? <callee_rt LE 8 bytes>        MOV  rt, imm64     ; RDI/RCX, or RSI/RDX when MEMORY-class
//! 0x43    4C 89 ?? <40 LE4>                   MOV  [rt+40], R10  ; clear callee trap_flag|kind
//! 0x4A    48 B8 <callee_entry LE 8 bytes>     MOV  RAX, imm64
//! 0x54    FF D0                               CALL RAX           ; RSP ≡ 0 (mod 16) here
//! 0x56    48 81 C4 <sh+8n+ap LE4>             ADD  RSP, sh+8n+ap ; drop copy + pads
//! 0x5D    41 5F                               POP  R15           ; restore caller's R15
//! 0x5F    49 BB <callee_rt LE 8 bytes>        MOV  R11, imm64    ; #381 trap relay: callee_rt
//! 0x69    4D 8B 93 <40 LE4>                   MOV  R10, [R11+40] ; trap_flag|trap_kind pair
//! 0x70    4D 85 D2                            TEST R10, R10
//! 0x73    74 07                               JE   +7            ; no trap -> skip
//! 0x75    4D 89 97 <40 LE4>                   MOV  [R15+40], R10 ; relay onto the CALLER
//! 0x7C    5D                                  POP  RBP           ; restore importer's RBP
//! 0x7D    C3                                  RET                ; return to importer
//! ```
//!
//! 126 bytes. Every per-signature difference is an immediate or a register
//! number of the same encoded length, so ONE `thunk_bytes` serves every
//! callee and both conventions and the arena stays slot-indexed. The copy
//! is a loop rather than `n` unrolled moves for the same reason: the arg cap
//! is 128 (`marshalCallArgs`), and an unrolled copy at that size would be
//! ~15× this thunk. The literals are embedded in the MOV imm64s (no pool),
//! so the thunk is position-independent.
//!
//! Overflow copy (ADR-0228, #390 shape 1): the importer wrote overflow word
//! `k` at `[RSP + sh + 8k]` and CALLed, so at thunk entry it is at
//! `[RSP + 8 + sh + 8k]` = `[RBP + 16 + sh + 8k]` after the frame link. The
//! callee reads word `k` at `[RSP_at_CALL + sh + 8k]` (its `[RBP + 16 + 8 +
//! sh + 8k]` after `PUSH RBP; PUSH R15`). Pushing the importer's words from
//! the highest down rebuilds the region at the bottom of this frame; the
//! Win64 home area is then reserved below it. Alignment: entry RSP ≡ 8, two
//! pushes → ≡ 8, `ap` and `n` pushes together add a multiple of 16 (`ap` is 8
//! exactly when `n` is even), and `sh` is a multiple of 16 — so the CALL lands
//! on a 16-byte boundary for every `n`. For `n = 0` this is the pre-ADR-0228
//! frame (`SUB RSP, sh + 8`), now in two instructions.
//!
//! A SysV v128 overflow argument is not counted by
//! `computeCallOverflowBytesCc` (two 16-aligned eightbytes; excluded on the
//! call site too), so the facade still declines any v128 parameter
//! (`api/instance.zig`). Win64 passes v128 as a hidden pointer, which is a
//! word like any other, but the decline is uniform.
//!
//! MEMORY-class (#390 shape 2): `emitCall` LEAs the hidden buffer pointer
//! into entry-arg0 and `emitImportDispatch` moves the runtime to arg1, as the
//! same-module CALL does; this thunk writes the callee's runtime to the SAME
//! slot and never touches entry-arg0, so the pointer reaches the callee's
//! prologue intact.
//!
//! Entry clear + trap relay (#381): the thunk is a JIT entry into another
//! instance's runtime; it zeroes the callee's `trap_flag`/`trap_kind` pair on
//! the way in (through `rt`, which still holds callee_rt) so the relay reads
//! THIS call's outcome, and after `POP R15` copies a set pair onto the
//! CALLER's runtime so the importer's existing post-call check fires
//! unchanged (`op_control.zig:emitPostCallTrapCheck`). The two u32 fields are
//! adjacent, so one 8-byte load/store carries both — asserted at comptime.
//!
//! R10/R11 are volatile in BOTH SysV and Win64, outside the reserved set
//! (`abi.zig:reserved_invariant_gprs` = {R15}) and reloaded by the call site
//! after the call (`op_call.zig:reloadHomedCallerSaved`), so the loop and the
//! relay may clobber them. RAX is loaded last, after the loop. The argument
//! registers, XMM0..7 and the return registers are untouched.
//!
//! R15: the callee's prologue PUSHes R15 before overwriting it
//! (`emit.zig` `PUSH RBP; PUSH R15; MOV RBP,RSP`; `frame_teardown.zig` pops
//! it), so a JIT callee returns it intact and the save here is belt and
//! braces — it also keeps `[RBP-8]` = caller_rt readable for the unwinder's
//! sniff (`frame_chain.zig`). arm64 differs: its callee does not save the
//! cohort, so its thunk must (`arm64/thunk.zig`, #413).
//!
//! **Cc-aware since #385.** Everything convention-dependent derives from the
//! `abi.sysv` / `abi.win64` tables: the runtime register, the shadow size,
//! and (through `computeCallOverflowBytesCc`) where the overflow begins.
//! `emitThunkCc` takes the convention at comptime so the Win64 layout is
//! testable from a SysV host; the Windows CI leg is the only instrument that
//! executes it.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const op_call = @import("op_call.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const zir = @import("../../../ir/zir.zig");

comptime {
    // The CALL alignment argument above needs a 16-multiple shadow. Both
    // conventions satisfy it today (0 and 32).
    if (abi.sysv.shadow_space_bytes % 16 != 0 or abi.win64.shadow_space_bytes % 16 != 0)
        @compileError("bridge thunk frame pad assumes a 16-multiple shadow space");
    // The relay below copies `trap_flag` and `trap_kind` as one 8-byte pair.
    if (jit_abi.trap_kind_off != jit_abi.trap_flag_off + 4)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; they are no longer adjacent");
    if (jit_abi.trap_flag_off % 8 != 0)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; trap_flag_off is no longer 8-aligned");
    // R15 is written literally in the PUSH/POP below, in the trap relay's
    // store, and in this file's byte offsets, under both conventions.
    // `x86_64/abi.zig` asserts the same thing, but whoever moves the
    // reservation edits that file and its tests together; the assumption
    // lives here, so the failure has to name this file.
    if (abi.reserved_invariant_gprs.len != 1 or abi.runtime_ptr_save_gpr != .r15 or
        abi.sysv.runtime_ptr_save_gpr != .r15 or abi.win64.runtime_ptr_save_gpr != .r15)
        @compileError("bridge thunk hard-codes R15 as the whole reserved-invariant set; it has moved or grown");
}

/// Total thunk size in bytes — see the layout table. One shape for every
/// callee: the signature only changes immediates and same-length register
/// numbers.
pub const thunk_bytes: usize = 126;

/// Emit one bridge thunk into `buf[0..thunk_bytes]` for a callee of
/// signature `sig`. `buf` MUST be exactly `thunk_bytes` long; the caller is
/// responsible for allocating it inside an RX-mappable arena.
///
/// `callee_rt`    — the callee instance's `*JitRuntime` value, installed in
///                  the register the callee's signature reserves for it.
/// `callee_entry` — the callee's JIT entry point.
/// `sig`          — the CALLEE's signature (`FuncImportTarget.sig`).
pub fn emitThunk(buf: []u8, callee_rt: usize, callee_entry: usize, sig: zir.FuncType) void {
    emitThunkCc(abi.current_cc, buf, callee_rt, callee_entry, sig);
}

/// The body of `emitThunk`, with the calling convention as a comptime
/// parameter. Production always passes `abi.current_cc`; the tests pass
/// both, so the Win64 layout is checked from a SysV host (#385).
pub fn emitThunkCc(comptime cc: abi.Cc, buf: []u8, callee_rt: usize, callee_entry: usize, sig: zir.FuncType) void {
    std.debug.assert(buf.len == thunk_bytes);
    const tables = switch (cc) {
        .sysv => abi.sysv,
        .win64 => abi.win64,
    };
    const shadow: u32 = tables.shadow_space_bytes;
    const overflow_bytes: u32 = op_call.computeCallOverflowBytesCc(cc, sig);
    const n_words: u32 = overflow_bytes / 8;
    // Parity pad: with `n` pushes, the CALL is 16-aligned exactly when
    // `ap + 8n ≡ 8 (mod 16)` — see the alignment note in the header.
    const align_pad: u32 = if (n_words % 2 == 0) 8 else 0;
    // The register the callee's prologue snapshots its runtime pointer from:
    // entry-arg0 (RDI / RCX), or arg1 (RSI / RDX) when entry-arg0 carries the
    // hidden result-buffer pointer (`op_call.zig:emitCall`, MEMORY-class).
    const rt_gpr: abi.Gpr = if (sig.results.len > 2) tables.arg_gprs[1] else tables.entry_arg0_gpr;
    const flag_off: i32 = jit_abi.trap_flag_off;
    // Importer's overflow region, as seen from this frame: word 0 at
    // `[RBP + 16 + shadow]` (16 = saved RBP + return address).
    const src_start: i32 = @intCast(16 + shadow);
    const src_end: i32 = src_start + @as(i32, @intCast(overflow_bytes));

    var off: usize = 0;
    const put = struct {
        fn put(b: []u8, o: *usize, e: inst.EncodedInsn) void {
            @memcpy(b[o.*..][0..e.len], e.slice());
            o.* += e.len;
        }
    }.put;

    // Frame link (D-238 / ADR-0185 a) + caller R15 save (D-142 cohort).
    put(buf, &off, inst.encPushR(.rbp));
    put(buf, &off, inst.encMovRR(.q, .rbp, .rsp));
    put(buf, &off, inst.encPushR(.r15));
    put(buf, &off, inst.encSubRSpImm32(@intCast(align_pad)));
    // Overflow copy loop: R11 = word 0, R10 = one past the last word; push
    // downwards until R10 meets R11. Skipped entirely when n == 0.
    put(buf, &off, inst.encLeaR64BaseDisp32(.r11, .rbp, src_start));
    put(buf, &off, inst.encLeaR64BaseDisp32(.r10, .rbp, src_end));
    const cmp = inst.encCmpRR(.q, .r10, .r11);
    const step = inst.encAddR64Imm32(.r10, -8);
    const push = inst.encPushMem64(.r10);
    const loop_len: usize = step.len + push.len + cmp.len + 2; // + JNE rel8
    put(buf, &off, cmp);
    put(buf, &off, inst.encJccRel8(.e, @intCast(loop_len)));
    const loop_start = off;
    put(buf, &off, step);
    put(buf, &off, push);
    put(buf, &off, cmp);
    put(buf, &off, inst.encJccRel8(.ne, @intCast(-@as(isize, @intCast(off + 2 - loop_start)))));
    std.debug.assert(off - loop_start == loop_len);
    // Win64 home area (#385) below the copied words; SUB RSP, 0 under SysV
    // keeps the shape fixed.
    put(buf, &off, inst.encSubRSpImm32(@intCast(shadow)));
    // #381 entry clear through `rt`, which holds callee_rt until the CALL.
    put(buf, &off, inst.encXorRR(.d, .r10, .r10));
    put(buf, &off, inst.encMovImm64Q(rt_gpr, callee_rt));
    put(buf, &off, inst.encStoreR64MemDisp32(.r10, rt_gpr, flag_off));
    // CALL the callee (RSP ≡ 0 mod 16 here); its RET returns to the ADD.
    put(buf, &off, inst.encMovImm64Q(.rax, callee_entry));
    put(buf, &off, inst.encCallReg(.rax));
    put(buf, &off, inst.encAddRSpImm32(@intCast(shadow + overflow_bytes + align_pad)));
    // Restore caller's R15 FIRST — the relay below stores through it.
    put(buf, &off, inst.encPopR(.r15));
    // #381 trap relay: R11 <- callee_rt (every arg register was clobbered by
    // the callee); R10 <- its trap_flag|trap_kind pair; store onto the caller
    // only when set, so a clean return cannot clear a flag the caller holds.
    const relay_store = inst.encStoreR64MemDisp32(.r10, .r15, flag_off);
    put(buf, &off, inst.encMovImm64Q(.r11, callee_rt));
    put(buf, &off, inst.encMovR64FromMemDisp32(.r10, .r11, flag_off));
    put(buf, &off, inst.encTestRR(.q, .r10, .r10));
    put(buf, &off, inst.encJccRel8(.e, @intCast(relay_store.len)));
    put(buf, &off, relay_store);
    // Restore importer's RBP; return to its call site.
    put(buf, &off, inst.encPopR(.rbp));
    put(buf, &off, inst.encRet());
    std.debug.assert(off == thunk_bytes);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const i32s = [_]zir.ValType{.i32} ** 12;
const f64s = [_]zir.ValType{.f64} ** 12;
const one = [_]zir.ValType{.i32};
const three = [_]zir.ValType{ .i32, .i32, .i32 };

fn sigOf(params: []const zir.ValType, results: []const zir.ValType) zir.FuncType {
    return .{ .params = params, .results = results };
}

// Fixed offsets of the layout table, checked against the encoded lengths so
// the table in the header cannot drift from the code.
const off_sub_pad: usize = 6;
const off_lea_start: usize = 13;
const off_lea_end: usize = 20;
const off_je_skip: usize = 30;
const off_loop: usize = 32;
const off_sub_shadow: usize = 47;
const off_mov_rt: usize = 57;
const off_clear_store: usize = 67;
const off_mov_rax: usize = 74;
const off_call: usize = 84;
const off_add_rsp: usize = 86;
const off_pop_r15: usize = 93;
const off_relay: usize = 95;

fn imm32At(buf: []const u8, at: usize) i32 {
    return @bitCast(std.mem.readInt(u32, buf[at..][0..4], .little));
}

test "emitThunk: byte-exact layout for known constants (SysV, no overflow, one result)" {
    var buf: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    emitThunkCc(.sysv, &buf, callee_rt, callee_entry, sigOf(&.{}, &one));

    try testing.expectEqual(@as(u8, 0x55), buf[0]); // PUSH RBP
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]); // MOV RBP,RSP
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]); // PUSH R15
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xEC, 0x08, 0x00, 0x00, 0x00 }, buf[6..13]); // SUB RSP,8 (n=0 → even → pad 8)
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x8D, 0x9D, 0x10, 0x00, 0x00, 0x00 }, buf[13..20]); // LEA R11,[RBP+16]
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x8D, 0x95, 0x10, 0x00, 0x00, 0x00 }, buf[20..27]); // LEA R10,[RBP+16]
    try testing.expectEqualSlices(u8, inst.encCmpRR(.q, .r10, .r11).slice(), buf[27..30]);
    try testing.expectEqualSlices(u8, &.{ 0x74, 0x0F }, buf[30..32]); // JE +15 → SUB RSP,shadow
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x81, 0xC2, 0xF8, 0xFF, 0xFF, 0xFF }, buf[32..39]); // ADD R10,-8
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xFF, 0x32 }, buf[39..42]); // PUSH qword [R10]
    try testing.expectEqualSlices(u8, inst.encCmpRR(.q, .r10, .r11).slice(), buf[42..45]);
    try testing.expectEqualSlices(u8, &.{ 0x75, 0xF1 }, buf[45..47]); // JNE -15 → ADD R10,-8
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xEC, 0x00, 0x00, 0x00, 0x00 }, buf[47..54]); // SUB RSP,0 (SysV shadow)
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x31, 0xD2 }, buf[54..57]); // XOR R10D,R10D
    // MOV RDI, callee_rt — REX.W (48) + B8+rdi.low3=7=BF + LE imm64
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xBF, 0xBE, 0xBA, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE }, buf[57..67]);
    // MOV [RDI+40], R10 (REX.WR=4C, 89, mod=10 reg=r10(2) rm=rdi(7) = 97).
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x97, 0x28, 0x00, 0x00, 0x00 }, buf[67..74]);
    // MOV RAX, callee_entry
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xB8, 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12 }, buf[74..84]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[84..86]); // CALL RAX
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xC4, 0x08, 0x00, 0x00, 0x00 }, buf[86..93]); // ADD RSP,8
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[93..95]); // POP R15
    // #381 trap relay — MOV R11, callee_rt (REX.WB=49 + B8+r11.low3=3 = BB).
    try testing.expectEqualSlices(u8, &.{ 0x49, 0xBB, 0xBE, 0xBA, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE }, buf[95..105]);
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x8B, 0x93, 0x28, 0x00, 0x00, 0x00 }, buf[105..112]); // MOV R10,[R11+40]
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x85, 0xD2 }, buf[112..115]); // TEST R10,R10
    try testing.expectEqualSlices(u8, &.{ 0x74, 0x07 }, buf[115..117]); // JE +7 (skips the store)
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x89, 0x97, 0x28, 0x00, 0x00, 0x00 }, buf[117..124]); // MOV [R15+40],R10
    try testing.expectEqual(@as(u8, 0x5D), buf[124]); // POP RBP
    try testing.expectEqual(@as(u8, 0xC3), buf[125]); // RET
}

// #385 — the Win64 layout, checked from whatever host runs the tests. The
// Windows leg is the only instrument that executes this encoder.
test "emitThunkCc: the Win64 layout differs in exactly the Cc-dependent slots (#385)" {
    var sysv: [thunk_bytes]u8 = undefined;
    var win: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    const sig = sigOf(&.{}, &one);
    emitThunkCc(.sysv, &sysv, callee_rt, callee_entry, sig);
    emitThunkCc(.win64, &win, callee_rt, callee_entry, sig);

    // The runtime pointer goes to the register the callee's prologue reads:
    // MOV RDI (48 BF) vs MOV RCX (48 B9), same length, same literal.
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xBF }, sysv[off_mov_rt..][0..2]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xB9 }, win[off_mov_rt..][0..2]);
    try testing.expectEqual(callee_rt, std.mem.readInt(u64, win[off_mov_rt + 2 ..][0..8], .little));
    // The #381 entry clear stores through that same register: modrm rm=rdi(7)
    // -> 0x97 vs rm=rcx(1) -> 0x91.
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x97 }, sysv[off_clear_store..][0..3]);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x91 }, win[off_clear_store..][0..3]);
    // The overflow region starts above the Win64 home area: LEAs at +16 vs +48.
    try testing.expectEqual(@as(i32, 16), imm32At(&sysv, off_lea_start + 3));
    try testing.expectEqual(@as(i32, 48), imm32At(&win, off_lea_start + 3));
    // The home area is reserved below the CALL and dropped after it: 0 vs 32,
    // and the ADD undoes shadow + copy + pad.
    try testing.expectEqual(@as(i32, 0), imm32At(&sysv, off_sub_shadow + 3));
    try testing.expectEqual(@as(i32, 32), imm32At(&win, off_sub_shadow + 3));
    try testing.expectEqual(@as(i32, 8), imm32At(&sysv, off_add_rsp + 3));
    try testing.expectEqual(@as(i32, 40), imm32At(&win, off_add_rsp + 3));
    // Everything else is Cc-invariant, which is why `thunk_bytes` is one number.
    try testing.expectEqualSlices(u8, sysv[0..off_lea_start], win[0..off_lea_start]);
    try testing.expectEqualSlices(u8, sysv[off_je_skip..off_sub_shadow], win[off_je_skip..off_sub_shadow]);
    try testing.expectEqualSlices(u8, sysv[off_mov_rax..off_add_rsp], win[off_mov_rax..off_add_rsp]);
    try testing.expectEqualSlices(u8, sysv[off_pop_r15..], win[off_pop_r15..]);
}

// #385 — RDI is callee-saved under Win64 AND in its allocatable pool, so an
// importer may hold a live value there across the call. The Win64 thunk must
// not write it — with or without a MEMORY-class return.
test "emitThunkCc: the Win64 thunk never writes RDI (#385)" {
    for ([_]zir.FuncType{ sigOf(i32s[0..2], &one), sigOf(i32s[0..6], &three) }) |sig| {
        var win: [thunk_bytes]u8 = undefined;
        emitThunkCc(.win64, &win, 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111, sig);
        // `MOV RDI, imm64` = REX.W + B8+rdi.low3(7).
        try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &win, &[_]u8{ 0x48, 0xBF }));
        // A store through RDI as base: REX.W|R + 0x89 + mod=10 reg=r10 rm=rdi.
        try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &win, &[_]u8{ 0x4C, 0x89, 0x97 }));
    }
}

// ADR-0228 / #390 shape 2 — a MEMORY-class callee gets its runtime in arg1
// and entry-arg0 (the hidden buffer pointer the importer LEA'd) is left
// alone: no MOV into it, no store through it.
test "emitThunkCc: a MEMORY-class callee's runtime goes to arg1 and entry-arg0 is untouched (#390)" {
    const sig = sigOf(i32s[0..2], &three);
    var sysv: [thunk_bytes]u8 = undefined;
    var win: [thunk_bytes]u8 = undefined;
    emitThunkCc(.sysv, &sysv, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888, sig);
    emitThunkCc(.win64, &win, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888, sig);
    // SysV: MOV RSI (48 BE), clear through RSI (modrm 0x96); never RDI.
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xBE }, sysv[off_mov_rt..][0..2]);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x96 }, sysv[off_clear_store..][0..3]);
    try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &sysv, &[_]u8{ 0x48, 0xBF }));
    try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &sysv, &[_]u8{ 0x4C, 0x89, 0x97 }));
    // Win64: MOV RDX (48 BA), clear through RDX (modrm 0x92); never RCX.
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xBA }, win[off_mov_rt..][0..2]);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x92 }, win[off_clear_store..][0..3]);
    try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &win, &[_]u8{ 0x48, 0xB9 }));
    try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &win, &[_]u8{ 0x4C, 0x89, 0x91 }));
    // The register choice is the only difference from the non-MEMORY thunk.
    var plain: [thunk_bytes]u8 = undefined;
    emitThunkCc(.sysv, &plain, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888, sigOf(i32s[0..2], &one));
    try testing.expectEqualSlices(u8, plain[0..off_mov_rt], sysv[0..off_mov_rt]);
    try testing.expectEqualSlices(u8, plain[off_mov_rax..], sysv[off_mov_rax..]);
}

// ADR-0228 / #390 shape 1 — the overflow copy is sized by the call site's
// own rule, the parity pad keeps the CALL 16-aligned for every `n`, and the
// ADD after the CALL drops exactly what was pushed and reserved.
test "emitThunkCc: the overflow copy follows computeCallOverflowBytesCc, and the CALL stays 16-aligned (#390)" {
    inline for ([_]abi.Cc{ .sysv, .win64 }) |cc| {
        const shadow: i32 = @intCast(switch (cc) {
            .sysv => abi.sysv.shadow_space_bytes,
            .win64 => abi.win64.shadow_space_bytes,
        });
        // int-only, fp-only, mixed and MEMORY-class shapes, up to 12 of a kind.
        var n_params: usize = 0;
        while (n_params <= 12) : (n_params += 1) {
            for ([_]zir.FuncType{
                sigOf(i32s[0..n_params], &one),
                sigOf(f64s[0..n_params], &one),
                sigOf(i32s[0..n_params], &three),
            }) |sig| {
                var buf: [thunk_bytes]u8 = undefined;
                emitThunkCc(cc, &buf, 0, 0, sig);
                const overflow: i32 = @intCast(op_call.computeCallOverflowBytesCc(cc, sig));
                const n: i32 = @divExact(overflow, 8);
                const pad: i32 = if (@mod(n, 2) == 0) 8 else 0;
                try testing.expectEqual(pad, imm32At(&buf, off_sub_pad + 3));
                try testing.expectEqual(16 + shadow, imm32At(&buf, off_lea_start + 3));
                try testing.expectEqual(16 + shadow + overflow, imm32At(&buf, off_lea_end + 3));
                try testing.expectEqual(shadow, imm32At(&buf, off_sub_shadow + 3));
                try testing.expectEqual(shadow + overflow + pad, imm32At(&buf, off_add_rsp + 3));
                // Entry RSP ≡ 8; PUSH RBP, PUSH R15, SUB pad, n pushes, SUB shadow.
                const rsp_mod_16: i32 = @mod(8 - 8 - 8 - pad - 8 * n - shadow, 16);
                try testing.expectEqual(@as(i32, 0), rsp_mod_16);
            }
        }
    }
    // A mixed SysV shape overflows per class: 6 ints (1 over) + 9 f64 (1 over).
    var mixed: [15]zir.ValType = undefined;
    for (0..6) |k| mixed[k] = .i32;
    for (6..15) |k| mixed[k] = .f64;
    var buf: [thunk_bytes]u8 = undefined;
    emitThunkCc(.sysv, &buf, 0, 0, sigOf(&mixed, &one));
    try testing.expectEqual(@as(i32, 16 + 16), imm32At(&buf, off_lea_end + 3));
    // The same shape under Win64 shares positions: 15 - 3 = 12 words.
    emitThunkCc(.win64, &buf, 0, 0, sigOf(&mixed, &one));
    try testing.expectEqual(@as(i32, 48 + 96), imm32At(&buf, off_lea_end + 3));
}

// The two short branches land on instruction boundaries: the JE skips the
// whole loop (onto `SUB RSP, shadow`), the JNE returns to its first
// instruction. A wrong displacement lands mid-instruction.
test "emitThunkCc: the copy loop's branches land on instruction boundaries" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunkCc(.sysv, &buf, 0, 0, sigOf(i32s[0..7], &one));
    const je_disp: i8 = @bitCast(buf[off_je_skip + 1]);
    try testing.expectEqual(off_sub_shadow, off_je_skip + 2 + @as(usize, @intCast(je_disp)));
    const jne_at = off_sub_shadow - 2;
    const jne_disp: i8 = @bitCast(buf[jne_at + 1]);
    try testing.expectEqual(off_loop, @as(usize, @intCast(@as(isize, @intCast(jne_at + 2)) + jne_disp)));
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xEC }, buf[off_sub_shadow..][0..3]); // SUB RSP, imm32
}

// #381 — the relay's two load-bearing properties, apart from the byte-exact
// layout: the JE skips EXACTLY the store, and the store targets the CALLER's
// runtime register while the load reads the callee's, at the SAME offset.
test "emitThunk: the trap relay reads the callee's runtime and writes the caller's (#381)" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunkCc(.sysv, &buf, 0, 0, sigOf(&.{}, &one));
    const flag_off: i32 = jit_abi.trap_flag_off;
    const load = inst.encMovR64FromMemDisp32(.r10, .r11, flag_off);
    const store = inst.encStoreR64MemDisp32(.r10, .r15, flag_off);
    const skip = inst.encJccRel8(.e, @intCast(store.len));
    const relay_start = off_relay + inst.encMovImm64Q(.r11, 0).len;
    // The entry clear zeroes the CALLEE's pair before the call.
    try testing.expectEqualSlices(u8, inst.encXorRR(.d, .r10, .r10).slice(), buf[off_sub_shadow + 7 ..][0..3]);
    try testing.expectEqualSlices(u8, inst.encStoreR64MemDisp32(.r10, .rdi, flag_off).slice(), buf[off_clear_store..][0..7]);
    try testing.expectEqualSlices(u8, load.slice(), buf[relay_start..][0..load.len]);
    try testing.expectEqualSlices(u8, inst.encTestRR(.q, .r10, .r10).slice(), buf[relay_start + load.len ..][0..3]);
    try testing.expectEqualSlices(u8, skip.slice(), buf[relay_start + load.len + 3 ..][0..skip.len]);
    try testing.expectEqualSlices(u8, store.slice(), buf[relay_start + load.len + 3 + skip.len ..][0..store.len]);
    // The branch lands on POP RBP, not inside the store.
    try testing.expectEqual(@as(usize, thunk_bytes - 2), relay_start + load.len + 3 + skip.len + store.len);
}

test "emitThunk: D-142 R15 save/restore + D-238 RBP frame around CALL" {
    // Structural assertion: a standard frame (PUSH RBP / MOV RBP,RSP /
    // POP RBP) wraps the body, and PUSH R15 / POP R15 wraps the CALL RAX.
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0xDEADBEEF, 0xCAFEBABE, sigOf(i32s[0..9], &one));
    try testing.expectEqual(@as(u8, 0x55), buf[0]); // PUSH RBP
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]); // MOV RBP,RSP
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]); // PUSH R15
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[off_call..][0..2]); // CALL RAX
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[off_pop_r15..][0..2]); // POP R15
    try testing.expectEqual(@as(u8, 0x5D), buf[thunk_bytes - 2]); // POP RBP
    try testing.expectEqual(@as(u8, 0xC3), buf[thunk_bytes - 1]); // RET
}
