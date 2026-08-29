// FILE-SIZE-EXEMPT: single-type Instance facade (ADR-0109 §3.5); 45% in-file tests is P4-alone — insufficient for a split (investigated 2026-08-12, per ADR-0099)
//! `Instance` — native Zig facade for an instantiated module per
//! ADR-0109 §3.5 + §3.6.
//!
//! Wraps `runtime/instance/instance.zig::Instance` (aliased
//! through `src/api/instance.zig` as the public binding handle)
//! and exposes `invoke(name, args, results)` with a typed
//! `InvokeError` union of the binding-shape errors plus every
//! `runtime.Trap` variant. The previous c_api veneer (`src/zwasm.zig`)
//! collapsed the 12 trap variants onto a single `error.Trap`
//! catchall; this surface restores the per-variant precision so
//! Zig callers can branch on the specific spec condition.

const std = @import("std");
const Allocator = std.mem.Allocator;

const _api_instance = @import("../api/instance.zig");
const _runtime_value = @import("../runtime/value.zig");
const _runtime_trap = @import("../runtime/trap.zig");
const _dispatch = @import("../interp/dispatch.zig");
const _zir = @import("../ir/zir.zig");
const _runner = @import("../engine/runner.zig"); // ADR-0200 JIT engine (Zone 2)
const _trap_surface = @import("../api/trap_surface.zig"); // JIT trap_kind → TrapKind

const _memory = @import("memory.zig");
const _global = @import("global.zig");
const _table = @import("table.zig");
const _typed_func = @import("typed_func.zig");
const _vc = @import("value_conv.zig");
const _zwasm = @import("../zwasm.zig");

/// Wasm spec §4.4 — runtime trap conditions. Re-exported from
/// `runtime.Trap` (12 variants).
pub const Trap = _runtime_trap.Trap;

