//! Per-Instance exception-handler table (ADR-0114 D3).
//!
//! Consumed at unwind time by `shared/unwind.zig`, which walks
//! the frame chain calling `lookup(pc,
//! throw_tag_idx)` at each frame's throw site. Built at JIT-emit
//! time by the per-arch `op_exception_handling.zig` (ADR-0114 D2)
//! as it encounters `try_table` bodies.
//!
//! Storage shape (per ADR-0114 D3): a sequence of `HandlerEntry`
//! records, each capturing one catch clause within a try_table
//! body. The table is consulted by the FP-walk unwinder using the
//! `(throw_pc, throw_tag_idx)` pair as the key; the first matching
//! entry (innermost-try_table-first by insertion order) wins.
//!
//! ADR-0114 D3 cites the eventual `*TagInstance` pointer-equality
//! key (D7), but the interp already keys on `tag_idx` (the
//! module's tag-section index) per `feature/exception_handling/
//! exception.zig` until cross-module tag identity lands. The
//! codegen-side table follows the interp's keying for now —
//! migrating both sides together when `*TagInstance` resolution
//! ships.
//!
//! For Wasm 3.0 this storage is per-Instance
//! and immutable after JIT compile (no run-time mutation); the
//! linear-scan lookup is acceptable until the per-function
//! sorted-by-PC binary-search optimisation lands at Phase 11+.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

/// Catch clause flavor — mirrors `ir/zir.zig::CatchKind` so the
/// per-arch emit path can copy through without re-encoding. The
/// `_ref` variants additionally push the caught `exnref` onto the
/// landing-pad's operand stack.
pub const CatchKind = enum(u8) {
    catch_ = 0,
    catch_ref = 1,
    catch_all = 2,
    catch_all_ref = 3,
};

/// One entry in the exception table: a single catch clause within
/// a try_table body. The PC range `[pc_start, pc_end)` matches
/// any throw site whose PC lies within it; this lets the FP-walk
/// unwinder identify the active try_table by PC alone.
///
/// `tag_idx == null` is required for `catch_all` / `catch_all_ref`
/// flavors and forbidden for the `catch_` / `catch_ref` flavors.
/// The constructor enforces the invariant.
pub const HandlerEntry = struct {
    pc_start: u32,
    pc_end: u32,
    tag_idx: ?u32,
    landing_pad_pc: u32,
    kind: CatchKind,
};

/// Result of a successful `lookup`: the landing-pad PC plus the
/// catch flavor (so the unwinder knows whether to push the
/// exnref).
pub const HandlerMatch = struct {
    landing_pad_pc: u32,
    kind: CatchKind,
};

