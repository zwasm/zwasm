//! WASM Spec §4.4 "Traps" — runtime trap conditions + tracing
//! support hooks.
//!
//! `Trap` is the zwasm-internal error set; the wasm-c-api binding
//! marshals these into `wasm_trap_t` via `api/trap_surface.zig`
//! per ADR-0023 §3. The trace types support optional per-instr
//! observation (Phase 6 / ADR-0013) used by §9.6 / 6.A
//! investigation flows and the WAST runner's `--trace` mode.
//!
//! Zone 1 (`src/runtime/`).

const value = @import("value.zig");
const zir = @import("../ir/zir.zig");

/// Trap conditions. The dispatch loop returns one of these on the
/// `Trap!` error union when a runtime-checked invariant fails.
/// `OutOfMemory` is included so allocator-backed paths can bubble
/// up uniformly.
pub const Trap = error{
    Unreachable,
    DivByZero,
    IntOverflow,
    InvalidConversionToInt,
    OutOfBoundsLoad,
    OutOfBoundsStore,
    OutOfBoundsTableAccess,
    UninitializedElement,
    IndirectCallTypeMismatch,
    StackOverflow,
    CallStackExhausted,
    OutOfMemory,
    /// Wasm 3.0 typed function references (§3.3.8): `ref.as_non_null`
    /// trap on null ref. Spec message: "null reference".
    NullReference,
    /// Wasm 3.0 exception-handling proposal (§3.3.10.7 / §4.5):
    /// `throw` / `throw_ref` raised an exception that escaped the
    /// outermost function without a matching catch in any
    /// enclosing `try_table` frame. Phase 10's interp foundation
    /// (10.E-4) traps uncaught exceptions immediately; full catch
    /// dispatch + frame unwind lands at 10.E-5.
    UncaughtException,
    /// Wasm 3.0 GC (§4.4.5): `ref.cast` / `ref.cast_null` whose operand's
    /// runtime type is not a subtype of the target heap type (or a null
    /// operand for the non-null `ref.cast` variant). Spec reason: "cast
    /// failure". (10.G cycle 152.)
    CastFailure,
    /// Wasm threads/atomics proposal (§exec, ADR-0168): an atomic
    /// memory access (`*.atomic.load` / `.store` / `.rmw*` / `notify`
    /// / `wait*`) whose effective address is not naturally aligned
    /// (ea mod N/8 ≠ 0). Distinct from out-of-bounds; spec reason:
    /// "unaligned atomic". Checked before the bounds test.
    UnalignedAtomic,
    /// Wasm threads/atomics proposal (§exec, ADR-0168): `memory.atomic.
    /// wait{32,64}` executed against a memory that is not shared. Spec
    /// requires the memory be shared; non-shared traps. Spec reason:
    /// "expected shared memory". (`notify` does NOT require shared.)
    ExpectedSharedMemory,
    /// Host-requested execution interruption (ADR-0179, Tier-1 #3a): a
    /// timeout deadline elapsed or a host thread requested cancellation.
    /// Cooperative — the guest polls a host-owned flag at function entry +
    /// loop back-edges and traps here. Spec-external (embedder resource
    /// control), surfaced as a trap. Spec reason: "interrupt".
    Interrupted,
    /// Host-imposed deterministic instruction-budget exhausted (ADR-0179 #3b):
    /// the per-`Runtime` fuel counter reached 0. Spec-external (embedder
    /// resource control); deterministic (decrements once per executed interp
    /// instruction). Spec reason: "all fuel consumed".
    OutOfFuel,
    /// A host callback returned a trap, or the embedder binding could not
    /// complete the call (issue #331). Host-originated: nothing in the guest
    /// faulted, so this must not be conflated with `Unreachable`. Spec-external,
    /// same class as `Interrupted` / `OutOfFuel`. Surfaces as `binding_error`
    /// ("host invocation error") on the C ABI.
    HostTrap,
};

/// Per-instruction trace event (Phase 6 / §9.6 / 6.A per ADR-0013).
/// Emitted post-handler when `Runtime.trace_cb` is set; consumed by
/// the runtime-asserting WAST runner's `--trace` mode and by §9.6 /
/// 6.E interp behaviour bug investigation. Zero-cost when disabled
/// (one predicted-not-taken branch in the dispatch loop).
pub const TraceEvent = struct {
    pc: u32,
    op: zir.ZirOp,
    /// Top-of-stack value AFTER the handler ran. `null` when the
    /// stack is empty (e.g. after a `drop` that empties it).
    operand_top: ?value.Value,
    frame_depth: u32,
};

pub const TraceCallback = *const fn (ctx: *anyopaque, ev: TraceEvent) void;
