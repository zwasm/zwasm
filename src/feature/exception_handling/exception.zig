//! Wasm 3.0 EH Exception heap object (10.E-exnref-a, per ADR-0114 D1).
//!
//! Allocated per `throw` from the Runtime's allocator (lifetime
//! managed by `Runtime.live_exceptions` tracker until `Runtime.deinit`).
//! The interp `throwOp` initialises the fields; the unwinder reads
//! `tag_idx` for catch matching and copies `payload[0..payload_len]`
//! onto the catch target's stack.
//!
//! For Wasm 3.0 / pre-GC milestones the object is keyed by `tag_idx`
//! into the module's tag-section index rather than ADR-0114 D1's
//! eventual `*TagInstance` (TagInstance lands when import/export
//! resolution wires cross-module tag identity — until then,
//! single-module throw/catch uses the validator-guaranteed in-range
//! `tag_idx` as the matching key).
//!
//! `payload` is inline (fixed-size `max_payload`) rather than the
//! ADR's `[*]Value` heap slice — the interp variant trades a small
//! upper bound on tag-param arity for one allocation per throw. The
//! codegen-side `zwasm_throw` trampoline (ADR-0114 D6, future
//! impl) can switch to the heap-slice form when arena pressure
//! warrants it; the interp consumer only depends on the
//! `payload[0..payload_len]` view.
//!
//! Zone 1 (`src/feature/exception_handling/`); see ROADMAP §4.1 / §A1.

const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const TagInstance = @import("tag.zig").TagInstance;

/// Upper bound on per-exception payload values. Matches
/// `Runtime.max_exception_payload` (= `max_block_arity` in the
/// interp). A tag with > 16 params is rejected at validation time
/// by the same arity cap that gates `throwOp`'s stack-local
/// payload buffer.
pub const max_payload: u32 = 16;

pub const Exception = struct {
    tag_idx: u32,
    /// ADR-0114 D1 tag identity (10.E-eh-tail). Set by `throwOp` to
    /// `rt.tags[tag_idx]`; catch matches by pointer. `null` only on
    /// the legacy/no-tags path (catch then falls back to `tag_idx`).
    tag: ?*TagInstance = null,
    /// The JIT's counterpart to `tag`: the globally comparable identity from
    /// the throwing instance's `tag_ids` (ADR-0134 D3). A reified `exnref`
    /// keeps it so a later `throw_ref` names the ORIGINAL tag, whatever local
    /// index — or none — the rethrowing module has for it (#426 review).
    /// `tag_idx` alone cannot: indices are per module. 0 = not set (the interp
    /// path, which matches on `tag`).
    jit_tag_id: u64 = 0,
    payload_len: u32,
    payload: [max_payload]Value,

    pub fn init(tag_idx: u32, payload_in: []const Value) Exception {
        var exc: Exception = .{
            .tag_idx = tag_idx,
            .payload_len = @intCast(payload_in.len),
            .payload = undefined,
        };
        for (payload_in, 0..) |v, i| exc.payload[i] = v;
        return exc;
    }
};
