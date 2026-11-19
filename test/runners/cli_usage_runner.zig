// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig).
//! `zwasm run`'s option parsing, observed from outside (#236, #232). Options
//! precede the module path, so an unknown one is a usage error (exit 2) — not
//! a module path that cannot be read (exit 1) — and `--` ends them. Anything
//! after the path is the guest's argv, even when it spells a known option.
//! And which engine runs a SIMD module, said where the run fails (#597).
//! `--timeout` fires while the guest sleeps in `poll_oneoff` (#598).
//! An f32 param with three results is refused by the JIT, not misread (#618).
//! A component reaches the host's network only with `--allow-network`.
//! A catch clause whose label is a loop branches to the loop's header (#369).
//! A catch clause whose label is the function's own label returns the delivered
//! values.
//! An `if` whose then-arm ends in `unreachable` returns the else arm's value
//! on every engine (#739). A block that closes short of its f64 result
//! before any vreg exists traps on every engine (#399). An `if` with no else
//! whose then arm branches to the `if`'s own label gives its params on cond=0
//! and the branch's values on cond=1, on every engine. Two edges into one
//! merge whose values sit in each other's places each deliver their own
//! values: a block's and an `if`'s on every engine, a loop's on the JIT;
//! the edge may be a `br_on_*`. `br_on_null` to a loop branches when its
//! operand is null, with and without a fuel budget.
//! `throw_ref` of a null exnref traps on every engine, caught or not (#745).
//!
//! Usage: `zig build test-cli-usage` /
//!        `zwasm-cli-usage <zwasm-cli> <module.wasm> <argv_echo.wasm>
//!         <simd_op.wasm> <simd_jit_decline.wasm> <select_v128_spilled_val2.wasm>
//!         <poll_sleep.wasm> <f32_param_three_results.wasm>
//!         <wasi_p2_tcp_rust.wasm> <catch_to_loop.wasm>
//!         <catch_to_loop_ref_result.wasm> <catch_to_loop_params.wasm>
//!         <catch_to_loop_unset_params.wasm> <if_dead_then_arm.wasm>
//!         <short_frame_f64.wasm> <if_branch_own_label.wasm> <catch_to_func.wasm>
//!         <catch_all_to_func.wasm> <merge_moves.wasm> <merge_moves_v128.wasm>
//!         <merge_moves_br_on.wasm> <merge_moves_br_on_null_loop.wasm>
//!         <br_on_null_loop.wasm> <throw_ref_null.wasm> <gc_alloc_trap.wasm>
//!         <gc_v128_array_new.wasm>`

const std = @import("std");
const builtin = @import("builtin");
const spawned_cli = @import("spawned_cli");

const Match = union(enum) {
    any,
    has: []const u8,
    is: []const u8,

    fn ok(m: Match, s: []const u8) bool {
        return switch (m) {
            .any => true,
            .has => |n| std.mem.find(u8, s, n) != null,
            .is => |e| std.mem.eql(u8, s, e),
        };
    }
};

const Row = struct {
    args: []const []const u8,
    exit: u8,
    stdout: Match = .any,
    stderr: Match = .any,
};

