// FILE-SIZE-EXEMPT: library root: re-export surface + root smoke tests; P4-alone at 44 lines over soft cap (investigated 2026-08-12, per ADR-0099)
//! zwasm — WebAssembly runtime, library root.
//!
//! Per ADR-0024 D-1/D-2: this file is the `root_source_file` of
//! the `core` Module that build.zig shares across the static lib
//! (`libzwasm.a`), the future shared lib / wasm lib targets, and
//! every test runner. The CLI exe (`zwasm` binary) lives in a
//! separate module rooted at `src/cli/main.zig` that imports
//! this module by name.
//!
//! ## Self-import surface (Bun pattern, ADR-0024 D-3)
//!
//! `core.addImport("zwasm", core)` in build.zig wires the
//! self-import. Any leaf file inside `src/` can write
//! `@import("zwasm").<zone>.<symbol>` to reach the unified
//! re-export hub regardless of how nested it is. Cross-zone
//! refactorings then update one re-export line below instead
//! of touching every leaf's `@import("../<zone>/<file>.zig")`.
//!
//! ## Two-tier import rule (ADR-0024 D-3)
//!
//! - Within-zone sibling: `@import("value.zig")` (relative)
//! - Within-zone parent:  `@import("../runtime.zig")` (relative)
//! - Cross-zone reference: `@import("zwasm").<zone>` (named)
//! - stdlib / builtin / build_options: `@import("std")` etc.
//!
//! ## Library zone classification
//!
//! `src/zwasm.zig` itself sits at "library surface" level — it
//! re-exports Zone 1+ symbols only (no Zone 2/3 export
//! dependencies leak through the surface). zone_check.sh
//! treats it as Zone 1.

const std = @import("std");

// Single source of truth = build.zig.zon `.version`, threaded through
// build_options by build.zig (no hand-sync; bump the zon when the user cuts
// a tag, per ADR-0156 USER-only release). `--version` reads this.
pub const version = @import("build_options").version;

// ============================================================
// Zig facade (ADR-0109 native API) — first-principles Engine +
// Module + Instance + Trap + Value surface. Engine / Module /
// Instance live in `src/zwasm/{engine,module,instance}.zig`.
// Closes I3 of `.claude/rules/phase9_close_invariants.md`.
// ============================================================

pub const Engine = @import("zwasm/engine.zig").Engine;
pub const Module = @import("zwasm/module.zig").Module;
pub const ExternKind = @import("zwasm/module.zig").ExternKind;
pub const ImportItem = @import("zwasm/module.zig").ImportItem;
pub const ExportItem = @import("zwasm/module.zig").ExportItem;
pub const ModuleImports = @import("zwasm/module.zig").ModuleImports;
pub const ModuleExports = @import("zwasm/module.zig").ModuleExports;
pub const Instance = @import("zwasm/instance.zig").Instance;
pub const Trap = @import("zwasm/instance.zig").Trap;
pub const TypedFunc = @import("zwasm/typed_func.zig").TypedFunc;
pub const Memory = @import("zwasm/memory.zig").Memory;
pub const Global = @import("zwasm/global.zig").Global;
pub const Table = @import("zwasm/table.zig").Table;
pub const Linker = @import("zwasm/linker.zig").Linker;
pub const Caller = @import("zwasm/caller.zig").Caller;

/// Zig-idiomatic tagged-union mirror of `wasm_val_t`.
/// Wasm spec §4.2.2 — value representation at the host boundary
/// (i32 / i64 / f32 / f64 / v128 / funcref / externref).
pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: u32,
    f64: u64,
    v128: u128,
    funcref: ?u64,
    externref: ?u64,

    pub fn fromI32(v: i32) Value {
        return .{ .i32 = v };
    }
    pub fn fromI64(v: i64) Value {
        return .{ .i64 = v };
    }
    pub fn fromF32Bits(b: u32) Value {
        return .{ .f32 = b };
    }
    pub fn fromF64Bits(b: u64) Value {
        return .{ .f64 = b };
    }
};

// ============================================================
// Force-analyse the C-ABI binding files so their `pub export
// fn wasm_*` symbols land in `libzwasm.a` (per ADR-0024 D-2's
// note about subsuming the former `api/lib_export.zig` role).
// `pub const` re-exports below are not enough — Zig only emits
// `export` symbols from compilation units that the analysis
// pass actually visits, and a top-level `pub const` is lazily
// referenced from outside. This `comptime` block forces eager
// analysis at module-root semantics time, mirroring the
// pre-ADR-0023 `c_api_lib.zig` mechanism.
// ============================================================
comptime {
    _ = @import("api/wasm.zig");
    _ = @import("api/wasi.zig");
    _ = @import("api/trap_surface.zig");
    _ = @import("api/vec.zig");
    _ = @import("api/types.zig");
    _ = @import("api/instance.zig");
    _ = @import("api/zwasm_ext.zig");
    _ = @import("api/module_introspect.zig");
    _ = @import("api/extern_new.zig");
    _ = @import("api/ref_base.zig");
    _ = @import("api/config.zig");
    _ = @import("api/host_info.zig");
    _ = @import("api/module_serialize.zig");
    _ = @import("api/cross_module.zig");
}

// ============================================================
// Zone re-exports — the public surface for both the library
// archive and the self-import (`@import("zwasm")`) inside leaf
// files.
// ============================================================

