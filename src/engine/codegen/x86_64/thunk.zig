//! x86_64 cross-module import bridge thunk encoder
//! (ADR-0066 + Amendment §A1, D-142
//! fix (A.3) + D-238/ADR-0185 (a) RBP frame-link).
//!
//! Each thunk is a 40-byte native code snippet that wraps a
//! call-and-return around the callee's JIT entry. It does three
//! things: **(1)** establishes a standard `PUSH RBP; MOV RBP,RSP`
//! frame so the cross-instance EH unwinder can walk THROUGH the
//! thunk (D-238 — `[RBP,0]`=saved importer RBP, `[RBP,8]`=importer
//! return address, making the thunk frame a chain link); **(2)**
//! **saves the caller's R15** (`runtime_ptr_save_gpr` per ADR-0026
//! Cc-pivot) across the CALL so the importer's runtime-ptr survives
//! the callee's prologue overwrite (the D-142 cohort discipline);
//! **(3)** keeps `CALL RAX` 16-byte aligned via an explicit pad.
//! Mirrors the arm64 `MOV X29,SP` thunk frame-link (`4f73d9ee`).
//! See `.dev/lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md`
//! for the D-142 chain, `.claude/rules/abi_callee_saved_pinning.md`
//! for the cohort discipline, ADR-0185 for the EH frame-walk.
//!
//! Layout:
//!
//! ```text
//! offset  encoding                            disassembly
//! 0x00    55                                  PUSH RBP           ; frame link (saved importer RBP)
//! 0x01    48 89 E5                            MOV  RBP, RSP      ; [RBP,8] = importer retaddr
//! 0x04    41 57                               PUSH R15           ; save caller's R15 (= caller_rt)
//! 0x06    48 83 EC <pad>                      SUB  RSP, pad      ; align (+ Win64 shadow)
//! 0x0A    48 B{7,9} <callee_rt LE 8 bytes>    MOV  arg0, imm64   ; RDI SysV / RCX Win64
//! 0x14    45 31 D2                            XOR  R10D, R10D    ; #381 entry clear
//! 0x17    4C 89 {97,91} <40 LE4>              MOV  [arg0+40], R10; clear callee trap_flag|kind
//! 0x1E    48 B8 <callee_entry LE 8 bytes>     MOV  RAX, imm64
//! 0x28    FF D0                               CALL RAX           ; SysV CALL (RSP 16-aligned here)
//! 0x2A    48 83 C4 <pad>                      ADD  RSP, pad      ; undo pad
//! 0x2E    41 5F                               POP  R15           ; restore caller's R15
//! 0x30    49 BB <callee_rt LE 8 bytes>        MOV  R11, imm64    ; #381 trap relay: callee_rt
//! 0x3A    4D 8B 93 <40 LE4>                   MOV  R10, [R11+40] ; trap_flag|trap_kind pair
//! 0x41    4D 85 D2                            TEST R10, R10
//! 0x44    74 07                               JE   +7            ; no trap -> skip
//! 0x46    4D 89 97 <40 LE4>                   MOV  [R15+40], R10 ; relay onto the CALLER
//! 0x4D    5D                                  POP  RBP           ; restore importer's RBP
//! 0x4E    C3                                  RET                ; return to importer
//! ```
//!
//! 1 + 3 + 2 + 4 + 10 + 3 + 7 + 10 + 2 + 4 + 2 + 10 + 7 + 3 + 2 + 7 + 1 + 1 =
//! 79 bytes total. The literals are embedded directly in the MOV imm64
//! instructions (no separate pool), so the thunk is position-independent:
//! relocate to any byte-aligned RX page without patching.
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
//! writes `[R15 + trap_flag_off]` and RETs (`op_control.zig:emitTrapExitStub`),
//! and every call site re-reads that flag afterwards
//! (`op_control.zig:emitPostCallTrapCheck`, ADR-0199 / D-468). Inside the
//! thunk R15 is the CALLEE's runtime, so a trap raised in the callee lands in
//! a runtime the importer never reads: `wasm_func_call` reported success and
//! the importer ran on past a call that returned nothing. The five
//! instructions at 0x26..0x42 copy the callee's flag onto the caller AFTER
//! `POP R15` has restored `caller_rt`, so the importer's existing post-call
//! check fires unchanged — no call-site codegen changes.
//!
//! `trap_flag` (u32 @40) and `trap_kind` (u32 @44) are adjacent, so ONE
//! 8-byte load/store carries both; the kind matters because a relay that
//! moved only the flag would report every cross-module trap as kind 0. The
//! adjacency is asserted at comptime below.
//!
//! R10/R11 are volatile in BOTH SysV and Win64 and are not in the
//! reserved-invariant set (`abi.zig:reserved_invariant_gprs` = {R15}), and the
//! call site reloads its homed caller-saved registers AFTER the call returns
//! (`op_call.zig:reloadHomedCallerSaved`), so clobbering them here is free.
//! The return-value registers (RAX/RDX/XMM0/XMM1) are untouched.
//!
//! **Cc-aware since #385.** The encoder used to write `MOV RDI, callee_rt`
//! unconditionally — entry-arg0 under SysV only. Under Win64 entry-arg0 is RCX
//! (`abi.win64.entry_arg0_gpr`) and `op_call.zig:emitImportDispatch` leaves the
//! IMPORTER's runtime there on the way in, so the callee's prologue snapshotted
//! the importer's runtime and the exporter's body ran against the wrong
//! instance's globals, memory, tables and WASI host. Two more Cc gaps rode
//! along: RDI is callee-saved AND allocatable under Win64
//! (`abi.win64.allocatable_gprs` adds it for that reason), so writing it
//! destroyed a live importer register; and the CALL reserved no Win64 shadow
//! space, whose 32-byte home area starts at this thunk's own RSP and covers
//! its saved R15, saved RBP and return address.
//!
//! All three are one root — a SysV-shaped encoder — and all three go away by
//! deriving from `abi.current`: the runtime pointer lands in
//! `entry_arg0_gpr`, RDI is never touched under Win64, and the frame pad is
//! `shadow_space_bytes + 8` rather than a bare 8. The byte COUNT is identical
//! under both conventions (the register change keeps every encoding the same
//! length and the pad is an imm8 either way), so `thunk_bytes` is Cc-agnostic
//! and the layout below reads for both.
//!
//! `emitThunkCc` takes the convention as a comptime parameter so the Win64
//! layout is testable from a SysV host. It has to be: nothing in the tree
//! exercised this path on Windows, and the cross-module tests that traverse it
//! pass there for the wrong reason — `i32.const 42` never touches a runtime,
//! and a trap raised on the importer's runtime is exactly where the caller
//! looks. The test that finally told the two apart routes a guest `proc_exit`
//! through the exporter and reads the WASI host it reached
//! (`test/c_api_conformance/wasi_exit_code.c`).
//!
//! SysV AMD64 §3.2.1 invariant: RBX, RBP, R12..R15 are callee-saved.
//! v2's JIT prologue (per ADR-0026 Cc-pivot) overwrites R15 with the
//! new `*JitRuntime` argument WITHOUT first stack-saving the caller's
//! value. For same-module calls this is a no-op (caller_rt ≡ callee_rt)
//! but for cross-module bridge thunks caller_rt ≠ callee_rt, so the
//! bridge thunk pays the save/restore cost on the caller's behalf.
//! Same discipline pattern as arm64 X19; see ADR-0066 §A1.
//!
//! Stack-alignment note (D-238 changed this): both conventions require
//! `RSP % 16 == 0` at the point of CALL. The importer's CALL into the
//! thunk leaves entry RSP ≡ 8 mod 16 (pushed return address). The two
//! pushes (`PUSH RBP` → ≡0, `PUSH R15` → ≡8) would leave `CALL RAX`
//! misaligned, so the explicit `SUB RSP, pad` restores ≡0 before the
//! CALL (and `ADD RSP, pad` undoes it after). The OLD 27-byte single-push
//! thunk aligned by luck (one push: ≡8 → ≡0); adding the RBP frame-link
//! needs the pad. Load-bearing for SSE/AVX in the callee.
//!
//! #385 — `pad` is `shadow_space_bytes + 8`: 8 under SysV, 40 under Win64,
//! where the low 32 bytes are the home area the callee may spill its four
//! register args into (Microsoft x64 §"Stack allocation"). Without it that
//! home area starts at this thunk's RSP and covers its saved R15, saved RBP
//! and return address. The alignment holds for both because
//! `shadow_space_bytes` is a multiple of 16 — asserted at comptime below.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");

