// FILE-SIZE-EXEMPT: ZIR container-type identity catalog (§P13); ZirOp data already lives in zir_ops.zig, remaining carve-outs are N3-shallow (investigated 2026-08-12, per ADR-0099)
//! ZIR (Zwasm Intermediate Representation) — container types only.
//!
//! Phase 1 / task 1.1 declares the **type identities** required by
//! ROADMAP §4.2's `ZirFunc` pseudocode. Per ROADMAP §P13 ("type
//! up-front, slots over flags") every `?T` analysis / regalloc /
//! optimisation slot is reserved day 1; later phases populate the
//! fields without touching the struct shape (the v1 "W54" redesign
//! lesson: retrofitting analysis slots onto a live IR struct churns
//! every downstream pass).
//!
//! `ZirOp` itself is an open enum here; task 1.2 declares the full
//! Wasm 3.0 + JIT pseudo-op catalogue per ROADMAP §4.2.
//!
//! Zone 1 (`src/ir/`) — may import Zone 0 only. No upward imports.

const std = @import("std");

const Allocator = std.mem.Allocator;

const trace = @import("../diagnostic/trace.zig");

/// Implementation cap on control-stack / block-nesting depth. The Wasm
/// spec sets no limit; this is zwasm's structural ceiling, the single
/// source of truth for BOTH the validator's `max_control_stack` (the
/// real gate, `validator.zig`) AND the IR verifier's branch-target
/// sanity ceiling (`verifier.zig`). They MUST stay equal — they drifted
/// (validator 1024 vs verifier 256), so a validator-accepted standard-Go
/// function with depth in [256,1024) was wrongly rejected by the verifier
/// (D-241, go_* realworld fixtures). Sourcing both here prevents recurrence.
/// Raised 1024 → 4096 (ADR-0165 / D-287): LLVM-lowered big C switches
/// (shootout/switch.wasm, depth 2568) are valid wasm wasmtime accepts; the cap
/// is bounded by the validator's host-stack `control_buf` — 4096 keeps the
/// Validator struct ~280 KB, comfortable on Windows' 1 MB thread stack (see ADR).
pub const max_control_stack: usize = 4096;

