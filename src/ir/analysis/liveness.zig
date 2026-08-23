//! Per-vreg liveness analysis pass (§9.5 / 5.4).
//!
//! Walks a lowered `ZirFunc`'s instr stream simulating the
//! operand stack as a stack of vreg ids. Each push assigns a
//! fresh vreg id (sequential, 0-based) and opens a live range
//! `(def_pc, def_pc)`. Each pop closes the topmost vreg's range
//! by setting `last_use_pc = pc`. The function-level `end`
//! consumes any vreg still on the stack so its range closes at
//! that instr index too.
//!
//! Phase-5 scope is the **straight-line MVP arithmetic + locals
//! + globals + select + conversions** subset (the ops covered by
//! `src/interp/mvp_int.zig`, `mvp_float.zig`, and
//! `mvp_conversions.zig` minus control flow). Encountering any
//! control-flow op (`block` / `loop` / `if` / `else` / `br` /
//! `br_if` / `br_table` / `return` / `call` / `call_indirect`)
//! returns `error.UnsupportedControlFlow` — the Phase-7 regalloc
//! consumer will refine the analysis to handle CFG splits when
//! it lands. Calls into `memory_ops.*` (loads / stores) are not
//! covered by this iteration either; their stack effects land
//! alongside the regalloc consumer.
//!
//! Lifetime: `compute` allocates the result slice via the
//! caller-supplied allocator. The caller owns it; pair with
//! `deinit` to free.
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("../zir.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const Liveness = zir.Liveness;
const LiveRange = zir.LiveRange;

pub const Error = error{
    UnsupportedControlFlow,
    UnsupportedOp,
    OperandStackUnderflow,
    OutOfMemory,
};

/// Bounded VM operand-stack simulation. 1024 mirrors the
/// validator's `max_operand_stack` so a function the validator
/// accepts cannot exceed this depth at runtime.
const max_simulated_stack: usize = 1024;
const max_control_stack: usize = 256;

// Stack effect catalog extracted to `liveness_stack_effect.zig`
// per ADR-0088. Re-exported here so callers reach
// `liveness.StackEffect` / `liveness.stackEffect` unchanged.
const stack_effect_mod = @import("liveness_stack_effect.zig");
pub const StackEffect = stack_effect_mod.StackEffect;
pub const stackEffect = stack_effect_mod.stackEffect;

// ADR-0155 (D-265 Phase IV stage 1) — register-homed locals. The homing plan
// is the single source of truth shared with regalloc + emit.
const local_homing = @import("local_homing.zig");

/// One control-nesting frame for the single-pass liveness walk.
/// Hoisted to module scope (was local to `compute`) so the D-330
/// `captureBlockMergeVregs` helper can take a `*Frame`.
const Frame = struct {
    entry_depth: u32,
    param_arity: u8,
    result_arity: u8,
    is_if: bool,
    // D-330: distinguishes a `loop` frame (backward branch target —
    // no forward result merge) from a `block` frame, so block-merge
    // capture skips loops.
    is_loop: bool,
    merge_captured: bool,
    param_vregs: [8]u32,
    // D-093 (d-11) — if/block result-merge survival. emit's per-arch
    // `.else` (if) / first br-or-br_if (block) captures the top
    // `result_arity` vregs as the merge target; the matching `.end`
    // MOVs the other arm's results into the captured slot. Without
    // liveness tracking the captured vreg's last_use_pc stops early,
    // so regalloc may alias its slot (or park it in a call-clobbered
    // callee-saved reg) and the post-block consumer reads garbage.
    merge_vregs: [8]u32,
};

/// D-330 — on the FIRST forward `br`/`br_if`/`br_table` to a
/// `block(result_arity>0)`, capture the targeted block's result
/// operands as its canonical merge vregs (mirrors the emit's
/// `captureOrEmitBlockMergeMov` first-capture). The block's `.end`
/// then extends these vregs' `last_use_pc` to the post-block
/// consumer, so the regalloc keeps them live across any
/// intervening call instead of parking the result in a
/// callee-saved register a call would clobber.
///
/// No-op for: `loop` targets (backward branch — no forward
/// merge), function-level escapes (depth ≥ stack), zero-result
/// blocks, already-captured frames, and a too-shallow operand
/// stack (dead-code branch). `result_arity ≤ 8` is guaranteed by
/// the block-open arity check.
fn captureBlockMergeVregs(
    block_stack: *[]Frame,
    block_stack_len: usize,
    depth: u32,
    sim: []const u32,
) void {
    if (depth >= block_stack_len) return;
    const fr = &block_stack.*[block_stack_len - 1 - @as(usize, depth)];
    if (fr.is_if or fr.is_loop or fr.merge_captured or fr.result_arity == 0) return;
    const arity: usize = fr.result_arity;
    if (sim.len < arity) return;
    const base = sim.len - arity;
    var i: usize = 0;
    while (i < arity) : (i += 1) {
        fr.merge_vregs[i] = sim[base + i];
    }
    fr.merge_captured = true;
}

fn isControlFlow(op: ZirOp) bool {
    // After sub-7.5c-iv, every Wasm 1.0 control-flow op is
    // handled explicitly in `compute`. The function exists
    // only as documentation of the categories; nothing in the
    // analysis branches on it now.
    return switch (op) {
        .@"unreachable",
        .br,
        .br_if,
        .br_table,
        .@"return",
        .block,
        .loop,
        .@"if",
        .@"else",
        .end,
        .call,
        .call_indirect,
        => true,
        else => false,
    };
}

/// Compute per-vreg live ranges. Returns a `Liveness` whose
/// `ranges` slice the caller owns.
///
/// `func_sigs` indexes function signatures by func_idx; consulted
/// by `call N` to determine the pop/push count. `module_types`
/// indexes type signatures by typeidx; consulted by
/// `call_indirect type_idx`. Pass empty slices when the function
/// has no calls (the existing straight-line tests).
///
/// **Phase 7.5 scope**: extends Phase-5's straight-line MVP +
/// conversions + sat_trunc (sub-h5) with `call` + `call_indirect`.
/// Block-level control flow (block / loop / if / else / br / etc.)
/// still rejects; sub-7.5c-future widens this to structured-CFG-
/// aware analysis.
pub fn compute(
    allocator: Allocator,
    func: *const ZirFunc,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
) Error!Liveness {
    var ranges: std.ArrayList(LiveRange) = .empty;
    errdefer ranges.deinit(allocator);

    var sim_stack: [max_simulated_stack]u32 = undefined;
    var sim_len: usize = 0;

    // D-093 (d-9) — `block` / `loop` / `if` entry depths so `.br N`
    // can close only vregs ABOVE the target's entry, leaving lower
    // values live for post-block consumers. Per Wasm spec §3.4.4:
    // br N pops the target label's arity values + discards
    // intermediate values pushed inside nested blocks; values
    // BELOW target's entry stack-depth are preserved.
    //
    // D-093 (d-10) extension — `if`-frame captures top
    // `param_arity` vregs at entry so `.else` can re-push them
    // (Wasm spec §3.4.4: else-arm starts with the same operand-
    // stack shape as the then-arm did at if-entry). Liveness then
    // sees the re-pushed vregs consumed by else-arm body, which
    // bumps their `last_use_pc` forward and prevents regalloc from
    // aliasing their spill slots across the if-frame.
    // Dynamic control-nesting stack (D-331): fat toolchains (standard Go's
    // giant runtime funcs — go_hello_wasi func[303] has 11151 instrs nesting
    // blocks >256 deep) exceed any fixed cap. The interp runs them, so the JIT
    // liveness must too. `max_control_stack` is the initial capacity; it grows
    // by doubling at the push sites below (OutOfMemory is the only ceiling).
    var block_stack: []Frame = try allocator.alloc(Frame, max_control_stack);
    defer allocator.free(block_stack);
    var block_stack_len: usize = 0;

    // Sub-7.5c-iv: after an unconditional branch (br / return /
    // unreachable) the rest of the block body is dead code per
    // Wasm's polymorphic-stack rule. Dead-code liveness does
    // nothing structurally — vregs that the dead region produces
    // would never reach a real consumer; their ranges stay
    // collapsed to a single pc by virtue of no later instr
    // popping them. So we don't track a separate dead flag
    // explicitly; the conservative pop-on-branch handling below
    // is enough.

    for (func.instrs.items, 0..) |instr, idx| {
        const pc: u32 = @intCast(idx);

        // The function-level `end` closes every still-live vreg.
        if (instr.op == .end) {
            const is_function_end = (idx + 1 == func.instrs.items.len);
            if (is_function_end) {
                while (sim_len > 0) {
                    sim_len -= 1;
                    const vreg = sim_stack[sim_len];
                    ranges.items[vreg].last_use_pc = pc;
                }
            } else if (block_stack_len > 0) {
                // D-093 (d-12): if-frame end. The per-arch emit's
                // `.end` reads V_else_i's spill slot at the merge
                // MOV PC, so liveness MUST bump V_else_i's
                // last_use_pc to this `.end` PC. (Without this,
                // V_else_0 dies at its def, freeing its slot for
                // V_else_1 to reuse — the merge MOVs then load
                // V_else_0's "slot" which now holds V_else_1's
                // value, and both V_then slots get the same wrong
                // payload. Pre-d-12 surfaced as
                // `if.wast:as-compare-operands` got 0 expected 1
                // — both merge slots collapsed onto V_else_1.)
                //
                // Then replace sim_stack[top..arity) with the
                // captured merge vregs (= V_then_i) so post-if
                // consumers' pops bump V_then_i's last_use_pc.
                // Without this swap, V_then_i would die at its
                // def in then-arm and its slot becomes
                // reusable across the if-frame's body — the
                // post-if consumer would then read whichever
                // later vreg got V_then_i's slot.
                const fr = block_stack[block_stack_len - 1];
                if (fr.is_if and fr.merge_captured and fr.result_arity > 0) {
                    if (sim_len >= @as(usize, fr.result_arity)) {
                        const base = sim_len - @as(usize, fr.result_arity);
                        var i: u32 = 0;
                        while (i < fr.result_arity) : (i += 1) {
                            ranges.items[sim_stack[base + i]].last_use_pc = pc;
                            sim_stack[base + i] = fr.merge_vregs[i];
                        }
                    }
                } else if (fr.is_if and !fr.merge_captured and fr.param_arity > 0 and fr.result_arity > 0) {
                    // D-093 (d-13) — implicit-else (no `.else`).
                    // Canonical post-if vreg is `param_vregs[i]`
                    // (Wasm spec §3.4.4 requires param == result
                    // for valid implicit-else). Bump then-body
                    // result vregs' last_use_pc and replace
                    // sim_stack with param_vregs so the post-if
                    // consumer pops the canonical vreg, extending
                    // its liveness.
                    if (sim_len >= @as(usize, fr.result_arity)) {
                        const base = sim_len - @as(usize, fr.result_arity);
                        var i: u32 = 0;
                        while (i < fr.result_arity) : (i += 1) {
                            ranges.items[sim_stack[base + i]].last_use_pc = pc;
                            sim_stack[base + i] = fr.param_vregs[i];
                        }
                    }
                } else if (!fr.is_if and fr.merge_captured and fr.result_arity > 0) {
                    // D-330 — block-result merge survival. The emit's
                    // `captureOrEmitBlockMergeMov` captured these vregs
                    // (the result operands of the FIRST br/br_if to this
                    // block) as the canonical merge target; `.end` homes
                    // the fall-through result into them. Bump their
                    // last_use_pc to this `.end` and swap them onto the
                    // operand stack so the post-block consumer pops the
                    // canonical vreg. Without this the merge vreg dies at
                    // the branch (range `[def,def]`), so the regalloc may
                    // park it in a callee-saved reg (X20-X22 / RBX-R14)
                    // that an intervening call clobbers — the taken edge
                    // jumps over `.end`'s home MOV, leaving it stale
                    // (c_sha256 dropped the final `\n`). Mirrors the
                    // if/else handling above.
                    //
                    // The case split mirrors `emitEndIntra`. `entry` is the
                    // block's own operand-stack base (entry depth minus the
                    // params it consumed), so the merge vregs are homed at
                    // `entry .. entry + result_arity`.
                    const arity: usize = fr.result_arity;
                    const entry: usize = @as(usize, fr.entry_depth) -| @as(usize, fr.param_arity);
                    if (sim_len < entry + arity) {
                        // The block's only exit is a `br`: its handler drained
                        // the body back to the innermost entry depth, so no
                        // fall-through operand is left to home. The merge
                        // vregs ARE the block's result — emit's `pushed_vregs`
                        // still carries them, so put them back and keep them
                        // live to this `.end`. Without this they die at the
                        // branch and regalloc hands their register to the next
                        // push, which then aliases the block's result
                        // (AssemblyScript `~lib/rt/tlsf.ts` insertBlock's
                        // `slMap[fl] |= 1 << sl` read 1 instead of 0).
                        if (sim_len > entry) sim_len = entry;
                        while (sim_len < entry) : (sim_len += 1) sim_stack[sim_len] = fr.merge_vregs[0];
                        var i: usize = 0;
                        while (i < arity) : (i += 1) {
                            if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
                            ranges.items[fr.merge_vregs[i]].last_use_pc = pc;
                            sim_stack[sim_len] = fr.merge_vregs[i];
                            sim_len += 1;
                        }
                    } else {
                        const base = sim_len - arity;
                        var i: usize = 0;
                        while (i < arity) : (i += 1) {
                            ranges.items[sim_stack[base + i]].last_use_pc = pc;
                            ranges.items[fr.merge_vregs[i]].last_use_pc = pc;
                            sim_stack[base + i] = fr.merge_vregs[i];
                        }
                    }
                }
                block_stack_len -= 1;
                // D-328: a catch-target block's results are delivered by the
                // unwinder, not produced by a ZIR op (the catch branches here
                // with the caught values; the static body's fall-through is the
                // throwing/unreachable path, leaving only dead vregs). Truncate
                // those dead vregs back to the block's entry depth and mint
                // `result_arity` fresh canonical result vregs so the regalloc
                // sizes distinct slots. The JIT emit does the IDENTICAL truncate
                // + mint at this same `.end`, keeping next_vreg in lockstep.
                const bidx: u64 = instr.payload;
                if (bidx < func.blocks.items.len and
                    func.blocks.items[@intCast(bidx)].is_catch_target and
                    fr.result_arity > 0)
                {
                    sim_len = fr.entry_depth;
                    var ci: u32 = 0;
                    while (ci < fr.result_arity) : (ci += 1) {
                        const vreg: u32 = @intCast(ranges.items.len);
                        try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
                        sim_stack[sim_len] = vreg;
                        sim_len += 1;
                    }
                }
            }
            // Mid-function `end` (block/loop/if frame closer) is
            // transparent at the liveness level — values produced
            // inside the block stay on the operand stack and flow
            // naturally to the next consumer. The Wasm validator
            // already enforces stack-shape consistency at block
            // boundaries.
            continue;
        }

        // block / loop / try_table: structural markers — push frame
        // so `.br N` can resolve target depth. `try_table` shares
        // the block-frame discipline (param/result arity packed into
        // `instr.extra` low byte); its catch clauses are handled
        // out-of-band by the emit layer via `func.eh_catch_entries`
        // — liveness treats it as a regular block for stack-effect
        // purposes.
        if (instr.op == .block or instr.op == .loop or instr.op == .try_table) {
            if (block_stack_len == block_stack.len) block_stack = try allocator.realloc(block_stack, block_stack.len * 2);
            // block/loop store result_arity for completeness;
            // merge mechanism here is fall-through-only so
            // merge_vregs are not captured (block-with-br is
            // handled by emit's captureOrEmitBlockMergeMov).
            const result_arity_u: u32 = instr.extra & 0xFF;
            if (result_arity_u > 8) return Error.UnsupportedOp;
            // The block's own params are already on the operand stack at
            // `entry_depth`, so `.end` needs them to find the block's base
            // (mirrors emit's `entry_stack_depth - param_arity`). The mask
            // bounds this to 0..255; `param_vregs` stays unused for
            // block/loop frames (only if-frames re-push params at `.else`).
            const block_param_arity_u: u32 = (instr.extra >> 8) & 0xFF;
            block_stack[block_stack_len] = .{
                .entry_depth = @intCast(sim_len),
                .param_arity = @intCast(block_param_arity_u),
                .result_arity = @intCast(result_arity_u),
                .is_if = false,
                // D-330: a `loop` is a backward-branch target (no
                // forward result merge); only `block`/`try_table`
                // capture merge vregs at the first br/br_if.
                .is_loop = instr.op == .loop,
                .merge_captured = false,
                .param_vregs = undefined,
                .merge_vregs = undefined,
            };
            block_stack_len += 1;
            continue;
        }
        // .else: restore the operand-stack shape the then-arm saw
        // at entry. Truncate sim_stack to entry_depth, then push
        // the captured param vregs back so subsequent else-arm
        // ops update their `last_use_pc` (preventing regalloc from
        // aliasing the param's spill slot with else-arm pushes).
        // Wasm spec §3.4.4 — only valid inside an if_then frame.
        if (instr.op == .@"else") {
            if (block_stack_len > 0) {
                const fr = &block_stack[block_stack_len - 1];
                if (fr.is_if) {
                    // D-093 (d-12) — capture top `result_arity`
                    // vregs as the merge target (mirrors emit's
                    // `.else` `merge_top_vregs` capture). At .end
                    // these become the canonical post-if vregs.
                    if (fr.result_arity > 0 and sim_len >= @as(usize, fr.result_arity)) {
                        const base = sim_len - @as(usize, fr.result_arity);
                        var i: u32 = 0;
                        while (i < fr.result_arity) : (i += 1) {
                            // Bump V_then_i's last_use_pc to the
                            // else-PC (emit captures + later writes
                            // through this slot at the merge MOV).
                            ranges.items[sim_stack[base + i]].last_use_pc = pc;
                            fr.merge_vregs[i] = sim_stack[base + i];
                        }
                        fr.merge_captured = true;
                    }
                    sim_len = fr.entry_depth;
                    var i: u32 = 0;
                    while (i < fr.param_arity) : (i += 1) {
                        if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
                        sim_stack[sim_len] = fr.param_vregs[i];
                        sim_len += 1;
                    }
                }
            }
            continue;
        }

        // if: pops the condition (1 operand), no push.
        // Tolerant pop: in dead code (after br / return /
        // unreachable drained sim_stack to 0), the cond pop is a
        // no-op. Validator already proved the stack shape; we
        // need not re-validate here.
        if (instr.op == .@"if") {
            if (sim_len > 0) {
                sim_len -= 1;
                const cond_vreg = sim_stack[sim_len];
                ranges.items[cond_vreg].last_use_pc = pc;
            }
            // D-093 (d-9): push block_stack AFTER popping the
            // condition so the if-frame's entry depth matches the
            // body's view of the operand stack.
            // D-093 (d-10): capture top `param_arity` vregs (from
            // `(extra >> 8) & 0xFF` — lower.zig packing) so .else
            // can re-push them; cap at 8 to fit Frame.param_vregs.
            if (block_stack_len == block_stack.len) block_stack = try allocator.realloc(block_stack, block_stack.len * 2);
            const param_arity_u: u32 = (instr.extra >> 8) & 0xFF;
            const result_arity_u: u32 = instr.extra & 0xFF;
            if (param_arity_u > 8 or result_arity_u > 8) return Error.UnsupportedOp;
            const param_arity: u8 = @intCast(param_arity_u);
            const result_arity: u8 = @intCast(result_arity_u);
            var param_vregs: [8]u32 = undefined;
            if (param_arity > 0 and sim_len >= @as(usize, param_arity)) {
                const base = sim_len - @as(usize, param_arity);
                var i: u32 = 0;
                while (i < param_arity) : (i += 1) {
                    param_vregs[i] = sim_stack[base + i];
                }
            }
            block_stack[block_stack_len] = .{
                .entry_depth = @intCast(sim_len),
                .param_arity = param_arity,
                .result_arity = result_arity,
                .is_if = true,
                .is_loop = false,
                .merge_captured = false,
                .param_vregs = param_vregs,
                .merge_vregs = undefined,
            };
            block_stack_len += 1;
            continue;
        }

        // Branches: conservative single-pass liveness.
        //   br N           — unconditional. Result values for
        //                     label N stay on the operand stack
        //                     at the target. For us: close every
        //                     vreg currently live (pessimistic;
        //                     forces spill if reused after target).
        //   br_if N        — pop 1 (condition); operand stack
        //                     otherwise unchanged (the K result
        //                     values for label N stay on stack
        //                     for both branch paths).
        //   br_table       — pop 1 (table index); same as br_if.
        //   return         — close all live vregs (function exits).
        //   unreachable    — trap; subsequent code dead.
        //
        // After unconditional branches the rest of the body is
        // dead per Wasm's polymorphic-stack rule. The Wasm
        // validator already accepts dead-code stack
        // arbitrariness; for liveness we just don't touch ranges
        // in that region. Implementation: continue iterating
        // until the matching `end` (the lowerer guarantees one
        // exists per Wasm validator rules); subsequent ops may
        // re-push fresh vregs they themselves define, which we
        // treat conservatively.
        // throw / throw_ref drain the operand stack identically to
        // `unreachable` / `return`: control never reaches subsequent
        // ops at this PC (the throw transfers to a catch landing pad
        // OR escapes the Wasm boundary as uncaught). The catch arm's
        // operand stack is reconstructed at the landing pad by the
        // emit layer; from liveness's straight-line view, the throw
        // is a stack-draining terminator.
        // Wasm spec 3.0 §3.3.8.18-20 (tail-call) — return_call /
        // return_call_indirect / return_call_ref consume the
        // caller's frame and transfer control to the callee; from
        // liveness's straight-line view they drain the operand
        // stack identically to `return` (the args on top become
        // the callee's params, marshalled by the emit layer; every
        // live vreg's last use is at this pc, and control never
        // reaches subsequent ops at this PC). ADR-0113 §A:
        // is_terminator=true, n_successor_edges=0.
        if (instr.op == .@"return" or instr.op == .@"unreachable" or
            instr.op == .throw or instr.op == .throw_ref or
            instr.op == .return_call or instr.op == .return_call_indirect or
            instr.op == .return_call_ref)
        {
            while (sim_len > 0) {
                sim_len -= 1;
                const vreg = sim_stack[sim_len];
                ranges.items[vreg].last_use_pc = pc;
            }
            continue;
        }
        if (instr.op == .br) {
            // D-093 (d-9): close only vregs ABOVE the target
            // label's entry depth. Per Wasm spec §3.4.4 br N
            // discards the intermediate values pushed inside
            // nested blocks (and pops the target's arity at
            // emit-time via merge_top_vregs), but preserves
            // values BELOW the target's entry — those flow to
            // post-block consumers. Pre-d-9, the unconditional
            // drain closed lower values too, causing regalloc
            // to alias their slots with subsequent pushes
            // (e.g. `block:break-inner` got 16/expected 15
            // because V_local0 was killed at a br inside an
            // inner void block then its slot was reused by the
            // `i32.const 0x2` that followed).
            const depth: u32 = @intCast(instr.payload);
            // D-330: capture the targeted block's result operands as
            // its merge vregs (mirrors emit's first-branch
            // captureOrEmitBlockMergeMov). The block's `.end` extends
            // their last_use_pc to the post-block consumer; without
            // this the merge vreg dies at the branch and the regalloc
            // may park it in a callee-saved reg that an intervening
            // call clobbers (c_sha256 `\n`: vreg in X22, clobbered by
            // a putchar call between the branch and the consumer).
            captureBlockMergeVregs(&block_stack, block_stack_len, depth, sim_stack[0..sim_len]);
            // D-330: `br N` is an unconditional terminator — control never
            // falls through; the next reachable code resumes at the `.end`
            // of the INNERMOST currently-open block (its body, or an outer
            // block's body once the inner `.end`s close). The vregs that
            // genuinely die here are only those inside that innermost block
            // (above its entry depth); values BELOW it belong to an
            // enclosing block whose body continues after the structural
            // ends and may still be consumed (e.g. labels.wast `switch`:
            // the `i32.mul`'s `i32.const 10` lhs sits at the outer
            // `$ret` block's base and is read by the post-`$exit` mul, on
            // the br_table fall-out path that skips this `br $ret`).
            // Draining to the br TARGET's entry depth (d-9) over-reached
            // across the enclosing block when the target was an outer
            // block, killing that lhs early -> regalloc aliased its reg
            // with the `$exit` fall-through const (got 25, expected 50).
            // The emit mirrors this: its forward-`br` leaves `pushed_vregs`
            // intact; only the per-block `.end` truncates.
            const innermost_entry: u32 = if (block_stack_len == 0)
                0
            else
                block_stack[block_stack_len - 1].entry_depth;
            while (sim_len > @as(usize, innermost_entry)) {
                sim_len -= 1;
                const vreg = sim_stack[sim_len];
                ranges.items[vreg].last_use_pc = pc;
            }
            continue;
        }
        if (instr.op == .br_if or instr.op == .br_table or instr.op == .br_on_non_null) {
            // Tolerant pop (see if-handler above for rationale).
            // br_on_non_null (10.R) pops the ref like br_if pops the
            // condition: its emit PEEKs the ref to carry it to the label
            // on the non-null branch, then `pop()`s it (the null fall-
            // through discards it). Mirrors the emit's pushed_vregs delta
            // (D-220; lesson 2026-06-02-jit-liveness-must-mirror-emit-pushed-vregs).
            if (sim_len > 0) {
                sim_len -= 1;
                const cond_vreg = sim_stack[sim_len];
                ranges.items[cond_vreg].last_use_pc = pc;
            }
            // D-330: same merge-vreg capture as the `br` handler. For
            // br_if the result operands stay on the stack (both edges),
            // but the captured merge vregs must still survive to the
            // block's `.end` so an intervening call doesn't clobber
            // their callee-saved reg on the taken edge (which jumps
            // over `.end`'s home MOV). br_table targets multiple
            // depths via emitBranchToDepth; capture for the immediate
            // (payload) depth is the common single-result case.
            if (instr.op == .br_if) {
                const depth_bi: u32 = @intCast(instr.payload);
                captureBlockMergeVregs(&block_stack, block_stack_len, depth_bi, sim_stack[0..sim_len]);
            } else if (instr.op == .br_table) {
                // br_table encoding (op_control.emitBrTable): payload=COUNT,
                // extra=start; case depths = branch_targets[start..start+count],
                // default = branch_targets[start+count]. Capture for EVERY target
                // depth. (The prior bug used payload (the count) as a single depth
                // → captured the wrong block + missed the real targets → x86_64
                // labels.wast switch got 25 not 50.)
                const count: u32 = @intCast(instr.payload);
                const start: u32 = @intCast(instr.extra);
                const targets = func.branch_targets.items;
                if (start + count < targets.len) {
                    var t: u32 = 0;
                    while (t <= count) : (t += 1) {
                        captureBlockMergeVregs(&block_stack, block_stack_len, targets[start + t], sim_stack[0..sim_len]);
                    }
                }
            }
            continue;
        }

        // D-093 (d-3): `local.tee` is operand-stack-transparent.
        // The per-arch emit doesn't pop or push — it STRs the
        // top vreg's register into the local slot and leaves the
        // vreg on the operand stack. The generic stackEffect
        // (.pops=1, .pushes=1) path would close the original
        // vreg's range AND fabricate a fresh vreg, opening a
        // window where the original vreg's slot can be reused
        // by a subsequent push (e.g. the right-hand operand of
        // an i32.add). Wasm spec §4.4.5.3 — local.tee is "set
        // and propagate"; the propagation IS the same value.
        //
        // Pre-d-3 surfaced as the `local_tee` cluster (8 spec
        // failures: `as-binary-left` got 20 expected 13 = `op1 +
        // op1` because the right-hand vreg was given the
        // closed-vreg's slot, clobbering op1 before the add
        // read it).
        // br_on_cast / br_on_cast_fail / br_on_null are operand-stack-
        // TRANSPARENT like local.tee: their emit PEEKs the ref (br_on_cast)
        // or pop()s-then-re-append()s the SAME vreg (br_on_null), so the top
        // vreg stays — it's both the fall-through value and (via the branch
        // merge) the label result. Generic 1→1 would close it + fabricate a
        // fresh vreg → reuse window (D-220; lesson 2026-06-02-jit-liveness-
        // must-mirror-emit-pushed-vregs).
        // ref.as_non_null has br_on_null's emit shape exactly — pop, null-
        // check, re-append the SAME vreg — so it belongs here too, and its
        // emit READS that vreg's register at this pc (the TEST/CMP), which
        // is what the last-use extension records (#245).
        if (instr.op == .@"local.tee" or instr.op == .br_on_cast or
            instr.op == .br_on_cast_fail or instr.op == .br_on_null or
            instr.op == .@"ref.as_non_null")
        {
            if (sim_len > 0) {
                const top_vreg = sim_stack[sim_len - 1];
                ranges.items[top_vreg].last_use_pc = pc;
            }
            continue;
        }

        // call / call_indirect / call_ref: pop callee-sig.params, push
        // callee-sig.results. call_ref (Wasm 3.0 §3.3.8.13) takes the
        // signature from `module_types[payload]` like call_indirect, and
        // pops a funcref off the top before the params (like
        // call_indirect pops the table index). NON-terminator.
        if (instr.op == .call or instr.op == .call_indirect or instr.op == .call_ref) {
            const callee_sig: zir.FuncType = blk: {
                if (instr.op == .call) {
                    if (instr.payload >= func_sigs.len) {
                        std.debug.print("liveness: UnsupportedOp[call-payload-OOB] payload={d} func_sigs.len={d} func_idx={d}\n", .{ instr.payload, func_sigs.len, func.func_idx });
                        return Error.UnsupportedOp;
                    }
                    break :blk func_sigs[instr.payload];
                } else {
                    if (instr.payload >= module_types.len) {
                        std.debug.print("liveness: UnsupportedOp[call_indirect/call_ref-payload-OOB] payload={d} types.len={d} func_idx={d}\n", .{ instr.payload, module_types.len, func.func_idx });
                        return Error.UnsupportedOp;
                    }
                    break :blk module_types[instr.payload];
                }
            };
            // call_indirect's stack at entry is [args..., idx]; call_ref's
            // is [args..., funcref]. Pop that top operand first. Tolerant:
            // dead-code pops are no-ops (validator proved shape).
            if (instr.op == .call_indirect or instr.op == .call_ref) {
                if (sim_len > 0) {
                    sim_len -= 1;
                    const top_vreg = sim_stack[sim_len];
                    ranges.items[top_vreg].last_use_pc = pc;
                }
            }
            // Pop N args (in reverse stack order). Best-effort:
            // pop only as many as actually present.
            const n_args: usize = callee_sig.params.len;
            var ai: usize = 0;
            while (ai < n_args and sim_len > 0) : (ai += 1) {
                sim_len -= 1;
                const arg_vreg = sim_stack[sim_len];
                ranges.items[arg_vreg].last_use_pc = pc;
            }
            // Push results.
            for (callee_sig.results) |_| {
                const vreg: u32 = @intCast(ranges.items.len);
                try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
                if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
                sim_stack[sim_len] = vreg;
                sim_len += 1;
            }
            continue;
        }

        // struct.new (§3.3.5.6.1) / array.new_fixed (§3.3.5.6.8): variadic
        // — pop `extra` operands (the field/element count, stamped by the
        // lowerer since the opcode immediate doesn't reach liveness), push
        // 1 GcRef. NON-terminator. Like `call`, the count isn't fixed per
        // opcode, so it can't live in `stackEffect`. Best-effort pop:
        // dead-code pops silently no-op (validator proved the shape).
        if (instr.op == .@"struct.new" or instr.op == .@"array.new_fixed") {
            const n_fields: usize = instr.extra;
            var fi: usize = 0;
            while (fi < n_fields and sim_len > 0) : (fi += 1) {
                sim_len -= 1;
                const fvreg = sim_stack[sim_len];
                ranges.items[fvreg].last_use_pc = pc;
            }
            const vreg: u32 = @intCast(ranges.items.len);
            try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
            if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
            sim_stack[sim_len] = vreg;
            sim_len += 1;
            continue;
        }

        if (isControlFlow(instr.op)) return Error.UnsupportedControlFlow;

        const eff = stackEffect(instr.op) orelse {
            std.debug.print("liveness: UnsupportedOp[stackEffect-missing] op={s} func_idx={d}\n", .{ @tagName(instr.op), func.func_idx });
            return Error.UnsupportedOp;
        };

        // Pop side first — record last_use for each vreg
        // consumed. Best-effort: in dead code (validator-cleared,
        // post-br/unreachable region), pops silently no-op.
        var i: u8 = 0;
        while (i < eff.pops and sim_len > 0) : (i += 1) {
            sim_len -= 1;
            const vreg = sim_stack[sim_len];
            ranges.items[vreg].last_use_pc = pc;
        }

        // Push side — open a fresh vreg per produced value.
        i = 0;
        while (i < eff.pushes) : (i += 1) {
            const vreg: u32 = @intCast(ranges.items.len);
            try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
            if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
            sim_stack[sim_len] = vreg;
            sim_len += 1;
        }
    }

    // ADR-0155 stage 1 (fix A — APPEND): mint K function-spanning pseudo-vregs
    // for the register-homed locals AFTER every temporary vreg, so temporary
    // numbering is unchanged (no block/if/br arithmetic above is touched). Each
    // pseudo-vreg's range is the whole function (def at prologue=pc 0, last_use
    // at the final instr) so regalloc never reclaims its slot — it stays
    // register-resident across the loop back-edge (the D-265 win). Regalloc
    // prioritises these high-id vregs onto low register slots.
    const homing = local_homing.plan(func);
    if (homing.count > 0 and func.instrs.items.len > 0) {
        const last_pc: u32 = @intCast(func.instrs.items.len - 1);
        var r: u32 = 0;
        while (r < homing.count) : (r += 1) {
            try ranges.append(allocator, .{ .def_pc = 0, .last_use_pc = last_pc });
        }
    }

    return .{ .ranges = try ranges.toOwnedSlice(allocator) };
}

pub fn deinit(allocator: Allocator, info: Liveness) void {
    if (info.ranges.len != 0) allocator.free(info.ranges);
}

const testing = std.testing;

fn buildFunc(allocator: Allocator, ops: []const ZirInstr) !ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    errdefer f.deinit(allocator);
    for (ops) |o| try f.instrs.append(allocator, o);
    return f;
}

