// FILE-SIZE-EXEMPT: Wasm spec §3.3 validation single-pass walker (type-stack + control-stack); P1 spec-defined sub-language, intrinsically singular (splitting the stack-walking opcode handlers would create artificial seams across an unsplittable algorithm). D-204: the pure file-scope GC valtype-subtype helpers (valTypeIsSubtypeFree / gcHeapAbstractSubtype / gcConcreteReaches{,Canonical} / gcValTypeSubtype / gcFieldSubtype) were extracted to `gc_subtype.zig` (they touch no Validator state); the remaining module-level helpers (constExprResultType / validateGlobalInits / funcTypeImportCompatible / validateTypeSection) are pub + externally-called → extract separately if the cap presses again. (per ADR-0099) (cap=3510) (3300→3400 for D-324 per-memory idx_type plumbing; 3400→3450 for ADR-0126 iso-recursive canonical-equality threading into the per-function subtype path; 3450→3510 for D-459 local definite-assignment (Wasm 3.0 §3.3.1) — the init-set restore at block/if `end`+`else` is woven into pushFrame/opEnd/opElse + the per-frame entry mask, NOT extractable — all Wasm 3.0 spec-conformance feature adds, same ADR-0099-amend class as the instance.zig raise. EXTRACTION DONE (D-475 cap pressure): the 4 pub tail helpers (constExprResultType / validateGlobalInits / funcTypeImportCompatible / validateTypeSection) + their GlobalEntry/typeDefIsSubtype deps moved to `validator_helpers.zig` (re-exported here so callers are unchanged) — file dropped 3502→3363, ample headroom. NEXT pressure → extract the next pure sub-language cluster (e.g. the SIMD validator delegation or the catch-clause label helpers) rather than raise.)
//! Wasm function-body **type-stack + control-stack validator**
//! (Phase 1 / §9.1 / 1.5).
//!
//! Single-pass over a function body's expression bytes. Tracks the
//! operand stack and the control stack per Wasm 1.0 spec §3.3
//! (validation) and §3.3.5 (polymorphic stack after `unreachable`,
//! `br`, `return`). Uses bounded inline stacks per ROADMAP §P3
//! (cold-start) — no per-call allocation.
//!
//! Scope is the MVP opcode subset needed to wire the validator into
//! the Phase 1 pipeline. The full Wasm 1.0 opcode set lands when
//! per-feature modules register opcode-typing handlers via
//! `DispatchTable` in §9.1 / 1.7. The current `dispatch` switch
//! marks each not-yet-implemented MVP opcode with `error.NotImplemented`
//! rather than silently passing — once 1.7 lands the giant switch
//! migrates to a dispatch-table lookup per ROADMAP §A12.
//!
//! Zone 1 (`src/frontend/`) — may import Zone 0 (`src/support/leb128.zig`)
//! and Zone 1 (`src/ir/`). No upward imports.

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");
const sections = @import("../parse/sections.zig");
const gc_subtype = @import("gc_subtype.zig");
const init_expr = @import("../parse/init_expr.zig");
const dispatch_collector = @import("../ir/dispatch_collector.zig");
const wasm_byte_map = @import("../ir/wasm_byte_map.zig");
const validator_simd = @import("validator_simd.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");

const ValType = zir.ValType;
const FuncType = zir.FuncType;
const BlockKind = zir.BlockKind;

/// Either a concrete ValType, or `bot` (polymorphic-any) used during
/// the unreachable-stack window per spec §3.3.5.
pub const TypeOrBot = union(enum) {
    known: ValType,
    bot,
};

pub const Error = error{
    StackUnderflow,
    StackTypeMismatch,
    UnexpectedEnd,
    UnexpectedOpcode,
    InvalidOpcode,
    BadBlockType,
    BadValType,
    InvalidLocalIndex,
    /// Wasm 3.0 function-references §validation: `local.get`/`local.tee`
    /// reads a non-defaultable (non-null `(ref ht)`) local before it is set.
    UninitializedLocal,
    InvalidFuncIndex,
    InvalidGlobalIndex,
    ImmutableGlobal,
    /// Wasm spec §3.4.4 / §3.3.5.7-8: a memory op (load/store/
    /// memory.size / memory.grow / memory.fill / memory.copy /
    /// memory.init) appears in a function body but the module
    /// declares no memory (no memory section and no memory
    /// import).
    UnknownMemory,
    /// Wasm spec §3.4.7.3 / §3.4.10: a `ref.func x` in a function
    /// body names a function index x that is not in the module's
    /// declared-funcrefs set (= the set of funcidxs that appear
    /// in any global initializer, element segment, or export, but
    /// excluding occurrences inside function code bodies and the
    /// start function). Spec error text: "undeclared function
    /// reference".
    UndeclaredFuncRef,
    InvalidBranchDepth,
    UnclosedFrames,
    TrailingBytes,
    OperandStackOverflow,
    ControlStackOverflow,
    ArityMismatch,
    /// Wasm SIMD spec §3.3.6.X (lane-index range): an
    /// `extract_lane*` / `replace_lane*` / load_lane / store_lane
    /// op's 1-byte lane-index immediate is ≥ the shape's lane
    /// count (16 / 8 / 4 / 2 depending on i8x16 / i16x8 / i32x4 /
    /// i64x2 / f32x4 / f64x2). Per spec, this is a validation-time
    /// reject (`assert_invalid`), not a deferred runtime trap.
    InvalidLaneIndex,
    /// Wasm spec §3.3.7 (memarg alignment): a memory op's
    /// alignment immediate (log2 of byte alignment) exceeds the
    /// op's natural alignment. Covers both scalar and SIMD memory
    /// ops. Naturals: v128.load / store ≤ 4 (16-byte); v128.load64_splat
    /// / load64_lane / store64_lane / load64_zero / loadXxY ≤ 3
    /// (8-byte); i64/f64 ≤ 3; 32-bit ≤ 2; 16-bit ≤ 1; 8-bit ≤ 0.
    /// Validation-time reject (spec assert_invalid).
    InvalidAlignment,
    /// Wasm 3.0 EH §3.3.10.7: a `throw tag_idx` op (or a
    /// `try_table` catch / catch_ref clause) references a tag
    /// index outside `module.tags[]`. Reported by `opThrow` and
    /// `validateCatchVec` once `Module.tags` reaches the validator
    /// (10.E-N).
    InvalidTagIndex,
    /// ADR-0125 — `struct.get`/`array.get` on a packed (i8/i16) field
    /// (must use get_s/get_u), or get_s/get_u on a non-packed field.
    PackedFieldAccess,
    NotImplemented,
    OutOfMemory,
} || leb128.Error;

// Pure file-scope validation helpers extracted to a sibling (the marker's
// planned extraction; D-475 table64 cap pressure). Re-exported so internal +
// external `validator.<fn>` / `validator.GlobalEntry` call sites are unchanged.
const helpers = @import("validator_helpers.zig");
pub const GlobalEntry = helpers.GlobalEntry;
pub const typeDefIsSubtype = helpers.typeDefIsSubtype;
pub const constExprResultType = helpers.constExprResultType;
pub const validateGlobalInits = helpers.validateGlobalInits;
pub const ConstExprVerdict = helpers.ConstExprVerdict;
pub const ConstExprScope = helpers.ConstExprScope;
pub const validateConstExpr = helpers.validateConstExpr;
pub const funcTypeImportCompatible = helpers.funcTypeImportCompatible;
pub const validateTypeSection = helpers.validateTypeSection;

pub const max_operand_stack: usize = 1024;
/// Single source of truth in `zir` (also used by the IR verifier's
/// branch-target ceiling — they MUST match; see D-241).
pub const max_control_stack: usize = zir.max_control_stack;

/// Block result type. Wasm 1.0 binary block-types are `empty` (0x40)
/// or `single` (one valtype byte). Wasm 2.0 multivalue extends this
/// to `multi` via an s33 typeidx referencing a FuncType — both for
/// function frames whose signature has > 1 result, and for blocks /
/// loops / ifs whose `(param ...)` and / or `(result ...)` lists
/// have multi-value shape (D-035 chunk-d035-a).
pub const BlockType = union(enum) {
    empty,
    single: ValType,
    multi: []const ValType,
};

/// Composite block signature: the `(param ...)` / `(result ...)`
/// lists Wasm 2.0 typeidx blocktypes carry. Wasm 1.0 forms always
/// have `start = .empty`; only the `end` slot is populated. For
/// loops, `start` is the label type (br to a loop transfers the
/// param values); for blocks / ifs, `end` is the label type.
pub const BlockTypeFull = struct {
    start: BlockType,
    end: BlockType,
};

/// Map a slice of valtypes to the corresponding `BlockType` form:
/// 0-length → `.empty`, 1-length → `.single`, ≥2 → `.multi`.
fn blockTypeOfSlice(types: []const ValType) BlockType {
    return switch (types.len) {
        0 => .empty,
        1 => .{ .single = types[0] },
        else => .{ .multi = types },
    };
}

/// Wasm spec §5.3.1 valtype encoding bytes.
fn valTypeByte(t: ValType) u8 {
    return switch (t) {
        .i32 => 0x7F,
        .i64 => 0x7E,
        .f32 => 0x7D,
        .f64 => 0x7C,
        .v128 => 0x7B,
        // ADR-0123 (Cycle 2): legacy abstract-ref bytes map through
        // the nullable abstract head. Non-nullable / concrete refs
        // need the 0x63 / 0x64 multi-byte form (caller-side handled).
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
            // Concrete typed-ref (`(ref null? $idx)`) — single-byte
            // path returns a sentinel; multi-byte 0x63/0x64 encoding
            // owned by the binary writer's encode-RefType helper
            // when 10.R-valtype-widen Cycle 3 lands the parser side.
            .concrete => 0x40,
        },
    };
}

const ControlFrame = struct {
    kind: BlockKind,
    /// Block's `(param ...)` types — popped from the outer stack
    /// when the block opens, and re-pushed as the block body's
    /// initial operand-stack contents. Wasm 1.0 → always `.empty`.
    /// Loops use this as their label type so a `br` target re-
    /// transfers the params (Wasm 2.0 §3.4.4).
    start_type: BlockType,
    /// Block's `(result ...)` types — popped from the inner stack
    /// at `end` (verifying the body produced them) and re-pushed
    /// onto the outer stack. Blocks / ifs use this as their label
    /// type. Single-result Wasm 1.0 forms use `.single`; empty
    /// uses `.empty`; multi-value 2.0 typeidx may use `.multi`.
    end_type: BlockType,
    /// Operand-stack height at frame entry, **after** params have
    /// been popped + re-pushed (i.e. the height seen from outside
    /// the block, before the block's own params land on the
    /// stack). `popAny` floor checks against this so the block
    /// body cannot pop below the outer stack.
    height: u32,
    /// True after `unreachable` / `br` / `return` until this frame's
    /// `end` (or `else`, which resets it for the alternate branch).
    unreachable_flag: bool,
    /// D-459 — definite-assignment init-set of the non-defaultable locals
    /// (bit i ↔ `nondefault_idx[i]`) captured at frame ENTRY. Wasm 3.0
    /// §3.3.1: `local.set`/`tee` inside a structured block do NOT escape it —
    /// at `end` (and at `else`, back to the if-entry state) the init-set is
    /// restored to this snapshot, so a `local.get` of a local set only inside
    /// a nested block/if is correctly rejected. 0 when no non-defaultable locals.
    init_mask_at_entry: u64 = 0,

    /// Types popped by `br` to this label. Wasm 2.0 §3.4.4: blocks
    /// / ifs use the frame's *end* types; loops use the frame's
    /// *start* types.
    fn labelType(self: ControlFrame) BlockType {
        return switch (self.kind) {
            .loop => self.start_type,
            // try_table: branches to the try_table label arrive
            // on `end` (catch dispatch uses the catch's own
            // label_idx, not this frame's label), so use the
            // block end_type rule. Per Wasm 3.0 EH §3.3.10.6.
            .block, .if_then, .else_open, .try_table => self.end_type,
        };
    }

    /// Types pushed back onto the operand stack at `end`.
    fn endType(self: ControlFrame) BlockType {
        return self.end_type;
    }
};

/// Validate a single function body expression.
///
/// `sig.params` and `locals` together index `local.get` / `local.set`
/// (params first, then declared locals). `body` is the raw expression
/// bytes — opcode stream terminated by an outermost `end` that closes
/// the implicit function frame. `func_types` carries the module-wide
/// per-function signature table so `call N` can type-check; pass an
/// empty slice for the standalone-function case.
pub fn validateFunction(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
    };
    try v.run();
}

/// ADR-0121 D5 (10.G op_gc cycle 15) — `validateFunction` variant
/// that threads the GC typedef side-tables. Used by tests + future
/// `frontendValidate` integration so struct.new / struct.new_default
/// (and forthcoming struct.get/set, array.new family) can resolve
/// typeidx → StructDef / ArrayDef.
pub fn validateFunctionWithGcTypes(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    module_types_kinds: []const sections.TypeKind,
    struct_defs: []const ?sections.StructDef,
    array_defs: []const ?sections.ArrayDef,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .module_types_kinds = module_types_kinds,
        .struct_defs = struct_defs,
        .array_defs = array_defs,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
    };
    try v.run();
}

/// Wasm 3.0 memory64 — `validateFunction` variant that threads
/// `memory0_idx_type` so memory ops (load/store) pop the correct
/// address valtype (i32 for default memory, i64 for memory64 per
/// the memory section's flag bit 0x04 / ADR-0111 D1). Used by
/// `frontendValidate` in `runtime/instance/instantiate.zig` so
/// modules declaring an i64 memory validate cleanly instead of
/// rejecting their load/store bodies with StackTypeMismatch.
pub fn validateFunctionWithMemIdx(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    memory0_idx_type: sections.MemoryEntry.IdxType,
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
        .memory0_idx_type = memory0_idx_type,
    };
    try v.run();
}

/// 10.E EH module-compile path — `frontendValidate` variant that
/// threads both `memory0_idx_type` AND `tags`. Used by
/// `runtime/instance/instantiate.zig::frontendValidate` so the
/// CLI / c_api compile path validates `throw` / `try_table` ops
/// without rejecting them on the empty-tags default.
pub fn validateFunctionWithMemIdxAndTags(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    memory_count: u32,
    memory0_idx_type: sections.MemoryEntry.IdxType,
    /// D-324 — per-memory idx_type (imports first, then defined) for
    /// mixed i32/i64 multi-memory modules. Empty → memory0 fallback.
    memory_idx_types: []const sections.MemoryEntry.IdxType,
    tags: []const sections.TagEntry,
    /// 10.R cycle 60 (D-195 sub-gap c) — Wasm spec §3.4.10
    /// declared-funcrefs bitset. When non-empty, `ref.func N` rejects
    /// if `N` is not declared (via globals init / elements / exports).
    /// Empty (`&.{}`) preserves the legacy pre-cycle-60 behaviour for
    /// callers that haven't been migrated yet — adopters pass the
    /// real bitset to enable the check.
    declared_funcs: []const bool,
    /// 10.R-funcrefs-tail — func-index → type-section-index map for
    /// ADR-0123 D4 typed `ref.func`. Empty → legacy abstract funcref.
    func_type_indices: []const u32,
    /// 10.G WasmGC — type-section kinds + sparse struct/array defs so
    /// struct.new/get/set + array.new/get/len resolve their typeidx.
    /// Empty (`&.{}`) → non-GC callers (struct/array ops then reject).
    module_types_kinds: []const sections.TypeKind,
    struct_defs: []const ?sections.StructDef,
    array_defs: []const ?sections.ArrayDef,
    supertypes: []const []const u32,
    /// 10.G cycle 158 — per-element-segment reftype for array.init_elem
    /// (segment <: array element) + table.init (segment == table elem).
    /// Empty (`&.{}`) → legacy callers skip the segment-reftype check.
    elem_types: []const ValType,
    /// ADR-0126: full Types → subtypeCtx canonical equality; null → raw reach.
    canonical_types: ?*const sections.Types,
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .module_types_kinds = module_types_kinds,
        .struct_defs = struct_defs,
        .array_defs = array_defs,
        .supertypes = supertypes,
        .canonical_types = canonical_types,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
        .elem_types = elem_types,
        .memory_count = memory_count,
        .memory0_idx_type = memory0_idx_type,
        .memory_idx_types = memory_idx_types,
        .tags = tags,
        .declared_funcs = declared_funcs,
        .func_type_indices = func_type_indices,
    };
    try v.run();
}

/// Wasm 3.0 EH (10.E-N-1) — `validateFunction` variant that also
/// threads the decoded tag section so `throw` and try_table catch
/// clauses range-check `tag_idx` against `module.tags[]`. Used
/// by EH unit tests; production `compileWasm` threads tags into
/// `validateFunctionAndCollectSelectTypesWithMemory` directly.
pub fn validateFunctionWithTags(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    tags: []const sections.TagEntry,
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
        .tags = tags,
    };
    try v.run();
}

/// Same as `validateFunction`, but additionally collects per-untyped-
/// `select` (opcode 0x1B) resolved operand valtype bytes into
/// `out_select_types`, in body-walk order. Used by the lower / emit
/// pipeline (D-115) to populate `ZirInstr.extra` for untyped select so
/// emit dispatches FCSEL / FpSelect on FP-class operands instead of
/// silently defaulting to GPR-class CSEL (Wasm spec §3.3.2.2).
///
/// Wasm spec §3.3.2.2 — untyped select infers t1 == t2 from the
/// validator's value-stack; the type byte stored here is the canonical
/// valtype encoding (0x7F i32 / 0x7E i64 / 0x7D f32 / 0x7C f64 /
/// 0x70 funcref / 0x6F externref). Polymorphic-bottom resolves to
/// 0x7F (the harmless default; pre-d-39 fall-through).
pub fn validateFunctionAndCollectSelectTypes(
    allocator: std.mem.Allocator,
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    out_select_types: *std.ArrayList(u8),
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
        .out_select_types = out_select_types,
        .out_allocator = allocator,
    };
    try v.run();
}

