// FILE-SIZE-EXEMPT: single compose+patch link pass over EmitOutputs; 41% in-file tests P4-alone (investigated 2026-08-12, per ADR-0099)
//! JIT module linker (sub-7.4b).
//!
//! Composes per-function `EmitOutput`s into a single contiguous
//! `JitBlock`, then patches every `BL` placeholder via the
//! `call_fixups` list using each callee's now-known body offset.
//!
//! The linker takes immutable per-function bytes (the emit pass's
//! product) + their call_fixup tables and produces a runnable
//! `JitModule`. Memory layout: function bodies are concatenated
//! at 4-byte boundaries (their natural ARM64 instruction
//! alignment) starting at the JitBlock origin; offsets recorded
//! per-function in `func_offsets`.
//!
//! Zone 2 (`src/engine/codegen/shared/`) — shared across per-arch backends because
//! the BL displacement encoding (imm26 word offset) is uniform on
//! ARM64 and the linker is arch-neutral except for the
//! placeholder-patching step (which currently assumes ARM64 BL;
//! Phase 8 / x86_64 emit will introduce arch dispatch).

const std = @import("std");
const builtin_arch = @import("builtin");
const Allocator = std.mem.Allocator;

const jit_mem = @import("../../../platform/jit_mem.zig");
const trap_registry = @import("../../../platform/trap_registry.zig"); // ADR-0202 D3
const code_map = @import("code_map.zig");
/// Comptime arch dispatch
/// matching `compile.zig` (commit `0925134`). Both backends
/// expose `CallFixup` with the same
/// `{byte_offset: u32, target_func_idx: u32}` shape.
const emit = switch (builtin_arch.target.cpu.arch) {
    .aarch64 => @import("../arm64/emit.zig"),
    .x86_64 => @import("../x86_64/emit.zig"),
    else => @compileError("unsupported host arch for linker"),
};
const inst = switch (builtin_arch.target.cpu.arch) {
    .aarch64 => @import("../arm64/inst.zig"),
    .x86_64 => @import("../x86_64/inst.zig"),
    else => @compileError("unsupported host arch for linker"),
};

pub const Error = error{
    /// A call_fixup names a target_func_idx outside `func_bodies`.
    UnknownCallTarget,
    /// BL displacement out of imm26 range (±128 MiB). Trips when
    /// the linked module is enormous; not expected in any
    /// realistic Wasm corpus.
    DisplacementOverflow,
} || jit_mem.Error || Allocator.Error;

/// Per-function input to the linker. `bytes` and `call_fixups`
/// come straight out of `emit.compile`; the linker takes
/// references (does not own).
pub const FuncBody = struct {
    bytes: []const u8,
    call_fixups: []const emit.CallFixup,
    /// Per-function aligned frame size in
    /// bytes (from `EmitOutput.frame_bytes`). Propagates to
    /// `CodeMap.Entry.frame_bytes`; the EH SP-restore path
    /// consumes it. Defaults to 0 for callers that don't set it
    /// (legacy test fixtures + non-EH paths).
    frame_bytes: u32 = 0,
    /// ADR-0202 D3 — byte offset (from body start) of this function's
    /// kind=6 oob trap stub (from `EmitOutput.oob_stub_off`). The
    /// linker adds the function's absolute base to build the trap
    /// registry's PC-redirect table. `FuncEntry.no_stub` = no
    /// bounds-checked access (default for legacy/test callers).
    oob_stub_off: u32 = trap_registry.FuncEntry.no_stub,
};

/// Per-function buffer-write wrapper thunk specification
/// (ADR-0106). Lists which `func_idx` in
/// `func_bodies` needs a wrapper emitted alongside its body.
/// The wrapper's Zig-side signature is `fn(rt, results, args)
/// callconv(.c) ErrCode` per `entry_buffer_write.BufferWriteFn`.
pub const WrapperSpec = struct {
    /// Function index in the wasm-space (= same indexing as
    /// `func_bodies`, offset by `num_imports`).
    func_idx: u32,
    /// Function signature; used by `wrapper_thunk.emit` to pick
    /// the per-shape wrapper byte sequence.
    sig: @import("../../../ir/zir.zig").FuncType,
};