/// ADR-0123 (Accepted 2026-05-28 cycle 90) D1 — typed-funcref
/// representation. ValType is a tagged union over the spec's
/// value-type space: numeric heads (i32/i64/f32/f64/v128) carry
/// no payload; the single `ref` head carries a `RefType` with
/// nullability + heap-type kind (abstract head like `func` /
/// `extern` / `any` / etc., or a concrete type-section index for
/// `(ref null? $typeidx)`).
///
/// Wasm 3.0 §5.3 binary mapping (preserved by-byte for the legacy
/// abstract refs):
///   0x7F i32        0x7E i64        0x7D f32        0x7C f64
///   0x7B v128
///   0x70 funcref    = ValType.funcref    = .{ .ref = .abs(.func, true) }
///   0x6F externref  = ValType.externref  = .{ .ref = .abs(.extern_, true) }
///   0x6E anyref     = ValType.anyref     = .{ .ref = .abs(.any, true) }
///   0x6D eqref      = ValType.eqref      = .{ .ref = .abs(.eq, true) }
///   0x6C i31ref     = ValType.i31ref     = .{ .ref = .abs(.i31, true) }
///   0x6B structref  = ValType.structref  = .{ .ref = .abs(.struct_, true) }
///   0x6A arrayref   = ValType.arrayref   = .{ .ref = .abs(.array, true) }
///   0x69 exnref     = ValType.exnref     = .{ .ref = .abs(.exn, true) }
///   0x63 (ref null ht)  = .{ .ref = .{ .nullable = true,  .heap_type = ht } }
///   0x64 (ref ht)       = .{ .ref = .{ .nullable = false, .heap_type = ht } }
///
/// The pub-const aliases below preserve value-construction
/// ergonomics for the 7 abstract heads (`const t: ValType =
/// .funcref;` still works via inferred-tag → const resolution).
/// Switch patterns must use the new `.ref => |r| switch
/// (r.heap_type) ...` nested form per ADR-0123 D2 + Zig's
/// `require_exhaustive_enum_switch` lint.
pub const ValType = union(enum) {
    i32,
    i64,
    f32,
    f64,
    v128,
    ref: RefType,

    pub const funcref: ValType = .{ .ref = RefType.abs(.func, true) };
    pub const externref: ValType = .{ .ref = RefType.abs(.extern_, true) };
    pub const anyref: ValType = .{ .ref = RefType.abs(.any, true) };
    pub const eqref: ValType = .{ .ref = RefType.abs(.eq, true) };
    pub const i31ref: ValType = .{ .ref = RefType.abs(.i31, true) };
    pub const structref: ValType = .{ .ref = RefType.abs(.struct_, true) };
    pub const arrayref: ValType = .{ .ref = RefType.abs(.array, true) };
    /// Wasm 3.0 EH §5.3.1 — `exnref` = `(ref null exn)`. The `.exn`
    /// abstract head already exists (used by tag heap-types); this
    /// alias + the `readValType` 0x69 arm let the bare byte appear as
    /// a value type (try_table catch_ref result tuples). 10.E.
    pub const exnref: ValType = .{ .ref = RefType.abs(.exn, true) };

    /// Wasm 3.0 §5.3.4 abbreviated bottom reftypes — the single-byte
    /// `(ref null <bottom-head>)` forms: `nullref` (0x71 none),
    /// `nullexternref` (0x72 noextern), `nullfuncref` (0x73 nofunc),
    /// `nullexnref` (0x74 noexn). Valid as struct/array field + value
    /// types (wasmtime gc/issue-13152; ADR-0192).
    pub const nullref: ValType = .{ .ref = RefType.abs(.none, true) };
    pub const nullexternref: ValType = .{ .ref = RefType.abs(.noextern, true) };
    pub const nullfuncref: ValType = .{ .ref = RefType.abs(.nofunc, true) };
    pub const nullexnref: ValType = .{ .ref = RefType.abs(.noexn, true) };

    /// Reverse-map a RefType to a legacy abstract-ref ValType. Used
    /// by post-migration code paths that still want the byte-pinned
    /// abstract reference (e.g. binary writer). Returns null when
    /// the RefType is concrete or non-nullable (which the legacy
    /// enum couldn't express).
    pub fn legacyAbsRef(self: ValType) ?AbstractHeapType {
        if (self != .ref) return null;
        if (!self.ref.nullable) return null;
        return switch (self.ref.heap_type) {
            .abstract => |a| a,
            .concrete => null,
        };
    }

    /// True if `self` is `.funcref` (i.e. `(ref null func)`).
    pub fn isFuncref(self: ValType) bool {
        return self == .ref and self.ref.nullable and
            self.ref.heap_type == .abstract and
            self.ref.heap_type.abstract == .func;
    }

    /// True if `self` is `.externref` (i.e. `(ref null extern)`).
    pub fn isExternref(self: ValType) bool {
        return self == .ref and self.ref.nullable and
            self.ref.heap_type == .abstract and
            self.ref.heap_type.abstract == .extern_;
    }

    /// True if `self` is the abstract heap `ht` (any nullability,
    /// abstract head only — concrete typed refs return false).
    pub fn isAbsHead(self: ValType, ht: AbstractHeapType) bool {
        if (self != .ref) return false;
        if (self.ref.heap_type != .abstract) return false;
        return self.ref.heap_type.abstract == ht;
    }

    pub fn isStructRef(self: ValType) bool {
        return self.isAbsHead(.struct_);
    }
    pub fn isArrayRef(self: ValType) bool {
        return self.isAbsHead(.array);
    }
    pub fn isAnyRef(self: ValType) bool {
        return self.isAbsHead(.any);
    }
    pub fn isEqRef(self: ValType) bool {
        return self.isAbsHead(.eq);
    }
    pub fn isI31Ref(self: ValType) bool {
        return self.isAbsHead(.i31);
    }

    /// True for any ref-shaped ValType (abstract or concrete,
    /// nullable or not).
    pub fn isRef(self: ValType) bool {
        return self == .ref;
    }

    /// Map the ValType to its Wasm 3.0 binary spec byte (§5.3).
    /// For concrete typed refs (`(ref null? $idx)`) returns the
    /// abstract-head byte for spec compatibility; callers needing
    /// the multi-byte 0x63/0x64 prefix consult `RefType` directly.
    /// This helper replaces the pre-ADR-0123 `@intFromEnum` pattern
    /// where the ValType enum tag value equalled the spec byte.
    pub fn specByte(self: ValType) u8 {
        return switch (self) {
            .i32 => 0x7F,
            .i64 => 0x7E,
            .f32 => 0x7D,
            .f64 => 0x7C,
            .v128 => 0x7B,
            .ref => |r| switch (r.heap_type) {
                .abstract => |a| switch (a) {
                    .func => 0x70,
                    .extern_ => 0x6F,
                    .any => 0x6E,
                    .eq => 0x6D,
                    .i31 => 0x6C,
                    .struct_ => 0x6B,
                    .array => 0x6A,
                    .exn => 0x69,
                    .none => 0x71,
                    .noextern => 0x72,
                    .nofunc => 0x73,
                    .noexn => 0x74,
                },
                // Concrete typed ref: return the corresponding
                // abstract head's byte. Callers needing the full
                // 0x63/0x64 multi-byte form handle that separately.
                .concrete => 0x70,
            },
        };
    }

    /// Human-readable value-type name for diagnostics (Wasm 3.0 text
    /// keywords). Nullable abstract refs use the shorthand keywords
    /// (`funcref`/`anyref`/…); non-null abstract refs use `(ref head)`;
    /// concrete typed refs collapse to `(ref $type)` since the index
    /// needs runtime formatting a `[]const u8` can't carry.
    pub fn name(self: ValType) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .i64 => "i64",
            .f32 => "f32",
            .f64 => "f64",
            .v128 => "v128",
            .ref => |r| switch (r.heap_type) {
                .concrete => "(ref $type)",
                .abstract => |a| if (r.nullable) switch (a) {
                    .func => "funcref",
                    .extern_ => "externref",
                    .any => "anyref",
                    .eq => "eqref",
                    .i31 => "i31ref",
                    .struct_ => "structref",
                    .array => "arrayref",
                    .none => "nullref",
                    .noextern => "nullexternref",
                    .nofunc => "nullfuncref",
                    .exn => "exnref",
                    .noexn => "nullexnref",
                } else switch (a) {
                    .func => "(ref func)",
                    .extern_ => "(ref extern)",
                    .any => "(ref any)",
                    .eq => "(ref eq)",
                    .i31 => "(ref i31)",
                    .struct_ => "(ref struct)",
                    .array => "(ref array)",
                    .none => "(ref none)",
                    .noextern => "(ref noextern)",
                    .nofunc => "(ref nofunc)",
                    .exn => "(ref exn)",
                    .noexn => "(ref noexn)",
                },
            },
        };
    }

    /// Deep structural equality. Zig auto-derives `==` for unions
    /// only when the inner types support it; `RefType` contains a
    /// `HeapType` union which the auto-derive can't traverse, so
    /// we provide an explicit comparison.
    pub fn eql(a: ValType, b: ValType) bool {
        const TagT = @typeInfo(ValType).@"union".tag_type.?;
        const ta: TagT = a;
        const tb: TagT = b;
        if (ta != tb) return false;
        return switch (a) {
            .i32, .i64, .f32, .f64, .v128 => true,
            .ref => |ra| blk: {
                const rb = b.ref;
                if (ra.nullable != rb.nullable) break :blk false;
                const hta: @typeInfo(HeapType).@"union".tag_type.? = ra.heap_type;
                const htb: @typeInfo(HeapType).@"union".tag_type.? = rb.heap_type;
                if (hta != htb) break :blk false;
                break :blk switch (ra.heap_type) {
                    .abstract => |a_abs| a_abs == rb.heap_type.abstract,
                    .concrete => |a_idx| a_idx == rb.heap_type.concrete,
                };
            },
        };
    }
};

// ADR-0123 (Accepted 2026-05-28) Cycle 1 — typed-funcref
// representation substrate. New types ride alongside the existing
// `ValType` enum; Cycle 2 of the `10.R-valtype-widen` bundle
// will pivot `ValType` to `union(enum)` and migrate the seven
// abstract-ref tags to `.ref = ValType.absRef(...)` form. Until
// that cycle lands, these types are referenced by the parser
// (`readValType`) and validator type-stack but not yet by the
// IR / interp / engine layers.

