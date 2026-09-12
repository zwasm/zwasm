//! `zwasm_throw` assembly entry glue (ADR-0114 D6 + ADR-0119).
//!
//! Per-arch `callconv(.naked)` trampoline invoked by JIT-emitted
//! `throw` / `throw_ref` sites. The naked attribute (ADR-0119) is
//! load-bearing — Zig MUST NOT emit a prologue/epilogue here, so
//! the trampoline observes the caller's FP (X29 / RBP) and saved
//! LR/RIP intact at entry.
//!
//! ## Current shape
//!
//! Two-layer architecture per ADR-0119 §Consequences:
//!
//! 1. `zwasmThrowTrampoline()` — tiny `callconv(.naked)` stub.
//!    Captures throw-site FP + LR + tag_idx + runtime-ptr into
//!    AAPCS64 / SysV arg regs, BL/CALLs into `trampolineCore`,
//!    then restores the saved FP/LR and RETs to the throw site
//!    (which then falls through to its trap-stub fallback).
//!
//! 2. `trampolineCore(initial_fp, throw_site_addr, tag_idx, rt)`
//!    — regular `callconv(.c)` Zig. Materializes ExceptionTable +
//!    CodeMap from `rt`, builds a `ThrowSite`, calls
//!    `shared/zwasm_throw.dispatchThrow`, and on the result:
//!      - `.uncaught`: sets `rt.trap_flag = 1` and returns (the
//!        naked stub then RETs to the throw site whose B/JMP
//!        falls through to the trap stub).
//!      - `.handler`: currently ALSO sets `rt.trap_flag = 1` —
//!        full handler dispatch (sp_restore + JMP landing_pad_pc)
//!        lands later.
//!
//! Net observable behavior: every throw traps; the load-bearing
//! delta is that the dispatcher
//! is ACTUALLY invoked, the EH table + code map are walked, and
//! handler resolution is exercised end-to-end. Installing a
//! catch handler in a fixture's exception_table now flows through
//! the unwinder; only the .handler→landing-pad JMP is deferred.
//!
//! Per ADR-0017, X19 (arm64) / R15 (x86_64) hold the pinned
//! `*JitRuntime` across every JIT call boundary. Naked attr +
//! the AAPCS64 / SysV callee-saved discipline mean the trampoline
//! inherits the pinned value from the throwing function — no
//! separate load needed at the entry point.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const builtin = @import("builtin");

const jit_abi = @import("jit_abi.zig");
const exception_table = @import("exception_table.zig");
const code_map_mod = @import("code_map.zig");
const zwasm_throw = @import("zwasm_throw.zig");
const eh_registry = @import("eh_registry.zig");

// ADR-0119 §Removal condition #1 — empirically validated 2026-05-27
// (spike `private/spikes/p10-it6-naked-trampoline/`): Zig 0.16
// `callconv(.naked)` produces zero prologue + epilogue on all three
// supported hosts (aarch64-macos / x86_64-linux-gnu /
// x86_64-windows-gnu).

const arm64_clobbers = if (builtin.target.cpu.arch == .aarch64)
    std.builtin.assembly.Clobbers{
        // We MOV into x0..x3 to marshal trampolineCore args. BLR
        // clobbers x30. trampolineCore itself (Zig fn, callconv(.c))
        // clobbers the standard AAPCS64 caller-saved cohort; we
        // list the explicit writers and BLR clobber, with memory
        // covering the trap_flag store inside trampolineCore.
        .x0 = true,
        .x1 = true,
        .x2 = true,
        .x3 = true,
        .x30 = true,
        .memory = true,
    }
else {
    // non-aarch64 hosts skip the arm64 branch; void collapses.
};

const x86_64_clobbers = if (builtin.target.cpu.arch == .x86_64)
    std.builtin.assembly.Clobbers{ .memory = true }
else {
    // non-x86_64 hosts skip the x86_64 branch; void collapses.
};

