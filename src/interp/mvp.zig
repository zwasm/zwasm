// FILE-SIZE-EXEMPT: impl-only after the P4 test extraction to mvp_tests.zig (sweep S1); control/call/EH handlers share the frame machinery — no impl seam without an N2 pub-leak (investigated 2026-08-12, per ADR-0099)
//! MVP interp handler shell (Phase 2 / §9.2 / 2.2).
//!
//! Per ROADMAP §4.5 / §A12, each handler is registered into the
//! central `DispatchTable.interp` via `register(*DispatchTable)`.
//! The dispatcher (`src/interp/dispatch.zig`) calls them with an
//! opaque `*InterpCtx` cast back to the concrete `*Runtime` from
//! `src/runtime/runtime.zig`.
//!
//! After §9.5 / 5.1 (ADR-0007 follow-on for `mvp.zig` discoverability)
//! the handler set is split across siblings:
//!
//! - `mvp_int.zig`         — i32 / i64 constants + numeric (unops,
//!                           binops, relops, testops)
//! - `mvp_float.zig`       — f32 / f64 constants + numeric
//! - `mvp_conversions.zig` — wrap / extend / trunc / convert /
//!                           promote / demote / reinterpret
//! - `memory_ops.zig`      — loads / stores / memory.size / .grow
//! - this file (residual)  — control flow (block / loop / if /
//!                           else / end / br / br_if / br_table /
//!                           call / call_indirect / return),
//!                           parametric (drop, select, select_typed),
//!                           variable (locals / globals),
//!                           unreachable / nop, plus the `register()`
//!                           shell that calls each split's `register()`
//!                           in sequence.
//!
//! Wraparound / NaN / trap semantics are documented at each split
//! module's header.
//!
//! Zone 2 (`src/interp/`) — feature-MVP handlers live alongside
//! the engine they wire into so the Zone-1 / Zone-2 boundary is
//! clean: `src/feature/mvp/mod.zig` (Zone 1) covers parser-side
//! handlers, this file + siblings (Zone 2) cover interp-side
//! handlers, and Phase-6+ `src/jit_*/mvp.zig` (Zone 2) will
//! mirror the pattern for JIT emitters.
//!
//! Imports Zone 0 (`util/`) + Zone 1 (`ir/`) + sibling Zone 2
//! (`mod.zig`, `dispatch.zig`, `memory_ops.zig`, `mvp_int.zig`,
//! `mvp_float.zig`, `mvp_conversions.zig`).

const std = @import("std");
const build_options = @import("build_options");

/// Wasm 3.0 subtype acceptance (§3.3.5.5) in `call_indirect` / `call_ref` is a
/// 3.0-only relaxation; sub-3.0 builds require exact `sigEq`. Gating the
/// `concreteReaches` arm behind this comptime const keeps the 3.0 symbol out of
/// `-Dwasm=v1_0|v2_0` binaries (ADR-0073 "absent from binary"; ADR-0129 leak fix).
const wasm_v3_plus = @backingInt(build_options.wasm_level) >=
    @backingInt(@TypeOf(build_options.wasm_level).v3_0);

const dispatch = @import("../ir/dispatch_table.zig");
const dbg = @import("../support/dbg.zig");
const call_profile = @import("../support/call_profile.zig");
const zir = @import("../ir/zir.zig");
const runtime = @import("../runtime/runtime.zig");
const memory_ops = @import("../instruction/wasm_1_0/memory.zig");
const ref_test_ops = @import("../instruction/wasm_3_0/ref_test_ops.zig");
const mvp_int = @import("../instruction/wasm_1_0/numeric_int.zig");
const mvp_float = @import("../instruction/wasm_1_0/numeric_float.zig");
const mvp_conversions = @import("../instruction/wasm_1_0/numeric_conversion.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = runtime.Runtime;
const Value = runtime.Value;
const Trap = runtime.Trap;

// ============================================================
// Public registration
// ============================================================

pub fn register(table: *DispatchTable) void {
    // Trap-only / no-op control
    table.interp[op(.@"unreachable")] = unreachableOp;
    table.interp[op(.nop)] = nopOp;
    // atomic.fence (threads, ADR-0168): no-op on the single-threaded
    // substrate (every atomic op is trivially seq-cst). Shares nopOp.
    table.interp[op(.@"atomic.fence")] = nopOp;
    table.interp[op(.select)] = selectOp;
    table.interp[op(.select_typed)] = selectOp;

    // Control flow
    table.interp[op(.block)] = blockOp;
    // Wasm 3.0 EH `try_table` shares `blockOp`'s label-push path
    // (the catch-vec lives on the side in `ZirFunc.eh_landing_pads`,
    // not in the Label itself); the `.try_table` BlockInfo kind
    // discriminates this label for `throwOp`'s unwind walk.
    table.interp[op(.try_table)] = blockOp;
    // Wasm 3.0 EH `throw` / `throw_ref` (§3.3.10.7-8). throwOp
    // walks the current frame's label stack to dispatch to a
    // matching catch in an enclosing `try_table`. throwRefOp is
    // still uncaught — exnref support lands at 10.E-N alongside
    // Module.tags wiring.
    table.interp[op(.throw)] = throwOp;
    table.interp[op(.throw_ref)] = throwRefOp;
    table.interp[op(.loop)] = loopOp;
    table.interp[op(.@"if")] = ifOp;
    table.interp[op(.@"else")] = elseOp;
    table.interp[op(.end)] = endOp;
    table.interp[op(.br)] = brOp;
    table.interp[op(.br_if)] = brIfOp;
    table.interp[op(.br_table)] = brTableOp;
    table.interp[op(.br_on_cast)] = brOnCastOp;
    table.interp[op(.br_on_cast_fail)] = brOnCastFailOp;
    table.interp[op(.@"return")] = returnOp;
    table.interp[op(.call)] = callOp;
    table.interp[op(.call_indirect)] = callIndirectOp;
    // Wasm 3.0 typed function references (function-references proposal).
    // Lives here (Zone 2) rather than in instruction/wasm_3_0/ (Zone 1)
    // because the handler invokes a callee body via `invoke()` + the
    // interp dispatch loop, both of which are Zone 2. The feature-level
    // gate in src/ir/feature_level_check.zig (`v3_op_tags` includes
    // `.call_ref`) prevents the lowering layer from emitting this op
    // when `wasm_3_0` is disabled — so unconditional registration here
    // is harmless on Wasm-2.0-only builds.
    table.interp[op(.call_ref)] = callRefOp;
    table.interp[op(.return_call_ref)] = returnCallRefOp;
    table.interp[op(.return_call)] = returnCallOp;
    table.interp[op(.return_call_indirect)] = returnCallIndirectOp;

    // Parametric
    table.interp[op(.drop)] = drop;

    // Locals + globals
    table.interp[op(.@"local.get")] = localGet;
    table.interp[op(.@"local.set")] = localSet;
    table.interp[op(.@"local.tee")] = localTee;
    table.interp[op(.@"global.get")] = globalGet;
    table.interp[op(.@"global.set")] = globalSet;

    // Numeric / conversions / loads-stores live in sibling modules.
    mvp_int.register(table);
    mvp_float.register(table);
    mvp_conversions.register(table);
    memory_ops.register(table);
}

inline fn op(t: ZirOp) usize {
    return @backingInt(t);
}

// ============================================================
// Handlers — control flow + parametric + variable
// ============================================================

fn unreachableOp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {
    return Trap.Unreachable;
}

fn nopOp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {
    // Wasm `nop` — intentionally empty.
}

fn selectOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const cond = rt.popOperand().i32;
    const b = rt.popOperand();
    const a = rt.popOperand();
    try rt.pushOperand(if (cond != 0) a else b);
}