// Zone 0
pub const support = struct {
    pub const dbg = @import("support/dbg.zig");
    pub const leb128 = @import("support/leb128.zig");
};
pub const platform = struct {
    pub const jit_mem = @import("platform/jit_mem.zig");
    pub const guarded_mem = @import("platform/guarded_mem.zig"); // ADR-0202 D1 reserve/commit backing
    pub const trap_registry = @import("platform/trap_registry.zig"); // ADR-0202 D3 fault classification
    pub const sigcontext = @import("platform/sigcontext.zig"); // ADR-0202 D2 PC read/write
    pub const windows_traphandler = @import("platform/windows_traphandler.zig");
    pub const stack_limit = @import("platform/stack_limit.zig");
    pub const signal = @import("platform/signal.zig"); // ADR-0166 internal-fault handler
    // fs / time are placeholders per ADR-0023 §3 P-H.
};

// Zone 1
pub const ir = struct {
    pub const zir = @import("ir/zir.zig");
    pub const dispatch_table = @import("ir/dispatch_table.zig");
    pub const dispatch_collector = @import("ir/dispatch_collector.zig");
    pub const feature_level_check = @import("ir/feature_level_check.zig");
    pub const wasm_byte_map = @import("ir/wasm_byte_map.zig");
    pub const lower = @import("ir/lower.zig");
    pub const verifier = @import("ir/verifier.zig");
    pub const analysis = struct {
        pub const loop_info = @import("ir/analysis/loop_info.zig");
        pub const liveness = @import("ir/analysis/liveness.zig");
        pub const const_prop = @import("ir/analysis/const_prop.zig");
    };
};
pub const parse = struct {
    pub const parser = @import("parse/parser.zig");
    pub const sections = @import("parse/sections.zig");
    pub const ctx = @import("parse/ctx.zig");
};
pub const validate = struct {
    pub const validator = @import("validate/validator.zig");
};
pub const runtime = @import("runtime/runtime.zig");
pub const diagnostic = @import("diagnostic/diagnostic.zig");
pub const feature = struct {
    pub const mvp = @import("feature/mvp/mod.zig");
    // Active feature register entries — placeholders until the
    // per-feature implementation lands per ROADMAP §11.
    pub const simd_128 = @import("feature/simd_128/register.zig");
    pub const gc = @import("feature/gc/register.zig");
    pub const exception_handling = @import("feature/exception_handling/register.zig");
    pub const tail_call = @import("feature/tail_call/register.zig");
    pub const function_references = @import("feature/function_references/register.zig");
    pub const memory64 = @import("feature/memory64/register.zig");
    // Component Model + WASI Preview 2 (ADR-0170). Exposed on the public
    // surface only when `wasi_level >= .p2` (ADR-0193 folded the former
    // `-Dcomponent` flag into the `-Dwasi` axis); a `-Dwasi=p1`/`none`
    // build emits zero component code. Unit tests reference `decode.zig`
    // directly (test loader below), so coverage runs regardless of the gate.
    pub const component = if (@import("build_options").enable_component)
        struct {
            pub const decode = @import("feature/component/decode.zig");
            pub const types = @import("feature/component/types.zig");
            pub const validate = @import("feature/component/validate.zig");
            pub const canon = @import("feature/component/canon.zig");
            pub const resource_table = @import("feature/component/resource_table.zig");
            pub const value = @import("feature/component/value.zig");
            /// REQ-3 (cw CM-API) — public WIT type-tree introspection.
            pub const wit_type = @import("feature/component/wit_type.zig");
            pub const wit = struct {
                pub const lexer = @import("feature/component/wit/lexer.zig");
                pub const parser = @import("feature/component/wit/parser.zig");
                pub const resolve = @import("feature/component/wit/resolve.zig");
            };
            // Zone-3 host orchestration (ADR-0172): instantiate + invoke.
            pub const host = @import("api/component.zig");
        }
    else
        struct {};
};