/// Stand-ins for the module paths, in argument order: a `_start` that does
/// nothing, one that echoes argv[1..] a line each, one SIMD op, a SIMD module
/// the JIT declines, #596's select, a 5 s sleep in `poll_oneoff`, #618's
/// `(f32) -> (i32 i32 i32)`, a Rust wasip2 TCP client, #369's catch clauses
/// that target a loop (without params, with a result, with params, and with a
/// param the stack never held a value for), #739's two `if`s, #399's block,
/// an `if` with no else whose then arm branches to its own label, two catch
/// clauses that target the function's label, and frames whose edges deliver
/// values that sit in each other's places (the v128 loop in a module of its
/// own, and the `br_on_*` edges in two more), and a loop with no params
/// whose back edge is a `br_on_null`, and #745's `throw_ref` of a null
/// exnref under each kind of clause, #364's two array.new* exports that ask
/// for a ~8 GiB array, and #364/D-495's v128-element array.new the JIT
/// declines.
const M = "<module>";
const E = "<argv_echo>";
const S = "<simd_op>";
const D = "<simd_jit_decline>";
const V = "<select_spill>";
const P = "<poll_sleep>";
const F = "<f32_three>";
const T = "<tcp_client>";
const L = "<catch_to_loop>";
const R = "<catch_to_loop_ref_result>";
const Q = "<catch_to_loop_params>";
const U = "<catch_to_loop_unset_params>";
const I = "<if_dead_then>";
const B = "<short_frame>";
const O = "<if_branch_own_label>";
const C = "<catch_to_func>";
const A = "<catch_all_to_func>";
const G = "<merge_moves>";
const W = "<merge_moves_v128>";
const K = "<merge_moves_br_on>";
const N = "<merge_moves_br_on_null_loop>";
const Y = "<br_on_null_loop>";
const Z = "<throw_ref_null>";
const H = "<gc_alloc_trap>";
const X = "<gc_v128_array_new>";
const placeholders = [_][]const u8{ M, E, S, D, V, P, F, T, L, R, Q, U, I, B, O, C, A, G, W, K, N, Y, Z, H, X };

const all_engines = [_][]const []const u8{ &.{ "--engine", "interp" }, &.{ "--engine", "jit" }, &.{} };
/// The interpreter traps on some loops with params (#244).
const jit_engines = all_engines[1..];

/// `run --invoke <name> <module>` on each engine, each printing `out`.
fn onEngines(comptime engines: []const []const []const u8, comptime module: []const u8, comptime name: []const u8, comptime out: []const u8) [engines.len]Row {
    var r: [engines.len]Row = undefined;
    for (engines, &r) |e, *row| row.* = .{ .args = &(.{"run"} ++ e[0..e.len].* ++ .{ "--invoke", name, module }), .exit = 0, .stdout = .{ .is = out } };
    return r;
}

/// `onEngines` for each `{ invocation, output }` of `list`.
fn eachOn(comptime engines: []const []const []const u8, comptime module: []const u8, comptime list: []const [2][]const u8) [engines.len * list.len]Row {
    var r: [engines.len * list.len]Row = undefined;
    for (list, 0..) |c, i| r[i * engines.len ..][0..engines.len].* = onEngines(engines, module, c[0], c[1]);
    return r;
}

/// `merge_moves_br_on_null_loop`: the same back edge as a `br_on_null`,
/// whose condition arm64 holds in the register the moves park in. The x86_64
/// JIT declines `br_on_null` to a loop.
const null_loop_rows = if (builtin.cpu.arch == .x86_64) [_]Row{
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "null_loop=1", N }, .exit = 1, .stderr = .{ .has = "UnsupportedOp" } },
} else eachOn(jit_engines, N, &.{
    .{ "null_loop=1", "292236\n" },     .{ "null_loop=0", "223629\n" },
    .{ "null_loop_f64=1", "292236\n" }, .{ "null_loop_f64=0", "223629\n" },
});

/// The engines with a fuel budget, which a loop's back edge polls.
const metered_engines = [_][]const []const u8{ &.{ "--fuel", "100000", "--engine", "interp" }, &.{ "--fuel", "100000", "--engine", "jit" }, &.{ "--fuel", "100000" } };

/// `br_on_null_loop`: `br_on_null` as the back edge of a loop with no params.
/// `passes` returns how many times the body ran: the edge is taken once when
/// its argument is set. The x86_64 JIT declines `br_on_null` to a loop, and
/// the default engine then runs the interpreter.
const null_back_edge_passes = [_][2][]const u8{ .{ "passes=1", "2\n" }, .{ "passes=0", "1\n" } };
const null_back_edge_rows = if (builtin.cpu.arch == .x86_64)
    eachOn(&.{ all_engines[0], all_engines[2], metered_engines[0], metered_engines[2] }, Y, &null_back_edge_passes) ++ [_]Row{
        .{ .args = &.{ "run", "--engine", "jit", "--invoke", "passes=1", Y }, .exit = 1, .stderr = .{ .has = "UnsupportedOp" } },
    }
