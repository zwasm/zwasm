//! Buffer-write entry ABI (ADR-0106 path (a)).
//!
//! Sibling to `entry.zig`'s ~84 per-shape `callXX_yy` helpers.
//! ADR-0106 path (a) collapses that catalog to ONE entry-helper
//! shape:
//!
//! ```text
//!   fn(*JitRuntime, [*]u64 results, [*]const u64 args)
//!     callconv(.c) ErrCode
//! ```
//!
//! Where `args` is a caller-prepared `u64` array (one slot per
//! Wasm param, regardless of valtype — i32 / f32 fit in the low
//! 32 bits, f64 / i64 in the full 64, funcref/externref pointers
//! in the full 64), and `results` is a caller-allocated buffer
//! sized by the function's `sig.results.len`. `ErrCode` is the
//! trap-status return (0 = OK, non-0 = trap kind). The JIT body's
//! epilogue writes each result to `results[i]` instead of the
//! per-arch register-pair (RAX/RDX or X0/X1).
//!
//! Why this shape (per ADR-0106 §"Path (a) — buffer-write entry ABI"):
//!
//! - **Cross-platform uniformity**: the single `u64` ErrCode
//!   return sidesteps Win64's hidden-RCX-pointer struct-return ABI
//!   (the D-164 root cause). All 3 hosts use the same shape.
//! - **Wasm 3.0 ready**: GC reftypes / EH tag-pack / memory64
//!   ptr64 results all fit in the existing `u64` slots — no new
//!   shape catalog per Wasm proposal.
//! - **Closes D-094 + D-164 together**: the buffer-write
//!   convention absorbs SysV's `> 2 same-class results` case
//!   without needing the hidden-RDI MEMORY-class path.
//!
//! The JIT epilogue (x86_64 + arm64) writes `results[i]` instead
//! of RAX/RDX / X0/X1, replacing the per-shape `FuncRet_*` extern
//! struct family.
//!
//! Zone 2 (`src/engine/codegen/shared/`) — same as `entry.zig`.

const std = @import("std");
const builtin = @import("builtin");

const jit_abi = @import("jit_abi.zig");
const stack_limit_mod = @import("../../../platform/stack_limit.zig");
const entry = @import("entry.zig");

pub const JitRuntime = jit_abi.JitRuntime;

/// Trap-status return code from a buffer-write JIT entry.
/// Mirrors the on-`JitRuntime.trap_kind` codes so the caller can
/// disambiguate without a separate fetch (the JIT body still
/// writes `trap_kind` to `rt.trap_kind` for diagnostic purposes;
/// the C-ABI scalar return here is a redundant fast path).
pub const ErrCode = u32;
pub const ErrCode_OK: ErrCode = 0;

pub const Error = error{Trap};

/// Buffer-write entry function-pointer type. Wasm 1.0 / 2.0 / 3.0
/// uniform — every JIT-compiled function (under path (a)) lowers
/// to this signature regardless of arity / result types.
pub const BufferWriteFn = *const fn (
    rt: *JitRuntime,
    results: [*]u64,
    args: [*]const u64,
) callconv(.c) ErrCode;

/// Invoke a buffer-write-shape JIT function. The caller owns
/// `args` (Wasm-param values packed as u64) and `results` (sized
/// by the function's `sig.results.len`). On success the buffer
/// contains the result values; on trap `Error.Trap` is returned
/// and the buffer contents are undefined.
///
/// Mirrors `entry.invokeAndCheck`'s pre/post discipline:
///   - Initialise `stack_limit` (ADR-0105 D1) so the prologue
///     probe activates.
///   - Clear `trap_flag` before the call.
///   - Check `trap_flag` after the call; `Error.Trap` on non-0.
///   - The ErrCode return is a redundant trap signal — if either
///     ErrCode != 0 OR trap_flag != 0 the call is treated as trap.
pub fn invokeBufferWrite(
    rt: *JitRuntime,
    fn_ptr: BufferWriteFn,
    args: [*]const u64,
    results: [*]u64,
) Error!void {
    rt.stack_limit = stack_limit_mod.computeStackLimit(stack_limit_mod.STACK_GUARD_HEADROOM);
    rt.trap_flag = 0;
    rt.trap_kind = 0;
    // D-311 / D-245: route through the non-inline cohort-clobber trampoline so
    // the host's callee-saved registers (RBX/R12-R15 · X19-X28) are saved &
    // restored around the JIT call. The native_emit'd body MOV-installs that
    // pinned cohort from `rt` WITHOUT stack-saving the caller's values, so a
    // plain `fn_ptr(...)` call loses any live value ReleaseSafe's optimized host
    // kept there → undefined-memory read / SEGV. The register/void entry paths
    // already do this (`entry.invokeAndCheck`); the buffer-write path had not.
    const code = @call(.never_inline, jitTrampolineBuf, .{ fn_ptr, rt, results, args });
    if (code != ErrCode_OK or rt.trap_flag != 0) return Error.Trap;
}

