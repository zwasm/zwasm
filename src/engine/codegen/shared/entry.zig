// FILE-SIZE-EXEMPT: uniform-pattern catalog (127 callXX_yy per-shape entry helpers; monotonic growth with Wasm signature shapes — +8 D-467 multi-scalar→v128 + 2 D-467 load/store-lane (i32,v128)→v128/i64) (cap=3200) (per ADR-0063 + ADR-0099 Revision 2026-05-24)
// Comptime generation is a follow-up; see ADR-0063 Alternative B + debt ledger.

//! JIT entry frame (ADR-0017).
//!
//! Bridge from a Zig caller into a JIT-emitted Wasm function.
//! Per ADR-0017, the JIT body's prologue loads X28..X24 from
//! `*X0 = *const JitRuntime`, so the entry frame collapses to
//! a standard AAPCS64 / System V function-pointer call passing
//! `&runtime` as the first argument. No inline asm; no clobber
//! list; same source compiles for both backends (Phase 7.6+).
//!
//! Argument marshalling for entry signatures with non-trivial
//! parameters (`callI32_i32i32`, etc.) lands in follow-up sub-
//! rows; this entry path covers the no-arg + i32-result shape.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");

const linker = @import("linker.zig");
const jit_abi = @import("jit_abi.zig");
const stack_limit_mod = @import("../../../platform/stack_limit.zig");
const signal = @import("../../../platform/signal.zig"); // ADR-0202 D4 fault-handler auto-install
const entry_buffer_write = @import("entry_buffer_write.zig");

/// Shared clobber set for the AAPCS64 inline-asm BLR thunks used by
/// the Class B entry helpers (ADR-0069). Lists all caller-saved
/// integer + FP registers the JIT body may touch. Outputs that pin a
/// specific register (e.g. `={x0}`) are still listed here — Zig's
/// asm machinery accepts the overlap silently. Factored to one
/// const to avoid repeating ~30 lines per helper.
const aarch64_blr_clobbers: if (builtin.target.cpu.arch == .aarch64) std.builtin.assembly.Clobbers else void =
    if (builtin.target.cpu.arch == .aarch64) .{
        .x0 = true,
        .x1 = true,
        .x2 = true,
        .x3 = true,
        .x4 = true,
        .x5 = true,
        .x6 = true,
        .x7 = true,
        .x8 = true,
        .x9 = true,
        .x10 = true,
        .x11 = true,
        .x12 = true,
        .x13 = true,
        .x14 = true,
        .x15 = true,
        .x16 = true,
        .x17 = true,
        .x30 = true,
        .z0 = true,
        .z1 = true,
        .z2 = true,
        .z3 = true,
        .z4 = true,
        .z5 = true,
        .z6 = true,
        .z7 = true,
        .memory = true,
    } else {
        // non-aarch64 hosts have no Class B inline-asm thunk; the
        // const's value collapses to void, which the linker discards.
    };

/// Shared clobber set for the x86_64 SysV inline-asm CALL thunk used
/// by Class B `(f64, f32)` mixed-eightbyte FP-class return (ADR-0069
/// D-146). Zig 0.16's `splitType` doesn't yet generate the call-site
/// disassembly for two same-class (SSE) eightbytes of different widths,
/// so the helper performs the CALL in inline-asm and captures XMM0 /
/// XMM1 directly. Lists every SysV caller-saved GPR + the full XMM
/// register bank.
const x86_64_sysv_call_clobbers: if (builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag != .windows) std.builtin.assembly.Clobbers else void =
    if (builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag != .windows) .{
        .rax = true,
        .rcx = true,
        .rdx = true,
        .rsi = true,
        .rdi = true,
        .r8 = true,
        .r9 = true,
        .r10 = true,
        .r11 = true,
        .xmm0 = true,
        .xmm1 = true,
        .xmm2 = true,
        .xmm3 = true,
        .xmm4 = true,
        .xmm5 = true,
        .xmm6 = true,
        .xmm7 = true,
        .xmm8 = true,
        .xmm9 = true,
        .xmm10 = true,
        .xmm11 = true,
        .xmm12 = true,
        .xmm13 = true,
        .xmm14 = true,
        .xmm15 = true,
        .cc = true,
        .memory = true,
    } else {
        // non-x86_64-SysV hosts: const value collapses to void.
    };

/// Shared clobber set for the x86_64 Win64 inline-asm CALL thunks used
/// by Class B mixed-eightbyte entry helpers on Windows (D-161). The
/// JIT body on Win64 writes results per the per-class assignment
/// (INTEGER → RAX, SSE → XMM0/XMM1) — which does NOT match the
/// Microsoft x64 C ABI for `{INTEGER, SSE}`-style structs (returned
/// via hidden RCX pointer when > 8 bytes). The thunk performs the
/// CALL in inline-asm, passes rt in RCX (Win64 first int arg), and
/// captures the result registers directly. Lists every Win64
/// caller-saved (volatile) GPR + XMM0–XMM5 (XMM6–XMM15 are
/// non-volatile under Win64 and the JIT prologue preserves them).
const x86_64_win64_call_clobbers: if (builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .windows) std.builtin.assembly.Clobbers else void =
    if (builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .windows) .{
        .rax = true,
        .rcx = true,
        .rdx = true,
        .r8 = true,
        .r9 = true,
        .r10 = true,
        .r11 = true,
        .xmm0 = true,
        .xmm1 = true,
        .xmm2 = true,
        .xmm3 = true,
        .xmm4 = true,
        .xmm5 = true,
        .cc = true,
        .memory = true,
    } else {
        // non-Win64 hosts: const value collapses to void.
    };

/// D-245 — the callee-saved GPRs the JIT prologue clobbers.
/// The prologue MOV-installs the pinned cohort (arm64 X19/X24-X28; x86_64
/// RBX/R12-R15) from `rt` WITHOUT stack-saving the caller's values, so a plain
/// host→JIT `@call` lets ReleaseSafe's optimized host lose any live value it
/// kept there → heap-corruption SEGV. `jitTrampoline` clobber-lists this set
/// so ITS prologue/epilogue saves & restores the cohort around the call,
/// masking the JIT's clobber. XMM/FP is omitted — the JIT already preserves
/// win64 XMM6-15, and the SysV/AAPCS64 FP cohort is caller-saved. The x86_64
/// arm is identical for SysV and Windows (same JIT regalloc pool).
pub const jit_cohort_clobbers: if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .x86_64) std.builtin.assembly.Clobbers else void =
    if (builtin.target.cpu.arch == .aarch64) .{
        .x19 = true,
        .x20 = true,
        .x21 = true,
        .x22 = true,
        .x23 = true,
        .x24 = true,
        .x25 = true,
        .x26 = true,
        .x27 = true,
        .x28 = true,
        .memory = true,
    } else if (builtin.target.cpu.arch == .x86_64) .{
        .rbx = true,
        .r12 = true,
        .r13 = true,
        .r14 = true,
        .r15 = true,
        .memory = true,
    } else {
        // other arches: no JIT cohort clobber; the const collapses to void.
    };

/// D-245 RESULT-path trampoline. Non-inline by construction
/// (called via `@call(.never_inline, …)`), so it has a real prologue/epilogue.
/// The `asm volatile ("" ::: jit_cohort_clobbers)` after the JIT call forces
/// THIS frame to save & restore the cohort the JIT clobbers, transparently
/// preserving the host caller's callee-saved registers. No per-arg asm
/// marshaling and no XMM handling — the default Zig calling convention passes
/// `.{rt} ++ args` correctly and still preserves callee-saved registers.
fn jitTrampoline(comptime R: type, f: anytype, rt: *JitRuntime, args: anytype) R {
    const r = @call(.auto, f, .{rt} ++ args);
    asm volatile ("" ::: jit_cohort_clobbers);
    return r;
}

/// Void sibling of `jitTrampoline` for the arg'd void path.
fn jitTrampolineVoid(f: anytype, rt: *JitRuntime, args: anytype) void {
    @call(.auto, f, .{rt} ++ args);
    asm volatile ("" ::: jit_cohort_clobbers);
}

pub const JitRuntime = jit_abi.JitRuntime;
pub const EhReifyCtx = jit_abi.EhReifyCtx;
pub const reifyExnref = jit_abi.reifyExnref;
pub const SegmentSlice = jit_abi.SegmentSlice;
pub const TableSlice = jit_abi.TableSlice;
pub const table_no_max: u64 = jit_abi.table_no_max;
pub const ElemSlice = jit_abi.ElemSlice;
pub const TableJitCallInfo = jit_abi.TableJitCallInfo;

pub const Error = error{
    /// The JIT body trapped — its trap stub stored 1 to
    /// `runtime.trap_flag` before unwinding. Sub-7.5b-ii
    /// detection is single-bit; Diagnostic M3 (D-022) widens
    /// this to per-trap-kind reasons.
    Trap,
};

/// Body shared by the ~97 Class A / Class C entry helpers.
/// `R` is the return type; `f` is the typed function pointer
/// produced by `module.entry(func_idx, FnPtr)`; `args` is a
/// tuple of the JIT-side parameters (without `rt`, which is
/// prepended here). Per ADR-0017 trap discipline: zero
/// `trap_flag` before the call, raise `Error.Trap` if it
/// becomes non-zero. D-135 discharge — collapses the 6-line
/// boilerplate that previously appeared in every helper.
inline fn invokeAndCheck(
    rt: *JitRuntime,
    comptime R: type,
    f: anytype,
    args: anytype,
) Error!R {
    // ADR-0202 D4 — guard-page bounds elision converts an oob access into a
    // hardware fault the production handler redirects to the oob stub. Any
    // JIT execution must therefore have a fault handler armed; this is the
    // single chokepoint (idempotent, skips when the CLI/embedding/spec-runner
    // already installed one). Cheap atomic-bool fast path after the once.
    signal.ensureInstalled();
    // ADR-0105 D1 — populate stack_limit per call for the prologue probe.
    rt.stack_limit = stack_limit_mod.computeStackLimit(stack_limit_mod.STACK_GUARD_HEADROOM);
    rt.trap_flag = 0;
    stack_limit_mod.diagOnceWithRt(rt, jit_abi.stack_limit_off, rt.stack_limit);
    // D-245: route through the non-inline clobber-trampoline
    // so the host's callee-saved cohort is preserved across the JIT call.
    // `.never_inline` guarantees a real prologue/epilogue on `jitTrampoline`.
    const result = @call(.never_inline, jitTrampoline, .{ R, f, rt, args });
    if (rt.trap_flag == 0) return result;
    // D-165 trap-stub entry-count diagnostic, gated behind -Dtrace-stackprobe
    // (default false; ADR-0164 B / D-292) — a D-279 Win64 investigation primitive.
    if (comptime build_options.trace_stackprobe) {
        if (rt.trap_kind == 4) dbg.print("codegen", "[d-165] kind=4 cumulative_trap_stub_entry_count={d}\n", .{rt.trap_stub_entry_count});
    }
    return Error.Trap;
}