pub const Instance = struct {
    handle: *_api_instance.Instance,
    c_store: *_api_instance.Store,

    /// Release the instance and its underlying runtime state. Does not
    /// free the owning `Engine` / `Module` (deinit those separately).
    pub fn deinit(self: *Instance) void {
        _api_instance.wasm_instance_delete(self.handle);
    }

    /// ADR-0179 #3a — request cooperative interruption of this instance from
    /// any thread (timeout / host cancellation). The running guest traps
    /// `error.Interrupted` at the next function entry or loop back-edge poll.
    /// Idempotent. Call `clearInterrupt` before re-invoking. Routes to the
    /// active engine (ADR-0200): interp flag storage or the JIT's own flag.
    pub fn interrupt(self: *Instance) void {
        if (self.handle.runtime) |rt| {
            rt.interrupt_flag_storage.store(1, .monotonic);
        } else if (self.jitHandle()) |jit| {
            jit.requestInterrupt();
        }
    }

    /// Clear a prior `interrupt()` so this instance can be invoked again.
    pub fn clearInterrupt(self: *Instance) void {
        if (self.handle.runtime) |rt| {
            rt.interrupt_flag_storage.store(0, .monotonic);
        } else if (self.jitHandle()) |jit| {
            jit.clearInterrupt();
        }
    }

    /// Whether an interruption is currently pending (set, not yet cleared).
    pub fn interruptRequested(self: *Instance) bool {
        if (self.handle.runtime) |rt| return rt.interrupt_flag_storage.load(.monotonic) != 0;
        if (self.jitHandle()) |jit| return jit.interruptRequested();
        return false;
    }

    /// ADR-0179 #3c — impose a host max on linear-memory size, in PAGES (of
    /// memory 0's page size), an extra cap below the module's declared max.
    /// `memory.grow` past it returns the spec grow-failure (−1), not a trap.
    /// `null` clears the host cap. Routes to the active engine (ADR-0200).
    pub fn setMemoryPagesLimit(self: *Instance, max_pages: ?u64) void {
        if (self.handle.runtime) |rt| {
            rt.store_memory_pages_max = max_pages;
        } else if (self.jitHandle()) |jit| {
            jit.setMemoryPagesLimit(max_pages);
        }
    }

    /// D-316 — impose a host max on table size, in ELEMENTS, applied to every
    /// table in this instance (an extra cap below each table's declared max).
    /// `table.grow` past it returns the spec grow-failure (−1), not a trap.
    /// `null` clears the host cap. Routes to the active engine (ADR-0200).
    pub fn setTableElementsLimit(self: *Instance, max_elements: ?u64) void {
        if (self.handle.runtime) |rt| {
            rt.store_table_elements_max = max_elements;
        } else if (self.jitHandle()) |jit| {
            jit.setTableElementsLimit(max_elements);
        }
    }

    /// ADR-0179 #3b — set the deterministic execution budget (fuel). The interp
    /// decrements once per executed instruction; the JIT meters poll-site
    /// crossings (function prologue + loop back-edges) — engines meter
    /// differently by design. Both trap `error.OutOfFuel` at exhaustion. `null`
    /// = unmetered. Routes to the active engine (ADR-0200).
    pub fn setFuel(self: *Instance, fuel: ?u64) void {
        if (self.handle.runtime) |rt| {
            rt.fuel = fuel;
        } else if (self.jitHandle()) |jit| {
            jit.setFuel(fuel);
        }
    }

    /// Remaining fuel, or `null` if unmetered / no live runtime.
    pub fn fuelRemaining(self: *Instance) ?u64 {
        if (self.handle.runtime) |rt| return rt.fuel;
        if (self.jitHandle()) |jit| return jit.fuelRemaining();
        return null;
    }

    /// Wasm spec §4.5.3 — comptime-typed export-function wrapper.
    /// `Sig` must be a Zig function type whose param + result
    /// types map to Wasm scalars (i32/i64/f32/f64); multi-result
    /// signatures use an anonymous-struct return type
    /// (`fn(i32, i32) struct { i32, i32 }`). Lookup of the export
    /// itself is deferred to `.call()` so the typed wrapper is a
    /// cheap value (no syscall on construction).
    pub fn typedFunc(self: *Instance, comptime Sig: type, name: []const u8) _typed_func.TypedFunc(Sig) {
        return .{ .instance = self, .export_name = name };
    }

    /// Wasm spec §4.5.3 — one-shot typed call: the convenience
    /// shorthand for `typedFunc(Sig, name).call(args)` when a cached
    /// handle isn't needed (cold-path / one-off invocations). `Sig` is
    /// a Zig function type (see `typedFunc`); `args` is its argument
    /// tuple. Per `docs/zig_api_design.md` §3.2.
    pub fn call(
        self: *Instance,
        comptime Sig: type,
        name: []const u8,
        args: std.meta.ArgsTuple(Sig),
    ) InvokeError!@typeInfo(Sig).@"fn".return_type.? {
        return self.typedFunc(Sig, name).call(args);
    }

    /// Wasm spec §4.5.3 — surface the named export's function
    /// signature for callers that need to size args / results
    /// buffers without invoking. Returns null if the name has no
    /// matching export, the export isn't a function, or the
    /// func slot is missing. Consumed today by the wasm-3.0-spec
    /// runner's `assert_trap` path, which sizes a results buffer
    /// to `sig.results.len` before calling `invoke` (so the
    /// arity check doesn't trip before the function actually
    /// runs).
    pub fn exportFuncSig(self: *Instance, name: []const u8) ?_zir.FuncType {
        // ADR-0200 — a JIT instance populates no `func_ptrs_storage` (interp-only);
        // resolve the export signature via the JIT path over the module bytes.
        // Closes the dual-engine-facade gap incr 5 missed (cljw from_cljw_02 / D-488):
        // without this, `exportFuncSig` returned null for EVERY export on a `.jit`
        // instance, so an embedder sizing buffers before `invoke` saw ExportNotFound.
        if (self.handle.runtime == null) {
            const jit = self.jitHandle() orelse return null;
            const store = self.handle.store orelse return null;
            const alloc = _api_instance.storeAllocator(store) orelse return null;
            return jit.exportFuncSig(alloc, name);
        }
        for (self.handle.exports_storage) |exp| {
            if (!std.mem.eql(u8, exp.name, name)) continue;
            if (exp.kind != .func) return null;
            if (exp.idx >= self.handle.func_ptrs_storage.len) return null;
            return self.handle.func_ptrs_storage[exp.idx].sig;
        }
        return null;
    }

    /// Wasm spec §4.2.8 — first memory instance, if any. Wasm 1.0
    /// allows at most one per module; v0.1 of the facade returns
    /// the implicit memory0 view.
    pub fn memory(self: *Instance) ?_memory.Memory {
        if (self.handle.runtime) |rt| {
            if (rt.memory.len == 0) return null;
            return .{ .backing = .{ .interp = rt } };
        }
        // ADR-0200 increment 5 — JIT-backed instance: read the live
        // `vm_base`/`mem_limit` view (null when the module has no memory).
        if (self.jitHandle()) |jit| {
            if (jit.owned.mem_ctx == null or jit.owned.rt.mem_limit == 0) return null;
            return .{ .backing = .{ .jit = jit } };
        }
        return null;
    }

    /// Wasm spec §4.5.5/6 — accessor for an exported global by name
    /// (D-272). Returns null if the name has no matching export, the
    /// export isn't a global, or its slot is missing. The returned
    /// `Global` reads/writes the live runtime cell (`get`/`set`);
    /// `set` on an immutable global is `error.Immutable`.
    pub fn global(self: *Instance, name: []const u8) ?_global.Global {
        if (self.handle.runtime) |rt| {
            for (self.handle.exports_storage, self.handle.export_types) |exp, et| {
                if (!std.mem.eql(u8, exp.name, name)) continue;
                if (exp.kind != .global) return null;
                if (exp.idx >= rt.globals.len) return null;
                return .{
                    .backing = .{ .interp = rt },
                    .global_idx = exp.idx,
                    .valtype = et.global.valtype,
                    .mutable = et.global.mutable,
                };
            }
            return null;
        }
        // ADR-0200 increment 5 — JIT-backed instance: resolve idx/valtype/
        // mutability from the bytes (the JIT path keeps no `export_types`).
        if (self.jitHandle()) |jit| {
            const store = self.handle.store orelse return null;
            const alloc = _api_instance.storeAllocator(store) orelse return null;
            const desc = jit.exportGlobal(alloc, name) orelse return null;
            return .{
                .backing = .{ .jit = jit },
                .global_idx = desc.idx,
                .valtype = desc.valtype,
                .mutable = desc.mutable,
            };
        }
        return null;
    }

    /// Wasm spec §4.4.6/7 — accessor for an exported table by name
    /// (D-272). Returns null if the name has no matching export, the
    /// export isn't a table, or its slot is missing. The returned
    /// `Table` reads/writes the live runtime table (`get`/`set`/`size`/
    /// `grow`).
    pub fn table(self: *Instance, name: []const u8) ?_table.Table {
        if (self.handle.runtime) |rt| {
            for (self.handle.exports_storage, self.handle.export_types) |exp, et| {
                if (!std.mem.eql(u8, exp.name, name)) continue;
                if (exp.kind != .table) return null;
                if (exp.idx >= rt.tables.len) return null;
                return .{
                    .backing = .{ .interp = rt },
                    .table_idx = exp.idx,
                    .elem_type = et.table.elem_type,
                    .max = et.table.max,
                };
            }
            return null;
        }
        // ADR-0200 increment 5 — JIT-backed instance: resolve idx/reftype/max
        // from the bytes (the JIT path keeps no `export_types`).
        if (self.jitHandle()) |jit| {
            const store = self.handle.store orelse return null;
            const alloc = _api_instance.storeAllocator(store) orelse return null;
            const desc = jit.exportTable(alloc, name) orelse return null;
            return .{
                .backing = .{ .jit = jit },
                .table_idx = desc.idx,
                .elem_type = desc.elem_type,
                .max = desc.max,
            };
        }
        return null;
    }

    /// Binding-shape errors (mismatched export name / kind / arity)
    /// in union with the full `runtime.Trap` set. Every spec trap
    /// condition is individually addressable — `error.DivByZero`,
    /// `error.OutOfBoundsLoad`, etc. — per ADR-0109 §3.6.
    pub const InvokeError = error{
        ExportNotFound,
        NotAFunc,
        ArgArityMismatch,
        ResultArityMismatch,
        /// A WASI host function requested process exit (e.g. `wasi:cli/exit`):
        /// the host records the exit code out-of-band and returns this to unwind
        /// the guest (a clean noreturn termination, NOT a wasm trap). The
        /// component-run caller catches it and reads the recorded code.
        ProcExit,
        /// ADR-0200 — the selected engine (currently the JIT) cannot yet invoke
        /// this export's signature (e.g. v128 / ref args, FP/v128 results, or an
        /// arity past the host-invoke thunk coverage). The interp engine has no
        /// such gap; surface it distinctly so a host can fall back to `.interp`.
        UnsupportedEngineSignature,
    } || Trap;

    /// Wasm spec §4.5.3 + §4.4 — invoke an exported function by name.
    /// `args` / `results` are raw `Value` slices (the TypedFunc path
    /// at J.4 wraps this with a comptime marshal layer).
    pub fn invoke(
        self: *Instance,
        name: []const u8,
        args: []const _zwasm.Value,
        results: []_zwasm.Value,
    ) InvokeError!void {
        // ADR-0200 — JIT-backed instance (`runtime == null`, `jit` set): route
        // to the native engine. The interp body below assumes `runtime != null`.
        if (self.handle.runtime == null) {
            if (self.jitHandle()) |jit| return self.invokeJit(jit, name, args, results);
            return error.ExportNotFound; // no engine attached
        }

        // ADR-0179 #3a: the facade runs the body via `dispatch.run` directly
        // (not `mvp.invoke`), so the function-entry interrupt poll must happen
        // here; the throttled loop poll inside `dispatch.run` covers tight loops.
        if (self.handle.runtime) |rt0| try rt0.checkInterrupt();
        const found_idx = blk: {
            for (self.handle.exports_storage) |exp| {
                if (!std.mem.eql(u8, exp.name, name)) continue;
                if (exp.kind != .func) return error.NotAFunc;
                break :blk exp.idx;
            }
            return error.ExportNotFound;
        };

        // D-201a — a re-exported IMPORTED func occupies the empty-sig
        // `unreachable` placeholder in `func_ptrs_storage`; invoking it
        // by name must dispatch CROSS-MODULE via the `host_calls` thunk
        // (which reads args off the operand stack + pushes results) using
        // the SOURCE func's sig, not run the placeholder body.
        if (self.handle.runtime) |rt0| {
            if (found_idx < rt0.host_calls.len and found_idx < rt0.func_entities.len) {
                if (rt0.host_calls[found_idx]) |hc| {
                    const fe = rt0.func_entities[found_idx];
                    if (fe.func_idx >= fe.runtime.funcs.len) return error.ExportNotFound;
                    const isig = fe.runtime.funcs[fe.func_idx].sig;
                    if (args.len != isig.params.len) return error.ArgArityMismatch;
                    if (results.len != isig.results.len) return error.ResultArityMismatch;
                    const op_base = rt0.operand_len;
                    for (args) |a| rt0.pushOperand(_vc.zwasmToRuntime(a)) catch |e| {
                        rt0.operand_len = op_base;
                        return mapDispatchErr(e);
                    };
                    hc.fn_ptr(rt0, hc.ctx) catch |err| {
                        rt0.operand_len = op_base;
                        return mapDispatchErr(err);
                    };
                    if (rt0.operand_len < op_base + isig.results.len) {
                        rt0.operand_len = op_base;
                        return error.ResultArityMismatch;
                    }
                    var ri: usize = isig.results.len;
                    while (ri > 0) {
                        ri -= 1;
                        results[ri] = _vc.runtimeToZwasm(rt0.operand_buf[op_base + ri], isig.results[ri]);
                    }
                    rt0.operand_len = op_base;
                    return;
                }
            }
        }

        if (found_idx >= self.handle.func_ptrs_storage.len) return error.ExportNotFound;
        const zfunc = self.handle.func_ptrs_storage[found_idx];
        const sig = zfunc.sig;

        if (args.len != sig.params.len) return error.ArgArityMismatch;
        if (results.len != sig.results.len) return error.ResultArityMismatch;

        const rt = self.handle.runtime orelse return error.ExportNotFound;
        const store = self.handle.store orelse return error.ExportNotFound;
        const alloc = _api_instance.storeAllocator(store) orelse return error.OutOfMemory;

        const num_locals = sig.params.len + zfunc.locals.len;
        const locals = try alloc.alloc(_runtime_value.Value, num_locals);
        defer alloc.free(locals);
        for (locals) |*l| l.* = _runtime_value.Value.zero;
        for (args, 0..) |a, idx| locals[idx] = _vc.zwasmToRuntime(a);

        const op_base = rt.operand_len;
        try rt.pushFrame(.{
            .sig = sig,
            .locals = locals,
            .operand_base = op_base,
            .pc = 0,
            .func = zfunc,
        });

        _dispatch.run(rt, _api_instance.dispatchTable(), zfunc.instrs.items) catch |err| {
            _ = rt.popFrame();
            rt.operand_len = op_base;
            return mapDispatchErr(err);
        };
        _ = rt.popFrame();

        if (rt.operand_len < op_base + sig.results.len) {
            rt.operand_len = op_base;
            return error.ResultArityMismatch;
        }

        var i: usize = sig.results.len;
        while (i > 0) {
            i -= 1;
            const v = rt.operand_buf[op_base + i];
            results[i] = _vc.runtimeToZwasm(v, sig.results[i]);
        }
        rt.operand_len = op_base;
    }

    /// ADR-0200 — cast the Zone-1 `Instance.jit` opaque slot to the engine type
    /// at the Zone-3 boundary. Null for an interp-backed (or empty) instance.
    fn jitHandle(self: *Instance) ?*_runner.JitInstance {
        const jp = self.handle.jit orelse return null;
        return @ptrCast(@alignCast(jp));
    }

    /// ADR-0200 — JIT engine invoke arm. Resolves the export sig (for arity +
    /// result typing), marshals scalar args to the JIT's u64 bit-carriers, runs
    /// via `JitInstance.invoke`, and unpacks the single scalar result. v128 / ref
    /// args+results and uncovered arities surface `UnsupportedEngineSignature`
    /// (the JIT host-invoke coverage gap — a host may retry on `.interp`).
    fn invokeJit(
        self: *Instance,
        jit: *_runner.JitInstance,
        name: []const u8,
        args: []const _zwasm.Value,
        results: []_zwasm.Value,
    ) InvokeError!void {
        const store = self.handle.store orelse return error.ExportNotFound;
        const alloc = _api_instance.storeAllocator(store) orelse return error.OutOfMemory;

        const sig = jit.exportFuncSig(alloc, name) orelse return error.ExportNotFound;
        if (args.len != sig.params.len) return error.ArgArityMismatch;
        if (results.len != sig.results.len) return error.ResultArityMismatch;

        if (args.len > 16) return error.UnsupportedEngineSignature;
        var abuf: [16]u64 = undefined;
        for (args, 0..) |a, i| abuf[i] = jitArgBits(a);

        // Multi-value results route through the ADR-0106 wrapper-thunk buffer
        // (self-describing `TypedResult`); single/void use the scalar `invoke`.
        if (sig.results.len > 1) {
            if (results.len > 16) return error.UnsupportedEngineSignature;
            var rbuf: [16]_runner.TypedResult = undefined;
            jit.invokeMulti(alloc, name, abuf[0..args.len], rbuf[0..results.len]) catch |err|
                return mapJitErr(err, jit);
            for (results, 0..) |*r, i| r.* = typedResultToValue(rbuf[i]);
            return;
        }

        const got = jit.invoke(alloc, name, abuf[0..args.len]) catch |err|
            return mapJitErr(err, jit);

        if (sig.results.len == 0) return;
        // Single-result shape. `got == null` ⇒ the result ran via the JIT void
        // path (a ref result run for side effects — D-222): no scalar to unpack,
        // so a ref result is not yet retrievable through this arm (a later slice
        // routes ref/v128/multi results via `invokeMulti`). Scalars decode by
        // valtype.
        const bits = got orelse return error.UnsupportedEngineSignature;
        results[0] = jitResultValue(sig.results[0], bits) orelse
            return error.UnsupportedEngineSignature;
    }
};