else
    eachOn(&(all_engines ++ metered_engines), Y, &null_back_edge_passes);

/// Every export of `throw_ref_null.wat` on each engine setting: exit 1 with
/// `null_reference`, and nothing printed, since no clause catches it.
const throw_ref_rows = blk: {
    const exports = [_][]const u8{ "plain", "catch_all", "catch_all_ref", "catch_tag_i32", "catch_tag_funcref", "catch_ref_tag_i32" };
    var out: [all_engines.len * exports.len]Row = undefined;
    for (all_engines, 0..) |engine, i| {
        for (exports, 0..) |name, j| {
            const args = [_][]const u8{"run"} ++ engine[0..engine.len].* ++ [_][]const u8{ "--invoke", name, Z };
            out[i * exports.len + j] = .{ .args = &args, .exit = 1, .stdout = .{ .is = "" }, .stderr = .{ .has = "trap kind=null_reference" } };
        }
    }
    const final = out;
    break :blk final;
};

const rows = [_]Row{
    .{ .args = &.{ "run", "--bogus", M }, .exit = 2, .stderr = .{ .has = "unknown option '--bogus'" } },
    .{ .args = &.{ "run", "-bogus", M }, .exit = 2, .stderr = .{ .has = "unknown option '-bogus'" } },
    .{ .args = &.{ "run", "--invok", "add", M }, .exit = 2, .stderr = .{ .has = "unknown option '--invok'" } },
    .{ .args = &.{ "run", "--invoke", "--bogus", M }, .exit = 2, .stderr = .{ .has = "usage: zwasm run --invoke" } },
    .{ .args = &.{ "run", "--dir", "--bogus", M }, .exit = 2, .stderr = .{ .has = "usage: zwasm run --dir" } },
    .{ .args = &.{ "run", "--", M }, .exit = 0 },
    .{ .args = &.{ "run", E, "--engine", "jit" }, .exit = 0, .stdout = .{ .is = "--engine\njit\n" }, .stderr = .{ .is = "" } },
    .{ .args = &.{"--help"}, .exit = 0, .stdout = .{ .has = "run [options]" } },
    .{ .args = &.{ "run", "--engine", "interp", S }, .exit = 1, .stderr = .{ .has = "the interpreter does not execute `v128.const`" } },
    .{ .args = &.{ "run", D }, .exit = 1, .stderr = .{ .has = "`return_call` with a 3-result callee\nthe interpreter does not execute `v128.const`" } },
    .{ .args = &.{ "run", "--invoke", "test", V }, .exit = 0, .stdout = .{ .is = "63\n" } },
    .{ .args = &.{ "run", "--timeout", "500", "--engine", "interp", P }, .exit = 1, .stderr = .{ .has = "interrupted" } },
    .{ .args = &.{ "run", "--timeout", "500", "--engine", "jit", P }, .exit = 1, .stderr = .{ .has = "interrupted" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "f=2.5", F }, .exit = 0, .stdout = .{ .is = "7\n250\n2500\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "f=2.5", F }, .exit = 1, .stderr = .{ .has = "unsupported entry signature" } },
    .{ .args = &.{ "run", "--invoke", "f=2.5", F }, .exit = 1, .stderr = .{ .has = "unsupported" } },
    // Nothing listens on loopback port 1, so a granted connect is refused by
    // the peer; a listener row would hang on accept once the gate broke.
    .{ .args = &.{ "run", T, "1" }, .exit = 1, .stderr = .{ .has = "connect failed: Os { code: 2, kind: PermissionDenied" } },
    .{ .args = &.{ "run", "--allow-network", T, "1" }, .exit = 1, .stderr = .{ .has = "connect failed: Os { code: 14, kind: ConnectionRefused" } },
    // A catch whose loop param the stack never held a value for: the JIT once
    // declined it (the param was the placeholder vreg), but since #399 the
    // frame mints a real vreg for it, so the JIT runs the shape and traps on
    // the `unreachable` it reaches, as the interpreter does.
    .{ .args = &.{ "run", "--engine", "interp", U }, .exit = 1, .stderr = .{ .has = "trap kind=unreachable_" } },
    .{ .args = &.{ "run", "--engine", "jit", U }, .exit = 1, .stderr = .{ .has = "trap kind=unreachable_" } },
    .{ .args = &.{ "run", U }, .exit = 1, .stderr = .{ .has = "trap kind=unreachable_" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "else_arm=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "else_arm=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--invoke", "else_arm=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "ref_result=0", I }, .exit = 0, .stdout = .{ .is = "47\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "ref_result=0", I }, .exit = 0, .stdout = .{ .is = "47\n" } },
    .{ .args = &.{ "run", "--invoke", "ref_result=0", I }, .exit = 0, .stdout = .{ .is = "47\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "param_else=0", I }, .exit = 0, .stdout = .{ .is = "45\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "param_else=0", I }, .exit = 0, .stdout = .{ .is = "45\n" } },
    .{ .args = &.{ "run", "--invoke", "param_else=0", I }, .exit = 0, .stdout = .{ .is = "45\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "param_else_only=0", I }, .exit = 0, .stdout = .{ .is = "15\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "param_else_only=0", I }, .exit = 0, .stdout = .{ .is = "15\n" } },
    .{ .args = &.{ "run", "--invoke", "param_else_only=0", I }, .exit = 0, .stdout = .{ .is = "15\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "param_brif=0,0", I }, .exit = 0, .stdout = .{ .is = "340\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "param_brif=0,0", I }, .exit = 0, .stdout = .{ .is = "340\n" } },
    .{ .args = &.{ "run", "--invoke", "param_brif=0,0", I }, .exit = 0, .stdout = .{ .is = "340\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "implicit_else=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "implicit_else=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--invoke", "implicit_else=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "f", B }, .exit = 1, .stderr = .{ .has = "kind=unreachable" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "f", B }, .exit = 1, .stderr = .{ .has = "kind=unreachable" } },
    .{ .args = &.{ "run", "--invoke", "f", B }, .exit = 1, .stderr = .{ .has = "kind=unreachable" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "else_short=1", B }, .exit = 0, .stdout = .{ .is = "17\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "else_short=1", B }, .exit = 0, .stdout = .{ .is = "17\n" } },
    .{ .args = &.{ "run", "--invoke", "else_short=1", B }, .exit = 0, .stdout = .{ .is = "17\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "else_unreachable=1", B }, .exit = 0, .stdout = .{ .is = "115\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "else_unreachable=1", B }, .exit = 0, .stdout = .{ .is = "115\n" } },
    .{ .args = &.{ "run", "--invoke", "else_unreachable=1", B }, .exit = 0, .stdout = .{ .is = "115\n" } },
} ++ onEngines(&all_engines, L, "catch_to_loop", "3\n") ++
    onEngines(&all_engines, L, "catch_to_block", "1\n") ++
    onEngines(&all_engines, L, "catch_all_to_loop", "3\n") ++
    onEngines(&all_engines, L, "catch_to_outer_loop", "3\n") ++
    onEngines(&all_engines, R, "test", "42\n") ++
    onEngines(jit_engines, Q, "payload_to_loop", "3\n") ++
    onEngines(jit_engines, Q, "f64_payload_to_loop", "4.5\n") ++
    onEngines(&all_engines, Q, "catch_ref_to_loop", "10\n") ++
    // cond=0: the params are the results. cond=1: the branch carries them.
    onEngines(&all_engines, O, "i32_result=0", "150\n") ++
    onEngines(&all_engines, O, "i32_result=1", "107\n") ++
    onEngines(&all_engines, O, "ref_result=0", "100\n") ++
    onEngines(&all_engines, O, "ref_result=1", "101\n") ++
    // A catch clause whose label is the function's own label returns the
    // delivered values on every engine: `catch_to_func` returns the tag's
    // payload (77); the `catch_all` form returns with no values (exit 0, no
    // output).
    onEngines(&all_engines, C, "D1", "77\n") ++
    onEngines(&all_engines, A, "D1", "") ++
    // `merge_moves`: each export folds its frame's results as r0 + 100*r1
    // (+ 10000*r2). A block's fall-through leaves [22 29 36] where its
    // `br_if` carries [29 36 57]; the same with two f64s.
    onEngines(&all_engines, G, "block=0", "362922\n") ++
    onEngines(&all_engines, G, "block=1", "573629\n") ++
    onEngines(&all_engines, G, "block_f64=0", "2922\n") ++
    onEngines(&all_engines, G, "block_f64=1", "5729\n") ++
    // A then arm reaches `else` with [22 29] after its `br_if` carried [29 57].
    onEngines(&all_engines, G, "if_then=1,0", "2922\n") ++
    onEngines(&all_engines, G, "if_then=1,1", "5729\n") ++
    // An else arm reaches `end` with [29 57] where the then arm's `br_if`
    // carries [22 29].
    onEngines(&all_engines, G, "if_else=0,0", "5729\n") ++
    onEngines(&all_engines, G, "if_else=1,1", "2922\n") ++
    // An else arm's `br_if` carries [22 29] where the then arm's `br` carries
    // [29 57], as f64.
    onEngines(&all_engines, G, "if_f64=0,1", "2922\n") ++
    onEngines(&all_engines, G, "if_f64=1,0", "5729\n") ++
    // A loop's back edge carries [29 57] into its params [22 29]; then one
    // that carries the params back in each other's place, as i32 and as v128.
    onEngines(jit_engines, G, "loop=1", "5729\n") ++
    onEngines(jit_engines, G, "loop=0", "2922\n") ++
    onEngines(jit_engines, G, "loop_swap=1", "2922\n") ++
    onEngines(jit_engines, G, "loop_swap=0", "2229\n") ++
    onEngines(jit_engines, W, "loop_swap=1", "2922\n") ++
    onEngines(jit_engines, W, "loop_swap=0", "2229\n") ++
    // `merge_moves_br_on`: a `br_on_*` is the edge. Into a block (c, n): taken
    // (0,1) it carries [22 29 ..] into the merge a `br_if` named with
    // [29 57 ..]; not taken (0,0) the body leaves [3 4 ..]. A null reference
    // result adds 1000000.
    eachOn(&all_engines, K, &.{
        .{ "null_block=0,1", "2922\n" },             .{ "null_block=0,0", "403\n" },
        .{ "non_null_block=0,1", "2922\n" },         .{ "non_null_block=0,0", "1000403\n" },
        .{ "cast_block=0,1", "2922\n" },             .{ "cast_block=0,0", "1000403\n" },
        .{ "cast_fail_block=0,1", "1002922\n" },     .{ "cast_fail_block=0,0", "403\n" },
        .{ "null_block_f64=0,1", "2922\n" },         .{ "null_block_f64=0,0", "403\n" },
        .{ "non_null_block_f64=0,1", "2922\n" },     .{ "non_null_block_f64=0,0", "1000403\n" },
        .{ "cast_block_f64=0,1", "2922\n" },         .{ "cast_block_f64=0,0", "1000403\n" },
        .{ "cast_fail_block_f64=0,1", "1002922\n" }, .{ "cast_fail_block_f64=0,0", "403\n" },
    }) ++
    // As a loop's back edge, taken once (1) or not (0), it carries
    // [22 29 36] back rotated by one; the moves form a cycle.
    eachOn(jit_engines, K, &.{
        .{ "cast_loop=1", "1292236\n" },         .{ "cast_loop=0", "1223629\n" },
        .{ "cast_fail_loop=1", "292236\n" },     .{ "cast_fail_loop=0", "223629\n" },
        .{ "cast_loop_f64=1", "1292236\n" },     .{ "cast_loop_f64=0", "1223629\n" },
        .{ "cast_fail_loop_f64=1", "292236\n" }, .{ "cast_fail_loop_f64=0", "223629\n" },
    }) ++ null_loop_rows ++ null_back_edge_rows ++ [_]Row{
    // The pad's back-edge poll stops a loop re-entered only through its catch;
    // without it the run ends after 10^8 iterations and prints the count.
    .{ .args = &.{ "run", "--timeout", "500", "--engine", "jit", "--invoke", "catch_all_spin=100000000", L }, .exit = 1, .stderr = .{ .has = "interrupted" } },
    .{ .args = &.{ "run", "--fuel", "100000", "--engine", "jit", "--invoke", "catch_all_spin=100000000", L }, .exit = 1, .stderr = .{ .has = "all fuel consumed" } },
    // #364 — a GC allocation past the heap's 4 GiB cap traps out_of_memory at
    // the allocating instruction on the JIT and the default engine, as it
    // already does on the interpreter; the trailing (i32.const 42) never runs.
    // array.new* are the only GC allocs whose SINGLE allocation can overshoot
    // the cap (a runtime length), so they are the cheap ones to exercise here.
    // struct.new* / array.new_fixed share the same zero-check and it is equally
    // load-bearing: a guest that fills the heap (retained refs) makes their
    // next alloc fail too — that path is just not cheap to drive in a fixture.
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "array_new_default", H }, .exit = 1, .stderr = .{ .has = "kind=out_of_memory" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "array_new_default", H }, .exit = 1, .stderr = .{ .has = "kind=out_of_memory" } },
    .{ .args = &.{ "run", "--invoke", "array_new_default", H }, .exit = 1, .stderr = .{ .has = "kind=out_of_memory" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "array_new", H }, .exit = 1, .stderr = .{ .has = "kind=out_of_memory" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "array_new", H }, .exit = 1, .stderr = .{ .has = "kind=out_of_memory" } },
    .{ .args = &.{ "run", "--invoke", "array_new", H }, .exit = 1, .stderr = .{ .has = "kind=out_of_memory" } },
    // #364 / D-495 — array.new of a v128 element is not an allocation failure:
    // the JIT fill cannot marshal a 16-byte init, so the JIT declines (not an
    // out_of_memory trap) and the default engine falls back to the interpreter,
    // which does not execute v128.const. Both engines refuse, each for its own
    // reason. array.new_default is unaffected (not asserted here — it needs no
    // v128.const, so it has no cli-usage shape distinct from the GC rows above).
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "new", X }, .exit = 1, .stderr = .{ .has = "the interpreter does not execute `v128.const`" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "new", X }, .exit = 1, .stderr = .{ .has = "the JIT does not compile `array.new` with a v128 element" } },
    .{ .args = &.{ "run", "--invoke", "new", X }, .exit = 1, .stderr = .{ .has = "the JIT does not compile `array.new` with a v128 element" } },
} ++ throw_ref_rows;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    var paths: [placeholders.len][]const u8 = undefined;
    for (&paths) |*p| p.* = arg_it.next() orelse return error.MissingModulePath;
    try spawned_cli.assertRunnerBuildMode(gpa, io, cli);

    var failed: u32 = 0;
    for (rows) |row| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, cli);
        for (row.args) |a| {
            const path = for (placeholders, paths) |ph, p| {
                if (std.mem.eql(u8, a, ph)) break p;
            } else a;
            try argv.append(gpa, path);
        }

        const result = try std.process.run(gpa, io, .{ .argv = argv.items });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const exit: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        const ok = exit == row.exit and row.stdout.ok(result.stdout) and row.stderr.ok(result.stderr);
        if (!ok) failed += 1;
        const shown = try std.mem.join(gpa, " ", row.args);
        defer gpa.free(shown);
        std.debug.print("cli-usage {s:<4} {s:<40} exit {d} (want {d}) stdout \"{f}\" stderr \"{f}\"\n", .{
            if (ok) "ok" else "FAIL",
            shown,
            exit,
            row.exit,
            std.zig.fmtString(result.stdout[0..@min(result.stdout.len, 40)]),
            std.zig.fmtString(std.mem.trimEnd(u8, result.stderr, "\n")),
        });
    }
    std.debug.print("cli-usage: {d} rows, {d} failed\n", .{ rows.len, failed });
    return if (failed != 0) 1 else 0;
}