pub const JitModule = struct {
    block: jit_mem.JitBlock,
    /// `func_offsets[i]` = byte offset of function `i`'s entry
    /// within `block.bytes`. Allocator-owned.
    func_offsets: []const u32,
    /// Per-function wrapper thunk offset (ADR-0106).
    /// `thunk_offsets[i]` = byte offset of function `i`'s
    /// **buffer-write wrapper thunk** entry within `block.bytes`,
    /// or `NO_THUNK` (= sentinel `0xFFFFFFFF`) when no thunk was
    /// emitted (e.g. function has no multi-result signature, or
    /// arch / shape isn't supported yet).
    ///
    /// Set to an allocator-owned `[]const u32` only when at least
    /// one function in the module has a wrapper thunk. Otherwise
    /// `null` — `entry_buf` panics in that case. The dual storage
    /// (body_offset + thunk_offset) lets the entry helper
    /// (`callI32i32i32NoArgs` etc.) read the thunk address while
    /// intra-module Wasm `call` dispatch still routes to the body
    /// address via `func_offsets[i]` per ADR-0017 / ADR-0066.
    thunk_offsets: ?[]const u32 = null,

    /// Per-Instance JIT code map (ADR-0114 D5) —
    /// entries sorted by `start_addr`. Built at link time from
    /// `func_offsets`; consumed by the FP-walk unwinder via
    /// `codeMap().lookup(ret_addr)` to translate a saved LR / RIP
    /// into a `(func_idx, relative_pc)` pair. Empty for modules
    /// with zero defined functions (import-only). Owned slice.
    code_map_entries: []const code_map.Entry = &.{},

    /// ADR-0202 D3 — per-function `{code_off, oob_stub_off}` (offsets
    /// relative to `block.bytes.ptr`), sorted ascending by `code_off`.
    /// The production fault handler binary-searches this via the trap
    /// registry to redirect a guard fault to the containing function's
    /// oob stub. Registered (`registerCodeRegion`) at link time when
    /// the block is executable + its base known; unregistered in
    /// `deinit`. Owned slice; empty for import-only modules.
    trap_func_entries: []const trap_registry.FuncEntry = &.{},
    /// Absolute base the trap entries were registered under (=
    /// `block.bytes.ptr`); the unregister key. 0 = not registered.
    trap_region_start: usize = 0,

    /// Sentinel for `thunk_offsets[i]` when function `i` has no
    /// emitted wrapper thunk (single-result, unsupported shape, or
    /// non-target arch).
    pub const NO_THUNK: u32 = 0xFFFFFFFF;

    pub fn deinit(self: *JitModule, allocator: Allocator) void {
        // ADR-0202 D3 — unregister BEFORE freeing the block so no
        // fault can classify against a freed (possibly reused) code
        // range. Keyed by the registered base (0 = never registered).
        if (self.trap_region_start != 0) {
            trap_registry.unregisterCodeRegion(self.trap_region_start);
            self.trap_region_start = 0;
        }
        if (self.trap_func_entries.len > 0) allocator.free(self.trap_func_entries);
        allocator.free(self.func_offsets);
        if (self.thunk_offsets) |to| allocator.free(to);
        if (self.code_map_entries.len > 0) allocator.free(self.code_map_entries);
        jit_mem.free(self.block);
    }

    /// View the per-module code map. The returned `CodeMap` aliases
    /// `code_map_entries`; valid for the JitModule's lifetime.
    pub fn codeMap(self: JitModule) code_map.CodeMap {
        return .{ .entries = self.code_map_entries };
    }

    /// Cast function `idx`'s entry to a function pointer of the
    /// given signature. Caller is responsible for matching the
    /// emitted body's signature.
    ///
    /// Defensive guard: the realworld_run_jit run-
    /// stage SEGV investigation surfaced this site as a possible
    /// out-of-bounds read path (idx ≥ func_offsets.len would walk
    /// into garbage and produce a wildly invalid function pointer,
    /// then the JIT prologue's first LDR would deref NULL and
    /// trigger a recursive panic in the unwinder). Surface the
    /// out-of-range case explicitly via @panic so future SEGVs
    /// land with a useful message instead of silent NULL deref.
    /// Also reject the IMPORT_SENTINEL_OFFSET path — the run-stage
    /// caller MUST resolve imports through the host_dispatch_base
    /// table, never through entry().
    pub fn entry(self: JitModule, idx: u32, comptime Fn: type) Fn {
        if (idx >= self.func_offsets.len) {
            std.debug.panic(
                "JitModule.entry: idx {d} >= func_offsets.len {d}",
                .{ idx, self.func_offsets.len },
            );
        }
        const off = self.func_offsets[idx];
        if (off == IMPORT_SENTINEL_OFFSET) {
            std.debug.panic(
                "JitModule.entry: idx {d} resolves to IMPORT_SENTINEL_OFFSET — caller routed an import through entry() instead of host_dispatch_base",
                .{idx},
            );
        }
        return @ptrCast(@alignCast(self.block.bytes.ptr + off));
    }

    /// Return the raw byte address of function `idx`'s entry —
    /// equivalent to `@intFromPtr(entry(idx, fn() callconv(.c) void))`
    /// but without forcing a concrete signature. Used by ADR-0066
    /// cross-module bridge thunks: the thunk's literal pool
    /// embeds the callee's entry address verbatim, and the per-
    /// import slot in `host_dispatch_base` then points at the
    /// thunk (which tail-jumps to this address).
    ///
    /// Same `IMPORT_SENTINEL_OFFSET` guard as `entry` — calling
    /// `entryAddr` for an unresolved import slot is a structural
    /// bug; the resolver must populate `host_dispatch_base[i]`
    /// without ever reaching for the importer's own JIT module's
    /// entry().
    /// Fetch the buffer-write wrapper thunk (ADR-0106)
    /// for function `idx` as a typed function pointer. The
    /// thunk's Zig-side signature is `fn(rt, results, args)
    /// callconv(.c) ErrCode` per `entry_buffer_write.BufferWriteFn`.
    ///
    /// Panics when:
    /// - The module has no `thunk_offsets` array (no wrapper thunks
    ///   were emitted; caller should use `entry()` instead).
    /// - `idx` is out of range.
    /// - `thunk_offsets[idx] == NO_THUNK` (function `idx` has no
    ///   wrapper — sig is single-result OR unsupported shape).
    /// Whether function `idx` has a buffer-write wrapper thunk usable via
    /// `entry_buf`. Multi-value invoke callers must gate on this: not every
    /// shape gets a thunk (single-result or a shape `wrapper_thunk.emit`
    /// rejects → NO_THUNK, or the whole module emitted none → null offsets).
    pub fn hasThunk(self: JitModule, idx: u32) bool {
        const offsets = self.thunk_offsets orelse return false;
        if (idx >= offsets.len) return false;
        return offsets[idx] != NO_THUNK;
    }

    pub fn entry_buf(self: JitModule, idx: u32, comptime Fn: type) Fn {
        const offsets = self.thunk_offsets orelse std.debug.panic(
            "JitModule.entry_buf: idx {d} — module has no thunk_offsets",
            .{idx},
        );
        if (idx >= offsets.len) {
            std.debug.panic(
                "JitModule.entry_buf: idx {d} >= thunk_offsets.len {d}",
                .{ idx, offsets.len },
            );
        }
        const off = offsets[idx];
        if (off == NO_THUNK) {
            std.debug.panic(
                "JitModule.entry_buf: idx {d} has no wrapper thunk (NO_THUNK sentinel)",
                .{idx},
            );
        }
        return @ptrCast(@alignCast(self.block.bytes.ptr + off));
    }

    pub fn entryAddr(self: JitModule, idx: u32) usize {
        if (idx >= self.func_offsets.len) {
            std.debug.panic(
                "JitModule.entryAddr: idx {d} >= func_offsets.len {d}",
                .{ idx, self.func_offsets.len },
            );
        }
        const off = self.func_offsets[idx];
        if (off == IMPORT_SENTINEL_OFFSET) {
            std.debug.panic(
                "JitModule.entryAddr: idx {d} resolves to IMPORT_SENTINEL_OFFSET — caller asked for an unresolved import's entry address",
                .{idx},
            );
        }
        return @intFromPtr(self.block.bytes.ptr) + off;
    }
};