/// ADR-0200 — marshal a facade `Value` to the JIT host-invoke u64 bit-carrier
/// (declaration order). i32/f32 occupy the low 32 bits. v128/ref carriers are
/// passed through but `JitInstance.invoke` rejects those param kinds before use.
fn jitArgBits(v: _zwasm.Value) u64 {
    return switch (v) {
        .i32 => |x| @as(u64, @as(u32, @bitCast(x))),
        .i64 => |x| @bitCast(x),
        .f32 => |b| @as(u64, b),
        .f64 => |b| b,
        .v128 => |b| @truncate(b),
        .funcref => |r| r orelse 0,
        .externref => |r| r orelse 0,
    };
}

/// ADR-0200 — decode a JIT scalar result u64 into a facade `Value` by valtype.
/// Null for v128 / ref results (not retrievable via the single-u64 arm).
fn jitResultValue(vt: _zir.ValType, bits: u64) ?_zwasm.Value {
    return switch (vt) {
        .i32 => .{ .i32 = @bitCast(@as(u32, @truncate(bits))) },
        .i64 => .{ .i64 = @bitCast(bits) },
        .f32 => .{ .f32 = @truncate(bits) },
        .f64 => .{ .f64 = bits },
        .v128 => null,
        .ref => null,
    };
}