/// Void-return sibling of `invokeAndCheck`.
inline fn invokeAndCheckVoid(
    rt: *JitRuntime,
    f: anytype,
    args: anytype,
) Error!void {
    signal.ensureInstalled(); // ADR-0202 D4 — see invokeAndCheck
    rt.stack_limit = stack_limit_mod.computeStackLimit(stack_limit_mod.STACK_GUARD_HEADROOM);
    rt.trap_flag = 0;
    stack_limit_mod.diagOnceWithRt(rt, jit_abi.stack_limit_off, rt.stack_limit);
    if (comptime builtin.target.cpu.arch == .aarch64 and args.len == 0) {
        // D-245: the JIT prologue MOV-installs the pinned cohort (X19 +
        // X24-X28) from `rt` WITHOUT saving the caller's values
        // (ADR-0017 / D-210), so it clobbers the host's callee-saved
        // X19-X28 and its epilogue can't restore them. A plain `@call`
        // leaves the host's live X19-X28 unprotected → SEGV in ReleaseSafe.
        // The asm manually stp/ldp X19-X28 around the BLR (balanced SP, 80B
        // = 16-aligned) so they're preserved WITHOUT clobber-listing them
        // (listing all 10 over-constrains the register allocator). Caller-
        // saved + X30 are still declared via aarch64_blr_clobbers.
        asm volatile (
            \\ stp x19, x20, [sp, #-80]!
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ mov x0, x10
            \\ blr %[callee]
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x19, x20, [sp], #80
            :
            // x0 is not an operand of this asm.
            //
            // It used to be both: an input `"{x0}"` carrying the runtime and an
            // output `"={x0}"` reading a result. The two are untied, so the
            // allocator may materialise the output's def before the input's use —
            // and under optimisation it did, leaving `blr` to enter the JIT body
            // with x0 holding whatever the output slot had been given rather than
            // the runtime. The fault address was a small constant: a field offset
            // read off that garbage. Debug allocated differently and never showed
            // it.
            //
            // The runtime now arrives in x10 and is placed in x0 by the asm itself;
            // results come back through x11/x12/x13. Every operand is pinned to a
            // named register — `"r"` was free to pick x0, or to pick the register a
            // neighbouring line had just written.
            //
            // Those registers are also in the clobber list. That overlap is the
            // tolerance the note at the head of this file already records; it is not
            // the reason this is correct.
            : [callee] "{x9}" (f),
              [rt_arg] "{x10}" (rt),
            : aarch64_blr_clobbers);
    } else if (comptime builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag != .windows and args.len == 0) {
        // D-245 (x86_64 SysV): the JIT uses an all-callee-saved regalloc pool
        // (RBX/R12-R15) and only the prologue's PUSH R15 is saved — R12-R14/RBX
        // are clobbered without restore, so a plain `@call` lets ReleaseSafe's
        // host lose its live values there → SEGV. Save/restore them around the
        // CALL (callee in RAX, rt in RDI). 5 pushes (40B) + sub $8 keep the
        // pre-CALL RSP 16-aligned (callee sees %16==8 per SysV), assuming the
        // inlined call site's incoming RSP is 16-aligned (as `@call` would need).
        asm volatile (
            \\ pushq %%rbx
            \\ pushq %%r12
            \\ pushq %%r13
            \\ pushq %%r14
            \\ pushq %%r15
            \\ subq $8, %%rsp
            \\ callq *%[callee]
            \\ addq $8, %%rsp
            \\ popq %%r15
            \\ popq %%r14
            \\ popq %%r13
            \\ popq %%r12
            \\ popq %%rbx
            :
            : [callee] "{rax}" (f),
              [rt_arg] "{rdi}" (rt),
            : x86_64_sysv_call_clobbers);
    } else {
        // D-245: arg'd void path — preserve the host cohort
        // via the non-inline clobber-trampoline. The no-arg arm64/x86_64
        // branches above keep their dedicated manual-asm save/restore.
        @call(.never_inline, jitTrampolineVoid, .{ f, rt, args });
    }
    if (rt.trap_flag != 0) {
        return Error.Trap;
    }
}

/// Host/test-boundary SAFE call of a raw entry fn-ptr `f` (materialised via
/// `module.entry` / `LoadedModule.entry`) through the D-245 cohort-clobber
/// trampoline. Use this instead of calling `f(rt, ...)` directly from a Zig
/// frame: the JIT prologue MOV-installs the pinned callee-saved cohort from
/// `rt` WITHOUT saving the caller's values, so a direct inline call lets the
/// compiler keep a live cohort-reg value across it → seed-dependent
/// corruption/SEGV (D-311). `R` = result type; `args` = the JIT params after
/// `rt`. Generic over JIT and AOT fn-ptrs (any `f`).
pub fn callEntrySafe(rt: *JitRuntime, comptime R: type, f: anytype, args: anytype) Error!R {
    return invokeAndCheck(rt, R, f, args);
}

/// Call a no-argument JIT function returning i32.
///
/// Per ADR-0017, X0 carries the runtime pointer; the body's
/// prologue does `LDR X28, [X0, #0]` etc. to materialise the
/// invariants. The native function-pointer call lowers to
/// `mov x0, <rt>; blr fn` automatically.
///
/// Sub-7.5b-ii: takes `*JitRuntime` (mutable) so the trap stub
/// can write `rt.trap_flag = 1` on trap. This fn zeroes
/// `trap_flag` before each call and returns `Error.Trap` if it
/// was set after the call.
pub fn callI32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{});
}

/// Variants taking a raw entry fn ptr (rather than a `JitModule` +
/// idx) so the AOT loader — which holds `LoadedModule.entry(idx, Fn)`
/// pointers, not a `JitModule` — reuses the same trap-flag / stack-limit
/// invoke invariant (ADR-0105 D1) instead of duplicating it.
pub fn callI32NoArgsPtr(f: *const fn (*const JitRuntime) callconv(.c) u32, rt: *JitRuntime) Error!u32 {
    return invokeAndCheck(rt, u32, f, .{});
}

pub fn callVoidNoArgsPtr(f: *const fn (*const JitRuntime) callconv(.c) void, rt: *JitRuntime) Error!void {
    return invokeAndCheckVoid(rt, f, .{});
}

/// Call a single-i32-argument JIT function returning i32.
/// Per AAPCS64 / SysV the ABI puts `rt` in X0 / RDI and `a0` in
/// X1 / RSI; the JIT body's prologue snapshots X1 (W1) into the
/// param-0 local slot. Used by the spec-assertion-driver
/// to invoke `assert_return` actions whose action.args is one i32.
pub fn callI32_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{a0});
}

/// Call a two-i32-argument JIT function returning i32. ABI puts
/// `rt`, `a0`, `a1` in X0, X1, X2 (AAPCS64) / RDI, RSI, RDX (SysV);
/// the prologue stores W1 → [SP, #0] and W2 → [SP, #8].
pub fn callI32_i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u32, u32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// Call a no-argument void-returning JIT function (results.len == 0).
/// The JIT body's function-level `end` handler skips result
/// marshalling when `func.sig.results.len == 0`; the epilogue
/// runs as POP RBP / RET (x86_64) or LDP / RET (ARM64). Used by
/// the spec_assert dispatch for `local.set` /
/// `global.set` / store-style assertions whose `(invoke ...)`
/// has empty `expected`. Trap detection mirrors `callI32NoArgs`.
pub fn callVoidNoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!void {
    const Fn = *const fn (*const JitRuntime) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{});
}

/// Call a single-i32-argument void-returning JIT function.
pub fn callVoid_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{a0});
}

/// Call a two-i32-argument void-returning JIT function.
pub fn callVoid_i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u32, u32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// Call a single-i64-argument void-returning JIT function.
pub fn callVoid_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u64) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{a0});
}

/// Call a single-f32-argument void-returning JIT function.
/// Used by spec_assert local_set fixtures whose param is f32.
pub fn callVoid_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, f32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{a0});
}

/// D-114 / d-41: `(i32, i64)` void-returning. Used by
/// memory_trap.wast's `i64.store` / `i64.store8` / `i64.store16` /
/// `i64.store32` exports (`(param i32) (param i64)` — addr + value);
/// both the assert_return form (`(invoke "i64.store" 0xfff8 0)`) and
/// the assert_trap form (`(invoke "i64.store" 0xfff9 …)`) need it.
pub fn callVoid_i32i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u64,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u32, u64) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// `(i64, i32) -> ()` — spec-corpus 2-arg JIT dispatch (D-217). e.g.
/// memory64 `store(i64 addr, i32 val)` (memory_trap64).
pub fn callVoid_i64i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: u32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u64, u32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// D-116: `(i32, f32)` void-returning. Used by float_exprs.wast's
/// `init` exports — `(func (param i32) (param f32) (f32.store ...))`
/// — so the `(invoke "init" ...)` bare actions actually execute and
/// leave their f32 in linear memory for subsequent `(invoke "check"
/// ...)` reads.
pub fn callVoid_i32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: f32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u32, f32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// D-116: `(i32, f64)` void-returning. f64 sibling of the
/// `callVoid_i32f32` shape used by float_exprs.wast's f64-typed
/// `init` exports.
pub fn callVoid_i32f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: f64,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u32, f64) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// D-116: `(i32, i32, i32)` void-returning. Used by float_exprs.wast's
/// `f<32,64>.simple_x4_sum` exports (`(param i32) (param i32) (param
/// i32)` — i / j / k offset triple).
pub fn callVoid_i32i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
    a2: u32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u32, u32, u32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

/// 5-arg helpers for the `(i64 f32 f64 i32 i32)` family that
/// covers the upstream `local_get`/`local_set` mixed-type
/// fixtures (`type-mixed`, `read`, `write`). Per AAPCS64 / SysV
/// the FP args go in V0/V1 (S0/D1) and the int args go in
/// X0..X4 / RDI..R8 in declaration order; the `callconv(.c)`
/// function pointer matches that ABI by construction.
pub fn callVoid_i64f32f64i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: f32,
    a2: f64,
    a3: u32,
    a4: u32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u64, f32, f64, u32, u32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1, a2, a3, a4 });
}

pub fn callI64_i64f32f64i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: f32,
    a2: f64,
    a3: u32,
    a4: u32,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u64, f32, f64, u32, u32) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ a0, a1, a2, a3, a4 });
}

pub fn callF64_i64f32f64i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: f32,
    a2: f64,
    a3: u32,
    a4: u32,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, u64, f32, f64, u32, u32) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1, a2, a3, a4 });
}

/// Call a single-f64-argument void-returning JIT function.
pub fn callVoid_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!void {
    const Fn = *const fn (*const JitRuntime, f64) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{a0});
}

/// Call a no-argument JIT function returning i64. ARM64 epilogue
/// MOV X0, X<vreg> (64-bit form) for results[0] == .i64.
pub fn callI64NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{});
}

/// Call a single-i32-argument JIT function returning i64.
pub fn callI64_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{a0});
}

/// Call a single-i64-argument JIT function returning i64.
pub fn callI64_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u64) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{a0});
}

/// Call a no-argument JIT function returning f32.
pub fn callF32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{});
}

/// Call a single-f32-argument JIT function returning f32.
pub fn callF32_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{a0});
}

/// Call a no-argument JIT function returning f64.
pub fn callF64NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{});
}

/// Call a single-f64-argument JIT function returning f64.
pub fn callF64_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, f64) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{a0});
}