// Zone 2
pub const interp = struct {
    pub const mvp = @import("interp/mvp.zig");
    pub const dispatch = @import("interp/dispatch.zig");
    pub const trap_audit = @import("interp/trap_audit.zig");
};
pub const instruction = struct {
    pub const wasm_1_0 = struct {
        pub const numeric_int = @import("instruction/wasm_1_0/numeric_int.zig");
        pub const numeric_float = @import("instruction/wasm_1_0/numeric_float.zig");
        pub const numeric_conversion = @import("instruction/wasm_1_0/numeric_conversion.zig");
        pub const memory = @import("instruction/wasm_1_0/memory.zig");
        // control / parametric / variable are placeholder skeletons
        // per ADR-0023 §7 item 8 (full split deferred).
    };
    pub const wasm_2_0 = struct {
        pub const sign_extension = @import("instruction/wasm_2_0/sign_extension.zig");
        pub const nontrap_conversion = @import("instruction/wasm_2_0/nontrap_conversion.zig");
        pub const bulk_memory = @import("instruction/wasm_2_0/bulk_memory.zig");
        pub const reference_types = @import("instruction/wasm_2_0/reference_types.zig");
        pub const table_ops = @import("instruction/wasm_2_0/table_ops.zig");
    };
};
pub const engine = struct {
    pub const runner = @import("engine/runner.zig");
    pub const runner_validate = @import("engine/runner_validate.zig");
    pub const export_lookup = @import("engine/export_lookup.zig");
    pub const codegen = struct {
        pub const dispatch_collector = @import("engine/codegen/dispatch_collector.zig");
        pub const shared = struct {
            pub const reg_class = @import("engine/codegen/shared/reg_class.zig");
            pub const regalloc = @import("engine/codegen/shared/regalloc.zig");
            pub const linker = @import("engine/codegen/shared/linker.zig");
            pub const entry = @import("engine/codegen/shared/entry.zig");
            pub const entry_buffer_write = @import("engine/codegen/shared/entry_buffer_write.zig");
            pub const compile = @import("engine/codegen/shared/compile.zig");
            pub const jit_abi = @import("engine/codegen/shared/jit_abi.zig");
            pub const thunk = @import("engine/codegen/shared/thunk.zig");
            pub const canonical_type = @import("engine/codegen/shared/canonical_type.zig");
            pub const result_abi = @import("engine/codegen/shared/result_abi.zig");
            pub const wrapper_thunk = @import("engine/codegen/shared/wrapper_thunk.zig");
        };
        pub const arm64 = struct {
            pub const inst = @import("engine/codegen/arm64/inst.zig");
            pub const inst_neon = @import("engine/codegen/arm64/inst_neon.zig");
            pub const abi = @import("engine/codegen/arm64/abi.zig");
            pub const prologue = @import("engine/codegen/arm64/prologue.zig");
            pub const label = @import("engine/codegen/arm64/label.zig");
            pub const emit = @import("engine/codegen/arm64/emit.zig");
        };
        pub const aot = struct {
            pub const format = @import("engine/codegen/aot/format.zig");
            pub const serialise = @import("engine/codegen/aot/serialise.zig");
            pub const produce = @import("engine/codegen/aot/produce.zig");
            pub const load_compiled = @import("engine/codegen/aot/load_compiled.zig");
        };
    };
};
pub const wasi = struct {
    pub const preview1 = @import("wasi/preview1.zig");
    pub const host = @import("wasi/host.zig");
    pub const fd = @import("wasi/fd.zig");
    pub const path = @import("wasi/path.zig");
    pub const clocks = @import("wasi/clocks.zig");
    pub const proc = @import("wasi/proc.zig");
    pub const jit_dispatch = @import("wasi/jit_dispatch.zig");
    /// WASI Preview 2 → Preview 1 adapter (ADR-0170 Phase D; `-Dwasi=preview2`).
    pub const adapter = @import("wasi/adapter.zig");
};

// Zone 3
pub const api = struct {
    pub const wasm = @import("api/wasm.zig");
    pub const wasi_binding = @import("api/wasi.zig");
    pub const trap_surface = @import("api/trap_surface.zig");
    pub const vec = @import("api/vec.zig");
    pub const types = @import("api/types.zig");
    pub const cross_module = @import("api/cross_module.zig");
    pub const instance = @import("api/instance.zig");
    pub const module_introspect = @import("api/module_introspect.zig");
    pub const extern_new = @import("api/extern_new.zig");
};
pub const cli = struct {
    pub const run = @import("cli/run.zig");
    pub const cache = @import("cli/cache.zig");
    pub const invoke_args = @import("cli/invoke_args.zig");
    pub const compile = @import("cli/compile.zig");
    pub const dispatch = @import("cli/dispatch.zig");
    pub const diag_print = @import("cli/diag_print.zig");
};

// ============================================================
// Test loader — pulled by every artifact that uses `core` as
// its `root_module` (lib / test runners). Keeps the unit-test
// surface in one place; mirrors what `src/main.zig` previously
// did but is decoupled from the CLI exe entry.
// ============================================================