// --- Control flow ---
//
// Block instr encoding (post §9.2 / 2.3 chunk 3):
//   payload = block index into func.blocks
//   extra   = arity (count of result values the block leaves on
//             the operand stack; 0/1 for Wasm 1.0, ≥1 for Wasm
//             2.0 multivalue typeidx blocks).

fn blockOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    // `instr.extra` packs (params << 8) | results for typeidx
    // blocktypes (per lower.zig readBlockArity — the high byte feeds
    // the JIT's end-of-block height calc). The interp's label arity is
    // the RESULT count (low byte); a param-carrying block (e.g.
    // try_table (param i32)) would otherwise set arity = 0x100 and trip
    // the max_block_arity guard. `height` excludes the params (they
    // belong INSIDE the block) so `restoreToLabel` truncates to the
    // correct base. block/try_table: br→end transfers results, so
    // branch_arity == arity == results.
    const results: u32 = instr.extra & 0xFF;
    const params: u32 = (instr.extra >> 8) & 0xFF;
    try frame.pushLabel(rt.alloc, .{
        .height = rt.operand_len - params,
        .arity = results,
        .branch_arity = results,
        .target_pc = blk.end_inst + 1,
        .block_idx = @intCast(instr.payload),
    });
}

fn loopOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    try frame.pushLabel(rt.alloc, .{
        .height = rt.operand_len,
        // `end` of a loop transfers the loop's result arity to the
        // operand stack (Wasm 2.0 multivalue: zero or more results).
        // §9.2 / 2.3 chunk 3b's missing piece — without this, falling
        // through a `loop (result T)` end drops the result and
        // unbalances the caller's stack (cf. tinygo_fib's
        // `loop (result i32)` recursion).
        .arity = instr.extra,
        // br to a loop targets the loop's start and transfers its
        // *params*. Wasm 1.0 has no loop-params; multivalue loop-
        // with-params lands alongside the rest of multivalue
        // (Phase 2 chunk 3b carry-over).
        .branch_arity = 0,
        // Branching to a loop pops the label (see doBranch) and jumps
        // back to the loop opcode itself, which re-runs loopOp and
        // re-pushes the label. Pointing target_pc past the opcode
        // would skip that re-push and corrupt the label stack on the
        // second iteration.
        .target_pc = blk.start_inst,
        .block_idx = @intCast(instr.payload),
    });
}

fn ifOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const cond = rt.popOperand().i32;
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    // Low byte = result arity, high byte = param count; see blockOp.
    // `height` excludes params; `if (param T)` blocktypes would
    // otherwise over-set arity + mis-place the restore base.
    const results: u32 = instr.extra & 0xFF;
    const params: u32 = (instr.extra >> 8) & 0xFF;
    try frame.pushLabel(rt.alloc, .{
        .height = rt.operand_len - params,
        .arity = results,
        .branch_arity = results,
        .target_pc = blk.end_inst + 1,
        .block_idx = @intCast(instr.payload),
    });
    if (cond == 0) {
        // Skip to else (if any) or directly past end.
        frame.pc = if (blk.else_inst) |e| e + 1 else blk.end_inst;
    }
}

fn elseOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    // Reaching else from the then-branch — jump to the matching `end`.
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    frame.pc = fnz.blocks.items[instr.payload].end_inst;
}

fn endOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    if (frame.label_len == 0) {
        // Function-level end: the run loop terminates after this step.
        frame.done = true;
        return;
    }
    const label = frame.popLabel();
    try restoreToLabel(rt, label);
}

/// Maximum arity supported by control-flow handlers. Bounded so
/// `restoreToLabel` and `returnOp` can save the topmost values to
/// a stack-local buffer without heap. Wasm 2.0 multivalue blocks
/// rarely return more than a handful of values; 16 is a generous
/// ceiling.
const max_block_arity: u32 = 16;

inline fn restoreToLabel(rt: *Runtime, label: runtime.Label) Trap!void {
    // Save `arity` topmost values, drop down to label.height, push back.
    if (label.arity == 0) {
        rt.operand_len = label.height;
        return;
    }
    if (label.arity > max_block_arity) return Trap.Unreachable;
    var saved: [max_block_arity]Value = undefined;
    var i: u32 = label.arity;
    while (i > 0) {
        i -= 1;
        saved[i] = rt.popOperand();
    }
    rt.operand_len = label.height;
    i = 0;
    while (i < label.arity) : (i += 1) {
        try rt.pushOperand(saved[i]);
    }
}