/// ADR-0200 — decode a self-describing JIT `TypedResult` (multi-value path) to a
/// facade `Value`. A zero ref carrier marshals to a null ref (per `value_conv`).
fn typedResultToValue(tr: _runner.TypedResult) _zwasm.Value {
    return switch (tr) {
        .i32 => |x| .{ .i32 = @bitCast(x) },
        .i64 => |x| .{ .i64 = @bitCast(x) },
        .f32 => |x| .{ .f32 = x },
        .f64 => |x| .{ .f64 = x },
        .funcref => |x| .{ .funcref = if (x == 0) null else x },
        .externref => |x| .{ .externref = if (x == 0) null else x },
    };
}

/// ADR-0200 — map a JIT engine error to the facade `InvokeError`. Runtime traps
/// surface as `entry.Error.Trap` with a numeric kind on the JIT runtime; the
/// compile-time-only `runner.Error` variants cannot arise from a post-instantiate
/// invoke (the module already compiled) — reaching one is a bug.
fn mapJitErr(err: _runner.Error, jit: *_runner.JitInstance) Instance.InvokeError {
    return switch (err) {
        error.ExportNotFound => error.ExportNotFound,
        error.ExportIsNotFunction => error.NotAFunc,
        error.UnsupportedEntrySignature => error.UnsupportedEngineSignature,
        error.OutOfMemory => error.OutOfMemory,
        error.Trap => jitTrapToError(jit.owned.rt.trap_kind),
        else => @panic("zwasm.Instance.invokeJit: compile-time runner.Error from a post-instantiate invoke"),
    };
}