/// Sentinel value stored in `func_offsets` for import slots. The
/// JIT-emit pass routes import calls to the function-local trap
/// stub directly (not through the linker's call_fixups), so this
/// value is never read by any executable path. A reader that
/// observes it (e.g. external tooling that unpacks JitModule)
/// should treat it as "no body — call would trap".
pub const IMPORT_SENTINEL_OFFSET: u32 = 0xFFFF_FFFF;

/// Lay out and link `func_bodies` into a freshly-allocated
/// `JitBlock`. The block returns in the executable state (caller
/// can immediately invoke entry pointers).
///
/// `num_imports` shifts the wasm-space function-index origin:
/// `func_offsets` is sized `num_imports + func_bodies.len` and
/// the first `num_imports` entries hold `IMPORT_SENTINEL_OFFSET`.
/// Defined-function K is laid out at byte offset
/// `func_offsets[num_imports + K]`. CallFixup `target_func_idx`
/// values are wasm-space indices; the linker patches them by
/// looking up `func_offsets[target_func_idx]` (which must NOT be
/// the sentinel — emit-pass invariant: import calls never produce
/// a CallFixup; import-as-trap branches go through the per-
/// function bounds_fixups / unreach_fixups list).
pub fn link(allocator: Allocator, func_bodies: []const FuncBody, num_imports: u32) Error!JitModule {
    const total_funcs: usize = @as(usize, num_imports) + func_bodies.len;
    // Empty module (Wasm spec allows zero defined functions):
    // skip the jit_mem allocation entirely — there is no
    // executable code to publish. Caller still receives a
    // structurally valid JitModule whose bytes slice is empty
    // and whose entry() must not be invoked. Import-only modules
    // (defined_count == 0, num_imports > 0) hit the same path:
    // every wasm-idx-based entry() lookup hits a sentinel.
    if (func_bodies.len == 0) {
        const offsets = try allocator.alloc(u32, total_funcs);
        @memset(offsets, IMPORT_SENTINEL_OFFSET);
        return .{
            .block = .{ .bytes = &[_:0]u8{} },
            .func_offsets = offsets,
        };
    }

    var total_size: usize = 0;
    var offsets = try allocator.alloc(u32, total_funcs);
    errdefer allocator.free(offsets);
    // Imports occupy slots [0..num_imports); fill with sentinel.
    @memset(offsets[0..num_imports], IMPORT_SENTINEL_OFFSET);
    for (func_bodies, 0..) |body, i| {
        offsets[num_imports + i] = @intCast(total_size);
        total_size += body.bytes.len;
        // Bodies emit only word-aligned content; no padding needed.
    }
    if (total_size == 0) return Error.AllocationFailed;

    var block = try jit_mem.alloc(total_size);
    errdefer jit_mem.free(block);

    try jit_mem.setWritable(block);
    for (func_bodies, 0..) |body, i| {
        const off = offsets[num_imports + i];
        @memcpy(block.bytes[off..][0..body.bytes.len], body.bytes);
    }

    // Patch every CALL/BL placeholder. Each fixup's byte_offset
    // is function-local; add the function's own base offset to
    // get its absolute byte position. The encoding differs per
    // arch (BL imm26 on ARM64; CALL rel32 on x86_64) — comptime
    // switch picks the right path with no runtime cost.
    for (func_bodies, 0..) |body, i| {
        const base = offsets[num_imports + i];
        for (body.call_fixups) |fx| {
            // CallFixups carry wasm-space indices. Imports are
            // routed via the trap stub by the emit pass — they
            // must never appear here. A sentinel target is a
            // structural emit-pass bug (post-chunk-b invariant).
            if (fx.target_func_idx >= total_funcs) return Error.UnknownCallTarget;
            if (fx.target_func_idx < num_imports) return Error.UnknownCallTarget;
            const fixup_abs: i64 = @as(i64, base) + @as(i64, fx.byte_offset);
            const target_abs: i64 = offsets[fx.target_func_idx];
            switch (builtin_arch.target.cpu.arch) {
                .aarch64 => {
                    const disp_bytes = target_abs - fixup_abs;
                    if (@rem(disp_bytes, 4) != 0) return Error.DisplacementOverflow;
                    const disp_words = @divExact(disp_bytes, 4);
                    // imm26 signed range: ±2^25 words = ±128 MiB.
                    if (disp_words < -(1 << 25) or disp_words >= (1 << 25)) {
                        return Error.DisplacementOverflow;
                    }
                    // ADR-0112 D4: `is_tail = true` → B (0x14...);
                    // otherwise BL (0x94...). Same imm26 layout.
                    const new_word = if (fx.is_tail)
                        inst.encB(@intCast(disp_words))
                    else
                        inst.encBL(@intCast(disp_words));
                    std.mem.writeInt(u32, block.bytes[@intCast(fixup_abs)..][0..4], new_word, .little);
                },
                .x86_64 => {
                    // CALL rel32: 5-byte instruction (0xE8 +
                    // disp32). disp = target - (at + 5). i32
                    // signed range = ±2 GiB; flag overflow.
                    const disp_bytes = target_abs - fixup_abs - 5;
                    if (disp_bytes < std.math.minInt(i32) or disp_bytes > std.math.maxInt(i32)) {
                        return Error.DisplacementOverflow;
                    }
                    inst.patchRel32(block.bytes, @intCast(fixup_abs), 5, @intCast(disp_bytes));
                },
                else => @compileError("unsupported host arch for linker patch loop"),
            }
        }
    }

    try jit_mem.setExecutable(block);

    // Build per-Instance code map entries. Each defined
    // function gets one Entry with absolute start_addr + len +
    // wasm-space func_idx. Sorted by start_addr by construction
    // (func_offsets is monotonically increasing). frame_bytes is
    // a placeholder (0) until the SP-restore path consumes it
    // for handler dispatch. `total_size` (the sum of body lengths,
    // pre-page-alignment) is the upper bound for the last
    // function — `block.bytes.len` is page-aligned and would
    // overshoot.
    const code_map_entries = try buildCodeMapEntries(
        allocator,
        block,
        offsets,
        num_imports,
        @intCast(total_size),
        func_bodies,
    );

    // ADR-0202 D3 — build + register the guard-fault PC-redirect table.
    const trap = try buildAndRegisterTrapEntries(allocator, block, offsets, num_imports, total_size, func_bodies);
    errdefer trap.unregisterAndFree(allocator);

    return .{
        .block = block,
        .func_offsets = offsets,
        .code_map_entries = code_map_entries,
        .trap_func_entries = trap.entries,
        .trap_region_start = trap.region_start,
    };
}