/// D-311 — buffer-write sibling of `entry.jitTrampoline`. Non-inline (a real
/// prologue/epilogue) so the trailing `asm` clobber forces THIS frame to
/// preserve the JIT-clobbered callee-saved cohort across the call.
fn jitTrampolineBuf(f: BufferWriteFn, rt: *JitRuntime, results: [*]u64, args: [*]const u64) ErrCode {
    const code = f(rt, results, args);
    asm volatile ("" ::: entry.jit_cohort_clobbers);
    return code;
}

/// ADR-0106 — Win64 routing helper for
/// 0-arg multi-result entry helpers; caller extracts u64 slots
/// into FuncRet struct. Forward-declared `linker.JitModule` use is
/// fine because both modules are in the same Zone 2 cohort.
pub fn invokeBufWin64NoArgs(
    rt: *JitRuntime,
    module: @import("linker.zig").JitModule,
    func_idx: u32,
    comptime n_results: usize,
) Error![n_results]u64 {
    const buf_fn = module.entry_buf(func_idx, BufferWriteFn);
    var args_buf: [1]u64 = .{0};
    var results_buf: [n_results]u64 = [_]u64{0} ** n_results;
    try invokeBufferWrite(rt, buf_fn, &args_buf, &results_buf);
    return results_buf;
}

/// ADR-0106 — Win64 routing helper for
/// 1+-arg multi-result entry helpers (D-167 wire-up). Mirrors
/// `invokeBufWin64NoArgs` but threads caller-supplied args through
/// the buffer-write ABI's `args: [*]const u64` channel.
///
/// Caller packs arg values into a `[]const u64` (each Value slot
/// 8 bytes; i32 args zero-extend, f32 args occupy low 32 bits per
/// the buffer-write ABI convention). The Win64 wrapper-thunk
/// (`wrapper_thunk.zig::emitX8664Win64` 1-arg+2-int /
/// 3-arg+2-int / 1-arg+3-int-MEM shapes, cycles 21-28) reads via
/// `[R8]` / `[R8+8]` / `[R8+16]` and routes into body-side
/// register-write (1+2int) or MEMORY-class (1+3int) convention.
pub fn invokeBufWin64Args(
    rt: *JitRuntime,
    module: @import("linker.zig").JitModule,
    func_idx: u32,
    args: []const u64,
    comptime n_results: usize,
) Error![n_results]u64 {
    const buf_fn = module.entry_buf(func_idx, BufferWriteFn);
    var results_buf: [n_results]u64 = [_]u64{0} ** n_results;
    try invokeBufferWrite(rt, buf_fn, args.ptr, &results_buf);
    return results_buf;
}

// ============================================================
// Tests — hand-rolled JIT bytes that match the buffer-write ABI
// without depending on the JIT emit changes (cycles 2-3).
// ============================================================

const testing = std.testing;
const skip = @import("../../../test_support/skip.zig");

/// Hand-rolled arm64 JIT bytes: writes `results[0] = 42`, returns 0.
///
/// AAPCS64 mapping: X0=rt, X1=results, X2=args. Body:
///   MOVZ X3, #42        ; 0xD2800543 → 0x43 0x05 0x80 0xD2
///   STR  X3, [X1]       ; 0xF9000023 → 0x23 0x00 0x00 0xF9
///   MOV  W0, WZR        ; 0x2A1F03E0 → 0xE0 0x03 0x1F 0x2A
///   RET                 ; 0xD65F03C0 → 0xC0 0x03 0x5F 0xD6
const aarch64_results0_eq_42: [16]u8 = .{
    0x43, 0x05, 0x80, 0xD2,
    0x23, 0x00, 0x00, 0xF9,
    0xE0, 0x03, 0x1F, 0x2A,
    0xC0, 0x03, 0x5F, 0xD6,
};