/// Per-Instance exception table. Immutable after JIT emit.
pub const ExceptionTable = struct {
    entries: []const HandlerEntry,
    /// Per-instance tag-identity map, indexed by local tag index:
    /// `tag_ids[i]` is a globally-comparable identity id for tag `i`.
    /// The JIT analog of the interp's `*TagInstance` pointer key
    /// (`mvp.catchTagMatches`, ADR-0114 D7): two local indices (same
    /// instance OR across instances) that bind the same runtime tag
    /// carry the same id. Aliased imports collapse to one id (Cause
    /// A: `(import "test" "e0")` ×2 → idx 0,1 → equal id); a
    /// cross-module import inherits the SOURCE instance's id (Cause B
    /// / ADR-0134 D3), so a module-1 throw and a module-2 catch on the
    /// imported tag compare equal once the unwinder uses the catching
    /// frame's own table.
    ///
    /// Built at setup over the FULL tag index space (imported ++
    /// defined) whenever the module has ≥1 imported tag; `null` (the
    /// default) = defined-tags-only / synthetic → raw-index comparison
    /// (each defined tag is its own identity). When present it must
    /// cover every valid index; an out-of-range index widens to the
    /// raw index (defensive).
    tag_ids: ?[]const u64 = null,

    /// Resolve a local tag index to its globally-comparable identity.
    fn identity(self: ExceptionTable, idx: u32) u64 {
        const m = self.tag_ids orelse return idx;
        return if (idx < m.len) m[idx] else idx;
    }

    /// Lookup the handler for a `(throw_pc, throw_tag_idx)` pair.
    /// Returns the first matching entry per the
    /// innermost-try_table-first insertion order; null if no
    /// catch clause matches (= unwind continues to caller frame
    /// per ADR-0114 D5).
    ///
    /// Matching rule (ADR-0114 D3 + Wasm 3.0 §4.5.10 try_table):
    ///   - PC must lie in `[pc_start, pc_end)`.
    ///   - `catch_all` / `catch_all_ref`: matches any tag.
    ///   - `catch_` / `catch_ref`: matches iff the catch tag and the
    ///     thrown tag resolve to the same identity id (so aliased /
    ///     cross-module-imported indices match their source tag).
    pub fn lookup(self: ExceptionTable, pc: u32, throw_tag_idx: u32) ?HandlerMatch {
        return self.lookupByIdentity(pc, self.identity(throw_tag_idx));
    }

    /// Like `lookup`, but takes a PRE-RESOLVED throw identity id rather
    /// than a local tag index. Cross-instance unwinding (ADR-0134 D2)
    /// resolves the throw's identity ONCE via the THROWING instance's
    /// `tag_ids`, then matches it against each frame's OWN table (whose
    /// entries resolve via THAT instance's `tag_ids`) — the local
    /// `throw_tag_idx` is meaningless in a different instance's index
    /// space, but the resolved u64 identity is globally comparable.
    pub fn lookupByIdentity(self: ExceptionTable, pc: u32, throw_id: u64) ?HandlerMatch {
        // Entries are appended in try_table emit order, so an enclosing
        // try_table's clauses precede a nested one's. The innermost
        // try_table covering `pc` must win (= the smallest covering
        // range); within one try_table the first matching clause wins.
        var best: ?HandlerEntry = null;
        for (self.entries) |e| {
            if (pc < e.pc_start or pc >= e.pc_end) continue;
            const matches = switch (e.kind) {
                .catch_all, .catch_all_ref => true,
                .catch_, .catch_ref => e.tag_idx != null and self.identity(e.tag_idx.?) == throw_id,
            };
            if (!matches) continue;
            if (best == null or e.pc_end - e.pc_start < best.?.pc_end - best.?.pc_start) best = e;
        }
        const e = best orelse return null;
        return .{
            .landing_pad_pc = e.landing_pad_pc,
            .kind = e.kind,
        };
    }

    /// Public accessor for a local tag index's identity id (used by the
    /// unwinder to resolve the throw's identity from the throwing
    /// instance's table before walking).
    pub fn identityOf(self: ExceptionTable, idx: u32) u64 {
        return self.identity(idx);
    }
};

/// Forward fixup recording one catch's
/// landing-pad target. Written by `try_table.emit` once the inner
/// block's `ExceptionTable.Builder` row is appended, patched by
/// the matching catch-label's `end` op (which writes
/// `entries[entry_idx].landing_pad_pc = ctx.buf.items.len` post-end).
///
/// `target_labels_depth` is the value of `ctx.labels.items.len`
/// AT FIXUP CREATION (= try_table.emit time, AFTER the try_table's
/// own inner-block label is pushed). For catch `label_idx = K`, it
/// equals `ctx.labels.items.len - K`. When the matching `end`
/// fires it observes labels.items.len equal to this value; AFTER
/// the pop, the popped label was the target and the next emit byte
/// is the landing-pad PC.
pub const LandingPadFixup = struct {
    entry_idx: u32,
    target_labels_depth: u32,
};