/// ADR-0202 D3 — build the per-function `{code_off, oob_stub_off}`
/// table (absolute-base-relative stub offsets) for `block` and
/// register it in the trap registry. `region_size` bounds the code
/// range (the body region only — wrapper thunks past it are non-Wasm
/// and excluded, mirroring `buildCodeMapEntries`). Import-only modules
/// register nothing. Caller stores the result on the JitModule and
/// pairs it with the `deinit` unregister.
const TrapEntries = struct {
    entries: []const trap_registry.FuncEntry = &.{},
    region_start: usize = 0,

    fn unregisterAndFree(self: TrapEntries, allocator: Allocator) void {
        if (self.region_start != 0) trap_registry.unregisterCodeRegion(self.region_start);
        if (self.entries.len > 0) allocator.free(self.entries);
    }
};

fn buildAndRegisterTrapEntries(
    allocator: Allocator,
    block: jit_mem.JitBlock,
    offsets: []const u32,
    num_imports: u32,
    region_size: usize,
    func_bodies: []const FuncBody,
) Error!TrapEntries {
    const defined_count = offsets.len - num_imports;
    if (defined_count == 0) return .{};
    const base = @intFromPtr(block.bytes.ptr);
    const entries = try allocator.alloc(trap_registry.FuncEntry, defined_count);
    errdefer allocator.free(entries);
    for (0..defined_count) |i| {
        const code_off = offsets[num_imports + i];
        const stub = func_bodies[i].oob_stub_off;
        entries[i] = .{
            .code_off = code_off,
            .oob_stub_off = if (stub == trap_registry.FuncEntry.no_stub)
                trap_registry.FuncEntry.no_stub
            else
                code_off + stub, // region-relative (region start = base)
        };
    }
    // offsets is monotonically increasing → already sorted by code_off.
    // A full registry (1024 live modules) surfaces as OutOfMemory.
    trap_registry.registerCodeRegion(base, base + region_size, entries) catch |e| switch (e) {
        error.RegistryFull => return Error.OutOfMemory,
    };
    return .{ .entries = entries, .region_start = base };
}

/// Derives `CodeMap.Entry`s from a linked JitBlock's
/// `func_offsets`. Caller owns the returned slice. `code_total` is
/// the sum of body lengths (= one-past-end offset of the last
/// defined function); `block.bytes.len` is page-aligned by
/// `jit_mem.alloc` and overshoots the actual function range.
/// `func_bodies` carries the per-function `frame_bytes`.
fn buildCodeMapEntries(
    allocator: Allocator,
    block: jit_mem.JitBlock,
    offsets: []const u32,
    num_imports: u32,
    code_total: u32,
    func_bodies: []const FuncBody,
) Allocator.Error![]code_map.Entry {
    const defined_count = offsets.len - num_imports;
    if (defined_count == 0) return &[_]code_map.Entry{};
    std.debug.assert(func_bodies.len == defined_count);

    var entries = try allocator.alloc(code_map.Entry, defined_count);
    errdefer allocator.free(entries);

    const block_addr = @intFromPtr(block.bytes.ptr);

    for (0..defined_count) |i| {
        const wasm_idx: u32 = @intCast(num_imports + i);
        const off = offsets[wasm_idx];
        const next_off: u32 = if (i + 1 < defined_count)
            offsets[num_imports + i + 1]
        else
            code_total;
        entries[i] = .{
            .start_addr = block_addr + off,
            .len = next_off - off,
            .func_idx = wasm_idx,
            .frame_bytes = func_bodies[i].frame_bytes,
        };
    }
    return entries;
}