// Cross-type scalar entry helpers
// covering `conversions.wast` shapes (trunc / trunc_sat for FP→int,
// convert for int→FP, promote / demote / reinterpret across FP
// widths). One entry pattern per (arg, result) pair so the FFI
// signature `*const fn (...) callconv(.c) <ret>` matches the JIT
// body's calling convention regardless of FP-vs-GPR ABI lane
// assignment.

/// Wasm spec §4.4.1 (i32.trunc_f32_s / _u, i32.trunc_sat_f32_s / _u,
/// i32.reinterpret_f32) — (f32) → i32 entry. Result type is u32
/// because the runner compares bit patterns and Wasm i32 is
/// representation-uninterpreted.
pub fn callI32_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, f32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (i32.trunc_f64_s / _u, i32.trunc_sat_f64_s / _u)
/// — (f64) → i32 entry.
pub fn callI32_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, f64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (i64.trunc_f32_s / _u, i64.trunc_sat_f32_s / _u)
/// — (f32) → i64 entry.
pub fn callI64_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, f32) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (i32.wrap_i64) — (i64) → i32 entry. The
/// 32-bit wrap is performed inside the JIT body (`AND eax, eax`
/// / equivalent); this entry just adapts the calling convention.
pub fn callI32_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (i64.trunc_f64_s / _u, i64.trunc_sat_f64_s / _u,
/// i64.reinterpret_f64) — (f64) → i64 entry.
pub fn callI64_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, f64) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (f32.convert_i32_s / _u, f32.reinterpret_i32)
/// — (i32) → f32 entry.
pub fn callF32_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (f32.convert_i64_s / _u) — (i64) → f32 entry.
pub fn callF32_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, u64) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (f64.convert_i32_s / _u) — (i32) → f64 entry.
pub fn callF64_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (f64.convert_i64_s / _u, f64.reinterpret_i64)
/// — (i64) → f64 entry.
pub fn callF64_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, u64) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (f32.demote_f64) — (f64) → f32 entry.
pub fn callF32_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f64) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{a0});
}

/// Wasm spec §4.4.1 (f64.promote_f32) — (f32) → f64 entry.
pub fn callF64_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, f32) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{a0});
}

// 2-arg scalar entry helpers covering the
// i64 / f32 / f64 binop + cmp families exercised by `i64.wast`,
// `f32.wast`, `f64.wast`, `f32_cmp.wast`, `f64_cmp.wast`. Each
// follows the same single-helper template as the 1-arg variants.

/// Wasm spec §4.4.1 (i64.add / sub / mul / and / or / xor /
/// div_s / div_u / rem_s / rem_u / shl / shr_s / shr_u / rotl /
/// rotr) — (i64, i64) → i64 entry.
pub fn callI64_i64i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: u64,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u64, u64) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// Wasm spec §4.4.1 (i64.eq / ne / lt_s / lt_u / gt_s / gt_u /
/// le_s / le_u / ge_s / ge_u) — (i64, i64) → i32 entry.
pub fn callI32_i64i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: u64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u64, u64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// Wasm spec §4.4.1 (f32.add / sub / mul / div / min / max /
/// copysign) — (f32, f32) → f32 entry.
pub fn callF32_f32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f32, f32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// Wasm spec §4.4.1 (f32.eq / ne / lt / gt / le / ge) —
/// (f32, f32) → i32 entry (FP comparison → i32 boolean).
pub fn callI32_f32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, f32, f32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// Wasm spec §4.4.1 (f64.add / sub / mul / div / min / max /
/// copysign) — (f64, f64) → f64 entry.
pub fn callF64_f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, f64, f64) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// Wasm spec §4.4.1 (f64.eq / ne / lt / gt / le / ge) —
/// (f64, f64) → i32 entry (FP comparison → i32 boolean).
pub fn callI32_f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, f64, f64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1 });
}

// 3+/4+-arg + mixed scalar entry shapes
// added to satisfy the `runner-shape-gap` skip-impl families surfaced
// by `nop` (3 i32 args), `f32` / `f64` arith (3+ FP args), and
// other multi-arg fixtures. Each helper mirrors the established
// AAPCS64 / SysV convention used by callI32_i32i32 etc.

pub fn callI32_i32i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
    a2: u32,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u32, u32, u32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

pub fn callI64_i32i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u64,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u32, u64) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ a0, a1 });
}

pub fn callI64_i64i64i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: u64,
    a2: u32,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u64, u64, u32) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

// D-301 — 3-arg atomic shapes for the threads spec corpus.
// i64.atomic.rmw.cmpxchg (addr, exp, repl) → i64.
pub fn callI64_i32i64i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u64,
    a2: u64,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u32, u64, u64) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}
// memory.atomic.wait32 (addr, expected, timeout) → i32.
pub fn callI32_i32i32i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
    a2: u64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u32, u32, u64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}
// memory.atomic.wait64 (addr, expected, timeout) → i32.
pub fn callI32_i32i64i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u64,
    a2: u64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u32, u64, u64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

/// Multi-result return struct for `(i64, i32)` shape. Wasm spec §4.5.3
/// allows function results of arbitrary length; Zig's `extern struct`
/// produces the AAPCS64 / SysV "small-struct returned via X0/RAX +
/// X1/RDX (Win64: hidden-ptr in RCX)" ABI layout that matches what
/// the JIT body's epilogue marshals into the result registers.
/// Field order matches Wasm result order (r0 = first result).
///
/// Entry-helper cohort per ADR-0065; this is the first
/// multi-result `FuncRet_*` struct. Subsequent shapes follow the same
/// naming convention `FuncRet_<concat-result-types>` (no separator).
pub const FuncRet_i64i32 = extern struct {
    r0: u64,
    r1: u32,
};

/// Multi-result return for `(i32, i64)`. Spec `value-block-i32-i64` /
/// `type-i32-i64` families. AAPCS64 / SysV pack via X0+X1 register
/// pair (16-byte struct with 4-byte padding after `r0`).
pub const FuncRet_i32i64 = extern struct {
    r0: u32,
    r1: u64,
};

/// Multi-result return for `(i32, i32)`. Spec `multi` /
/// `type-all-i32-i32` / `value-i32-i32` families.
///
/// **Layout convention** (entry.zig multi-result): each field is
/// u64-padded so the struct's total size is ≥ 16 bytes, forcing
/// AAPCS64 / SysV to return via the X0+X1 (RAX+RDX on SysV)
/// register-pair path instead of packing two fields into a single
/// register. This aligns the Zig C-ABI struct return layout with
/// the JIT epilogue's per-result-slot register convention
/// (result[0]→X0/W0, result[1]→X1/W1). Each `r_i: u64` holds the
/// i32 result zero-extended to 64 bits (matching the W-form
/// zero-extension that the JIT epilogue's `MOV Wi, Wj` produces).
/// Future same-width 2× int FuncRet_* structs follow this
/// convention. Mixed int+float multi-result remains D-137 scope
/// (FP results route through V/XMM registers, not the GPR pair).
pub const FuncRet_i32i32 = extern struct {
    r0: u64,
    r1: u64,
};

/// Multi-result return for `(i32, i32, i32)`. Class C MEMORY-class
/// per ADR-0069 §Phase 2 + AAPCS64 §6.8.2 / SysV §3.2.3 — struct
/// > 16 B (3 × 8 = 24 B) routes via the indirect-result-pointer
/// hidden first-arg (X8 on arm64; R11 on x86_64 per ADR-0026
/// 2026-05-18 amend zwasm-internal convention). Each field u64-
/// padded per the Class A convention; zwasm JIT writes i32→W0..W2
/// (arm64) / EAX/ECX/EDX-via-buffer (x86_64) zero-extended.
pub const FuncRet_i32i32i32 = extern struct {
    r0: u64,
    r1: u64,
    r2: u64,
};

/// Multi-result return for `(i32, i32, i64)`. Class C MEMORY-class.
/// Same 24 B u64-padded layout as `FuncRet_i32i32i32`; the JIT
/// epilogue writes i32→W-form (low 32 of slot 0/1) + i64→full 8 B
/// (slot 2). Spec corpus: `break-multi-value` family in block /
/// loop / if (also (i32) → (i32,i32,i64) variant in if.wast).
pub const FuncRet_i32i32i64 = extern struct {
    r0: u64,
    r1: u64,
    r2: u64,
};

/// Multi-result return for `(i32, f64)`. Class B mixed int+float
/// per ADR-0069.
///
/// Layout chosen to MATCH JIT epilogue + SysV per-eightbyte ABI:
/// `r0: u64` (i32 zero-ext) in eightbyte 0 → RAX (SysV INTEGER
/// class) / X0 (AAPCS64 first GPR-pair slot). `r1: f64` in
/// eightbyte 1 → XMM0 (SysV SSE class) / X1 (AAPCS64 second
/// GPR-pair slot — but JIT writes D0, not X1, so AAPCS64 needs
/// the inline-asm thunk in `callI32f64NoArgs`).
pub const FuncRet_i32f64 = extern struct {
    r0: u64,
    r1: f64,
};

/// Multi-result return for `(f64, i32)`. Class B mixed.
///
/// Mirror of `FuncRet_i32f64` with order swapped. SysV per-
/// eightbyte: eightbyte 0 = f64 (SSE → XMM0); eightbyte 1 = i32
/// (INTEGER → RAX — first INTEGER eightbyte per the per-class
/// register pool rule). JIT writes f64→XMM0 (n_fp=0) + i32→RAX
/// (n_gpr=0). MATCH on SysV. AAPCS64 same shape needs inline-
/// asm thunk because AAPCS64 routes the whole non-HFA composite
/// through X0+X1 GPR pair, expecting eightbyte-0 (= f64 bits)
/// in X0 and eightbyte-1 (= i32) in X1 — but JIT writes f64→D0
/// + i32→X0 sequentially per class.
pub const FuncRet_f64i32 = extern struct {
    r0: f64,
    r1: u64, // i32 zero-ext; u64 ensures 16-byte total + AAPCS64 X0/X1 layout
};

/// Multi-result return for `(f64, f32)`. Class B heterogeneous-FP
/// per ADR-0069 D-146.
///
/// SysV: eightbyte 0 = f64 → SSE → XMM0; eightbyte 1 = f32 → SSE
/// → XMM1. Zig 0.16's `splitType` cannot yet generate the
/// call-site disassembly for two SSE eightbytes of different
/// widths, so `callF64f32NoArgs` uses an inline-asm thunk and
/// the FuncRet struct just carries the bit-packed result.
///
/// AAPCS64: not HFA (different element types), so routes to X0+
/// X1 GPR pair. JIT writes f64→D0 + f32→S1 (FP-class slots), so
/// X0/X1 read garbage. Inline-asm thunk captures D0 + S1 via
/// FMOV.
///
/// Layout note: no explicit u32 pad after r1. The earlier cycle
/// added `_pad0: u32 = 0` to force 16-byte total for AAPCS64
/// routing, but that gave eightbyte 1 `{f32 (SSE), u32 (INTEGER)}`
/// — SysV post-merge rule "SSE + INTEGER → INTEGER" then routed
/// eightbyte 1 to RDX, while JIT writes f32 to XMM1. With the
/// pad dropped, Zig's implicit alignment pad has NO_CLASS so
/// eightbyte 1 stays pure SSE → XMM1 (irrelevant for the
/// inline-asm thunk, which captures XMM1 directly, but matches
/// the natural SysV classification).
pub const FuncRet_f64f32 = extern struct {
    r0: f64,
    r1: f32,
};