/// Wasm 3.0 reference-types abstract heap-type tags. Spec
/// §5.3.5 byte encodings (negative-prefix LEB128):
/// `func` (0x70), `extern` (0x6F), `any` (0x6E), `eq` (0x6D),
/// `i31` (0x6C), `struct` (0x6B), `array` (0x6A),
/// `none` (0x71), `noextern` (0x72), `nofunc` (0x73),
/// `exn` (0x69), `noexn` (0x74).
pub const AbstractHeapType = enum(u8) {
    func,
    extern_,
    any,
    eq,
    i31,
    struct_,
    array,
    none,
    noextern,
    nofunc,
    exn,
    noexn,
};

/// Heap type: either an abstract head (`func` / `extern` / ...)
/// or a concrete typed reference `(ref null? $typeidx)` carrying
/// a type-section index. ADR-0123 D1+D5.
pub const HeapType = union(enum) {
    abstract: AbstractHeapType,
    concrete: u32, // type section index
};

/// Reference type: nullability flag + heap type. ADR-0123 D1.
/// Wasm 3.0 §5.3.4 binary encoding: `0x63` = `(ref null ht)`,
/// `0x64` = `(ref ht)`, plus the legacy single-byte abstract
/// encodings (0x70 funcref = `(ref null func)`, etc.).
pub const RefType = struct {
    nullable: bool,
    heap_type: HeapType,

    /// Convenience: abstract reference at the given nullability.
    pub fn abs(ht: AbstractHeapType, nullable: bool) RefType {
        return .{ .nullable = nullable, .heap_type = .{ .abstract = ht } };
    }

    /// Convenience: concrete typed reference at the given
    /// nullability + type-section index.
    pub fn conc(idx: u32, nullable: bool) RefType {
        return .{ .nullable = nullable, .heap_type = .{ .concrete = idx } };
    }
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// Module table entry (Wasm 2.0 §9.2 / 2.3 chunk 5c). Carries
/// only the static metadata the validator needs; the runtime
/// counterpart `TableInstance` (in `runtime/runtime.zig`) holds the
/// actual reference values.
pub const TableEntry = struct {
    /// Address-space width discriminator (memory64 proposal's table
    /// extension, "table64"). `.i32` for legacy tables; `.i64` for an
    /// `i64`-indexed table (limits-flag bit 0x04, mirroring memory64).
    /// table.get/set/grow/size/fill/copy/init + call_indirect index this
    /// table at this width.
    idx_type: IdxType = .i32,
    elem_type: ValType,
    // u64 limits: a table64 (idx_type == .i64) may declare min/max up to
    // 2^64-1 (spec §5.3.5). i32 tables keep min/max ≤ u32 (decoder-enforced).
    min: u64,
    max: ?u64 = null,
    /// 10.G cycle 166 — Wasm 3.0 table-with-explicit-init-expr
    /// (`0x40 0x00 reftype limits constexpr`): raw const-expr bytes for
    /// the initial element value. Empty = default (null_ref) fill.
    init_expr: []const u8 = &.{},
};

/// Index-width discriminator shared by the memory64 + table64 proposals:
/// the address/index space is either 32-bit (legacy) or 64-bit. Encoded
/// in the limits-flag byte (bit 0x04).
pub const IdxType = enum(u1) { i32 = 0, i64 = 1 };

pub const BlockKind = enum(u8) {
    block,
    loop,
    if_then,
    else_open,
    /// Wasm 3.0 exception-handling proposal (§3.3.10.6 / §4.5):
    /// `try_table` introduces a control frame that establishes
    /// exception handlers via its catch vec. Label types follow
    /// the `block` rule (end_type) — branches to the try_table
    /// label arrive on `end`, not on `throw` (catch dispatch
    /// uses the catch's own label_idx). Foundation entry for
    /// 10.E-N opcode/validator/interp wiring.
    try_table,
};

pub const BlockInfo = struct {
    kind: BlockKind,
    start_inst: u32,
    end_inst: u32,
    /// Position of the matching `else` opcode for `if` frames that
    /// have one. The interp routes `if cond=0` to `else_inst + 1`
    /// or, when `null`, to `end_inst + 1`. Set by the lowerer on
    /// `else` emission; remains `null` for plain blocks / loops /
    /// if-without-else.
    else_inst: ?u32 = null,
    /// Block result arity (count of result types). Set by the lowerer
    /// at block open (= `readBlockArity() & 0xFF`). D-328 needs it at a
    /// catch-target block's `.end` to mint the right number of result
    /// vregs (the JIT regalloc otherwise has nothing to size them from).
    result_arity: u8 = 0,
    /// D-328: true when some `try_table` catch clause branches to THIS
    /// block (resolved from the catch's `label_idx` by the lowerer). The
    /// caught values arrive via the unwinder, not a ZIR op, so both the
    /// liveness pass and the JIT emit MUST mint `result_arity` fresh
    /// vregs at this block's `.end` (in lockstep) — else a multi-value
    /// catch result collides to one slot. Only `.block`-kind targets are
    /// marked (loops branch to their start, not `.end`).
    is_catch_target: bool = false,
};

// ZirOp catalog extracted to `zir_ops.zig` per ADR-0087 (pure
// tag enum, 684 LOC). Re-exported here so callers reach `zir.ZirOp`
// unchanged.
const zir_ops = @import("zir_ops.zig");
pub const ZirOp = zir_ops.ZirOp;

pub const ZirInstr = struct {
    op: ZirOp,
    payload: u64 = 0,
    extra: u32 = 0,
};

/// Per Wasm 3.0 §5.4.6 / ADR-0111 D3, memarg-bearing ops
/// (load*/store*/load_lane/store_lane) carry alignment + an
/// explicit memidx through `ZirInstr.extra`. Encoded as a
/// packed-u32 so the existing `extra: u32` field stays
/// byte-identical for non-memarg ops. `_pad` is reserved zero
/// (future memory64-related extensions: page-size hint, etc.).
pub const MemArgExtra = packed struct(u32) {
    /// log2 of byte alignment (Wasm spec §5.4.6 memarg align;
    /// always ≤ natural alignment of the op — i32: ≤ 2 /
    /// i64: ≤ 3 / v128: ≤ 4). 5 bits permits 0..31, well
    /// beyond any Wasm-permitted op.
    align_pow2: u5 = 0,
    /// Memory index (Wasm 3.0 multi-memory). 0 for legacy
    /// single-memory modules; 1..255 for multi-memory enabled
    /// modules (parser+validator support at 10.M-3; runtime
    /// instantiate still rejects > 1 until codegen wires
    /// per-memidx access at 10.M-4).
    memidx: u8 = 0,
    _pad: u19 = 0,

    pub fn pack(align_pow2: u5, memidx: u8) u32 {
        const m: MemArgExtra = .{ .align_pow2 = align_pow2, .memidx = memidx };
        return @bitCast(m);
    }

    pub fn unpack(extra: u32) MemArgExtra {
        return @bitCast(extra);
    }
};

/// Returns true if `op` is a SIMD-128 ZirOp (operates on or
/// produces v128 vregs). Per ADR-0041 §"Decision" / 1
/// (shape-as-variant), the predicate uses tag-name prefix
/// matching: any op whose textual name starts with `v128.`,
/// `i8x16.`, `i16x8.`, `i32x4.`, `i64x2.`, `f32x4.`, or
/// `f64x2.` is a SIMD op.
///
/// Used by `regalloc.compute()` to populate
/// `Allocation.shape_tags` per ADR-0041 §"Decision" / 2 +
/// §14 (single_slot_dual_meaning). Emit pass queries the
/// resulting shape tag to select 16-byte vs 8-byte spill
/// stride and Q vs D/S register view.
pub fn isSimdZirOp(op: ZirOp) bool {
    const name = @tagName(op);
    return std.mem.startsWith(u8, name, "v128.") or
        std.mem.startsWith(u8, name, "i8x16.") or
        std.mem.startsWith(u8, name, "i16x8.") or
        std.mem.startsWith(u8, name, "i32x4.") or
        std.mem.startsWith(u8, name, "i64x2.") or
        std.mem.startsWith(u8, name, "f32x4.") or
        std.mem.startsWith(u8, name, "f64x2.");
}

// Forward-declared "slot" types — identities reserved day 1 per
// P13 / W54 lesson. Fields land in the populating phase
// (commented at each declaration). Adding fields later is OK;
// renaming or removing the type would be a §4.2 deviation
// requiring an ADR (§18).

/// Phase 5+: per-function liveness analysis result. Populated
/// by `src/ir/liveness.zig`. Per-vreg live ranges; vreg ids are
/// assigned in def order (0, 1, 2 …) as the analysis walks the
/// instr stream simulating the operand stack. Slices borrowed —
/// caller owns lifetime, mirrors `LoopInfo`.
pub const Liveness = struct {
    /// One entry per defined vreg. `ranges[v].def_pc` is the
    /// instr index that pushed the value; `last_use_pc` is the
    /// final consuming instr (pop-side or function-level end).
    ranges: []const LiveRange = &.{},

    /// D-596 — per-pc snapshot of the simulated operand stack, taken BEFORE
    /// instr `pc`. Populated only when `ZWASM_DEBUG=liveverify` is on; the
    /// emit compares it against its own `pushed_vregs` so a divergence
    /// surfaces at the instruction that caused it instead of as a wrong
    /// number downstream. `stack_digest` is FNV-1a over the vreg ids: the
    /// class is a vreg-IDENTITY drift, and three of its four known instances
    /// are depth-neutral. Empty (and skipped) on every other build.
    stack_depth: []const u32 = &.{},
    stack_digest: []const u64 = &.{},
};

pub const LiveRange = struct {
    def_pc: u32,
    last_use_pc: u32,
};

/// Phase 5+: loop nesting + branch target resolution. Populated
/// by `src/ir/loop_info.zig` from `ZirFunc.blocks` after the
/// lowerer fills the block table. Slices borrowed; lifetime is
/// the caller's (typically the per-instance arena, or
/// `loop_info.deinit` on free).
pub const LoopInfo = struct {
    /// Instruction indices of `loop` opcodes in this function.
    /// Parallel to `loop_end`. Empty for non-looping functions.
    loop_headers: []const u32 = &.{},
    /// Instruction indices of the matching `end` for each loop in
    /// `loop_headers`. Same length as `loop_headers`.
    loop_end: []const u32 = &.{},
};

/// Phase 5+: hoisted-constant pool seed. Populated by
/// `src/ir/const_prop.zig`. Each entry records a peephole-foldable
/// binop site: the two `i*.const` def pcs that supplied the
/// operands, the binop pc itself, and the constant-evaluated
/// result encoded as a `(lo, hi)` `u32` pair (`result_lo` carries
/// 32-bit results; `result_hi` carries the upper 32 bits for i64).
/// Slice borrowed; lifetime is the caller's, mirrors LoopInfo /
/// Liveness.
pub const ConstantPool = struct {
    folds: []const ConstantFold = &.{},
};

pub const ConstantFold = struct {
    def_pc_a: u32,
    def_pc_b: u32,
    op_pc: u32,
    result_lo: u32,
    result_hi: u32 = 0,
};

/// Per-vreg register-class identity. The IR carries the class
/// so the regalloc IR shape is per-arch-independent (the W54
/// post-mortem identified per-arch IR drift as the v1 D117
/// dual-entry-self-call workaround's root cause). Per-class
/// invariants (width, spill alignment, special-cache discipline)
/// live in `src/jit/reg_class.zig` (Zone 2); the per-arch
/// physical register inventory lives in
/// `src/jit_<arch>/abi.zig` (Phase 7.2). This 3-way split is the
/// "split class identity from per-arch register inventory" rule
/// made structural.
///
/// The three `*_special` variants are the W54-class day-1 slot
/// fill (ROADMAP §4.2 + §9.7 / 7.0) — they reserve regalloc IR
/// slots that the v1 design discovered late and patched with
/// per-callsite workarounds:
///   - `inst_ptr_special`  — the `inst_ptr` cache that v1's
///     D117 workaround proved must be expressible in regalloc
///     IR, not the per-arch emit pass.
///   - `vm_ptr_special`    — the runtime base pointer.
///   - `simd_base_special` — the SIMD-lane base pointer.
pub const RegClass = enum(u8) {
    gpr,
    fpr,
    simd,
    inst_ptr_special,
    vm_ptr_special,
    simd_base_special,
    _,
};

/// Phase 7+: spilled-vreg stack slot record.
pub const SpillSlot = struct {};

/// Phase 7+: special-purpose register cache layout (inst_ptr /
/// vm_ptr / simd_base, per ROADMAP §4.2 RegClass.*_special).
pub const CacheLayout = struct {};

/// Phase 9+: SIMD lane-routing metadata.
pub const LaneRouting = struct {};

/// Phase 10+: GC-managed reference root map.
pub const GcRootMap = struct {};

/// Wasm 3.0 EH §4.5 — catch clause kind discriminator. Encoded in the
/// `try_table` instruction's catch-vec; preserved on `CatchEntry`
/// for the interp unwinder to decide payload shape at catch time.
///   - `catch_` / `catch_ref`: match exception by `tag_idx` equality.
///     `_ref` variants additionally push the originating `exnref` on
///     entry to the catch label.
///   - `catch_all` / `catch_all_ref`: match any exception (no
///     `tag_idx`). `_ref` pushes the `exnref`.
pub const CatchKind = enum(u8) {
    catch_ = 0x00,
    catch_ref = 0x01,
    catch_all = 0x02,
    catch_all_ref = 0x03,
};

/// One catch clause inside a `try_table`'s catch-vec. Stored flat in
/// `ZirFunc.eh_catch_entries`; each `LandingPad` references a
/// `[catches_start, catches_end)` slice. `tag_idx` is unused (zeroed)
/// for the `catch_all` / `catch_all_ref` kinds.
///
/// Wasm spec 3.0 §4.5 — try_table catch encoding.
pub const CatchEntry = struct {
    kind: CatchKind,
    tag_idx: u32,
    label_idx: u32,
};

/// Phase 10+: exception-handling landing pad. One per `try_table`
/// instruction in the function body. `block_idx` keys into
/// `ZirFunc.blocks` (the `.try_table` BlockInfo); the interp
/// unwinder uses this to associate a try_table label on the
/// label stack with its catch-vec when `Trap.UncaughtException`
/// propagates. `catches_start` / `catches_end` form a half-open
/// slice into `ZirFunc.eh_catch_entries`.
///
/// Wasm spec 3.0 §3.3.10.6 — try_table catch metadata.
pub const LandingPad = struct {
    block_idx: u32,
    catches_start: u32,
    catches_end: u32,
};

/// Phase 10+: tail-call site record.
pub const TailCallSite = struct {};

/// Phase 8+: hoisted constant placement record (per ADR-0031).
/// Populated by `src/ir/hoist/pass.zig` when a `*.const` opcode
/// inside a loop is rewritten via the local-set/local-get
/// pattern: `*.const K; local.set N` is inserted before the loop
/// header; the in-loop `*.const K` becomes `local.get N`.
/// `original_pc` is the const's PC in the pre-hoist instr stream;
/// `prologue_const_pc` and `prologue_set_pc` are the post-hoist
/// PCs of the inserted prologue pair; `in_loop_pc` is the
/// post-hoist PC of the replacement `local.get`. `local_idx` is
/// the absolute Wasm-space local index allocated for this hoist
/// (= original `num_params + locals.len + synthetic_offset`).
/// `op` + `payload` + `extra` mirror the original ZirInstr fields.
pub const HoistedConst = struct {
    original_pc: u32,
    prologue_const_pc: u32,
    prologue_set_pc: u32,
    in_loop_pc: u32,
    local_idx: u32,
    op: ZirOp,
    payload: u64,
    extra: u32,
};

/// Phase 15+: bounds-check elision proof.
pub const ElisionRecord = struct {};

/// Phase 8+ (§9.8b / 8b.1; ADR-0035): post-regalloc slot-
/// aliasing coalescer record. Emit pass queries
/// `func.coalesced_movs` for each MOV-shaped emission site
/// and skips emission when a record's `instr_pc` matches
/// the current dispatch index. Side-table metadata only —
/// neither ZIR nor `regalloc.Allocation` is mutated.
pub const CoalesceRecord = struct {
    /// PC of the ZIR instr in `func.instrs.items` whose
    /// emit-time MOV is redundant (src_slot == dst_slot
    /// AND dst is consumed via that slot OR is dead before
    /// next write).
    instr_pc: u32,
    /// The slot id involved (informational; both src and
    /// dst share this slot — that's the alias).
    slot: u16,
    /// Detection class. Open enum (`_` extension) so
    /// future detection passes can add new reasons without
    /// breaking existing emit-side consumers.
    reason: Reason,

    pub const Reason = enum(u8) {
        /// `slots[src_vreg] == slots[dst_vreg]` AND not
        /// across a call boundary AND not at a branch
        /// target (per ADR-0035 detection algorithm).
        same_slot_alias = 0,
        _,
    };
};

/// Phase 8+: per-function per-pass diagnostic record (per
/// ADR-0033). Populated by the compile pipeline's `passExit`
/// wrapper at each pipeline stage. The `extra` field is
/// per-pass (documented at the call site to avoid the
/// `single_slot_dual_meaning.md` anti-pattern):
///   - `lower`: resulting `instrs.len`
///   - `loop_info`: 0
///   - `hoist`: synthetic locals added
///   - `liveness`: range-table length
///   - `regalloc`: high-water slot id
///   - `emit`: bytes emitted
pub const PassRecord = struct {
    pass: trace.PassId,
    applied: u32,
    skipped: u32,
    extra: u32,
};

/// Phase 8+: per-function pass-diagnostics slot (per ADR-0033).
/// Borrowed slice; lifetime mirrors `Liveness` / `LoopInfo`.
/// Populated when `trace.enabled == true`; otherwise the slot
/// stays `null` and is dead state. Freed via
/// `deinitPassDiagnostics` from the same allocator that built
/// the slice.
pub const PassDiagnostics = struct {
    entries: []const PassRecord = &.{},
};

/// Free a `PassDiagnostics`'s entries slice. No-op when the
/// slice is empty (default-initialised case).
pub fn deinitPassDiagnostics(allocator: Allocator, pd: PassDiagnostics) void {
    if (pd.entries.len != 0) allocator.free(pd.entries);
}

pub const ZirFunc = struct {
    func_idx: u32,
    sig: FuncType,
    locals: []const ValType,
    instrs: std.ArrayList(ZirInstr),
    blocks: std.ArrayList(BlockInfo),
    branch_targets: std.ArrayList(u32),

    // Phase 5+ — analysis layer.
    loop_info: ?LoopInfo = null,
    liveness: ?Liveness = null,
    constant_pool: ?ConstantPool = null,

    // Phase 7+ — JIT register allocator.
    reg_class_hints: ?[]RegClass = null,
    spill_slots: ?[]SpillSlot = null,
    inst_ptr_cache_layout: ?CacheLayout = null,
    vm_ptr_cache_layout: ?CacheLayout = null,
    simd_base_cache_layout: ?CacheLayout = null,

    // Phase 9+ — SIMD additional state.
    simd_lane_routing: ?LaneRouting = null,

    /// Phase 9+ — SIMD 16-byte literal pool (per ADR-0042). Each
    /// entry is the raw 16-byte immediate of a `v128.const` or
    /// `i8x16.shuffle` op. Indexed by the producing op's
    /// `ZirInstr.payload`. Lower-time owner: `Lowerer.simd_consts`
    /// builder; flushed to `func.simd_consts` at lower close.
    /// Caller-owned: freed by `ZirFunc.deinit`.
    simd_consts: ?[]const [16]u8 = null,

    // Phase 10+ — GC / EH / tail-call additional state.
    gc_root_map: ?GcRootMap = null,
    /// One entry per `try_table` in body order (per ADR-0114 EH design,
    /// interp-side metadata; codegen consumes the same data via
    /// `engine/codegen/shared/exception_table.zig` at JIT time).
    /// Owned slice; freed by `ZirFunc.deinit`.
    eh_landing_pads: ?[]const LandingPad = null,
    /// Flat backing store for all catch clauses across the function.
    /// `LandingPad.catches_start..catches_end` indexes into this.
    eh_catch_entries: ?[]const CatchEntry = null,
    tail_call_sites: ?[]TailCallSite = null,

    /// 10.G GC-on-JIT (D-212) — module-level GC field/element valtype
    /// tables, referenced (not owned) so the regalloc vreg-class
    /// classifier + the struct.get/array.get emit can tell whether the
    /// loaded field/element is f32/f64 (→ FP-class result) without the
    /// module type section. `gc_array_elem_valtypes[typeidx]` = the
    /// array element's spec valtype byte; `gc_struct_field_valtypes[
    /// typeidx][fieldidx]` = the struct field's spec valtype byte.
    /// Arena-allocated by `compileWasm`; lifetime spans the compile, so
    /// `ZirFunc.deinit` does NOT free them. Empty when no GC types.
    gc_array_elem_valtypes: []const u8 = &.{},
    gc_struct_field_valtypes: []const []const u8 = &.{},

    /// D-235 — module declares func subtyping (`usesTypeSubtyping`). When
    /// true, regalloc force-spills `call_indirect` operands (inclusive
    /// crossing, like `struct.new`) so they survive the in-op
    /// `jitCallIndirectResolve` trampoline call, which the subtyping emit
    /// inserts BEFORE marshalling. Default `false` keeps non-subtyping
    /// modules on the strict-crossing (byte-identical) path. Set by
    /// `compileOne`; arena lifetime n/a (scalar).
    uses_type_subtyping: bool = false,

    /// D-475 (table64) — per-table index types in the full wasm table
    /// index space (imports first, defined after; mirrors
    /// `validator_tables` in `compileWasm`). The table-op /
    /// call_indirect emitters consult this to pick 32- vs 64-bit index
    /// widths per table. Arena-allocated by `compileWasm` (referenced,
    /// not owned — same lifetime posture as `gc_array_elem_valtypes`).
    /// Empty for modules without tables; `tableIdxType` defaults
    /// out-of-range indices to `.i32` so emit-level unit tests that
    /// don't populate it keep the legacy width.
    table_idx_types: []const IdxType = &.{},

    // Phase 8+ — optimisation passes.
    hoisted_constants: ?[]HoistedConst = null,
    /// Synthetic locals appended by post-lowering passes (notably
    /// the §9.8 / 8.4 hoist pass per ADR-0031, which reserves new
    /// local indices to host hoisted-constant cache values).
    /// Indexed at `local_idx >= func.locals.len`. Caller-owned;
    /// freed by the pass that allocates it (see
    /// `src/ir/hoist/pass.zig:deinitSynthetic`).
    synthetic_locals: ?[]ValType = null,
    bounds_check_elision_map: ?[]ElisionRecord = null,
    coalesced_movs: ?[]CoalesceRecord = null,

    /// Phase 8+ — per-function per-pass diagnostic record
    /// (per ADR-0033 + §9.8a / 8a.1). Populated only when
    /// `trace.enabled == true`; otherwise stays `null` and
    /// folds out as dead state. Freed via
    /// `deinitPassDiagnostics`.
    pass_diagnostics: ?PassDiagnostics = null,

    pub fn init(func_idx: u32, sig: FuncType, locals: []const ValType) ZirFunc {
        return .{
            .func_idx = func_idx,
            .sig = sig,
            .locals = locals,
            .instrs = .empty,
            .blocks = .empty,
            .branch_targets = .empty,
        };
    }

    pub fn deinit(self: *ZirFunc, alloc: Allocator) void {
        self.instrs.deinit(alloc);
        self.blocks.deinit(alloc);
        self.branch_targets.deinit(alloc);
        if (self.simd_consts) |sc| alloc.free(sc);
        if (self.eh_landing_pads) |lps| alloc.free(lps);
        if (self.eh_catch_entries) |ces| alloc.free(ces);
    }

    /// Total declared-locals count = original `func.locals.len`
    /// plus any `synthetic_locals` appended by post-lowering
    /// passes. Use this anywhere `func.locals.len` was the
    /// authoritative count for stack-frame sizing or local-index
    /// validation.
    pub fn totalLocalCount(self: *const ZirFunc) u32 {
        const base: u32 = @intCast(self.locals.len);
        const extra: u32 = if (self.synthetic_locals) |s| @intCast(s.len) else 0;
        return base + extra;
    }

    /// Look up a local's `ValType` by its absolute Wasm-space
    /// local index (parameter 0..num_params-1, then declared
    /// locals num_params..num_params+totalLocalCount-1).
    /// Caller has already validated the index range.
    pub fn localValType(self: *const ZirFunc, local_idx: u32) ValType {
        const num_params: u32 = @intCast(self.sig.params.len);
        if (local_idx < num_params) return self.sig.params[local_idx];
        const decl_idx: u32 = local_idx - num_params;
        const orig_len: u32 = @intCast(self.locals.len);
        if (decl_idx < orig_len) return self.locals[@intCast(decl_idx)];
        return self.synthetic_locals.?[@intCast(decl_idx - orig_len)];
    }

    /// D-475 (table64) — index type of table `tableidx`, defaulting to
    /// `.i32` when the slice is unpopulated (emit-level unit tests) or
    /// the index is out of range (validator pre-rejects those).
    pub fn tableIdxType(self: *const ZirFunc, tableidx: u32) IdxType {
        if (tableidx >= self.table_idx_types.len) return .i32;
        return self.table_idx_types[tableidx];
    }

    /// 10.G GC-on-JIT (D-212) — the array element's spec valtype byte
    /// for `array.get`/`array.set` on `typeidx`, or 0 when unknown
    /// (non-array typeidx / table absent). 0x7D = f32, 0x7C = f64.
    pub fn arrayElemValType(self: *const ZirFunc, typeidx: u32) u8 {
        if (typeidx >= self.gc_array_elem_valtypes.len) return 0;
        return self.gc_array_elem_valtypes[typeidx];
    }

    /// 10.G GC-on-JIT (D-212) — the struct field's spec valtype byte for
    /// `struct.get`/`struct.set` of `fieldidx` on `typeidx`, or 0 when
    /// unknown. 0x7D = f32, 0x7C = f64.
    pub fn structFieldValType(self: *const ZirFunc, typeidx: u32, fieldidx: u32) u8 {
        if (typeidx >= self.gc_struct_field_valtypes.len) return 0;
        const fields = self.gc_struct_field_valtypes[typeidx];
        if (fieldidx >= fields.len) return 0;
        return fields[fieldidx];
    }

    /// D-460 — a GC aggregate field/element slot is 16 bytes for v128
    /// (0x7B), else the uniform 8 bytes (ADR-0116 §3a). Mirrors
    /// `feature/gc/type_info.zig fieldSlotSize` so JIT-computed offsets match
    /// the materialised heap layout.
    pub fn gcSlotBytes(valtype_byte: u8) u32 {
        return if (valtype_byte == 0x7B) 16 else 8;
    }

    /// D-460 — byte offset of struct field `fieldidx` within the heap payload
    /// (running sum of prior field slot sizes; v128=16, else 8). Equals the
    /// legacy `fieldidx*8` for an all-scalar struct, and is correct once a
    /// preceding field is v128.
    pub fn structFieldByteOffset(self: *const ZirFunc, typeidx: u32, fieldidx: u32) u32 {
        if (typeidx >= self.gc_struct_field_valtypes.len) return fieldidx * 8;
        const fields = self.gc_struct_field_valtypes[typeidx];
        var off: u32 = 0;
        var i: u32 = 0;
        while (i < fieldidx and i < fields.len) : (i += 1) off += gcSlotBytes(fields[i]);
        return off;
    }

    /// D-460 — array element slot size in bytes (16 v128, else 8).
    pub fn arrayElemBytes(self: *const ZirFunc, typeidx: u32) u32 {
        return gcSlotBytes(self.arrayElemValType(typeidx));
    }
};

test "ZirFunc.init: required fields populated, slots null" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(7, sig, &.{});
    defer f.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), f.func_idx);
    try std.testing.expectEqual(@as(usize, 0), f.sig.params.len);
    try std.testing.expectEqual(@as(usize, 0), f.sig.results.len);
    try std.testing.expectEqual(@as(usize, 0), f.locals.len);
    try std.testing.expectEqual(@as(usize, 0), f.instrs.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.branch_targets.items.len);

    try std.testing.expect(f.loop_info == null);
    try std.testing.expect(f.liveness == null);
    try std.testing.expect(f.constant_pool == null);
    try std.testing.expect(f.reg_class_hints == null);
    try std.testing.expect(f.spill_slots == null);
    try std.testing.expect(f.inst_ptr_cache_layout == null);
    try std.testing.expect(f.vm_ptr_cache_layout == null);
    try std.testing.expect(f.simd_base_cache_layout == null);
    try std.testing.expect(f.simd_lane_routing == null);
    try std.testing.expect(f.gc_root_map == null);
    try std.testing.expect(f.eh_landing_pads == null);
    try std.testing.expect(f.eh_catch_entries == null);
    try std.testing.expect(f.tail_call_sites == null);
    try std.testing.expect(f.hoisted_constants == null);
    try std.testing.expect(f.bounds_check_elision_map == null);
    try std.testing.expect(f.coalesced_movs == null);
    try std.testing.expect(f.pass_diagnostics == null);
}