inline fn doBranch(rt: *Runtime, frame: *runtime.Frame, depth: u32) Trap!void {
    // `br depth` where depth == label_len targets the function body — Wasm's
    // implicit outermost block (§4.4.8). Semantically a function return: carry
    // the result-arity values out and end the frame. (gc/type-subtyping.17
    // "run" ends with a top-level `br 0` after all blocks close → label_len=0.)
    if (depth == frame.label_len) return returnFromFunction(rt, frame);
    if (depth > frame.label_len) return Trap.Unreachable;
    const target = frame.labelAt(depth);
    // Pop (depth + 1) labels off the control stack — except for loop
    // labels, br re-enters them (the loop opcode at target_pc will
    // re-push the label). Easier: pop all (depth+1), let the loop
    // opcode re-push if needed.
    var i: u32 = 0;
    while (i <= depth) : (i += 1) _ = frame.popLabel();
    // `restoreToLabel` uses `arity` — for branches we need
    // branch_arity (= results for block/if; = 0 for loops in
    // Wasm 1.0). Synthesise a label with the branch-time arity.
    const branch_label: runtime.Label = .{
        .height = target.height,
        .arity = target.branch_arity,
        .branch_arity = target.branch_arity,
        .target_pc = target.target_pc,
    };
    try restoreToLabel(rt, branch_label);
    frame.pc = target.target_pc;
}

fn brOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try doBranch(rt, rt.currentFrame(), @intCast(instr.payload));
}

fn brIfOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const cond = rt.popOperand().i32;
    if (cond != 0) {
        try doBranch(rt, rt.currentFrame(), @intCast(instr.payload));
    }
}

/// Wasm 3.0 GC §4.4.5 — `br_on_cast` / `br_on_cast_fail`. ZirInstr (D-453):
/// payload = labelidx | (ht2_encoded << 32), extra = flags (lower.zig).
/// ht2 is the full D-453 encoded heap-type (idx ≥ 64 representable); ht1
/// is validation-only and dropped. The operand ref stays on the stack
/// (carried on a taken branch, kept on fall-through — only its static type
/// narrows, a validate-time concern); we branch iff the runtime type-test
/// against ht2 matches (`br_on_cast`) or doesn't (`br_on_cast_fail`). Null
/// matches ht2 only when ht2 is nullable (flags bit 1). Concrete ht2 walks
/// the supertype chain via `gcRefMatchesNonNull` (10.G cycle 153).
fn brOnCastImpl(c: *InterpCtx, instr: *const ZirInstr, is_fail: bool) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const flags: u8 = @truncate(instr.extra);
    const ht2: u32 = @truncate(instr.payload >> 32);
    const labelidx: u32 = @truncate(instr.payload);
    const ht2_nullable = (flags & 0x02) != 0;
    const matches = if (v.ref == Value.null_ref) ht2_nullable else ref_test_ops.gcRefMatchesNonNull(rt, v, ht2);
    try rt.pushOperand(v); // ref remains on the stack (branch carries it / fall-through keeps it)
    const take = if (is_fail) !matches else matches;
    if (take) try doBranch(rt, rt.currentFrame(), labelidx);
}

fn brOnCastOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    return brOnCastImpl(c, instr, false);
}
fn brOnCastFailOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    return brOnCastImpl(c, instr, true);
}

fn brTableOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const idx = rt.popOperand().u32;
    const count = instr.payload;
    const start = instr.extra;
    const fnz = frame.func orelse return Trap.Unreachable;
    const targets = fnz.branch_targets.items;
    const end_idx = start + count;
    if (end_idx >= targets.len) return Trap.Unreachable;
    const depth = if (idx < count) targets[start + idx] else targets[end_idx];
    try doBranch(rt, frame, depth);
}

/// Recursive call. Pops args, allocates locals (params + zero-init
/// declared locals), pushes a frame, recursively runs the callee
/// body, then pops the frame on return.
fn callOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    // Host-call short-circuit (§9.4 / 4.7 chunk c). For imports
    // wired by the C-API binding, `host_calls[idx]` carries the
    // thunk + host context; defined-function indices have null
    // and fall through to ordinary ZirFunc dispatch.
    if (idx < rt.host_calls.len) {
        if (rt.host_calls[idx]) |hc| {
            // D-331A: fingerprint linear memory at every host-call boundary so an
            // interp trace can be diffed against the JIT's fd_write/poll_oneoff hooks.
            if (dbg.on("mem.cksum")) dbg.print("mem.cksum", "interp {d} {x}", .{ idx, dbg.fnv1a(rt.memory) });
            hc.fn_ptr(rt, hc.ctx) catch |err| {
                // Cross-module EH (10.E-eh-tail cycle 120): a cross-
                // module call's thunk transfers an uncaught throw into
                // `rt.pending_exception` (cross_module.zig). Unlike a
                // same-module ZIR callee — whose frame `invoke` pops
                // before searching the CALLER's try_table — the thunk
                // leaves no frame on `rt`, so the catch in THIS calling
                // func's own frame must be searched here before
                // re-raising.
                if (err == Trap.UncaughtException and rt.pending_exception != null and rt.frame_len > 0) {
                    const exc = rt.pending_exception.?;
                    if (try findAndDispatchCatch(rt, rt.currentFrame(), exc)) {
                        rt.pending_exception = null;
                        return;
                    }
                }
                return err;
            };
            return;
        }
    }
    if (idx >= rt.funcs.len) return Trap.Unreachable;
    if (dbg.on("jit.callcount")) call_profile.bump(@intCast(idx));
    if (dbg.on("jit.calledge")) {
        const caller: u32 = if (rt.currentFrame().func) |zf| zf.func_idx else 0xFFFF_FFFF;
        std.debug.print("[calledge] {d}->{d}\n", .{ caller, @as(u32, @intCast(idx)) });
    }
    const callee = rt.funcs[idx];
    const tbl = rt.table orelse return Trap.Unreachable;
    try invoke(rt, tbl, callee);
}