/// Multi-result return for `(f64, f64)`. Spec `type-f64-f64-value`.
///
/// Homogeneous Floating-point Aggregate (HFA): per AAPCS64 §6.8.2
/// a 2-element HFA<double> returns via the V0+V1 register pair
/// (each lane in its own V/D register). SysV similarly routes
/// each double to XMM0 / XMM1 sequentially. This matches the
/// JIT epilogue's FP-class-indexed convention naturally —
/// result[0]→V0/XMM0, result[1]→V1/XMM1 — so no padding trick
/// is required.
pub const FuncRet_f64f64 = extern struct {
    r0: f64,
    r1: f64,
};

/// Call a `(i64, i64, i32) -> (i64, i32)` JIT function. Used by the
/// spec_assert non-simd runner to invoke the `add64_u_with_carry`
/// family (spec `if.wast` / `func.wast` / etc.). Multi-result ABI
/// per `FuncRet_i64i32`.
pub fn callI64i32_i64i64i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: u64,
    a2: u32,
) Error!FuncRet_i64i32 {
    if (builtin.os.tag == .windows) {
        const args = [_]u64{ a0, a1, @as(u64, a2) };
        const r = try entry_buffer_write.invokeBufWin64Args(rt, module, func_idx, &args, 2);
        return .{ .r0 = r[0], .r1 = @intCast(r[1] & 0xFFFFFFFF) };
    }
    const Fn = *const fn (*const JitRuntime, u64, u64, u32) callconv(.c) FuncRet_i64i32;
    return invokeAndCheck(rt, FuncRet_i64i32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

/// `() -> (i32, i64)` family — value-block-i32-i64 etc.
pub fn callI32i64NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!FuncRet_i32i64 {
    if (builtin.os.tag == .windows) {
        const r = try entry_buffer_write.invokeBufWin64NoArgs(rt, module, func_idx, 2);
        return .{ .r0 = @intCast(r[0] & 0xFFFFFFFF), .r1 = r[1] };
    }
    const Fn = *const fn (*const JitRuntime) callconv(.c) FuncRet_i32i64;
    return invokeAndCheck(rt, FuncRet_i32i64, module.entry(func_idx, Fn), .{});
}

/// `() -> (i64, i32)` family — call_indirect `type-all-i32-i64` shape.
pub fn callI64i32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!FuncRet_i64i32 {
    if (builtin.os.tag == .windows) {
        const r = try entry_buffer_write.invokeBufWin64NoArgs(rt, module, func_idx, 2);
        return .{ .r0 = r[0], .r1 = @intCast(r[1] & 0xFFFFFFFF) };
    }
    const Fn = *const fn (*const JitRuntime) callconv(.c) FuncRet_i64i32;
    return invokeAndCheck(rt, FuncRet_i64i32, module.entry(func_idx, Fn), .{});
}

/// `() -> (i32, i32)` — Win64: 16-B aggregate is MEMORY-class; route via wrapper-thunk like callI32i32i32NoArgs.
pub fn callI32i32NoArgs(module: linker.JitModule, func_idx: u32, rt: *JitRuntime) Error!FuncRet_i32i32 {
    if (builtin.os.tag == .windows) {
        const r = try entry_buffer_write.invokeBufWin64NoArgs(rt, module, func_idx, 2);
        return .{ .r0 = r[0], .r1 = r[1] };
    }
    const Fn = *const fn (*const JitRuntime) callconv(.c) FuncRet_i32i32;
    return invokeAndCheck(rt, FuncRet_i32i32, module.entry(func_idx, Fn), .{});
}

/// `() -> (i32, i32, i32)` — Class C MEMORY-class per ADR-0069.
/// SysV / AAPCS64: native `callconv(.c)` MEMORY-class via X8
/// (arm64) / RDI hidden-arg (SysV). Win64: wrapper-thunk path.
pub fn callI32i32i32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!FuncRet_i32i32i32 {
    if (builtin.os.tag == .windows) {
        const r = try entry_buffer_write.invokeBufWin64NoArgs(rt, module, func_idx, 3);
        return .{ .r0 = r[0], .r1 = r[1], .r2 = r[2] };
    }
    const Fn = *const fn (*const JitRuntime) callconv(.c) FuncRet_i32i32i32;
    return invokeAndCheck(rt, FuncRet_i32i32i32, module.entry(func_idx, Fn), .{});
}

/// `() -> (i32, i32, i64)` — Class C MEMORY-class per ADR-0069
/// §Phase 2. Spec corpus: `break-multi-value` in block.wast +
/// loop.wast.
///
/// Layout + ABI identical to `callI32i32i32NoArgs`; only the third
/// result's width differs (W-form vs X-form on arm64; 32 vs 64
/// bits of buffer slot 2 on x86_64). Per the u64-padded
/// `FuncRet_i32i32i64` layout, each slot is 8 B regardless.
pub fn callI32i32i64NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!FuncRet_i32i32i64 {
    const Fn = *const fn (*const JitRuntime) callconv(.c) FuncRet_i32i32i64;
    return invokeAndCheck(rt, FuncRet_i32i32i64, module.entry(func_idx, Fn), .{});
}

/// `(i32) -> (i32, i32, i64)` — Class C MEMORY-class with one
/// user arg. Spec corpus: `break-multi-value` in if.wast (two
/// fixture occurrences).
///
/// Per ADR-0026 2026-05-18 Convention Swap, native `callconv(.c)`
/// places `&buffer` in RDI, `rt` in RSI, `a0` in RDX on x86_64
/// SysV — matching the JIT-emitted callee's param marshal start
/// at slot 2. arm64 places `rt` in X0, `a0` in X1, `&buffer` in
/// X8 — independent slot, no shift.
pub fn callI32i32i64_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!FuncRet_i32i32i64 {
    if (builtin.os.tag == .windows) {
        const args = [_]u64{@as(u64, a0)};
        const r = try entry_buffer_write.invokeBufWin64Args(rt, module, func_idx, &args, 3);
        return .{ .r0 = r[0], .r1 = r[1], .r2 = r[2] };
    }
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) FuncRet_i32i32i64;
    return invokeAndCheck(rt, FuncRet_i32i32i64, module.entry(func_idx, Fn), .{a0});
}

/// Multi-result return for `func.wast::large-sig`: 16 results in
/// declaration order `(f64, f32, i32, i32, i32, i64, f32, i32, i32,
/// f32, f64, f64, i32, f32, i32, f64)`. Class C MEMORY-class per
/// ADR-0069 §Phase 3 (128 B > 16 B threshold on both arches).
///
/// Layout: 16 × u64 slots matching the JIT's 8-byte-per-slot stride.
/// f64 slots receive a full 8-byte STR Dn / MOV [RAX+disp]; f32 slots
/// receive a 4-byte STR Sn / MOV [RAX+disp] (upper 4 bytes of slot
/// remain uninitialised — read via `@truncate(r_i)` then `@bitCast`).
/// i32 slots are zero-extended to 8 bytes via X-form STR / 8-byte
/// MOV; i64 slots use the natural 8-byte store.
pub const FuncRet_largesig = extern struct {
    r0: u64,
    r1: u64,
    r2: u64,
    r3: u64,
    r4: u64,
    r5: u64,
    r6: u64,
    r7: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

/// Call `func.wast::large-sig` — 17 params + 16 results. Class C
/// MEMORY-class. Native `callconv(.c)` per ADR-0026 2026-05-18
/// Convention Swap places &buffer in RDI / X8 and rt in RSI / X0;
/// the JIT-emitted callee's prologue captures the buffer ptr and
/// the epilogue writes each result slot via the standard MEMORY-
/// class path. No inline-asm thunk needed.
pub fn callLargesig(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u64,
    a2: f32,
    a3: f32,
    a4: u32,
    a5: f64,
    a6: f32,
    a7: u32,
    a8: u32,
    a9: u32,
    a10: f32,
    a11: f64,
    a12: f64,
    a13: f64,
    a14: u32,
    a15: u32,
    a16: f32,
) Error!FuncRet_largesig {
    const Fn = *const fn (
        *const JitRuntime,
        u32,
        u64,
        f32,
        f32,
        u32,
        f64,
        f32,
        u32,
        u32,
        u32,
        f32,
        f64,
        f64,
        f64,
        u32,
        u32,
        f32,
    ) callconv(.c) FuncRet_largesig;
    return invokeAndCheck(rt, FuncRet_largesig, module.entry(func_idx, Fn), .{
        a0,  a1,  a2,  a3,  a4,
        a5,  a6,  a7,  a8,  a9,
        a10, a11, a12, a13, a14,
        a15, a16,
    });
}

/// `(i32) -> (i32, i32)` — if.wast `multi`, etc.
pub fn callI32i32_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!FuncRet_i32i32 {
    if (builtin.os.tag == .windows) {
        const args = [_]u64{@as(u64, a0)};
        const r = try entry_buffer_write.invokeBufWin64Args(rt, module, func_idx, &args, 2);
        return .{ .r0 = r[0], .r1 = r[1] };
    }
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) FuncRet_i32i32;
    return invokeAndCheck(rt, FuncRet_i32i32, module.entry(func_idx, Fn), .{a0});
}

/// `(i32) -> (i32, i64)` — break-br_if-num-num / break-br_table-num-num.
/// Uses `FuncRet_i32i64` (16-byte struct, X0+X1 register pair).
pub fn callI32i64_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!FuncRet_i32i64 {
    if (builtin.os.tag == .windows) {
        const args = [_]u64{@as(u64, a0)};
        const r = try entry_buffer_write.invokeBufWin64Args(rt, module, func_idx, &args, 2);
        return .{ .r0 = @intCast(r[0] & 0xFFFFFFFF), .r1 = r[1] };
    }
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) FuncRet_i32i64;
    return invokeAndCheck(rt, FuncRet_i32i64, module.entry(func_idx, Fn), .{a0});
}