test {
    _ = @import("support/leb128.zig");
    _ = @import("support/dbg.zig");
    _ = @import("diagnostic/diagnostic.zig");
    _ = @import("diagnostic/trace.zig");
    _ = @import("cli/diag_print.zig");
    _ = @import("cli/dispatch.zig");
    _ = @import("ir/zir.zig");
    _ = @import("ir/dispatch_table.zig");
    _ = @import("ir/dispatch_collector.zig");
    _ = @import("engine/codegen/dispatch_collector.zig");
    _ = @import("ir/wasm_byte_map.zig");
    _ = @import("ir/hoist/pass.zig");
    _ = @import("ir/coalesce/pass.zig");
    _ = @import("engine/codegen/aot/format.zig");
    _ = @import("engine/codegen/aot/serialise.zig");
    _ = @import("engine/codegen/aot/produce.zig");
    _ = @import("engine/codegen/aot/load_compiled.zig");
    _ = @import("cli/compile.zig");
    _ = @import("engine/codegen/shared/reg_class.zig");
    _ = @import("engine/codegen/shared/regalloc.zig");
    _ = @import("engine/codegen/arm64/inst.zig");
    _ = @import("engine/codegen/arm64/inst_neon.zig");
    _ = @import("engine/codegen/arm64/inst_neon_arith.zig");
    _ = @import("engine/codegen/arm64/inst_neon_lane_cmp.zig");
    _ = @import("engine/codegen/arm64/op_simd.zig");
    _ = @import("engine/codegen/arm64/op_simd_int_arith.zig");
    _ = @import("engine/codegen/arm64/op_simd_int_cmp_lane.zig");
    _ = @import("engine/codegen/arm64/op_simd_float.zig");
    _ = @import("engine/codegen/arm64/abi.zig");
    _ = @import("engine/codegen/arm64/emit.zig");
    _ = @import("engine/codegen/arm64/emit_test.zig");
    _ = @import("engine/codegen/x86_64/reg_class.zig");
    _ = @import("engine/codegen/x86_64/inst.zig");
    _ = @import("engine/codegen/x86_64/inst_sse.zig");
    _ = @import("engine/codegen/x86_64/inst_sse_packed.zig");
    _ = @import("engine/codegen/x86_64/inst_sse_scalar.zig");
    _ = @import("engine/codegen/x86_64/abi.zig");
    _ = @import("engine/codegen/x86_64/prologue.zig");
    _ = @import("engine/codegen/x86_64/types.zig");
    _ = @import("engine/codegen/x86_64/label.zig");
    _ = @import("engine/codegen/x86_64/op_alu_int.zig");
    _ = @import("engine/codegen/x86_64/op_alu_float.zig");
    _ = @import("engine/codegen/x86_64/op_simd.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_arith.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_cmp_lane.zig");
    _ = @import("engine/codegen/x86_64/op_simd_float.zig");
    _ = @import("engine/codegen/x86_64/op_simd_test.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_arith_test.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_cmp_lane_test.zig");
    _ = @import("engine/codegen/x86_64/op_simd_float_test.zig");
    _ = @import("engine/codegen/x86_64/emit.zig");
    _ = @import("engine/codegen/x86_64/emit_test.zig");
    _ = @import("platform/jit_mem.zig");
    _ = @import("platform/guarded_mem.zig");
    _ = @import("platform/trap_registry.zig");
    _ = @import("platform/sigcontext.zig");
    _ = @import("platform/fault_redirect_test.zig");
    _ = @import("runtime/instance/memory_backing.zig");
    _ = @import("platform/windows_traphandler.zig");
    _ = @import("platform/stack_limit.zig");
    _ = @import("platform/signal.zig");
    _ = @import("engine/codegen/shared/linker.zig");
    _ = @import("engine/codegen/shared/entry.zig");
    _ = @import("engine/codegen/shared/entry_buffer_write.zig");
    _ = @import("engine/codegen/shared/result_abi.zig");
    _ = @import("engine/codegen/shared/wrapper_thunk.zig");
    _ = @import("engine/codegen/shared/jit_abi.zig");
    _ = @import("engine/codegen/shared/compile.zig");
    _ = @import("engine/codegen/shared/thunk.zig");
    _ = @import("engine/codegen/shared/throw_trampoline.zig");
    _ = @import("engine/codegen/arm64/thunk.zig");
    _ = @import("engine/codegen/x86_64/thunk.zig");
    _ = @import("engine/runner.zig");
    _ = @import("engine/runner_test.zig");
    _ = @import("engine/runner_gc_test.zig");
    _ = @import("engine/pic_helper_test.zig");
    _ = @import("engine/runner_v128_jit_test.zig");
    _ = @import("engine/runner_multiarg_invoke_test.zig");
    _ = @import("engine/runner_trap_test.zig");
    _ = @import("ir/analysis/loop_info.zig");
    _ = @import("ir/analysis/liveness.zig");
    _ = @import("ir/verifier.zig");
    _ = @import("ir/analysis/const_prop.zig");
    _ = @import("parse/parser.zig");
    _ = @import("validate/validator.zig");
    _ = @import("validate/validator_tests.zig");
    _ = @import("validate/validator_helpers_tests.zig");
    _ = @import("ir/lower.zig");
    _ = @import("ir/lower_tests.zig");
    _ = @import("parse/ctx.zig");
    _ = @import("feature/mvp/mod.zig");
    _ = @import("parse/sections.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/value.zig");
    _ = @import("runtime/trap.zig");
    _ = @import("runtime/frame.zig");
    _ = @import("interp/dispatch.zig");
    _ = @import("interp/mvp.zig");
    _ = @import("instruction/wasm_1_0/memory.zig");
    _ = @import("interp/trap_audit.zig");
    _ = @import("instruction/wasm_2_0/sign_extension.zig");
    _ = @import("instruction/wasm_2_0/nontrap_conversion.zig");
    _ = @import("instruction/wasm_2_0/bulk_memory.zig");
    _ = @import("instruction/wasm_2_0/reference_types.zig");
    _ = @import("instruction/wasm_2_0/table_ops.zig");
    _ = @import("api/wasm.zig");
    // S5 test-discovery guard (check_test_discovery.sh) backfill: these
    // files carried named tests that no test step discovered.
    _ = @import("engine/codegen/x86_64/frame_chain.zig");
    _ = @import("engine/codegen/arm64/frame_chain.zig");
    _ = @import("engine/codegen/x86_64/sp_restore.zig");
    _ = @import("engine/codegen/arm64/sp_restore.zig");
    _ = @import("engine/codegen/shared/frame_teardown.zig");
    _ = @import("ir/feature_level_check.zig");
    _ = @import("test_support/skip.zig");
    _ = @import("interp/mvp_tests.zig");
    _ = @import("wasi/preview1.zig");
    _ = @import("wasi/host.zig");
    _ = @import("wasi/proc.zig");
    _ = @import("wasi/fd.zig");
    _ = @import("wasi/path.zig");
    _ = @import("wasi/clocks.zig");
    _ = @import("wasi/jit_dispatch.zig");
    _ = @import("wasi/adapter.zig");
    _ = @import("wasi/p2_sockets.zig");
    _ = @import("cli/run.zig");
    _ = @import("cli/cache.zig");
    _ = @import("cli/invoke_args.zig");
    _ = @import("feature/component/decode.zig");
    _ = @import("feature/component/types.zig");
    _ = @import("feature/component/types_tests.zig");
    _ = @import("feature/component/validate.zig");
    _ = @import("feature/component/wit/lexer.zig");
    _ = @import("feature/component/wit/parser.zig");
    _ = @import("feature/component/wit/resolve.zig");
    _ = @import("feature/component/canon.zig");
    _ = @import("feature/component/resource_table.zig");
    _ = @import("feature/component/async.zig");
    _ = @import("feature/component/value.zig");
    _ = @import("api/component.zig");
    _ = @import("api/component_wasi_ctx.zig");
    _ = @import("api/component_wasi_p3_host.zig");
    _ = @import("api/component_wasi_p2.zig");
    _ = @import("api/component_tests.zig");
    _ = @import("api/component_async_tests.zig");
    // ADR-0193 P3: the P3 driver + its 28 async tests compile only at
    // `wasi_level >= .p3`. The default `.p2` `zig build test` skips them;
    // the `test-wasi-p3` step (forced `-Dwasi=p3`) covers them.
    if (@import("build_options").enable_wasi_p3) _ = @import("api/component_wasi_p3.zig");
    _ = @import("api/component_typed.zig");
}