/// `call_indirect type_idx table_idx`: pops i32 selector, indexes
/// `rt.tables[table_idx]`, resolves the table cell's funcref by
/// dereferencing `*const FuncEntity` (ADR-0014 §2.1 / 6.K.1), and
/// invokes the callee body found at `fe.runtime.funcs[fe.func_idx]`
/// after a runtime sig-equality check against
/// `rt.module_types[type_idx]`. Encoding: `instr.payload` =
/// type_idx, `instr.extra` = table_idx.
///
/// Spec traps:
///   - selector >= table.len               → OutOfBoundsTableAccess
///   - table[selector] == null_ref         → UninitializedElement
///   - resolved sig != expected sig        → IndirectCallTypeMismatch
/// Pop a call_indirect table selector at the table's address width: a
/// table64 (memory64 proposal's table extension) selector is i64 (read the
/// full 64 bits so a >2^32 selector still trips the bounds check); an i32
/// table reads the low word.
inline fn popTableSelector(rt: *Runtime, idx_type: zir.IdxType) u64 {
    return switch (idx_type) {
        .i64 => @bitCast(rt.popOperand().i64),
        .i32 => rt.popOperand().u32,
    };
}

fn callIndirectOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.extra;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];

    const sel = popTableSelector(rt, tbl.idx_type);
    if (sel >= tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    const ref_v = tbl.refs[@intCast(sel)];
    const fe = runtime.Value.refAsFuncEntity(ref_v) orelse return Trap.UninitializedElement;
    const callee_rt = fe.runtime;
    if (fe.func_idx >= callee_rt.funcs.len) return Trap.UninitializedElement;
    if (dbg.on("jit.callcount") and callee_rt == rt) call_profile.bump(fe.func_idx);
    if (dbg.on("jit.calledge") and callee_rt == rt) {
        const caller: u32 = if (rt.currentFrame().func) |zf| zf.func_idx else 0xFFFF_FFFF;
        std.debug.print("[calledge] {d}->{d}\n", .{ caller, fe.func_idx });
    }
    const callee = callee_rt.funcs[fe.func_idx];

    if (instr.payload >= rt.module_types.len) return Trap.IndirectCallTypeMismatch;
    const expected = rt.module_types[instr.payload];
    // Wasm 3.0 §3.3.5.5 — the callee's declared func type need only be a
    // SUBTYPE of the expected type (not structurally equal): a `$t1` func
    // (`$t1 <: $t0`) called via `call_indirect (type $t0)` runs (D-198).
    // When the module carries a GC type-identity table (declares `sub`/`final`
    // subtyping), `concreteReaches` is AUTHORITATIVE — structural `sigEq` is too
    // loose (ignores type identity / finality) and wrongly accepts structurally-
    // equal-but-distinct types (D-232). Cross-module (callee_rt != rt — no
    // shared type space) + non-subtyping modules use `sigEq`. The 3.0 arm
    // comptime-elides in sub-3.0 builds (ADR-0129).
    const accepted = if (comptime wasm_v3_plus) blk: {
        if (callee_rt == rt and ref_test_ops.hasGti(rt))
            break :blk ref_test_ops.concreteReaches(rt, fe.raw_typeidx, @intCast(instr.payload));
        break :blk sigEq(callee.sig, expected);
    } else sigEq(callee.sig, expected);
    if (!accepted) {
        if (dbg.on("interp.calltrap")) std.debug.print("[calltrap] indirect mismatch: sel={d} callee_idx={d} callee.sig params={any} results={any} expected params={any} results={any}\n", .{ sel, fe.func_idx, callee.sig.params, callee.sig.results, expected.params, expected.results });
        return Trap.IndirectCallTypeMismatch;
    }

    if (try routeForeignCallee(rt, callee_rt, fe.func_idx, callee)) return;
    const dispatch_tbl = rt.table orelse return Trap.Unreachable;
    try invoke(rt, dispatch_tbl, callee);
}

/// Wasm spec 3.0 §3.3.8.10 (`call_ref typeidx`): pops a funcref;
/// if null → Trap.NullReference (§3.3.8.10 step 2). Else decodes
/// the funcref to a FuncEntity, verifies its signature equals
/// `module_types[typeidx]` (else Trap.IndirectCallTypeMismatch),
/// and invokes the callee body — same cross-module dispatch path
/// as `call_indirect` (§3.4 / 6.K.3 via `fe.runtime`). Encoding:
/// `instr.payload` = typeidx.
///
/// Differs from call_indirect by sourcing the funcref directly
/// from the operand stack (no table indexing); spec-required null
/// trap supplants call_indirect's table-bound UninitializedElement.
fn callRefOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const ref_v = rt.popOperand();
    if (ref_v.ref == runtime.Value.null_ref) return Trap.NullReference;
    const fe = runtime.Value.refAsFuncEntity(ref_v) orelse return Trap.NullReference;
    const callee_rt = fe.runtime;
    if (fe.func_idx >= callee_rt.funcs.len) return Trap.IndirectCallTypeMismatch;
    const callee = callee_rt.funcs[fe.func_idx];

    if (instr.payload >= rt.module_types.len) return Trap.IndirectCallTypeMismatch;
    const expected = rt.module_types[instr.payload];
    // Wasm 3.0 §3.3.5.5 — the callee's declared func type need only be a
    // SUBTYPE of the expected type (not structurally equal): a `$t1` func
    // (`$t1 <: $t0`) called via `call_ref (type $t0)` runs (D-198).
    // gti present (subtyping module) → `concreteReaches` authoritative; structural
    // `sigEq` is too loose (D-232). Cross-module + non-subtyping → `sigEq`. 3.0
    // arm comptime-elides in sub-3.0 builds (ADR-0129).
    const accepted = if (comptime wasm_v3_plus) blk: {
        if (callee_rt == rt and ref_test_ops.hasGti(rt))
            break :blk ref_test_ops.concreteReaches(rt, fe.raw_typeidx, @intCast(instr.payload));
        break :blk sigEq(callee.sig, expected);
    } else sigEq(callee.sig, expected);
    if (!accepted) {
        if (dbg.on("interp.calltrap")) std.debug.print("[calltrap] call_ref mismatch: callee_idx={d} callee.sig params={any} results={any} expected params={any} results={any}\n", .{ fe.func_idx, callee.sig.params, callee.sig.results, expected.params, expected.results });
        return Trap.IndirectCallTypeMismatch;
    }

    if (try routeForeignCallee(rt, callee_rt, fe.func_idx, callee)) return;
    const dispatch_tbl = rt.table orelse return Trap.Unreachable;
    try invoke(rt, dispatch_tbl, callee);
}