/// `() -> (i32, f64)` — Class B mixed int+float per ADR-0069.
///
/// On x86_64 SysV: native `extern struct { u64, f64 }` C-ABI
/// return matches the JIT's RAX+XMM0 sequential per-class write
/// (eightbyte 0 = INTEGER → RAX; eightbyte 1 = SSE → XMM0).
///
/// On AAPCS64 (arm64): non-HFA composite ≤ 16 B routes through
/// the X0+X1 GPR pair (eightbyte 0 → X0; eightbyte 1 → X1).
/// JIT writes i32→X0 + f64→D0 sequentially per class — X0
/// matches but X1 reads garbage. Inline-asm thunk pre-loads
/// X0=rt, does BLR, captures X0 (i32) + D0 (f64 bits via
/// FMOV) into the return struct.
///
/// Win64 (D-161): inline-asm thunk passes rt in RCX (Win64 first
/// int arg), allocates 32-byte shadow space + 8-byte alignment
/// pad, CALLs the function pointer, and captures RAX (i32) +
/// XMM0 (f64) directly — bypassing the MS x64 C ABI's hidden-RCX
/// return-pointer convention for > 8-byte composites, which
/// doesn't match the JIT body's per-class register write.
pub fn callI32f64NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!FuncRet_i32f64 {
    rt.trap_flag = 0;
    if (comptime builtin.target.cpu.arch == .aarch64) {
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
        const f = module.entry(func_idx, Fn);
        var r0_raw: u64 = undefined;
        var r1_raw: u64 = undefined;
        asm volatile (
            \\ stp x19, x20, [sp, #-80]!
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ mov x0, x10
            \\ blr %[callee]
            \\ mov x11, x0
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x19, x20, [sp], #80
            \\ fmov x12, d0
            : [r0_out] "={x11}" (r0_raw),
              [r1_bits] "={x12}" (r1_raw),
              // x0 is not an operand of this asm.
              //
              // It used to be both: an input `"{x0}"` carrying the runtime and an
              // output `"={x0}"` reading a result. The two are untied, so the
              // allocator may materialise the output's def before the input's use —
              // and under optimisation it did, leaving `blr` to enter the JIT body
              // with x0 holding whatever the output slot had been given rather than
              // the runtime. The fault address was a small constant: a field offset
              // read off that garbage. Debug allocated differently and never showed
              // it.
              //
              // The runtime now arrives in x10 and is placed in x0 by the asm itself;
              // results come back through x11/x12/x13. Every operand is pinned to a
              // named register — `"r"` was free to pick x0, or to pick the register a
              // neighbouring line had just written.
              //
              // Those registers are also in the clobber list. That overlap is the
              // tolerance the note at the head of this file already records; it is not
              // the reason this is correct.
            : [callee] "{x9}" (f),
              [rt_arg] "{x10}" (rt),
            : aarch64_blr_clobbers);
        if (rt.trap_flag != 0) return Error.Trap;
        return .{ .r0 = r0_raw, .r1 = @bitCast(r1_raw) };
    } else if (comptime builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag != .windows) {
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) FuncRet_i32f64;
        const f = module.entry(func_idx, Fn);
        const result = f(rt);
        if (rt.trap_flag != 0) return Error.Trap;
        return result;
    } else if (comptime builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .windows) {
        // Win64 (D-161): rt in RCX, 32 B shadow + 8 B alignment via
        // `sub $40`, CALL, capture RAX (i32) + XMM0 (f64).
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
        const f = module.entry(func_idx, Fn);
        var r0_raw: u64 = undefined;
        var r1_raw: f64 = undefined;
        asm volatile (
            \\ subq $40, %rsp
            \\ callq *%[callee]
            \\ addq $40, %rsp
            : [r0_out] "={rax}" (r0_raw),
              [r1_out] "={xmm0}" (r1_raw),
            : [callee] "r" (f),
              [rt_arg] "{rcx}" (rt),
            : x86_64_win64_call_clobbers);
        if (rt.trap_flag != 0) return Error.Trap;
        return .{ .r0 = r0_raw, .r1 = r1_raw };
    }
}

/// `() -> (f64, i32)` — Class B mixed (FP-first ordering) per
/// ADR-0069.
///
/// On x86_64 SysV: native `extern struct { f64, u64 }` C-ABI
/// matches JIT's XMM0 (eightbyte 0 SSE) + RAX (eightbyte 1
/// INTEGER, going to first INTEGER reg in the per-class pool).
///
/// On AAPCS64: as with `(i32, f64)`, JIT's sequential per-
/// class assignment puts f64→D0 + i32→X0, while AAPCS64's
/// GPR-pair expects eightbyte 0 (= f64 bits) in X0 and
/// eightbyte 1 (= i32) in X1. Inline-asm thunk captures both.
pub fn callF64i32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!FuncRet_f64i32 {
    rt.trap_flag = 0;
    if (comptime builtin.target.cpu.arch == .aarch64) {
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
        const f = module.entry(func_idx, Fn);
        var r0_raw: u64 = undefined;
        var r1_raw: u64 = undefined;
        asm volatile (
            \\ stp x19, x20, [sp, #-80]!
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ mov x0, x10
            \\ blr %[callee]
            \\ mov x11, x0
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x19, x20, [sp], #80
            \\ fmov x12, d0
            : [r0_bits] "={x12}" (r0_raw),
              [r1_out] "={x11}" (r1_raw),
              // x0 is not an operand of this asm.
              //
              // It used to be both: an input `"{x0}"` carrying the runtime and an
              // output `"={x0}"` reading a result. The two are untied, so the
              // allocator may materialise the output's def before the input's use —
              // and under optimisation it did, leaving `blr` to enter the JIT body
              // with x0 holding whatever the output slot had been given rather than
              // the runtime. The fault address was a small constant: a field offset
              // read off that garbage. Debug allocated differently and never showed
              // it.
              //
              // The runtime now arrives in x10 and is placed in x0 by the asm itself;
              // results come back through x11/x12/x13. Every operand is pinned to a
              // named register — `"r"` was free to pick x0, or to pick the register a
              // neighbouring line had just written.
              //
              // Those registers are also in the clobber list. That overlap is the
              // tolerance the note at the head of this file already records; it is not
              // the reason this is correct.
            : [callee] "{x9}" (f),
              [rt_arg] "{x10}" (rt),
            : aarch64_blr_clobbers);
        if (rt.trap_flag != 0) return Error.Trap;
        return .{ .r0 = @bitCast(r0_raw), .r1 = r1_raw };
    } else if (comptime builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag != .windows) {
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) FuncRet_f64i32;
        const f = module.entry(func_idx, Fn);
        const result = f(rt);
        if (rt.trap_flag != 0) return Error.Trap;
        return result;
    } else if (comptime builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .windows) {
        // Win64 (D-161): same shadow-space pattern as
        // `callI32f64NoArgs`; capture XMM0 (f64) + RAX (i32).
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
        const f = module.entry(func_idx, Fn);
        var r0_raw: f64 = undefined;
        var r1_raw: u64 = undefined;
        asm volatile (
            \\ subq $40, %rsp
            \\ callq *%[callee]
            \\ addq $40, %rsp
            : [r0_out] "={xmm0}" (r0_raw),
              [r1_out] "={rax}" (r1_raw),
            : [callee] "r" (f),
              [rt_arg] "{rcx}" (rt),
            : x86_64_win64_call_clobbers);
        if (rt.trap_flag != 0) return Error.Trap;
        return .{ .r0 = r0_raw, .r1 = r1_raw };
    }
}

/// `() -> (f64, f32)` — Class B heterogeneous-FP per ADR-0069
/// D-146.
///
/// On AAPCS64: not HFA (different element types) so routes to
/// X0+X1 GPR pair; JIT writes f64→D0 + f32→S1 in FP-class slots.
/// Inline-asm thunk performs the BLR and captures D0 + S1 via
/// FMOV — same shape as `callI32f64NoArgs` / `callF64i32NoArgs`.
///
/// On x86_64 SysV: both eightbytes are SSE class but of
/// different widths. Zig 0.16 cannot yet code-gen the call-site
/// disassembly (`error: TODO implement splitType(2,
/// FuncRet_f64f32)`), so the helper uses an inline-asm thunk
/// that performs `callq *fn` with rdi=rt and captures XMM0
/// (f64) + XMM1 (f32) directly.
///
/// Win64 (D-161): same inline-asm thunk shape as `callI32f64NoArgs`,
/// passing rt in RCX with 32-byte shadow space, and capturing
/// XMM0 (f64) + XMM1 (f32) directly. The MS x64 C ABI cannot
/// natively express a `{f64, f32}` return that lands in XMM0+XMM1.
pub fn callF64f32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!FuncRet_f64f32 {
    rt.trap_flag = 0;
    if (comptime builtin.target.cpu.arch == .aarch64) {
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
        const f = module.entry(func_idx, Fn);
        var r0_raw: u64 = undefined;
        var r1_raw: u64 = undefined;
        asm volatile (
            \\ stp x19, x20, [sp, #-80]!
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ mov x0, x10
            \\ blr %[callee]
            \\ fmov x12, d0
            \\ fmov x13, d1
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x19, x20, [sp], #80
            : [r0_bits] "={x12}" (r0_raw),
              [r1_bits] "={x13}" (r1_raw),
              // x0 is not an operand of this asm.
              //
              // It used to be both: an input `"{x0}"` carrying the runtime and an
              // output `"={x0}"` reading a result. The two are untied, so the
              // allocator may materialise the output's def before the input's use —
              // and under optimisation it did, leaving `blr` to enter the JIT body
              // with x0 holding whatever the output slot had been given rather than
              // the runtime. The fault address was a small constant: a field offset
              // read off that garbage. Debug allocated differently and never showed
              // it.
              //
              // The runtime now arrives in x10 and is placed in x0 by the asm itself;
              // results come back through x11/x12/x13. Every operand is pinned to a
              // named register — `"r"` was free to pick x0, or to pick the register a
              // neighbouring line had just written.
              //
              // Those registers are also in the clobber list. That overlap is the
              // tolerance the note at the head of this file already records; it is not
              // the reason this is correct.
            : [callee] "{x9}" (f),
              [rt_arg] "{x10}" (rt),
            : aarch64_blr_clobbers);
        if (rt.trap_flag != 0) return Error.Trap;
        const r1_f32: f32 = @bitCast(@as(u32, @truncate(r1_raw)));
        return .{ .r0 = @bitCast(r0_raw), .r1 = r1_f32 };
    } else if (comptime builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag != .windows) {
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
        const f = module.entry(func_idx, Fn);
        var r0_raw: f64 = undefined;
        var r1_raw: f32 = undefined;
        asm volatile (
            \\ callq *%[callee]
            : [r0_out] "={xmm0}" (r0_raw),
              [r1_out] "={xmm1}" (r1_raw),
            : [callee] "r" (f),
              [rt_arg] "{rdi}" (rt),
            : x86_64_sysv_call_clobbers);
        if (rt.trap_flag != 0) return Error.Trap;
        return .{ .r0 = r0_raw, .r1 = r1_raw };
    } else if (comptime builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag == .windows) {
        // Win64 (D-161): same shadow-space pattern as the other
        // Class B Win64 thunks; capture XMM0 (f64) + XMM1 (f32).
        const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
        const f = module.entry(func_idx, Fn);
        var r0_raw: f64 = undefined;
        var r1_raw: f32 = undefined;
        asm volatile (
            \\ subq $40, %rsp
            \\ callq *%[callee]
            \\ addq $40, %rsp
            : [r0_out] "={xmm0}" (r0_raw),
              [r1_out] "={xmm1}" (r1_raw),
            : [callee] "r" (f),
              [rt_arg] "{rcx}" (rt),
            : x86_64_win64_call_clobbers);
        if (rt.trap_flag != 0) return Error.Trap;
        return .{ .r0 = r0_raw, .r1 = r1_raw };
    }
}

/// `() -> (f64, f64)` — HFA on POSIX, Win64 uses 2-XMM wrapper.
pub fn callF64f64NoArgs(module: linker.JitModule, func_idx: u32, rt: *JitRuntime) Error!FuncRet_f64f64 {
    if (builtin.os.tag == .windows) {
        const r = try entry_buffer_write.invokeBufWin64NoArgs(rt, module, func_idx, 2);
        return .{ .r0 = @bitCast(r[0]), .r1 = @bitCast(r[1]) };
    }
    const Fn = *const fn (*const JitRuntime) callconv(.c) FuncRet_f64f64;
    return invokeAndCheck(rt, FuncRet_f64f64, module.entry(func_idx, Fn), .{});
}

pub fn callF32_f32f32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
    a2: f32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f32, f32, f32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

pub fn callF32_f32f32f32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
    a2: f32,
    a3: f32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f32, f32, f32, f32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1, a2, a3 });
}