comptime {
    // #385 — the frame pad below is `shadow_space_bytes + 8`, which lands the
    // CALL on a 16-byte boundary only while the shadow itself is a multiple
    // of 16. Both conventions satisfy it today (0 and 32).
    if (abi.sysv.shadow_space_bytes % 16 != 0 or abi.win64.shadow_space_bytes % 16 != 0)
        @compileError("bridge thunk frame pad assumes a 16-multiple shadow space");
    // The relay below copies `trap_flag` and `trap_kind` as one 8-byte pair.
    if (jit_abi.trap_kind_off != jit_abi.trap_flag_off + 4)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; they are no longer adjacent");
    if (jit_abi.trap_flag_off % 8 != 0)
        @compileError("bridge thunk relays trap_flag|trap_kind as one 8-byte pair; trap_flag_off is no longer 8-aligned");
}

/// Total thunk size in bytes (PUSH RBP [1] + MOV RBP,RSP [3] + PUSH
/// R15 [2] + SUB RSP,8 [4] + MOV RDI imm64 [10] + MOV RAX imm64 [10]
/// + #381 entry clear [3+7 = 10] + MOV RAX imm64 [10] + CALL RAX [2] +
/// ADD RSP,8 [4] + POP R15 [2] + #381 trap relay [10+7+3+2+7 = 29] +
/// POP RBP [1] + RET [1] = 79). Stable across all callee signatures.
pub const thunk_bytes: usize = 79;