test "ZirFunc: instrs grow via per-call allocator" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(std.testing.allocator);

    const op0: ZirOp = @enumFromInt(0);
    try f.instrs.append(std.testing.allocator, .{ .op = op0, .payload = 42, .extra = 0 });
    try f.instrs.append(std.testing.allocator, .{ .op = op0, .payload = 0, .extra = 7 });

    try std.testing.expectEqual(@as(usize, 2), f.instrs.items.len);
    try std.testing.expectEqual(@as(u32, 42), f.instrs.items[0].payload);
    try std.testing.expectEqual(@as(u32, 7), f.instrs.items[1].extra);
}

test "ValType / BlockKind: enum tags are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ValType.i32));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ValType.i64));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(BlockKind.block));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(BlockKind.loop));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(BlockKind.if_then));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(BlockKind.else_open));
    // Wasm 3.0 EH addition: try_table comes after the pre-existing
    // 4 control-frame kinds (per ADR-0114 EH design; foundation
    // wiring at 10.E-3).
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(BlockKind.try_table));
}

test "FuncType holds slices without copying" {
    const params = [_]ValType{ .i32, .i64 };
    const results = [_]ValType{.f64};
    const sig: FuncType = .{ .params = &params, .results = &results };
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqual(ValType.f64, sig.results[0]);
}