/// Link + emit per-function wrapper thunks alongside the
/// bodies (ADR-0106).
///
/// Composes existing `link()` with a wrapper
/// emit pass: bodies first (at offset 0..body_size), wrappers
/// appended after (at offset body_size..total_size).
/// `thunk_offsets[func_idx]` records the wrapper's offset, or
/// `NO_THUNK` (0xFFFFFFFF) when no wrapper was emitted.
///
/// When `wrapper_specs.len == 0`, behaves identically to
/// `link()` and returns `thunk_offsets = null`.
/// When ALL specs return `UnsupportedOp` from `wrapper_thunk.
/// emit` (e.g. arch not implemented, shape unsupported), also
/// returns `thunk_offsets = null` — the body link still
/// succeeds.
///
/// Implementation: two-pass. Pass 1 calls `link()` to compute
/// body offsets + a body-only JitBlock. Pass 2 computes
/// wrapper bytes via `wrapper_thunk.emit`, allocates a NEW
/// JitBlock of total size, copies bodies + wrappers,
/// populates `thunk_offsets`. The pass-1 block is freed.
pub fn linkWithThunks(
    allocator: Allocator,
    func_bodies: []const FuncBody,
    num_imports: u32,
    wrapper_specs: []const WrapperSpec,
) Error!JitModule {
    if (wrapper_specs.len == 0) {
        return link(allocator, func_bodies, num_imports);
    }

    var body_module = try link(allocator, func_bodies, num_imports);
    errdefer body_module.deinit(allocator);

    const total_funcs = body_module.func_offsets.len;
    const body_size = body_module.block.bytes.len;

    var wrapper_bytes_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (wrapper_bytes_list.items) |b| allocator.free(b);
        wrapper_bytes_list.deinit(allocator);
    }

    var thunk_offsets = try allocator.alloc(u32, total_funcs);
    errdefer allocator.free(thunk_offsets);
    @memset(thunk_offsets, JitModule.NO_THUNK);

    const wrapper_thunk = @import("wrapper_thunk.zig");
    var wrapper_total: usize = 0;
    for (wrapper_specs) |spec| {
        if (spec.func_idx >= total_funcs) return Error.UnknownCallTarget;
        const body_offset = body_module.func_offsets[spec.func_idx];
        if (body_offset == IMPORT_SENTINEL_OFFSET) return Error.UnknownCallTarget;
        const thunk_offset_usize = body_size + wrapper_total;
        const wrapper_out = wrapper_thunk.emit(allocator, .{
            .sig = spec.sig,
            .body_offset = body_offset,
            .thunk_offset = @intCast(thunk_offset_usize),
        }) catch |err| switch (err) {
            error.UnsupportedOp => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        try wrapper_bytes_list.append(allocator, wrapper_out.bytes);
        thunk_offsets[spec.func_idx] = @intCast(thunk_offset_usize);
        wrapper_total += wrapper_out.bytes.len;
    }

    if (wrapper_total == 0) {
        allocator.free(thunk_offsets);
        return body_module;
    }

    const total_size = body_size + wrapper_total;
    var block = try jit_mem.alloc(total_size);
    errdefer jit_mem.free(block);
    try jit_mem.setWritable(block);
    @memcpy(block.bytes[0..body_size], body_module.block.bytes);
    var off: usize = body_size;
    for (wrapper_bytes_list.items) |w| {
        @memcpy(block.bytes[off..][0..w.len], w);
        off += w.len;
    }
    try jit_mem.setExecutable(block);

    const offsets_copy = try allocator.dupe(u32, body_module.func_offsets);
    errdefer allocator.free(offsets_copy);
    body_module.deinit(allocator);

    // Rebuild code_map_entries against the new block. The
    // body_module's entries point at the freed block; rebuilding
    // here ensures the returned JitModule's entries match the
    // wrapper-extended block addresses. The body offsets stay
    // identical (wrappers append past the body region) so func_idx
    // → offset mapping is unchanged; only start_addr shifts to the
    // new block.bytes.ptr. `body_size` bounds the body region (the
    // wrapper region is non-Wasm and intentionally excluded from
    // the unwinder's per-function lookup).
    const code_map_entries = try buildCodeMapEntries(
        allocator,
        block,
        offsets_copy,
        num_imports,
        @intCast(body_size),
        func_bodies,
    );
    errdefer allocator.free(code_map_entries);

    // ADR-0202 D3 — `body_module.deinit` above unregistered the (now-freed)
    // body block; the combined block must be registered afresh, or a guard
    // fault in a wrapper-thunk module (the dominant path — any exported
    // ≥1-param / ≥2-result function) would go unclassified. Region bounded
    // by `body_size` (wrapper thunks past it are non-Wasm, like the code map).
    const trap = try buildAndRegisterTrapEntries(allocator, block, offsets_copy, num_imports, body_size, func_bodies);
    errdefer trap.unregisterAndFree(allocator);

    return .{
        .block = block,
        .func_offsets = offsets_copy,
        .thunk_offsets = thunk_offsets,
        .code_map_entries = code_map_entries,
        .trap_func_entries = trap.entries,
        .trap_region_start = trap.region_start,
    };
}

// ============================================================
// Tests
// ============================================================

const builtin = @import("builtin");
const testing = std.testing;
const skip = @import("../../../test_support/skip.zig");
const zir = @import("../../../ir/zir.zig");
const jit_abi = @import("jit_abi.zig");
const entry_mod = @import("entry.zig"); // D-311: callEntrySafe for test entry calls
const ZirFunc = zir.ZirFunc;
const regalloc = @import("regalloc.zig");

test "link: 2-function module — fn0 calls fn1, returns 7" {
    // D-193 triage: ungated. emit.compile (linker.zig:30 comptime arch
    // switch) + module.entry (callconv .c) are portable; mac-arm64 +
    // linux-x86_64 both execute. Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const sigs = [_]zir.FuncType{
        .{ .params = &.{}, .results = &.{.i32} }, // fn0
        .{ .params = &.{}, .results = &.{.i32} }, // fn1
    };

    // fn0: () → i32  { call 1 ; end }
    var fn0 = ZirFunc.init(0, sigs[0], &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .call, .payload = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn0_slots = [_]u16{0};
    const fn0_alloc: regalloc.Allocation = .{ .slots = &fn0_slots, .n_slots = 1 };

    // fn1: () → i32  { i32.const 7 ; end }
    var fn1 = ZirFunc.init(1, sigs[1], &.{});
    defer fn1.deinit(testing.allocator);
    try fn1.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn1.instrs.append(testing.allocator, .{ .op = .end });
    fn1.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn1_slots = [_]u16{0};
    const fn1_alloc: regalloc.Allocation = .{ .slots = &fn1_slots, .n_slots = 1 };

    const out0 = try emit.compile(testing.allocator, &fn0, fn0_alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);
    const out1 = try emit.compile(testing.allocator, &fn1, fn1_alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out1);

    const bodies = [_]FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
        .{ .bytes = out1.bytes, .call_fixups = out1.call_fixups },
    };
    var module = try link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    // ADR-0034 sentinel store mandates a valid
    // JitRuntime ptr in X0 (was tolerable garbage pre-sentinel
    // because the existing prologue LDRs read but never wrote
    // through X0; the new STR W17, [X19, #flag_off] requires
    // a real backing store).
    var memory: [0]u8 = .{};
    var rt: jit_abi.JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const Fn = *const fn (rt: *jit_abi.JitRuntime) callconv(.c) u32;
    const f = module.entry(0, Fn);
    // D-311: route through the cohort-clobber trampoline (NOT a raw `f(&rt)`).
    try testing.expectEqual(@as(u32, 7), try entry_mod.callEntrySafe(&rt, u32, f, .{}));
    try testing.expect(rt.jit_executed_flag != 0);

    // ADR-0066 (c)-2.3 enabling: `entryAddr` returns the raw byte
    // address of function `idx`'s entry. Cross-module bridge thunks
    // embed this verbatim in their literal pool (the thunk's
    // tail-jump target). Verify parity with `entry()` cast to
    // `usize`: both must point at the same first instruction.
    try testing.expectEqual(@intFromPtr(f), module.entryAddr(0));
    const f1 = module.entry(1, Fn);
    try testing.expectEqual(@intFromPtr(f1), module.entryAddr(1));
    // Distinct functions live at distinct offsets.
    try testing.expect(module.entryAddr(0) != module.entryAddr(1));
}