/// Emit one bridge thunk into `buf[0..thunk_bytes]`. `buf` MUST be
/// exactly `thunk_bytes` long; the caller is responsible for
/// allocating it inside an RX-mappable arena.
///
/// `callee_rt`    — the callee instance's `*JitRuntime` value
///                  to install in RDI before the CALL.
/// `callee_entry` — the callee's JIT entry point.
pub fn emitThunk(buf: []u8, callee_rt: usize, callee_entry: usize) void {
    emitThunkCc(abi.current_cc, buf, callee_rt, callee_entry);
}

/// #385 — the body of `emitThunk`, with the calling convention as a comptime
/// parameter. Production always passes `abi.current_cc`; the tests pass both,
/// so the Win64 layout is checked from a SysV host. It has to be checkable
/// that way — the Windows leg is the only instrument that runs this code, and
/// the cross-module tests that traverse it pass there even when the callee
/// receives the wrong runtime.
pub fn emitThunkCc(comptime cc: abi.Cc, buf: []u8, callee_rt: usize, callee_entry: usize) void {
    std.debug.assert(buf.len == thunk_bytes);
    const tables = switch (cc) {
        .sysv => abi.sysv,
        .win64 => abi.win64,
    };
    // The register the callee's prologue snapshots its runtime pointer from
    // (`emit.zig`'s `MOV R15, <entry_arg0>`): RDI under SysV, RCX under Win64.
    const entry_arg0 = tables.entry_arg0_gpr;
    // Alignment pad + the Win64 home area the callee may spill its register
    // args into. Never touches RDI under Win64, where it is callee-saved and
    // in the allocatable pool.
    const frame_pad: i8 = @intCast(tables.shadow_space_bytes + 8);
    // PUSH RBP — establish the frame link so the cross-instance EH
    // unwinder can walk through the thunk (D-238 / ADR-0185 a).
    @memcpy(buf[0..1], inst.encPushR(.rbp).slice());
    // MOV RBP, RSP — now [RBP,0]=saved RBP, [RBP,8]=importer retaddr.
    @memcpy(buf[1..4], inst.encMovRR(.q, .rbp, .rsp).slice());
    // PUSH R15 — save caller's R15 = caller_rt (D-142 cohort save).
    @memcpy(buf[4..6], inst.encPushR(.r15).slice());
    // SUB RSP, pad — alignment (two pushes left RSP ≡ 8; restore ≡ 0 so the
    // CALL below is 16-aligned) plus the Win64 shadow space (#385).
    @memcpy(buf[6..10], inst.encSubRSpImm8(frame_pad).slice());
    const flag_off: i32 = jit_abi.trap_flag_off;
    // MOV <entry_arg0>, callee_rt — the callee's `*JitRuntime` in the register
    // its prologue reads (#385; RDI under SysV, RCX under Win64).
    @memcpy(buf[10..20], inst.encMovImm64Q(entry_arg0, callee_rt).slice());
    // #381 entry clear — zero the callee's trap_flag|trap_kind pair while the
    // entry-arg0 register still holds callee_rt, so the relay below reads THIS
    // call's outcome and not a trap the exporter kept from an earlier one.
    @memcpy(buf[20..23], inst.encXorRR(.d, .r10, .r10).slice());
    @memcpy(buf[23..30], inst.encStoreR64MemDisp32(.r10, entry_arg0, flag_off).slice());
    // MOV RAX, callee_entry.
    @memcpy(buf[30..40], inst.encMovImm64Q(.rax, callee_entry).slice());
    // CALL RAX — SysV CALL (not JMP); pushes post-CALL RIP so the
    // callee's RET returns here.
    @memcpy(buf[40..42], inst.encCallReg(.rax).slice());
    // ADD RSP, pad — undo the alignment + shadow allocation.
    @memcpy(buf[42..46], inst.encAddRSpImm8(frame_pad).slice());
    // POP R15 — RESTORE caller's R15. Everything below relays onto it, so it
    // must come after this and not before.
    @memcpy(buf[46..48], inst.encPopR(.r15).slice());

    // #381 trap relay. R11 <- callee_rt (RDI was clobbered by the callee);
    // R10 <- the callee's trap_flag|trap_kind pair; store it onto the caller
    // only when the callee actually trapped, so a clean return cannot clear a
    // flag the caller already holds.
    const relay_load = inst.encMovR64FromMemDisp32(.r10, .r11, flag_off);
    const relay_test = inst.encTestRR(.q, .r10, .r10);
    const relay_store = inst.encStoreR64MemDisp32(.r10, .r15, flag_off);
    // JE skips exactly the store — its own encoded length, not a literal.
    const relay_skip = inst.encJccRel8(.e, @intCast(relay_store.len));
    var off: usize = 48;
    for ([_]inst.EncodedInsn{
        inst.encMovImm64Q(.r11, callee_rt),
        relay_load,
        relay_test,
        relay_skip,
        relay_store,
    }) |e| {
        @memcpy(buf[off..][0..e.len], e.slice());
        off += e.len;
    }

    // POP RBP — RESTORE importer's RBP.
    @memcpy(buf[off..][0..1], inst.encPopR(.rbp).slice());
    off += 1;
    // RET — return to importer's call site.
    @memcpy(buf[off..][0..1], inst.encRet().slice());
    off += 1;
    std.debug.assert(off == thunk_bytes);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// #385 — the Win64 layout, checked from whatever host runs the tests. Nothing
// in the tree exercised this encoder on Windows, and the cross-module tests
// that traverse it pass there even when the callee receives the importer's
// runtime (`i32.const 42` touches no runtime; a trap raised on the importer's
// runtime is where the caller looks). So the encoding is pinned here rather
// than left to the one CI leg that runs it.
test "emitThunkCc: the Win64 layout differs in exactly the Cc-dependent slots (#385)" {
    var sysv: [thunk_bytes]u8 = undefined;
    var win: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    emitThunkCc(.sysv, &sysv, callee_rt, callee_entry);
    emitThunkCc(.win64, &win, callee_rt, callee_entry);

    // The runtime pointer goes to the register the callee's prologue reads:
    // MOV RDI (48 BF) vs MOV RCX (48 B9), same length, same literal.
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xBF }, sysv[10..12]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xB9 }, win[10..12]);
    try testing.expectEqual(callee_rt, std.mem.readInt(u64, win[12..20], .little));

    // The #381 entry clear stores through that same register: modrm rm=rdi(7)
    // -> 0x97 vs rm=rcx(1) -> 0x91.
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x97 }, sysv[23..26]);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x91 }, win[23..26]);

    // The frame pad carries the Win64 home area: SUB/ADD RSP, 8 vs 40.
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x08 }, sysv[6..10]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x28 }, win[6..10]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x08 }, sysv[42..46]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x28 }, win[42..46]);

    // Everything else is Cc-invariant, which is why `thunk_bytes` is one number.
    try testing.expectEqualSlices(u8, sysv[0..6], win[0..6]); // frame + PUSH R15
    try testing.expectEqualSlices(u8, sysv[20..23], win[20..23]); // XOR R10D,R10D
    try testing.expectEqualSlices(u8, sysv[26..30], win[26..30]); // the disp32
    try testing.expectEqualSlices(u8, sysv[30..42], win[30..42]); // MOV RAX + CALL
    try testing.expectEqualSlices(u8, sysv[46..thunk_bytes], win[46..thunk_bytes]); // POP + relay + RET
}