/// ADR-0200 — map the JIT runtime's numeric `trap_kind` (recorded by a trap
/// stub or, for host-originated traps, by a host thunk) to the facade `Trap`
/// error. The generic bucket (codes the codegen does not yet distinguish,
/// D-292) maps to `error.Unreachable` — honest pending the per-kind codegen
/// widening; `oob_memory` collapses load/store (same D-292 gap).
fn jitTrapToError(code: u32) Instance.InvokeError {
    const kind = _trap_surface.jitTrapCode(code) orelse return error.Unreachable;
    return switch (kind) {
        .unreachable_ => error.Unreachable,
        .div_by_zero => error.DivByZero,
        .int_overflow => error.IntOverflow,
        .invalid_conversion => error.InvalidConversionToInt,
        .oob_memory => error.OutOfBoundsLoad,
        .oob_table => error.OutOfBoundsTableAccess,
        .uninitialized_elem => error.UninitializedElement,
        .indirect_call_mismatch => error.IndirectCallTypeMismatch,
        .stack_overflow => error.StackOverflow,
        .out_of_memory => error.OutOfMemory,
        .null_reference => error.NullReference,
        .cast_failure => error.CastFailure,
        .uncaught_exception => error.UncaughtException,
        .unaligned_atomic => error.UnalignedAtomic,
        .expected_shared_memory => error.ExpectedSharedMemory,
        .interrupted => error.Interrupted,
        .out_of_fuel => error.OutOfFuel,
        .wasi_exit => error.ProcExit, // #331 — a clean WASI termination, not a fault
        .binding_error => error.HostTrap, // #331 — the embedder's own failure
    };
}

/// Narrow `dispatch.run`'s `anyerror!void` return back to the
/// `Trap`-shaped set the spec actually defines. `else => @panic`
/// guards against future dispatch additions that emit non-Trap
/// errors (a new variant must be added to `runtime.Trap` and
/// echoed here — caught at compile time of the new path's tests).
fn mapDispatchErr(err: anyerror) Instance.InvokeError {
    return switch (err) {
        error.Unreachable => error.Unreachable,
        error.DivByZero => error.DivByZero,
        error.IntOverflow => error.IntOverflow,
        error.InvalidConversionToInt => error.InvalidConversionToInt,
        error.OutOfBoundsLoad => error.OutOfBoundsLoad,
        error.OutOfBoundsStore => error.OutOfBoundsStore,
        error.OutOfBoundsTableAccess => error.OutOfBoundsTableAccess,
        error.UninitializedElement => error.UninitializedElement,
        error.IndirectCallTypeMismatch => error.IndirectCallTypeMismatch,
        error.StackOverflow => error.StackOverflow,
        error.CallStackExhausted => error.CallStackExhausted,
        error.NullReference => error.NullReference,
        error.UncaughtException => error.UncaughtException,
        error.CastFailure => error.CastFailure, // Wasm 3.0 GC ref.cast (10.G c152)
        error.UnalignedAtomic => error.UnalignedAtomic, // Wasm threads (ADR-0168)
        error.ExpectedSharedMemory => error.ExpectedSharedMemory, // Wasm threads (ADR-0168)
        error.Interrupted => error.Interrupted, // host timeout/cancel (ADR-0179 #3a)
        error.OutOfFuel => error.OutOfFuel, // host fuel budget exhausted (ADR-0179 #3b)
        error.HostTrap => error.HostTrap, // a host callback trapped (#331)
        error.OutOfMemory => error.OutOfMemory,
        // GC heap 4 GiB cap exceeded (huge array.new* / struct.new) — surfaces
        // as the OutOfMemory trap ("allocation size too large"; wasmtime
        // gc/array-alloc-too-large). The JIT path traps via its 0-sentinel.
        error.OutOfHeap => error.OutOfMemory,
        // A host func (e.g. wasi:cli/exit) requested process exit — unwind cleanly.
        error.ProcExit => error.ProcExit,
        else => @panic("zwasm.Instance.invoke: dispatch returned non-Trap error variant"),
    };
}