/// Per-arch emit-time bookkeeping for an open `try_table` block.
/// One entry pushed at `try_table.emit`, popped + patched at the
/// matching `end` op (the `pc_end` placeholder originally written
/// by `try_table.emit` becomes the real post-inner-block PC).
///
/// `labels_depth` is the depth of the per-arch label stack at the
/// time this try_table pushed its inner-block label (= the index of
/// the pushed label, 1-indexed; equivalently `labels.items.len`
/// immediately after the push). The matching `end` identifies the
/// closing try_table by comparing the popped label's stack position
/// to this field.
pub const OpenTryTable = struct {
    labels_depth: u32,
    entry_start: u32,
    entry_count: u32,
};

/// Build-time accumulator for the exception table. The per-arch
/// `op_exception_handling.zig` instantiates one per function being
/// compiled, calls `add(...)` as it lowers each catch clause, and
/// calls `finalize()` to produce the per-Instance `ExceptionTable`.
pub const Builder = struct {
    entries: std.ArrayList(HandlerEntry),

    pub const empty: Builder = .{ .entries = .empty };

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Append a handler entry. Enforces the
    /// `kind ↔ tag_idx-presence` invariant (`catch_*` requires a
    /// `tag_idx`; `catch_all*` forbids one).
    pub fn add(
        self: *Builder,
        allocator: std.mem.Allocator,
        entry: HandlerEntry,
    ) !void {
        switch (entry.kind) {
            .catch_, .catch_ref => std.debug.assert(entry.tag_idx != null),
            .catch_all, .catch_all_ref => std.debug.assert(entry.tag_idx == null),
        }
        std.debug.assert(entry.pc_start < entry.pc_end);
        try self.entries.append(allocator, entry);
    }

    /// Freeze the builder into an `ExceptionTable`. The returned
    /// table aliases the builder's allocation; the caller owns
    /// the lifetime via `deinit`.
    pub fn finalize(self: *const Builder) ExceptionTable {
        return .{ .entries = self.entries.items };
    }
};

/// Collect per-function HandlerEntry slices into
/// a single per-Instance ExceptionTable.entries. pc_start / pc_end
/// are shifted by each function's byte offset within the JitBlock
/// (`func_offsets[num_imports + i]`), making them module-relative —
/// consistent with the FP-walk unwinder calling
/// `ExceptionTable.lookup(absolute_pc - block_addr, throw_tag_idx)`.
/// landing_pad_pc stays as written by the per-arch emit;
/// resolution to a module-relative JIT byte offset happens at the
/// dispatch boundary.
///
/// `per_func_handlers[i]` corresponds to the i-th DEFINED function
/// (wasm idx `num_imports + i`). Empty per-function slices are
/// skipped; the returned slice's length equals the sum of all
/// per-function lengths. Returns the empty static slice when total
/// is zero (no allocation; deinit-side `if (len > 0) free` works).
pub fn collectModuleTable(
    allocator: std.mem.Allocator,
    per_func_handlers: []const []const HandlerEntry,
    func_offsets: []const u32,
    num_imports: u32,
) std.mem.Allocator.Error![]HandlerEntry {
    var total: usize = 0;
    for (per_func_handlers) |h| total += h.len;
    if (total == 0) return &[_]HandlerEntry{};

    var entries = try allocator.alloc(HandlerEntry, total);
    errdefer allocator.free(entries);

    var write_idx: usize = 0;
    for (per_func_handlers, 0..) |handlers, i| {
        const base = func_offsets[num_imports + i];
        for (handlers) |h| {
            entries[write_idx] = .{
                .pc_start = h.pc_start + base,
                .pc_end = h.pc_end + base,
                .tag_idx = h.tag_idx,
                .landing_pad_pc = h.landing_pad_pc,
                .kind = h.kind,
            };
            write_idx += 1;
        }
    }
    return entries;
}

// ---------------------------------------------------------------------
// Unit tests — pure-data lookup; no per-arch dependency.
// ---------------------------------------------------------------------

const testing = std.testing;

test "exception_table: empty table — lookup always returns null" {
    const t: ExceptionTable = .{ .entries = &.{} };
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(0, 0));
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(100, 42));
}