// #385 — RDI is callee-saved under Win64 AND in its allocatable pool
// (`abi.win64.allocatable_gprs` adds RDI/RSI for exactly that reason), so an
// importer may hold a live value there across the call. The Win64 thunk must
// not write it. Stated as its own property because the byte-exact test above
// would still pass if a future edit moved an RDI write somewhere else.
test "emitThunkCc: the Win64 thunk never writes RDI (#385)" {
    var win: [thunk_bytes]u8 = undefined;
    emitThunkCc(.win64, &win, 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111);
    // `MOV RDI, imm64` = REX.W + B8+rdi.low3(7).
    try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &win, &[_]u8{ 0x48, 0xBF }));
    // A store through RDI as base: REX.W|R + 0x89 + mod=10 reg=r10 rm=rdi.
    try testing.expectEqual(@as(?usize, null), std.mem.find(u8, &win, &[_]u8{ 0x4C, 0x89, 0x97 }));
}

// #385 — the Win64 CALL must leave 32 bytes below it for the callee's home
// area. Without them the callee's spill of its four register args starts at
// this thunk's RSP and covers its saved R15, saved RBP and return address.
test "emitThunkCc: Win64 reserves the 32-byte home area below the CALL (#385)" {
    var win: [thunk_bytes]u8 = undefined;
    emitThunkCc(.win64, &win, 0, 0);
    const pad: i8 = @bitCast(win[9]); // the imm8 of SUB RSP, imm8
    try testing.expect(pad >= @as(i8, @intCast(abi.win64.shadow_space_bytes)));
    // …and the pad still lands the CALL on a 16-byte boundary: entry RSP ≡ 8,
    // two pushes → ≡ 8, minus the pad → ≡ 0.
    try testing.expectEqual(@as(i32, 0), @mod(8 - @as(i32, pad), 16));
    try testing.expectEqual(win[9], win[45]); // the ADD undoes exactly the SUB
}