/// The arms every `call_indirect` / `call_ref` form takes, tail or not, before
/// its own dispatch; true when one of them ran the callee. An import slot
/// (host trampoline or cross-module guest) dispatches via host_calls, not its
/// placeholder body (D-310); the args sit on this rt's operand stack. A funcref
/// owned by another runtime runs in ITS context — own globals / memory /
/// tables — via `invokeCrossRuntime` (D-325). Either way the callee runs
/// nested, so a tail form follows with `tailReturn`: the trampoline (D-187)
/// swaps frames only within one runtime (#538).
fn routeForeignCallee(rt: *Runtime, callee_rt: *Runtime, func_idx: u32, callee: *const zir.ZirFunc) anyerror!bool {
    if (func_idx < callee_rt.host_calls.len) {
        if (callee_rt.host_calls[func_idx]) |hc| {
            try hc.fn_ptr(rt, hc.ctx);
            return true;
        }
    }
    if (callee_rt != rt) {
        // The interp DispatchTable (ZirOp→handler) is shared, so pass ours.
        const dispatch_tbl = rt.table orelse return Trap.Unreachable;
        try invokeCrossRuntime(rt, callee_rt, dispatch_tbl, callee);
        return true;
    }
    return false;
}

/// Tail-call epilogue shared by the `return_call*` family. After
/// `invoke()` returns, the callee's results sit at the top of the
/// operand stack. The validator guaranteed `callee.results` matches
/// the enclosing function's return type element-wise — so those
/// values ARE the caller's return values. Reset the caller's
/// operand stack to its operand_base, push the saved results back,
/// and mark the frame done so the dispatch loop exits cleanly.
fn tailReturn(rt: *Runtime) anyerror!void {
    const caller_frame = rt.currentFrame();
    const arity: u32 = @intCast(caller_frame.sig.results.len);
    if (arity > max_block_arity) return Trap.Unreachable;
    var saved: [max_block_arity]Value = undefined;
    var i: u32 = arity;
    while (i > 0) {
        i -= 1;
        saved[i] = rt.popOperand();
    }
    rt.operand_len = caller_frame.operand_base;
    i = 0;
    while (i < arity) : (i += 1) {
        try rt.pushOperand(saved[i]);
    }
    caller_frame.label_len = 0;
    caller_frame.done = true;
}

/// D-187 — interp tail-call trampoline signal. Sets the runtime
/// flag that `src/interp/dispatch.zig::run`'s outer loop polls
/// after the current frame's instr loop exits, marks the caller
/// frame done so the inner loop exits without executing further
/// instrs, and clears the caller's label stack so any in-flight
/// control labels don't survive into the popped frame. Args
/// stay on the operand stack at `[caller.operand_base..operand_len]`
/// (validator-guaranteed exactly the callee's params at
/// return_call); the trampoline pops them into fresh callee
/// locals after popping the caller frame.
fn signalTailCall(rt: *Runtime, callee: *const zir.ZirFunc) void {
    rt.pending_tail_call = callee;
    const caller_frame = rt.currentFrame();
    caller_frame.done = true;
    caller_frame.label_len = 0;
}

/// Wasm spec 3.0 §3.3.10.5 (`return_call_ref typeidx`): tail-call
/// variant of call_ref. Pops funcref + the typeidx-determined args,
/// runs the same null + sig-mismatch checks, then routes the callee
/// as `callRefOp` does and tail-calls it.
fn returnCallRefOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const ref_v = rt.popOperand();
    if (ref_v.ref == runtime.Value.null_ref) return Trap.NullReference;
    const fe = runtime.Value.refAsFuncEntity(ref_v) orelse return Trap.NullReference;
    const callee_rt = fe.runtime;
    if (fe.func_idx >= callee_rt.funcs.len) return Trap.IndirectCallTypeMismatch;
    const callee = callee_rt.funcs[fe.func_idx];

    if (instr.payload >= rt.module_types.len) return Trap.IndirectCallTypeMismatch;
    const expected = rt.module_types[instr.payload];
    if (!sigEq(callee.sig, expected)) return Trap.IndirectCallTypeMismatch;

    if (try routeForeignCallee(rt, callee_rt, fe.func_idx, callee)) return tailReturn(rt);
    signalTailCall(rt, callee);
}

/// Wasm spec 3.0 §3.3.10.3 (`return_call funcidx`): tail-call
/// variant of `call`. Host imports (rt.host_calls) keep the
/// invoke + `tailReturn` shape (host fns don't grow the host
/// call stack per Wasm tail-call, so the prior recursive shape
/// stays correct for them). Same-module Zir-defined callees
/// route through `dispatch.run`'s trampoline (D-187 discharge):
/// the handler sets `rt.pending_tail_call` + marks the current
/// frame done; the trampoline pops the caller frame, pops args
/// off the operand stack into fresh callee locals, and continues
/// iterating in the same Zig stack frame.
fn returnCallOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx: u32 = @intCast(instr.payload);
    if (idx < rt.host_calls.len) {
        if (rt.host_calls[idx]) |hc| {
            try hc.fn_ptr(rt, hc.ctx);
            try tailReturn(rt);
            return;
        }
    }
    if (idx >= rt.funcs.len) return Trap.Unreachable;
    const callee = rt.funcs[idx];
    signalTailCall(rt, callee);
}