pub fn callF32_f32f32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
    a2: u32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f32, f32, u32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

pub fn callF32_f32f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f64,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f32, f64) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1 });
}

pub fn callF32_f64f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, f64, f32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1 });
}

pub fn callF64_f64f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
    a2: f64,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, f64, f64, f64) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

pub fn callF64_f64f64f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
    a2: f64,
    a3: f64,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, f64, f64, f64, f64) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1, a2, a3 });
}

pub fn callF64_f64f64i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
    a2: u32,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, f64, f64, u32) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

// Residual `runner-shape-gap` shapes.
// Same AAPCS64/SysV calling-
// convention pattern; result + arg classes are scalar (no
// reftype / v128).

pub fn callF32_i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, u32, u32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1 });
}

/// `(i32, f32) -> f32` — spec-corpus 2-arg JIT dispatch (D-217).
pub fn callF32_i32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: f32,
) Error!f32 {
    const Fn = *const fn (*const JitRuntime, u32, f32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ a0, a1 });
}

pub fn callF64_i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
) Error!f64 {
    const Fn = *const fn (*const JitRuntime, u32, u32) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1 });
}

pub fn callI32_f32f32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
    a2: f32,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, f32, f32, f32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

pub fn callI32_f64f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
    a2: f64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, f64, f64, f64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

pub fn callI32_i32f64i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: f64,
    a2: u32,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u32, f64, u32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

pub fn callF64_f64f64f64f64f64f64f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
    a2: f64,
    a3: f64,
    a4: f64,
    a5: f64,
    a6: f64,
    a7: f64,
) Error!f64 {
    const Fn = *const fn (
        *const JitRuntime,
        f64,
        f64,
        f64,
        f64,
        f64,
        f64,
        f64,
        f64,
    ) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1, a2, a3, a4, a5, a6, a7 });
}

pub fn callF64_f32i32i64i32f64i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: u32,
    a2: u64,
    a3: u32,
    a4: f64,
    a5: u32,
) Error!f64 {
    const Fn = *const fn (
        *const JitRuntime,
        f32,
        u32,
        u64,
        u32,
        f64,
        u32,
    ) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ a0, a1, a2, a3, a4, a5 });
}

// Reftype-aliased dispatch shapes
// for the table_grow / table_fill family. Reftype args/results
// alias onto the i64 GPR-class scalar path per ADR-0061
// codegen plumbing, so the helpers below carry plain `u64`
// signatures rather than a separate reftype variant.

pub fn callI32_i32i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u64,
) Error!u32 {
    const Fn = *const fn (*const JitRuntime, u32, u64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ a0, a1 });
}

pub fn callI64_i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
) Error!u64 {
    const Fn = *const fn (*const JitRuntime, u32, u32) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ a0, a1 });
}

pub fn callVoid_i32i64i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u64,
    a2: u32,
) Error!void {
    const Fn = *const fn (*const JitRuntime, u32, u64, u32) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, a1, a2 });
}

/// Wasm spec §4.4 (function invocation, v128 result) — call a no-
/// argument JIT function returning v128. Per ADR-0046, both backends
/// emit the v128 result through the SIMD return register (ARM64 V0,
/// x86_64 XMM0). `@Vector(16, u8)` lowers to that register on both
/// AAPCS64 and SysV; we then bit-cast to a flat byte array so callers
/// (notably `simd_assert_runner`) can compare against manifest hex
/// tokens directly.
///
/// Used by the spec-assertion-driver to invoke `()→v128`
/// fixtures (simd_address / simd_align / simd_const). v128 PARAM
/// marshal is a separate follow-up.
pub fn callV128NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{});
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i32) → v128` invocation. The i32 arg follows
/// the established W1 / ESI ABI (per `callI32_i32`); the v128 result
/// uses the SIMD return register (per `callV128NoArgs`).
pub fn callV128_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{a0});
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i64) → v128` invocation (D-467, i64x2.splat). The i64 arg
/// follows the X1 / RSI GPR ABI; the v128 result uses the SIMD return register.
pub fn callV128_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{a0});
    return @bitCast(result);
}
/// Wasm spec §4.4 — `(f32) → v128` (D-467, f32x4.splat). f32 arg in V0/XMM0; v128 result in the SIMD return reg.
pub fn callV128_f32(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: f32) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, f32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{a0});
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(f64) → v128` (D-467, f64x2.splat). f64 arg in V0/XMM0; v128 result in the SIMD return reg.
pub fn callV128_f64(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: f64) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, f64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{a0});
    return @bitCast(result);
}

// D-467 multi-scalar → v128 constructor shapes. Used by simd_splat
// `as-i8x16_add_sub-operands` / `as-i32x4_add_sub_mul-operands` /
// `as-f32x4_eq-operands` etc. — exports that take N scalar lanes (all
// of one type) and build a v128. Each scalar follows its register
// class (GPR i32/i64 in X1.. / RSI.. ; FP f32/f64 in V0.. / XMM0..)
// per AAPCS64 + SysV ordering; Zig's `callconv(.c)` does the
// assignment. v128 result in the SIMD return register.

/// Wasm spec §4.4 — `(i32, i32) → v128` invocation (D-467).
pub fn callV128_i32i32(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: u32, a1: u32) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u32, u32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i32, i32, i32) → v128` invocation (D-467).
pub fn callV128_i32i32i32(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: u32, a1: u32, a2: u32) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u32, u32, u32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1, a2 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i32, i32, i32, i32) → v128` invocation (D-467).
pub fn callV128_i32i32i32i32(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: u32, a1: u32, a2: u32, a3: u32) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u32, u32, u32, u32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1, a2, a3 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i64, i64) → v128` invocation (D-467).
pub fn callV128_i64i64(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: u64, a1: u64) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u64, u64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i64, i64, i64, i64) → v128` invocation (D-467).
pub fn callV128_i64i64i64i64(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: u64, a1: u64, a2: u64, a3: u64) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u64, u64, u64, u64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1, a2, a3 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(f32, f32) → v128` invocation (D-467).
pub fn callV128_f32f32(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: f32, a1: f32) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, f32, f32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(f64, f64) → v128` invocation (D-467).
pub fn callV128_f64f64(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: f64, a1: f64) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, f64, f64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(f64, f64, f64, f64) → v128` invocation (D-467).
pub fn callV128_f64f64f64f64(module: linker.JitModule, func_idx: u32, rt: *JitRuntime, a0: f64, a1: f64, a2: f64, a3: f64) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, f64, f64, f64, f64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, a1, a2, a3 });
    return @bitCast(result);
}

// D-467 single-scalar → scalar shapes (simd_splat extract-lane
// operand fixtures) reuse the existing scalar↔scalar helpers
// `callI64_i64` / `callI32_i64` / `callF32_f32` / `callF64_f64`.

/// Wasm spec §4.4 — `(v128) → v128` invocation. Enables
/// FP / int unop fixtures
/// (simd_f32x4_arith neg / sqrt, simd_i32x4_arith neg / abs,
/// etc.). a0 lowers to V0/XMM0; result also V0/XMM0.
pub fn callV128_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{@as(Vec, @bitCast(a0))});
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128) → ()` invocation.
/// (D-079 (i) discharge): enables single-v128-param setter
/// fixtures (simd_const `as-global.set_value_$g0` etc.). a0
/// lowers to V0/XMM0; no result. Per ADR-0046's PARAM marshal
/// shape, identical to `callV128_v128` minus the return.
pub fn callVoid_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!void {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{@as(Vec, @bitCast(a0))});
}

/// Wasm spec §4.4 — `(v128, v128) → ()` invocation.
/// (D-079 (i) discharge): two-v128-param setter fixtures
/// (simd_const `as-global.set_value_$g1_$g2` etc.).
pub fn callVoid_v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
) Error!void {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)) });
}

/// Wasm spec §4.4 — `(v128, v128, v128, v128) → ()` invocation.
/// (D-079 (i) discharge): four-v128-param setter
/// fixtures (simd_const `as-global.set_value_$g0_$g1_$g2_$g3`).
/// Per AAPCS64 / SysV ABI: a0..a3 lower to V0..V3 (ARM64) /
/// XMM0..XMM3 (x86_64); RDI/X0 stays the runtime ptr.
pub fn callVoid_v128v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
    a3: [16]u8,
) Error!void {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec, Vec, Vec) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)), @as(Vec, @bitCast(a2)), @as(Vec, @bitCast(a3)) });
}

/// Wasm spec §4.4 — `(v128, v128) → v128` invocation. Enables
/// FP arith / int arith / bitwise binop
/// fixtures (simd_bitwise, simd_f32x4_arith, simd_i32x4_arith,
/// etc.). Per ADR-0046 v128 PARAM marshal: a0 lowers
/// to V0/XMM0, a1 to V1/XMM1; result is V0/XMM0.
pub fn callV128_v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)) });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, v128, v128) → v128` invocation.
/// (D-070 unblock): enables bitselect / select
/// corpus assertions that take 3 v128 inputs and produce a v128
/// result. a0 → V0/XMM0, a1 → V1/XMM1, a2 → V2/XMM2; result is
/// V0/XMM0. AAPCS64 / SysV register pool covers ≤ 8 v128 args
/// (V0..V7 / XMM0..XMM7).
pub fn callV128_v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec, Vec) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)), @as(Vec, @bitCast(a2)) });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128) → i32` invocation.
/// (v128-param-pending discharge): enables i*x*.all_true /
/// any_true / bitmask / i*x*.extract_lane.{s,u} fixtures whose
/// `(args, results)` is `((v128,), (i32,))`. a0 lowers to
/// V0/XMM0; the i32 result returns in W0/EAX per AAPCS64 / SysV.
pub fn callI32_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!u32 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{@as(Vec, @bitCast(a0))});
}

/// Wasm spec §4.4 — `(v128) → f32` invocation.
/// (v128-param-pending discharge): enables f32x4.extract_lane
/// fixtures whose `(args, results)` is `((v128,), (f32,))`. a0
/// lowers to V0/XMM0; the f32 result returns in S0/XMM0 per
/// AAPCS64 / SysV.
pub fn callF32_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!f32 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{@as(Vec, @bitCast(a0))});
}

/// Wasm spec §4.4 — `(v128) → f64` invocation.
/// (v128-param-pending discharge): enables f64x2.extract_lane
/// fixtures whose `(args, results)` is `((v128,), (f64,))`. a0
/// lowers to V0/XMM0; the f64 result returns in D0/XMM0 per
/// AAPCS64 / SysV.
pub fn callF64_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!f64 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{@as(Vec, @bitCast(a0))});
}

/// Wasm spec §4.4 — `(v128, i32) → v128` invocation.
/// (v128-param-pending discharge): enables i*x*.shl /
/// shr_s / shr_u (shift count = i32) AND i*x*.replace_lane
/// (replacement value = i32, lane index baked into the opcode).
/// Per AAPCS64 / SysV: a0 → V0/XMM0 (vector arg goes to the
/// first FP/vector register), a1 → W1/ESI (i32 arg goes to the
/// first GPR after `rt`); result returns in V0/XMM0.
pub fn callV128_v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, f32) → v128` invocation.
/// (v128-param-pending discharge): enables
/// f32x4.replace_lane fixtures (replacement value = f32, lane
/// index baked into the opcode). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → V1/XMM1 (both FP/vector args use the FP
/// register file in declaration order); result returns in
/// V0/XMM0.
pub fn callV128_v128f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f32,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, f32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, f64) → v128` invocation.
/// (v128-param-pending discharge): enables
/// f64x2.replace_lane fixtures (replacement value = f64, lane
/// index baked into the opcode). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → V1/XMM1; result returns in V0/XMM0.
pub fn callV128_v128f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f64,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, f64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128) → i64` invocation.
/// (v128-param-pending residual discharge): enables
/// `i64x2.extract_lane` fixtures (lane index baked into the
/// opcode immediate; one v128 input, one i64 result). Per
/// AAPCS64 / SysV: a0 lowers to V0/XMM0 (the FP/vector arg
/// register), result returns in X0/RAX (the first GPR).
pub fn callI64_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!u64 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{@as(Vec, @bitCast(a0))});
}

