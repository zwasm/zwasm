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
//! Two places where the models legitimately differ, both reconstructible from
//! state the emit already holds:
//!
//!   1. Dead code. An unconditional terminator drains liveness's `sim_stack`;
//!      the emit sets `dead_code` and freezes `pushed_vregs` until the `.end`
//!      or `.else` that clears it. Skipped via the caller's own flag.
//!   2. The else arm of an `if (result T…)` with no params. `emitElse`
//!      captures the then-arm's top `result_arity` vregs as the merge target
//!      and leaves them ON `pushed_vregs`; liveness's `.else` truncates to the
//!      frame's entry depth and drops them. `expected()` deletes them again,
//!      driven by the emit's own label stack.
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
/// Reach: the CLI, the C API, and the test runners that call `dbg.initFromEnv`
/// at startup — `scripts/check_runner_dbg_init.sh` holds that line, and the
/// files it exempts say why in their first lines. One lane runs with the
/// channel on: `test-spec-wasm-3.0-assert-liveverify` (ADR-0226); its runner
/// reads `takeResiduals` below and gates on the count. This module does not
/// read the env itself, which Zone 2 cannot do without pulling `std.c.getenv`
/// out of its one Zone 3 call site.
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

/// Residual lines printed since the last `takeResiduals`. Written only on
/// the mismatch path of `check`, read by the spec runner after each module's
/// compile (ADR-0226 D3). Single-threaded by construction: the JIT compiles
/// one module at a time and the runner reads between modules.
var residuals: u32 = 0;

/// Read-and-reset. The count is what the liveverify lane gates on; `check`'s
/// print stays for the person fixing the row.
pub fn takeResiduals() u32 {
    const n = residuals;
    residuals = 0;
    return n;
}

/// Compare the operand stack entering instr `pc`. Prints, counts and returns
/// on a mismatch — the print is a diagnostic mirroring `ZWASM_DEBUG=regverify`,
/// the count is the lane's (ADR-0226).
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
    dead_code: bool,
) void {
    if (!compiled_in) return;
    if (dead_code) return;
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

    residuals += 1;
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