// ADR-0112 D4: tail-call
// CallFixup with `is_tail = true` MUST patch to B (0x14...),
// NOT BL (0x94...), so the caller's frame is not preserved by
// LR-save and the callee RETs to the caller's caller. Same
// imm26 layout — only bit 31 differs. Synthetic test exercises
// the patch dispatch without going through emit.compile (which
// doesn't yet construct is_tail CallFixups; that lands in the
// follow-on cycle wiring return_call.emit).
test "link: is_tail=true fixup -> tail transfer (arm64 B / x86_64 JMP)" {
    // D-193 / ADR-0122 D3: portable via comptime per-arch byte shape.
    // is_tail=true => a transfer that does NOT preserve a return frame.
    // arm64: link() rewrites the word to B (0x14...) selected from
    // is_tail (vs BL 0x94...). x86_64: the opcode (JMP 0xE9) is chosen
    // by the emit pass; link() patches only the rel32 disp and
    // preserves the opcode byte (patchRel32; see linker.zig x86_64
    // branch). Synthetic test exercises the patch dispatch directly.
    // Win deferred per ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    switch (builtin.cpu.arch) {
        .aarch64 => {
            const a64 = @import("../arm64/inst.zig");
            const ret_word: u32 = 0xD65F03C0; // RET (X30)
            var fn0_bytes: [8]u8 = undefined;
            std.mem.writeInt(u32, fn0_bytes[0..4], 0x14000000, .little); // B 0 placeholder
            std.mem.writeInt(u32, fn0_bytes[4..8], ret_word, .little);
            var fn1_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, fn1_bytes[0..4], ret_word, .little);
            const fn0_fixups = [_]emit.CallFixup{.{ .byte_offset = 0, .target_func_idx = 1, .is_tail = true }};
            const bodies = [_]FuncBody{
                .{ .bytes = fn0_bytes[0..], .call_fixups = fn0_fixups[0..] },
                .{ .bytes = fn1_bytes[0..], .call_fixups = &.{} },
            };
            var module = try link(testing.allocator, &bodies, 0);
            defer module.deinit(testing.allocator);
            const fn0_off = module.func_offsets[0];
            const fn1_off = module.func_offsets[1];
            const disp_words: i32 = @intCast(@divExact(@as(i64, fn1_off) - @as(i64, fn0_off), 4));
            const patched = std.mem.readInt(u32, module.block.bytes[fn0_off..][0..4], .little);
            try testing.expectEqual(a64.encB(disp_words), patched);
            // B prefix (0x14...), not BL (0x94...).
            try testing.expectEqual(@as(u32, 0x14000000), patched & 0xFC000000);
        },
        .x86_64 => {
            // JMP rel32 placeholder (0xE9 + disp32) + RET (0xC3) = 6 bytes.
            const fn0_bytes = [_]u8{ 0xE9, 0, 0, 0, 0, 0xC3 };
            const fn1_bytes = [_]u8{0xC3};
            const fn0_fixups = [_]emit.CallFixup{.{ .byte_offset = 0, .target_func_idx = 1, .is_tail = true }};
            const bodies = [_]FuncBody{
                .{ .bytes = fn0_bytes[0..], .call_fixups = fn0_fixups[0..] },
                .{ .bytes = fn1_bytes[0..], .call_fixups = &.{} },
            };
            var module = try link(testing.allocator, &bodies, 0);
            defer module.deinit(testing.allocator);
            const fn0_off = module.func_offsets[0];
            const fn1_off = module.func_offsets[1];
            // disp = target - (fixup_abs + 5); fixup_abs = fn0_off + 0.
            const want_disp: i32 = @intCast(@as(i64, fn1_off) - @as(i64, fn0_off) - 5);
            // Opcode byte preserved as JMP (0xE9), not CALL (0xE8).
            try testing.expectEqual(@as(u8, 0xE9), module.block.bytes[fn0_off]);
            try testing.expectEqual(want_disp, std.mem.readInt(i32, module.block.bytes[fn0_off + 1 ..][0..4], .little));
        },
        else => @compileError("unsupported arch for linker fixup test"),
    }
}