test "emitThunk: byte-exact layout for known constants (D-238 RBP frame-link)" {
    var buf: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    emitThunk(&buf, callee_rt, callee_entry);

    try testing.expectEqual(@as(u8, 0x55), buf[0]); // PUSH RBP
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]); // MOV RBP,RSP
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]); // PUSH R15
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x08 }, buf[6..10]); // SUB RSP,8
    // MOV RDI, callee_rt — REX.W (48) + B8+rdi.low3=7=BF + LE imm64
    try testing.expectEqualSlices(u8, &.{
        0x48, 0xBF,
        0xBE, 0xBA,
        0xFE, 0xCA,
        0xEF, 0xBE,
        0xAD, 0xDE,
    }, buf[10..20]);
    // #381 entry clear — XOR R10D,R10D (REX.RB=45) then MOV [RDI+40], R10
    // (REX.WR=4C, 89, mod=10 reg=r10(2) rm=rdi(7) = 97).
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x31, 0xD2 }, buf[20..23]);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0x97, 0x28, 0x00, 0x00, 0x00 }, buf[23..30]);
    // MOV RAX, callee_entry — REX.W (48) + B8+rax.low3=0=B8 + LE imm64
    try testing.expectEqualSlices(u8, &.{
        0x48, 0xB8,
        0xF0, 0xDE,
        0xBC, 0x9A,
        0x78, 0x56,
        0x34, 0x12,
    }, buf[30..40]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[40..42]); // CALL RAX
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x08 }, buf[42..46]); // ADD RSP,8
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[46..48]); // POP R15
    // #381 trap relay — MOV R11, callee_rt (REX.WB=49 + B8+r11.low3=3 = BB).
    try testing.expectEqualSlices(u8, &.{
        0x49, 0xBB,
        0xBE, 0xBA,
        0xFE, 0xCA,
        0xEF, 0xBE,
        0xAD, 0xDE,
    }, buf[48..58]);
    // MOV R10, [R11+40] — REX.WRB=4D, 8B, mod=10 reg=r10(2) rm=r11(3) = 93.
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x8B, 0x93, 0x28, 0x00, 0x00, 0x00 }, buf[58..65]);
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x85, 0xD2 }, buf[65..68]); // TEST R10,R10
    try testing.expectEqualSlices(u8, &.{ 0x74, 0x07 }, buf[68..70]); // JE +7 (skips the store)
    // MOV [R15+40], R10 — REX.WRB=4D, 89, mod=10 reg=r10(2) rm=r15(7) = 97.
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x89, 0x97, 0x28, 0x00, 0x00, 0x00 }, buf[70..77]);
    try testing.expectEqual(@as(u8, 0x5D), buf[77]); // POP RBP
    try testing.expectEqual(@as(u8, 0xC3), buf[78]); // RET
}