// ============================================================
// Zig facade tests (master plan §5.2 + I3 invariant)
// ============================================================

// (module (func (export "main") (result i32) i32.const 255 i32.extend8_s))
// i32.extend8_s is the Wasm 2.0 sign-extension proposal (opcode 0xC0).
// Sign-extending bits[0..8] of 255 (0xFF) yields -1.
const facade_extend8_s_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: 1 fn, type 0
    0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x00, // export "main" (func 0)
    // code section: id=0x0a, size=8 (count + entry_size + 6-byte entry),
    //   count=1, entry_size=6, body = locals_count(0) i32.const 255 (0x41 0xff 0x01)
    //   i32.extend8_s (0xC0) end (0x0B).
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0xff, 0x01, 0xC0, 0x0B,
};

test "zwasm facade Wasm 2.0 round-trip via Engine / Module / Instance / Value" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    var mod = try eng.compile(&facade_extend8_s_wasm);
    defer mod.deinit();

    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    var results: [1]Value = .{.{ .i32 = 0 }};
    try inst.invoke("main", &.{}, &results);

    // i32.extend8_s of 0xFF = -1.
    try std.testing.expectEqual(@as(i32, -1), results[0].i32);
}

// T1.1 — Engine + Module lifecycle, allocator strict-pass via a
// recording wrapper. ADR-0109 §4.1 requires the user allocator
// reach internal allocations; recording proves the path.
const RecordingAllocator = struct {
    inner: std.mem.Allocator,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *RecordingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_calls += 1;
        return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
    }
};

test "zwasm facade T1.1: Engine + Module lifecycle — allocator strict-pass" {
    var rec: RecordingAllocator = .{ .inner = std.testing.allocator };

    var eng = try Engine.init(rec.allocator(), .{});
    defer eng.deinit();
    try std.testing.expect(rec.alloc_calls >= 1);

    var mod = try eng.compile(&facade_extend8_s_wasm);
    defer mod.deinit();
    // compile() invokes the native parser which allocates the
    // sections list through the user allocator.
    try std.testing.expect(rec.alloc_calls >= 2);
}

test "zwasm facade T1.2: Module.compile rejects invalid bytes" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    // Truncated header (< 8 bytes) — native parser returns
    // `TruncatedHeader`, surfaced as `error.ParseFailed`.
    try std.testing.expectError(error.ParseFailed, eng.compile(&[_]u8{ 0x00, 0x61 }));

    // Bad magic — native parser returns `InvalidMagic`.
    const bad_magic = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.ParseFailed, eng.compile(&bad_magic));
}

test "zwasm facade: compile distinguishes ValidateFailed from ParseFailed (D-197)" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    // Parses structurally but FAILS validation: `(func (result i32))`
    // whose body is just `end` — declares an i32 result but leaves the
    // operand stack empty. parser.parse succeeds; frontendValidate rejects.
    const parse_ok_validate_fail = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> (i32)
        0x03, 0x02, 0x01, 0x00, // func: 1 func of type 0
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: 1 body {locals=0, end}
    };
    try std.testing.expectError(error.ValidateFailed, eng.compile(&parse_ok_validate_fail));
}

test "zwasm facade T1.3: Instance.invoke happy-path (untyped raw Value)" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    var mod = try eng.compile(&facade_extend8_s_wasm);
    defer mod.deinit();

    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    var results: [1]Value = .{Value.fromI32(0)};
    try inst.invoke("main", &.{}, &results);

    try std.testing.expectEqual(@as(i32, -1), results[0].i32);
}

// (module (func (export "div") (param i32 i32) (result i32)
//   local.get 0 local.get 1 i32.div_s))
// `i32.div_s 1 0` traps with DivByZero per Wasm spec §4.4.
const facade_div_s_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version
    // type: (i32, i32) -> (i32)
    0x01, 0x07, 0x01, 0x60,
    0x02, 0x7F, 0x7F, 0x01,
    0x7F,
    // func: 1 fn, type 0
    0x03, 0x02, 0x01,
    0x00,
    // export "div" (func 0)
    0x07, 0x07, 0x01,
    0x03, 0x64, 0x69, 0x76,
    0x00, 0x00,
    // code: id 0x0a, size 9, count 1, entry_size 7
    //   locals_count 0, local.get 0 (0x20 0x00), local.get 1 (0x20 0x01), i32.div_s (0x6D), end (0x0B)
    0x0a, 0x09,
    0x01, 0x07, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x6D,
    0x0B,
};