test "link: is_tail=false fixup -> call (arm64 BL / x86_64 CALL); regression for the dispatch branch" {
    // D-193 / ADR-0122 D3: portable via comptime per-arch byte shape.
    // Non-tail call preserves a return frame: arm64 BL (0x94...),
    // x86_64 CALL (0xE8...). x86_64 opcode is emit-chosen; link()
    // patches only the rel32 disp. Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    switch (builtin.cpu.arch) {
        .aarch64 => {
            const ret_word: u32 = 0xD65F03C0;
            var fn0_bytes: [8]u8 = undefined;
            std.mem.writeInt(u32, fn0_bytes[0..4], 0x94000000, .little); // BL 0 placeholder
            std.mem.writeInt(u32, fn0_bytes[4..8], ret_word, .little);
            var fn1_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, fn1_bytes[0..4], ret_word, .little);
            const fn0_fixups = [_]emit.CallFixup{.{ .byte_offset = 0, .target_func_idx = 1 }}; // is_tail defaults false
            const bodies = [_]FuncBody{
                .{ .bytes = fn0_bytes[0..], .call_fixups = fn0_fixups[0..] },
                .{ .bytes = fn1_bytes[0..], .call_fixups = &.{} },
            };
            var module = try link(testing.allocator, &bodies, 0);
            defer module.deinit(testing.allocator);
            const fn0_off = module.func_offsets[0];
            const patched = std.mem.readInt(u32, module.block.bytes[fn0_off..][0..4], .little);
            // BL prefix (0x94...) — non-tail dispatch path intact.
            try testing.expectEqual(@as(u32, 0x94000000), patched & 0xFC000000);
        },
        .x86_64 => {
            // CALL rel32 placeholder (0xE8 + disp32) + RET (0xC3).
            const fn0_bytes = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 };
            const fn1_bytes = [_]u8{0xC3};
            const fn0_fixups = [_]emit.CallFixup{.{ .byte_offset = 0, .target_func_idx = 1 }};
            const bodies = [_]FuncBody{
                .{ .bytes = fn0_bytes[0..], .call_fixups = fn0_fixups[0..] },
                .{ .bytes = fn1_bytes[0..], .call_fixups = &.{} },
            };
            var module = try link(testing.allocator, &bodies, 0);
            defer module.deinit(testing.allocator);
            const fn0_off = module.func_offsets[0];
            const fn1_off = module.func_offsets[1];
            const want_disp: i32 = @intCast(@as(i64, fn1_off) - @as(i64, fn0_off) - 5);
            // CALL (0xE8...) opcode preserved.
            try testing.expectEqual(@as(u8, 0xE8), module.block.bytes[fn0_off]);
            try testing.expectEqual(want_disp, std.mem.readInt(i32, module.block.bytes[fn0_off + 1 ..][0..4], .little));
        },
        else => @compileError("unsupported arch for linker fixup test"),
    }
}

// ADR-0112 D3 — end-to-end `return_call`
// drives the full pipeline (emit → link → execute) on Mac aarch64.
// fn0 = `return_call 1 ; end` (no args, no locals → frame_bytes=0
// keeps the teardown to a single LDP). fn1 = `i32.const 7 ; end`.
// The caller invokes fn0 expecting i32; if the tail-call is wired
// correctly, fn1's body runs and its RET goes straight back to the
// Zig stub — the same observable as a regular call but via the
// B-fixup path (no LR clobber, no return through fn0).
test "link+execute: fn0 return_call fn1 returns 7 via B/JMP fixup (ADR-0112 D3/D4)" {
    // Both arches wired (arm64 + x86_64).
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const sigs = [_]zir.FuncType{
        .{ .params = &.{}, .results = &.{.i32} }, // fn0
        .{ .params = &.{}, .results = &.{.i32} }, // fn1
    };

    // fn0: () → i32  { return_call 1 ; end }
    var fn0 = ZirFunc.init(0, sigs[0], &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .return_call, .payload = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const fn0_slots = [_]u16{};
    const fn0_alloc: regalloc.Allocation = .{ .slots = &fn0_slots, .n_slots = 0 };

    // fn1: () → i32  { i32.const 7 ; end }
    var fn1 = ZirFunc.init(1, sigs[1], &.{});
    defer fn1.deinit(testing.allocator);
    try fn1.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn1.instrs.append(testing.allocator, .{ .op = .end });
    fn1.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn1_slots = [_]u16{0};
    const fn1_alloc: regalloc.Allocation = .{ .slots = &fn1_slots, .n_slots = 1 };

    const out0 = try emit.compile(testing.allocator, &fn0, fn0_alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out0);
    const out1 = try emit.compile(testing.allocator, &fn1, fn1_alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out1);

    const bodies = [_]FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
        .{ .bytes = out1.bytes, .call_fixups = out1.call_fixups },
    };
    var module = try link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    // Verify the fixup at fn0's tail-jump site patched into a
    // PC-relative tail-jump opcode (arm64: B 0x14..., not BL
    // 0x94...; x86_64: JMP 0xE9, not CALL 0xE8). Forward-scan is
    // robust to prologue layout changes that don't touch the
    // tail-call wire-up.
    const fn0_off: usize = module.func_offsets[0];
    const block_end: usize = module.func_offsets[1];
    var found_tail_jmp: bool = false;
    switch (builtin.cpu.arch) {
        .aarch64 => {
            var byte_off: usize = fn0_off;
            while (byte_off + 4 <= block_end) : (byte_off += 4) {
                const w = std.mem.readInt(u32, module.block.bytes[byte_off..][0..4], .little);
                if ((w & 0xFC000000) == 0x14000000) {
                    found_tail_jmp = true;
                    break;
                }
            }
        },
        .x86_64 => {
            // JMP rel32 = 0xE9 (5 bytes). CALL rel32 = 0xE8 (also 5
            // bytes); structurally similar but starts with the
            // different opcode byte. Scan byte-by-byte since x86
            // instruction boundaries aren't 4-aligned.
            var byte_off: usize = fn0_off;
            while (byte_off + 5 <= block_end) : (byte_off += 1) {
                if (module.block.bytes[byte_off] == 0xE9) {
                    found_tail_jmp = true;
                    break;
                }
            }
        },
        else => @compileError("unsupported host arch for tail-call e2e probe"),
    }
    try testing.expect(found_tail_jmp);

    // End-to-end execute: fn0 tail-calls fn1; fn1 returns 7.
    var memory: [0]u8 = .{};
    var rt: jit_abi.JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const Fn = *const fn (rt: *jit_abi.JitRuntime) callconv(.c) u32;
    const f = module.entry(0, Fn);
    // D-311: route through the cohort-clobber trampoline (NOT a raw `f(&rt)`).
    try testing.expectEqual(@as(u32, 7), try entry_mod.callEntrySafe(&rt, u32, f, .{}));
    try testing.expect(rt.jit_executed_flag != 0);
}