test "ZirOp: MVP opcodes are declared" {
    // Spot-check a representative slice of MVP entries.
    const mvp = [_]ZirOp{
        .@"unreachable", .nop,          .block,         .loop,           .@"if",
        .@"else",        .end,          .br,            .br_if,          .br_table,
        .@"return",      .call,         .call_indirect, .drop,           .select,
        .select_typed,   .@"local.get", .@"local.set",  .@"local.tee",   .@"global.get",
        .@"global.set",  .@"i32.const", .@"i32.add",    .@"i32.sub",     .@"i32.mul",
        .@"i64.const",   .@"f32.const", .@"f64.const",  .@"memory.size", .@"memory.grow",
    };
    inline for (mvp) |op| {
        _ = @intFromEnum(op);
    }
}

test "ZirOp: Wasm 2.0 / SIMD / 3.0 entries declared" {
    const v2 = [_]ZirOp{ .@"i32.extend8_s", .@"memory.copy", .@"ref.null", .@"table.get" };
    const simd = [_]ZirOp{ .@"v128.load", .@"v128.const", .@"i8x16.add", .@"f64x2.add" };
    const v3 = [_]ZirOp{
        .try_table,         .throw,        .return_call, .call_ref,
        .@"struct.new",     .@"array.new", .@"ref.test", .@"ref.i31",
        .@"memory.discard",
    };
    const phase34 = [_]ZirOp{ .@"atomic.fence", .@"i32.atomic.load", .@"cont.new", .@"resume" };
    const pseudo = [_]ZirOp{
        .@"__pseudo.const_in_reg",        .@"__pseudo.loop_header",
        .@"__pseudo.bounds_check_elided", .@"__pseudo.spill_to_slot",
        .@"__pseudo.frame_setup",
    };
    inline for (v2 ++ simd ++ v3 ++ phase34 ++ pseudo) |op| {
        _ = @intFromEnum(op);
    }
}

