//! WASM Spec §4.2.7 "Table Instance" — table reference cells.
//!
//! Per ADR-0023 §3 reference table + §7 item 6: extracted from
//! the previous monolithic `runtime/runtime.zig`. The runner /
//! instantiator allocates `refs` and threads the table via
//! `Runtime.tables`. `table.copy / .init / .fill / .grow` helper
//! impls land alongside Wasm 2.0 bulk-memory work; this file
//! currently owns only the data shape.
//!
//! Zone 1 (`src/runtime/`).

const value_mod = @import("../value.zig");
const zir = @import("../../ir/zir.zig");

const Value = value_mod.Value;

/// Runtime counterpart of `zir.TableEntry` — actually holds the
/// reference cells. The runner allocates `refs` and threads the
/// instance via `Runtime.tables`.
pub const TableInstance = struct {
    refs: []Value,
    elem_type: zir.ValType,
    max: ?u64 = null,
    /// table64 (memory64 proposal's table extension): `.i64` for an
    /// i64-indexed table — the table-op handlers pop the index/n at this
    /// width and table.size/grow push their result at this width.
    idx_type: zir.IdxType = .i32,
    /// #449 — set once a `wasm_table_new` table has been imported. The binder
    /// hands the importer a VALUE copy whose `refs` header aliases the same
    /// backing, so a grow on either side strands the other on the freed
    /// buffer; both decline until they share one `*TableInstance`
    /// (`linker.zig`'s D-201b note has the follow-up). Never cleared:
    /// clearing it wrongly costs the use-after-free back.
    host_imported: bool = false,
};