test "exception_table: catch_ matches exact tag_idx, misses on mismatch" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 5,
        .landing_pad_pc = 200,
        .kind = .catch_,
    });
    const t = b.finalize();

    // Matching tag → hit.
    const hit = t.lookup(50, 5).?;
    try testing.expectEqual(@as(u32, 200), hit.landing_pad_pc);
    try testing.expectEqual(CatchKind.catch_, hit.kind);

    // Wrong tag → miss.
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(50, 6));
}

test "exception_table: tag_ids matches by identity — aliased + cross-module" {
    // tag_ids carries a globally-comparable identity per local index.
    // Aliased imports share an id (Cause A); a cross-module import
    // inherits the source id (Cause B) — both are the same comparison.
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 0,
        .landing_pad_pc = 200,
        .kind = .catch_,
    });
    // idx0 + idx1 alias the same source (id 0xAA); idx2 is a distinct
    // defined tag (id 0xBB). A cross-module source id (0xAA) need not
    // equal any raw index — that's the point of the u64 identity.
    const ids = [_]u64{ 0xAA, 0xAA, 0xBB };
    const t: ExceptionTable = .{ .entries = b.finalize().entries, .tag_ids = &ids };

    // Throw with the alias index 1 → id 0xAA == catch idx 0's id → hit.
    try testing.expectEqual(@as(u32, 200), t.lookup(50, 1).?.landing_pad_pc);
    // Throw the distinct tag idx 2 (id 0xBB) → miss.
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(50, 2));
    // Without a map: raw-index comparison → alias idx 1 misses catch 0.
    const t_raw: ExceptionTable = .{ .entries = b.finalize().entries };
    try testing.expectEqual(@as(?HandlerMatch, null), t_raw.lookup(50, 1));
}

test "exception_table: catch_all matches any tag in PC range" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 10,
        .pc_end = 50,
        .tag_idx = null,
        .landing_pad_pc = 300,
        .kind = .catch_all,
    });
    const t = b.finalize();

    // Any tag in range → hit.
    try testing.expectEqual(@as(u32, 300), t.lookup(20, 0).?.landing_pad_pc);
    try testing.expectEqual(@as(u32, 300), t.lookup(20, 999).?.landing_pad_pc);

    // Out of range → miss.
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(5, 0));
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(50, 0));
}

test "exception_table: catch_ref / catch_all_ref propagate through HandlerMatch.kind" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 7,
        .landing_pad_pc = 400,
        .kind = .catch_ref,
    });
    try b.add(testing.allocator, .{
        .pc_start = 100,
        .pc_end = 200,
        .tag_idx = null,
        .landing_pad_pc = 500,
        .kind = .catch_all_ref,
    });
    const t = b.finalize();

    try testing.expectEqual(CatchKind.catch_ref, t.lookup(50, 7).?.kind);
    try testing.expectEqual(CatchKind.catch_all_ref, t.lookup(150, 99).?.kind);
}

test "exception_table: insertion-order wins (innermost try_table first)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    // Outer try_table: PC range [0, 1000), catch_all → landing 999.
    // Inner try_table: PC range [100, 200), catch_ tag=3 → landing 150.
    // The INNER entry is added FIRST per the
    // innermost-try_table-first insertion discipline (the per-arch
    // emit walks try_table bodies depth-first).
    try b.add(testing.allocator, .{
        .pc_start = 100,
        .pc_end = 200,
        .tag_idx = 3,
        .landing_pad_pc = 150,
        .kind = .catch_,
    });
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 1000,
        .tag_idx = null,
        .landing_pad_pc = 999,
        .kind = .catch_all,
    });
    const t = b.finalize();

    // PC inside inner range + matching tag → inner wins.
    try testing.expectEqual(@as(u32, 150), t.lookup(150, 3).?.landing_pad_pc);

    // PC inside inner range + non-matching tag → falls through to outer catch_all.
    try testing.expectEqual(@as(u32, 999), t.lookup(150, 4).?.landing_pad_pc);

    // PC outside inner range → only outer can match.
    try testing.expectEqual(@as(u32, 999), t.lookup(50, 3).?.landing_pad_pc);
}