// #381 — the relay's two load-bearing properties, stated apart from the
// byte-exact layout so a future reshuffle that keeps the bytes but loses the
// meaning still fails: the JE skips EXACTLY the store (a wrong displacement
// lands mid-instruction), and the store targets the CALLER's runtime register
// while the load reads the callee's, at the SAME offset.
test "emitThunk: the trap relay reads the callee's runtime and writes the caller's (#381)" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0);
    const flag_off: i32 = jit_abi.trap_flag_off;
    const load = inst.encMovR64FromMemDisp32(.r10, .r11, flag_off);
    const store = inst.encStoreR64MemDisp32(.r10, .r15, flag_off);
    const skip = inst.encJccRel8(.e, @intCast(store.len));
    // The relay tail runs from `POP R15` to `POP RBP`, in this exact order.
    const relay_start = 48 + inst.encMovImm64Q(.r11, 0).len;
    // The entry clear zeroes the CALLEE's pair before the call, so the read
    // above cannot see a trap the exporter kept from an earlier call.
    try testing.expectEqualSlices(u8, inst.encXorRR(.d, .r10, .r10).slice(), buf[20..23]);
    try testing.expectEqualSlices(
        u8,
        inst.encStoreR64MemDisp32(.r10, .rdi, flag_off).slice(),
        buf[23..30],
    );
    try testing.expectEqualSlices(u8, load.slice(), buf[relay_start..][0..load.len]);
    try testing.expectEqualSlices(u8, inst.encTestRR(.q, .r10, .r10).slice(), buf[relay_start + load.len ..][0..3]);
    try testing.expectEqualSlices(u8, skip.slice(), buf[relay_start + load.len + 3 ..][0..skip.len]);
    try testing.expectEqualSlices(u8, store.slice(), buf[relay_start + load.len + 3 + skip.len ..][0..store.len]);
    // The branch lands on POP RBP, not inside the store.
    try testing.expectEqual(@as(usize, thunk_bytes - 2), relay_start + load.len + 3 + skip.len + store.len);
}