test "ZirOp: tag count meets §4.2 baseline" {
    // §4.2 declares ~280 named tags (Wasm 1.0 + 2.0 + SIMD + 3.0
    // + Phase 3-4 reserved + JIT pseudo-ops). Treat 250 as a
    // conservative floor — the assertion guards against a future
    // accidental deletion of a swath of tags.
    const fields = @typeInfo(ZirOp).@"enum".fields;
    try std.testing.expect(fields.len >= 250);
}

test "PassDiagnostics: empty default + deinit no-op + populated free" {
    // Empty default: deinit is a no-op (zero-length slice ≠ allocation).
    const empty: PassDiagnostics = .{};
    deinitPassDiagnostics(std.testing.allocator, empty);

    // Populated: allocate a slice via the test allocator, attach to
    // a fresh slot, and verify deinit frees cleanly (the leak
    // detector in std.testing.allocator catches any escape).
    const records = try std.testing.allocator.alloc(PassRecord, 3);
    records[0] = .{ .pass = .lower, .applied = 12, .skipped = 0, .extra = 12 };
    records[1] = .{ .pass = .hoist, .applied = 4, .skipped = 8, .extra = 2 };
    records[2] = .{ .pass = .emit, .applied = 12, .skipped = 0, .extra = 96 };
    const pd: PassDiagnostics = .{ .entries = records };
    try std.testing.expectEqual(@as(usize, 3), pd.entries.len);
    try std.testing.expectEqual(trace.PassId.hoist, pd.entries[1].pass);
    try std.testing.expectEqual(@as(u32, 8), pd.entries[1].skipped);
    deinitPassDiagnostics(std.testing.allocator, pd);
}