/// Trampoline-core: regular Zig fn, called from the naked stub.
///
/// Args (AAPCS64 / SysV C-ABI):
///   X0 / RDI = `initial_fp`       — throw fn's FP at throw site
///   X1 / RSI = `throw_site_addr`  — saved LR / RIP at the BL/CALL
///   X2 / RDX = `tag_idx`          — from throw site's MOVZ / MOV
///   X3 / RCX = `rt`               — `*JitRuntime` (= pinned X19/R15)
///
/// Pure data-flow: no inline asm here. Easier to test + reason about
/// than the equivalent inline assembly. The naked stub's only job
/// is to marshal these args and call this.
pub fn trampolineCore(
    initial_fp: usize,
    throw_site_addr: usize,
    tag_idx: u32,
    rt: *jit_abi.JitRuntime,
) callconv(.c) void {
    // Materialize the per-Instance EH views from `rt` (populated
    // at instance init).
    const table: zwasm_throw.ExceptionTable = .{
        .entries = if (rt.eh_table_entries) |p|
            p[0..rt.eh_table_count]
        else
            &.{},
        // Tag identity map (ADR-0134 D3) so aliased + cross-
        // module-imported tags match by source identity, not raw idx.
        .tag_ids = if (rt.tag_ids_ptr) |p|
            p[0..rt.tag_ids_count]
        else
            null,
    };
    const cmap: zwasm_throw.CodeMap = .{
        .entries = if (rt.eh_code_map_entries) |p|
            p[0..rt.eh_code_map_count]
        else
            &.{},
    };
    // The identity is what the walk matches on. Normally it comes from this
    // instance's `tag_ids[tag_idx]`; a `throw_ref` whose tag this module does
    // not declare arrives with the no-index marker and the identity in
    // `eh_thrown_tag_id` instead (#426 review).
    // `null` = no identity to carry, so the walk derives one from the index as
    // it always did. That is the case for a runtime with no `tag_ids` map:
    // `identityOf` then returns the INDEX, and recording that as an identity
    // would have `rethrowFromExnref` — which trusts a non-zero identity over
    // the index — search a map that is not there and report no local tag, so a
    // same-instance rethrow went uncaught (#426 review).
    const thrown_tag_id: ?u64 = if (tag_idx == jit_abi.no_local_tag_idx)
        rt.eh_thrown_tag_id // a rethrow with no local index: the identity IS the name
    else if (rt.tag_ids_ptr == null)
        null
    else
        table.identityOf(tag_idx);
    const site: zwasm_throw.ThrowSite = .{
        .initial_fp = initial_fp,
        .throw_site_addr = throw_site_addr,
        .tag_idx = tag_idx,
        .tag_id = thrown_tag_id,
    };

    // ADR-0134 D2 — cross-instance per-frame dispatch. With zero
    // registrations (no cross-module setup) the resolver returns null
    // for every PC → the walk falls back to `table` (this instance's),
    // i.e. identical single-instance behaviour. Registration (the
    // linker / spec runner) activates cross-instance unwinding.
    const result = zwasm_throw.dispatchThrow(
        table,
        &cmap,
        site,
        zwasm_throw.default_max_unwind_depth,
        eh_registry.resolver(),
        // D-238 / ADR-0185 (c) — global code-membership for the x86_64 sniff
        // (cross-instance frames + the importer's bridge thunk). arm64 ignores.
        eh_registry.isCodeAddr,
    );

    switch (result) {
        .uncaught => {
            rt.trap_flag = 1;
            rt.eh_handler_active = 0;
        },
        .handler => |h| {
            // Resolve the catching function's CodeMap entry via the
            // absolute PC captured at the matched frame. For a
            // CROSS-INSTANCE catch the handler lives in a different
            // instance than the throwing one, so its `start_addr` +
            // `frame_bytes` must come from the CATCHING instance's
            // CodeMap (ADR-0134 D2) — fall back to this instance's `cmap`
            // when the registry has no owner (single-instance / empty).
            const eff_cmap = eh_registry.codeMapForPc(h.handler_abs_pc) orelse cmap;
            const entry_lookup = eff_cmap.lookup(h.handler_abs_pc);
            switch (entry_lookup) {
                .inside => |hit| {
                    // SP-restore: handler_fp = catching frame's X29/RBP
                    // = SP at the point AFTER the prologue's `MOV X29,SP`.
                    // The prologue then did `SUB SP, SP, #frame_bytes`
                    // (allocating locals + spills + outgoing-call slots);
                    // to land at the catch handler with the prologue-
                    // completion SP, subtract that frame_bytes back.
                    rt.eh_handler_sp = h.handler_fp -% hit.frame_bytes;
                    // Landing-pad PC: module-relative `landing_pad_pc`
                    // plus the catching function's absolute `start_addr`.
                    rt.eh_handler_pc = hit.start_addr +% h.landing_pad_pc;
                    // The catching function's body addresses locals
                    // via X29/RBP; restore it from the matched frame.
                    rt.eh_handler_fp = h.handler_fp;
                    // The landing pad runs the CATCHING instance's code, so it
                    // needs that instance's runtime in the pinned invariant
                    // registers. A throw leaves through the bridge thunk's
                    // frame instead of returning through it, so the thunk's own
                    // restore never runs (#426 review). Falls back to this
                    // runtime when the registry has no owner — the
                    // single-instance case, where they are the same.
                    const catching_rt = eh_registry.runtimeForPc(h.handler_abs_pc) orelse rt;
                    // The landing pad reads the thrown payload through the SAME
                    // pinned register it reads globals through, so switching the
                    // register moves the payload out from under a `catch`
                    // clause's parameters — measured as 0 where 42 was thrown
                    // (runner_test's registered chain). Carry the dispatch state
                    // across to the instance that is about to read it. No-op
                    // when they are the same instance.
                    if (catching_rt != rt) {
                        catching_rt.eh_payload_len = rt.eh_payload_len;
                        const n = @min(rt.eh_payload_len, rt.eh_payload_buf.len);
                        var k: usize = 0;
                        while (k < n) : (k += 1) catching_rt.eh_payload_buf[k] = rt.eh_payload_buf[k];
                        catching_rt.eh_reify_ctx = rt.eh_reify_ctx;
                        // The tag INDEX is module-local and `Exception` records
                        // no owner, so copying it across would have a later
                        // `throw_ref` resolve the throwing module's number in
                        // the catching module's tag space — a different tag, or
                        // none (#426 review). Translate through the globally
                        // comparable identity the unwinder already matches on;
                        // when the catching module declares no tag with that
                        // identity, the exnref has no representable index here,
                        // and the no-match sentinel `rethrowFromExnref` already
                        // uses for a null exnref sends a `throw_ref` of it to an
                        // uncaught dispatch rather than to the wrong handler.
                        // The identity travels; the index is only its name in
                        // one module, so it is translated where the catching
                        // module has one and marked absent where it does not.
                        // `reifyExnref` keeps the identity either way, so an
                        // exnref rethrown in a third module that DOES declare
                        // the tag still names it.
                        catching_rt.eh_thrown_tag_idx =
                            translateTagIdx(rt, catching_rt, site.tag_idx) orelse
                            jit_abi.no_local_tag_idx;
                    }
                    rt.eh_handler_rt = @intFromPtr(catching_rt);
                    rt.eh_handler_active = 1;
                    // D-327 (ADR-0120 D6) — stash the thrown tag_idx so a
                    // catch_ref / catch_all_ref landing pad can reify the
                    // exnref with the ACTUAL caught tag (catch_all_ref has no
                    // compile-time tag). Uniform for both _ref kinds.
                    rt.eh_thrown_tag_idx = site.tag_idx;
                    // And the identity beside it, on the runtime the landing pad
                    // will reify through — UNCONDITIONALLY. Written only for a
                    // cross-instance catch, it went stale: this runtime kept the
                    // FOREIGN identity from an earlier cross-instance catch, and
                    // a later same-instance `_ref` catch reified its own tag
                    // with it, so `rethrowFromExnref` — which trusts a non-zero
                    // identity over the index — sent the rethrow to the wrong
                    // tag or to none (#426 review).
                    catching_rt.eh_thrown_tag_id = thrown_tag_id orelse 0;
                    // trap_flag stays 0 — handler dispatch will run.
                },
                .outside => {
                    // Defensive: should not happen for a real handler
                    // hit (the unwinder matched a HandlerEntry which by
                    // construction lives inside a JIT function's PC
                    // range). Treat as uncaught.
                    rt.trap_flag = 1;
                    rt.eh_handler_active = 0;
                },
            }
        },
    }
}