test "emitThunk: round-trip literals at zero" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0);
    // Frame + opcode bytes unchanged; both imm64 fields all-zero.
    try testing.expectEqual(@as(u8, 0x55), buf[0]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x08 }, buf[6..10]);
    try testing.expectEqual(@as(u8, 0x48), buf[10]);
    try testing.expectEqual(@as(u8, 0xBF), buf[11]);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[12..20], .little));
    try testing.expectEqual(@as(u8, 0x48), buf[30]);
    try testing.expectEqual(@as(u8, 0xB8), buf[31]);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[32..40], .little));
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[40..42]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x08 }, buf[42..46]);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[46..48]);
    // #381 relay: the callee_rt literal is the third imm64 field and zeroes too.
    try testing.expectEqualSlices(u8, &.{ 0x49, 0xBB }, buf[48..50]);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[50..58], .little));
    try testing.expectEqual(@as(u8, 0x5D), buf[thunk_bytes - 2]);
    try testing.expectEqual(@as(u8, 0xC3), buf[thunk_bytes - 1]);
}

test "emitThunk: opcode/frame bytes constant across two distinct callees" {
    var buf_a: [thunk_bytes]u8 = undefined;
    var buf_b: [thunk_bytes]u8 = undefined;
    emitThunk(&buf_a, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888);
    emitThunk(&buf_b, 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111);
    // Frame + opcode bytes at fixed offsets must match across thunks
    // (ADR-0066 §A1 + ADR-0185 a invariant); only the imm64 literals differ.
    try testing.expectEqualSlices(u8, buf_a[0..12], buf_b[0..12]); // frame + MOV RDI opcode
    try testing.expectEqualSlices(u8, buf_a[20..32], buf_b[20..32]); // entry clear + MOV RAX opcode
    try testing.expectEqualSlices(u8, buf_a[40..48], buf_b[40..48]); // CALL + ADD + POP R15
    try testing.expectEqualSlices(u8, buf_a[58..79], buf_b[58..79]); // relay + POP RBP + RET
}

test "emitThunk: D-142 R15 save/restore + D-238 RBP frame around CALL" {
    // Structural assertion: a standard frame (PUSH RBP / MOV RBP,RSP /
    // POP RBP) wraps the body, and PUSH R15 / POP R15 wraps the CALL RAX.
    // These are the load-bearing invariants — RBP frame for the EH unwind
    // (D-238), R15 save for the cohort (D-142). A future encoder reshuffle
    // that drops either fails here before the runtime SEGV / unwind break.
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0xDEADBEEF, 0xCAFEBABE);
    try testing.expectEqual(@as(u8, 0x55), buf[0]); // PUSH RBP
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]); // MOV RBP,RSP
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]); // PUSH R15
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[40..42]); // CALL RAX
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[46..48]); // POP R15
    try testing.expectEqual(@as(u8, 0x5D), buf[thunk_bytes - 2]); // POP RBP
    try testing.expectEqual(@as(u8, 0xC3), buf[thunk_bytes - 1]); // RET
}