/// Wasm spec §4.4 — `(v128, i64) → v128` invocation.
/// (v128-param-pending residual discharge): enables
/// `i64x2.replace_lane` (replacement value = i64, lane index
/// baked into the opcode). Per AAPCS64 / SysV: a0 → V0/XMM0
/// (the FP/vector arg register); a1 → X1/RSI (the first GPR
/// after `rt`); result returns in V0/XMM0.
pub fn callV128_v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, v128) → i32` invocation.
/// (v128-param-pending residual discharge): enables
/// composite-body fixtures whose Wasm function takes two v128
/// inputs, performs a bitwise op (`and` / `or` / `xor`) between
/// them, and reduces via `i*x*.{all,any}_true` → i32
/// (`simd_boolean` `*_with_v128.{and,or,xor}` /
/// `*_as_i32.*_operand` exports). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → V1/XMM1; result returns in W0/EAX.
pub fn callI32_v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
) Error!u32 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)) });
}

/// Wasm spec §4.4 — `(v128, v128, i32) → v128` invocation.
/// (v128-param-pending residual discharge): enables
/// `select_v128_i32` (Wasm `select` with explicit v128 operands
/// and an i32 selector — `simd_select.wast` `select_v128`).
/// Signature: `v128 v1, v128 v2, i32 cond → v128`. Per
/// AAPCS64 / SysV: a0 → V0/XMM0, a1 → V1/XMM1, a2 → W1/ESI
/// (the first GPR after `rt`); result returns in V0/XMM0.
pub fn callV128_v128v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: u32,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec, u32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)), a2 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, v128, v128) → i32` invocation.
/// (v128-param-pending residual discharge): enables the
/// composite `*_with_v128.bitselect` exports from `simd_boolean`
/// whose body is `(any_true|all_true)(bitselect(v0, v1, v2))` and
/// reduces to i32. Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → V1/XMM1,
/// a2 → V2/XMM2; result returns in W0/EAX.
pub fn callI32_v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
) Error!u32 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec, Vec) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)), @as(Vec, @bitCast(a2)) });
}

/// Wasm spec §4.4 — `(v128, i32) → i32` invocation.
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite exports `i*x*_replace_lane-{s,u}` (replace lane then
/// extract back as i32) and `as-i*x*_any_true-operand` (any_true
/// on `v128 op v128(splat i32 arg)`). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → W1/ESI (first GPR after `rt`); result returns
/// in W0/EAX.
pub fn callI32_v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
) Error!u32 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u32) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
}

/// Wasm spec §4.4 — `(v128, i64) → i32` invocation.
/// (v128-param-pending residual discharge): enables `simd_lane`
/// `as-i32x4_any_true-operand2` whose body takes `(v128, i64)` and
/// returns i32 via `i32x4.any_true ((v128 op v128(splat i64)))`.
/// Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → X1/RSI; result returns
/// in W0/EAX.
pub fn callI32_v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
) Error!u32 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u64) callconv(.c) u32;
    return invokeAndCheck(rt, u32, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
}

/// Wasm spec §4.4 — `(v128, i64) → i64` invocation.
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite `i64x2_replace_lane` (replace lane with i64 arg, then
/// `i64x2.extract_lane` it back). Per AAPCS64 / SysV: a0 → V0/XMM0,
/// a1 → X1/RSI; result returns in X0/RAX.
pub fn callI64_v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
) Error!u64 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u64) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
}

/// Wasm spec §4.4 — `(v128, f32) → f32` invocation.
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite `f32x4_replace_lane` (replace lane with f32 arg then
/// extract back). Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → V1/XMM1
/// (both vector / FP args use the FP register file in declaration
/// order); result returns in S0/XMM0.
pub fn callF32_v128f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f32,
) Error!f32 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, f32) callconv(.c) f32;
    return invokeAndCheck(rt, f32, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
}

/// Wasm spec §4.4 — `(v128, f64) → f64` invocation.
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite `f64x2_replace_lane`. Per AAPCS64 / SysV: a0 → V0/XMM0,
/// a1 → V1/XMM1; result returns in D0/XMM0.
pub fn callF64_v128f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f64,
) Error!f64 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, f64) callconv(.c) f64;
    return invokeAndCheck(rt, f64, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1 });
}

/// Wasm spec §4.4 — `(v128, v128, v128, v128) → v128` invocation.
/// (v128-param-pending residual discharge): enables
/// `simd_lane` `swizzle-as-i8x16_add-operands` /
/// `shuffle-as-i8x16_sub-operands` which take 4 v128 inputs and
/// produce a v128 result. Per AAPCS64 / SysV the V0..V7 / XMM0..XMM7
/// FP register pool covers ≤ 8 v128 args; a0..a3 → V0..V3 /
/// XMM0..XMM3; result returns in V0/XMM0.
pub fn callV128_v128v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
    a3: [16]u8,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, Vec, Vec, Vec) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), @as(Vec, @bitCast(a1)), @as(Vec, @bitCast(a2)), @as(Vec, @bitCast(a3)) });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, i32, v128) → v128` invocation.
/// (v128-param-pending residual discharge): enables
/// `simd_lane` `as-v8x16_swizzle-operand` (swizzle takes (v128, v128)
/// but the export wraps it with an i32 arg in the middle threading
/// the lane index). Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → W1/ESI
/// (first GPR after `rt`), a2 → V1/XMM1 (next vector slot); result
/// returns in V0/XMM0.
pub fn callV128_v128i32v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
    a2: [16]u8,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u32, Vec) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1, @as(Vec, @bitCast(a2)) });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, i32, v128, i32) → v128` invocation.
/// (v128-param-pending residual discharge): enables
/// `simd_lane` `as-v8x16_shuffle-operands` /
/// `as-i*x*_add-operands` (4-arg composite that interleaves two
/// (v128, i32) `replace_lane` pairs into a single `add`). Per
/// AAPCS64 / SysV: a0 → V0/XMM0, a1 → W1/ESI, a2 → V1/XMM1, a3 →
/// W2/EDX; result returns in V0/XMM0.
pub fn callV128_v128i32v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
    a2: [16]u8,
    a3: u32,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u32, Vec, u32) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1, @as(Vec, @bitCast(a2)), a3 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, i64, v128, i64) → v128` invocation.
/// (v128-param-pending residual discharge): enables
/// `simd_lane` `as-i64x2_add-operands` (i64-typed sibling of
/// `as-i32x4_add-operands`; two `(v128, i64)` `replace_lane` pairs
/// composed into `i64x2.add`). Per AAPCS64 / SysV: a0 → V0/XMM0,
/// a1 → X1/RSI, a2 → V1/XMM1, a3 → X2/RDX; result returns in
/// V0/XMM0.
pub fn callV128_v128i64v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
    a2: [16]u8,
    a3: u64,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, Vec, u64, Vec, u64) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ @as(Vec, @bitCast(a0)), a1, @as(Vec, @bitCast(a2)), a3 });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i32, v128) → ()` invocation.
/// (v128-param-pending residual discharge): enables `simd_align`
/// `v128.store align=N` fixtures (store address + v128 value, void
/// return). Per AAPCS64 / SysV: a0 → W1/ESI (i32 address), a1 →
/// V0/XMM0 (v128 value uses first FP slot); no result. The GPR /
/// FP register pools are independent so the i32 arg doesn't push
/// the v128 down the FP pool.
pub fn callVoid_i32v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: [16]u8,
) Error!void {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u32, Vec) callconv(.c) void;
    return invokeAndCheckVoid(rt, module.entry(func_idx, Fn), .{ a0, @as(Vec, @bitCast(a1)) });
}