/// Wasm spec 3.0 §3.3.10.4 (`return_call_indirect typeidx tableidx`):
/// tail-call variant of `call_indirect`. Mirrors `callIndirectOp` +
/// `tailReturn`. Encoding: `instr.payload` = typeidx, `instr.extra`
/// = tableidx.
fn returnCallIndirectOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.extra;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];

    const sel = popTableSelector(rt, tbl.idx_type);
    if (sel >= tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    const ref_v = tbl.refs[@intCast(sel)];
    const fe = runtime.Value.refAsFuncEntity(ref_v) orelse return Trap.UninitializedElement;
    const callee_rt = fe.runtime;
    if (fe.func_idx >= callee_rt.funcs.len) return Trap.UninitializedElement;
    if (dbg.on("jit.callcount") and callee_rt == rt) call_profile.bump(fe.func_idx);
    if (dbg.on("jit.calledge") and callee_rt == rt) {
        const caller: u32 = if (rt.currentFrame().func) |zf| zf.func_idx else 0xFFFF_FFFF;
        std.debug.print("[calledge] {d}->{d}\n", .{ caller, fe.func_idx });
    }
    const callee = callee_rt.funcs[fe.func_idx];

    if (instr.payload >= rt.module_types.len) return Trap.IndirectCallTypeMismatch;
    const expected = rt.module_types[instr.payload];
    if (!sigEq(callee.sig, expected)) return Trap.IndirectCallTypeMismatch;

    if (try routeForeignCallee(rt, callee_rt, fe.func_idx, callee)) return tailReturn(rt);
    signalTailCall(rt, callee);
}

inline fn sigEq(a: zir.FuncType, b: zir.FuncType) bool {
    if (a.params.len != b.params.len) return false;
    if (a.results.len != b.results.len) return false;
    for (a.params, b.params) |x, y| if (!x.eql(y)) return false;
    for (a.results, b.results) |x, y| if (!x.eql(y)) return false;
    return true;
}

/// Invoke a callee on the given runtime. Made public per
/// ADR-0014 §2.1 / 6.K.3 so the cross-module call thunk in
/// `c_api/instance.zig` can dispatch source-instance bodies on
/// the source instance's runtime.
pub fn invoke(rt: *Runtime, table: *const DispatchTable, callee: *const zir.ZirFunc) anyerror!void {
    // D-288 / ADR-0167: each wasm call recurses on the host stack here
    // (~8 KiB/frame). Trap CallStackExhausted at the real per-OS native
    // limit BEFORE a SEGV (the binding guard on the small Windows stack,
    // where ~128 < the frame_buf[256] cap).
    try rt.checkNativeStackLimit(@frameAddress());
    try rt.checkInterrupt(); // ADR-0179 #3a: host-requested timeout/cancel
    const params_len = callee.sig.params.len;
    const total = params_len + callee.locals.len;
    const locals = try rt.alloc.alloc(runtime.Value, total);
    defer rt.alloc.free(locals);

    // Pop args in reverse (last param popped first lands at locals[params_len-1]).
    var i: usize = params_len;
    while (i > 0) {
        i -= 1;
        if (rt.operand_len == 0) return Trap.StackOverflow;
        locals[i] = rt.popOperand();
    }
    // Zero-init declared locals.
    var j: usize = params_len;
    while (j < total) : (j += 1) locals[j] = runtime.Value.zero;

    try rt.pushFrame(.{
        .sig = callee.sig,
        .locals = locals,
        .operand_base = rt.operand_len,
        .pc = 0,
        .func = callee,
    });

    const dispatch_loop_local = @import("dispatch.zig");
    const run_err = dispatch_loop_local.run(rt, table, callee.instrs.items);
    _ = rt.popFrame();

    // Wasm 3.0 EH cross-frame unwind (10.E-5d). When the callee
    // body propagated an uncaught exception, retry the catch
    // search against the caller frame's labels before re-raising.
    // The pending-exception pointer survives the popFrame since
    // it lives on Runtime, not on the per-frame operand stack;
    // the underlying `*Exception` survives via `rt.live_exceptions`.
    run_err catch |err| {
        if (err == Trap.UncaughtException and rt.pending_exception != null and rt.frame_len > 0) {
            const exc = rt.pending_exception.?;
            const caller = rt.currentFrame();
            if (try findAndDispatchCatch(rt, caller, exc)) {
                rt.pending_exception = null;
                return;
            }
        }
        return err;
    };
}

/// Invoke `callee` (which belongs to `callee_rt`) from `caller_rt` when the two
/// runtimes differ — the callee must execute in ITS OWN runtime context (own
/// globals / memory / tables), not the caller's. Transfers the args from the
/// caller's operand stack to the callee's, runs `invoke` against `callee_rt`,
/// and transfers the results back (mirrors `cross_module.thunk`; both share
/// this so the cross-runtime contract has a single home). Used by
/// `call_indirect` / `call_ref` / their tail-call variants when a table /
/// stack funcref carries a foreign `fe.runtime` (D-325 — wit-bindgen shim
/// tables hold cross-instance guest funcrefs; without this the callee runs
/// against the shim's globals and traps).
pub fn invokeCrossRuntime(
    caller_rt: *Runtime,
    callee_rt: *Runtime,
    callee_dispatch: *const DispatchTable,
    callee: *const zir.ZirFunc,
) anyerror!void {
    const num_params: u32 = @intCast(callee.sig.params.len);
    if (caller_rt.operand_len < num_params) return Trap.StackOverflow;
    const args_start = caller_rt.operand_len - num_params;
    var i: u32 = 0;
    while (i < num_params) : (i += 1) {
        try callee_rt.pushOperand(caller_rt.operand_buf[args_start + i]);
    }
    caller_rt.operand_len = args_start;

    invoke(callee_rt, callee_dispatch, callee) catch |err| {
        // Cross-runtime exception propagation (mirrors cross_module.thunk):
        // hand an uncaught throw to the caller so ITS catch search matches.
        if (err == Trap.UncaughtException) {
            if (callee_rt.pending_exception) |exc| {
                caller_rt.pending_exception = exc;
                callee_rt.pending_exception = null;
            }
        }
        return err;
    };

    const num_results: u32 = @intCast(callee.sig.results.len);
    if (callee_rt.operand_len < num_results) return Trap.StackOverflow;
    const results_start = callee_rt.operand_len - num_results;
    i = 0;
    while (i < num_results) : (i += 1) {
        try caller_rt.pushOperand(callee_rt.operand_buf[results_start + i]);
    }
    callee_rt.operand_len = results_start;
}