test "zwasm facade T1.4: invoke surfaces error.DivByZero (no Trap catchall)" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    var mod = try eng.compile(&facade_div_s_wasm);
    defer mod.deinit();

    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    var results: [1]Value = .{Value.fromI32(0)};
    const args: [2]Value = .{ Value.fromI32(1), Value.fromI32(0) };
    try std.testing.expectError(error.DivByZero, inst.invoke("div", &args, &results));
}

// T1.5 fixture — `(module (func (export "add") (param i32 i32) (result i32)
//   local.get 0 local.get 1 i32.add))`. i32.add opcode = 0x6A.
const facade_add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F, // type (i32,i32)->(i32)
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" func 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01,
    0x6A, 0x0B,
};

test "zwasm facade T1.5: TypedFunc happy-path — fn(i32,i32) i32" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_add_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const add = inst.typedFunc(fn (i32, i32) i32, "add");
    try std.testing.expectEqual(@as(i32, 5), try add.call(.{ 2, 3 }));
}

// T1.6 fixture — `(module (func (export "swap") (param i32 i32) (result i32 i32)
//   local.get 1 local.get 0))`. Multi-result Wasm 2.0 — type vec(result)=2.
const facade_swap_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: (i32,i32) -> (i32,i32) — body = 8 bytes
    0x01, 0x08, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x02,
    0x7F, 0x7F, 0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x73, 0x77, 0x61, 0x70, 0x00, 0x00, // "swap" func 0
    // code: size=8, entry_size=6 (locals 0 + 2 local.get + end = 6)
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x01, 0x20, 0x00, 0x0B,
};

test "zwasm facade T1.6: TypedFunc multi-result via anonymous struct" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_swap_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const swap = inst.typedFunc(fn (i32, i32) struct { i32, i32 }, "swap");
    const r = try swap.call(.{ 7, 13 });
    try std.testing.expectEqual(@as(i32, 13), r[0]);
    try std.testing.expectEqual(@as(i32, 7), r[1]);
}

// T1.7 fixture — `(module (memory (export "mem") 1))`. One page memory.
const facade_mem_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1 mem, no max, min=1
    0x07, 0x07, 0x01, 0x03, 0x6D, 0x65, 0x6D, 0x02, 0x00, // export "mem" memory 0
};

test "zwasm facade T1.7: Memory write+read i32 round-trip" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_mem_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const mem = inst.memory() orelse return error.TestUnexpectedResult;
    try std.testing.expect(mem.size() >= 1);
    try mem.write(0x100, @as(i32, 42));
    try std.testing.expectEqual(@as(i32, 42), try mem.read(i32, 0x100));
}

// T1.8 fixture — returns the f64 quiet-NaN bit pattern
// 0x7FF8_0000_0000_0001 verbatim (no canonicalisation). Bytes
// LE: 01 00 00 00 00 00 F8 7F.
const facade_qnan_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7C, // type () -> f64
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x71, 0x6E, 0x61, 0x6E, 0x00, 0x00, // "qnan" func 0
    // code: id 0x0a, size 0x0d, count 1, entry_size 0x0b, locals 0,
    //   f64.const (0x44) + 8 bytes payload, end (0x0B)
    0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x44, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xF8, 0x7F, 0x0B,
};

test "zwasm facade T1.8: NaN-boxing — f64 quiet NaN bits preserved" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_qnan_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const qnan = inst.typedFunc(fn () f64, "qnan");
    const got = try qnan.call(.{});
    const got_bits: u64 = @bitCast(got);
    try std.testing.expectEqual(@as(u64, 0x7FF8_0000_0000_0001), got_bits);
}

// T1.9 fixture — imports env.add(i32,i32)→i32, exports go(i32,i32)→i32
// that calls add.
const facade_host_add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: (i32,i32) -> i32 — size 7
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01,
    0x7F,
    // import: "env" "add" func type 0 — size 11
    0x02, 0x0B, 0x01, 0x03, 0x65, 0x6E, 0x76,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    // function: 1 fn, type 0
    0x03, 0x02,
    0x01, 0x00,
    // export: "go" func 1 (imports come first in funcidx space) — size 6
    0x07, 0x06, 0x01, 0x02, 0x67, 0x6F,
    0x00, 0x01,
    // code: locals 0; local.get 0; local.get 1; call 0; end — entry 8, sec 10
    0x0A, 0x0A, 0x01, 0x08, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x10, 0x00, 0x0B,
};

fn hostAdd(_: *Caller, a: i32, b: i32) i32 {
    return a +% b;
}

test "zwasm facade T1.9: Linker.defineFunc + host import round-trip" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_host_add_wasm);
    defer mod.deinit();

    var lk = Linker.init(&eng);
    defer lk.deinit();
    try lk.defineFunc("env", "add", fn (*Caller, i32, i32) i32, hostAdd);

    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();

    const go = inst.typedFunc(fn (i32, i32) i32, "go");
    try std.testing.expectEqual(@as(i32, 11), try go.call(.{ 4, 7 }));
}

