// FILE-SIZE-EXEMPT: single-pass opcode→ZirOp lowering; 19 private helpers share the emit cursor, any extraction forces an N2 pub-leak (investigated 2026-08-12, per ADR-0099)
//! Wasm function-body **lowerer** — wasm opcode → ZirOp emission
//! into a pre-initialised `ZirFunc` (Phase 1 / §9.1 / 1.6).
//!
//! Single pass over the validated body bytes. The validator (§9.1 /
//! 1.5) is the structural gate; the lowerer trusts the byte stream
//! and only enforces what the encoding itself dictates (LEB128
//! truncation, blocktype byte, length of float immediates, function
//! frame closure). Per ROADMAP §P3 (cold-start) and §P6
//! (single-pass) this lowers without intermediate buffers; the only
//! allocation is the caller-provided `ZirFunc.instrs` /
//! `ZirFunc.blocks` ArrayLists.
//!
//! Immediate packing into the fixed `ZirInstr { op, payload: u32,
//! extra: u32 }` record:
//!   - `i32.const N`               → payload = bitcast(N: i32)
//!   - `i64.const N`               → payload = low32(N), extra = high32(N)
//!   - `f32.const x`               → payload = raw 4-byte LE bits
//!   - `f64.const x`               → payload = low32(bits), extra = high32(bits)
//!   - `local.{get,set,tee} K`     → payload = K
//!   - `br N`                      → payload = depth N
//!   - `block` / `loop` / `if`     → payload = block index into out.blocks,
//!                                   extra = arity (count of result values
//!                                   the block leaves on the operand stack;
//!                                   0 for empty, 1 for single valtype, ≥1
//!                                   for typeidx form per Wasm 2.0
//!                                   multivalue)
//!   - `else` / `end` (block-end)  → payload = block index of the matching frame
//!   - `end` (function frame)      → payload = 0, terminates the lowering walk
//!
//! Scope tracks the validator's MVP smoke set 1:1; opcodes outside
//! that subset return `Error.NotImplemented` until §9.1 / 1.7 wires
//! per-feature handlers via `DispatchTable` per ROADMAP §A12.
//!
//! Zone 1 (`src/frontend/`) — may import Zone 0 (`src/support/leb128.zig`)
//! and Zone 1 (`src/ir/`). No upward imports.

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const zir = @import("zir.zig");
const init_expr = @import("../parse/init_expr.zig");
const dispatch_collector = @import("dispatch_collector.zig");
const wasm_byte_map = @import("wasm_byte_map.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const BlockKind = zir.BlockKind;
const BlockInfo = zir.BlockInfo;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;

pub const Error = error{
    UnexpectedEnd,
    UnexpectedOpcode,
    BadBlockType,
    /// Malformed memarg per Wasm 3.0 §5.4.6: align value
    /// > 31 (exceeds u5 width of MemArgExtra.align_pow2), or
    /// memidx > 255 (exceeds u8 width of MemArgExtra.memidx).
    BadMemarg,
    ControlStackOverflow,
    TrailingBytes,
    NotImplemented,
    OutOfMemory,
} || leb128.Error;

pub const max_control_stack: usize = 1024;

/// D-093 (d-1) — sentinel in `block_stack[]` for blocks opened
/// while the lowerer is in dead-code mode. closeBlock detects
/// this and skips `.end` emission + `out.blocks` mutation.
const unreachable_block_sentinel: u32 = std.math.maxInt(u32);

/// Lower the body bytes into `out`. `out` must be initialised
/// (typically via `ZirFunc.init`); lowering appends to its
/// `instrs` and `blocks` lists. The caller retains ownership and
/// must call `out.deinit(alloc)` when done.
///
/// `module_types` is the module's type section. Lowering needs it
/// to resolve s33 typeidx blocktypes (Wasm 2.0 multivalue). Pass
/// an empty slice for standalone-function bodies that never use
/// typeidx blocks.
pub fn lowerFunctionBody(
    alloc: Allocator,
    body: []const u8,
    out: *ZirFunc,
    module_types: []const FuncType,
    select_types: []const u8,
) Error!void {
    return lowerFunctionBodyWith(alloc, body, out, module_types, select_types, &.{}, &.{});
}

/// Variant carrying `struct_field_counts` (typeidx-indexed; built from
/// the module's struct type defs in `engine/compile.zig`). 10.G GC-on-
/// JIT `struct.new` is variadic — its field count is determined by the
/// struct TYPE, not the instruction encoding — so lowering stamps the
/// count into `ZirInstr.extra` here, where the liveness pass + per-arch
/// emit read it without re-deriving the type section. `&.{}` (the
/// default via `lowerFunctionBody`) leaves struct.new `extra = 0`,
/// which the interp path ignores (it reads the runtime StructInfo).
pub fn lowerFunctionBodyWith(
    alloc: Allocator,
    body: []const u8,
    out: *ZirFunc,
    module_types: []const FuncType,
    select_types: []const u8,
    struct_field_counts: []const u32,
    array_elem_valtypes: []const u8,
) Error!void {
    var lo = Lowerer{
        .alloc = alloc,
        .body = body,
        .out = out,
        .pos = 0,
        .module_types = module_types,
        .select_types = select_types,
        .struct_field_counts = struct_field_counts,
        .array_elem_valtypes = array_elem_valtypes,
    };
    try lo.run();
}

pub const Lowerer = struct {
    alloc: Allocator,
    body: []const u8,
    out: *ZirFunc,
    pos: usize,
    module_types: []const FuncType,

    /// D-115 d-39: per-untyped-`select` (0x1B) resolved operand
    /// valtype bytes, in body-walk order. Sourced from
    /// `validate.validateFunctionAndCollectSelectTypes`. Empty slice
    /// disables select-extra resolution — `extra` stays 0 (the
    /// pre-d-39 default, which emit dispatches as gpr32 CSEL).
    select_types: []const u8 = &.{},
    select_idx: usize = 0,

    /// 10.G GC-on-JIT — typeidx-indexed struct field counts (from the
    /// module's struct defs). `struct.new` stamps `field_counts[typeidx]`
    /// into `ZirInstr.extra` so liveness + emit know the variadic pop
    /// count. Empty → struct.new `extra = 0` (interp path ignores it).
    struct_field_counts: []const u32 = &.{},

    /// 10.G GC-on-JIT (A-6a) — typeidx-indexed array element valtype bytes
    /// (0x78 i8 / 0x77 i16 / …). `array.get_s` stamps `valtypes[typeidx]`
    /// into `ZirInstr.extra` so the emit picks the packed-width extend
    /// (SXTB vs SXTH). Empty → `extra = 0` (interp path ignores it).
    array_elem_valtypes: []const u8 = &.{},

    block_stack: [max_control_stack]u32 = undefined,
    block_stack_len: usize = 0,

    /// D-093 (d-1) — Wasm spec §3.4 polymorphic-stack tracking.
    /// `null` = reachable; non-null = `block_stack_len` snapshot
    /// at the unconditional terminator (br / return / unreachable
    /// / br_table). While set, `emit()` becomes a no-op so dead
    /// ZirInstrs never reach the downstream regalloc / emit
    /// passes. Cleared at the matching `end` (closeBlock detects
    /// block_stack_len dropping below the saved depth) or at
    /// `else` (else-arm is reachable independent of then-arm's
    /// terminator). Block structure inside the dead region is
    /// still tracked via `block_stack` using the sentinel
    /// `unreachable_block_sentinel` so closeBlock knows whether
    /// to emit `.end` or just bookkeep.
    unreachable_at_depth: ?u32 = null,

    /// SIMD 16-byte const-pool builder (per ADR-0042). Each entry is
    /// the raw immediate of a `v128.const` / `i8x16.shuffle` op.
    /// Producing ops store the array index in `ZirInstr.payload`.
    /// Flushed to `out.simd_consts` at `run()` close.
    simd_consts: std.ArrayList([16]u8) = .empty,

    /// Wasm 3.0 EH (ADR-0114). Builders for the per-function
    /// landing-pad + catch-entry arrays. One LandingPad per
    /// `try_table` opcode (appended at openTryTable); catch entries
    /// land flat in `catch_entries` with `[start, end)` slice.
    /// Flushed to `out.eh_landing_pads` / `out.eh_catch_entries`
    /// at `run()` close.
    landing_pads: std.ArrayList(zir.LandingPad) = .empty,
    catch_entries: std.ArrayList(zir.CatchEntry) = .empty,

    fn run(self: *Lowerer) Error!void {
        errdefer self.simd_consts.deinit(self.alloc);
        errdefer self.landing_pads.deinit(self.alloc);
        errdefer self.catch_entries.deinit(self.alloc);
        var fn_done = false;
        while (!fn_done) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const op = self.body[self.pos];
            self.pos += 1;
            try self.dispatch(op, &fn_done);
        }
        if (self.pos != self.body.len) return Error.TrailingBytes;
        // Flush SIMD const-pool builder to func.simd_consts (transfer
        // ownership). If empty, leave func.simd_consts null.
        if (self.simd_consts.items.len > 0) {
            self.out.simd_consts = try self.simd_consts.toOwnedSlice(self.alloc);
        } else {
            self.simd_consts.deinit(self.alloc);
        }
        if (self.landing_pads.items.len > 0) {
            self.out.eh_landing_pads = try self.landing_pads.toOwnedSlice(self.alloc);
        } else {
            self.landing_pads.deinit(self.alloc);
        }
        if (self.catch_entries.items.len > 0) {
            self.out.eh_catch_entries = try self.catch_entries.toOwnedSlice(self.alloc);
        } else {
            self.catch_entries.deinit(self.alloc);
        }
    }

    /// Append a 16-byte SIMD constant to the per-function pool;
    /// return the index for `ZirInstr.payload` encoding.
    // SIBLING-PUB: lower_simd.zig (per ADR-0089 extraction)
    pub fn appendSimdConst(self: *Lowerer, bytes: [16]u8) Error!u32 {
        const idx: u32 = @intCast(self.simd_consts.items.len);
        try self.simd_consts.append(self.alloc, bytes);
        return idx;
    }

    fn dispatch(self: *Lowerer, op: u8, fn_done: *bool) Error!void {
        // §9.12-B / B8: route through dispatch_collector when the
        // bytecode maps to a migrated ZirOp. Same shape as the B7
        // validator wire — per ADR-0073 +
        // `.dev/dispatcher_wire_design.md` §2.2 (lower wire = "after
        // the byte-tag mapping is decided, route the payload-emit
        // through the dispatcher"). When the per-op file's `lower`
        // handler is a stub returning NotMigrated, the legacy
        // switch below retains authority. Mid-cycle migrations
        // (B9..Bn) activate per-op routing as real lower bodies land.
        if (wasm_byte_map.byteToZirOp(op)) |zir_tag| {
            if (dispatch_collector.dispatcher(.lower)(zir_tag, .{})) |_| {
                return;
            } else |err| switch (err) {
                error.NotMigrated, error.UnsupportedOpForBuildLevel => {},
            }
        }
        switch (op) {
            0x00 => {
                try self.emit(.@"unreachable", 0, 0);
                self.markUnreachable();
            },
            0x01 => try self.emit(.nop, 0, 0),
            0x02 => try self.openBlock(.block, .block),
            0x03 => try self.openBlock(.loop, .loop),
            0x04 => try self.openBlock(.if_then, .@"if"),
            // Wasm 3.0 exception-handling proposal (§4.5):
            // `try_table blocktype vec(catch) instr* end`. Foundation
            // wiring — the catch vec is parsed-and-discarded; body
            // runs like a block; full catch dispatch lands at 10.E-5.
            0x1F => try self.openTryTable(),
            // Wasm 3.0 EH `throw tag_idx` (§4.5): raise an exception
            // with the tag's payload. Terminator — marks the rest of
            // the block unreachable in the lowerer.
            0x08 => {
                try self.emitUlebPayload(.throw);
                self.markUnreachable();
            },
            // Wasm 3.0 EH `throw_ref`: re-raise the exception held by
            // the top-of-stack exnref. Terminator like `throw`.
            0x0A => {
                try self.emit(.throw_ref, 0, 0);
                self.markUnreachable();
            },
            0x05 => try self.emitElse(),
            0x0B => {
                if (self.block_stack_len == 0) {
                    // D-093 (d-1): function-end is always part
                    // of the canonical IR; clear the dead-region
                    // flag (if set by a top-level br/return/
                    // unreachable) so the `.end` ZirInstr lands.
                    self.unreachable_at_depth = null;
                    try self.emit(.end, 0, 0);
                    fn_done.* = true;
                } else {
                    try self.closeBlock();
                }
            },
            0x0C => {
                const depth = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.br, depth, 0);
                self.markUnreachable();
            },
            0x0F => {
                try self.emit(.@"return", 0, 0);
                self.markUnreachable();
            },
            0x1A => try self.emit(.drop, 0, 0),
            0x20 => try self.emitLocalIndexed(.@"local.get"),
            0x21 => try self.emitLocalIndexed(.@"local.set"),
            0x22 => try self.emitLocalIndexed(.@"local.tee"),
            0x41 => {
                const v = try leb128.readSleb128(i32, self.body, &self.pos);
                const bits: u32 = @bitCast(v);
                try self.emit(.@"i32.const", bits, 0);
            },
            0x42 => {
                const v = try leb128.readSleb128(i64, self.body, &self.pos);
                const u: u64 = @bitCast(v);
                const lo: u32 = @truncate(u);
                const hi: u32 = @truncate(u >> 32);
                try self.emit(.@"i64.const", lo, hi);
            },
            0x43 => {
                if (self.body.len - self.pos < 4) return Error.UnexpectedEnd;
                const bits = std.mem.readInt(u32, self.body[self.pos..][0..4], .little);
                self.pos += 4;
                try self.emit(.@"f32.const", bits, 0);
            },
            0x44 => {
                if (self.body.len - self.pos < 8) return Error.UnexpectedEnd;
                const lo = std.mem.readInt(u32, self.body[self.pos..][0..4], .little);
                const hi = std.mem.readInt(u32, self.body[self.pos..][4..8], .little);
                self.pos += 8;
                try self.emit(.@"f64.const", lo, hi);
            },
            // Control flow continued
            0x0D => try self.emitUlebPayload(.br_if),
            0x0E => try self.emitBrTable(),
            0x10 => try self.emitUlebPayload(.call),
            0x11 => try self.emitCallIndirect(),
            // Wasm 3.0 tail-call proposal (function-references + tail-call).
            // A tail call leaves the function like `return`, so what follows is
            // dead and must be dropped here: emit's dead-code arm skips the
            // try_table bookkeeping that liveness performs unconditionally.
            0x12 => {
                try self.emitUlebPayload(.return_call);
                self.markUnreachable();
            },
            0x13 => {
                try self.emitReturnCallIndirect();
                self.markUnreachable();
            },

            // Parametric
            0x1B => {
                // D-115 d-39: untyped select. Validator resolved
                // the operand valtype byte; consume one entry per
                // 0x1B occurrence (body-walk order). When the slice
                // is empty (callers that bypass the collect-side
                // entry point, e.g. compileOne unit tests pre-d-39
                // semantics), `extra` stays 0 and emit dispatches
                // the gpr32 path — correct for i32 operands, the
                // common untyped-select case.
                const extra: u32 = if (self.select_idx < self.select_types.len) blk: {
                    const b = self.select_types[self.select_idx];
                    self.select_idx += 1;
                    break :blk @as(u32, b);
                } else 0;
                try self.emit(.select, 0, extra);
            },
            0x1C => {
                // select_typed: count valtype*. Wasm 2.0 requires
                // count = 1; consume + emit select_typed (runtime
                // semantics identical to select).
                const count = try leb128.readUleb128(u32, self.body, &self.pos);
                if (count != 1) return Error.UnexpectedOpcode;
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                const t = self.body[self.pos];
                self.pos += 1;
                switch (t) {
                    // numeric + v128 + funcref/externref + GC/EH single-byte
                    // abstract reftypes (D-492: `select t` admits any valtype).
                    0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F => {},
                    0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69 => {}, // any/eq/i31/struct/array/exn ref
                    0x71, 0x72, 0x73, 0x74 => {}, // null{,extern,func,exn}ref
                    else => return Error.BadBlockType,
                }
                try self.emit(.select_typed, 0, t);
            },

            // Globals
            0x23 => try self.emitUlebPayload(.@"global.get"),
            0x24 => try self.emitUlebPayload(.@"global.set"),

            // Tables (Wasm 2.0 §9.2 / 2.3 chunk 5c)
            0x25 => try self.emitUlebPayload(.@"table.get"),
            0x26 => try self.emitUlebPayload(.@"table.set"),

            // Loads (memarg → align uleb32 + offset uleb32)
            0x28 => try self.emitMemarg(.@"i32.load"),
            0x29 => try self.emitMemarg(.@"i64.load"),
            0x2A => try self.emitMemarg(.@"f32.load"),
            0x2B => try self.emitMemarg(.@"f64.load"),
            0x2C => try self.emitMemarg(.@"i32.load8_s"),
            0x2D => try self.emitMemarg(.@"i32.load8_u"),
            0x2E => try self.emitMemarg(.@"i32.load16_s"),
            0x2F => try self.emitMemarg(.@"i32.load16_u"),
            0x30 => try self.emitMemarg(.@"i64.load8_s"),
            0x31 => try self.emitMemarg(.@"i64.load8_u"),
            0x32 => try self.emitMemarg(.@"i64.load16_s"),
            0x33 => try self.emitMemarg(.@"i64.load16_u"),
            0x34 => try self.emitMemarg(.@"i64.load32_s"),
            0x35 => try self.emitMemarg(.@"i64.load32_u"),

            // Stores
            0x36 => try self.emitMemarg(.@"i32.store"),
            0x37 => try self.emitMemarg(.@"i64.store"),
            0x38 => try self.emitMemarg(.@"f32.store"),
            0x39 => try self.emitMemarg(.@"f64.store"),
            0x3A => try self.emitMemarg(.@"i32.store8"),
            0x3B => try self.emitMemarg(.@"i32.store16"),
            0x3C => try self.emitMemarg(.@"i64.store8"),
            0x3D => try self.emitMemarg(.@"i64.store16"),
            0x3E => try self.emitMemarg(.@"i64.store32"),

            // Memory
            0x3F => try self.emitMemoryReserved(.@"memory.size"),
            0x40 => try self.emitMemoryReserved(.@"memory.grow"),

            // Numeric: testop / cmp / unop / binop
            0x45 => try self.emit(.@"i32.eqz", 0, 0),
            0x46 => try self.emit(.@"i32.eq", 0, 0),
            0x47 => try self.emit(.@"i32.ne", 0, 0),
            0x48 => try self.emit(.@"i32.lt_s", 0, 0),
            0x49 => try self.emit(.@"i32.lt_u", 0, 0),
            0x4A => try self.emit(.@"i32.gt_s", 0, 0),
            0x4B => try self.emit(.@"i32.gt_u", 0, 0),
            0x4C => try self.emit(.@"i32.le_s", 0, 0),
            0x4D => try self.emit(.@"i32.le_u", 0, 0),
            0x4E => try self.emit(.@"i32.ge_s", 0, 0),
            0x4F => try self.emit(.@"i32.ge_u", 0, 0),

            0x50 => try self.emit(.@"i64.eqz", 0, 0),
            0x51 => try self.emit(.@"i64.eq", 0, 0),
            0x52 => try self.emit(.@"i64.ne", 0, 0),
            0x53 => try self.emit(.@"i64.lt_s", 0, 0),
            0x54 => try self.emit(.@"i64.lt_u", 0, 0),
            0x55 => try self.emit(.@"i64.gt_s", 0, 0),
            0x56 => try self.emit(.@"i64.gt_u", 0, 0),
            0x57 => try self.emit(.@"i64.le_s", 0, 0),
            0x58 => try self.emit(.@"i64.le_u", 0, 0),
            0x59 => try self.emit(.@"i64.ge_s", 0, 0),
            0x5A => try self.emit(.@"i64.ge_u", 0, 0),

            0x5B => try self.emit(.@"f32.eq", 0, 0),
            0x5C => try self.emit(.@"f32.ne", 0, 0),
            0x5D => try self.emit(.@"f32.lt", 0, 0),
            0x5E => try self.emit(.@"f32.gt", 0, 0),
            0x5F => try self.emit(.@"f32.le", 0, 0),
            0x60 => try self.emit(.@"f32.ge", 0, 0),

            0x61 => try self.emit(.@"f64.eq", 0, 0),
            0x62 => try self.emit(.@"f64.ne", 0, 0),
            0x63 => try self.emit(.@"f64.lt", 0, 0),
            0x64 => try self.emit(.@"f64.gt", 0, 0),
            0x65 => try self.emit(.@"f64.le", 0, 0),
            0x66 => try self.emit(.@"f64.ge", 0, 0),

            0x67 => try self.emit(.@"i32.clz", 0, 0),
            0x68 => try self.emit(.@"i32.ctz", 0, 0),
            0x69 => try self.emit(.@"i32.popcnt", 0, 0),
            0x6A => try self.emit(.@"i32.add", 0, 0),
            0x6B => try self.emit(.@"i32.sub", 0, 0),
            0x6C => try self.emit(.@"i32.mul", 0, 0),
            0x6D => try self.emit(.@"i32.div_s", 0, 0),
            0x6E => try self.emit(.@"i32.div_u", 0, 0),
            0x6F => try self.emit(.@"i32.rem_s", 0, 0),
            0x70 => try self.emit(.@"i32.rem_u", 0, 0),
            0x71 => try self.emit(.@"i32.and", 0, 0),
            0x72 => try self.emit(.@"i32.or", 0, 0),
            0x73 => try self.emit(.@"i32.xor", 0, 0),
            0x74 => try self.emit(.@"i32.shl", 0, 0),
            0x75 => try self.emit(.@"i32.shr_s", 0, 0),
            0x76 => try self.emit(.@"i32.shr_u", 0, 0),
            0x77 => try self.emit(.@"i32.rotl", 0, 0),
            0x78 => try self.emit(.@"i32.rotr", 0, 0),

            0x79 => try self.emit(.@"i64.clz", 0, 0),
            0x7A => try self.emit(.@"i64.ctz", 0, 0),
            0x7B => try self.emit(.@"i64.popcnt", 0, 0),
            0x7C => try self.emit(.@"i64.add", 0, 0),
            0x7D => try self.emit(.@"i64.sub", 0, 0),
            0x7E => try self.emit(.@"i64.mul", 0, 0),
            0x7F => try self.emit(.@"i64.div_s", 0, 0),
            0x80 => try self.emit(.@"i64.div_u", 0, 0),
            0x81 => try self.emit(.@"i64.rem_s", 0, 0),
            0x82 => try self.emit(.@"i64.rem_u", 0, 0),
            0x83 => try self.emit(.@"i64.and", 0, 0),
            0x84 => try self.emit(.@"i64.or", 0, 0),
            0x85 => try self.emit(.@"i64.xor", 0, 0),
            0x86 => try self.emit(.@"i64.shl", 0, 0),
            0x87 => try self.emit(.@"i64.shr_s", 0, 0),
            0x88 => try self.emit(.@"i64.shr_u", 0, 0),
            0x89 => try self.emit(.@"i64.rotl", 0, 0),
            0x8A => try self.emit(.@"i64.rotr", 0, 0),

            0x8B => try self.emit(.@"f32.abs", 0, 0),
            0x8C => try self.emit(.@"f32.neg", 0, 0),
            0x8D => try self.emit(.@"f32.ceil", 0, 0),
            0x8E => try self.emit(.@"f32.floor", 0, 0),
            0x8F => try self.emit(.@"f32.trunc", 0, 0),
            0x90 => try self.emit(.@"f32.nearest", 0, 0),
            0x91 => try self.emit(.@"f32.sqrt", 0, 0),
            0x92 => try self.emit(.@"f32.add", 0, 0),
            0x93 => try self.emit(.@"f32.sub", 0, 0),
            0x94 => try self.emit(.@"f32.mul", 0, 0),
            0x95 => try self.emit(.@"f32.div", 0, 0),
            0x96 => try self.emit(.@"f32.min", 0, 0),
            0x97 => try self.emit(.@"f32.max", 0, 0),
            0x98 => try self.emit(.@"f32.copysign", 0, 0),

            0x99 => try self.emit(.@"f64.abs", 0, 0),
            0x9A => try self.emit(.@"f64.neg", 0, 0),
            0x9B => try self.emit(.@"f64.ceil", 0, 0),
            0x9C => try self.emit(.@"f64.floor", 0, 0),
            0x9D => try self.emit(.@"f64.trunc", 0, 0),
            0x9E => try self.emit(.@"f64.nearest", 0, 0),
            0x9F => try self.emit(.@"f64.sqrt", 0, 0),
            0xA0 => try self.emit(.@"f64.add", 0, 0),
            0xA1 => try self.emit(.@"f64.sub", 0, 0),
            0xA2 => try self.emit(.@"f64.mul", 0, 0),
            0xA3 => try self.emit(.@"f64.div", 0, 0),
            0xA4 => try self.emit(.@"f64.min", 0, 0),
            0xA5 => try self.emit(.@"f64.max", 0, 0),
            0xA6 => try self.emit(.@"f64.copysign", 0, 0),

            // Conversions
            0xA7 => try self.emit(.@"i32.wrap_i64", 0, 0),
            0xA8 => try self.emit(.@"i32.trunc_f32_s", 0, 0),
            0xA9 => try self.emit(.@"i32.trunc_f32_u", 0, 0),
            0xAA => try self.emit(.@"i32.trunc_f64_s", 0, 0),
            0xAB => try self.emit(.@"i32.trunc_f64_u", 0, 0),
            0xAC => try self.emit(.@"i64.extend_i32_s", 0, 0),
            0xAD => try self.emit(.@"i64.extend_i32_u", 0, 0),
            0xAE => try self.emit(.@"i64.trunc_f32_s", 0, 0),
            0xAF => try self.emit(.@"i64.trunc_f32_u", 0, 0),
            0xB0 => try self.emit(.@"i64.trunc_f64_s", 0, 0),
            0xB1 => try self.emit(.@"i64.trunc_f64_u", 0, 0),
            0xB2 => try self.emit(.@"f32.convert_i32_s", 0, 0),
            0xB3 => try self.emit(.@"f32.convert_i32_u", 0, 0),
            0xB4 => try self.emit(.@"f32.convert_i64_s", 0, 0),
            0xB5 => try self.emit(.@"f32.convert_i64_u", 0, 0),
            0xB6 => try self.emit(.@"f32.demote_f64", 0, 0),
            0xB7 => try self.emit(.@"f64.convert_i32_s", 0, 0),
            0xB8 => try self.emit(.@"f64.convert_i32_u", 0, 0),
            0xB9 => try self.emit(.@"f64.convert_i64_s", 0, 0),
            0xBA => try self.emit(.@"f64.convert_i64_u", 0, 0),
            0xBB => try self.emit(.@"f64.promote_f32", 0, 0),
            0xBC => try self.emit(.@"i32.reinterpret_f32", 0, 0),
            0xBD => try self.emit(.@"i64.reinterpret_f64", 0, 0),
            0xBE => try self.emit(.@"f32.reinterpret_i32", 0, 0),
            0xBF => try self.emit(.@"f64.reinterpret_i64", 0, 0),

            // Wasm 2.0 sign extension
            0xC0 => try self.emit(.@"i32.extend8_s", 0, 0),
            0xC1 => try self.emit(.@"i32.extend16_s", 0, 0),
            0xC2 => try self.emit(.@"i64.extend8_s", 0, 0),
            0xC3 => try self.emit(.@"i64.extend16_s", 0, 0),
            0xC4 => try self.emit(.@"i64.extend32_s", 0, 0),

            // Wasm 2.0 reference types + Wasm 3.0 function-references
            // (typed null) + GC abstract heads.
            // ADR-0123 Cycle 5: heaptype is either a single-byte
            // abstract head OR a signed LEB128 type-section index.
            // Lowered `extra` carries the encoding-byte for legacy
            // path compatibility (0x70 / 0x6F) — the runtime treats
            // ref.null uniformly as Value.null_ref regardless of
            // heap type, so the static distinction lives only in
            // the validator type stack (cycle 90 ValType pivot).
            0xD0 => {
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                const b = self.body[self.pos];
                const is_abstract = switch (b) {
                    0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69, 0x71, 0x72, 0x73, 0x74 => true,
                    else => false,
                };
                if (is_abstract) {
                    self.pos += 1;
                    try self.emit(.@"ref.null", 0, b);
                } else {
                    // Concrete typed null: consume signed-LEB; emit
                    // with extra=0x70 (funcref encoding placeholder)
                    // since runtime semantics are identical. The
                    // signed-LEB must be non-negative per spec
                    // §5.3.5 (heap-type indices are u32); negative
                    // values are not valid heap types — reject as
                    // BadBlockType for backward compatibility with
                    // the pre-cycle-90 rejection test.
                    const idx_signed = leb128.readSleb128(i33, self.body, &self.pos) catch return Error.BadBlockType;
                    if (idx_signed < 0) return Error.BadBlockType;
                    try self.emit(.@"ref.null", 0, 0x70);
                }
            },
            0xD1 => try self.emit(.@"ref.is_null", 0, 0),
            0xD2 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"ref.func", idx, 0);
            },
            // Wasm 3.0 GC §3.3.5.2 — ref.eq is single-byte 0xD3 (NOT
            // 0xFB 0x13 = array.init_elem; cyc156 mis-numbering fix).
            0xD3 => try self.emit(.@"ref.eq", 0, 0),
            // Wasm 3.0 typed function references (function-references proposal).
            0xD4 => try self.emit(.@"ref.as_non_null", 0, 0),
            0xD5 => try self.emitUlebPayload(.br_on_null),
            0xD6 => try self.emitUlebPayload(.br_on_non_null),
            0x14 => try self.emitUlebPayload(.call_ref),
            0x15 => {
                try self.emitUlebPayload(.return_call_ref);
                self.markUnreachable();
            },

            // Wasm 2.0+ prefix opcodes (sat-trunc / bulk-memory / ...)
            0xFC => try self.emitPrefixFC(),

            // Wasm 3.0 GC prefix (struct / array / ref.test / ref.cast /
            // i31 / br_on_cast ...). Currently dispatches only the i31
            // sub-trio; remaining GC ops light up per 10.G sub-chunks.
            0xFB => try self.emitPrefixFB(),

            // Wasm SIMD-128 prefix (§9.9 per ADR-0041).
            // Sub-opcode is uleb32; emit lands the ZirOp + immediate
            // payload mirroring the validator's prefix-0xFD catalogue
            // from §9.9/9.3.
            0xFD => try self.emitPrefixFD(),

            // Wasm threads/atomics prefix (0xFE, ADR-0168). Sub-op
            // is uleb32; emit lands the reserved-atomics ZirOp. The
            // validator already rejected malformed encodings.
            0xFE => try self.emitPrefixFE(),

            else => return Error.NotImplemented,
        }
    }

    // SIBLING-PUB: lower_simd.zig (per ADR-0089 extraction)
    pub fn emit(self: *Lowerer, op: ZirOp, payload: u64, extra: u32) Error!void {
        // D-093 (d-1): skip ZirInstr emission while in the dead
        // region following an unconditional terminator. Operand
        // bytes are still consumed by the caller (the dispatch
        // arm parses them before calling `emit`), so the lowerer
        // stays positionally correct in `self.body`.
        if (self.unreachable_at_depth != null) return;
        try self.out.instrs.append(self.alloc, .{ .op = op, .payload = payload, .extra = extra });
    }

    /// Wasm 2.0+ prefix-0xFC opcode group. Sub-opcode is uleb32.
    /// Sub-opcodes 0..7 are saturating truncations (§9.2 / 2.3
    /// chunk 2); 10/11 are memory.copy/memory.fill (chunk 4); other
    /// sub-opcodes land in later chunks.
    /// Wasm 3.0 GC prefix (0xFB). Sub-opcodes encode struct / array /
    /// ref.test / ref.cast / i31 / br_on_cast etc.; this dispatcher
    /// currently handles the i31 trio + ref.test / ref.test_null
    /// (10.G op_gc cycle 7). Other sub-opcodes land per 10.G heap /
    /// struct / array sub-chunks.
    fn emitPrefixFB(self: *Lowerer) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            // struct.new / struct.new_default (Wasm 3.0 GC §3.3.5.6.1).
            // Encoding: 0xFB {0,1} typeidx(uleb32). Pack typeidx in
            // payload; runtime handler reads it for the StructInfo
            // lookup (deferred to RTT integration).
            0 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                // Stamp the struct's field count into `extra` so the
                // variadic liveness pop + per-arch emit field-store loop
                // know it without the type section (10.G GC-on-JIT A-3).
                const field_count: u32 = if (typeidx < self.struct_field_counts.len)
                    self.struct_field_counts[typeidx]
                else
                    0;
                try self.emit(.@"struct.new", typeidx, field_count);
            },
            1 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"struct.new_default", typeidx, 0);
            },
            // struct.get / struct.get_s / struct.get_u / struct.set
            // (Wasm 3.0 GC §3.3.5.6.2-4). Encoding: 0xFB {2..5}
            // typeidx(uleb32) fieldidx(uleb32). Pack typeidx in
            // payload + fieldidx in extra.
            2, 3, 4, 5 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const fieldidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const tag: zir.ZirOp = switch (sub) {
                    2 => .@"struct.get",
                    3 => .@"struct.get_s",
                    4 => .@"struct.get_u",
                    5 => .@"struct.set",
                    else => unreachable,
                };
                try self.emit(tag, typeidx, fieldidx);
            },
            // array.new / array.new_default (Wasm 3.0 GC §3.3.5.6.6).
            // Encoding: 0xFB {6,7} typeidx(uleb32). Pack typeidx in payload.
            6 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"array.new", typeidx, 0);
            },
            7 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"array.new_default", typeidx, 0);
            },
            // array.new_fixed (Wasm 3.0 GC §3.3.5.6.8).
            // Encoding: 0xFB 0x08 typeidx(uleb32) N(uleb32).
            // Pack typeidx in payload + N in extra.
            8 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const n = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"array.new_fixed", typeidx, n);
            },
            // array.new_data / array.new_elem (Wasm 3.0 GC §3.3.5.6.7/8).
            // Encoding: 0xFB {9,10} typeidx(uleb32) segidx(uleb32).
            // payload=typeidx, extra=segidx.
            9, 10 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const segidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const tag: zir.ZirOp = if (sub == 9) .@"array.new_data" else .@"array.new_elem";
                try self.emit(tag, typeidx, segidx);
            },
            // array.get / array.get_s / array.get_u / array.set / array.fill
            // (Wasm 3.0 GC §3.3.5.6.10-14). Encoding: 0xFB {11..14,16}
            // typeidx(uleb32). Pack typeidx in payload. `array.get_s` (sub 12)
            // and `array.get_u` (sub 13) additionally stamp the packed element
            // valtype byte into `extra` so the JIT emit picks the sign/zero-
            // extend width (i8 vs i16) without re-deriving the type section
            // (A-6a/b; mirror struct.new's field-count stamp).
            11, 12, 13, 14, 16 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const tag: zir.ZirOp = switch (sub) {
                    11 => .@"array.get",
                    12 => .@"array.get_s",
                    13 => .@"array.get_u",
                    14 => .@"array.set",
                    16 => .@"array.fill",
                    else => unreachable,
                };
                const extra: u32 = if ((sub == 12 or sub == 13) and typeidx < self.array_elem_valtypes.len)
                    self.array_elem_valtypes[typeidx]
                else
                    0;
                try self.emit(tag, typeidx, extra);
            },
            // array.len (Wasm 3.0 GC §3.3.5.6.13). No immediates.
            15 => try self.emit(.@"array.len", 0, 0),
            // array.copy (sub-op 17): dst_typeidx + src_typeidx.
            // payload=dst, extra=src (10.G cycle 157).
            17 => {
                const dst_typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const src_typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"array.copy", dst_typeidx, src_typeidx);
            },
            // array.init_data (18) / array.init_elem (19): typeidx + segidx.
            // payload=typeidx, extra=segidx (10.G cycle 158).
            18, 19 => {
                const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const segidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const tag: zir.ZirOp = if (sub == 18) .@"array.init_data" else .@"array.init_elem";
                try self.emit(tag, typeidx, segidx);
            },
            // ref.test / ref.test_null (Wasm 3.0 GC §3.3.5.3).
            // Each consumes an SLEB128 heap_type immediate (D-453: a
            // concrete idx ≥ 64 is multi-byte). `readHeapType` advances
            // pos past the full SLEB and returns the D-453 encoded u32
            // (abstract head / idx<64 → bare byte; idx≥64 → 0x8000_0000|idx)
            // stored in payload so the runtime type-test can resolve it.
            20 => {
                const ht = init_expr.readHeapType(self.body, &self.pos) catch return Error.UnexpectedOpcode;
                try self.emit(.@"ref.test", ht, 0);
            },
            21 => {
                const ht = init_expr.readHeapType(self.body, &self.pos) catch return Error.UnexpectedOpcode;
                try self.emit(.@"ref.test_null", ht, 0);
            },
            // ref.cast / ref.cast_null (Wasm 3.0 GC §3.3.5.4).
            // Same SLEB heap_type encoding as ref.test family.
            22 => {
                const ht = init_expr.readHeapType(self.body, &self.pos) catch return Error.UnexpectedOpcode;
                try self.emit(.@"ref.cast", ht, 0);
            },
            23 => {
                const ht = init_expr.readHeapType(self.body, &self.pos) catch return Error.UnexpectedOpcode;
                try self.emit(.@"ref.cast_null", ht, 0);
            },
            // br_on_cast / br_on_cast_fail (Wasm 3.0 GC §3.3.5.5).
            // Wire: flags(u8) labelidx(uleb32) ht1(SLEB) ht2(SLEB).
            // D-453 IR encoding: ht1 is validation-only (the validator
            // already checked rt2<:rt1) so it is DROPPED here; the target
            // ht2 needs the full u32 width (idx≥64) so it can't share
            // `extra` with labelidx+flags. payload = labelidx |
            // (ht2_encoded << 32); extra = flags.
            24, 25 => {
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                const flags = self.body[self.pos];
                self.pos += 1;
                const labelidx = try leb128.readUleb128(u32, self.body, &self.pos);
                _ = init_expr.readHeapType(self.body, &self.pos) catch return Error.UnexpectedOpcode; // ht1 (validation-only)
                const ht2 = init_expr.readHeapType(self.body, &self.pos) catch return Error.UnexpectedOpcode;
                const payload: u64 = @as(u64, labelidx) | (@as(u64, ht2) << 32);
                const tag: zir.ZirOp = if (sub == 24) .br_on_cast else .br_on_cast_fail;
                try self.emit(tag, payload, flags);
            },
            // any.convert_extern / extern.convert_any (Wasm 3.0 GC
            // §3.3.5.7). No immediates; reinterpret the operand
            // between any and extern hierarchies.
            26 => try self.emit(.@"any.convert_extern", 0, 0),
            27 => try self.emit(.@"extern.convert_any", 0, 0),
            28 => try self.emit(.@"ref.i31", 0, 0),
            29 => try self.emit(.@"i31.get_s", 0, 0),
            30 => try self.emit(.@"i31.get_u", 0, 0),
            else => return Error.NotImplemented,
        }
    }

    fn emitPrefixFC(self: *Lowerer) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            0 => try self.emit(.@"i32.trunc_sat_f32_s", 0, 0),
            1 => try self.emit(.@"i32.trunc_sat_f32_u", 0, 0),
            2 => try self.emit(.@"i32.trunc_sat_f64_s", 0, 0),
            3 => try self.emit(.@"i32.trunc_sat_f64_u", 0, 0),
            4 => try self.emit(.@"i64.trunc_sat_f32_s", 0, 0),
            5 => try self.emit(.@"i64.trunc_sat_f32_u", 0, 0),
            6 => try self.emit(.@"i64.trunc_sat_f64_s", 0, 0),
            7 => try self.emit(.@"i64.trunc_sat_f64_u", 0, 0),
            8 => {
                // memory.init: dataidx + memidx (was reserved 0x00).
                // 10.M cycle 67 — memidx LEB-decoded into `extra`
                // (dataidx stays in `payload`). Multi-memory routes
                // the destination memory via the new extra field.
                const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const dst_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"memory.init", dataidx, dst_memidx);
            },
            9 => {
                // data.drop: dataidx.
                const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"data.drop", dataidx, 0);
            },
            12 => {
                // table.init x y: elemidx + tableidx.
                const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const tableidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.init", elemidx, tableidx);
            },
            13 => {
                // elem.drop x: elemidx.
                const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"elem.drop", elemidx, 0);
            },
            14 => {
                // table.copy x y: dst-tableidx + src-tableidx.
                const dst = try leb128.readUleb128(u32, self.body, &self.pos);
                const src = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.copy", dst, src);
            },
            15 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.grow", idx, 0);
            },
            16 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.size", idx, 0);
            },
            17 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.fill", idx, 0);
            },
            10 => {
                // memory.copy: dst-memidx + src-memidx (was two
                // reserved 0x00 bytes). 10.M cycle 67 — packed as
                // payload=dst_memidx, extra=src_memidx.
                const dst_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const src_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"memory.copy", dst_memidx, src_memidx);
            },
            11 => {
                // memory.fill: memidx (was reserved 0x00). 10.M cycle
                // 67 — packed as payload=memidx.
                const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"memory.fill", memidx, 0);
            },
            // Wasm wide-arithmetic (ADR-0168 v0.2) — no immediates.
            19 => try self.emit(.@"i64.add128", 0, 0),
            20 => try self.emit(.@"i64.sub128", 0, 0),
            21 => try self.emit(.@"i64.mul_wide_s", 0, 0),
            22 => try self.emit(.@"i64.mul_wide_u", 0, 0),
            else => return Error.NotImplemented,
        }
    }

    fn emitPrefixFD(self: *Lowerer) Error!void {
        return @import("lower_simd.zig").emitPrefixFD(self);
    }

    /// Wasm threads/atomics prefix-0xFE opcode group (ADR-0168).
    /// Sub-op 0x03 = atomic.fence: consume the reserved memory-order
    /// byte (already validated == 0x00) and emit the no-op fence.
    /// 0x00..0x02 / 0x10+ (notify/wait/load/store/rmw/cmpxchg) land
    /// in later chunks.
    fn emitPrefixFE(self: *Lowerer) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            // memory.atomic.notify / wait{32,64} — carry a memarg
            // (offset + align/memidx) identical to the load/store shape.
            0x00 => try self.emitMemarg(.@"memory.atomic.notify"),
            0x01 => try self.emitMemarg(.@"memory.atomic.wait32"),
            0x02 => try self.emitMemarg(.@"memory.atomic.wait64"),
            0x03 => {
                self.pos += 1; // reserved memory-order byte
                try self.emit(.@"atomic.fence", 0, 0);
            },
            // i32.atomic.load — memarg payload identical to i32.load.
            0x10 => try self.emitMemarg(.@"i32.atomic.load"),
            0x11 => try self.emitMemarg(.@"i64.atomic.load"),
            0x12 => try self.emitMemarg(.@"i32.atomic.load8_u"),
            0x13 => try self.emitMemarg(.@"i32.atomic.load16_u"),
            0x14 => try self.emitMemarg(.@"i64.atomic.load8_u"),
            0x15 => try self.emitMemarg(.@"i64.atomic.load16_u"),
            0x16 => try self.emitMemarg(.@"i64.atomic.load32_u"),
            0x17 => try self.emitMemarg(.@"i32.atomic.store"),
            0x18 => try self.emitMemarg(.@"i64.atomic.store"),
            0x19 => try self.emitMemarg(.@"i32.atomic.store8"),
            0x1A => try self.emitMemarg(.@"i32.atomic.store16"),
            0x1B => try self.emitMemarg(.@"i64.atomic.store8"),
            0x1C => try self.emitMemarg(.@"i64.atomic.store16"),
            0x1D => try self.emitMemarg(.@"i64.atomic.store32"),
            0x1E => try self.emitMemarg(.@"i32.atomic.rmw.add"),
            0x1F => try self.emitMemarg(.@"i64.atomic.rmw.add"),
            0x20 => try self.emitMemarg(.@"i32.atomic.rmw8.add_u"),
            0x21 => try self.emitMemarg(.@"i32.atomic.rmw16.add_u"),
            0x22 => try self.emitMemarg(.@"i64.atomic.rmw8.add_u"),
            0x23 => try self.emitMemarg(.@"i64.atomic.rmw16.add_u"),
            0x24 => try self.emitMemarg(.@"i64.atomic.rmw32.add_u"),
            0x25 => try self.emitMemarg(.@"i32.atomic.rmw.sub"),
            0x26 => try self.emitMemarg(.@"i64.atomic.rmw.sub"),
            0x27 => try self.emitMemarg(.@"i32.atomic.rmw8.sub_u"),
            0x28 => try self.emitMemarg(.@"i32.atomic.rmw16.sub_u"),
            0x29 => try self.emitMemarg(.@"i64.atomic.rmw8.sub_u"),
            0x2A => try self.emitMemarg(.@"i64.atomic.rmw16.sub_u"),
            0x2B => try self.emitMemarg(.@"i64.atomic.rmw32.sub_u"),
            0x2C => try self.emitMemarg(.@"i32.atomic.rmw.and"),
            0x2D => try self.emitMemarg(.@"i64.atomic.rmw.and"),
            0x2E => try self.emitMemarg(.@"i32.atomic.rmw8.and_u"),
            0x2F => try self.emitMemarg(.@"i32.atomic.rmw16.and_u"),
            0x30 => try self.emitMemarg(.@"i64.atomic.rmw8.and_u"),
            0x31 => try self.emitMemarg(.@"i64.atomic.rmw16.and_u"),
            0x32 => try self.emitMemarg(.@"i64.atomic.rmw32.and_u"),
            0x33 => try self.emitMemarg(.@"i32.atomic.rmw.or"),
            0x34 => try self.emitMemarg(.@"i64.atomic.rmw.or"),
            0x35 => try self.emitMemarg(.@"i32.atomic.rmw8.or_u"),
            0x36 => try self.emitMemarg(.@"i32.atomic.rmw16.or_u"),
            0x37 => try self.emitMemarg(.@"i64.atomic.rmw8.or_u"),
            0x38 => try self.emitMemarg(.@"i64.atomic.rmw16.or_u"),
            0x39 => try self.emitMemarg(.@"i64.atomic.rmw32.or_u"),
            0x3A => try self.emitMemarg(.@"i32.atomic.rmw.xor"),
            0x3B => try self.emitMemarg(.@"i64.atomic.rmw.xor"),
            0x3C => try self.emitMemarg(.@"i32.atomic.rmw8.xor_u"),
            0x3D => try self.emitMemarg(.@"i32.atomic.rmw16.xor_u"),
            0x3E => try self.emitMemarg(.@"i64.atomic.rmw8.xor_u"),
            0x3F => try self.emitMemarg(.@"i64.atomic.rmw16.xor_u"),
            0x40 => try self.emitMemarg(.@"i64.atomic.rmw32.xor_u"),
            0x41 => try self.emitMemarg(.@"i32.atomic.rmw.xchg"),
            0x42 => try self.emitMemarg(.@"i64.atomic.rmw.xchg"),
            0x43 => try self.emitMemarg(.@"i32.atomic.rmw8.xchg_u"),
            0x44 => try self.emitMemarg(.@"i32.atomic.rmw16.xchg_u"),
            0x45 => try self.emitMemarg(.@"i64.atomic.rmw8.xchg_u"),
            0x46 => try self.emitMemarg(.@"i64.atomic.rmw16.xchg_u"),
            0x47 => try self.emitMemarg(.@"i64.atomic.rmw32.xchg_u"),
            0x48 => try self.emitMemarg(.@"i32.atomic.rmw.cmpxchg"),
            0x49 => try self.emitMemarg(.@"i64.atomic.rmw.cmpxchg"),
            0x4A => try self.emitMemarg(.@"i32.atomic.rmw8.cmpxchg_u"),
            0x4B => try self.emitMemarg(.@"i32.atomic.rmw16.cmpxchg_u"),
            0x4C => try self.emitMemarg(.@"i64.atomic.rmw8.cmpxchg_u"),
            0x4D => try self.emitMemarg(.@"i64.atomic.rmw16.cmpxchg_u"),
            0x4E => try self.emitMemarg(.@"i64.atomic.rmw32.cmpxchg_u"),
            else => return Error.NotImplemented,
        }
    }

    fn emitLocalIndexed(self: *Lowerer, op: ZirOp) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(op, idx, 0);
    }

    /// br_if / call / global.get / global.set: read uleb32 → payload.
    fn emitUlebPayload(self: *Lowerer, op: ZirOp) Error!void {
        const v = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(op, v, 0);
    }

    /// memarg-bearing op (load*/store*): payload = offset,
    /// extra = packed MemArgExtra { align_pow2, memidx, _pad }
    /// per Wasm 3.0 §5.4.6 (ADR-0111 D3). The align uleb's bit
    /// 6 (0x40) is the memidx-presence flag — if set, a memidx
    /// uleb follows and the effective log2-align is `align & 0x3F`.
    // SIBLING-PUB: lower_simd.zig (per ADR-0089 extraction)
    pub fn emitMemarg(self: *Lowerer, op: ZirOp) Error!void {
        const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
        const has_memidx = (raw_align & 0x40) != 0;
        const align_pow2_val = if (has_memidx) (raw_align & 0x3F) else raw_align;
        if (align_pow2_val > std.math.maxInt(u5)) return Error.BadMemarg;
        const memidx_val: u32 = if (has_memidx)
            try leb128.readUleb128(u32, self.body, &self.pos)
        else
            0;
        if (memidx_val > std.math.maxInt(u8)) return Error.BadMemarg;
        const offset = try self.readMemargOffset();
        const extra = zir.MemArgExtra.pack(
            @intCast(align_pow2_val),
            @intCast(memidx_val),
        );
        try self.emit(op, offset, extra);
    }

    /// Decode a memarg offset. Wasm 3.0 §5.4.6: a memory64 offset is a
    /// u64 (≤ 10-byte LEB; clang/lld pad these to fixed relocatable
    /// width). The body is already validated — the validator gatekeeps
    /// the per-memory-type width (`skipMemargOffset`: an i32 memory's
    /// offset is decoded at u32 width, so an offset > 2^32 on an i32
    /// memory is rejected upstream) — so a u64 offset that reaches here
    /// belongs to a memory64. The `zir` payload slot is u64, so D-209:
    /// keep the full u64 (the prior u32 cap was the artificial narrowing
    /// that rejected a genuine > 4 GiB memory64 offset; the 64-bit
    /// base+offset + carry-trap codegen already handles it on both arches).
    // SIBLING-PUB: lower_simd.zig emitMemargLane (per ADR-0089 extraction)
    pub fn readMemargOffset(self: *Lowerer) Error!u64 {
        return try leb128.readUleb128(u64, self.body, &self.pos);
    }

    /// memory.size / memory.grow: takes a single memidx byte (was
    /// "reserved 0x00" in Wasm 1.0/2.0; the multi-memory proposal
    /// in Wasm 3.0 turns it into a real memidx). The memidx is
    /// LEB128-encoded per Wasm spec §5.4.6 and lands in
    /// `ZirInstr.payload` so the interp handler can route through
    /// `rt.memories[memidx]` (cycle 64's MemArgExtra plumbing did
    /// the same for load/store via `instr.extra`; for memory.size /
    /// memory.grow which take no other operands `payload` is
    /// available and the wider 32-bit width is wasted but harmless).
    fn emitMemoryReserved(self: *Lowerer, op: ZirOp) Error!void {
        const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(op, memidx, 0);
    }

    /// call_indirect: type_idx + table_idx (Wasm 2.0). In Wasm 1.0
    /// the table_idx is a single reserved 0x00 byte which decodes
    /// as uleb32(0); reading it as uleb32 is backwards-compatible.
    fn emitCallIndirect(self: *Lowerer) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const table_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(.call_indirect, type_idx, table_idx);
    }

    /// return_call_indirect: type_idx + table_idx (Wasm 3.0 tail-call
    /// proposal §3.4.10.4). Same encoding as call_indirect.
    fn emitReturnCallIndirect(self: *Lowerer) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const table_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(.return_call_indirect, type_idx, table_idx);
    }

    /// br_table: emit ZirOp.br_table with payload = count of labels.
    /// The label-vec + default ride in `out.branch_targets` (per
    /// `ZirFunc.branch_targets` slot in §4.2 / 1.1). The br_table
    /// instr's `extra` is the start index into branch_targets; payload
    /// is the count (not including default — default is at start+count).
    fn emitBrTable(self: *Lowerer) Error!void {
        // D-093 (d-1): branch_targets is a per-function pool the
        // emit reads via (start, count). In dead code the pool
        // doesn't need new entries (emit skips the .br_table
        // ZirInstr); parse the operands to stay positional, but
        // don't grow `out.branch_targets`.
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        if (self.unreachable_at_depth != null) {
            var i: u32 = 0;
            while (i < count) : (i += 1) _ = try leb128.readUleb128(u32, self.body, &self.pos);
            _ = try leb128.readUleb128(u32, self.body, &self.pos); // default
            // Already in dead region — flag stays set; no
            // markUnreachable needed.
            return;
        }
        const start: u32 = @intCast(self.out.branch_targets.items.len);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const d = try leb128.readUleb128(u32, self.body, &self.pos);
            try self.out.branch_targets.append(self.alloc, d);
        }
        const default = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.out.branch_targets.append(self.alloc, default);
        try self.emit(.br_table, count, start);
        self.markUnreachable();
    }

    /// D-093 (d-1) helper: enter the dead-code region. Records
    /// `block_stack_len` at the terminator's site so the matching
    /// `end` / `else` knows when to clear. Idempotent — repeated
    /// terminators in dead code don't update the depth.
    fn markUnreachable(self: *Lowerer) void {
        if (self.unreachable_at_depth == null) {
            self.unreachable_at_depth = @intCast(self.block_stack_len);
        }
    }

    /// Wasm 3.0 EH `try_table` opener — mirrors `openBlock` but
    /// parses the catch-vec into `Lowerer.catch_entries` between
    /// `readBlockArity` and the frame push. Each opener appends one
    /// `LandingPad` referencing the new block plus the half-open
    /// catch-entry slice. The interp unwinder (10.E-5b) consumes
    /// `ZirFunc.eh_landing_pads` keyed by the try_table label's
    /// block_idx to find the matching catch on `Trap.UncaughtException`.
    ///
    /// Wasm spec 3.0 §3.3.10.6 — try_table.
    fn openTryTable(self: *Lowerer) Error!void {
        const arity = try self.readBlockArity();
        const catches_start: u32 = @intCast(self.catch_entries.items.len);
        try self.lowerCatchVec();
        const catches_end: u32 = @intCast(self.catch_entries.items.len);

        if (self.block_stack_len == max_control_stack) return Error.ControlStackOverflow;
        if (self.unreachable_at_depth != null) {
            // Dead-code try_table — the catch entries belong to no
            // BlockInfo we'll emit; truncate them back to avoid
            // dangling LandingPad-less catch data. Per D-093 dead-
            // region discipline.
            self.catch_entries.shrinkRetainingCapacity(catches_start);
            self.block_stack[self.block_stack_len] = unreachable_block_sentinel;
            self.block_stack_len += 1;
            return;
        }

        const block_idx: u32 = @intCast(self.out.blocks.items.len);
        const start_inst: u32 = @intCast(self.out.instrs.items.len);
        try self.out.blocks.append(self.alloc, .{
            .kind = .try_table,
            .start_inst = start_inst,
            .end_inst = 0,
        });
        try self.landing_pads.append(self.alloc, .{
            .block_idx = block_idx,
            .catches_start = catches_start,
            .catches_end = catches_end,
        });
        try self.emit(.try_table, block_idx, arity);

        self.block_stack[self.block_stack_len] = block_idx;
        self.block_stack_len += 1;
    }

    /// Decode the catch vec that follows `try_table`'s blocktype
    /// into `Lowerer.catch_entries`. Spec catch encoding (Wasm 3.0
    /// EH §4.5):
    ///   0x00 tag_idx label_idx  -- catch
    ///   0x01 tag_idx label_idx  -- catch_ref
    ///   0x02 label_idx          -- catch_all
    ///   0x03 label_idx          -- catch_all_ref
    /// `tag_idx` is zeroed for the `_all` variants.
    fn lowerCatchVec(self: *Lowerer) Error!void {
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const kind_byte = self.body[self.pos];
            self.pos += 1;
            switch (kind_byte) {
                0x00, 0x01 => {
                    const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    try self.catch_entries.append(self.alloc, .{
                        .kind = if (kind_byte == 0x00) .catch_ else .catch_ref,
                        .tag_idx = tag_idx,
                        .label_idx = label_idx,
                    });
                },
                0x02, 0x03 => {
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    try self.catch_entries.append(self.alloc, .{
                        .kind = if (kind_byte == 0x02) .catch_all else .catch_all_ref,
                        .tag_idx = 0,
                        .label_idx = label_idx,
                    });
                },
                else => return Error.BadBlockType,
            }
        }
    }

    fn openBlock(self: *Lowerer, kind: BlockKind, op: ZirOp) Error!void {
        const arity = try self.readBlockArity();
        if (self.block_stack_len == max_control_stack) return Error.ControlStackOverflow;

        // D-093 (d-1): block opened inside the dead region —
        // bookkeep depth via the sentinel, skip BlockInfo /
        // ZirInstr allocation. The matching `end` (closeBlock
        // detects the sentinel) just pops.
        if (self.unreachable_at_depth != null) {
            self.block_stack[self.block_stack_len] = unreachable_block_sentinel;
            self.block_stack_len += 1;
            return;
        }

        const block_idx: u32 = @intCast(self.out.blocks.items.len);
        const start_inst: u32 = @intCast(self.out.instrs.items.len);
        try self.out.blocks.append(self.alloc, .{
            .kind = kind,
            .start_inst = start_inst,
            .end_inst = 0,
        });
        try self.emit(op, block_idx, arity);

        self.block_stack[self.block_stack_len] = block_idx;
        self.block_stack_len += 1;
    }

    /// Decode a Wasm blocktype and return its arity (count of result
    /// types the block pushes back at end). Wasm 1.0 forms (single
    /// byte 0x40 / 0x7F..0x7C) yield 0 or 1. Wasm 2.0 multivalue
    /// (s33 typeidx ≥ 0) yields the typeidx'd FuncType's results
    /// length. D-035 chunk-d035-a lifts the previous `params.len !=
    /// 0` rejection — multi-param + multi-result blocks now flow
    /// through. The `arity` slot still communicates only the result
    /// count; param consumption + push-back is handled by the
    /// validator's stack discipline (the operand stack already
    /// carries the params at block entry — emit sees them as
    /// existing vregs).
    fn readBlockArity(self: *Lowerer) Error!u32 {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const sleb = leb128.readSleb128(i32, self.body, &self.pos) catch
            return Error.BadBlockType;
        if (sleb < 0) {
            return switch (sleb) {
                -64 => @as(u32, 0), // 0x40 empty
                // §9.9 / 9.9-f-2: -5 (0x7B) = v128 single valtype
                // (Wasm 2.0 SIMD per spec §5.3.5). §9.9 /
                // 9.9-l-1b-d093-d45 (D-118): -16/-17 = funcref/externref
                // reftype single valtypes (Wasm 2.0 §5.3.5).
                // Wasm 3.0 GC §5.3.4 — single-byte abstract reftype
                // shorthands (0x6E..0x69 = anyref/eqref/i31ref/structref/
                // arrayref/exnref) as blocktypes: 1 result, 0 params.
                // Sibling of validator.readBlockType's GC arms (10.G c144).
                -1, -2, -3, -4, -5, -16, -17, -18, -19, -20, -21, -22, -23 => @as(u32, 1), // single valtype
                // function-references §5.3.4: typed-ref result via
                // `0x63 ht` / `0x64 ht`. The SLEB read consumed the
                // prefix (0x63 → -29, 0x64 → -28); consume the heap-type
                // and count it as a single result. Nullability is
                // irrelevant to arity, but readTypedRef needs it.
                -29, -28 => blk: {
                    _ = init_expr.readTypedRef(self.body, &self.pos, sleb == -29) catch
                        return Error.BadBlockType;
                    break :blk @as(u32, 1);
                },
                else => Error.BadBlockType,
            };
        }
        const idx: u32 = @intCast(sleb);
        if (idx >= self.module_types.len) return Error.BadBlockType;
        const ft = self.module_types[idx];
        // D-093 (d-6): pack param_arity into the high byte so
        // per-arch emit can compute the correct end-of-block
        // operand-stack height (= entry - params + results). The
        // Wasm 2.0 typeidx blocktype admits both params and
        // results; the single-byte negative forms have 0 params.
        // 8-bit per arity matches `Label.merge_top_vregs_cap`.
        const params: u32 = @intCast(ft.params.len);
        const results: u32 = @intCast(ft.results.len);
        if (params > 0xFF or results > 0xFF) return Error.BadBlockType;
        return (params << 8) | results;
    }

    fn closeBlock(self: *Lowerer) Error!void {
        self.block_stack_len -= 1;
        const block_idx = self.block_stack[self.block_stack_len];

        // D-093 (d-1): sentinel marks a block opened entirely
        // inside dead code — pop + return, no ZirInstr / no
        // out.blocks update. The unreachable flag itself stays
        // set (we're still inside the outer dead region).
        if (block_idx == unreachable_block_sentinel) return;

        // If popping this (live) block crosses the depth where
        // the unreachable region started, clear the flag NOW so
        // the `.end` ZirInstr below emits cleanly. The block
        // that "started the unreachable region" is the one that
        // contained the br/return/unreachable; its end is part
        // of the reachable structure.
        if (self.unreachable_at_depth) |d| {
            if (self.block_stack_len < d) {
                self.unreachable_at_depth = null;
            }
        }

        const end_inst: u32 = @intCast(self.out.instrs.items.len);
        try self.emit(.end, block_idx, 0);
        self.out.blocks.items[block_idx].end_inst = end_inst;
    }

    fn emitElse(self: *Lowerer) Error!void {
        if (self.block_stack_len == 0) return Error.UnexpectedOpcode;
        const block_idx = self.block_stack[self.block_stack_len - 1];

        // D-093 (d-1): else of a dead-code if — stays dead.
        if (block_idx == unreachable_block_sentinel) return;

        // If the then-arm's br/return/unreachable made us
        // unreachable AT THIS if-block's depth, the else-arm is
        // reachable independent of the then-arm; clear the flag.
        // Deeper unreachable depths (from nested blocks inside
        // the then-arm) were already cleared at their matching
        // ends per closeBlock's check.
        if (self.unreachable_at_depth) |d| {
            if (self.block_stack_len == d) {
                self.unreachable_at_depth = null;
            }
        }

        const else_pc: u32 = @intCast(self.out.instrs.items.len);
        self.out.blocks.items[block_idx].kind = .else_open;
        self.out.blocks.items[block_idx].else_inst = else_pc;
        try self.emit(.@"else", block_idx, 0);
    }
};