/// §9.9 / 9.9-l-1b-d093-d79 — variant that also threads
/// `memory_count` so the validator can reject memory ops
/// (load/store/size/grow/fill/copy/init) in function bodies
/// when the module declares no memory. Production callers
/// in `compileWasm` use this variant; the original
/// `validateFunctionAndCollectSelectTypes` keeps the
/// legacy default (`memory_count = 0`) for tests that
/// don't exercise memory ops.
pub fn validateFunctionAndCollectSelectTypesWithMemory(
    allocator: std.mem.Allocator,
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    memory_count: u32,
    declared_funcs: []const bool,
    elem_types: []const ValType,
    data_count_section_present: bool,
    out_select_types: *std.ArrayList(u8),
    memory0_idx_type: sections.MemoryEntry.IdxType,
    /// D-324 — per-memory idx_type (imports first, then defined) for
    /// mixed i32/i64 multi-memory modules. Empty → memory0 fallback.
    memory_idx_types: []const sections.MemoryEntry.IdxType,
    tags: []const sections.TagEntry,
    // 10.G GC-on-JIT (ADR-0128 §2): thread the type section's GC
    // kind + struct/array defs so the JIT compile path validates
    // struct.new* / array.* (previously defaulted to `&.{}`, which
    // rejected every GC op as InvalidFuncIndex — the corpus is
    // interp-only so this JIT-validate-GC path was never exercised).
    module_types_kinds: []const sections.TypeKind,
    struct_defs: []const ?sections.StructDef,
    array_defs: []const ?sections.ArrayDef,
    // D-220: declared supertype chains (parallel to module_types) so the JIT
    // compile path's `subtypeCtx`/`gcConcreteReaches` validates concrete GC
    // subtyping (br_on_cast, narrowed-ref call args, gc/type-subtyping).
    // Previously defaulted to `&.{}` → StackTypeMismatch on every concrete
    // subtype check (the interp path threads it via instantiate.zig).
    supertypes: []const []const u32,
    // D-239: func-index → type-section-index map (imports-first) so typed
    // `ref.func N` yields the PRECISE `(ref func_type_indices[N])` instead
    // of abstract funcref (ADR-0123 D4). Previously omitted → defaulted to
    // `&.{}` → `ref.func` mismatched a `(ref $t)` param → StackTypeMismatch
    // (br_on_null / br_on_non_null / ref_as_non_null modules). The interp
    // path threads it via instantiate.zig:128-143.
    func_type_indices: []const u32,
    // ADR-0126: full Types → subtypeCtx canonical equality; null → raw reach.
    canonical_types: ?*const sections.Types,
) Error!void {
    var v = Validator{
        .supertypes = supertypes,
        .canonical_types = canonical_types,
        .func_type_indices = func_type_indices,
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
        .memory_count = memory_count,
        .memory0_idx_type = memory0_idx_type,
        .memory_idx_types = memory_idx_types,
        .declared_funcs = declared_funcs,
        .elem_types = elem_types,
        .data_count_section_present = data_count_section_present,
        .out_select_types = out_select_types,
        .out_allocator = allocator,
        .tags = tags,
        .module_types_kinds = module_types_kinds,
        .struct_defs = struct_defs,
        .array_defs = array_defs,
    };
    try v.run();
}

/// Wasm 3.0 §3.3.3 — a local type is defaultable (numeric/vector or NULLABLE
/// ref) and readable without a set; non-null `(ref ht)` is not (cyc195).
fn localIsDefaultable(t: ValType) bool {
    return switch (t) {
        .ref => |r| r.nullable,
        else => true,
    };
}