/// Hand-rolled x86_64 SysV/Win64 JIT bytes: same semantics.
///
/// Win64: rt=RCX results=RDX args=R8. SysV: rt=RDI results=RSI args=RDX.
/// We pick a register-agnostic sequence by re-loading via the SysV slot
/// because the unit test compiles to native host ABI; the test runs
/// on Mac aarch64 primarily so this body is gated by os/cpu.
const x86_64_sysv_results0_eq_42: [16]u8 = .{
    // MOV RAX, 42            -> 48 C7 C0 2A 00 00 00
    0x48, 0xC7, 0xC0, 0x2A, 0x00, 0x00, 0x00,
    // MOV [RSI], RAX         -> 48 89 06
    0x48, 0x89, 0x06,
    // XOR EAX, EAX           -> 31 C0
    0x31, 0xC0,
    // RET                    -> C3
    0xC3,
    // pad to 16
    0x90,
    0x90, 0x90,
};

test "buffer-write entry: hand-rolled JIT writes results[0] = 42 (ADR-0106 path (a) API check)" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const bytes: [16]u8 = if (builtin.cpu.arch == .aarch64)
        aarch64_results0_eq_42
    else
        x86_64_sysv_results0_eq_42;

    const jit_mem = @import("../../../platform/jit_mem.zig");
    var block = try jit_mem.alloc(bytes.len);
    defer jit_mem.free(block);
    try jit_mem.setWritable(block);
    @memcpy(block.bytes[0..bytes.len], &bytes);
    try jit_mem.setExecutable(block);

    const fn_ptr: BufferWriteFn = @ptrCast(block.bytes.ptr);

    var rt: JitRuntime = .{
        .vm_base = undefined,
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
    var args_buf: [1]u64 = .{0};
    var results_buf: [1]u64 = .{0};
    try invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u64, 42), results_buf[0]);
}

/// Typed-result wrapper around `invokeBufferWrite` for the
/// spec runner's multi-result dispatch (a later pass will swap the
/// per-shape `callI32i32i32NoArgs` callsites in
/// `spec_assert_runner_non_simd.zig` to this helper when on
/// Win64). The helper packs 0 args (no-args overload — the only
/// shape currently hitting the SKIP-WIN64-MULTI-RESULT arm) and
/// unpacks each `[*]u64` result slot into the caller's typed
/// out-param array.
///
/// The caller must compile the JIT module with
/// `alloc.result_abi = .buffer_write`. The fn_ptr extracted via
/// `module.entry(idx, BufferWriteFn)` is shape-correct only
/// under that compilation; reusing this against a `.register_write`-
/// compiled module produces undefined behaviour.
///
/// Per-result type tag picks how to unpack each `u64` slot:
/// `.i32` / `.f32` masks low 32 bits; `.i64` / `.f64` /
/// `.funcref` / `.externref` reads the full 64 bits.
pub const ResultKind = enum { i32, i64, f32, f64, funcref, externref };

pub const TypedResult = union(ResultKind) {
    i32: u32,
    i64: u64,
    f32: u32,
    f64: u64,
    funcref: u64,
    externref: u64,
};

pub fn invokeMultiResultNoArgs(
    rt: *JitRuntime,
    fn_ptr: BufferWriteFn,
    results: []TypedResult,
) Error!void {
    if (results.len > 16) return Error.Trap;
    var args_buf: [1]u64 = .{0};
    var u64_buf: [16]u64 = undefined;
    try invokeBufferWrite(rt, fn_ptr, &args_buf, &u64_buf);
    for (results, 0..) |*r, i| {
        const slot = u64_buf[i];
        r.* = switch (r.*) {
            .i32 => .{ .i32 = @intCast(slot & 0xFFFFFFFF) },
            .i64 => .{ .i64 = slot },
            .f32 => .{ .f32 = @intCast(slot & 0xFFFFFFFF) },
            .f64 => .{ .f64 = slot },
            .funcref => .{ .funcref = slot },
            .externref => .{ .externref = slot },
        };
    }
}

test "buffer-write entry: invokeMultiResultNoArgs unpacks 3-i32 result (ADR-0106)" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 100 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 200 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 300 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
        .{ .def_pc = 1, .last_use_pc = 3 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 3,
        .result_abi = .buffer_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer native_emit.deinit(testing.allocator, out);
    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);
    const fn_ptr = module.entry(0, BufferWriteFn);
    var rt: JitRuntime = .{
        .vm_base = undefined,
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
    var results = [_]TypedResult{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 } };
    try invokeMultiResultNoArgs(&rt, fn_ptr, &results);
    try testing.expectEqual(@as(u32, 100), results[0].i32);
    try testing.expectEqual(@as(u32, 200), results[1].i32);
    try testing.expectEqual(@as(u32, 300), results[2].i32);
}