test "compute: straight-line i32.const + i32.const + i32.add + drop + end" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.add" },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 3), live.ranges.len);
    // vreg 0: pushed at pc 0, consumed by add at pc 2.
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[0].last_use_pc);
    // vreg 1: pushed at pc 1, consumed by add at pc 2.
    try testing.expectEqual(@as(u32, 1), live.ranges[1].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[1].last_use_pc);
    // vreg 2: produced by add at pc 2, consumed by drop at pc 3.
    try testing.expectEqual(@as(u32, 2), live.ranges[2].def_pc);
    try testing.expectEqual(@as(u32, 3), live.ranges[2].last_use_pc);
}

test "compute: function-level end closes the still-live vreg" {
    // i32.const 7 ; end -> vreg 0 def=0 last_use=1 (closed by end)
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 7 },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 1), live.ranges[0].last_use_pc);
}

test "compute: D-093 (d-3) local.tee keeps the input vreg alive across the tee" {
    // local.get 0 ; local.tee 1 ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"local.get", .payload = 0 },
        .{ .op = .@"local.tee", .payload = 1 },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    // local.tee is operand-stack-transparent (matches emit's
    // "STR top → local slot, no pop/push" semantics). Only one
    // vreg exists across local.get → local.tee → drop; its
    // last_use_pc extends from the tee through to the drop.
    // Pre-d-3 there were 2 vregs (local.tee fabricated a fresh
    // push); the original vreg's slot got reused by subsequent
    // pushes (the local_tee cluster bug).
    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[0].last_use_pc);
}