pub const Validator = struct {
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    pos: usize,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    /// §9.9 / 9.9-l-1b-d093-d79 — count of memories (imports +
    /// defined) reachable at function-body validation time.
    /// Wasm 2.0 §3.4.4 caps total memories at 1; this is
    /// either 0 or 1 in practice. Memory ops in function bodies
    /// (load/store/size/grow + bulk variants) require memory_count
    /// >= 1; absent memory → `Error.UnknownMemory`.
    ///
    /// Default = 1: legacy `validateFunction` /
    /// `validateFunctionAndCollectSelectTypes` callers (unit
    /// tests, wast_runner) don't thread memory_count and
    /// assume memory ops are valid — preserving pre-d-79
    /// behaviour. Production `compileWasm` uses
    /// `validateFunctionAndCollectSelectTypesWithMemory`
    /// which sets memory_count explicitly per module.
    memory_count: u32 = 1,
    /// ADR-0111 D2 — memory 0's idx_type for Wasm 3.0 memory64.
    /// Determines the address operand type at opLoad/opStore
    /// (i32-indexed memory → pop i32 addr; i64-indexed → pop
    /// i64 addr). Default `.i32` keeps legacy `validateFunction`
    /// / `validateFunctionAndCollectSelectTypes` callers behaviour
    /// -preserving (they don't thread memory64 state); production
    /// `compileWasm` uses the WithMemory entry which sets it
    /// explicitly per module.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// D-324 — per-memory idx_type slice (imports first, then
    /// defined) for mixed i32/i64 multi-memory modules (Wasm 3.0
    /// memory64 × multi-memory). Indexed by memidx; memory ops look
    /// their target memory's address type up here. Empty (default)
    /// falls back to `memory0_idx_type` for every memidx — preserves
    /// legacy single-memory callers (unit tests, wast_runner).
    /// Production `compileWasm` / `frontendValidate` thread the real
    /// slice.
    memory_idx_types: []const sections.MemoryEntry.IdxType = &.{},
    /// §9.9 / 9.9-l-1b-d093-d82 — declared-funcrefs bitset per
    /// Wasm spec §3.4.10. Length = total funcs (imports +
    /// defined); entry `true` iff that funcidx appears in some
    /// global initializer, element segment (funcidx or init expr),
    /// or export (kind=func). Function code bodies and the start
    /// function do NOT contribute. Empty slice (default) disables
    /// enforcement so legacy callers (unit tests, wast_runner)
    /// keep prior behaviour; production `compileWasm` passes a
    /// populated slice.
    declared_funcs: []const bool = &.{},
    /// 10.R-funcrefs-tail — func-index → type-section-index map
    /// (length = total funcs; imports first, then defined). ADR-0123
    /// D4: `ref.func N` yields the non-null typed ref `(ref
    /// func_type_indices[N])` instead of the abstract `funcref`, so it
    /// satisfies typed `(ref $sig)` params at `call` / `call_ref`.
    /// Empty (default) → legacy abstract `funcref` push for callers
    /// (unit tests, compileWasm) that don't thread it yet.
    func_type_indices: []const u32 = &.{},
    /// §9.9 / 9.9-l-1b-d093-d83 — per-element-segment reftype
    /// (parallel to `elem_count`; length = elem_count when
    /// populated). Used by `opTableInit` to enforce Wasm spec
    /// §3.3.5.20: `table.init x y` requires
    /// `elem_types[x] == tables[y].elem_type`. Empty slice
    /// (default) disables the per-elem reftype check so legacy
    /// callers retain prior behaviour (chunk 5d-2 era accepted
    /// any in-range elemidx/tableidx pair).
    elem_types: []const ValType = &.{},
    /// §9.9 / 9.9-l-1b-d093-d84 — Wasm spec §5.5.10: when any
    /// function body uses `memory.init` (0xFC 0x08) or
    /// `data.drop` (0xFC 0x09), the module MUST contain the
    /// optional `data count` section (id 12). False ↔ section
    /// absent; the two opcodes' validation paths reject.
    /// Default `true` keeps legacy callers / unit tests
    /// unaffected.
    data_count_section_present: bool = true,
    /// Wasm 3.0 EH §4.5 — decoded tag section. `throw tag_idx`
    /// and try_table catch (0x00 / 0x01) reference this by index
    /// to look up the tag's params (= the FuncType at
    /// `module_types[tags[tag_idx].typeidx]`). Default `&.{}`
    /// preserves the pre-10.E-N behaviour for callers that
    /// didn't thread the tag section through (their `throw`
    /// will now reject with `Error.InvalidTagIndex` — the
    /// existing test surface migrated at 10.E-N-1; production
    /// `compileWasm` passes the decoded section).
    tags: []const sections.TagEntry = &.{},
    /// ADR-0121 D2 (10.G op_gc cycle 14) — parallel to
    /// `module_types`; tags each typeidx's kind so struct.new /
    /// array.new can look up the typedef shape. Empty slice
    /// (default) means struct/array ops reject as "unknown
    /// typeidx kind" — preserves the pre-cycle-15 behaviour
    /// for callers that don't thread the kinds slice.
    module_types_kinds: []const sections.TypeKind = &.{},
    /// ADR-0121 D2 — sparse typeidx → struct field list. Non-null
    /// iff `module_types_kinds[idx] == .structdef`. struct.new /
    /// struct.new_default consult this via `struct_defs[idx].?`.
    struct_defs: []const ?sections.StructDef = &.{},
    /// ADR-0121 D2 — sparse typeidx → array element type. Non-null
    /// iff `module_types_kinds[idx] == .arraydef`. array.new family
    /// consults this when those ops land.
    array_defs: []const ?sections.ArrayDef = &.{},

    /// ADR-0124 — per-typeidx declared supertype lists (parallel to
    /// `module_types`). Enables the concrete→concrete subtype rule in
    /// `subtypeCtx`: a `(ref $sub)` satisfies a `(ref $super)` operand
    /// (e.g. a `call` arg) when `$sub`'s declared supertype chain reaches
    /// `$super` (`gcConcreteReaches`). Empty (default) → concrete refs
    /// match only by identity, preserving pre-GC callers' behaviour.
    supertypes: []const []const u32 = &.{},

    /// ADR-0126 — full type section (when threaded) so `subtypeCtx`'s
    /// concrete→concrete rule uses iso-recursive CANONICAL equality
    /// (cross-rec-group identity) not raw-index reach. Null → fall back
    /// to `supertypes`.
    canonical_types: ?*const sections.Types = null,

    operand_buf: [max_operand_stack]TypeOrBot = undefined,
    operand_len: usize = 0,

    control_buf: [max_control_stack]ControlFrame = undefined,
    control_len: usize = 0,

    /// cyc195 — grow-only definite-assignment bitset for non-defaultable
    /// locals (Wasm 3.0 function-references §validation; see `markLocalInit`
    /// + `opLocalGet`). Disabled if local count exceeds the buffer cap (safe).
    locals_init: [max_operand_stack]bool = undefined,
    track_local_init: bool = false,
    n_locals_total: u32 = 0,
    /// D-459 — indices of the non-defaultable locals (the only ones whose
    /// init bit can transition false→true), capped at 64 so a frame's
    /// entry init-set fits one u64 (`ControlFrame.init_mask_at_entry`). A
    /// function with >64 non-defaultable locals tracks the first 64 for the
    /// block-escape rule (the rest keep grow-only global tracking — strictly
    /// better than no block-restore; >64 non-null-ref locals is unheard-of).
    nondefault_idx: [64]u16 = undefined,
    n_nondefault: u32 = 0,

    /// D-115 d-39: when non-null, `opSelect` appends the resolved
    /// operand valtype byte per untyped `select` (0x1B). Body-walk
    /// order; consumed by `lower.zig` to populate `ZirInstr.extra`
    /// so emit can dispatch FCSEL / FpSelect on FP-class operands.
    out_select_types: ?*std.ArrayList(u8) = null,
    out_allocator: ?std.mem.Allocator = null,

    /// D-334 F5a — set by a type-mismatch reject site so the dispatch-loop
    /// cold path (which owns the op location) can render a rich message
    /// instead of the bare error name: `.types` = a concrete expected/found
    /// pair (popExpect); `.expected_ref` = a reference type was required but
    /// the found type isn't one (the `isRef` gates). The error
    /// short-circuits straight to that catch, so no successful op ever
    /// observes a stale value.
    mismatch: ?union(enum) {
        types: struct { expected: ValType, found: ValType },
        expected_ref: ValType, // the (non-ref) found type
    } = null,

    fn run(self: *Validator) Error!void {
        // Implicit function frame: a `block` with the function's result type.
        // The frame's start_type stays `.empty` — the function's params live
        // as locals (not on the operand stack at entry), so `return` pops
        // the result types and `br depth=N-1` does the same. (Wasm 2.0
        // §3.4.10 retains this convention even with multi-value.)
        const fn_end_type: BlockType = blockTypeOfSlice(self.sig.results);

        try self.pushFrame(.block, .empty, fn_end_type);

        // cyc195 — seed the definite-assignment bitset (skip if over cap).
        {
            const total = self.sig.params.len + self.locals.len;
            if (total <= max_operand_stack) {
                self.track_local_init = true;
                self.n_locals_total = @intCast(total);
                const params_len = self.sig.params.len;
                var li: u32 = 0;
                while (li < total) : (li += 1) {
                    // Params always init (receive args); declared locals by defaultability.
                    const defaultable = li < params_len or localIsDefaultable(self.localType(li).?);
                    self.locals_init[li] = defaultable;
                    // D-459: record non-defaultable locals (init can flip
                    // false→true) so per-frame entry masks can restore them.
                    if (!defaultable and self.n_nondefault < self.nondefault_idx.len) {
                        self.nondefault_idx[self.n_nondefault] = @intCast(li);
                        self.n_nondefault += 1;
                    }
                }
            }
        }

        while (self.control_len > 0) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const op = self.body[self.pos];
            const op_pos = self.pos;
            self.pos += 1;
            // ADR-0016 M3 — attribute the failing instruction on the cold
            // path: the body offset + opcode of the op that rejected.
            // `frontendValidate` patches `fn_idx` afterward. This is the
            // permanent replacement for the throwaway op-probe used during
            // GC corpus bring-up (lesson `gc-type-subtyping-is-rtt-blocked`).
            self.dispatch(op) catch |e| {
                const loc: diagnostic.Location = .{ .validate = .{
                    .fn_idx = 0,
                    .body_offset = @intCast(op_pos),
                    .opcode = op,
                } };
                if (e == Error.StackTypeMismatch and self.mismatch != null) {
                    switch (self.mismatch.?) {
                        .types => |m| diagnostic.setDiag(.validate, .other, loc, "type mismatch: expected {s}, found {s} at op 0x{x}", .{ m.expected.name(), m.found.name(), op }),
                        .expected_ref => |found| diagnostic.setDiag(.validate, .other, loc, "type mismatch: expected a reference type, found {s} at op 0x{x}", .{ found.name(), op }),
                    }
                } else {
                    diagnostic.setDiag(.validate, .other, loc, "{s} at op 0x{x}", .{ @errorName(e), op });
                }
                return e;
            };
        }

        if (self.pos != self.body.len) return Error.TrailingBytes;
    }

    // ----------------------------------------------------------------
    // Operand-stack helpers
    // ----------------------------------------------------------------

    // SIBLING-PUB: validator_simd.zig (per ADR-0083 extraction)
    pub fn pushType(self: *Validator, t: ValType) Error!void {
        if (self.operand_len == max_operand_stack) return Error.OperandStackOverflow;
        self.operand_buf[self.operand_len] = .{ .known = t };
        self.operand_len += 1;
    }

    fn pushBot(self: *Validator) Error!void {
        if (self.operand_len == max_operand_stack) return Error.OperandStackOverflow;
        self.operand_buf[self.operand_len] = .bot;
        self.operand_len += 1;
    }

    /// Pop one operand and assert it has the expected type. In an
    /// unreachable region pop returns `bot` (synthesised) instead of
    /// underflowing.
    ///
    /// ADR-0123 Cycle 6 (10.R-funcrefs-tail bundle Cycle 2): the
    /// match is subtype-aware rather than strict-eql:
    /// - numeric / v128: must be identical (no subtyping)
    /// - ref types: `(ref ht)` (non-null) is a subtype of
    ///   `(ref null ht)` (nullable) — popping a non-null where
    ///   nullable is expected is OK.  Heap type must still match
    ///   exactly (full subtype lattice for heap types lands with
    ///   10.G — for now only nullability flexibility).
    /// Wasm spec 3.0 §3.3.4 subtype rules.
    // SIBLING-PUB: validator_simd.zig (per ADR-0083 extraction)
    pub fn popExpect(self: *Validator, expected: ValType) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!self.subtypeCtx(t, expected)) {
                self.mismatch = .{ .types = .{ .expected = expected, .found = t } };
                return Error.StackTypeMismatch;
            },
        }
    }

    pub fn valTypeIsSubtype(actual: ValType, expected: ValType) bool {
        return gc_subtype.valTypeIsSubtypeFree(actual, expected);
    }

    /// Subtype check WITH module-type context — extends the context-free
    /// `valTypeIsSubtypeFree` with the Wasm 3.0 GC §4.2.8 concrete→abstract
    /// rule: a concrete `(ref $t)` satisfies an abstract eq/any/struct/
    /// array head when `$t`'s kind matches (struct.new pushes `(ref $t)`;
    /// a func returning structref / anyref must accept it). Needs
    /// `module_types_kinds` (threaded by frontendValidate, 10.G cycle 135).
    pub fn subtypeCtx(self: *const Validator, actual: ValType, expected: ValType) bool {
        // The context-free helper approximates EVERY concrete head as `func`
        // (ADR-0123: pre-GC the type section held only func types). Once
        // `module_types_kinds` is threaded that approximation is WRONG for a
        // struct/array typedef, so it must not short-circuit ahead of the
        // kind-aware arm below — else `(ref null $struct)` satisfies a
        // `funcref` slot and the reference is later read as a func entity.
        // With no kinds threaded the arm's own `.func` fallback reproduces
        // the ADR-0123 answer, so pre-GC callers are unaffected.
        const concrete_to_abstract = actual == .ref and expected == .ref and
            actual.ref.heap_type == .concrete and expected.ref.heap_type == .abstract;
        if (!concrete_to_abstract and gc_subtype.valTypeIsSubtypeFree(actual, expected)) return true;
        if (actual != .ref or expected != .ref) return false;
        if (actual.ref.nullable and !expected.ref.nullable) return false;
        return switch (actual.ref.heap_type) {
            .concrete => |idx| switch (expected.ref.heap_type) {
                .abstract => |e_abs| blk: {
                    const head: zir.AbstractHeapType = if (idx < self.module_types_kinds.len) switch (self.module_types_kinds[idx]) {
                        .func => .func,
                        .structdef => .struct_,
                        .arraydef => .array,
                    } else .func;
                    break :blk gc_subtype.gcHeapAbstractSubtype(head, e_abs);
                },
                // ADR-0124 — concrete→concrete: `(ref $a)` <: `(ref $b)`
                // iff `$a`'s declared supertype chain reaches `$b`. Drives
                // call-arg / return / local.set coercion of narrowed GC
                // refs (gc/type-subtyping.6/7 fail at `call` without this).
                // ADR-0126 — canonical (cross-rec-group) equality when Types
                // is threaded; else raw-index reach.
                .concrete => |e_idx| if (self.canonical_types) |t|
                    gc_subtype.gcConcreteReachesCanonical(idx, e_idx, t)
                else
                    gc_subtype.gcConcreteReaches(idx, e_idx, self.supertypes),
            },
            // Wasm 3.0 GC §4.2.8 abstract heap-type hierarchy
            // (i31/struct/array <: eq <: any; bottoms <: all in their
            // hierarchy; cross-hierarchy rejected). e.g. a `(ref i31)`
            // value flowing into an anyref table.grow/fill/init
            // (i31.wast $anyref_table_of_i31ref). The bottom heads also
            // reach CONCRETE types (`Heaptype_sub/none` / `/nofunc`) —
            // see `gcBottomReachesConcrete` for why that is neither
            // "bottom implies true" nor the plain abstract lattice.
            .abstract => |a_abs| switch (expected.ref.heap_type) {
                .abstract => |e_abs| gc_subtype.gcHeapAbstractSubtype(a_abs, e_abs),
                .concrete => |e_idx| gc_subtype.gcBottomReachesConcrete(a_abs, e_idx, self.module_types_kinds),
            },
        };
    }

    fn popAny(self: *Validator) Error!TypeOrBot {
        const frame = &self.control_buf[self.control_len - 1];
        if (self.operand_len == frame.height) {
            if (frame.unreachable_flag) return .bot;
            return Error.StackUnderflow;
        }
        self.operand_len -= 1;
        return self.operand_buf[self.operand_len];
    }

    /// Peek the operand `d` slots from top WITHOUT popping; `.bot` when below
    /// the frame floor (polymorphic fill, matching `popAny`). For `br_table`
    /// D-452 (subtype-check branch operands against every label, no consume).
    fn peekOperandFromTop(self: *Validator, d: usize) TypeOrBot {
        const avail = self.operand_len - self.topFrame().height;
        if (d >= avail) return .bot;
        return self.operand_buf[self.operand_len - 1 - d];
    }

    /// D-452 (Wasm 3.0 §3.3.8.8) — the top `lt.arity` operands must each be a
    /// SUBTYPE of label `lt`'s result types (branch operands flow to the
    /// target). Peek-only; `.bot` matches any. `ts[k]` = operand at depth len-1-k.
    fn checkOperandsSubtypeOfLabel(self: *Validator, lt: BlockType) Error!void {
        switch (lt) {
            .empty => {},
            .single => |t| switch (self.peekOperandFromTop(0)) {
                .bot => {},
                .known => |ot| if (!self.subtypeCtx(ot, t)) return Error.StackTypeMismatch,
            },
            .multi => |ts| for (ts, 0..) |t, k| switch (self.peekOperandFromTop(ts.len - 1 - k)) {
                .bot => {},
                .known => |ot| if (!self.subtypeCtx(ot, t)) return Error.StackTypeMismatch,
            },
        }
    }

    // ----------------------------------------------------------------
    // Control-stack helpers
    // ----------------------------------------------------------------

    fn pushFrame(
        self: *Validator,
        kind: BlockKind,
        start_bt: BlockType,
        end_bt: BlockType,
    ) Error!void {
        if (self.control_len == max_control_stack) return Error.ControlStackOverflow;
        self.control_buf[self.control_len] = .{
            .kind = kind,
            .start_type = start_bt,
            .end_type = end_bt,
            .height = @intCast(self.operand_len),
            .unreachable_flag = false,
            // D-459: snapshot the init-set so this block's local sets are
            // discarded at its `end` (they don't escape — Wasm 3.0 §3.3.1).
            .init_mask_at_entry = self.currentInitMask(),
        };
        self.control_len += 1;
    }

    fn topFrame(self: *Validator) *ControlFrame {
        return &self.control_buf[self.control_len - 1];
    }

    /// Index 0 = innermost frame.
    fn frameAt(self: *Validator, depth: u32) ?*ControlFrame {
        if (depth >= self.control_len) return null;
        return &self.control_buf[self.control_len - 1 - depth];
    }

    fn markUnreachable(self: *Validator) void {
        const frame = self.topFrame();
        frame.unreachable_flag = true;
        // Drop everything pushed inside this frame; `bot` reads will
        // synthesise types as the polymorphic-stack rule demands.
        self.operand_len = frame.height;
    }

    // ----------------------------------------------------------------
    // Local-index helpers
    // ----------------------------------------------------------------

    fn localType(self: *Validator, idx: u32) ?ValType {
        const params_len = self.sig.params.len;
        if (idx < params_len) return self.sig.params[idx];
        const local_idx = idx - params_len;
        if (local_idx >= self.locals.len) return null;
        return self.locals[local_idx];
    }

    // ----------------------------------------------------------------
    // Block-type decoder (Wasm 1.0 forms + Wasm 2.0 typeidx)
    // ----------------------------------------------------------------

    /// Wasm spec §5.4.X (block type) — encoded as an s33 LEB. Negative
    /// values are well-known type abbreviations (-64 = empty, -1..-4 =
    /// single valtype); positive values are typeidx into the module's
    /// type section (Wasm 2.0 multivalue per §3.4.4).
    ///
    /// Returns the block's full signature (`start` = params, `end` =
    /// results). Wasm 1.0 forms always have `start = .empty`.
    /// D-035 chunk-d035-a lifts the previous `params.len != 0`
    /// rejection so multi-param + multi-result blocks (block.wast,
    /// br_*.wast, call.wast) round-trip through validate + lower.
    fn readBlockType(self: *Validator) Error!BlockTypeFull {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const sleb = leb128.readSleb128(i32, self.body, &self.pos) catch
            return Error.BadBlockType;
        if (sleb < 0) {
            const end: BlockType = switch (sleb) {
                -64 => .empty, // 0x40
                -1 => .{ .single = .i32 }, // 0x7F
                -2 => .{ .single = .i64 }, // 0x7E
                -3 => .{ .single = .f32 }, // 0x7D
                -4 => .{ .single = .f64 }, // 0x7C
                -5 => .{ .single = .v128 }, // 0x7B (§9.9 / 9.9-f-2)
                // §9.9 / 9.9-l-1b-d093-d45 (D-118): reftype block-
                // results per Wasm 2.0 §5.3.5 (`valtype` for block
                // types includes funcref / externref). `br_table.wast`'s
                // `meet-funcref` / `meet-externref` exports declare
                // `(block (result <ref>) ...)` blocks. Reftype-class
                // codegen plumbing (d-33) aliases these onto the
                // i64 8-byte gpr-class scalar path.
                -16 => .{ .single = .funcref }, // 0x70
                -17 => .{ .single = .externref }, // 0x6F
                // Wasm 3.0 GC §5.3.4 — single-byte abstract reftype
                // shorthands as blocktypes (`(ref null <ht>)`). Mirrors
                // `init_expr.readValType`'s 0x6E..0x69 set; the gc
                // ref_test / ref_cast / br_on_cast fixtures open
                // `(block (result structref) ...)`. (10.G cycle 144)
                -18 => .{ .single = ValType.anyref }, // 0x6E
                -19 => .{ .single = ValType.eqref }, // 0x6D
                -20 => .{ .single = ValType.i31ref }, // 0x6C
                -21 => .{ .single = ValType.structref }, // 0x6B
                -22 => .{ .single = ValType.arrayref }, // 0x6A
                -23 => .{ .single = ValType.exnref }, // 0x69
                // function-references §5.3.4 + blocktype §5.4.1:
                // typed-ref result via `0x63 ht` (ref null ht) / `0x64
                // ht` (ref ht). The SLEB read above consumed the prefix
                // byte (0x63 → -29, 0x64 → -28); readTypedRefBlockType
                // decodes the heap-type that follows and bound-checks a
                // concrete type index.
                -29 => try self.readTypedRefBlockType(true), // 0x63
                -28 => try self.readTypedRefBlockType(false), // 0x64
                else => return Error.BadBlockType,
            };
            return .{ .start = .empty, .end = end };
        }
        const idx: u32 = @intCast(sleb);
        if (idx >= self.module_types.len) return Error.BadBlockType;
        const ft = self.module_types[idx];
        return .{
            .start = blockTypeOfSlice(ft.params),
            .end = blockTypeOfSlice(ft.results),
        };
    }

    /// Wasm spec §5.3.4 — decode the heap-type following a typed-ref
    /// blocktype prefix (`0x63`/`0x64`, already consumed by
    /// readBlockType's SLEB read) into a `.single` BlockType. A
    /// concrete heap-type index must reference a declared type (spec
    /// §3.2.3); out-of-range or malformed → BadBlockType, mirroring the
    /// typeidx-blocktype bound check above. `readTypedRef` does not
    /// bound-check (it also serves index-free init-expr contexts), so
    /// the validator owns that check here. ref.9 / ref.10
    /// (function-references) exercise the out-of-range reject.
    fn readTypedRefBlockType(self: *Validator, nullable: bool) Error!BlockType {
        const vt = init_expr.readTypedRef(self.body, &self.pos, nullable) catch
            return Error.BadBlockType;
        if (vt == .ref and vt.ref.heap_type == .concrete and
            vt.ref.heap_type.concrete >= self.module_types.len)
        {
            return Error.BadBlockType;
        }
        return .{ .single = vt };
    }

    // ----------------------------------------------------------------
    // Opcode dispatch
    // ----------------------------------------------------------------

    fn dispatch(self: *Validator, op: u8) Error!void {
        // §9.12-B / B7: route through dispatch_collector before the
        // legacy switch. Per ADR-0073 + `.dev/dispatcher_wire_design.md`
        // §2.1 option B: `wasm_byte_map.byteToZirOp(op)` translates the
        // Wasm bytecode to the ZirOp tag; then
        // `dispatch_collector.dispatcher(.validate)` routes to per-op
        // file. NotMigrated / UnsupportedOpForBuildLevel → fall
        // through to legacy switch. Bytes not yet in the map (null
        // return) also fall through silently.
        if (wasm_byte_map.byteToZirOp(op)) |zir_tag| {
            if (dispatch_collector.dispatcher(.validate)(zir_tag, .{})) |_| {
                // Migrated op handled by per-op file.
                return;
            } else |err| switch (err) {
                error.NotMigrated, error.UnsupportedOpForBuildLevel => {},
            }
        }
        switch (op) {
            // Control flow
            0x00 => try self.opUnreachable(),
            0x01 => {}, // nop
            0x02 => try self.opBlock(.block),
            0x03 => try self.opBlock(.loop),
            0x04 => try self.opIf(),
            // Wasm 3.0 EH `try_table` (§3.3.10.6 / §4.5).
            0x1F => try self.opTryTable(),
            // Wasm 3.0 EH `throw tag_idx` (§3.3.10.7).
            0x08 => try self.opThrow(),
            // Wasm 3.0 EH `throw_ref` (§3.3.10.8).
            0x0A => try self.opThrowRef(),
            0x05 => try self.opElse(),
            0x0B => try self.opEnd(),
            0x0C => try self.opBr(),
            0x0D => try self.opBrIf(),
            0x0E => try self.opBrTable(),
            0x0F => try self.opReturn(),
            0x10 => try self.opCall(),
            0x11 => try self.opCallIndirect(),
            // Wasm 3.0 tail-call proposal.
            0x12 => try self.opReturnCall(),
            0x13 => try self.opReturnCallIndirect(),

            // Parametric
            0x1A => try self.opDrop(),
            0x1B => try self.opSelect(),
            0x1C => try self.opSelectTyped(),

            // Variables
            0x20 => try self.opLocalGet(),
            0x21 => try self.opLocalSet(),
            0x22 => try self.opLocalTee(),
            0x23 => try self.opGlobalGet(),
            0x24 => try self.opGlobalSet(),

            // Tables (Wasm 2.0 §9.2 / 2.3 chunk 5c)
            0x25 => try self.opTableGet(),
            0x26 => try self.opTableSet(),

            // Loads (memarg → align uleb32 + offset uleb32)
            // §3.3.7 natural-alignment caps: load8≤0, load16≤1,
            // load32≤2, load64≤3 (log2 of byte width).
            0x28 => try self.opLoad(.i32, 2), // i32.load
            0x29 => try self.opLoad(.i64, 3), // i64.load
            0x2A => try self.opLoad(.f32, 2), // f32.load
            0x2B => try self.opLoad(.f64, 3), // f64.load
            0x2C => try self.opLoad(.i32, 0), // i32.load8_s
            0x2D => try self.opLoad(.i32, 0), // i32.load8_u
            0x2E => try self.opLoad(.i32, 1), // i32.load16_s
            0x2F => try self.opLoad(.i32, 1), // i32.load16_u
            0x30 => try self.opLoad(.i64, 0), // i64.load8_s
            0x31 => try self.opLoad(.i64, 0), // i64.load8_u
            0x32 => try self.opLoad(.i64, 1), // i64.load16_s
            0x33 => try self.opLoad(.i64, 1), // i64.load16_u
            0x34 => try self.opLoad(.i64, 2), // i64.load32_s
            0x35 => try self.opLoad(.i64, 2), // i64.load32_u

            // Stores
            0x36 => try self.opStore(.i32, 2), // i32.store
            0x37 => try self.opStore(.i64, 3), // i64.store
            0x38 => try self.opStore(.f32, 2), // f32.store
            0x39 => try self.opStore(.f64, 3), // f64.store
            0x3A => try self.opStore(.i32, 0), // i32.store8
            0x3B => try self.opStore(.i32, 1), // i32.store16
            0x3C => try self.opStore(.i64, 0), // i64.store8
            0x3D => try self.opStore(.i64, 1), // i64.store16
            0x3E => try self.opStore(.i64, 2), // i64.store32

            // memory.size / memory.grow (each carries a reserved 0x00 byte)
            0x3F => try self.opMemorySize(),
            0x40 => try self.opMemoryGrow(),

            // Constants
            0x41 => try self.opIxxConst(.i32),
            0x42 => try self.opIxxConst(.i64),
            0x43 => try self.opFxxConst(.f32),
            0x44 => try self.opFxxConst(.f64),

            // i32 testop / relops
            0x45 => try self.opTestop(.i32),
            0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F => try self.opRelop(.i32),

            // i64 testop / relops
            0x50 => try self.opTestop(.i64),
            0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A => try self.opRelop(.i64),

            // f32 / f64 relops
            0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60 => try self.opRelop(.f32),
            0x61, 0x62, 0x63, 0x64, 0x65, 0x66 => try self.opRelop(.f64),

            // Unops + binops by group
            0x67, 0x68, 0x69 => try self.opUnop(.i32),
            0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78 => try self.opBinop(.i32),
            0x79, 0x7A, 0x7B => try self.opUnop(.i64),
            0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A => try self.opBinop(.i64),
            0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91 => try self.opUnop(.f32),
            0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98 => try self.opBinop(.f32),
            0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F => try self.opUnop(.f64),
            0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 => try self.opBinop(.f64),

            // Numeric conversions (from → to)
            0xA7 => try self.opCvt(.i64, .i32), // wrap
            0xA8, 0xA9 => try self.opCvt(.f32, .i32),
            0xAA, 0xAB => try self.opCvt(.f64, .i32),
            0xAC, 0xAD => try self.opCvt(.i32, .i64),
            0xAE, 0xAF => try self.opCvt(.f32, .i64),
            0xB0, 0xB1 => try self.opCvt(.f64, .i64),
            0xB2, 0xB3 => try self.opCvt(.i32, .f32),
            0xB4, 0xB5 => try self.opCvt(.i64, .f32),
            0xB6 => try self.opCvt(.f64, .f32), // demote
            0xB7, 0xB8 => try self.opCvt(.i32, .f64),
            0xB9, 0xBA => try self.opCvt(.i64, .f64),
            0xBB => try self.opCvt(.f32, .f64), // promote
            0xBC => try self.opCvt(.f32, .i32), // reinterpret
            0xBD => try self.opCvt(.f64, .i64),
            0xBE => try self.opCvt(.i32, .f32),
            0xBF => try self.opCvt(.i64, .f64),

            // Wasm 2.0 sign extension (§9.2 / 2.3 chunk 1)
            0xC0, 0xC1 => try self.opUnop(.i32),
            0xC2, 0xC3, 0xC4 => try self.opUnop(.i64),

            // Wasm 2.0 reference types (§9.2 / 2.3 chunk 5)
            0xD0 => try self.opRefNull(),
            0xD1 => try self.opRefIsNull(),
            0xD2 => try self.opRefFunc(),

            // Wasm 3.0 GC §3.3.5.2 — ref.eq is the single-byte 0xD3 (NOT
            // 0xFB 0x13, which is array.init_elem; cyc156 mis-numbering fix).
            0xD3 => try self.opRefEq(),

            // Wasm 3.0 typed function references (function-references proposal).
            0xD4 => try self.opRefAsNonNull(),
            0xD5 => try self.opBrOnNull(),
            0xD6 => try self.opBrOnNonNull(),
            0x14 => try self.opCallRef(),
            0x15 => try self.opReturnCallRef(),

            // Wasm 2.0 prefix opcodes (§9.2 / 2.3 chunk 2 onward)
            0xFC => try self.dispatchPrefixFC(),

            // Wasm 3.0 GC prefix.
            0xFB => try self.dispatchPrefixFB(),

            // Wasm SIMD-128 prefix (§9.9 / Phase 9 per ADR-0041).
            // The validator dispatches inline (mirroring 0xFC's
            // shape) per ADR-0041 Revision 2 — the central
            // DispatchTable's validator slot is not consumed
            // today; that's a Phase 14+ structural refactor.
            0xFD => try validator_simd.dispatchPrefixFD(self),

            // Wasm threads/atomics prefix (0xFE, ADR-0168). Sub-opcode
            // is uleb32; single-threaded substrate validates the ops
            // like their plain memory counterparts (alignment lands
            // per-op in later chunks).
            0xFE => try self.dispatchPrefixFE(),

            else => return Error.NotImplemented,
        }
    }

    // ----------------------------------------------------------------
    // Opcode handlers
    // ----------------------------------------------------------------

    fn opUnreachable(self: *Validator) Error!void {
        self.markUnreachable();
    }

    /// Wasm 3.0 EH §3.3.10.6 — `try_table blocktype vec(catch) ...
    /// end`. Pushes a `.try_table` control frame; body validates
    /// like `block`. The catch vec is validated for label-index
    /// range (each catch's branch target must reference an
    /// existing outer label) but NOT for label-type compatibility
    /// — full type checking lands at 10.E-5 alongside the interp
    /// unwind path. Catch encoding per §4.5: 0x00 catch / 0x01
    /// catch_ref carry tag_idx + label_idx; 0x02 catch_all / 0x03
    /// catch_all_ref carry label_idx only.
    /// Wasm spec 3.0 §3.3.10.7 — `throw tag_idx`: raise an
    /// exception with the tag's payload. Range-checks tag_idx
    /// against `self.tags`, looks up the tag's typeidx →
    /// `module_types[typeidx]`, pops the params (last-first)
    /// from the operand stack, then marks unreachable
    /// (terminator).
    fn opThrow(self: *Validator) Error!void {
        const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (tag_idx >= self.tags.len) return Error.InvalidTagIndex;
        const tag = self.tags[tag_idx];
        if (tag.typeidx >= self.module_types.len) return Error.InvalidFuncIndex;
        const ft = self.module_types[tag.typeidx];
        try self.popLabelTypes(blockTypeOfSlice(ft.params));
        self.markUnreachable();
    }

    /// Wasm spec 3.0 §3.3.10.8 — `throw_ref`: re-raise an
    /// exception via an `exnref` on the operand stack.
    /// Polymorphic-stack from here. v2.0 catalogue can't express
    /// the (ref null exn) type so we accept any reftype as the
    /// popped value (same caveat as 10.R-1..5 typed-ref
    /// catalogue limitation).
    fn opThrowRef(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) {
                self.mismatch = .{ .expected_ref = t };
                return Error.StackTypeMismatch;
            },
        }
        self.markUnreachable();
    }

    fn opTryTable(self: *Validator) Error!void {
        const bt = try self.readBlockType();
        try self.validateCatchVec();
        try self.popLabelTypes(bt.start);
        try self.pushFrame(.try_table, bt.start, bt.end);
        switch (bt.start) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    /// Validates a try_table's catch vec. Per Wasm 3.0 EH §3.3.10.6,
    /// each clause's branched-to label must accept the clause's
    /// pushed types:
    ///   - `catch tag depth`        → pushes `tag.params`
    ///   - `catch_ref tag depth`    → pushes `tag.params ++ [exnref]`
    ///   - `catch_all depth`        → pushes `[]`
    ///   - `catch_all_ref depth`    → pushes `[exnref]`
    /// Mismatch → `StackTypeMismatch`. (Tag-index + label-index
    /// range checks subsume the prior pre-cycle-61 surface.)
    ///
    /// `catch_ref` / `catch_all_ref` push an `exnref` as the last
    /// pushed value. Since cycle 112 landed `ValType.exnref` (bare
    /// `0x69`), these match structurally against the branch target's
    /// label type via `labelTypeEqParamsPlusExn` (was a blanket
    /// reject while `exnref` was un-decodable).
    fn validateCatchVec(self: *Validator) Error!void {
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const kind = self.body[self.pos];
            self.pos += 1;
            switch (kind) {
                0x00 => {
                    // catch tag depth — pushes tag.params (= func type's
                    // params; results are required to be empty per spec
                    // but enforced at tag-decode time).
                    const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (tag_idx >= self.tags.len) return Error.InvalidTagIndex;
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    const expected = target.labelType();
                    const typeidx = self.tags[tag_idx].typeidx;
                    if (typeidx >= self.module_types.len) return Error.InvalidTagIndex;
                    const tag_params = self.module_types[typeidx].params;
                    const pushed = blockTypeOfSlice(tag_params);
                    if (!labelTypesEq(pushed, expected)) return Error.StackTypeMismatch;
                },
                0x01 => {
                    // catch_ref tag depth — pushes tag.params ++ [exnref]
                    const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (tag_idx >= self.tags.len) return Error.InvalidTagIndex;
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    const typeidx = self.tags[tag_idx].typeidx;
                    if (typeidx >= self.module_types.len) return Error.InvalidTagIndex;
                    const tag_params = self.module_types[typeidx].params;
                    if (!labelTypeEqParamsPlusExn(target.labelType(), tag_params)) return Error.StackTypeMismatch;
                },
                0x02 => {
                    // catch_all depth — pushes []
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    if (!labelTypesEq(.empty, target.labelType())) return Error.StackTypeMismatch;
                },
                0x03 => {
                    // catch_all_ref depth — pushes [exnref] (no tag params)
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    if (!labelTypeEqParamsPlusExn(target.labelType(), &.{})) return Error.StackTypeMismatch;
                },
                else => return Error.BadBlockType,
            }
        }
    }

    fn opBlock(self: *Validator, kind: BlockKind) Error!void {
        const bt = try self.readBlockType();
        // Wasm 2.0 §3.4.4: pop params from the outer stack (verifying
        // their types), push frame at the post-pop height, then re-
        // push params as the block body's initial operand stack so the
        // body sees them.
        try self.popLabelTypes(bt.start);
        try self.pushFrame(kind, bt.start, bt.end);
        switch (bt.start) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opIf(self: *Validator) Error!void {
        const bt = try self.readBlockType();
        // The cond i32 is popped *before* the params (it lives above
        // them on the outer stack — Wasm 2.0 §3.4.4 specifies the
        // structured-control encoding pops the cond first).
        try self.popExpect(.i32);
        try self.popLabelTypes(bt.start);
        try self.pushFrame(.if_then, bt.start, bt.end);
        switch (bt.start) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opElse(self: *Validator) Error!void {
        const frame = self.topFrame();
        if (frame.kind != .if_then) return Error.UnexpectedOpcode;
        // Verify the if-branch produced the expected end types.
        try self.expectFrameEndTypes(frame.*);
        // Reset stack to entry height; alternate branch starts fresh.
        self.operand_len = frame.height;
        frame.kind = .else_open;
        frame.unreachable_flag = false;
        // D-459: the else-arm starts from the if's ENTRY init-set — sets made
        // in the then-arm do not carry into the else-arm (Wasm 3.0 §3.3.1).
        self.restoreInitMask(frame.init_mask_at_entry);
        // D-093 (d-10) — Wasm spec §3.4.4: the else-arm starts with
        // the if-frame's `start` (param) types pushed back onto the
        // operand stack (same shape the then-arm saw at entry).
        // Pre-d-10 omitted this, surfacing as `if.wast:param`
        // StackUnderflow because the else-arm body's `(i32.add)`
        // expected param + const but found only const.
        // `start_type` mirrors `BlockType bt.start` from opIf — for
        // Wasm 1.0 blocktypes it's `.empty`; for Wasm 2.0 typeidx
        // blocktypes it's `blockTypeOfSlice(ft.params)`.
        switch (frame.start_type) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opEnd(self: *Validator) Error!void {
        const frame = self.topFrame().*;
        // §9.9 / 9.9-l-1b-d093-d81 — Wasm spec §3.3.5
        // "ifelse" validation: an `if` block without an `else`
        // is equivalent to an empty `else` body. For the empty
        // else to be type-correct, the `if`'s start type
        // (params) must equal its end type (results). Drains
        // `if` corpus SKIP-VALIDATOR-GAP entries where
        // `if (result T)` lacks an else branch.
        if (frame.kind == .if_then) {
            if (!labelTypesEq(frame.start_type, frame.end_type)) {
                return Error.StackTypeMismatch;
            }
        }
        try self.expectFrameEndTypes(frame);
        self.control_len -= 1;
        // D-459: sets inside this block/loop/if do not escape it — restore the
        // non-defaultable locals' init-set to the frame's entry snapshot.
        self.restoreInitMask(frame.init_mask_at_entry);
        // Restore stack height to entry, then push the frame's end types.
        self.operand_len = frame.height;
        switch (frame.endType()) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opBr(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        try self.popLabelTypes(target.labelType());
        self.markUnreachable();
    }

    fn opReturn(self: *Validator) Error!void {
        // Function frame is always at depth control_len - 1 (index 0 in our buffer).
        const fn_frame = &self.control_buf[0];
        try self.popLabelTypes(fn_frame.end_type);
        self.markUnreachable();
    }

    fn popLabelTypes(self: *Validator, lt: BlockType) Error!void {
        switch (lt) {
            .empty => {},
            .single => |t| try self.popExpect(t),
            .multi => |ts| {
                var i: usize = ts.len;
                while (i > 0) {
                    i -= 1;
                    try self.popExpect(ts[i]);
                }
            },
        }
    }

    fn opDrop(self: *Validator) Error!void {
        _ = try self.popAny();
    }

    fn opLocalGet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const t = self.localType(idx) orelse return Error.InvalidLocalIndex;
        // cyc195 — non-defaultable local read before set is invalid (skipped
        // in unreachable/dead code, which is validation-permissive).
        if (self.track_local_init and idx < self.n_locals_total and
            !self.locals_init[idx] and !self.topFrame().unreachable_flag)
        {
            return Error.UninitializedLocal;
        }
        try self.pushType(t);
    }

    fn opLocalSet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const t = self.localType(idx) orelse return Error.InvalidLocalIndex;
        try self.popExpect(t);
        self.markLocalInit(idx);
    }

    fn opLocalTee(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const t = self.localType(idx) orelse return Error.InvalidLocalIndex;
        try self.popExpect(t);
        self.markLocalInit(idx); // tee writes the local before pushing
        try self.pushType(t);
    }

    /// cyc195 — mark a local definitely-set (grow-only; reachable code only,
    /// so a dead-code set can't satisfy a later live read).
    fn markLocalInit(self: *Validator, idx: u32) void {
        if (self.track_local_init and idx < self.n_locals_total and
            !self.topFrame().unreachable_flag)
        {
            self.locals_init[idx] = true;
        }
    }

    /// D-459 — snapshot the current init-set of the (≤64) non-defaultable
    /// locals into a u64 (bit i ↔ `nondefault_idx[i]`). Captured at frame
    /// entry; 0 when there are none (the common case → no-op).
    fn currentInitMask(self: *const Validator) u64 {
        var mask: u64 = 0;
        var i: u32 = 0;
        while (i < self.n_nondefault) : (i += 1) {
            if (self.locals_init[self.nondefault_idx[i]]) mask |= @as(u64, 1) << @intCast(i);
        }
        return mask;
    }

    /// D-459 — restore the non-defaultable locals' init bits from a frame's
    /// entry mask (discards sets made inside the just-closed structured block,
    /// per Wasm 3.0 §3.3.1 — sets do not escape block/loop/if).
    fn restoreInitMask(self: *Validator, mask: u64) void {
        var i: u32 = 0;
        while (i < self.n_nondefault) : (i += 1) {
            self.locals_init[self.nondefault_idx[i]] = (mask >> @intCast(i)) & 1 == 1;
        }
    }

    fn opGlobalGet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.globals.len) return Error.InvalidGlobalIndex;
        try self.pushType(self.globals[idx].valtype);
    }

    fn opGlobalSet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.globals.len) return Error.InvalidGlobalIndex;
        const g = self.globals[idx];
        if (!g.mutable) return Error.ImmutableGlobal;
        try self.popExpect(g.valtype);
    }

    fn opIxxConst(self: *Validator, t: ValType) Error!void {
        // Skip the signed leb128 immediate (we do not range-check the
        // value here — that is the lowerer's concern in 1.6).
        if (t == .i32) {
            _ = try leb128.readSleb128(i32, self.body, &self.pos);
        } else {
            _ = try leb128.readSleb128(i64, self.body, &self.pos);
        }
        try self.pushType(t);
    }

    fn opFxxConst(self: *Validator, t: ValType) Error!void {
        const width: usize = if (t == .f32) 4 else 8;
        if (self.body.len - self.pos < width) return Error.UnexpectedEnd;
        self.pos += width;
        try self.pushType(t);
    }

    fn opTestop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.pushType(.i32);
    }

    fn opUnop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.pushType(t);
    }

    fn opBinop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.popExpect(t);
        try self.pushType(t);
    }

    fn opRelop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.popExpect(t);
        try self.pushType(.i32);
    }

    fn opCvt(self: *Validator, from: ValType, to: ValType) Error!void {
        try self.popExpect(from);
        try self.pushType(to);
    }

    /// Dispatch the Wasm 2.0+ prefix-0xFC opcode group. Sub-opcodes
    /// 0..7 are saturating truncations (§9.2 / 2.3 chunk 2); 10/11
    /// are memory.copy/memory.fill (chunk 4); 8/9/12+ land in later
    /// chunks (data section / table section dependencies).
    /// Encoding: 0xFC <uleb32 sub-opcode>.
    /// Wasm 3.0 GC prefix (0xFB). Dispatches i31 sub-trio (28-30)
    /// + ref.test / ref.test_null (20 / 21; 10.G op_gc cycle 7)
    /// + ref.cast / ref.cast_null (22 / 23; 10.G op_gc cycle 8)
    /// + br_on_cast / br_on_cast_fail (24 / 25; 10.G op_gc cycle 9)
    /// + any.convert_extern / extern.convert_any (26 / 27; 10.G op_gc
    /// cycle 10); other GC sub-opcodes light up per 10.G heap /
    /// struct / array sub-chunks.
    fn dispatchPrefixFB(self: *Validator) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            // struct.new (sub-op 0): pop field-count Values per
            // declared struct, push .structref.
            0 => try self.opStructNew(false),
            // struct.new_default (sub-op 1): no pops, just typeidx;
            // push .structref.
            1 => try self.opStructNew(true),
            // struct.get (sub-op 2): pop structref, push field valtype.
            // Packed-type fields (i8/i16) reject — caller must use
            // struct.get_s/_u for those (deferred per ADR-0121 D3).
            2 => try self.opStructGet(),
            // struct.get_s / struct.get_u (sub-ops 3/4): packed-type
            // (i8/i16) field read, sign-/zero-extended to i32 (ADR-0125).
            3, 4 => try self.opStructGetPacked(),
            // struct.set (sub-op 5): pop value + structref, push nothing.
            5 => try self.opStructSet(),
            // array.new (sub-op 6): pop init Value + i32 size, push arrayref.
            6 => try self.opArrayNew(.with_init),
            // array.new_default (sub-op 7): pop i32 size only, push arrayref.
            7 => try self.opArrayNew(.default),
            // array.new_fixed (sub-op 8): pop N init values, push arrayref.
            8 => try self.opArrayNewFixed(),
            9 => try self.opArrayNewSeg(.data), // array.new_data $t $d
            10 => try self.opArrayNewSeg(.elem), // array.new_elem $t $e
            // array.get (sub-op 11): pop i32 idx + arrayref, push element.
            11 => try self.opArrayGet(),
            // array.get_s / array.get_u (sub-ops 12/13): packed element
            // (i8/i16) read, sign-/zero-extended to i32 (ADR-0125).
            12, 13 => try self.opArrayGetPacked(),
            // array.set (sub-op 14): pop value + i32 idx + arrayref.
            14 => try self.opArraySet(),
            // array.fill (sub-op 16): pop count + value + i32 idx + arrayref.
            16 => try self.opArrayFill(),
            // array.len (Wasm 3.0 GC §3.3.5.6.13): pop arrayref, push i32.
            15 => try self.opArrayLen(),
            // array.copy (sub-op 17): dst $t + src $t; pop len + src_off +
            // src_ref + dst_off + dst_ref (10.G cycle 157).
            17 => try self.opArrayCopy(),
            // array.init_data (18) / array.init_elem (19): segment → array
            // bulk init (10.G cycle 158). ref.eq is 0xD3, not 19.
            18 => try self.opArrayInitSeg(.data),
            19 => try self.opArrayInitSeg(.elem),
            // ref.test / ref.test_null share validator shape:
            // consume heap_type byte, pop reftype, push i32.
            20, 21 => try self.opRefTest(),
            // ref.cast (non-null target) / ref.cast_null (nullable):
            // consume heap_type byte, pop reftype, push the cast TARGET.
            22 => try self.opRefCast(false),
            23 => try self.opRefCast(true),
            // br_on_cast / br_on_cast_fail share validator shape:
            // consume flags + labelidx + ht1 + ht2, pop reftype,
            // pop+repush label types, push reftype back on fall-through.
            24 => try self.opBrOnCast(false), // br_on_cast
            25 => try self.opBrOnCast(true), // br_on_cast_fail
            // any.convert_extern (26): pop externref, push anyref.
            26 => try self.opConvertRef(.externref, .anyref),
            // extern.convert_any (27): pop anyref, push externref.
            27 => try self.opConvertRef(.anyref, .externref),
            28 => try self.opRefI31(),
            29, 30 => try self.opI31Get(), // .get_s / .get_u share validator shape
            else => return Error.NotImplemented,
        }
    }

    /// Dispatch the Wasm threads/atomics prefix-0xFE opcode group
    /// (ADR-0168). Encoding: 0xFE <uleb32 sub-opcode>. Sub-op 0x03 =
    /// atomic.fence (single reserved 0x00 byte, no stack effect);
    /// 0x00..0x02 = notify/wait, 0x10+ = load/store/rmw/cmpxchg —
    /// those land per-op in later chunks.
    fn dispatchPrefixFE(self: *Validator) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            // memory.atomic.notify (natural align 2 = 4B) / wait32
            // (align 2) / wait64 (align 3) — threads §valid: EXACT
            // natural align + a memory. Shared-ness is a RUNTIME
            // property (wait traps on non-shared), not a validation
            // constraint, so these validate on any memory.
            0x00 => try self.opAtomicNotify(),
            0x01 => try self.opAtomicWait(.i32, 2),
            0x02 => try self.opAtomicWait(.i64, 3),
            // atomic.fence: read the reserved memory-order byte (MUST
            // be 0x00 per threads spec §binary; "nonzero byte after
            // atomic.fence" is malformed). No operand stack effect,
            // no memory required ("no memory is ok").
            0x03 => {
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                const reserved = self.body[self.pos];
                self.pos += 1;
                if (reserved != 0x00) return Error.InvalidOpcode;
            },
            // i32.atomic.load (natural align = 2): pop addr → push i32.
            0x10 => try self.opAtomicLoad(.i32, 2),
            0x11 => try self.opAtomicLoad(.i64, 3), // i64.atomic.load (natural align 3 = 8B)
            0x12 => try self.opAtomicLoad(.i32, 0), // i32.atomic.load8_u
            0x13 => try self.opAtomicLoad(.i32, 1), // i32.atomic.load16_u
            0x14 => try self.opAtomicLoad(.i64, 0), // i64.atomic.load8_u
            0x15 => try self.opAtomicLoad(.i64, 1), // i64.atomic.load16_u
            0x16 => try self.opAtomicLoad(.i64, 2), // i64.atomic.load32_u
            0x17 => try self.opAtomicStore(.i32, 2), // i32.atomic.store
            0x18 => try self.opAtomicStore(.i64, 3), // i64.atomic.store
            0x19 => try self.opAtomicStore(.i32, 0), // i32.atomic.store8
            0x1A => try self.opAtomicStore(.i32, 1), // i32.atomic.store16
            0x1B => try self.opAtomicStore(.i64, 0), // i64.atomic.store8
            0x1C => try self.opAtomicStore(.i64, 1), // i64.atomic.store16
            0x1D => try self.opAtomicStore(.i64, 2), // i64.atomic.store32
            0x1E => try self.opAtomicRmw(.i32, 2), // i32.atomic.rmw.add
            0x1F => try self.opAtomicRmw(.i64, 3), // i64.atomic.rmw.add
            0x20 => try self.opAtomicRmw(.i32, 0), // i32.atomic.rmw8.add_u
            0x21 => try self.opAtomicRmw(.i32, 1), // i32.atomic.rmw16.add_u
            0x22 => try self.opAtomicRmw(.i64, 0), // i64.atomic.rmw8.add_u
            0x23 => try self.opAtomicRmw(.i64, 1), // i64.atomic.rmw16.add_u
            0x24 => try self.opAtomicRmw(.i64, 2), // i64.atomic.rmw32.add_u
            0x25 => try self.opAtomicRmw(.i32, 2), // i32.atomic.rmw.sub
            0x26 => try self.opAtomicRmw(.i64, 3), // i64.atomic.rmw.sub
            0x27 => try self.opAtomicRmw(.i32, 0), // i32.atomic.rmw8.sub_u
            0x28 => try self.opAtomicRmw(.i32, 1), // i32.atomic.rmw16.sub_u
            0x29 => try self.opAtomicRmw(.i64, 0), // i64.atomic.rmw8.sub_u
            0x2A => try self.opAtomicRmw(.i64, 1), // i64.atomic.rmw16.sub_u
            0x2B => try self.opAtomicRmw(.i64, 2), // i64.atomic.rmw32.sub_u
            0x2C => try self.opAtomicRmw(.i32, 2), // i32.atomic.rmw.and
            0x2D => try self.opAtomicRmw(.i64, 3), // i64.atomic.rmw.and
            0x2E => try self.opAtomicRmw(.i32, 0), // i32.atomic.rmw8.and_u
            0x2F => try self.opAtomicRmw(.i32, 1), // i32.atomic.rmw16.and_u
            0x30 => try self.opAtomicRmw(.i64, 0), // i64.atomic.rmw8.and_u
            0x31 => try self.opAtomicRmw(.i64, 1), // i64.atomic.rmw16.and_u
            0x32 => try self.opAtomicRmw(.i64, 2), // i64.atomic.rmw32.and_u
            0x33 => try self.opAtomicRmw(.i32, 2), // i32.atomic.rmw.or
            0x34 => try self.opAtomicRmw(.i64, 3), // i64.atomic.rmw.or
            0x35 => try self.opAtomicRmw(.i32, 0), // i32.atomic.rmw8.or_u
            0x36 => try self.opAtomicRmw(.i32, 1), // i32.atomic.rmw16.or_u
            0x37 => try self.opAtomicRmw(.i64, 0), // i64.atomic.rmw8.or_u
            0x38 => try self.opAtomicRmw(.i64, 1), // i64.atomic.rmw16.or_u
            0x39 => try self.opAtomicRmw(.i64, 2), // i64.atomic.rmw32.or_u
            0x3A => try self.opAtomicRmw(.i32, 2), // i32.atomic.rmw.xor
            0x3B => try self.opAtomicRmw(.i64, 3), // i64.atomic.rmw.xor
            0x3C => try self.opAtomicRmw(.i32, 0), // i32.atomic.rmw8.xor_u
            0x3D => try self.opAtomicRmw(.i32, 1), // i32.atomic.rmw16.xor_u
            0x3E => try self.opAtomicRmw(.i64, 0), // i64.atomic.rmw8.xor_u
            0x3F => try self.opAtomicRmw(.i64, 1), // i64.atomic.rmw16.xor_u
            0x40 => try self.opAtomicRmw(.i64, 2), // i64.atomic.rmw32.xor_u
            0x41 => try self.opAtomicRmw(.i32, 2), // i32.atomic.rmw.xchg
            0x42 => try self.opAtomicRmw(.i64, 3), // i64.atomic.rmw.xchg
            0x43 => try self.opAtomicRmw(.i32, 0), // i32.atomic.rmw8.xchg_u
            0x44 => try self.opAtomicRmw(.i32, 1), // i32.atomic.rmw16.xchg_u
            0x45 => try self.opAtomicRmw(.i64, 0), // i64.atomic.rmw8.xchg_u
            0x46 => try self.opAtomicRmw(.i64, 1), // i64.atomic.rmw16.xchg_u
            0x47 => try self.opAtomicRmw(.i64, 2), // i64.atomic.rmw32.xchg_u
            0x48 => try self.opAtomicCmpxchg(.i32, 2),
            0x49 => try self.opAtomicCmpxchg(.i64, 3),
            0x4A => try self.opAtomicCmpxchg(.i32, 0),
            0x4B => try self.opAtomicCmpxchg(.i32, 1),
            0x4C => try self.opAtomicCmpxchg(.i64, 0),
            0x4D => try self.opAtomicCmpxchg(.i64, 1),
            0x4E => try self.opAtomicCmpxchg(.i64, 2),
            else => return Error.NotImplemented,
        }
    }

    /// Wasm spec 3.0 §3.3.5.3 — `ref.test heap_type` /
    /// `ref.test_null heap_type`: consume the SLEB128 heap_type
    /// immediate (D-453: a concrete idx ≥ 64 is multi-byte — decode
    /// to advance pos past the full immediate, not one byte); pop
    /// reftype; push i32.
    fn opRefTest(self: *Validator) Error!void {
        // `readTypedRef` validates well-formedness + advances pos past the
        // full SLEB (the result type itself is unused here — ref.test pushes
        // i32). `nullable` is immaterial to advancing; pass false.
        _ = init_expr.readTypedRef(self.body, &self.pos, false) catch return Error.BadValType;
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) {
                self.mismatch = .{ .expected_ref = t };
                return Error.StackTypeMismatch;
            },
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.4 — `ref.cast (ref ht)` / `ref.cast null
    /// (ref null ht)`: pop a reftype; push the cast TARGET reftype
    /// `(ref ht)` (non-null) or `(ref null ht)` (nullable). The target
    /// type — not the wider operand — is what flows on; a block result
    /// like `(result (ref null $t))` fed by `(ref.cast (ref $t) …)`
    /// requires this narrowing (gc/type-subtyping.17). `null` heap-type
    /// byte (multi-byte index, not stored by lower) falls back to the
    /// operand type.
    fn opRefCast(self: *Validator, nullable: bool) Error!void {
        // D-453: the heap_type is an SLEB128 (concrete idx ≥ 64 is multi-
        // byte). `readTypedRef` decodes the full immediate AND yields the
        // cast TARGET reftype directly — `(ref [null] ht)` for both abstract
        // and concrete (idx ≥ 64) targets — replacing the byte-wide
        // `castTargetType`.
        const target = init_expr.readTypedRef(self.body, &self.pos, nullable) catch return Error.BadValType;
        const top = try self.popAny();
        switch (top) {
            .bot => try self.pushBot(),
            .known => |t| {
                if (!t.isRef()) {
                    self.mismatch = .{ .expected_ref = t };
                    return Error.StackTypeMismatch;
                }
                try self.pushType(target);
            },
        }
    }

    /// Wasm spec 3.0 §3.3.5.6.1 — `struct.new typeidx` /
    /// `struct.new_default typeidx`: allocate a struct of the
    /// declared type. `struct.new` pops one Value per field (in
    /// reverse declared order so the topmost stack entry is the
    /// last field); `struct.new_default` skips the pops and
    /// zero-inits. Both push `.structref`.
    ///
    /// Pre-RTT cycle-15: the pushed reftype is the abstract
    /// `.structref` rather than a typed `(ref typeidx)` (typed-
    /// ref ValType narrowing lands with RTT TypeInfo per ADR-0116
    /// amendment). Caller-side cast ops re-validate against the
    /// expected concrete type.
    fn opStructNew(self: *Validator, is_default: bool) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .structdef) return Error.InvalidFuncIndex;
        const sd = self.struct_defs[typeidx] orelse return Error.InvalidFuncIndex;
        if (!is_default) {
            // Pop fields in reverse declared order: stack top = last field.
            var i: usize = sd.fields.len;
            while (i > 0) {
                i -= 1;
                try self.popExpect(sd.fields[i].storage.operandType());
            }
        }
        // Wasm 3.0 GC §3.3.5.6.1: struct.new $t : […] -> [(ref $t)] — the
        // result is the CONCRETE non-null typed ref, not abstract structref
        // (so a func returning `(ref $t)` accepts it; subtypeCtx widens to
        // structref/eqref/anyref slots).
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    /// Resolve a (typeidx, fieldidx) pair to a StructDef field. Used
    /// by struct.get / struct.set (cycle 17). Returns InvalidFuncIndex
    /// on unknown typeidx, wrong kind, or out-of-range fieldidx.
    fn lookupStructField(self: *Validator) Error!sections.StructFieldType {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const fieldidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .structdef) return Error.InvalidFuncIndex;
        const sd = self.struct_defs[typeidx] orelse return Error.InvalidFuncIndex;
        if (fieldidx >= sd.fields.len) return Error.InvalidFuncIndex;
        return sd.fields[fieldidx];
    }

    /// Wasm spec 3.0 §3.3.5.6.2 — `struct.get typeidx fieldidx`:
    /// pop structref, push the named field's valtype. Packed-type
    /// fields (i8/i16) rejected here — caller must use struct.get_s
    /// or struct.get_u (ADR-0121 D3 defers packed types).
    fn opStructGet(self: *Validator) Error!void {
        const field = try self.lookupStructField();
        // ADR-0125 — plain struct.get is invalid on a packed field; the
        // module must use struct.get_s / struct.get_u.
        if (field.storage.isPacked()) return Error.PackedFieldAccess;
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            // Accept abstract struct/eq/any heads OR a concrete `(ref $t)`
            // whose typedef is a struct (struct.new now pushes concrete).
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.structref))) return Error.StackTypeMismatch,
        }
        try self.pushType(field.storage.operandType());
    }

    /// Wasm spec 3.0 §3.3.5.6.3 — `struct.get_s` / `struct.get_u
    /// typeidx fieldidx`: pop structref, push i32 (the packed i8/i16
    /// field sign-/zero-extended). Valid ONLY on packed fields (ADR-0125).
    fn opStructGetPacked(self: *Validator) Error!void {
        const field = try self.lookupStructField();
        if (!field.storage.isPacked()) return Error.PackedFieldAccess;
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.structref))) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.6.4 — `struct.set typeidx fieldidx`:
    /// pop value (matching field.storage.operandType()) + pop structref, push
    /// nothing. Field must be mutable.
    fn opStructSet(self: *Validator) Error!void {
        const field = try self.lookupStructField();
        if (!field.mutable) return Error.StackTypeMismatch;
        try self.popExpect(field.storage.operandType());
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.structref))) return Error.StackTypeMismatch,
        }
    }

    /// Resolve typeidx to an ArrayDef (cycle 18 helper). Returns
    /// InvalidFuncIndex on unknown typeidx or non-arraydef kind.
    fn lookupArrayDef(self: *Validator) Error!sections.ArrayDef {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        return self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
    }

    /// Wasm spec 3.0 §3.3.5.6.10 — `array.get typeidx`: pop i32 idx
    /// + arrayref, push element.valtype. Packed types (ADR-0121 D3)
    /// reject via get_s/_u routes in dispatch.
    fn opArrayGet(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        // ADR-0125 — plain array.get is invalid on a packed element.
        if (ad.element.storage.isPacked()) return Error.PackedFieldAccess;
        try self.popExpect(.i32);
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
        try self.pushType(ad.element.storage.operandType());
    }

    /// Wasm spec 3.0 §3.3.5.6.11 — `array.get_s` / `array.get_u
    /// typeidx`: pop i32 idx + arrayref, push i32 (packed i8/i16 element
    /// sign-/zero-extended). Valid ONLY on packed elements (ADR-0125).
    fn opArrayGetPacked(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        if (!ad.element.storage.isPacked()) return Error.PackedFieldAccess;
        try self.popExpect(.i32);
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.6.12 — `array.set typeidx`: pop value
    /// + i32 idx + arrayref. Element type must be mutable.
    fn opArraySet(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        if (!ad.element.mutable) return Error.StackTypeMismatch;
        try self.popExpect(ad.element.storage.operandType());
        try self.popExpect(.i32);
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
    }

    /// Wasm spec 3.0 §3.3.5.6.14 — `array.fill typeidx`: pop count
    /// (i32) + value + i32 idx + arrayref. Element type must be
    /// mutable. Stack effect (top first): count, value, idx, arrayref.
    fn opArrayFill(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        if (!ad.element.mutable) return Error.StackTypeMismatch;
        try self.popExpect(.i32); // count
        try self.popExpect(ad.element.storage.operandType()); // fill value
        try self.popExpect(.i32); // idx
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
    }

    /// True iff array element `src` is assignable to `dst` (covariant, as
    /// storage types): packed-ness must match (i8/i16 invariant), else the
    /// operand valtype must subtype. Mirrors gcFieldSubtype's covariant arm.
    fn arrayElemAssignable(self: *const Validator, src: sections.StructFieldType, dst: sections.StructFieldType) bool {
        if (src.storage.isPacked() != dst.storage.isPacked()) return false;
        if (src.storage.isPacked()) return src.storage.specByte() == dst.storage.specByte();
        return self.subtypeCtx(src.storage.operandType(), dst.storage.operandType());
    }

    fn popArrayRef(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
    }

    /// Wasm spec 3.0 §3.3.5.6.14 — `array.copy dst_typeidx src_typeidx`:
    /// pop [len:i32, src_off:i32, src_ref, dst_off:i32, dst_ref]. dst
    /// element must be mutable; src element must be assignable to dst's.
    fn opArrayCopy(self: *Validator) Error!void {
        const dst = try self.lookupArrayDef(); // dst typeidx (read first)
        const src = try self.lookupArrayDef(); // src typeidx
        if (!dst.element.mutable) return Error.StackTypeMismatch;
        if (!self.arrayElemAssignable(src.element, dst.element)) return Error.StackTypeMismatch;
        try self.popExpect(.i32); // len
        try self.popExpect(.i32); // src_off
        try self.popArrayRef(); // src_ref
        try self.popExpect(.i32); // dst_off
        try self.popArrayRef(); // dst_ref
    }

    /// Wasm spec 3.0 §3.3.5.6.16/17 — `array.init_data $t $d` /
    /// `array.init_elem $t $e`: pop [len:i32, src_off:i32, dst_off:i32,
    /// dst_ref]. $t element mutable; data variant needs a numeric/packed
    /// element + data-count section; elem variant needs the segment
    /// reftype assignable to the element.
    fn opArrayInitSeg(self: *Validator, kind: ArrayNewSegKind) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const segidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        const ad = self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
        if (!ad.element.mutable) return Error.StackTypeMismatch;
        switch (kind) {
            .data => {
                // data segments hold raw bytes → element must be numeric/packed.
                if (ad.element.storage.operandType().isRef()) return Error.StackTypeMismatch;
                if (!self.data_count_section_present) return Error.UnknownMemory;
                if (segidx >= self.data_count) return Error.InvalidFuncIndex;
            },
            .elem => {
                if (segidx >= self.elem_count) return Error.InvalidFuncIndex;
                if (segidx < self.elem_types.len and !self.subtypeCtx(self.elem_types[segidx], ad.element.storage.operandType())) return Error.StackTypeMismatch;
            },
        }
        try self.popExpect(.i32); // len
        try self.popExpect(.i32); // src_off
        try self.popExpect(.i32); // dst_off
        try self.popArrayRef(); // dst_ref
    }

    const ArrayNewVariant = enum { with_init, default };

    /// Wasm spec 3.0 §3.3.5.6.6 — `array.new typeidx` /
    /// `array.new_default typeidx`: allocate an array of the
    /// declared element type. `array.new` pops one init Value
    /// (matching ArrayDef.element.valtype) + i32 size; the
    /// `_default` variant skips the init pop. Both push `.arrayref`.
    ///
    /// Pre-RTT cycle-16: the pushed reftype is the abstract
    /// `.arrayref`; typed-ref ValType narrowing lands with RTT
    /// (ADR-0116 amendment).
    fn opArrayNew(self: *Validator, variant: ArrayNewVariant) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        const ad = self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
        // Pop order on the stack (top first): size:i32, then init (if any).
        try self.popExpect(.i32);
        if (variant == .with_init) {
            try self.popExpect(ad.element.storage.operandType());
        }
        // Wasm 3.0 GC: array.new $t : […] -> [(ref $t)] (concrete, non-null);
        // subtypeCtx widens it to arrayref/eqref/anyref slots (cycle 137).
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    /// Wasm spec 3.0 §3.3.5.6.8 — `array.new_fixed typeidx N`:
    /// allocate an N-element array of the declared element type;
    /// pop N init Values (last array element on top), push
    /// `.arrayref`. N is an in-stream uleb32 immediate (not a
    /// typeidx-side length).
    fn opArrayNewFixed(self: *Validator) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        const ad = self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
        const n = try leb128.readUleb128(u32, self.body, &self.pos);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try self.popExpect(ad.element.storage.operandType());
        }
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    const ArrayNewSegKind = enum { data, elem };

    /// Wasm 3.0 GC §3.3.5.6.7/8 — `array.new_data $t $d` /
    /// `array.new_elem $t $e`: pop `[offset:i32, size:i32]`, build a new
    /// array of type `$t` whose elements come from data segment `$d`
    /// (data) / element segment `$e` (elem); push the concrete `(ref $t)`.
    /// Validate-only this cut: typeidx is arraydef, segment index in
    /// range (data needs the DataCount section, mirroring memory.init);
    /// runtime copy lands in the exec follow-on.
    fn opArrayNewSeg(self: *Validator, kind: ArrayNewSegKind) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const segidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        if (self.array_defs[typeidx] == null) return Error.InvalidFuncIndex;
        switch (kind) {
            .data => {
                if (!self.data_count_section_present) return Error.UnknownMemory;
                if (segidx >= self.data_count) return Error.InvalidFuncIndex;
            },
            .elem => if (segidx >= self.elem_count) return Error.InvalidFuncIndex,
        }
        try self.popExpect(.i32); // size
        try self.popExpect(.i32); // offset
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    /// Wasm spec 3.0 §3.3.5.6.13 — `array.len`: pop an arrayref
    /// (`(ref null array)`), push i32. Pre-RTT we accept any
    /// reftype on the operand (the spec restricts to arrayref-
    /// subtypes; runtime traps NullReference until array creation
    /// ops land).
    fn opArrayLen(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) {
                self.mismatch = .{ .expected_ref = t };
                return Error.StackTypeMismatch;
            },
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.2 — `ref.eq`: pop two operands, each a
    /// subtype of `eqref` (the internal-eq hierarchy: i31 / struct /
    /// array / eq / none — NOT func / extern / any), push i32. Operands
    /// outside the eq hierarchy (funcref, externref, anyref) are a type
    /// error (cyc156 — was a lenient any-ref accept that let the
    /// ref_eq invalid fixtures through).
    fn opRefEq(self: *Validator) Error!void {
        var i: u32 = 0;
        while (i < 2) : (i += 1) {
            const top = try self.popAny();
            switch (top) {
                .bot => {},
                .known => |t| if (!self.subtypeCtx(t, ValType.eqref)) return Error.StackTypeMismatch,
            }
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.7 — `any.convert_extern` /
    /// `extern.convert_any`: reinterpret a reftype between the
    /// `any` and `extern` hierarchies. Stack effect: pop `from`,
    /// push `to`. Pre-RTT both directions are unconditional (no
    /// runtime check); the validator narrows the type for the
    /// fall-through, mirroring the spec's static signature.
    fn opConvertRef(self: *Validator, from: ValType, to: ValType) Error!void {
        try self.popExpect(from);
        try self.pushType(to);
    }

    /// Wasm spec 3.0 §3.3.5.5 — `br_on_cast flags l ht1 ht2` /
    /// `br_on_cast_fail flags l ht1 ht2`. Immediate: flags (bit 0 = ht1
    /// nullable, bit 1 = ht2 nullable) + labelidx (uleb32) + ht1 + ht2
    /// (heap-type encodings). `rt1 = (ref null1? ht1)` is the source
    /// type; `rt2 = (ref null2? ht2)` is the cast target.
    ///
    /// `br_on_cast` branches to l when the operand matches rt2 (carrying
    /// rt2), and falls through with `rt1 \ rt2`. `br_on_cast_fail`
    /// inverts it: branches with `rt1 \ rt2`, falls through with rt2.
    /// The difference `rt1 \ rt2` keeps ht1 but drops nullability when
    /// rt2 is nullable (the null case is consumed by the match). The
    /// label's last type must be a supertype of the carried reftype
    /// (subtypeCtx, NOT the cycle-9 stub's `eql(operand)` which wrongly
    /// compared the source operand instead of the cast target).
    fn opBrOnCast(self: *Validator, is_fail: bool) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const flags = self.body[self.pos];
        self.pos += 1;
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        const ht1_nullable = (flags & 0x01) != 0;
        const ht2_nullable = (flags & 0x02) != 0;
        const rt1 = init_expr.readTypedRef(self.body, &self.pos, ht1_nullable) catch return Error.BadValType;
        const rt2 = init_expr.readTypedRef(self.body, &self.pos, ht2_nullable) catch return Error.BadValType;
        // Spec §3.3.5.5 validity: rt2 <: rt1 (the cast target is a
        // subtype of the source) — FULL reftype subtyping, including
        // nullability. Rejects `eqref anyref` / `structref arrayref` /
        // `funcref (ref $struct)` (heap mismatch) AND `(ref any)` source
        // with a `(ref null $t)` target (nullable ⊄ non-null). All six
        // br_on_cast{,_fail} assert_invalid fixtures hinge on this.
        if (!self.subtypeCtx(rt2, rt1)) return Error.StackTypeMismatch;
        // Operand: a ref subtype of rt1 (coarse isRef check pre-RTT).
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) {
                self.mismatch = .{ .expected_ref = t };
                return Error.StackTypeMismatch;
            },
        }
        const diff: ValType = .{ .ref = .{
            .nullable = ht1_nullable and !ht2_nullable,
            .heap_type = rt1.ref.heap_type,
        } };
        const label_carry: ValType = if (is_fail) diff else rt2;
        const fallthrough: ValType = if (is_fail) rt2 else diff;
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        switch (target.labelType()) {
            .empty => return Error.StackTypeMismatch,
            .single => |t| {
                if (!self.subtypeCtx(label_carry, t)) return Error.StackTypeMismatch;
            },
            .multi => |ts| {
                if (ts.len == 0) return Error.StackTypeMismatch;
                if (!self.subtypeCtx(label_carry, ts[ts.len - 1])) return Error.StackTypeMismatch;
                const prefix = ts[0 .. ts.len - 1];
                var i: usize = prefix.len;
                while (i > 0) {
                    i -= 1;
                    try self.popExpect(prefix[i]);
                }
                for (prefix) |t| try self.pushType(t);
            },
        }
        try self.pushType(fallthrough);
    }

    /// Wasm spec 3.0 §3.x (GC) — `ref.i31`: pop i32, push an
    /// i31-tagged reftype. Push `.i31ref` per ADR-0115 §6
    /// Revision 2026-05-29 (cycle 1 of 10.G-op_gc bundle).
    /// Previously stood in with `.funcref` while the typed-ref
    /// catalogue extension was pending; this cycle (5) wires the
    /// proper type so `i31.get_*` validator-pops match.
    fn opRefI31(self: *Validator) Error!void {
        try self.popExpect(.i32);
        // Wasm 3.0 GC: `ref.i31 : [i32] -> [(ref i31)]` — the result is
        // NON-NULL (an i31 ref is never null). Pushing the nullable
        // `.i31ref` abbreviation breaks `global.set` / returns into a
        // non-null `(ref i31)` slot (StackTypeMismatch).
        try self.pushType(.{ .ref = zir.RefType.abs(.i31, false) });
    }

    /// Wasm spec 3.0 §3.x (GC) — `i31.get_s` / `i31.get_u`: pop a
    /// reftype (must be an i31 ref at runtime; runtime checks
    /// `isI31Ref` and traps otherwise), push i32. Validator
    /// shape identical for both ops (sign vs unsign disambiguation
    /// is runtime-side).
    fn opI31Get(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) {
                self.mismatch = .{ .expected_ref = t };
                return Error.StackTypeMismatch;
            },
        }
        try self.pushType(.i32);
    }

    fn dispatchPrefixFC(self: *Validator) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            0, 1 => try self.opCvt(.f32, .i32), // i32.trunc_sat_f32_{s,u}
            2, 3 => try self.opCvt(.f64, .i32), // i32.trunc_sat_f64_{s,u}
            4, 5 => try self.opCvt(.f32, .i64), // i64.trunc_sat_f32_{s,u}
            6, 7 => try self.opCvt(.f64, .i64), // i64.trunc_sat_f64_{s,u}
            8 => try self.opMemoryInit(),
            9 => try self.opDataDrop(),
            12 => try self.opTableInit(),
            13 => try self.opElemDrop(),
            10 => try self.opMemoryCopy(),
            11 => try self.opMemoryFill(),
            14 => try self.opTableCopy(),
            15 => try self.opTableGrow(),
            16 => try self.opTableSize(),
            17 => try self.opTableFill(),
            // Wasm wide-arithmetic (ADR-0168 v0.2): i64.add128 (19) /
            // sub128 (20) = 4 i64 → 2 i64 (128-bit lo,hi pairs);
            // mul_wide_s (21) / mul_wide_u (22) = 2 i64 → 2 i64.
            19, 20 => try self.opWideAddSub128(),
            21, 22 => try self.opWideMul(),
            else => return Error.NotImplemented,
        }
    }

    /// Wasm wide-arith §valid — `i64.add128` / `i64.sub128`: pop two
    /// 128-bit operands (each lo:i64, hi:i64 = 4 i64) → push the 128-bit
    /// result (lo:i64, hi:i64 = 2 i64).
    fn opWideAddSub128(self: *Validator) Error!void {
        try self.popExpect(.i64);
        try self.popExpect(.i64);
        try self.popExpect(.i64);
        try self.popExpect(.i64);
        try self.pushType(.i64);
        try self.pushType(.i64);
    }

    /// Wasm wide-arith §valid — `i64.mul_wide_s` / `i64.mul_wide_u`:
    /// pop a:i64, b:i64 → push the full 128-bit product (lo:i64, hi:i64).
    fn opWideMul(self: *Validator) Error!void {
        try self.popExpect(.i64);
        try self.popExpect(.i64);
        try self.pushType(.i64);
        try self.pushType(.i64);
    }

    /// memory.copy x y: 0xFC 10 dst_memidx src_memidx. Wasm 3.0
    /// §3.4.7: operand types are [it_dst it_src it_min] where
    /// it_min = i32 if EITHER memory is i32-indexed (mixed
    /// i32/i64 cross-memory copies are valid; D-324). Pops n
    /// (it_min), src (it_src), dst (it_dst); pushes nothing.
    fn opMemoryCopy(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        // 10.M cycle 67 — relax multi-memory: dst + src memidx are
        // now real LEBs (were reserved 0x00). Range-check both
        // against memory_count.
        const dst_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const src_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dst_memidx >= self.memory_count or src_memidx >= self.memory_count) {
            return Error.UnknownMemory;
        }
        const dst_t = self.memIdxTypeAt(dst_memidx);
        const src_t = self.memIdxTypeAt(src_memidx);
        const n_t: ValType = if (dst_t == .i32 or src_t == .i32) .i32 else .i64;
        try self.popExpect(n_t); // n (it_min)
        try self.popExpect(src_t); // src
        try self.popExpect(dst_t); // dst
    }

    /// memory.init: 0xFC 8 dataidx 0x00 (one reserved memidx byte).
    /// Pops three values (n:i32, src:i32, dst:idx_type); pushes
    /// nothing. dataidx must be < module's data segment count.
    /// Wasm 3.0 §3.4.7: dst uses the memory's idx_type (i64 for
    /// memory64); src + n are always i32 (data-segment offsets).
    fn opMemoryInit(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        if (!self.data_count_section_present) return Error.UnknownMemory;
        const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dataidx >= self.data_count) return Error.InvalidFuncIndex;
        // 10.M cycle 67 — relax multi-memory dst memidx LEB
        // (was reserved 0x00). Range-check against memory_count.
        const dst_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dst_memidx >= self.memory_count) return Error.UnknownMemory;
        try self.popExpect(.i32); // n (data-segment byte count)
        try self.popExpect(.i32); // src (data-segment offset)
        try self.popExpect(self.memIdxTypeAt(dst_memidx)); // dst (memory addr)
    }

    /// data.drop: 0xFC 9 dataidx. No operand stack effects.
    fn opDataDrop(self: *Validator) Error!void {
        if (!self.data_count_section_present) return Error.UnknownMemory;
        const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dataidx >= self.data_count) return Error.InvalidFuncIndex;
    }

    /// ref.null heaptype: 0xD0 + heaptype. Heaptype is a single
    /// byte for the 12 abstract heads (Wasm 3.0 §5.3.5) OR a signed
    /// LEB128 type-section index for concrete typed null refs
    /// (function-references proposal §3.3.10.5).
    fn opRefNull(self: *Validator) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const b = self.body[self.pos];
        // Single-byte abstract heads — consume one byte, build the
        // matching abstract `(ref null ht)`.
        const abstract: ?zir.AbstractHeapType = switch (b) {
            0x70 => .func,
            0x6F => .extern_,
            0x6E => .any,
            0x6D => .eq,
            0x6C => .i31,
            0x6B => .struct_,
            0x6A => .array,
            0x69 => .exn,
            0x71 => .none,
            0x72 => .noextern,
            0x73 => .nofunc,
            0x74 => .noexn,
            else => null,
        };
        if (abstract) |ht| {
            self.pos += 1;
            try self.pushType(.{ .ref = .{ .nullable = true, .heap_type = .{ .abstract = ht } } });
            return;
        }
        // Concrete typed null ref: signed LEB128 type-section index
        // (ADR-0123 Cycle 5). Index must be in [0, module_types.len).
        const idx_signed = leb128.readSleb128(i33, self.body, &self.pos) catch return Error.BadValType;
        if (idx_signed < 0) return Error.BadValType;
        const idx: u32 = @intCast(idx_signed);
        if (idx >= self.module_types.len) return Error.BadValType;
        try self.pushType(.{ .ref = .{ .nullable = true, .heap_type = .{ .concrete = idx } } });
    }

    /// ref.is_null: pop any reftype, push i32. Polymorphic over
    /// funcref / externref.
    fn opRefIsNull(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) {
                self.mismatch = .{ .expected_ref = t };
                return Error.StackTypeMismatch;
            },
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.8.5 (function-references proposal):
    /// `ref.as_non_null` — pop reftype; if null, trap at runtime.
    /// Statically, narrows `(ref null T)` to `(ref T)` — same Wasm
    /// valtype here since v2.0 reftype catalogue does NOT yet
    /// model the typed-ref nullability axis (the .funcref /
    /// .externref enum is opaque to nullability). Push the same
    /// reftype back. Validator surface preserves backward-compat
    /// for legacy reftype callers; nullability tightening lands
    /// at 10.G (WasmGC) where `(ref $sig)` typed refs need their
    /// own typed-ref module per `phase10_design_plan_ja.md` §3.2.
    fn opRefAsNonNull(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {
                // Unreachable/polymorphic stack: the result type is
                // unknown, so stay polymorphic (.bot) rather than
                // collapsing to a concrete funcref — else a typed
                // downstream consumer (e.g. `call` expecting `(ref $t)`)
                // mismatches the abstract funcref (ref_as_non_null.0
                // func 6: `unreachable; ref.as_non_null; call 0`).
                try self.pushBot();
            },
            .known => |t| {
                if (!t.isRef()) {
                    self.mismatch = .{ .expected_ref = t };
                    return Error.StackTypeMismatch;
                }
                // ADR-0123 D2 (cycle 93 / 10.R-valtype-widen Cycle 4):
                // narrow the popped ref's `nullable` flag to false.
                // `ref.as_non_null` traps at runtime on null; on the
                // fall-through path the result is statically known
                // non-null.
                const narrowed: ValType = .{ .ref = .{
                    .nullable = false,
                    .heap_type = t.ref.heap_type,
                } };
                try self.pushType(narrowed);
            },
        }
    }

    /// Wasm spec 3.0 §3.3.8.6 (function-references proposal):
    /// `br_on_null l` — pop reftype; if null at runtime, branch
    /// to label l (consume l.label_types from stack as branch
    /// values). Otherwise the (non-null) reftype is preserved on
    /// the fall-through path. Stack effect: precondition
    /// `[t1*, reftype]` where label l takes `[t1*]`; postcondition
    /// (fall-through) `[t1*, reftype]` (reftype narrowed to
    /// non-null, but v2.0 catalogue can't express the narrowing).
    /// Branch path destination expects `[t1*]`.
    fn opBrOnNull(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        // Pop reftype first (it's the topmost value, the null-test
        // condition that the branch consumes). A `.bot` operand
        // (unreachable region) must STAY `.bot` through the
        // fall-through push below: materialising it as `.funcref`
        // plants a concrete ref the region never had, which a
        // downstream consumer with a real expectation — call_ref's
        // `(ref null typeidx)` callee — then rejects
        // (`(call_ref $t (br_on_null $l (unreachable)))`,
        // function-references/br_on_null).
        const top = try self.popAny();
        const reftype: ?ValType = switch (top) {
            .bot => null,
            .known => |t| blk: {
                if (!t.isRef()) {
                    self.mismatch = .{ .expected_ref = t };
                    return Error.StackTypeMismatch;
                }
                break :blk t;
            },
        };
        // Resolve target label; verify stack carries label's types.
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        const lt = target.labelType();
        try self.popLabelTypes(lt);
        // Fall-through: push label types back + reftype back.
        switch (lt) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
        // ADR-0123 D2 (cycle 93 / 10.R-valtype-widen Cycle 4):
        // `br_on_null` narrows the fall-through path's reftype to
        // non-null (the branch only fires when the ref IS null, so
        // post-branch the value must be non-null). Branch-target
        // path still receives the original ref kind via label_types.
        if (reftype) |rt| {
            try self.pushType(.{ .ref = .{
                .nullable = false,
                .heap_type = rt.ref.heap_type,
            } });
        } else {
            try self.pushBot();
        }
    }

    /// Wasm spec 3.0 §3.3.8.7 (function-references proposal):
    /// `br_on_non_null l` — pop reftype; if non-null at runtime,
    /// branch to label l (consume l.label_types — which include
    /// the reftype as the last entry — from stack as branch
    /// values, ref passed at top). Otherwise the (null) reftype
    /// is consumed and the fall-through path has just the
    /// prefix on stack. Stack effect: precondition
    /// `[t1*, reftype]` where label l takes `[t1*, reftype]`;
    /// postcondition (fall-through) `[t1*]` (ref consumed).
    /// Branch path destination expects `[t1*, reftype]` (non-null
    /// narrowed, but v2.0 catalogue can't express the narrowing).
    fn opBrOnNonNull(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        const top = try self.popAny();
        // Unreachable/polymorphic stack: the popped ref type is unknown
        // and unifies with whatever ref the label expects, so the ref↔
        // label subtype checks below are skipped (br_on_non_null.0 func
        // 6: `block (result (ref 0)); unreachable; br_on_non_null 0`).
        const is_bot = (top == .bot);
        const reftype: ValType = switch (top) {
            .bot => .funcref, // polymorphic; pick any reftype
            .known => |t| blk: {
                if (!t.isRef()) {
                    self.mismatch = .{ .expected_ref = t };
                    return Error.StackTypeMismatch;
                }
                break :blk t;
            },
        };
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        const lt = target.labelType();
        // Label l must take [t1*, (ref ht)] where the popped
        // reftype is (ref null ht). The branch only fires when the
        // ref is non-null at runtime — so the narrowed (non-null)
        // form is what flows to the label. Per Wasm 3.0 §3.3.10.9.
        const narrowed_ref: ValType = if (reftype.isRef()) .{ .ref = .{
            .nullable = false,
            .heap_type = reftype.ref.heap_type,
        } } else reftype;
        switch (lt) {
            .empty => return Error.StackTypeMismatch,
            .single => |t| {
                if (!is_bot and !self.subtypeCtx(narrowed_ref, t)) {
                    return Error.StackTypeMismatch;
                }
                // Prefix is empty; no further pop/push.
            },
            .multi => |ts| {
                if (ts.len == 0) return Error.StackTypeMismatch;
                if (!is_bot and !self.subtypeCtx(narrowed_ref, ts[ts.len - 1])) return Error.StackTypeMismatch;
                const prefix = ts[0 .. ts.len - 1];
                var i: usize = prefix.len;
                while (i > 0) {
                    i -= 1;
                    try self.popExpect(prefix[i]);
                }
                for (prefix) |t| try self.pushType(t);
            },
        }
    }

    /// Wasm spec 3.0 §3.3.10.4 (function-references proposal):
    /// `call_ref typeidx` — `typeidx` must name a func type, and the
    /// callee operand must be a subtype of `(ref null typeidx)`: the
    /// non-null `(ref typeidx)`, a concrete type reaching it through
    /// the declared supertype chain, or a func-hierarchy bottom. Pop
    /// the args matching that signature's params; push the
    /// signature's results. Runtime separately traps if the funcref
    /// is null (Trap.NullReference) or its actual sig mismatches
    /// (Trap.IndirectCallTypeMismatch).
    fn opCallRef(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        // `module_types[idx]` is meaningful only when `kinds[idx] ==
        // .func` (sections.zig TypeKind): a struct/array typedef holds
        // an empty placeholder sig there, so without this gate
        // `call_ref $s (struct.new $s ...)` validates — the operand IS
        // `(ref null $s)` — and the struct is read as a func entity at
        // runtime. Empty kinds = pre-GC caller (func types only).
        if (type_idx < self.module_types_kinds.len and self.module_types_kinds[type_idx] != .func) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        // The callee must sit in `(ref null typeidx)`'s hierarchy — an
        // externref/anyref/struct ref here was previously accepted and
        // then read as a function entity by both engines.
        try self.popExpect(.{ .ref = .{ .nullable = true, .heap_type = .{ .concrete = type_idx } } });
        // Pop args in reverse, then push results.
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        for (callee.results) |r| try self.pushType(r);
    }

    /// Wasm spec 3.0 §3.3.10.5 (function-references + tail-call):
    /// `return_call_ref typeidx` — tail-call variant of call_ref,
    /// with call_ref's callee typing: `typeidx` must name a func
    /// type and the popped callee must be a subtype of
    /// `(ref null typeidx)`. Pop the typeidx-determined params;
    /// verify that the callee's results match the **enclosing
    /// function's** return type (else the tail call would lose
    /// values); mark the stack polymorphic-from-here (= unreachable)
    /// per spec. Runtime trap semantics inherit call_ref's null +
    /// sig-mismatch behaviour.
    fn opReturnCallRef(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        // Same kind gate as call_ref: a struct/array typedef holds only
        // a placeholder sig in `module_types`.
        if (type_idx < self.module_types_kinds.len and self.module_types_kinds[type_idx] != .func) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        try self.popExpect(.{ .ref = .{ .nullable = true, .heap_type = .{ .concrete = type_idx } } });
        // Pop callee params in reverse (the tail-call args).
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        try self.checkResultsMatchFnReturn(callee.results);
        // Polymorphic-stack from here (terminator).
        self.markUnreachable();
    }

    /// Tail-call result-type check used by `return_call*` family
    /// (Wasm 3.0 §3.3.10.3-5). Each callee result MUST be a SUBTYPE of
    /// the corresponding enclosing-function return type — the tail call
    /// forwards its results as the enclosing function's results, so the
    /// same subtyping that `end` would apply governs here (e.g. a callee
    /// returning `(ref extern)` satisfies an enclosing `externref`).
    /// Exact equality is too strict and rejects spec-valid GC programs.
    fn checkResultsMatchFnReturn(self: *Validator, callee_results: []const ValType) Error!void {
        const fn_frame = &self.control_buf[0];
        switch (fn_frame.end_type) {
            .empty => if (callee_results.len != 0) return Error.StackTypeMismatch,
            .single => |t| {
                if (callee_results.len != 1 or !self.subtypeCtx(callee_results[0], t)) return Error.StackTypeMismatch;
            },
            .multi => |ts| {
                if (callee_results.len != ts.len) return Error.StackTypeMismatch;
                for (callee_results, ts) |a, b| if (!self.subtypeCtx(a, b)) return Error.StackTypeMismatch;
            },
        }
    }

    /// Wasm spec 3.0 §3.3.10.3 (tail-call): `return_call funcidx` —
    /// tail-call variant of `call`. Pop callee's params + verify
    /// callee's results match the enclosing function's return type;
    /// then polymorphic-stack (terminator).
    fn opReturnCall(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.func_types.len) return Error.InvalidFuncIndex;
        const callee = self.func_types[idx];
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        try self.checkResultsMatchFnReturn(callee.results);
        self.markUnreachable();
    }

    /// Wasm spec 3.0 §3.3.10.4 (tail-call): `return_call_indirect
    /// typeidx tableidx` — tail-call variant of `call_indirect`.
    /// Pop i32 selector + callee's params; verify callee's results
    /// match the enclosing function's return type; polymorphic-stack.
    /// Table must be `funcref` (same constraint as call_indirect).
    fn opReturnCallIndirect(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const table_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (table_idx >= self.tables.len) return Error.InvalidFuncIndex;
        // Subtype-of-funcref (incl. typed funcref tables), mirroring
        // opCallIndirect (Wasm 3.0 §3.3.5.6).
        if (!self.subtypeCtx(self.tables[table_idx].elem_type, ValType.funcref)) return Error.InvalidFuncIndex;
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        try self.popExpect(.i32);
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        try self.checkResultsMatchFnReturn(callee.results);
        self.markUnreachable();
    }

    /// Wasm spec §3.4.7.3 / §3.4.10 (ref.func x): read funcidx,
    /// validate it's within the module's function index space and
    /// — when the caller supplied a non-empty `declared_funcs`
    /// bitset — that the funcidx is in the module's declared set.
    /// The declared set captures funcidxs referenced from globals
    /// / elements / exports but NOT from other function bodies or
    /// the start function. Pushes funcref.
    fn opRefFunc(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.func_types.len) return Error.InvalidFuncIndex;
        if (self.declared_funcs.len != 0) {
            if (idx >= self.declared_funcs.len or !self.declared_funcs[idx]) {
                return Error.UndeclaredFuncRef;
            }
        }
        // ADR-0123 D4: `ref.func N` yields the non-null typed ref `(ref
        // func_type_indices[N])` so it satisfies typed `(ref $sig)`
        // params at `call` / `call_ref`. Callers that don't thread the
        // func→typeidx map (unit tests, compileWasm pre-migration) fall
        // back to the abstract `funcref`.
        if (idx < self.func_type_indices.len) {
            try self.pushType(.{ .ref = .{
                .nullable = false,
                .heap_type = .{ .concrete = self.func_type_indices[idx] },
            } });
        } else {
            try self.pushType(.funcref);
        }
    }

    /// table.get x: pop i32 idx, push tables[x].elem_type.
    fn opTableGet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(self.tableIdxType(idx)); // index (i32 or i64 for table64)
        try self.pushType(self.tables[idx].elem_type);
    }

    /// table.set x: pop tables[x].elem_type, pop idx (i32/i64).
    fn opTableSet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(self.tables[idx].elem_type);
        try self.popExpect(self.tableIdxType(idx));
    }

    /// table.size x (0xFC 16): push the table's index type (i64 for table64).
    fn opTableSize(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.pushType(self.tableIdxType(idx));
    }

    /// table.grow x (0xFC 15): pop n:idx_type, init:elem_type; push idx_type.
    fn opTableGrow(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(self.tableIdxType(idx)); // n (delta)
        try self.popExpect(self.tables[idx].elem_type);
        try self.pushType(self.tableIdxType(idx)); // previous size
    }

    /// Wasm spec §3.3.5.20 (table.init x y, 0xFC 12): pop three
    /// i32 (n, src, dst). The elemidx and tableidx must both be
    /// in range, and the elem segment's reftype must equal the
    /// destination table's reftype. The per-elem reftype check
    /// fires only when `elem_types` is populated (production
    /// `compileWasm` path); legacy callers without the slice
    /// retain pre-d-83 behaviour.
    fn opTableInit(self: *Validator) Error!void {
        const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const tableidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (elemidx >= self.elem_count) return Error.InvalidFuncIndex;
        if (tableidx >= self.tables.len) return Error.InvalidFuncIndex;
        if (self.elem_types.len != 0) {
            // Wasm §3.3.5.20 — segment reftype must be a SUBTYPE of the
            // table's reftype (not exact-equal): an i31ref elem segment
            // initialising an anyref table is valid (i31.wast
            // $anyref_table_of_i31ref).
            if (!self.subtypeCtx(self.elem_types[elemidx], self.tables[tableidx].elem_type)) {
                return Error.StackTypeMismatch;
            }
        }
        try self.popExpect(.i32); // n (elem-segment item count)
        try self.popExpect(.i32); // src (elem-segment offset)
        try self.popExpect(self.tableIdxType(tableidx)); // dst (table addr)
    }

    /// elem.drop x (0xFC 13): no operand-stack effects. Validates
    /// elemidx in range.
    fn opElemDrop(self: *Validator) Error!void {
        const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (elemidx >= self.elem_count) return Error.InvalidFuncIndex;
    }

    /// table.copy x y (0xFC 14): dst-tableidx, src-tableidx; pops
    /// three i32 (n, src, dst). Wasm 3.0 §3.3.6 requires the SOURCE
    /// elem type to be a subtype of the DEST elem type (not exact
    /// equality) — e.g. copying a `(ref func)` table into a `funcref`
    /// table is valid. Same exact-eql-vs-subtyping class as the
    /// return_call result check.
    fn opTableCopy(self: *Validator) Error!void {
        const dst = try leb128.readUleb128(u32, self.body, &self.pos);
        const src = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dst >= self.tables.len or src >= self.tables.len) return Error.InvalidFuncIndex;
        if (!self.subtypeCtx(self.tables[src].elem_type, self.tables[dst].elem_type)) {
            return Error.StackTypeMismatch;
        }
        // table64: dst uses dst-table idx_type, src uses src-table idx_type,
        // n uses the narrower of the two (mirrors memory.copy, §3.4.7).
        const dst_t = self.tableIdxType(dst);
        const src_t = self.tableIdxType(src);
        const n_t: ValType = if (dst_t == .i32 or src_t == .i32) .i32 else .i64;
        try self.popExpect(n_t); // n
        try self.popExpect(src_t); // src
        try self.popExpect(dst_t); // dst
    }

    /// table.fill x (0xFC 17): pop n:idx_type, val:elem_type, dst:idx_type.
    fn opTableFill(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(self.tableIdxType(idx)); // n
        try self.popExpect(self.tables[idx].elem_type);
        try self.popExpect(self.tableIdxType(idx)); // dst
    }

    /// memory.fill: 0xFC 11 memidx. Pops three values
    /// (n:idx_type, val:i32, dst:idx_type); pushes nothing.
    /// Wasm 3.0 §3.4.7: dst + n use the TARGET memory's idx_type
    /// (per-memory, D-324); val is always i32.
    fn opMemoryFill(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        // 10.M cycle 67 — relax multi-memory memidx LEB (was
        // reserved 0x00). Range-check against memory_count.
        const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (memidx >= self.memory_count) return Error.UnknownMemory;
        const addr = self.memIdxTypeAt(memidx);
        try self.popExpect(addr); // n
        try self.popExpect(.i32); // val
        try self.popExpect(addr); // dst
    }

    fn opBrTable(self: *Validator) Error!void {
        const n = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.popExpect(.i32); // selector
        // Wasm 2.0 §3.3.5.8 (br_table):
        //   - All targets' label types must have the same arity
        //     (§9.9 / 9.9-l-1b-d093-d85 — even in polymorphic
        //     stack mode, arity mismatch cannot unify via .bot).
        //   - Numeric-type equality across targets is enforced in
        //     reachable code only; in polymorphic (post-
        //     unreachable / br / return) code the joined type
        //     collapses to `bot` so per-target type may differ
        //     (the `meet-bottom` fixture in `unreached-valid.wast`
        //     exercises `block f32` vs `block f64` targets).
        //   - The label-type pop happens unconditionally — in
        //     polymorphic code the operand stack may still carry
        //     concrete values pushed AFTER unreachable, and those
        //     must match the joined label type just as in
        //     reachable code (drains `unreached-invalid.85` =
        //     `block (result i32); unreachable; f32.const 0;
        //     i32.const 1; br_table 0; end` where the f32 must
        //     reject against the inner block's i32 result type).
        const arityOf = struct {
            fn f(bt: BlockType) usize {
                return switch (bt) {
                    .empty => 0,
                    .single => 1,
                    .multi => |ts| ts.len,
                };
            }
        }.f;
        // D-452 (Wasm 3.0 §3.3.8.8): every target + default must have equal
        // arity, and the branch operands must be a SUBTYPE of EACH label type —
        // NOT pairwise-equal across labels (the old `labelTypesEq` wrongly
        // rejected e.g. `(ref func)` vs `funcref` targets with a `(ref func)`
        // operand). Peek per-label (no consume), then pop once; `.bot` matches any.
        var first: ?BlockType = null;
        var arity: usize = 0;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            const depth = try leb128.readUleb128(u32, self.body, &self.pos);
            const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
            const lt = target.labelType();
            if (first == null) {
                first = lt;
                arity = arityOf(lt);
            } else if (arityOf(lt) != arity) return Error.ArityMismatch;
            try self.checkOperandsSubtypeOfLabel(lt);
        }
        if (first) |lt| try self.popLabelTypes(lt);
        self.markUnreachable();
    }

    fn opBrIf(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.popExpect(.i32);
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        // br_if pops the label values, then pushes them back (since the
        // taken branch consumes; the fall-through preserves them).
        const lt = target.labelType();
        try self.popLabelTypes(lt);
        switch (lt) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opCall(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.func_types.len) return Error.InvalidFuncIndex;
        const callee = self.func_types[idx];
        // Pop args in reverse order so the topmost popped value matches the
        // last param.
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        for (callee.results) |r| try self.pushType(r);
    }

    fn opCallIndirect(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        // Wasm 2.0: table_idx is uleb32 (any table); Wasm 1.0
        // encoded a single 0x00 byte which decodes as uleb32(0).
        const table_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (table_idx >= self.tables.len) return Error.InvalidFuncIndex;
        // Wasm 3.0 §3.3.5.6: call_indirect requires the table's reftype
        // to be a SUBTYPE of `funcref` — abstract `func`/`nofunc` OR a
        // concrete func-typed `(ref null $t)` / `(ref $t)` (a typed
        // funcref table, gc/type-subtyping.19). Externref / struct / array
        // tables are rejected. (Was an exact `isFuncref()` test, which
        // accepted only the abstract `(ref null func)`.)
        if (!self.subtypeCtx(self.tables[table_idx].elem_type, ValType.funcref)) return Error.InvalidFuncIndex;
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        // Pop the function-table index (i64 for a table64), then args in reverse.
        try self.popExpect(self.tableIdxType(table_idx));
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        for (callee.results) |r| try self.pushType(r);
    }

    fn opSelect(self: *Validator) Error!void {
        // select (untyped, MVP): pop i32 cond; pop t2; pop t1; require
        // t1 == t2 (numeric); push t1.
        // §9.9 / 9.9-l-1b-d093-d81 — Wasm spec §3.3.2.2:
        // untyped `select` requires the value operands to have
        // a *numeric* type (i32/i64/f32/f64/v128). Reftype
        // operands (funcref / externref) must use `select_typed`
        // (0x1C). Rejecting reftype operands here drains the
        // `select.4` SKIP-VALIDATOR-GAP case where untyped select
        // appears with externref params.
        try self.popExpect(.i32);
        const a = try self.popAny();
        const b = try self.popAny();
        const isNumeric = struct {
            fn check(t: ValType) bool {
                return switch (t) {
                    .i32, .i64, .f32, .f64, .v128 => true,
                    // 10.G op_gc cycle 2: i31ref is a reftype per
                    // Wasm 3.0 spec — untyped select rejects ref
                    // operands per Wasm 2.0 §3.3.2.2.
                    .ref => false,
                };
            }
        }.check;
        switch (a) {
            .known => |ka| if (!isNumeric(ka)) return Error.StackTypeMismatch,
            .bot => {},
        }
        switch (b) {
            .known => |kb| if (!isNumeric(kb)) return Error.StackTypeMismatch,
            .bot => {},
        }
        const result: TypeOrBot = blk: {
            switch (a) {
                .bot => break :blk b,
                .known => |ka| switch (b) {
                    .bot => break :blk a,
                    .known => |kb| {
                        if (!ka.eql(kb)) return Error.StackTypeMismatch;
                        break :blk a;
                    },
                },
            }
        };
        switch (result) {
            .known => |t| try self.pushType(t),
            .bot => try self.pushBot(),
        }
        // D-115 d-39: emit the resolved valtype byte for the lower /
        // emit pipeline. Polymorphic-bottom (only reachable in dead
        // code after `unreachable` / `br`) resolves to 0x7F i32 — the
        // default CSEL Wd path, harmless because the bytes are
        // unreachable at runtime per Wasm spec §3.3.5.
        if (self.out_select_types) |list| {
            const byte: u8 = switch (result) {
                .known => |t| valTypeByte(t),
                .bot => 0x7F,
            };
            try list.append(self.out_allocator.?, byte);
        }
    }

    /// select_typed (Wasm 2.0): 0x1C count valtype*. Wasm 2.0
    /// requires count = 1 (the result type). Pops i32 cond, two
    /// values of that type, pushes one of them.
    fn opSelectTyped(self: *Validator) Error!void {
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        if (count != 1) return Error.InvalidOpcode;
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const b = self.body[self.pos];
        self.pos += 1;
        const t: ValType = switch (b) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            0x7B => .v128,
            0x70 => .funcref,
            0x6F => .externref,
            // Wasm 3.0 GC / EH single-byte abstract reftypes (mirror
            // init_expr.readValType): `select t` admits ANY valtype (D-492).
            0x6E => .anyref,
            0x6D => .eqref,
            0x6C => .i31ref,
            0x6B => .structref,
            0x6A => .arrayref,
            0x69 => .exnref,
            0x71 => .nullref,
            0x72 => .nullexternref,
            0x73 => .nullfuncref,
            0x74 => .nullexnref,
            else => return Error.BadValType,
        };
        try self.popExpect(.i32);
        try self.popExpect(t);
        try self.popExpect(t);
        try self.pushType(t);
    }

    /// Wasm 3.0 §5.4.6 — memarg align uleb bit 6 (0x40) signals
    /// an explicit memidx LEB follows. Mirrors `lower.zig::emitMemarg`
    /// byte consumption so validator + lowerer stay in sync; without
    /// this the validator's position desyncs on bit-6-set memargs
    /// and subsequent opcodes parse from wrong offsets. Returns the
    /// memarg's memidx (0 when bit 6 unset) so callers can type the
    /// address operand per memory (D-324).
    fn skipMemarg(self: *Validator) Error!u32 {
        const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
        var memidx: u32 = 0;
        if ((raw_align & 0x40) != 0) {
            memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        }
        try self.skipMemargOffset(memidx);
        return memidx;
    }

    /// Wasm 3.0 §5.4.6: an i64-indexed (memory64) memory's memarg
    /// offset is a u64 (LEB128 ≤ 10 bytes); a legacy i32 memory's is a
    /// u32 (≤ 5 bytes). clang/lld emit width-padded offset LEBs for
    /// memory64 (relocatable fixed-width), so decoding at u32 width
    /// wrongly rejects a valid offset as Error.Overlong (D-209,
    /// realworld clang_wasm64 — the spec corpus only uses minimal
    /// LEBs, which masked this). Width keys off the TARGET memory's
    /// idx_type (per-memory via `memory_idx_types`; D-324).
    fn skipMemargOffset(self: *Validator, memidx: u32) Error!void {
        switch (self.memEntryIdxType(memidx)) {
            .i32 => _ = try leb128.readUleb128(u32, self.body, &self.pos),
            .i64 => _ = try leb128.readUleb128(u64, self.body, &self.pos),
        }
    }

    /// Wasm spec §3.3.7 (memarg alignment) — read the memarg
    /// align uleb (mask off bit 6 multi-memory flag), validate
    /// the actual alignExp ≤ `max_align_log2` (the op's natural
    /// alignment exponent). Then consume the optional memidx +
    /// offset uleb just like `skipMemarg`. Rejects with
    /// `Error.InvalidAlignment` on out-of-range align. Returns the
    /// memidx (0 when bit 6 unset) for per-memory address typing.
    fn readMemargCheckAlign(self: *Validator, max_align_log2: u32) Error!u32 {
        const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
        const align_log2 = raw_align & ~@as(u32, 0x40);
        if (align_log2 > max_align_log2) return Error.InvalidAlignment;
        var memidx: u32 = 0;
        if ((raw_align & 0x40) != 0) {
            memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        }
        try self.skipMemargOffset(memidx);
        return memidx;
    }

    /// Address operand type for memory ops per Wasm 3.0 §3.4.7 —
    /// `.i32` for legacy i32-indexed memory; `.i64` for memory64.
    /// Determined by `self.memory0_idx_type`; per-memidx ops use
    /// `memIdxTypeAt` (D-324) which falls back here.
    fn memAddrType(self: *const Validator) ValType {
        return switch (self.memory0_idx_type) {
            .i32 => .i32,
            .i64 => .i64,
        };
    }

    /// D-324 — raw idx_type of a SPECIFIC memidx, falling back to
    /// `memory0_idx_type` when per-memory types aren't threaded
    /// (legacy callers with the empty default).
    fn memEntryIdxType(self: *const Validator, memidx: u32) sections.MemoryEntry.IdxType {
        if (memidx < self.memory_idx_types.len) return self.memory_idx_types[memidx];
        return self.memory0_idx_type;
    }

    /// D-324 — address operand valtype for a SPECIFIC memidx
    /// (Wasm 3.0 §3.4.7 multi-memory × memory64 mixing).
    pub fn memIdxTypeAt(self: *const Validator, memidx: u32) ValType {
        return switch (self.memEntryIdxType(memidx)) {
            .i32 => .i32,
            .i64 => .i64,
        };
    }

    /// The index/operand valtype for a table's address space (table64,
    /// memory64 proposal's table extension): i64 for an i64-indexed table,
    /// i32 otherwise. table.get/set/grow/size/fill/copy/init + call_indirect
    /// index this table at this width (caller must have range-checked idx).
    fn tableIdxType(self: *const Validator, idx: u32) ValType {
        return switch (self.tables[idx].idx_type) {
            .i32 => .i32,
            .i64 => .i64,
        };
    }

    fn opLoad(self: *Validator, t: ValType, max_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlign(max_align_log2);
        try self.popExpect(self.memIdxTypeAt(memidx)); // address (i32 or i64)
        try self.pushType(t);
    }

    /// Read a memarg whose alignment exponent MUST equal the op's
    /// natural alignment (Wasm threads §valid: "atomic instructions
    /// must always specify maximum alignment") — stricter than
    /// `readMemargCheckAlign`'s `≤`. Out-of-range → `InvalidAlignment`.
    fn readMemargCheckAlignExact(self: *Validator, natural_align_log2: u32) Error!u32 {
        const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
        const align_log2 = raw_align & ~@as(u32, 0x40);
        if (align_log2 != natural_align_log2) return Error.InvalidAlignment;
        var memidx: u32 = 0;
        if ((raw_align & 0x40) != 0) {
            memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        }
        try self.skipMemargOffset(memidx);
        return memidx;
    }

    /// Wasm threads §valid — `tNN.atomic.load*`: EXACT natural
    /// alignment + a memory present; pop addr → push the result type.
    /// Atomics do NOT require a shared memory (wasm-tools
    /// `check_shared_memarg`; ADR-0168). Runtime alignment trap is
    /// enforced by the handler/JIT, not the validator.
    fn opAtomicLoad(self: *Validator, t: ValType, natural_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlignExact(natural_align_log2);
        try self.popExpect(self.memIdxTypeAt(memidx)); // address (i32 or i64)
        try self.pushType(t);
    }

    /// Wasm threads §valid — `tNN.atomic.store*`: EXACT natural alignment +
    /// a memory present; pop value (type t) then addr. No result (ADR-0168).
    fn opAtomicStore(self: *Validator, t: ValType, natural_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlignExact(natural_align_log2);
        try self.popExpect(t); // value
        try self.popExpect(self.memIdxTypeAt(memidx)); // address (i32 or i64)
    }

    /// Wasm threads §valid — `tNN.atomic.rmw*.<op>` (non-cmpxchg): EXACT
    /// natural align + a memory; pop value (t) + addr, push old (t).
    fn opAtomicRmw(self: *Validator, t: ValType, natural_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlignExact(natural_align_log2);
        try self.popExpect(t); // value
        try self.popExpect(self.memIdxTypeAt(memidx)); // address
        try self.pushType(t); // old
    }

    /// Wasm threads §valid — `tNN.atomic.rmw*.cmpxchg`: EXACT align +
    /// memory; pop replacement (t) + expected (t) + addr, push old (t).
    fn opAtomicCmpxchg(self: *Validator, t: ValType, natural_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlignExact(natural_align_log2);
        try self.popExpect(t); // replacement
        try self.popExpect(t); // expected
        try self.popExpect(self.memIdxTypeAt(memidx)); // address
        try self.pushType(t); // old
    }

    /// Wasm threads §valid — `memory.atomic.notify`: EXACT natural align
    /// (2 = 4B) + a memory; pop count(i32) + addr → push i32 (waiters
    /// woken). Valid on any memory (notify on non-shared returns 0).
    fn opAtomicNotify(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlignExact(2);
        try self.popExpect(.i32); // count
        try self.popExpect(self.memIdxTypeAt(memidx)); // address
        try self.pushType(.i32); // waiters woken
    }

    /// Wasm threads §valid — `memory.atomic.wait{32,64}`: EXACT natural
    /// align (2 / 3) + a memory; pop timeout(i64) + expected(t) + addr →
    /// push i32 (0 ok / 1 not-equal / 2 timed-out). Runtime traps on a
    /// non-shared memory (not a validation constraint).
    fn opAtomicWait(self: *Validator, t: ValType, natural_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlignExact(natural_align_log2);
        try self.popExpect(.i64); // timeout
        try self.popExpect(t); // expected (i32 for wait32, i64 for wait64)
        try self.popExpect(self.memIdxTypeAt(memidx)); // address
        try self.pushType(.i32); // status
    }

    fn opStore(self: *Validator, t: ValType, max_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try self.readMemargCheckAlign(max_align_log2);
        try self.popExpect(t); // value
        try self.popExpect(self.memIdxTypeAt(memidx)); // address (i32 or i64)
    }

    fn opMemorySize(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        // 10.M cycle 66 — Wasm 3.0 multi-memory: was `if (body[pos]
        // != 0x00) reject` (single reserved byte). Now LEB-decode
        // memidx + range-check against memory_count. Pushed type =
        // the TARGET memory's idx_type (per-memory, D-324).
        const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (memidx >= self.memory_count) return Error.UnknownMemory;
        try self.pushType(self.memIdxTypeAt(memidx));
    }

    fn opMemoryGrow(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (memidx >= self.memory_count) return Error.UnknownMemory;
        try self.popExpect(self.memIdxTypeAt(memidx));
        try self.pushType(self.memIdxTypeAt(memidx));
    }

    // ----------------------------------------------------------------
    // Frame end-type assertion
    // ----------------------------------------------------------------

    fn expectFrameEndTypes(self: *Validator, frame: ControlFrame) Error!void {
        const end = frame.endType();
        const expected_len: usize = switch (end) {
            .empty => 0,
            .single => 1,
            .multi => |ts| ts.len,
        };
        const have: usize = self.operand_len - frame.height;
        // §9.9 / 9.9-l-1b-d093-d85 — Wasm spec §3.3.5
        // (polymorphic stack): in unreachable code, MISSING values
        // are synthesised on read (i.e. `have < expected_len` is
        // OK), but PRESENT values must still type-check against
        // the corresponding expected slot. Excess values (`have >
        // expected_len`) is an unconsumed-result error even in
        // unreachable code (spec §3.3.5.4: "the validator must
        // ensure that no unused values remain on the stack"). The
        // pre-d-85 form bailed out entirely whenever
        // `unreachable_flag` was set, which silently accepted
        // unreached-invalid.{5,18,20,22,28,30,32,40,42,44,82,85,86,115}
        // — concrete pushes after `unreachable` that contradicted
        // the surrounding function / block's declared result
        // types.
        if (frame.unreachable_flag) {
            if (have > expected_len) return Error.StackTypeMismatch;
        } else {
            if (have != expected_len) return Error.ArityMismatch;
        }
        // The `have` present values occupy the TOP of the
        // conceptual full result tuple. With expected types
        // `[e_0, ..., e_{N-1}]` (e_0 = bottom, e_{N-1} = top), the
        // first present slot (operand_buf[frame.height]) maps to
        // expected[N - have].
        const offset = expected_len - have;
        // ADR-0123 Cycle 3 (10.R-funcrefs-tail) — subtype-aware
        // result-type check per Wasm 3.0 §3.3.4: a `(ref ht)`
        // pushed onto a block whose declared end-type is
        // `(ref null ht)` is valid.
        switch (end) {
            .empty => {},
            .single => |t| {
                if (have == 1) {
                    const top = self.operand_buf[frame.height];
                    switch (top) {
                        .bot => {},
                        .known => |k| if (!self.subtypeCtx(k, t)) return Error.StackTypeMismatch,
                    }
                }
            },
            .multi => |ts| {
                var i: usize = 0;
                while (i < have) : (i += 1) {
                    const slot = self.operand_buf[frame.height + i];
                    const expected_t = ts[offset + i];
                    switch (slot) {
                        .bot => {},
                        .known => |k| if (!self.subtypeCtx(k, expected_t)) return Error.StackTypeMismatch,
                    }
                }
            },
        }
    }
};