test "buffer-write entry: native-emit () → (i32, i64) shape (SKIP arm callI32i64NoArgs shape; ADR-0106)" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 2,
        .result_abi = .buffer_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer native_emit.deinit(testing.allocator, out);
    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);
    const fn_ptr = module.entry(0, BufferWriteFn);
    var rt: JitRuntime = .{
        .vm_base = undefined,
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
    var results = [_]TypedResult{ .{ .i32 = 0 }, .{ .i64 = 0 } };
    try invokeMultiResultNoArgs(&rt, fn_ptr, &results);
    try testing.expectEqual(@as(u32, 7), results[0].i32);
    try testing.expectEqual(@as(u64, 8), results[1].i64);
}

test "buffer-write entry: native-emit () → (i64, i32) shape (SKIP arm callI64i32NoArgs shape; ADR-0106)" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xABCDEF12 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xCAFE });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 2,
        .result_abi = .buffer_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer native_emit.deinit(testing.allocator, out);
    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);
    const fn_ptr = module.entry(0, BufferWriteFn);
    var rt: JitRuntime = .{
        .vm_base = undefined,
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
    var results = [_]TypedResult{ .{ .i64 = 0 }, .{ .i32 = 0 } };
    try invokeMultiResultNoArgs(&rt, fn_ptr, &results);
    try testing.expectEqual(@as(u64, 0xABCDEF12), results[0].i64);
    try testing.expectEqual(@as(u32, 0xCAFE), results[1].i32);
}

test "buffer-write entry: ErrCode_OK sentinel" {
    try testing.expectEqual(@as(ErrCode, 0), ErrCode_OK);
}

// ============================================================
// ADR-0106 — x86_64 emit drives the buffer-write epilogue
// when `alloc.result_abi == .buffer_write`. Test compiles a trivial
// `(i32.const 42) end` fn with the flag set + invokes via
// invokeBufferWrite. Linux x86_64 + Win64 ubuntu exercise the
// new emit path.
// ============================================================

const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const regalloc = @import("regalloc.zig");
const linker = @import("linker.zig");
const native_emit = if (builtin.cpu.arch == .aarch64)
    @import("../arm64/emit.zig")
else if (builtin.cpu.arch == .x86_64)
    @import("../x86_64/emit.zig")
else
    struct {};

test "buffer-write entry: native-emit () → (i32, i32, i32) multi-result via buffer (ADR-0106 / D-164 trigger shape)" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // Build ZirFunc: () -> (i32, i32, i32); body = i32.const 11; 22; 33; end.
    // 3 results trigger the D-164 SysV §3.2.3 > 2 GPR-class results path
    // — the case that motivated ADR-0106 path (a) buffer-write redesign.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 22 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 33 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
        .{ .def_pc = 1, .last_use_pc = 3 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 3,
        .result_abi = .buffer_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer native_emit.deinit(testing.allocator, out);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);
    const fn_ptr = module.entry(0, BufferWriteFn);
    var rt: JitRuntime = .{
        .vm_base = undefined,
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
    var args_buf: [1]u64 = .{0};
    var results_buf: [3]u64 = .{ 0, 0, 0 };
    try invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u64, 11), results_buf[0] & 0xFFFFFFFF);
    try testing.expectEqual(@as(u64, 22), results_buf[1] & 0xFFFFFFFF);
    try testing.expectEqual(@as(u64, 33), results_buf[2] & 0xFFFFFFFF);
}

test "buffer-write entry: native-emit (i32) → i32 identity via [args_ptr+0] (ADR-0106)" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // Build ZirFunc: (param i32) → i32; body = local.get 0; end.
    const sig: zir.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 1,
        .result_abi = .buffer_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer native_emit.deinit(testing.allocator, out);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);
    const fn_ptr = module.entry(0, BufferWriteFn);
    var rt: JitRuntime = .{
        .vm_base = undefined,
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
    // args[0] = 123 (i32 value packed into low 32 of u64).
    var args_buf: [1]u64 = .{123};
    var results_buf: [1]u64 = .{0};
    try invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u64, 123), results_buf[0] & 0xFFFFFFFF);
}

test "buffer-write entry: native-emit (i32.const 42) end → results[0] = 42 (ADR-0106)" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // Build the ZirFunc: () -> i32; body = i32.const 42; end.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 1,
        .result_abi = .buffer_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer native_emit.deinit(testing.allocator, out);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    const fn_ptr = module.entry(0, BufferWriteFn);
    var rt: JitRuntime = .{
        .vm_base = undefined,
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
    var args_buf: [1]u64 = .{0};
    var results_buf: [1]u64 = .{0};
    try invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u64, 42), results_buf[0]);
}