/// Wasm spec §4.4 — `(i32, v128) → v128` invocation (D-467,
/// `v128.load{8,16,32,64}_lane`). The export takes an i32 address +
/// a v128 source, loads N bits from linear memory into the addressed
/// lane, and returns the merged v128. Per AAPCS64 / SysV: a0 →
/// W1/ESI (i32 address), a1 → V0/XMM0 (v128); independent GPR / FP
/// pools. Result v128 in V0/XMM0. Active data segments are
/// materialized into linear memory by the runner before invoke.
pub fn callV128_i32v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: [16]u8,
) Error![16]u8 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u32, Vec) callconv(.c) Vec;
    const result = try invokeAndCheck(rt, Vec, module.entry(func_idx, Fn), .{ a0, @as(Vec, @bitCast(a1)) });
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i32, v128) → i64` invocation (D-467,
/// `v128.store{8,16,32,64}_lane` test exports). The export stores the
/// addressed lane to linear memory then reads back an i64 from the
/// same address and returns it (the spec fixture's read-back probe).
/// ABI mirrors `callV128_i32v128`; result i64 in X0/RAX.
pub fn callI64_i32v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: [16]u8,
) Error!u64 {
    const Vec = @Vector(16, u8);
    const Fn = *const fn (*const JitRuntime, u32, Vec) callconv(.c) u64;
    return invokeAndCheck(rt, u64, module.entry(func_idx, Fn), .{ a0, @as(Vec, @bitCast(a1)) });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const skip = @import("../../../test_support/skip.zig");
const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const regalloc = @import("regalloc.zig");
// Comptime per-arch emit dispatch (matches linker.zig:30). Lets the
// execution tests below run on mac-arm64 + linux-x86_64 instead of
// being arm64-pinned (D-193 / D-180-hazard discharge).
const emit = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arm64/emit.zig"),
    .x86_64 => @import("../x86_64/emit.zig"),
    else => @compileError("entry.zig tests: unsupported arch"),
};

test "entry: i32.load offset=0 reads memory[0..4] through X28 vm_base" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    // (i32.const 0) (i32.load offset=0) end
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    // Stage 16 bytes; the Wasm body reads memory[0..4] little-endian.
    var memory: [16]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 0xEFBEADDE), result);
}

test "entry: ADR-0018 sub-1c — spilled i32.const returns 42 via STR/LDR round-trip" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // Force vreg 0 into spill territory (slot 10). The JIT body's
    // prologue extends frame by 8 + 16-align = 16 bytes; i32.const
    // emits MOVZ X14,#42 + STR X14,[SP]; end emits LDR X14,[SP] +
    // MOV X0,X14. Calling via the entry-frame returns 42.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{10};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots_gpr = 10,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 42), result);
}

test "entry: ADR-0027 — global.set 0 then global.get 0 (i32) round-trips through JitRuntime.globals_base" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const Value = @import("../../../runtime/value.zig").Value;
    // (i32.const 7) (global.set 0) (global.get 0) end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"global.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // const → set
            .{ .def_pc = 2, .last_use_pc = 3 }, // get → end
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};
    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);
    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    // Pre-populate globals[0] with a sentinel so we can prove the
    // global.set actually overwrites it (rather than the function
    // happening to return the initial value).
    var globals = [_]Value{ Value.fromI32(0xDEAD), Value.fromI32(0xBEEF) };
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = &globals,
        .globals_count = globals.len,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 7), result);
    // global slot 0 was actually overwritten by `global.set 0 (=7)`.
    try testing.expectEqual(@as(i32, 7), globals[0].i32);
    // global slot 1 untouched.
    try testing.expectEqual(@as(i32, 0xBEEF), globals[1].i32);
}

test "entry: pure constant function returns 42 (sanity — no memory access)" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 42), result);
}

test "entry: callI32_i32i32 — 2 i32 params summed via i32.add" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (param i32 i32) (result i32) — body: local.get 0; local.get 1; i32.add; end
    const sig: zir.FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(u32, 7), try callI32_i32i32(module, 0, &rt, 3, 4));
    try testing.expectEqual(@as(u32, 0), try callI32_i32i32(module, 0, &rt, 0, 0));
}

test "entry: callI32_i32 — 1 i32 param echoed through W1 → SP slot 0 → result" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const sig: zir.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(u32, 0xCAFEBABE), try callI32_i32(module, 0, &rt, 0xCAFEBABE));
    try testing.expectEqual(@as(u32, 42), try callI32_i32(module, 0, &rt, 42));
}

test "entry: f32 local round-trip — local.get 0 of f32 param via V0" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (param f32) (result f32) — body: local.get 0; end
    // The prologue STR S0, [SP, #0] (multi-arg-entry FP path);
    // local.get 0 must LDR S<vd>, [SP, #0] (D-NNN FP-local fix);
    // end MOVs into V0 / S0 for return.
    const sig: zir.FuncType = .{ .params = &.{.f32}, .results = &.{.f32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32) callconv(.c) f32;
    const f = module.entry(0, Fn);
    // D-311: route through the cohort-clobber trampoline (NOT a raw `f(&rt,…)`).
    try testing.expectEqual(@as(f32, 3.5), try callEntrySafe(&rt, f32, f, .{@as(f32, 3.5)}));
    try testing.expectEqual(@as(f32, -1.25), try callEntrySafe(&rt, f32, f, .{@as(f32, -1.25)}));
}

test "entry: callI64NoArgs — i64.const 0xDEADBEEFCAFE returns full 64-bit" {
    // D-193 triage: ungated. Body checks result value only (no
    // arch-pinned byte asserts) and emits via comptime native_emit,
    // so mac-arm64 + linux-x86_64 both exercise it. Win deferred per
    // ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (result i64) — body: i64.const 0xDEADBEEFCAFE; end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    // i64.const 0xDEADBEEFCAFE → low32 = 0xBEEFCAFE, high32 = 0xDEAD.
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xBEEFCAFE, .extra = 0xDEAD });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFE), try callI64NoArgs(module, 0, &rt));
}

test "entry: ref.as_non_null traps on null funcref source" {
    // ADR-0123 D2: closes the spike_discipline §2 gap from
    // the scaffolding commit (`86e5bfaf`). Exercises the new
    // arm64 + x86_64 ref.as_non_null emit handler end-to-end through
    // JIT.
    //
    // Body: (func (result i32) ref.null funcref ; ref.as_non_null ;
    //        ref.is_null ; end)
    // - ref.null pushes the null sentinel (0).
    // - ref.as_non_null compares to 0 and traps (B.EQ/JE → generic
    //   bounds_fixups trap stub → trap_flag=1 → Error.Trap per
    //   entry.zig invokeAndCheck).
    // - ref.is_null + end are unreached on the null path; the
    //   function signature still type-checks ((result i32) satisfied
    //   by ref.is_null's i32 even if execution traps).
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    // arm64/emit.zig:789 / x86_64 emit ignore ref.null's payload —
    // both unconditionally emit MOVZ Xd, #0 / XOR Rd, Rd. payload=0
    // is a safe default for a JIT-execution test that bypasses parse.
    try fn0.instrs.append(testing.allocator, .{ .op = .@"ref.null", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"ref.as_non_null" });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"ref.is_null" });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    // Identity-passthrough liveness: ref.as_non_null does NOT allocate
    // a new result vreg (it pushes its src vreg back unchanged per
    // ref_as_non_null.zig emit). So vreg 0 = ref.null result + lives
    // until ref.is_null at pc 2 consumes it; vreg 1 = ref.is_null
    // result + lives to end at pc 3. They overlap at pc 2 → two
    // distinct physical slots.
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    // ref.as_non_null traps on null → callI32NoArgs returns Error.Trap.
    try testing.expectError(Error.Trap, callI32NoArgs(module, 0, &rt));
    // And trap_flag was set by the trap stub.
    try testing.expect(rt.trap_flag != 0);
}

test "entry: br_on_null branches to block end on null funcref" {
    // ADR-0123 D2: closes the spike_discipline §2 gap from
    // the scaffolding commit (`1b0fc917`). End-to-end exercises
    // the arm64 br_on_null emit handler.
    //
    // Body: (func (result i32)
    //         (block
    //           (ref.null funcref)
    //           (br_on_null 0)   ; null → branch to block end (always taken)
    //           (drop))          ; fall-through path (unreached at runtime; validator OK)
    //         (i32.const 7))
    // Expected: callI32NoArgs returns 7 — branch around the drop, block
    // end (arity 0, empty stack), then i32.const 7 + func end → 7.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // D-194 discharged — x86_64 br_on_null per-op file landed
    // via Path B (`captureOrEmitBlockMergeMovCtx` ctx-shape wrapper in
    // `x86_64/op_control.zig`); test now runs on both Mac aarch64 +
    // Linux x86_64.

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .block });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"ref.null", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .br_on_null, .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .drop });
    try fn0.instrs.append(testing.allocator, .{ .op = .end }); // closes block
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end }); // closes func
    fn0.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 1, .last_use_pc = 3 }, // vreg 0: ref.null result → drop
            .{ .def_pc = 5, .last_use_pc = 6 }, // vreg 1: i32.const 7 → func end
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};
    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(u32, 7), try callI32NoArgs(module, 0, &rt));
}

test "entry: br_on_non_null falls through on null funcref param" {
    // ADR-0123 D2: closes the spike_discipline §2 gap from
    // the scaffolding commit (`f30d08a7`). End-to-end exercises
    // the arm64 br_on_non_null emit handler.
    //
    // Body: (func (param funcref) (result i32)
    //         (block (result funcref)
    //           (local.get 0)
    //           (br_on_non_null 0)   ; non-null → branch with funcref
    //           (ref.null funcref))  ; null fall-through pushes null
    //         (ref.is_null))
    //
    // Called with funcref = 0 (null): br_on_non_null does NOT branch;
    // fall through pushes ref.null; block result = null; ref.is_null
    // returns 1. callI32_i64(0) → 1.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // D-194 discharged — see br_on_null sibling above.

    const sig: zir.FuncType = .{ .params = &.{.funcref}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .br_on_non_null, .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"ref.null", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end }); // closes block
    try fn0.instrs.append(testing.allocator, .{ .op = .@"ref.is_null" });
    try fn0.instrs.append(testing.allocator, .{ .op = .end }); // closes func
    // Liveness: 3 vregs total across both paths. vreg 0 (local.get
    // result) lives until ref.is_null on branch-taken (worst case);
    // vreg 1 (ref.null result) lives until ref.is_null on fall-through;
    // vreg 2 (ref.is_null result) lives until func end. Conservative
    // distinct-slot allocation (n_slots=3) avoids merge-slot subtleties.
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 5 },
        .{ .def_pc = 3, .last_use_pc = 5 },
        .{ .def_pc = 5, .last_use_pc = 6 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const sigs = [_]zir.FuncType{sig};
    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    // funcref = 0 (null) → null path: br_on_non_null does NOT branch;
    // ref.null pushed; block result = null; ref.is_null returns 1.
    try testing.expectEqual(@as(u32, 1), try callI32_i64(module, 0, &rt, 0));
}

test "entry: br_on_cast matches i31 → branch carries the ref → i31.get_s = 7" {
    // GC-on-JIT: end-to-end exercises the br_on_cast emit
    // handler (cast via jitGcRefTest + conditional branch via the shared
    // branchOnReg). The ref is an i31, the target is i31 → match → branch
    // to the block end carrying the (narrowed) i31ref → i31.get_s → 7.
    //
    // Body: (func (result i32)
    //         (block (result (ref i31))
    //           i32.const 7  ref.i31         ; i31ref(7)
    //           (br_on_cast 0 (ref null any)(ref i31)))  ; match → branch
    //         i31.get_s)                       ; → 7
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    // extra packs {flags, ht1, ht2}: flags bit0 = ht1(any) nullable = 1;
    // ht1 = any (0x6E); ht2 = i31 (0x6C), non-null. = 0x6C6E01.
    const br_extra: u32 = 0x01 | (@as(u32, 0x6E) << 8) | (@as(u32, 0x6C) << 16);
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"ref.i31" });
    try fn0.instrs.append(testing.allocator, .{ .op = .br_on_cast, .payload = 0, .extra = br_extra });
    try fn0.instrs.append(testing.allocator, .{ .op = .end }); // closes block
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i31.get_s" });
    try fn0.instrs.append(testing.allocator, .{ .op = .end }); // closes func
    // vreg0 i32.const 7 → ref.i31; vreg1 i31ref spans br_on_cast's CALL (pc3)
    // and is consumed by i31.get_s (pc5) — it MUST be spill-homed: it lives
    // across the `jitGcRefTest` CALL, which clobbers every caller-saved pool
    // register (X9..X13). A register slot (0..max_reg_slots_gpr-1) would put
    // the i31ref in X10 and the CALL would trash it → i31.get_s reads garbage
    // and traps. Slot id == max_reg_slots_gpr (10) parks it in the spill frame
    // (offset 0), where the value survives the CALL via STR/LDR. vreg0 / vreg2
    // stay in register slots 0 / 1. (Mirrors the "spilled i32.const" test's
    // force-spill shape above.)
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 5 },
        .{ .def_pc = 5, .last_use_pc = 6 },
    } };
    const slots = [_]u16{ 0, 10, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 11, .max_reg_slots_gpr = 10 };
    const sigs = [_]zir.FuncType{sig};
    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(u32, 7), try callI32NoArgs(module, 0, &rt));
}