test "compute: br closes all live vregs at branch site (sub-7.5c-iv)" {
    // (i32.const 1) (br) (end) — `br` is now handled, not rejected.
    // The const's vreg should have last_use_pc == br's pc.
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .br },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer testing.allocator.free(live.ranges);
    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 1), live.ranges[0].last_use_pc); // br at pc=1
}

test "compute: pop on empty stack is tolerant (validator-cleared dead-code path)" {
    // Liveness trusts the validator's prior pass for stack-shape
    // validity. A pop on an empty stack — only reachable via the
    // dead-code zone after an unconditional branch — is a no-op
    // here, not an error. See §9.7 / 7.5-block-result-deadcode.
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer testing.allocator.free(live.ranges);
    try testing.expectEqual(@as(usize, 0), live.ranges.len);
}

test "compute: dead code after `br 0` does not underflow" {
    // Real-world repro from spec/wasm-1.0/labels.0.wasm:
    //   block (result i32) i32.const 1 ; br 0 ; i32.const 0 end
    // After `br 0` the stack drains; `i32.const 0` (dead code)
    // pushes a fresh vreg. The matching `end` is the
    // function-level end (block / function share `end` op since
    // the block-result path collapses).
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .block },
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .br, .payload = 0 },
        .{ .op = .@"i32.const", .payload = 0 },
        .{ .op = .end },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    // Should compute successfully — no underflow on the dead
    // i32.const after the br.
    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer testing.allocator.free(live.ranges);
    // Two i32.const pushes → 2 vreg ranges.
    try testing.expectEqual(@as(usize, 2), live.ranges.len);
}

test "compute: select consumes 3 vregs and produces 1" {
    // i32.const 1 ; i32.const 2 ; i32.const 0 ; select ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.const", .payload = 0 },
        .{ .op = .select },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 4), live.ranges.len);
    // The three operands all close at pc 3 (select), and select's
    // result vreg lives until drop at pc 4.
    for (live.ranges[0..3]) |r| {
        try testing.expectEqual(@as(u32, 3), r.last_use_pc);
    }
    try testing.expectEqual(@as(u32, 3), live.ranges[3].def_pc);
    try testing.expectEqual(@as(u32, 4), live.ranges[3].last_use_pc);
}

test "compute: install onto ZirFunc.liveness slot round-trips" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 5 },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    f.liveness = try compute(testing.allocator, &f, &.{}, &.{});
    defer if (f.liveness) |li| deinit(testing.allocator, li);

    try testing.expect(f.liveness != null);
    try testing.expectEqual(@as(usize, 1), f.liveness.?.ranges.len);
}