/// `from`'s local tag index expressed in `to`'s tag space, or null when `to`
/// declares no tag with the same identity. Tag indices are per module; the
/// `tag_ids` arrays hold the identity the unwinder compares (ADR-0134 D3), so
/// that is what crosses the boundary.
fn translateTagIdx(from: *const jit_abi.JitRuntime, to: *const jit_abi.JitRuntime, idx: u32) ?u32 {
    const from_ids = from.tag_ids_ptr orelse return null;
    if (idx >= from.tag_ids_count) return null;
    const identity = from_ids[idx];
    const to_ids = to.tag_ids_ptr orelse return null;
    var i: u32 = 0;
    while (i < to.tag_ids_count) : (i += 1) {
        if (to_ids[i] == identity) return i;
    }
    return null;
}

/// EH dispatcher trampoline. Invoked via BL/CALL from JIT-emitted
/// `throw` / `throw_ref` sites; expects:
///   - X0 / EDI: tag_idx (set by `op_throw.emit` marshal step)
///   - X19 / R15: pinned `*JitRuntime` (per ADR-0017)
///   - X29 / RBP: throw fn's frame pointer (intact via callee-
///     saved + naked-no-prologue discipline)
///   - X30 / [RSP]: saved-LR / saved-RIP (the throw-site address)
///
/// Marshals these into the C-ABI argregs for `trampolineCore`,
/// calls it, then branches on `JitRuntime.eh_handler_active`:
///   - 0 (uncaught): restore the saved FP/LR and RET back to the
///     throw site's post-CALL fallthrough (the trap-stub branch).
///   - 1 (handler): install `eh_handler_sp` → SP, `eh_handler_fp`
///     → X29/RBP, then BR/JMP to `eh_handler_pc` (the absolute
///     landing-pad address; never returns to the wrapper).
pub fn zwasmThrowTrampoline() callconv(.naked) noreturn {
    switch (builtin.target.cpu.arch) {
        // ARM64 body. The offsets into JitRuntime are inlined at
        // comptime via `std.fmt.comptimePrint` so the asm template
        // sees literal numbers; LDR Wt / LDR Xt accept 12-bit imm
        // (scaled by access size) which all current EH offsets fit
        // (≤ 296 B head_size). Comments live outside the template
        // body — the LLVM ARM64 inline-asm parser doesn't reliably
        // accept `//` as a comment delimiter.
        //
        //   stp x29, x30, [sp, #-16]!   ; save throw fn FP+LR
        //   mov x3, x19                  ; arg3 = rt ptr (pinned)
        //   mov x2, x0                   ; arg2 = tag_idx
        //   mov x1, x30                  ; arg1 = throw_site_addr
        //   mov x0, x29                  ; arg0 = initial_fp
        //   blr %[core]                  ; call trampolineCore (void)
        //   ldr w16, [x19, #active]      ; load eh_handler_active
        //   cbz w16, .Luncaught          ; 0 → uncaught fallthrough
        //   ldr x16, [x19, #sp]          ; handler path: load new SP
        //   mov sp, x16
        //   ldr x29, [x19, #fp]          ; restore catching frame FP
        //   ldr x17, [x19, #pc]          ; landing PC, before x19 moves
        //   ldr x19, [x19, #handler_rt]  ; the CATCHING instance's runtime
        //   ldr x23..x28, [x19, #...]    ; and its invariant cohort
        //   br x17                       ; jump (never returns here)
        // .Luncaught:
        //   ldp x29, x30, [sp], #16
        //   ret
        .aarch64 => asm volatile (std.fmt.comptimePrint(
                \\stp x29, x30, [sp, #-16]!
                \\mov x3, x19
                \\mov x2, x0
                \\mov x1, x30
                \\mov x0, x29
                \\blr %[core]
                \\ldr w16, [x19, #{d}]
                \\cbz w16, 1f
                \\ldr x16, [x19, #{d}]
                \\mov sp, x16
                \\ldr x29, [x19, #{d}]
                \\ldr x17, [x19, #{d}]
                \\ldr x19, [x19, #{d}]
                \\ldr x23, [x19, #{d}]
                \\ldr x24, [x19, #{d}]
                \\ldr x25, [x19, #{d}]
                \\ldr x26, [x19, #{d}]
                \\ldr x27, [x19, #{d}]
                \\ldr x28, [x19, #{d}]
                \\br x17
                \\1:
                \\ldp x29, x30, [sp], #16
                \\ret
            , .{
                jit_abi.eh_handler_active_off,
                jit_abi.eh_handler_sp_off,
                jit_abi.eh_handler_fp_off,
                jit_abi.eh_handler_pc_off,
                jit_abi.eh_handler_rt_off,
                jit_abi.globals_base_off,
                jit_abi.typeidx_base_off,
                jit_abi.table_size_off,
                jit_abi.funcptr_base_off,
                jit_abi.mem_limit_off,
                jit_abi.vm_base_off,
            })
            :
            : [core] "r" (&trampolineCore),
            : arm64_clobbers),
        // x86_64 SysV body. The handler arm restores RSP from
        // `eh_handler_sp`, RBP from `eh_handler_fp`, then `jmpq *`
        // through `eh_handler_pc`. The `pushq %rbp` from the
        // uncaught entry path is intentionally NOT popped on the
        // handler arm — the new SP completely supersedes the
        // wrapper's stack frame.
        //
        //   pushq %rbp                 ; save throw fn RBP
        //   movq 8(%rsp), %rsi          ; arg1 = throw_site_addr
        //   movq %rdi, %rdx             ; arg2 = tag_idx
        //   movq %rbp, %rdi             ; arg0 = initial_fp
        //   movq %r15, %rcx             ; arg3 = rt ptr
        //   callq *%[core]              ; trampolineCore (void)
        //   movl active(%r15), %eax
        //   testl %eax, %eax
        //   jz .Luncaught
        //   movq sp(%r15), %rsp         ; handler path
        //   movq fp(%r15), %rbp
        //   jmpq *pc(%r15)              ; never returns
        // .Luncaught:
        //   popq %rbp
        //   retq
        .x86_64 => switch (builtin.target.os.tag) {
            .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => asm volatile (std.fmt.comptimePrint(
                    \\pushq %%rbp
                    \\movq 8(%%rsp), %%rsi
                    \\movq %%rdi, %%rdx
                    \\movq %%rbp, %%rdi
                    \\movq %%r15, %%rcx
                    \\callq *%[core]
                    \\movl {d}(%%r15), %%eax
                    \\testl %%eax, %%eax
                    \\jz 1f
                    \\movq {d}(%%r15), %%rsp
                    \\movq {d}(%%r15), %%rbp
                    \\movq {d}(%%r15), %%rax
                    \\movq {d}(%%r15), %%r15
                    \\jmpq *%%rax
                    \\1:
                    \\popq %%rbp
                    \\retq
                , .{
                    jit_abi.eh_handler_active_off,
                    jit_abi.eh_handler_sp_off,
                    jit_abi.eh_handler_fp_off,
                    jit_abi.eh_handler_pc_off,
                    jit_abi.eh_handler_rt_off,
                })
                :
                : [core] "r" (&trampolineCore),
                : x86_64_clobbers),
            // x86_64 Win64 (MS x64) body. Same shape as the SysV
            // path — `callq *core; branch on eh_handler_active; on
            // 1 install SP/RBP and jmpq *pc`. Differences from SysV:
            //   - Arg routing: trampolineCore is `callconv(.c)` →
            //     Win64 ABI puts args in RCX/RDX/R8/R9.
            //     arg0 initial_fp     = %rcx (= %rbp at entry)
            //     arg1 throw_site_addr = %rdx (= saved RIP at +8 of
            //                                  the entry SP)
            //     arg2 tag_idx        = %r8  (op_throw doesn't yet
            //                                  marshal; placeholder
            //                                  via the throw-site-
            //                                  marshalled reg, same
            //                                  outstanding gap as SysV)
            //     arg3 rt             = %r9  (= %r15 pinned)
            //   - Shadow space: Win64 requires 32 bytes of caller-
            //     allocated stack before the CALL into trampolineCore
            //     (MS x64 ABI §The Stack After Function Prologues).
            //     `subq $0x20, %rsp` allocates; `addq $0x20, %rsp`
            //     releases on the uncaught arm. The handler arm
            //     never returns, so cleanup is implicit (new SP
            //     completely supersedes the wrapper's stack frame).
            //   - Stack-layout offset for saved RIP: at trampoline
            //     entry, [RSP] = saved RIP. After `pushq %rbp` we
            //     have [RSP] = saved RBP, [RSP+8] = saved RIP. Then
            //     `subq $0x20, %rsp` bumps the offsets by 0x20, so
            //     saved RIP lives at [RSP + 0x28].
            //
            //   pushq %rbp
            //   movq %rbp, %rcx                ; arg0 = initial_fp
            //   subq $0x20, %rsp               ; shadow space
            //   movq 0x28(%rsp), %rdx          ; arg1 = throw_site_addr
            //   movq <pre-marshalled tag reg>, %r8 ; arg2 = tag_idx
            //   movq %r15, %r9                 ; arg3 = rt ptr
            //   callq *%[core]
            //   movl active(%r15), %eax
            //   testl %eax, %eax
            //   jz .Luncaught
            //   movq sp(%r15), %rsp            ; handler arm
            //   movq fp(%r15), %rbp
            //   jmpq *pc(%r15)
            // .Luncaught:
            //   addq $0x20, %rsp               ; release shadow space
            //   popq %rbp
            //   retq
            //
            // op_throw on x86_64 emits `MOVABS R10, addr; CALL R10`;
            // it does not yet marshal tag_idx into a specific reg
            // (same outstanding gap on SysV). For the in-progress
            // EH pipeline, catch_all-only fixtures work because
            // catch_all ignores tag_idx; tagged-catch coverage is
            // gated on op_throw marshal completion (follow-on).
            // The Win64 body uses RCX as the "incoming tag_idx" reg
            // — matching the Win64 first-arg convention should
            // op_throw eventually marshal there — but the routing
            // is shuffled (initial_fp also wants RCX). Stash RCX
            // first via R10 (caller-saved, free).
            .windows => asm volatile (std.fmt.comptimePrint(
                    \\movq %%rcx, %%r10
                    \\pushq %%rbp
                    \\movq %%rbp, %%rcx
                    \\subq $0x20, %%rsp
                    \\movq 0x28(%%rsp), %%rdx
                    \\movq %%r10, %%r8
                    \\movq %%r15, %%r9
                    \\callq *%[core]
                    \\movl {d}(%%r15), %%eax
                    \\testl %%eax, %%eax
                    \\jz 1f
                    \\movq {d}(%%r15), %%rsp
                    \\movq {d}(%%r15), %%rbp
                    \\movq {d}(%%r15), %%rax
                    \\movq {d}(%%r15), %%r15
                    \\jmpq *%%rax
                    \\1:
                    \\addq $0x20, %%rsp
                    \\popq %%rbp
                    \\retq
                , .{
                    jit_abi.eh_handler_active_off,
                    jit_abi.eh_handler_sp_off,
                    jit_abi.eh_handler_fp_off,
                    jit_abi.eh_handler_pc_off,
                    jit_abi.eh_handler_rt_off,
                })
                :
                : [core] "r" (&trampolineCore),
                : x86_64_clobbers),
            else => @compileError("unsupported x86_64 OS for EH trampoline"),
        },
        else => @compileError("unsupported host arch for EH trampoline"),
    }
}

// ---------------------------------------------------------------------
// Tests — invoke the trampoline via an inline-asm wrapper that loads
// the pinned register (X19/R15) with a mock JitRuntime, BL/CALLs the
// trampoline, and verifies trap_flag was set.
// ---------------------------------------------------------------------

const testing = std.testing;

/// Wrapper that sets up the pinned `*JitRuntime` register, installs
/// a 2-slot **sentinel frame** as the trampoline's initial X29 / RBP,
/// and calls the trampoline. The sentinel terminates the unwinder's
/// frame-chain walk at depth 1 (`caller_fp == 0` → `.uncaught`) so
/// the test never depends on the host process's frame-pointer chain
/// being intact — Zig 0.16's self-hosted x86_64 backend doesn't
/// reliably maintain RBP-chaining, so walking the host stack would
/// dereference garbage and SEGV in a subsequent test (see lesson
/// `2026-05-28-eh-test-wrapper-host-fp-walk-segv.md`).
fn invokeTrampolineWith(rt: *jit_abi.JitRuntime, tag_idx: u32) void {
    // Sentinel "frame" the trampoline's naked stub will capture as
    // initial X29 / RBP: slot 0 = caller_fp = 0 (= top-of-Wasm-stack
    // sentinel per ADR-0114 D5 + arm64/frame_chain.zig docstring),
    // slot 1 = caller_lr = 0 (unused after caller_fp termination).
    var sentinel: [2]usize align(16) = .{ 0, 0 };
    const sentinel_ptr: usize = @intFromPtr(&sentinel);
    // Widen tag_idx to u64 so the "r" constraint guarantees a
    // full-width X (arm64) / RAX-class (x86_64) register with
    // the upper bits zero.
    const tag_idx_widened: u64 = tag_idx;
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            const trampoline_addr: usize = @intFromPtr(&zwasmThrowTrampoline);
            // STP saves X19 + X29 on the stack (16-byte aligned). The
            // trampoline body then sees X19 = rt and X29 = sentinel_ptr.
            // BLR clobbers X0..X17 + X30 (AAPCS64 caller-saved set);
            // the trampoline's own prologue saves X29/X30. After return,
            // LDP restores both. Comments live outside the asm template
            // body — the LLVM ARM64 inline-asm parser doesn't reliably
            // accept `//` mid-line.
            asm volatile (
                \\stp x19, x29, [sp, #-16]!
                \\mov x19, %[rt]
                \\mov x29, %[sentinel]
                \\mov x0, %[tag]
                \\blr %[addr]
                \\ldp x19, x29, [sp], #16
                :
                : [rt] "r" (rt),
                  [addr] "r" (trampoline_addr),
                  [tag] "r" (tag_idx_widened),
                  [sentinel] "r" (sentinel_ptr),
                : aarch64_invoke_clobbers);
        },
        .x86_64 => {
            const trampoline_addr: usize = @intFromPtr(&zwasmThrowTrampoline);
            // R12 is callee-saved under BOTH SysV and Win64 → preserved
            // across the trampoline's CALL → safe slot to save R15. RBP
            // is also callee-saved on both; push it, install the sentinel,
            // call, then restore. The two arms are identical except the
            // incoming-tag register: the SysV trampoline body reads the
            // tag from RDI (`movq %rdi,%rdx`), the Win64 body from RCX
            // (`movq %rcx,%r10`) — see the `.windows` production arm above.
            // The single `pushq %rbp` before `callq` is shared, so RSP
            // parity at the trampoline entry matches between the two arms
            // (and matches the production op_throw call site → entry RSP
            // ≡ 8 mod 16, the standard callee convention).
            switch (builtin.target.os.tag) {
                .windows => asm volatile (
                // The single `pushq %%rbp` would enter the trampoline at
                // RSP ≡ 0 mod 16, but the production op_throw JIT `CALL`
                // site enters at ≡ 8 — so the trampoline reaches
                // `trampolineCore` at ≡ 0 instead of the ABI-required
                // ≡ 8. SysV tolerates that (integer-only uncaught walk);
                // Win64's ABI-strict aligned-SSE prologue in
                // `trampolineCore` faults (D-248 sibling, throw_trampoline
                // Win64 crash). `subq/addq $8` restores production parity.
                    \\movq %%r15, %%r12
                    \\movq %[rt], %%r15
                    \\pushq %%rbp
                    \\movq %[sentinel], %%rbp
                    \\movq %[tag], %%rcx
                    \\subq $8, %%rsp
                    \\callq *%[addr]
                    \\addq $8, %%rsp
                    \\popq %%rbp
                    \\movq %%r12, %%r15
                    :
                    : [rt] "r" (rt),
                      [addr] "r" (trampoline_addr),
                      [tag] "r" (tag_idx_widened),
                      [sentinel] "r" (sentinel_ptr),
                    : x86_64_invoke_clobbers),
                else => asm volatile (
                    \\movq %%r15, %%r12
                    \\movq %[rt], %%r15
                    \\pushq %%rbp
                    \\movq %[sentinel], %%rbp
                    \\movq %[tag], %%rdi
                    \\callq *%[addr]
                    \\popq %%rbp
                    \\movq %%r12, %%r15
                    :
                    : [rt] "r" (rt),
                      [addr] "r" (trampoline_addr),
                      [tag] "r" (tag_idx_widened),
                      [sentinel] "r" (sentinel_ptr),
                    : x86_64_invoke_clobbers),
            }
        },
        else => @compileError("unsupported host arch"),
    }
}

const aarch64_invoke_clobbers = if (builtin.target.cpu.arch == .aarch64)
    std.builtin.assembly.Clobbers{
        // BLR clobbers the AAPCS64 caller-saved set (X0..X17, X30, V0..V7).
        // X19 + X29 are saved/restored via STP/LDP within the asm body.
        .x0 = true,
        .x1 = true,
        .x2 = true,
        .x3 = true,
        .x17 = true,
        .x30 = true,
        .memory = true,
    }
else {
    // non-aarch64 hosts skip.
};

const x86_64_invoke_clobbers = if (builtin.target.cpu.arch == .x86_64)
    std.builtin.assembly.Clobbers{
        // SysV caller-saved set touched by the CALL into trampolineCore.
        // R12 is written (used as R15 save slot); RBP is saved/restored
        // on the stack within the asm body.
        .rax = true,
        .rcx = true,
        .rdx = true,
        .rdi = true,
        .rsi = true,
        .r8 = true,
        .r9 = true,
        .r10 = true,
        .r11 = true,
        .r12 = true,
        .memory = true,
    }
else {
    // non-x86_64 hosts skip.
};

test "zwasmThrowTrampoline: uncaught path sets trap_flag (no handler installed)" {
    // Empty EH table → dispatchThrow returns .uncaught; trap_flag
    // is set by trampolineCore. End-to-end exercises:
    //   op_throw site → naked stub → trampolineCore →
    //   dispatchThrow → unwind.walk → no match → .uncaught →
    //   rt.trap_flag = 1 → RET to throw site
    var rt: jit_abi.JitRuntime = std.mem.zeroes(jit_abi.JitRuntime);
    try testing.expectEqual(@as(u32, 0), rt.trap_flag);
    invokeTrampolineWith(&rt, 0);
    try testing.expectEqual(@as(u32, 1), rt.trap_flag);
    try testing.expectEqual(@as(u32, 0), rt.eh_handler_active);
}

test "zwasmThrowTrampoline: handler-found path populates eh_handler_sp + eh_handler_pc + active=1" {
    // Install a catch_all handler that covers the throw site's
    // PC. dispatchThrow returns .handler; trampolineCore now
    // resolves the catching function's CodeMap entry, computes
    // the absolute landing-pad PC (start_addr + landing_pad_pc)
    // and the restored SP (handler_fp - frame_bytes), stashes
    // both in JitRuntime, and sets `eh_handler_active = 1`. The
    // naked-stub branch + JMP path consumes
    // these fields; this test verifies the data plumbing.
    var rt: jit_abi.JitRuntime = std.mem.zeroes(jit_abi.JitRuntime);

    const cmap_entries = [_]code_map_mod.Entry{
        .{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0, .frame_bytes = 32 },
    };
    rt.eh_code_map_entries = cmap_entries[0..].ptr;
    rt.eh_code_map_count = cmap_entries.len;

    const eh_entries = [_]exception_table.HandlerEntry{
        .{ .pc_start = 0, .pc_end = 0x100, .tag_idx = null, .landing_pad_pc = 0x40, .kind = .catch_all },
    };
    rt.eh_table_entries = eh_entries[0..].ptr;
    rt.eh_table_count = eh_entries.len;

    // Direct `trampolineCore` call (bypasses the asm wrapper so we
    // control `throw_site_addr` precisely — needed to assert exact
    // absolute landing-pad PC + SP values).
    const fake_handler_fp: usize = 0x7FFF_0000_4000;
    trampolineCore(fake_handler_fp, 0x10042, 5, &rt);

    try testing.expectEqual(@as(u32, 1), rt.eh_handler_active);
    try testing.expectEqual(@as(u32, 0), rt.trap_flag);
    // start_addr (0x10000) + landing_pad_pc (0x40) = 0x10040.
    try testing.expectEqual(@as(usize, 0x10040), rt.eh_handler_pc);
    // handler_fp (0x7FFF_0000_4000) - frame_bytes (32) = …_3FE0.
    try testing.expectEqual(@as(usize, 0x7FFF_0000_3FE0), rt.eh_handler_sp);
    try testing.expectEqual(@as(usize, 0x7FFF_0000_4000), rt.eh_handler_fp);
}

test "zwasmThrowTrampoline: uncaught fallback (no handler reachable) → trap_flag + active=0" {
    // Empty handler table → walker never matches. Use a stack-resident
    // sentinel frame so loadFrame returns caller_fp=0 cleanly (no host
    // stack walk, per test_discipline.md §3).
    var sentinel: [2]usize align(16) = .{ 0, 0 };
    var rt: jit_abi.JitRuntime = std.mem.zeroes(jit_abi.JitRuntime);

    const cmap_entries = [_]code_map_mod.Entry{
        .{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0, .frame_bytes = 0 },
    };
    rt.eh_code_map_entries = cmap_entries[0..].ptr;
    rt.eh_code_map_count = cmap_entries.len;
    // No handler installed → .uncaught.

    trampolineCore(@intFromPtr(&sentinel), 0x10042, 5, &rt);
    try testing.expectEqual(@as(u32, 0), rt.eh_handler_active);
    try testing.expectEqual(@as(u32, 1), rt.trap_flag);
}

test "zwasmThrowTrampoline: symbol address is non-zero (linker exported)" {
    try testing.expect(@intFromPtr(&zwasmThrowTrampoline) != 0);
}