// T1.10 fixture — imports env.poke_42 (no args, no result); has 1-page
// memory exported as "mem"; exports "go" that calls poke_42.
const facade_host_poke_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: () -> () — size 4
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    // import "env" "poke_42" func type 0 — size 15
    0x02, 0x0F,
    0x01, 0x03, 0x65, 0x6E, 0x76, 0x07, 0x70, 0x6F,
    0x6B, 0x65, 0x5F, 0x34, 0x32, 0x00, 0x00,
    // function: 1 fn, type 0
    0x03,
    0x02, 0x01, 0x00,
    // memory: min 1
    0x05, 0x03, 0x01, 0x00, 0x01,
    // export: "mem" memory 0; "go" func 1 — size 12
    0x07, 0x0C, 0x02, 0x03, 0x6D, 0x65, 0x6D, 0x02,
    0x00, 0x02, 0x67, 0x6F, 0x00, 0x01,
    // code: locals 0; call 0; end — entry 4, sec 6
    0x0A, 0x06,
    0x01, 0x04, 0x00, 0x10, 0x00, 0x0B,
};

fn hostPoke42(caller: *Caller) void {
    const mem = caller.memory() orelse return;
    mem.write(0, @as(i32, 42)) catch return;
}

test "zwasm facade T1.10: host fn uses caller.memory() to write linear memory" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_host_poke_wasm);
    defer mod.deinit();

    var lk = Linker.init(&eng);
    defer lk.deinit();
    try lk.defineFunc("env", "poke_42", fn (*Caller) void, hostPoke42);

    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();

    const go = inst.typedFunc(fn () void, "go");
    try go.call(.{});

    const mem = inst.memory() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 42), try mem.read(i32, 0));
}

fn hostAddOneArg(_: *Caller, a: i32) i32 {
    return a +% 1;
}

test "zwasm facade T1.11: arity-mismatched host fn → error.SignatureMismatch" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_host_add_wasm);
    defer mod.deinit();

    var lk = Linker.init(&eng);
    defer lk.deinit();
    // Module declares env.add as (i32,i32)→i32; register with (i32)→i32.
    try lk.defineFunc("env", "add", fn (*Caller, i32) i32, hostAddOneArg);

    try std.testing.expectError(error.SignatureMismatch, lk.instantiate(&mod, .{}));
}

// T1.12 importer — imports env.shared (memory 1); writes 42 into memory[4].
const facade_cross_mem_writer_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: () -> ()
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    // import "env" "shared" memory min=1 — size 15
    0x02, 0x0F,
    0x01, 0x03, 0x65, 0x6E, 0x76, 0x06, 0x73, 0x68,
    0x61, 0x72, 0x65, 0x64, 0x02, 0x00, 0x01,
    // function
    0x03,
    0x02, 0x01, 0x00,
    // export "go" func 0
    0x07, 0x06, 0x01, 0x02, 0x67,
    0x6F, 0x00, 0x00,
    // code: locals 0; i32.const 4; i32.const 42; i32.store align=2 offset=0; end — entry 9, sec 11
    0x0A, 0x0B, 0x01, 0x09, 0x00,
    0x41, 0x04, 0x41, 0x2A, 0x36, 0x02, 0x00, 0x0B,
};

// T1.12 exporter — (memory (export "shared") 1).
const facade_cross_mem_exporter_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x0A, 0x01,
    0x06, 0x73, 0x68, 0x61, 0x72, 0x65, 0x64, 0x02,
    0x00,
};

test "zwasm facade T1.12: cross-instance memory sharing via Linker.defineMemory" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    var exporter_mod = try eng.compile(&facade_cross_mem_exporter_wasm);
    defer exporter_mod.deinit();
    var exporter = try exporter_mod.instantiate(.{ .engine = .interp });
    defer exporter.deinit();

    var writer_mod = try eng.compile(&facade_cross_mem_writer_wasm);
    defer writer_mod.deinit();

    var lk = Linker.init(&eng);
    defer lk.deinit();
    const exp_mem = exporter.memory() orelse return error.TestUnexpectedResult;
    try lk.defineMemory("env", "shared", exp_mem);

    var writer = try lk.instantiate(&writer_mod, .{});
    defer writer.deinit();

    const go = writer.typedFunc(fn () void, "go");
    try go.call(.{});

    // Writer's i32.store landed in the shared exporter memory.
    try std.testing.expectEqual(@as(i32, 42), try exp_mem.read(i32, 4));
}

// T1.13 fixture — imports wasi_snapshot_preview1.proc_exit
// (i32 -> ()) and exports "go" which never calls it.
// Instantiation succeeds (binding wires WASI thunk via Linker.defineWasi);
// no syscall is exercised.
const facade_wasi_smoke_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: vec=2; [0] = (i32)->() (for proc_exit); [1] = ()->() (for go)
    // body: 0x02, 0x60 0x01 0x7F 0x00, 0x60 0x00 0x00 = 8 bytes
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7F, 0x00, 0x60,
    0x00, 0x00,
    // import "wasi_snapshot_preview1" "proc_exit" func type 0
    // body: vec=1, 22 'w...' 09 'p...' 00 00 = 1+1+22+1+9+1+1 = 36 bytes
    0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70, 0x73,
    0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76,
    0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6F,
    0x63, 0x5F, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00,
    // function: 1 fn, type 1
    0x03, 0x02, 0x01, 0x01,
    // export "go" func 1 (imports come first)
    0x07, 0x06, 0x01, 0x02,
    0x67, 0x6F, 0x00, 0x01,
    // code: locals 0; end — entry 2, sec 4
    0x0A, 0x04, 0x01, 0x02,
    0x00, 0x0B,
};