test "exception_table: PC at pc_end is exclusive (matches the contract)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 10,
        .pc_end = 20,
        .tag_idx = null,
        .landing_pad_pc = 100,
        .kind = .catch_all,
    });
    const t = b.finalize();

    try testing.expectEqual(@as(u32, 100), t.lookup(10, 0).?.landing_pad_pc);
    try testing.expectEqual(@as(u32, 100), t.lookup(19, 0).?.landing_pad_pc);
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(20, 0));
}

test "exception_table: Builder.finalize aliases the appended entries (no copy)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 1,
        .landing_pad_pc = 50,
        .kind = .catch_,
    });
    const t = b.finalize();
    try testing.expectEqual(@as(usize, 1), t.entries.len);
    try testing.expectEqual(@as(u32, 50), t.entries[0].landing_pad_pc);
}

test "collectModuleTable: per-function entries flatten with module-relative pc shift" {
    // Two defined funcs (wasm-idx 1 + 2) preceded
    // by one import (wasm-idx 0). fn1 has 1 catch at function-local
    // [0, 10); fn2 has 2 catches at function-local [0, 5) and
    // [5, 20). func_offsets places fn1 at byte 0, fn2 at byte 64.
    // After collection, fn2's pc ranges must be shifted by +64.
    const fn1_handlers = [_]HandlerEntry{
        .{ .pc_start = 0, .pc_end = 10, .tag_idx = 3, .landing_pad_pc = 8, .kind = .catch_ },
    };
    const fn2_handlers = [_]HandlerEntry{
        .{ .pc_start = 0, .pc_end = 5, .tag_idx = null, .landing_pad_pc = 4, .kind = .catch_all },
        .{ .pc_start = 5, .pc_end = 20, .tag_idx = 7, .landing_pad_pc = 18, .kind = .catch_ref },
    };
    const per_func: [2][]const HandlerEntry = .{ &fn1_handlers, &fn2_handlers };
    const func_offsets = [_]u32{ 0xFFFFFFFF, 0, 64 }; // import sentinel + fn1 + fn2

    const entries = try collectModuleTable(testing.allocator, &per_func, &func_offsets, 1);
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 3), entries.len);

    // fn1's catch — base 0, unchanged pcs.
    try testing.expectEqual(@as(u32, 0), entries[0].pc_start);
    try testing.expectEqual(@as(u32, 10), entries[0].pc_end);
    try testing.expectEqual(@as(?u32, 3), entries[0].tag_idx);
    try testing.expectEqual(CatchKind.catch_, entries[0].kind);

    // fn2's catches — base 64, pc ranges shift by +64.
    try testing.expectEqual(@as(u32, 64), entries[1].pc_start);
    try testing.expectEqual(@as(u32, 69), entries[1].pc_end);
    try testing.expectEqual(@as(?u32, null), entries[1].tag_idx);
    try testing.expectEqual(CatchKind.catch_all, entries[1].kind);

    try testing.expectEqual(@as(u32, 69), entries[2].pc_start);
    try testing.expectEqual(@as(u32, 84), entries[2].pc_end);
    try testing.expectEqual(@as(?u32, 7), entries[2].tag_idx);
    try testing.expectEqual(CatchKind.catch_ref, entries[2].kind);
}

test "collectModuleTable: all per-func slices empty → returns static empty slice" {
    const per_func: [2][]const HandlerEntry = .{ &.{}, &.{} };
    const func_offsets = [_]u32{ 0, 100 };
    const entries = try collectModuleTable(testing.allocator, &per_func, &func_offsets, 0);
    // No allocation when total is zero; caller can pass the slice
    // through `if (len > 0) free` without UB.
    try testing.expectEqual(@as(usize, 0), entries.len);
}