// D-204: GC-subtype + valtype-subtype helpers extracted to gc_subtype.zig (called via `gc_subtype.<fn>`).
// Pure const-expr-typing + subtype-validation helpers (constExprResultType /
// validateGlobalInits / funcTypeImportCompatible / validateTypeSection /
// typeDefIsSubtype + GlobalEntry) extracted to validator_helpers.zig (the
// marker's planned extraction; D-475 table64 cap pressure). Re-exported above
// (`helpers.<fn>`) so internal + external `validator.<fn>` callers are unchanged.

/// True iff `expected` (a branch target's label type) structurally
/// equals `tag_params ++ [exnref]` — the tuple a `catch_ref` clause
/// pushes. `catch_all_ref` passes empty `tag_params`, so the pushed
/// tuple is just `[exnref]`. Avoids materialising the concatenated
/// slice (the validator has no scratch allocator on this path).
fn labelTypeEqParamsPlusExn(expected: BlockType, tag_params: []const ValType) bool {
    const n = tag_params.len;
    if (n == 0) {
        // pushed = [exnref] → single element.
        return switch (expected) {
            .single => |t| t.eql(ValType.exnref),
            .empty, .multi => false,
        };
    }
    // n >= 1 → pushed has n+1 (≥2) elements → must be `.multi`.
    return switch (expected) {
        .multi => |ts| blk: {
            if (ts.len != n + 1) break :blk false;
            for (tag_params, ts[0..n]) |p, e| if (!p.eql(e)) break :blk false;
            break :blk ts[n].eql(ValType.exnref);
        },
        .empty, .single => false,
    };
}

fn labelTypesEq(a: BlockType, b: BlockType) bool {
    return switch (a) {
        .empty => b == .empty,
        .single => |t1| switch (b) {
            .single => |t2| t1.eql(t2),
            else => false,
        },
        .multi => |ts1| switch (b) {
            .multi => |ts2| blk: {
                // ADR-0123 Cycle 2: ValType is union(enum); std.mem.eql
                // can't derive == for unions whose inner types are
                // also unions. Manual loop via ValType.eql.
                if (ts1.len != ts2.len) break :blk false;
                for (ts1, ts2) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            else => false,
        },
    };
}