const testing = std.testing;

test "facade Instance.interrupt(): a pending interrupt traps the next invoke; clear re-enables (ADR-0179 #3a-2)" {
    // (module (func (export "f") (result i32) (i32.const 42)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->(i32)
        0x03, 0x02, 0x01, 0x00, // func: 1× type 0
        0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00, // export "f" = func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42; end
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    // D-499 — pin .interp: trivial-fn fuel/interrupt is not trapped on x86_64 JIT (poll
    // only emitted for runtime-ptr-using fns); runaway-safety intact (loops polled).
    var inst = try mod.instantiate(.{ .engine = .interp });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};

    // Baseline: runs to completion.
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);

    // Host requests interruption → the next invoke traps at function entry.
    try testing.expect(!inst.interruptRequested());
    inst.interrupt();
    try testing.expect(inst.interruptRequested());
    try testing.expectError(error.Interrupted, inst.invoke("f", &.{}, &results));

    // Cleared → runs to completion again.
    inst.clearInterrupt();
    try testing.expect(!inst.interruptRequested());
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "facade engine=.jit: MIXED 2-arg (i32,f64)->f64 export invoke (cljw from_cljw_04 — veneer falls through to buffer path)" {
    // (module (func (export "mix") (param i32 f64) (result f64)
    //   local.get 1 local.get 0 f64.convert_i32_s f64.add))  ;; f64param + (f64)i32param
    // The 2-arg veneer (dispatchScalar2) lacks the mixed (i32,f64)→f64 key; it must fall
    // through to the buffer-write thunk instead of trapping (cljw from_cljw_04).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7c, 0x01, 0x7c, // (i32 f64)->f64
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x07, 0x01, 0x03, 0x6d, 0x69, 0x78, 0x00, 0x00, // export "mix"
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x01, 0x20, 0x00,
        0xb7, 0xa0, 0x0b,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .f64 = 0 }};
    try inst.invoke("mix", &.{ .{ .i32 = 3 }, .{ .f64 = @bitCast(@as(f64, 1.5)) } }, &results);
    try testing.expectEqual(@as(f64, 4.5), @as(f64, @bitCast(results[0].f64))); // 1.5 + 3.0
}

test "facade engine=.jit: 3-arg f64 export invoke via the buffer-write path (D-477 — typical wide shape)" {
    // (module (func (export "add3") (param f64 f64 f64) (result f64)
    //   local.get 0 local.get 1 f64.add local.get 2 f64.add))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x01, 0x60, 0x03, 0x7c, 0x7c, 0x7c, 0x01, 0x7c, // (f64 f64 f64)->f64
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x08, 0x01, 0x04, 0x61, 0x64, 0x64, 0x33, 0x00, 0x00, // export "add3"
        0x0a, 0x0c, 0x01, 0x0a, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa0,
        0x20, 0x02, 0xa0, 0x0b,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .f64 = 0 }};
    try inst.invoke("add3", &.{
        .{ .f64 = @bitCast(@as(f64, 1.5)) },
        .{ .f64 = @bitCast(@as(f64, 2.25)) },
        .{ .f64 = @bitCast(@as(f64, 0.25)) },
    }, &results);
    try testing.expectEqual(@as(f64, 4.0), @as(f64, @bitCast(results[0].f64)));
}

test "facade engine=.jit: i32.div_s by zero traps DivByZero (not a binding error) — wast misc_traps/divbyzero" {
    // (module (func (export "div") (param i32 i32) (result i32) local.get 0 local.get 1 i32.div_s))
    // (i32,i32)->i32 is a covered dispatch key, so the JIT body runs + traps; the facade
    // must surface the SPECIFIC DivByZero trap (the .auto-flip ubuntu run showed a
    // 'binding_error' here — probing whether basic JIT trap-kind mapping is correct).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32 i32)->i32
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x07, 0x01, 0x03, 0x64, 0x69, 0x76, 0x00, 0x00, // export "div"
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6d, 0x0b, // local.get 0/1; i32.div_s
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};
    try testing.expectError(error.DivByZero, inst.invoke("div", &.{ .{ .i32 = 1 }, .{ .i32 = 0 } }, &results));
}

test "facade engine=.jit: f64 (FP-bank) param+result export invoke (cljw from_cljw_03)" {
    // (module (func (export "addf") (param f64 f64) (result f64) local.get 0 local.get 1 f64.add))
    // cljw reported f64 export-invoke TRAPS on JIT (interp returns 3.75) — the FP-bank
    // arg placement / f64-result retrieval in the host→guest entry trampoline.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7c, // type: (f64 f64)->f64
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x08, 0x01, 0x04, 0x61, 0x64, 0x64, 0x66, 0x00, 0x00, // export "addf"
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa0, 0x0b, // local.get 0/1; f64.add
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .f64 = 0 }};
    try inst.invoke("addf", &.{ .{ .f64 = @bitCast(@as(f64, 1.5)) }, .{ .f64 = @bitCast(@as(f64, 2.25)) } }, &results);
    try testing.expectEqual(@as(f64, 3.75), @as(f64, @bitCast(results[0].f64)));
}