test "ZirFunc: pass_diagnostics slot attaches + detaches without leak" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(99, sig, &.{});
    defer f.deinit(std.testing.allocator);

    try std.testing.expect(f.pass_diagnostics == null);

    const records = try std.testing.allocator.alloc(PassRecord, 1);
    records[0] = .{ .pass = .liveness, .applied = 5, .skipped = 0, .extra = 7 };
    f.pass_diagnostics = .{ .entries = records };

    try std.testing.expect(f.pass_diagnostics != null);
    try std.testing.expectEqual(@as(usize, 1), f.pass_diagnostics.?.entries.len);

    // Caller-owned slot: deinit before f.deinit (mirrors compile.zig's
    // deinitFuncResult ordering — pass_diagnostics is freed before
    // ZirFunc.deinit, same as Liveness / LoopInfo).
    deinitPassDiagnostics(std.testing.allocator, f.pass_diagnostics.?);
    f.pass_diagnostics = null;
}

// ============================================================
// §9.9 / 9.5-b — isSimdZirOp predicate tests (per ADR-0041
// §"Decision" / 1 — shape-as-variant)
// ============================================================

test "isSimdZirOp: v128.* prefix matches" {
    try std.testing.expect(isSimdZirOp(.@"v128.load"));
    try std.testing.expect(isSimdZirOp(.@"v128.store"));
    try std.testing.expect(isSimdZirOp(.@"v128.const"));
    try std.testing.expect(isSimdZirOp(.@"v128.not"));
}