test "zwasm facade T1.13: Linker.defineWasi smoke instantiation" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    var lk = Linker.init(&eng);
    defer lk.deinit();
    try lk.defineWasi(.{});

    var mod = try eng.compile(&facade_wasi_smoke_wasm);
    defer mod.deinit();

    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    // Smoke: instantiate succeeds and ownership of the wasi_host
    // transfers to the Store (`wasm_store_delete` will free it).
}

test "zwasm facade T1.4-types: Instance.invoke return type carries all 12 Trap variants" {
    const InvokeError = Instance.InvokeError;
    const info = @typeInfo(InvokeError).error_set orelse @compileError("expected concrete error_set");
    // Walk every runtime.Trap variant and confirm it is present in InvokeError.
    const required = [_][]const u8{
        "Unreachable",              "DivByZero",
        "IntOverflow",              "InvalidConversionToInt",
        "OutOfBoundsLoad",          "OutOfBoundsStore",
        "OutOfBoundsTableAccess",   "UninitializedElement",
        "IndirectCallTypeMismatch", "StackOverflow",
        "CallStackExhausted",       "OutOfMemory",
    };
    inline for (required) |name| {
        var found = false;
        for (info) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

// T1.14 fixture — (module (global (export "g_mut") (mut i32) (i32.const 7))
//   (global (export "g_imm") i32 (i32.const 42)))
const facade_global_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // global section: 2 globals — [i32 mut =7] [i32 const =42]
    0x06, 0x0b, 0x02, 0x7f, 0x01, 0x41, 0x07, 0x0b,
    0x7f, 0x00, 0x41, 0x2a, 0x0b,
    // export section: "g_mut" global 0, "g_imm" global 1
    0x07, 0x11, 0x02,
    0x05, 0x67, 0x5f, 0x6d, 0x75, 0x74, 0x03, 0x00,
    0x05, 0x67, 0x5f, 0x69, 0x6d, 0x6d, 0x03, 0x01,
};

test "zwasm facade T1.14: Instance.global get/set + immutable rejection (D-272)" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_global_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const g_mut = inst.global("g_mut") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 7), g_mut.get().i32);
    try g_mut.set(.{ .i32 = 100 });
    try std.testing.expectEqual(@as(i32, 100), g_mut.get().i32);

    const g_imm = inst.global("g_imm") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 42), g_imm.get().i32);
    try std.testing.expectError(error.Immutable, g_imm.set(.{ .i32 = 0 }));

    try std.testing.expect(inst.global("nope") == null);
}

// T1.15 fixture — (module (table (export "t") 2 externref))
const facade_table_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x04, 0x04, 0x01, 0x6f, 0x00, 0x02, // table: externref, min 2
    0x07, 0x05, 0x01, 0x01, 0x74, 0x01, 0x00, // export "t" table 0
};

test "zwasm facade T1.15: Instance.table get/set/size/grow (D-272)" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_table_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .interp });
    defer inst.deinit();

    const t = inst.table("t") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), t.size());
    try std.testing.expect((try t.get(0)).externref == null);
    try t.set(0, .{ .externref = 0xABCD });
    try std.testing.expectEqual(@as(?u64, 0xABCD), (try t.get(0)).externref);
    try std.testing.expectError(error.OutOfBounds, t.get(2));

    try t.grow(1, .{ .externref = null });
    try std.testing.expectEqual(@as(u32, 3), t.size());
    try std.testing.expect((try t.get(2)).externref == null);

    try std.testing.expect(inst.table("nope") == null);
}

// T1.16 fixture — (module (func $f unreachable) (start $f)): the start
// function traps at instantiation, so `Module.instantiate` must fail.
const facade_start_trap_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type () -> ()
    0x03, 0x02, 0x01, 0x00, // func[0]: type 0
    0x08, 0x01, 0x00, // start: func 0
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b, // code: unreachable; end
};

test "zwasm facade T1.16: Module.instantiate surfaces a start-function trap (D-275)" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&facade_start_trap_wasm);
    defer mod.deinit();
    // The start function hits `unreachable` → instantiation fails with the
    // dedicated `StartTrapped` (not the coarse `InstantiateFailed`), via the
    // now-wired `wasm_instance_new` `trap_out` (D-275).
    try std.testing.expectError(error.StartTrapped, mod.instantiate(.{}));
}

test "public API contract — pinned dogfooding consumers" {
    // Compile-time guard on the exact `zwasm`-module symbols a pinned embedder
    // (ClojureWasm) imports. Renaming/removing any of these is a breaking change
    // for that consumer; referencing them here turns a silent downstream break
    // (surfacing only at their next pin bump) into a local CI failure.
    _ = Engine.init;
    _ = Instance;
    _ = Value;
    _ = Module.Budget;
    _ = Module.InstantiateOpts;
    _ = cli.run.PreopenDir;
    _ = cli.run.runWasmCapturedFull;
    _ = ir.zir.FuncType;
    _ = ir.zir.ValType;
    _ = wasi.host.Host;
    if (@import("build_options").enable_component) {
        _ = feature.component.host;
        _ = feature.component.types;
    }
}