/// Wasm 3.0 EH `throw tag_idx` (§3.3.10.7 / §4.5). Pops the
/// tag's params (per `Runtime.tag_param_counts[tag_idx]`) into
/// a stack-local stash, then walks the current frame's label
/// stack inward-out looking for a `try_table` whose catch-vec
/// contains a matching clause. On match dispatches like `br`
/// to the catch's `label_idx` target (which is measured from
/// try_table's lexical position, i.e. excluding the try_table
/// label itself — see `Validator.validateCatchVec`).
///
/// Catch flavor coverage:
///   - `catch_` (0x00): match if `entry.tag_idx == thrown_tag_idx`;
///     restore operand stack to target label's height, push the
///     stashed payload (= the tag's params in spec order).
///   - `catch_all` (0x02): always matches; payload is discarded
///     (stack restores to target label's height).
///   - `catch_ref` (0x01) / `catch_all_ref` (0x03): deferred —
///     exnref support lands at 10.E-N alongside the heap-typed
///     exception value (would push an `exnref` payload in
///     addition to / instead of the tag params).
///
/// When no matching catch is found in the current frame, the
/// stashed payload is dropped and `Trap.UncaughtException`
/// propagates (cross-frame unwind lands at 10.E-5d).
fn throwOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const thrown_tag_idx: u32 = @intCast(instr.payload);

    // Pop the tag's params per the pre-resolved count. Safe
    // fallback: when `tag_param_counts` is empty or the tag_idx
    // is past the populated length, treat as 0 params.
    const param_count: u32 = if (thrown_tag_idx < rt.tag_param_counts.len)
        rt.tag_param_counts[thrown_tag_idx]
    else
        0;
    if (param_count > runtime.max_exception_payload) return Trap.Unreachable;

    // Pop params into a stack-local buffer (last param on top).
    var payload_buf: [runtime.max_exception_payload]Value = undefined;
    var i: u32 = param_count;
    while (i > 0) {
        i -= 1;
        payload_buf[i] = rt.popOperand();
    }

    // Allocate the Exception heap object; track for Runtime.deinit
    // cleanup. The exnref pushed by catch_all_ref / catch_ref
    // points into this allocation; lifetime extends until
    // Runtime.deinit (pre-GC milestones).
    const exc = try rt.alloc.create(runtime.Exception);
    exc.* = runtime.Exception.init(thrown_tag_idx, payload_buf[0..param_count]);
    // ADR-0114 D1 — stamp the tag identity so catch (incl. cross-
    // module) matches by `*TagInstance` pointer, not index.
    if (thrown_tag_idx < rt.tags.len) exc.tag = rt.tags[thrown_tag_idx];
    try rt.live_exceptions.append(rt.alloc, exc);
    rt.pending_exception = exc;

    if (try findAndDispatchCatch(rt, frame, exc)) {
        rt.pending_exception = null;
        return;
    }
    return Trap.UncaughtException;
}

/// Wasm 3.0 EH `throw_ref` (§3.3.10.8). Re-raises an exception
/// via an `exnref` on the operand stack. Pops the exnref,
/// resolves the `*Exception` it wraps, writes the pointer to
/// `rt.pending_exception`, then re-enters `findAndDispatchCatch`
/// against the current frame. A null exnref traps
/// (`Trap.NullReference` per spec). The Exception object itself
/// is NOT re-allocated — `throw_ref` just routes the existing
/// `*Exception` back through the unwinder, so catch arms that
/// match see the same payload + tag_idx as the original throw.
fn throwRefOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const ref_v = rt.popOperand();
    const exc_opaque = Value.refAsExceptionPtr(ref_v) orelse return Trap.NullReference;
    const exc: *runtime.Exception = @ptrCast(@alignCast(exc_opaque));
    rt.pending_exception = exc;

    if (try findAndDispatchCatch(rt, frame, exc)) {
        rt.pending_exception = null;
        return;
    }
    return Trap.UncaughtException;
}

/// 10.E-5b/c catch dispatch. Walks the frame's label stack
/// inward-out (depth 0 = innermost). For each label whose
/// owning BlockInfo is a `.try_table`, scans the matching
/// `LandingPad` in `func.eh_landing_pads` for the first
/// satisfying catch clause.
///
///   - `catch_all` (no payload push): routes through `doBranch`
///     with depth `(try_table_depth + 1 + catch.label_idx)`.
///     The `+ 1` skips the try_table's own label per the
///     validator's catch-label numbering.
///   - `catch_` (push payload): manual unwind — pop labels down
///     to the target depth, set `operand_len = target.height`,
///     then push each payload Value in spec order. doBranch
///     can't be reused here because its `restoreToLabel` uses
///     the target's `branch_arity` (block result count) rather
///     than the tag's param count.
///
/// `catch_ref` / `catch_all_ref` are deferred to the exnref
/// implementation (10.E-N follow-up).
/// ADR-0114 D1 — does a `catch`/`catch_ref` clause (tag index in the
/// CATCHER's space) match the thrown exception? Compares by
/// `*TagInstance` pointer (correct across module boundaries) when both
/// the catcher's `rt.tags` slot and the exception's stamped tag are
/// available; falls back to the index key on the legacy no-tags path.
fn catchTagMatches(rt: *Runtime, entry_tag_idx: u32, exc: *const runtime.Exception) bool {
    if (exc.tag) |thrown_tag| {
        if (entry_tag_idx < rt.tags.len) return rt.tags[entry_tag_idx] == thrown_tag;
    }
    return entry_tag_idx == exc.tag_idx;
}

