//! Debug-gated check that `liveness.compute`'s operand-stack simulation still
//! agrees with what the per-arch emit does to `ctx.pushed_vregs` (D-596).
//!
//! The two are independent hand-maintained models of one fact. When they
//! disagree the vreg numbering desyncs, regalloc aliases slots, and the JIT
//! returns wrong values with no trap and no diagnostic — four times so far
//! (D-093 d-3 `local.tee`, D-220 `any.convert_extern`, D-330 block merge,
//! #245 `ref.as_non_null`, #250 br-only block, #253 if-merge + `unreachable`).
//!
//! What is compared is the **vreg identity vector**, not its length. Measured
//! on the four historical events: a depth-only comparison catches #250 alone —
//! D-330, #245 and two of #253's three shapes are depth-neutral and only show
//! up as a differing vreg id.
//!
//! One place where the models legitimately differ, reconstructible from
//! state the emit already holds:
//!
//!   1. The else arm of an `if (result T…)` with no params. `emitElse`
//!      captures the then-arm's top `result_arity` vregs as the merge target
//!      and leaves them ON `pushed_vregs`; liveness's `.else` truncates to the
//!      frame's entry depth and drops them. `expected()` deletes them again,
//!      driven by the emit's own label stack.
//!
//! Dead code is not one of them any more. A terminator pops what the op
//! consumes and then leaves the stack alone on both sides — the emit by
//! freezing `pushed_vregs` under `dead_code`, liveness by closing ranges
//! without popping — so the `.end` or `.else` that clears the flag (the
//! next pc, since the lowerer prunes the dead body) sees one frozen stack
//! on each side and is compared like any other pc.
//!
//! Zone 2 (`engine/`); reads Zone 1 `ir/` downward, which the layering allows.

const std = @import("std");
const builtin = @import("builtin");

const dbg = @import("../../../support/dbg.zig");
const zir = @import("../../../ir/zir.zig");
const liveness = @import("../../../ir/analysis/liveness.zig");

/// Comptime-dead in the release modes `dbg` is comptime-dead in, so the call
/// site collapses to nothing there.
pub const compiled_in: bool =
    builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// Hoist this out of the emit loop; `dbg.on` is a whitelist walk.
///
/// Reach: the CLI, today. `dbg.initFromEnv` is called from `cli/main.zig` and
/// `api/instance.zig` only, and no test runner reaches either, so the channel
/// is dark for the whole of `zig build test-all`. Lane coverage arrives when
/// that gap closes; this module does not read the env itself, which Zone 2
/// cannot do without pulling `std.c.getenv` out of its one Zone 3 call site.
pub fn on() bool {
    if (!compiled_in) return false;
    return dbg.on("liveverify");
}

/// The liveness snapshot and this check must agree on both the buffer bound
/// and the hash, so both come from the producer rather than being mirrored
/// here. A second copy of either would be the D-596 failure mode inside the
/// D-596 diagnostic.
const max_stack: usize = liveness.max_simulated_stack;
const digest = liveness.snapshotDigest;

/// Compare the operand stack entering instr `pc`. Prints and returns on a
/// mismatch — a diagnostic, not a gate, mirroring `ZWASM_DEBUG=regverify`.
///
/// `labels` is the emit's own label stack; both arches' `Label` carries the
/// same `kind` / `merge_captured` / `result_arity` / `param_arity` /
/// `entry_stack_depth` fields, so `anytype` fits both without a shared type.
pub fn check(
    func: *const zir.ZirFunc,
    pc: usize,
    op: zir.ZirOp,
    pushed_vregs: []const u32,
    labels: anytype,
) void {
    if (!compiled_in) return;
    const lv = func.liveness orelse return;
    if (pc >= lv.stack_depth.len) return;

    var expect: [max_stack]u32 = undefined;
    var len: usize = 0;
    for (pushed_vregs) |v| {
        if (len == expect.len) return; // deeper than liveness can model
        expect[len] = v;
        len += 1;
    }
    // Delete each else-arm's captured merge vregs, outermost frame first —
    // every deletion shifts the inner frames' recorded bases down by `removed`.
    var removed: usize = 0;
    for (labels) |lb| {
        if (lb.kind != .else_open or !lb.merge_captured or lb.result_arity == 0) continue;
        if (lb.param_arity != 0) continue; // emitElse already dropped them
        const base: usize = @as(usize, lb.entry_stack_depth) -| @as(usize, lb.param_arity);
        const at: usize = base -| removed;
        const n: usize = lb.result_arity;
        if (at + n > len) continue;
        std.mem.copyForwards(u32, expect[at .. len - n], expect[at + n .. len]);
        len -= n;
        removed += n;
    }

    if (len == lv.stack_depth[pc] and digest(expect[0..len]) == lv.stack_digest[pc]) return;

    std.debug.print(
        "[liveverify] func[{d}] pc={d} op={s}: liveness depth={d} digest={x}, emit depth={d} digest={x} (raw {d})\n",
        .{
            func.func_idx,          pc,                  @tagName(op),
            lv.stack_depth[pc],     lv.stack_digest[pc], len,
            digest(expect[0..len]), pushed_vregs.len,
        },
    );
    std.debug.print("[liveverify]   emit pushed_vregs={any}\n", .{pushed_vregs});
}