test "isSimdZirOp: per-shape prefixes match" {
    try std.testing.expect(isSimdZirOp(.@"i8x16.splat"));
    try std.testing.expect(isSimdZirOp(.@"i16x8.splat"));
    try std.testing.expect(isSimdZirOp(.@"i32x4.add"));
    try std.testing.expect(isSimdZirOp(.@"i64x2.splat"));
    try std.testing.expect(isSimdZirOp(.@"f32x4.splat"));
    try std.testing.expect(isSimdZirOp(.@"f64x2.splat"));
}

test "isSimdZirOp: scalar ops do not match" {
    try std.testing.expect(!isSimdZirOp(.@"i32.const"));
    try std.testing.expect(!isSimdZirOp(.@"i64.add"));
    try std.testing.expect(!isSimdZirOp(.@"f32.const"));
    try std.testing.expect(!isSimdZirOp(.@"f64.add"));
    try std.testing.expect(!isSimdZirOp(.end));
    try std.testing.expect(!isSimdZirOp(.@"local.get"));
    try std.testing.expect(!isSimdZirOp(.call));
}

test "ValType.name: scalars + abstract refs (D-334 F5a diagnostics)" {
    const eql = std.mem.eql;
    const i32_t: ValType = .i32;
    const f64_t: ValType = .f64;
    const v128_t: ValType = .v128;
    try std.testing.expect(eql(u8, i32_t.name(), "i32"));
    try std.testing.expect(eql(u8, f64_t.name(), "f64"));
    try std.testing.expect(eql(u8, v128_t.name(), "v128"));
    try std.testing.expect(eql(u8, ValType.funcref.name(), "funcref"));
    try std.testing.expect(eql(u8, ValType.externref.name(), "externref"));
    try std.testing.expect(eql(u8, ValType.exnref.name(), "exnref"));
    // non-null abstract ref → `(ref head)`
    const ref_func: ValType = .{ .ref = RefType.abs(.func, false) };
    try std.testing.expect(eql(u8, ref_func.name(), "(ref func)"));
    // concrete typed ref → index-less placeholder
    const ref_conc: ValType = .{ .ref = RefType.conc(3, true) };
    try std.testing.expect(eql(u8, ref_conc.name(), "(ref $type)"));
}