fn findAndDispatchCatch(
    rt: *Runtime,
    frame: *runtime.Frame,
    exc: *runtime.Exception,
) Trap!bool {
    const fnz = frame.func orelse return false;
    const landing_pads = fnz.eh_landing_pads orelse return false;
    const catch_entries = fnz.eh_catch_entries orelse &[_]zir.CatchEntry{};
    const payload = exc.payload[0..exc.payload_len];

    var depth: u32 = 0;
    while (depth < frame.label_len) : (depth += 1) {
        const label = frame.labelAt(depth);
        if (label.block_idx >= fnz.blocks.items.len) continue;
        if (fnz.blocks.items[label.block_idx].kind != .try_table) continue;

        const lp = findLandingPad(landing_pads, label.block_idx) orelse continue;
        var i: u32 = lp.catches_start;
        while (i < lp.catches_end) : (i += 1) {
            const entry = catch_entries[i];
            switch (entry.kind) {
                .catch_all => {
                    try doBranch(rt, frame, depth + 1 + entry.label_idx);
                    return true;
                },
                .catch_ => {
                    if (!catchTagMatches(rt, entry.tag_idx, exc)) continue;
                    try dispatchCatchWithPayload(rt, frame, depth + 1 + entry.label_idx, payload);
                    return true;
                },
                .catch_all_ref => {
                    // catch_all_ref pushes only the exnref (no tag params).
                    var exn_only: [1]Value = .{Value.fromExceptionRef(@ptrCast(exc))};
                    try dispatchCatchWithPayload(rt, frame, depth + 1 + entry.label_idx, exn_only[0..]);
                    return true;
                },
                .catch_ref => {
                    if (!catchTagMatches(rt, entry.tag_idx, exc)) continue;
                    // catch_ref pushes the tag's params followed by the exnref.
                    var combined: [runtime.max_exception_payload + 1]Value = undefined;
                    for (payload, 0..) |v, j| combined[j] = v;
                    combined[payload.len] = Value.fromExceptionRef(@ptrCast(exc));
                    try dispatchCatchWithPayload(rt, frame, depth + 1 + entry.label_idx, combined[0 .. payload.len + 1]);
                    return true;
                },
            }
        }
    }
    return false;
}

/// Unwind to `target_depth` and push `payload` values onto the
/// operand stack at the target label's height. Used by catch_
/// dispatch where `payload` carries the thrown tag's params (the
/// catch label's stack signature expects exactly these values).
inline fn dispatchCatchWithPayload(
    rt: *Runtime,
    frame: *runtime.Frame,
    target_depth: u32,
    payload: []const Value,
) Trap!void {
    if (target_depth >= frame.label_len) return Trap.Unreachable;
    const target = frame.labelAt(target_depth);
    var k: u32 = 0;
    while (k <= target_depth) : (k += 1) _ = frame.popLabel();
    rt.operand_len = target.height;
    for (payload) |v| try rt.pushOperand(v);
    frame.pc = target.target_pc;
}

fn findLandingPad(pads: []const zir.LandingPad, block_idx: u32) ?zir.LandingPad {
    for (pads) |lp| {
        if (lp.block_idx == block_idx) return lp;
    }
    return null;
}

/// Function return: save the top `sig.results.len` values, drop the operand
/// stack to the frame base, push them back, end the frame. Shared by the
/// explicit `return` op AND `doBranch` when a `br` targets the implicit
/// function-body label (depth == label_len).
fn returnFromFunction(rt: *Runtime, frame: *runtime.Frame) Trap!void {
    const arity: u32 = @intCast(frame.sig.results.len);
    if (arity > max_block_arity) return Trap.Unreachable;
    var saved: [max_block_arity]Value = undefined;
    var i: u32 = arity;
    while (i > 0) {
        i -= 1;
        saved[i] = rt.popOperand();
    }
    rt.operand_len = frame.operand_base;
    i = 0;
    while (i < arity) : (i += 1) {
        try rt.pushOperand(saved[i]);
    }
    frame.label_len = 0;
    frame.done = true;
}

fn returnOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try returnFromFunction(rt, rt.currentFrame());
}

fn drop(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    _ = rt.popOperand();
}

fn localGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    try rt.pushOperand(frame.locals[idx]);
}

fn localSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    frame.locals[idx] = rt.popOperand();
}

fn localTee(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    frame.locals[idx] = rt.topOperand();
}

fn globalGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    if (idx >= rt.globals.len) return Trap.Unreachable;
    try rt.pushOperand(rt.globals[idx].*);
}

fn globalSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    if (idx >= rt.globals.len) return Trap.Unreachable;
    const v = rt.popOperand();
    rt.globals[idx].* = v;
    // D-494 asyncify debug (ZWASM_DEBUG=global.trace): the TinyGo asyncify state
    // machine drives globals 0/1/2 (i32). Byte-read the low 4 bytes so a non-i32
    // global in another program doesn't trip the union active-field check.
    if (dbg.on("global.trace")) {
        const lo4 = std.mem.bytesToValue(i32, std.mem.asBytes(&v)[0..4]);
        const fnz: u32 = if (rt.currentFrame().func) |zf| zf.func_idx else 0xFFFF_FFFF;
        std.debug.print("[gset] fn={d} g{d}={d}\n", .{ fnz, idx, lo4 });
    }
}

// The one in-file test: it exercises the PRIVATE catchTagMatches predicate
// (the sibling mvp_tests.zig suite tests through the public dispatch surface).
const testing_ = @import("std").testing;

test "catchTagMatches: *TagInstance pointer identity vs index fallback (10.E-eh-tail cycle 119)" {
    var rt = Runtime.init(testing_.allocator);
    defer rt.deinit();
    // Two structurally-identical tags (same typeidx) — identity is the
    // POINTER, so they must NOT match each other (ADR-0114 D1).
    var tag_a: runtime.TagInstance = .{ .typeidx = 0 };
    var tag_b: runtime.TagInstance = .{ .typeidx = 0 };
    var tags = [_]*runtime.TagInstance{ &tag_a, &tag_b };
    rt.tags = &tags;
    var exc = runtime.Exception.init(0, &.{});
    exc.tag = &tag_a;
    try testing_.expect(catchTagMatches(&rt, 0, &exc)); // tags[0]==&tag_a==exc.tag
    try testing_.expect(!catchTagMatches(&rt, 1, &exc)); // tags[1]==&tag_b != exc.tag
    // No stamped tag → legacy index fallback.
    exc.tag = null;
    exc.tag_idx = 1;
    try testing_.expect(catchTagMatches(&rt, 1, &exc));
    try testing_.expect(!catchTagMatches(&rt, 0, &exc));
}