test "facade engine=.jit: opt-in JIT instance invokes a no-import compute export (ADR-0200)" {
    // (module (func (export "add") (param i32 i32) (result i32)
    //   local.get 0 local.get 1 i32.add))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32 i32)->i32
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code: i32.add
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();
    try testing.expect(inst.handle.runtime == null); // JIT-backed: no interp runtime
    try testing.expect(inst.handle.jit != null);

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};
    try inst.invoke("add", &.{ .{ .i32 = 2 }, .{ .i32 = 3 } }, &results);
    try testing.expectEqual(@as(i32, 5), results[0].i32);
}

test "facade engine=.jit: exportFuncSig resolves an export signature (cljw from_cljw_02 / D-488)" {
    // (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09,
        0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
        0x0b,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();
    try testing.expect(inst.handle.runtime == null); // JIT-backed

    // exportFuncSig must resolve on a JIT instance (func_ptrs_storage is empty there).
    const sig = inst.exportFuncSig("add") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), sig.params.len);
    try testing.expectEqual(@as(usize, 1), sig.results.len);
    try testing.expect(sig.results[0] == .i32);
    try testing.expect(sig.params[0] == .i32);
    // a name that is not an exported function → null (not a crash).
    try testing.expect(inst.exportFuncSig("nope") == null);
}

test "facade engine=.jit: a SIMD-body export executes on the JIT (scalar boundary) (ADR-0200)" {
    // (module (func (export "lane0") (result i32)
    //   (i32x4.extract_lane 0 (v128.const i32x4 42 0 0 0))))
    // SIMD ops run in the JIT-compiled body; the i32 result returns via the
    // scalar thunk. This is the user's "SIMD must be JIT" constraint met through
    // the embedding API — v128 AT the host-call boundary stays niche debt (D-477).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->i32
        0x03, 0x02, 0x01, 0x00, // func type 0
        0x07, 0x09, 0x01, 0x05, 0x6c, 0x61, 0x6e, 0x65, 0x30, 0x00, 0x00, // export "lane0"
        0x0a, 0x19, 0x01, 0x17, 0x00, // code: size 0x17, 0 locals
        0xfd, 0x0c, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // v128.const i32x4 42,0,0,0
        0xfd, 0x1b, 0x00, // i32x4.extract_lane 0
        0x0b, // end
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};
    try inst.invoke("lane0", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "facade engine=.jit: multi-result scalar export via invokeMulti (ADR-0200)" {
    // (module (func (export "swap2") (param i32 i32) (result i32 i32)
    //   local.get 1 local.get 0))  — returns (b, a)
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x02, 0x7f, 0x7f, // (i32 i32)->(i32 i32)
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x09, 0x01, 0x05, 0x73, 0x77, 0x61, 0x70, 0x32, 0x00, 0x00, // export "swap2"
        0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x01, 0x20, 0x00, 0x0b, // local.get 1; local.get 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{ .{ .i32 = 0 }, .{ .i32 = 0 } };
    try inst.invoke("swap2", &.{ .{ .i32 = 7 }, .{ .i32 = 9 } }, &results);
    try testing.expectEqual(@as(i32, 9), results[0].i32);
    try testing.expectEqual(@as(i32, 7), results[1].i32);
}

test "facade engine=.jit: a satisfiable WASI import dispatches (sched_yield → 0) (ADR-0200 / D-451)" {
    // (module (import "wasi_snapshot_preview1" "sched_yield" (func (result i32)))
    //         (func (export "f") (result i32) call 0))  — f returns the errno (0).
    // sched_yield needs no host/memory; proves a WASI import resolves to its JIT
    // dispatch thunk (not a trap-on-call stub) under the facade JIT path.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->i32
        0x02, 0x26, 0x01, // import section
        0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, // "wasi_snapshot_preview1"
        0x0b, 0x73, 0x63, 0x68, 0x65, 0x64, 0x5f, 0x79, 0x69, 0x65, 0x6c, 0x64, // "sched_yield"
        0x00, 0x00, // func, typeidx 0
        0x03, 0x02, 0x01, 0x00, // func: 1× type 0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01, // export "f" = func 1
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b, // code: call 0; end
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = -1 }};
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 0), results[0].i32); // Errno.success
}

test "facade engine=.jit: an unsatisfiable import fails instantiation (ADR-0200 / D-451)" {
    // (module (import "env" "foo" (func)))  — "env.foo" is not a WASI export, so
    // the JIT path rejects it at instantiate (not a trap-on-call stub), mirroring
    // the interp linker's UnknownImport.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: ()->()
        0x02, 0x0b, 0x01, // import section
        0x03, 0x65, 0x6e, 0x76, // "env"
        0x03, 0x66, 0x6f, 0x6f, // "foo"
        0x00, 0x00, // func, typeidx 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    try testing.expectError(error.InstantiateFailed, mod.instantiate(.{ .engine = .jit }));
}