test "linkWithThunks: single multi-result function — wrapper invocation writes results buffer" {
    // D-193 triage: ungated. Gate already included x86_64 (ran on
    // ubuntu); removing the defensive over-skip on non-CI hosts
    // (Linux aarch64 / Mac x86_64). Win deferred per ADR-0122 phaseEnd.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const entry_buf = @import("entry_buffer_write.zig");

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 100 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 200 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 300 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
        .{ .def_pc = 1, .last_use_pc = 3 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 3,
        .result_abi = .register_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer emit.deinit(testing.allocator, out);

    const bodies = [_]FuncBody{.{ .bytes = out.bytes, .call_fixups = out.call_fixups }};
    const specs = [_]WrapperSpec{.{ .func_idx = 0, .sig = sig }};

    var module = try linkWithThunks(testing.allocator, &bodies, 0, &specs);
    defer module.deinit(testing.allocator);

    try testing.expect(module.thunk_offsets != null);
    try testing.expect(module.thunk_offsets.?[0] != JitModule.NO_THUNK);

    const fn_ptr = module.entry_buf(0, entry_buf.BufferWriteFn);
    var rt: entry_buf.JitRuntime = .{
        .vm_base = undefined,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    var args_buf: [1]u64 = .{0};
    var results_buf: [3]u64 = .{ 0, 0, 0 };
    try entry_buf.invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u32, 100), @as(u32, @intCast(results_buf[0] & 0xFFFFFFFF)));
    try testing.expectEqual(@as(u32, 200), @as(u32, @intCast(results_buf[1] & 0xFFFFFFFF)));
    try testing.expectEqual(@as(u32, 300), @as(u32, @intCast(results_buf[2] & 0xFFFFFFFF)));
}

test "link: populates code_map entries for each defined function" {
    // link() builds per-Instance CodeMap entries
    // from func_offsets so the FP-walk unwinder can translate a
    // saved LR / RIP into (func_idx, relative_pc). Synthetic bytes
    // (no real emit) are enough: link() copies them verbatim into
    // an executable JitBlock and we verify codeMap().lookup against
    // the resulting addresses.
    //
    // Layout: 2 defined functions of 16 + 32 bytes (offsets
    // 0 + 16). num_imports = 1 → wasm-space idx 1 + 2.
    var body0_bytes: [16]u8 = @splat(0);
    var body1_bytes: [32]u8 = @splat(0);
    const bodies = [_]FuncBody{
        .{ .bytes = body0_bytes[0..], .call_fixups = &.{} },
        .{ .bytes = body1_bytes[0..], .call_fixups = &.{} },
    };
    var module = try link(testing.allocator, &bodies, 1);
    defer module.deinit(testing.allocator);

    const cmap = module.codeMap();
    try testing.expectEqual(@as(usize, 2), cmap.entries.len);

    const block_addr = @intFromPtr(module.block.bytes.ptr);

    // fn1 (wasm idx 1) lives at offset 0; first defined function.
    try testing.expectEqual(@as(usize, block_addr), cmap.entries[0].start_addr);
    try testing.expectEqual(@as(u32, 16), cmap.entries[0].len);
    try testing.expectEqual(@as(u32, 1), cmap.entries[0].func_idx);

    // fn2 (wasm idx 2) starts at offset 16; length = 32.
    try testing.expectEqual(@as(usize, block_addr + 16), cmap.entries[1].start_addr);
    try testing.expectEqual(@as(u32, 32), cmap.entries[1].len);
    try testing.expectEqual(@as(u32, 2), cmap.entries[1].func_idx);

    // lookup() mid-fn1 returns the right relative_pc.
    const hit0 = cmap.lookup(block_addr + 8);
    try testing.expect(hit0 == .inside);
    try testing.expectEqual(@as(u32, 8), hit0.inside.relative_pc);
    try testing.expectEqual(@as(u32, 1), hit0.inside.func_idx);

    // lookup() mid-fn2 returns the right relative_pc.
    const hit1 = cmap.lookup(block_addr + 16 + 12);
    try testing.expect(hit1 == .inside);
    try testing.expectEqual(@as(u32, 12), hit1.inside.relative_pc);
    try testing.expectEqual(@as(u32, 2), hit1.inside.func_idx);

    // lookup() at start_addr exactly → relative_pc = 0.
    const hit_start = cmap.lookup(block_addr);
    try testing.expect(hit_start == .inside);
    try testing.expectEqual(@as(u32, 0), hit_start.inside.relative_pc);
    try testing.expectEqual(@as(u32, 1), hit_start.inside.func_idx);

    // lookup() past block → .outside.
    try testing.expectEqual(code_map.Lookup.outside, cmap.lookup(block_addr + 16 + 32));
}

test "link: import-only module — code_map empty" {
    // Zero defined functions → empty code_map entries.
    var module = try link(testing.allocator, &.{}, 2);
    defer module.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), module.codeMap().entries.len);
}

test "link: frame_bytes round-trips from FuncBody to CodeMap.Entry" {
    // `EmitOutput.frame_bytes`
    // flows through `FuncBody.frame_bytes` into
    // `CodeMap.Entry.frame_bytes`. The EH SP-restore path
    // (sp_restore.emitSpRestoreFull) reads this to recover the
    // handler frame's post-prologue SP boundary.
    var body0_bytes: [16]u8 = @splat(0);
    var body1_bytes: [32]u8 = @splat(0);
    const bodies = [_]FuncBody{
        .{ .bytes = body0_bytes[0..], .call_fixups = &.{}, .frame_bytes = 48 },
        .{ .bytes = body1_bytes[0..], .call_fixups = &.{}, .frame_bytes = 96 },
    };
    var module = try link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    const cmap = module.codeMap();
    try testing.expectEqual(@as(usize, 2), cmap.entries.len);
    try testing.expectEqual(@as(u32, 48), cmap.entries[0].frame_bytes);
    try testing.expectEqual(@as(u32, 96), cmap.entries[1].frame_bytes);
}