test "facade engine=.jit: interrupt traps the next invoke; clear re-enables (ADR-0200 / D-314)" {
    // f calls g → the calling fn pins the runtime ptr so the prologue interrupt
    // poll is emitted on BOTH arches (a no-call fn has no poll on x86_64).
    // (module (func $g (result i32) i32.const 42)
    //         (func (export "f") (result i32) call $g))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x07, 0x05, 0x01, 0x01,
        0x66, 0x00, 0x01, 0x0a, 0x0b, 0x02, 0x04, 0x00, 0x41, 0x2a, 0x0b, 0x04,
        0x00, 0x10, 0x00, 0x0b,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);

    try testing.expect(!inst.interruptRequested());
    inst.interrupt();
    try testing.expect(inst.interruptRequested());
    try testing.expectError(error.Interrupted, inst.invoke("f", &.{}, &results));

    inst.clearInterrupt();
    try testing.expect(!inst.interruptRequested());
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "facade engine=.jit: setFuel bounds an expensive loop with OutOfFuel (ADR-0200)" {
    // (func (export "f") (result i32) (local $i i32)
    //   (local.set $i (i32.const 1000000))
    //   (loop $L (local.set $i (i32.sub (local.get $i) 1)) (br_if $L (local.get $i)))
    //   (i32.const 42))  — ~1e6 back-edge poll crossings.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x1c, 0x01, 0x1a, 0x01, 0x01, 0x7f, 0x41, 0xc0, 0x84,
        0x3d, 0x21, 0x00, 0x03, 0x40, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x21, 0x00,
        0x20, 0x00, 0x0d, 0x00, 0x0b, 0x41, 0x2a, 0x0b,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    inst.setFuel(100); // « the ~1e6 back-edge crossings the loop needs
    var results = [_]_zwasm.Value{.{ .i32 = 0 }};
    try testing.expectError(error.OutOfFuel, inst.invoke("f", &.{}, &results));
}

test "facade setMemoryPagesLimit: host cap refuses memory.grow past it (ADR-0179 #3c)" {
    // (module (memory (export "m") 1))  — min 1 page, no declared max.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1× {min 1}
        0x07, 0x05, 0x01, 0x01, 'm', 0x02, 0x00, // export "m" = memory 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    inst.setMemoryPagesLimit(2); // host cap = 2 pages (below the spec max)
    const mem = inst.memory() orelse return error.NoMemory;

    try testing.expectEqual(@as(?u32, 1), mem.grow(1)); // 1 → 2 OK (old size 1)
    try testing.expectEqual(@as(?u32, null), mem.grow(1)); // 2 → 3 refused by host cap

    inst.setMemoryPagesLimit(4); // raise the cap → growth allowed again
    try testing.expectEqual(@as(?u32, 2), mem.grow(1)); // 2 → 3 OK

    inst.setMemoryPagesLimit(null); // clear host cap
    try testing.expectEqual(@as(?u32, 3), mem.grow(1)); // 3 → 4 OK (spec max only)
}

test "facade setTableElementsLimit: host cap refuses table.grow past it (D-316)" {
    // (module (table (export "t") 1 funcref))  — min 1, no declared max.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: 1× funcref {min 1}
        0x07, 0x05, 0x01, 0x01, 't', 0x01, 0x00, // export "t" = table 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .interp });
    defer inst.deinit();

    inst.setTableElementsLimit(3); // host cap = 3 elements (below the spec max)
    const tab = inst.table("t") orelse return error.NoTable;
    const nullref = _zwasm.Value{ .funcref = null };

    try tab.grow(2, nullref); // 1 → 3 OK (at the cap)
    try testing.expectError(error.GrowFailed, tab.grow(1, nullref)); // 3 → 4 refused

    inst.setTableElementsLimit(5); // raise the cap → growth allowed again
    try tab.grow(2, nullref); // 3 → 5 OK

    inst.setTableElementsLimit(null); // clear host cap
    try tab.grow(1, nullref); // 5 → 6 OK (no declared/spec table max here)
}

test "facade setFuel: exhausted budget traps OutOfFuel; ample budget completes + drains (ADR-0179 #3b)" {
    // (module (func (export "f") (result i32) (i32.const 42)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->(i32)
        0x03, 0x02, 0x01, 0x00, // func: 1× type 0
        0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00, // export "f" = func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42; end
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    // D-499 — pin .interp: trivial-fn fuel/interrupt is not trapped on x86_64 JIT (poll
    // only emitted for runtime-ptr-using fns); runaway-safety intact (loops polled).
    var inst = try mod.instantiate(.{ .engine = .interp });
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};

    // Zero budget → the first instruction traps deterministically.
    inst.setFuel(0);
    try testing.expectError(error.OutOfFuel, inst.invoke("f", &.{}, &results));

    // Ample budget → completes, and instructions were charged.
    inst.setFuel(1000);
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
    const rem = inst.fuelRemaining() orelse return error.NoFuel;
    try testing.expect(rem < 1000);

    // Unmetered → always completes.
    inst.setFuel(null);
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "facade Instance.call: one-shot typed shorthand matches typedFunc().call (docs §3.2)" {
    // (module (func (export "add") (param i32 i32) (result i32)
    //   (i32.add (local.get 0) (local.get 1))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32,i32)->(i32)
        0x03, 0x02, 0x01, 0x00, // func: 1× type 0
        0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00, // export "add" = func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // local.get 0,1; i32.add; end
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const Sig = fn (i32, i32) i32;
    const shorthand = try inst.call(Sig, "add", .{ 2, 3 });
    const via_handle = try inst.typedFunc(Sig, "add").call(.{ 2, 3 });
    try testing.expectEqual(@as(i32, 5), shorthand);
    try testing.expectEqual(via_handle, shorthand);

    // Missing export surfaces through the same InvokeError channel.
    try testing.expectError(error.ExportNotFound, inst.call(Sig, "nope", .{ 1, 1 }));
}
