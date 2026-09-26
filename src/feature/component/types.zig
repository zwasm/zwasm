// FILE-SIZE-EXEMPT: verified P1 seam (section decode → types_decode.zig) SCHEDULED post-v2.5.0 as D-581 (triage 2026-08-12, per ADR-0099)
//! Component **type model + type/import/export section decode** (CM campaign
//! chunk A2; spec `component-model/design/mvp/Binary.md` §type / §import-export).
//!
//! Builds the component-level type index space from the `type` section (id 7)
//! and the `import` (id 10) / `export` (id 11) sections. The model is kept
//! DISTINCT from `runtime.Value` (`single_slot_dual_meaning`): a component
//! `ValType` describes interface-level shape, not a runtime slot.
//!
//! Encoding note (`Binary.md`): type-constructor opcodes use the same
//! negative-SLEB128 scheme as Core Wasm — `0x7f` is `SLEB(-1)` and they count
//! down, leaving the non-negative SLEB128 range for type indices. So a
//! `valtype` is decoded by reading one SLEB128: negative → a primitive opcode
//! (`v & 0x7f`), non-negative → a `typeidx` into the type index space.
//!
//! SCOPE (campaign close 2026-06-13): the full deftype family decodes —
//! primitives, functype, compound defvaltypes (record/variant/list/tuple/
//! flags/enum/option/result/own/borrow), componenttype/instancetype decl
//! scopes, and resourcetype 0x3f (D-322; raw-byte peek — it is
//! sleb-positive unlike every other deftype op). Still typed
//! stream/future (0x66/0x65) decode as CM-async value types (WASI 0.3).
//! Still typed `UnsupportedTypeForm` (spec-faithful deferral, never a silent
//! skip): the 0x3e async-dtor resource form.
//!
//! No-copy: v1 `component.zig` uses an OLDER component-model draft (e.g. its
//! `0x41` is `func`, the current spec's `0x41` is `componenttype`). This is
//! re-derived from the current `Binary.md` (component `version == 0x0d`).

const std = @import("std");

const leb128 = @import("../../support/leb128.zig");
const core_scan = @import("core_scan.zig");
pub const CoreDefType = core_scan.CoreDefType;
pub const CoreModuleDecl = core_scan.CoreModuleDecl;
pub const CoreTypeDef = core_scan.CoreTypeDef;
const decode = @import("decode.zig");

const Allocator = std.mem.Allocator;

/// Primitive value types (`Binary.md` `primvaltype`). Enum values ARE the
/// (positive) opcode bytes, i.e. `v & 0x7f` of the negative SLEB128.
pub const PrimValType = enum(u8) {
    bool = 0x7f,
    s8 = 0x7e,
    u8 = 0x7d,
    s16 = 0x7c,
    u16 = 0x7b,
    s32 = 0x7a,
    u32 = 0x79,
    s64 = 0x78,
    u64 = 0x77,
    f32 = 0x76,
    f64 = 0x75,
    char = 0x74,
    string = 0x73,
    error_context = 0x64,
};

/// `valtype ::= typeidx | primvaltype` (`Binary.md`). A compound type is never
/// inline here — it is a `deftype` referenced by `type_index`.
pub const ValType = union(enum) {
    primitive: PrimValType,
    type_index: u32,
};

/// `labelvaltype ::= label' valtype` — a named parameter/field. `name` borrows
/// from the decoded input.
pub const NamedVal = struct {
    name: []const u8,
    ty: ValType,
};

/// `functype ::= 0x40 paramlist resultlist` (async variant `0x43`).
/// `resultlist` is a single optional result (`0x00 valtype` | `0x01 0x00`).
pub const FuncType = struct {
    params: []const NamedVal,
    result: ?ValType,
    is_async: bool,
};

/// `enum` defvaltype (`Binary.md` 0x6d): an ordered label set, no payloads.
pub const EnumType = struct {
    labels: []const []const u8,
};

/// `flags` defvaltype (`Binary.md` 0x6e): a bit-set of labels (1..=32).
pub const FlagsType = struct {
    labels: []const []const u8,
};

/// `record` defvaltype (`Binary.md` 0x72): named, ordered fields.
pub const RecordType = struct {
    fields: []const NamedVal,
};

/// `list<T>` defvaltype (`Binary.md` 0x70 variable / 0x67 fixed-length).
pub const ListType = struct {
    element: *const ValType,
    /// Fixed length (`0x67`), or null for a variable-length list (`0x70`).
    fixed_length: ?u32,
};

/// `tuple` defvaltype (`Binary.md` 0x6f): positional, unnamed element types.
pub const TupleType = struct {
    types: []const ValType,
};

/// One `variant` case (`Binary.md` `case`): a label + optional payload type.
pub const Case = struct {
    name: []const u8,
    payload: ?ValType,
};

/// `variant` defvaltype (`Binary.md` 0x71): a tagged union of cases.
pub const VariantType = struct {
    cases: []const Case,
};

/// `option<T>` defvaltype (`Binary.md` 0x6b) — sugar for `variant{none, some(T)}`.
pub const OptionType = struct {
    payload: *const ValType,
};

/// `result<T, E>` defvaltype (`Binary.md` 0x6a) — sugar for
/// `variant{ok(T?), err(E?)}`; both payloads optional.
pub const ResultType = struct {
    ok: ?ValType,
    err: ?ValType,
};

/// `stream<t?>` defvaltype (`Binary.md` 0x66) — an async readable/writable
/// stream of an OPTIONAL element type (CM-async / WASI 0.3; `Concurrency.md`).
pub const StreamType = struct {
    payload: ?ValType,
};

/// `future<t?>` defvaltype (`Binary.md` 0x65) — an async single-shot value of
/// an OPTIONAL element type (CM-async / WASI 0.3; `Concurrency.md`).
pub const FutureType = struct {
    payload: ?ValType,
};

/// One `deftype` in the type index space. A2 modelled primitives + `functype`;
/// B2 `enum`/`flags`; B5 the remaining compound value types; own/borrow are
/// resource handles; stream/future are the CM-async (WASI 0.3) value types.
pub const DefType = union(enum) {
    value: ValType,
    func: FuncType,
    enum_: EnumType,
    flags: FlagsType,
    record: RecordType,
    list: ListType,
    tuple: TupleType,
    variant: VariantType,
    option: OptionType,
    result: ResultType,
    /// `stream<t?>` (0x66) — async stream of an optional element type.
    stream: StreamType,
    /// `future<t?>` (0x65) — async single-shot value of an optional type.
    future: FutureType,
    /// `own<i>` (0x69) — an owning handle to resource type `i`.
    own: u32,
    /// `borrow<i>` (0x68) — a borrowed handle to resource type `i`.
    borrow: u32,
    /// `instancetype` (0x42) — a component instance type (a WASI interface
    /// type is one of these).
    instance_type: InstanceType,
    /// `resourcetype` (0x3f/0x3e) — a fresh (generative) resource type.
    /// MVP rep is i32; the optional destructor is a core funcidx.
    resource: ResourceType,
    /// `componenttype` (0x41) — a component type.
    component_type: ComponentType,
};

/// One `instancedecl` (`Binary.md`): a declaration inside an `instancetype`.
pub const InstanceDecl = union(enum) {
    /// 0x01 — a nested component `type` definition.
    type_def: *const DefType,
    /// 0x02 — an alias.
    alias: Alias,
    /// 0x04 — `exportdecl ::= exportname' externdesc`.
    export_decl: ImportExportDecl,
};

pub const ImportExportDecl = struct {
    name: []const u8,
    desc: ExternDesc,
};

pub const InstanceType = struct {
    decls: []const InstanceDecl,
};

/// `resourcetype ::= 0x3f 0x7f dtor? | 0x3e 0x7f dtor cb?` (rep i32; the
/// 🐘 i64 rep + 🚝 async forms decode to the same shape, dtor flags kept
/// minimal — callbacks are not modeled).
pub const ResourceType = struct {
    /// Core funcidx of the destructor, if declared.
    dtor: ?u32,
};

/// One `componentdecl` (`Binary.md`): `0x03 importdecl` or an `instancedecl`.
pub const ComponentDecl = union(enum) {
    import_decl: ImportExportDecl,
    instance_decl: InstanceDecl,
};

pub const ComponentType = struct {
    decls: []const ComponentDecl,
};

/// Component-level `sort` (`Binary.md`); `core` nests a `core:sort`.
pub const CoreSort = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
    tag = 0x04,
    type = 0x10,
    module = 0x11,
    instance = 0x12,
    _,
};

pub const Sort = union(enum) {
    core: CoreSort,
    func,
    value,
    type,
    component,
    instance,
};

/// `typebound` (`Binary.md`) — a `(type ...)` import/export bound.
pub const TypeBound = union(enum) {
    /// `(eq i)` — equal to type `i`.
    eq: u32,
    /// `(sub resource)` — a fresh abstract resource type.
    sub_resource,
};

/// `externdesc` (`Binary.md`) — what an import/export refers to.
pub const ExternDesc = union(enum) {
    core_module: u32,
    func: u32,
    component: u32,
    instance: u32,
    /// `(type b)` — a type import/export with bound `b`.
    type_bound: TypeBound,
    /// `(value b)` — a value import/export. B carries an `eq valueidx` or an
    /// inline `valtype`; modelled minimally (the valtype/idx) for now.
    value_bound: ?ValType,
};

pub const Import = struct {
    name: []const u8,
    desc: ExternDesc,
};

/// Top-level `export ::= exportname' sortidx externdesc?` — the export aliases
/// a definition by `sortidx`; the optional `externdesc` ascribes a type.
pub const Export = struct {
    name: []const u8,
    sort: Sort,
    index: u32,
    desc: ?ExternDesc,
    /// The size of this export's own sort index space at this export's
    /// DEFINITION point — i.e. before the entry this export itself adds.
    ///
    /// A sortidx may only name something defined earlier, so this — not the
    /// final space size — is the bound `validate.zig` must check. The
    /// distinction only became observable once exports started appending to
    /// their spaces (D-527): before that, `(export "a" (instance 0))` with no
    /// instances was out of bounds against a space of size 0, and afterwards
    /// the export's own entry made index 0 look valid. Same for a func or type
    /// export naming itself.
    ///
    /// Zero for the sorts whose spaces exports do not extend (`core`,
    /// `component`, `value`); `validate.zig` checks those against their own
    /// counters as before.
    sort_space_len_at_def: u32 = 0,
};

/// The decoded type index space + import/export lists. All owned allocations
/// live in `arena`; `name` slices borrow from the component input.
/// `string-encoding` canonopt (`Binary.md` `canonopt`).
pub const StringEncoding = enum { utf8, utf16, latin1_utf16 };

/// Decoded `opts` (`Binary.md` `canonopt` vec): the canonical-ABI options for a
/// lift/lower.
pub const CanonOpts = struct {
    string_encoding: StringEncoding = .utf8,
    memory: ?u32 = null, // core:memidx
    realloc: ?u32 = null, // core:funcidx
    post_return: ?u32 = null, // core:funcidx
    is_async: bool = false, // CM-async `async` canonopt (0x06)
    callback: ?u32 = null, // CM-async `callback` core:funcidx (0x07); lift-only, implies async
};

/// The `canon stream.*` / `future.*` builtins (`Binary.md` 0x0e–0x1b, CM-async
/// / WASI 0.3). The tag selects the operation; the payload shape varies
/// (new/drop carry only the element typeidx, read/write add `opts`,
/// cancel-read/write add an `async?` flag).
pub const StreamFutureOp = enum {
    stream_new, // 0x0e
    stream_read, // 0x0f
    stream_write, // 0x10
    stream_cancel_read, // 0x11
    stream_cancel_write, // 0x12
    stream_drop_readable, // 0x13
    stream_drop_writable, // 0x14
    future_new, // 0x15
    future_read, // 0x16
    future_write, // 0x17
    future_cancel_read, // 0x18
    future_cancel_write, // 0x19
    future_drop_readable, // 0x1a
    future_drop_writable, // 0x1b
};

/// `canon waitable-set.*` / `waitable.join` builtins (`Binary.md` 0x1f–0x23).
/// `new`/`drop`/`join` are bare; `wait`/`poll` carry a `cancellable` flag + a
/// `memory` index (where the delivered event tuple is written).
pub const WaitableSetOp = enum {
    new, // 0x1f
    wait, // 0x20
    poll, // 0x21
    drop, // 0x22
    join, // 0x23
};

/// One `canon` section definition (`Binary.md` `canon`). B6 models lift/lower +
/// the resource builtins; the stream/future builtins are the CM-async front.
pub const Canon = union(enum) {
    /// `canon lift` (0x00 0x00): a core func exposed as a component func of
    /// `type_index`, with `opts`.
    lift: struct { core_func: u32, opts: CanonOpts, type_index: u32 },
    /// `canon lower` (0x01 0x00): a component func lowered to a core func.
    lower: struct { func: u32, opts: CanonOpts },
    resource_new: u32, // 0x02 typeidx
    resource_drop: u32, // 0x03 typeidx
    resource_rep: u32, // 0x04 typeidx
    /// `canon stream.*` / `future.*` (0x0e–0x1b) over element type `type_index`.
    /// `opts` present only for read/write; `is_async` only for cancel-read/write.
    stream_future: struct { op: StreamFutureOp, type_index: u32, opts: ?CanonOpts = null, is_async: ?bool = null },
    /// `canon task.return` (0x09): the core func an async task imports to return
    /// its `result` (a single optional valtype), lifted via `opts`.
    task_return: struct { result: ?ValType, opts: CanonOpts },
    /// `canon waitable-set.*` / `waitable.join` (0x1f–0x23). `memory`/`cancellable`
    /// present only for `wait`/`poll`.
    waitable_set: struct { op: WaitableSetOp, cancellable: bool = false, memory: ?u32 = null },
    /// `canon task.cancel` (0x05) — cancel the current task.
    task_cancel,
    /// `canon subtask.cancel` (0x06 `async?`).
    subtask_cancel: struct { is_async: bool },
    /// `canon subtask.drop` (0x0d).
    subtask_drop,
    /// `canon context.{get,set}` (0x0a/0x0b): a core valtype (i32/i64) + the
    /// slot index into the current task's context-local storage.
    context_get: ContextSlot,
    context_set: ContextSlot,
    /// `canon thread.yield` (0x0c `cancel?`).
    thread_yield: struct { cancellable: bool },
};

/// `canon context.{get,set}` operand pair — `t:<core valtype>` (0x7f i32 /
/// 0x7e i64) + the storage slot index.
pub const ContextSlot = struct { is_i64: bool, slot: u32 };

/// The WASI interface-version generation an import's `@x.y.z` suffix maps to
/// (ADR-0205 D1). Shapes are frozen within a generation (0.2.x) or additive
/// (0.3.x); they diverge BETWEEN generations for same-named funcs.
pub const WasiGen = enum { p2, p3, any };

/// `@version` suffix → generation. Guards against a "0.2x"-style prefix
/// false-match: the minor must terminate at end or '.'.
pub fn parseWasiGen(v: []const u8) WasiGen {
    inline for (.{ .{ "0.2", WasiGen.p2 }, .{ "0.3", WasiGen.p3 } }) |m| {
        if (std.mem.startsWith(u8, v, m[0]) and (v.len == m[0].len or v[m[0].len] == '.')) return m[1];
    }
    return .any;
}

/// `core:instantiatearg ::= name 0x12 instanceidx` — a `with` argument
/// supplying an imported instance to a core instantiation.
pub const CoreInstantiateArg = struct {
    name: []const u8,
    instance: u32,
};

/// `core:inlineexport ::= name core:sortidx`.
pub const CoreInlineExport = struct {
    name: []const u8,
    sort: CoreSort,
    index: u32,
};

/// One `core:instance` (`Binary.md` §Instance): instantiate a core module, or
/// a synthetic instance of inline exports.
pub const CoreInstance = union(enum) {
    instantiate: struct { module: u32, args: []const CoreInstantiateArg },
    inline_exports: []const CoreInlineExport,
};

/// One entry in the component's **core-func index space** (`Binary.md`: core
/// funcs are minted, in definition order, by `canon lower` / `canon
/// resource.{new,drop,rep}` and by core-func `alias`es — NOT by `canon lift`,
/// which mints a component func). Recording them in a single ordered list is
/// what lets the host map a core-func index to its true definition (a prior
/// alias-only count mis-indexed any component mixing lowers + aliases).
pub const CoreFuncDef = union(enum) {
    /// `canon lower` of component func `func` — host-implemented (the host
    /// satisfies the lowered import, e.g. a WASI-P2 trampoline). `opts` decides
    /// the core ABI the trampoline must present (notably the CM-async `async`
    /// canonopt: an async-lowered import returns a packed subtask status).
    lower: struct { func: u32, opts: CanonOpts },
    resource_new: u32,
    resource_drop: u32,
    resource_rep: u32,
    /// A `canon stream.*`/`future.*` builtin (0x0e–0x1b) over element type
    /// `type_index` — minted into the core-func index space ("(core func)").
    stream_future: struct { op: StreamFutureOp, type_index: u32 },
    /// `canon task.return` (0x09) minted into the core-func space ("(core
    /// func)") — carries the result type + lift `opts` the async runner needs.
    task_return: struct { result: ?ValType, opts: CanonOpts },
    /// A `canon waitable-set.*` / `waitable.join` (0x1f–0x23) minted into the
    /// core-func space; `memory` set only for `wait`/`poll`.
    waitable_set: struct { op: WaitableSetOp, cancellable: bool = false, memory: ?u32 = null },
    /// The CM-async task/subtask/context builtins (0x05/0x06/0x0a–0x0d)
    /// minted into the core-func space ("(core func)").
    task_cancel,
    subtask_cancel: struct { is_async: bool },
    subtask_drop,
    context_get: ContextSlot,
    context_set: ContextSlot,
    thread_yield: struct { cancellable: bool },
    /// A core-func `alias` (a core-instance export, or an `outer` alias).
    alias: AliasTarget,
};

/// `aliastarget` (`Binary.md` §Alias): the source an alias pulls a definition
/// from.
pub const AliasTarget = union(enum) {
    /// 0x00 — an export of a (component) instance.
    component_export: struct { instance: u32, name: []const u8 },
    /// 0x01 — an export of a CORE instance (what canon-lift core funcs use).
    core_export: struct { instance: u32, name: []const u8 },
    /// 0x02 — an `outer` alias `ct` levels up at index `idx`.
    outer: struct { count: u32, index: u32 },
};

/// One entry in the component **func** index space (`Binary.md`: component
/// funcs are minted, in definition order, by func `import`s, func `alias`es, and
/// `canon lift`s — NOT by `canon lower`, which mints a CORE func). Recorded in
/// section order so a `canon lower`'s `func` operand resolves to its origin (the
/// host needs the imported interface a lowered WASI import came from).
pub const ComponentFuncDef = union(enum) {
    /// A func `import` (index into `imports`).
    import: u32,
    /// A func `alias` (an instance export, or an `outer` alias).
    alias: AliasTarget,
    /// A `canon lift` (index into `canons`).
    lift: u32,
    /// A component-level `export` of a func (index into `exports`). Per
    /// `Binary.md`, exporting a func ADDS an entry to the component func index
    /// space — it does not merely name an existing one — so the space
    /// interleaves lift, export, lift, export, … in definition order. Omitting
    /// these shifted every index after the first export and made any component
    /// with two or more exports fail validation with `InvalidSort` (D-527).
    re_export: u32,
};

/// Where a component-instance index originates. Each of the four constructs
/// that mint an instance index (`Binary.md`) has its own variant. An `import`
/// carries the interface name it imports; the other three carry the index of
/// the entry that minted them. Resolving an instance index is therefore one
/// lookup, never a count of earlier indices. (A count went wrong as soon as an
/// alias or an export was minted between two definitions: wit-component lays
/// out every interface export as definition, export, definition, export, …)
pub const InstanceOrigin = union(enum) {
    /// An instance `import`; the name is the interface, e.g.
    /// `"wasi:cli/stdout@0.2.0"`. The host classifies only these.
    import: []const u8,
    /// An `instance`-section definition (instantiate or inline exports):
    /// index into `component_instances`.
    local: u32,
    /// An instance-sort `alias` (an instance exported by another instance):
    /// index into `aliases`.
    alias: u32,
    /// A component-level `export` of an instance: index into `exports`. It
    /// defines nothing; it re-exports the instance `exports[i].index` names,
    /// which is always an EARLIER index (validate.zig checks the bound at the
    /// export's definition point).
    re_export: u32,
};

/// `alias ::= sort aliastarget` — introduces a new index in `sort`'s space.
pub const Alias = struct {
    sort: Sort,
    target: AliasTarget,
};

/// Index-space snapshot taken just BEFORE an alias mints its own entry.
pub const AliasSpaceBefore = struct {
    type_space: u32,
    core_types: u32,
};

/// Lightweight recursive scan of a NESTED (inline) component: only the
/// type-sort OUTER aliases (for the resource-generativity rule) and the
/// children are modeled. The inner section body is a complete component
/// binary (with preamble).
pub const NestedComponentScan = struct {
    outer_type_aliases: []const OuterTypeRef,
    children: []const NestedComponentScan,
    /// Func-sort IMPORT names in definition order (the inner func index
    /// space prefix) — wit-component interface wrappers re-export these.
    func_import_names: []const []const u8 = &.{},
    /// Func-sort EXPORTS (name + inner func index).
    func_exports: []const NestedFuncExport = &.{},
};

pub const NestedFuncExport = struct { name: []const u8, index: u32 };

pub const OuterTypeRef = struct { count: u32, index: u32 };

/// `instantiatearg ::= name sortidx` — a `with` arg satisfying a child
/// component's import with a definition from this component's index spaces.
pub const ComponentInstantiateArg = struct {
    name: []const u8,
    sort: Sort,
    index: u32,
};

/// `inlineexport ::= exportname' sortidx`.
pub const ComponentInlineExport = struct {
    name: []const u8,
    sort: Sort,
    index: u32,
};

/// One entry in the component **type index space**, in definition order. A
/// type index is minted by a `type`-section def (`.def` = index into
/// `deftypes`) or by a type-sort `alias` / type `import` / type `export`
/// (`.named` — the type is introduced under a name).
pub const TypeSpaceEntry = union(enum) {
    def: u32,
    named: NamedOrigin,
};

/// WHICH construct minted a `.named` type index — lets a consumer chase
/// the name back to its defining scope (ADR-0183: `use`d interface types
/// live in the import's instance-type decls).
pub const NamedOrigin = union(enum) {
    /// Index into `aliases`.
    alias: u32,
    /// Index into `imports` (a `(type (eq i))` import).
    import: u32,
    /// Index into `exports` (a type export re-binding an earlier index).
    @"export": u32,
};

/// One `instance` (`Binary.md` §Instance, component level): instantiate a child
/// component with `with` args, or a synthetic instance of inline exports.
pub const ComponentInstanceDef = union(enum) {
    instantiate: struct { component: u32, args: []const ComponentInstantiateArg },
    inline_exports: []const ComponentInlineExport,
};

pub const TypeInfo = struct {
    arena: std.heap.ArenaAllocator,
    deftypes: std.ArrayList(DefType),
    /// The TRUE size of the component **type index space** — minted (in
    /// definition order) by `type`-section defs PLUS type-sort `alias`es, type
    /// `import`s, and type `export`s. `deftypes.len` alone counts only the type
    /// section, so a valid index pointing at an aliased/imported type would look
    /// out-of-bounds; validation (ADR-0176) bounds-checks against THIS instead.
    /// Always `type_space.items.len`.
    type_space_len: u32,
    /// Counts of the component's `core:module` / nested `component` sections
    /// (their index spaces), for the validator's instantiate-section bounds
    /// (ADR-0176 rule 9).
    core_module_count: u32,
    component_count: u32,
    /// Core-type index space size: core-type section defs + core-type aliases.
    core_type_count: u32,
    /// Core-memory index space size: aliases of core-instance exports of
    /// sort memory (the only top-level minting form).
    core_memory_count: u32,
    /// Core-global index space size (alias-minted, like memories).
    core_global_count: u32,
    /// Parallel to `aliases`: index-space sizes at each alias's DEFINITION
    /// point (an outer count-0 alias must not see indices it mints itself —
    /// definition order, same posture as the rule-1 type_space positions).
    alias_space_before: std.ArrayList(AliasSpaceBefore),
    /// Decoded core-type section definitions (validation model).
    core_types: std.ArrayList(CoreTypeDef),
    /// Recursive scans of nested (inline) component sections, in order.
    nested_scans: std.ArrayList(NestedComponentScan),
    /// The component type index space in definition order: each entry records
    /// whether its index was minted by a `type`-section def (`.def` = index
    /// into `deftypes`) or introduced under a name by a type-sort `alias` /
    /// type `import` / type `export` (`.named`). ADR-0176 rule 7 ("type not
    /// valid to be used as export") lets exported types reference `.named`
    /// entries only.
    type_space: std.ArrayList(TypeSpaceEntry),
    imports: std.ArrayList(Import),
    exports: std.ArrayList(Export),
    canons: std.ArrayList(Canon),
    core_instances: std.ArrayList(CoreInstance),
    component_instances: std.ArrayList(ComponentInstanceDef),
    aliases: std.ArrayList(Alias),
    /// The core-func index space in definition order (`CoreFuncDef`) — the
    /// authoritative map for resolving a core-func index to its definition.
    core_funcs: std.ArrayList(CoreFuncDef),
    /// The core-**table** index space in definition order. Core tables enter the
    /// component-level index space only via `alias core export` (a core table is
    /// never minted by canon), so each entry is the alias target. Needed by the
    /// general instantiation engine (E2) to resolve a synthetic instance's table
    /// re-export — e.g. wit-bindgen's `$fixup-args` re-exporting the shim's
    /// `$imports` table (ADR-0175).
    core_tables: std.ArrayList(AliasTarget),
    /// The component-func index space in definition order (`ComponentFuncDef`) —
    /// lets a `canon lower`'s `func` operand resolve to its origin interface.
    component_funcs: std.ArrayList(ComponentFuncDef),
    /// The component-instance index space, recording each index's origin so an
    /// imported-instance alias resolves to its WASI interface name.
    instance_origins: std.ArrayList(InstanceOrigin),

    pub fn deinit(self: *TypeInfo) void {
        self.arena.deinit();
    }

    /// Resolve a `typeidx` against the decoded type index space.
    pub fn deftype(self: *const TypeInfo, index: u32) ?DefType {
        if (index >= self.deftypes.items.len) return null;
        return self.deftypes.items[index];
    }

    /// A resolved core-func index-space entry pointing at a core-instance
    /// export (the form `canon lift`/`canon lower` reference).
    pub const CoreExportRef = struct {
        instance: u32,
        name: []const u8,
    };

    /// Resolve a core-func index → its definition (`CoreFuncDef`) in the
    /// component's core-func index space, or null if out of range.
    pub fn coreFunc(self: *const TypeInfo, core_func_idx: u32) ?CoreFuncDef {
        if (core_func_idx >= self.core_funcs.items.len) return null;
        return self.core_funcs.items[core_func_idx];
    }

    /// Resolve a core-func index → the core-instance export it aliases. Returns
    /// null if out of range or the entry is not a direct core-export alias
    /// (e.g. a `canon lower`/resource builtin, or an `outer` alias — those are
    /// resolved via `coreFunc`). Indexes the full core-func space (lowers +
    /// resource builtins + aliases interleaved), not aliases alone.
    pub fn resolveCoreFuncExport(self: *const TypeInfo, core_func_idx: u32) ?CoreExportRef {
        const def = self.coreFunc(core_func_idx) orelse return null;
        return switch (def) {
            .alias => |t| switch (t) {
                .core_export => |ce| .{ .instance = ce.instance, .name = ce.name },
                else => null,
            },
            else => null,
        };
    }

    /// Resolve a core-**table** index → the core-instance export it aliases
    /// (`{instance, name}`), or null if out of range / not a core-export alias.
    /// The general instantiation engine uses this to find which built instance
    /// owns a table a synthetic instance re-exports (the shim `$imports` table).
    pub fn resolveCoreTableExport(self: *const TypeInfo, core_table_idx: u32) ?CoreExportRef {
        if (core_table_idx >= self.core_tables.items.len) return null;
        return switch (self.core_tables.items[core_table_idx]) {
            .core_export => |ce| .{ .instance = ce.instance, .name = ce.name },
            else => null,
        };
    }

    /// An imported WASI interface + func name a lowered component func came
    /// from, plus the interface-version GENERATION (ADR-0205 D1): 0.2.x and
    /// 0.3.x share many interface/func names with DIFFERENT shapes (filesystem
    /// `stat`, sockets), so the adapter dispatches per generation. `.any` =
    /// unversioned import (matches every row).
    pub const ImportRef = struct { interface: []const u8, func: []const u8, gen: WasiGen = .any };

    /// Resolve a component **func** index (a `canon lower`'s `func` operand) back
    /// to the imported interface + func name it aliases — so the host classifies
    /// a lowered WASI import by its COMPONENT interface (`wasi/adapter`) instead
    /// of the core module's hand-chosen import names. The `@version` suffix is
    /// stripped to match the adapter's interface table. Returns null when the
    /// func is not a func-alias of an imported instance (a direct func import, a
    /// `canon lift`, or an alias of a locally-defined instance).
    pub fn resolveComponentImport(self: *const TypeInfo, component_func_idx: u32) ?ImportRef {
        if (component_func_idx >= self.component_funcs.items.len) return null;
        const ce = switch (self.component_funcs.items[component_func_idx]) {
            .alias => |t| switch (t) {
                .component_export => |c| c,
                else => return null,
            },
            else => return null,
        };
        const full = switch (self.instanceOrigin(ce.instance) orelse return null) {
            .import => |name| name,
            .local, .alias, .re_export => return null,
        };
        const at = std.mem.findScalar(u8, full, '@');
        const interface = if (at) |i| full[0..i] else full;
        const gen: WasiGen = if (at) |i| parseWasiGen(full[i + 1 ..]) else .any;
        return .{ .interface = interface, .func = ce.name, .gen = gen };
    }

    /// A component `func` export resolved to the core exports the host must
    /// invoke: the lowered core func + the canon options' realloc / post-return
    /// core funcs.
    pub const ResolvedLift = struct {
        core_func: CoreExportRef,
        realloc: ?CoreExportRef,
        post_return: ?CoreExportRef,
        string_encoding: StringEncoding,
        /// The CM-async `async` canonopt (0x06) on this lift — true when the
        /// export is a stackless-async task (ADR-0195 c-2b: the graph
        /// async-runner routes such an export through `driveScheduler`).
        is_async: bool,
        /// The async `callback` core:funcidx (0x07), resolved to its core-instance
        /// export, when present (lift-only; implies `is_async`). The graph
        /// async-runner re-enters this per delivered event.
        callback: ?CoreExportRef,
    };

    /// One introspected func export: the name + its WIT-typed signature,
    /// taken from the SELF-DESCRIBING binary (ADR-0183 / CWFS ADR-0135 —
    /// no `.wit` sidecar). `name` is owned by the `exportedFuncs` caller
    /// (interface-nested funcs need a synthesized `<iface>#<func>` path);
    /// `ty` borrows from this `TypeInfo`. Free via `freeExportedFuncs`.
    pub const ExportedFunc = struct {
        name: []const u8,
        ty: FuncType,
    };

    /// Free a slice returned by `exportedFuncs` (names are alloc-owned;
    /// the types still borrow from the `TypeInfo`).
    pub fn freeExportedFuncs(alloc: Allocator, funcs: []ExportedFunc) void {
        for (funcs) |f| alloc.free(f.name);
        alloc.free(funcs);
    }

    /// The origin that DEFINES instance-space index `instance_index`: a
    /// `re_export` is followed to the instance it re-exports, so the result is
    /// never `.re_export`. Null when out of range, or when a re-export does not
    /// name an earlier index (validation rejects that; the check keeps the walk
    /// terminating on unvalidated input). This is `liftForFuncIndex`'s twin one
    /// index space over: D-527 made an export mint an index in both spaces,
    /// but only the func side learned to follow a re-export to its definition.
    /// Every instance-space resolver goes through here, so an imported
    /// instance re-exported by the component still answers as that import.
    pub fn instanceOrigin(self: *const TypeInfo, instance_index: u32) ?InstanceOrigin {
        var idx = instance_index;
        while (idx < self.instance_origins.items.len) {
            const origin = self.instance_origins.items[idx];
            switch (origin) {
                .re_export => |ei| {
                    if (ei >= self.exports.items.len) return null;
                    const target = self.exports.items[ei].index;
                    if (target >= idx) return null;
                    idx = target;
                },
                .import, .local, .alias => return origin,
            }
        }
        return null;
    }

    /// The `component_instances` index that defines instance-space index
    /// `instance_index` (re-exports followed); null for an imported or
    /// alias-minted instance, or an out-of-range index.
    pub fn localInstanceOrdinal(self: *const TypeInfo, instance_index: u32) ?u32 {
        return switch (self.instanceOrigin(instance_index) orelse return null) {
            .local => |d| if (d < self.component_instances.items.len) d else null,
            .import, .alias, .re_export => null,
        };
    }

    /// Map an instance-space index to its LOCAL component-instance
    /// definition; null for import- or alias-originated or out-of-range
    /// indices.
    fn localInstanceDef(self: *const TypeInfo, instance_index: u32) ?ComponentInstanceDef {
        const d = self.localInstanceOrdinal(instance_index) orelse return null;
        return self.component_instances.items[d];
    }

    /// Resolve a func-export PATH to its component-func index: a top-level
    /// func export name, or `<instance-export>#<func>` addressing a func
    /// inside an exported INSTANCE (wit-bindgen interface exports; D-322).
    fn exportedFuncIndex(self: *const TypeInfo, path: []const u8) ?u32 {
        if (std.mem.findScalar(u8, path, '#')) |hash| {
            const iface = path[0..hash];
            const fname = path[hash + 1 ..];
            for (self.exports.items) |e| {
                if (std.meta.activeTag(e.sort) != .instance) continue;
                if (!std.mem.eql(u8, e.name, iface)) continue;
                switch (self.localInstanceDef(e.index) orelse return null) {
                    .inline_exports => |exps| for (exps) |ie| {
                        if (std.meta.activeTag(ie.sort) == .func and std.mem.eql(u8, ie.name, fname)) return ie.index;
                    },
                    // A wit-component interface WRAPPER: a nested component
                    // that re-exports its func imports under the interface
                    // names; chase export -> inner import -> instantiate arg.
                    .instantiate => |it| {
                        if (it.component >= self.nested_scans.items.len) return null;
                        const scan = self.nested_scans.items[it.component];
                        for (scan.func_exports) |fe| {
                            if (!std.mem.eql(u8, fe.name, fname)) continue;
                            if (fe.index >= scan.func_import_names.len) return null; // non-import-backed — deferred
                            const iname = scan.func_import_names[fe.index];
                            for (it.args) |arg| {
                                if (std.meta.activeTag(arg.sort) == .func and std.mem.eql(u8, arg.name, iname)) return arg.index;
                            }
                            return null;
                        }
                        return null;
                    },
                }
                return null;
            }
            return null;
        }
        for (self.exports.items) |e| {
            if (e.sort == .func and std.mem.eql(u8, e.name, path)) return e.index;
        }
        return null;
    }

    /// The WIT `functype` of a lifted func export, or null when the export
    /// does not resolve to a concrete local functype (alias-minted types
    /// stay deferred — concrete components lift with an explicit type).
    pub fn resolveFuncType(self: *const TypeInfo, export_name: []const u8) ?FuncType {
        const fi = self.exportedFuncIndex(export_name) orelse return null;
        const lift = self.liftForFuncIndex(fi) orelse return null;
        const ti = lift.type_index;
        if (ti >= self.type_space.items.len) return null;
        switch (self.type_space.items[ti]) {
            .def => |d| switch (self.deftypes.items[d]) {
                .func => |ft| return ft,
                else => return null,
            },
            .named => return null, // alias-minted signature — deferred
        }
    }

    /// The `canon lift` a component-FUNC index resolves to, via the
    /// definition-order `component_funcs` index space (func aliases /
    /// imports occupy earlier slots in real wit-bindgen output — counting
    /// lifts by ordinal mis-resolves those components).
    fn liftForFuncIndex(self: *const TypeInfo, fi: u32) ?@TypeOf(@as(Canon, undefined).lift) {
        if (fi < self.component_funcs.items.len) {
            switch (self.component_funcs.items[fi]) {
                .lift => |ci| return self.canons.items[ci].lift,
                // A re-export resolves to whatever it re-exports. The target is
                // always defined EARLIER in the space (an export cannot forward-
                // reference), so this terminates; the depth bound is belt-and-
                // braces against a malformed input that claims otherwise.
                .re_export => |ei| {
                    if (ei >= self.exports.items.len) return null;
                    const target = self.exports.items[ei].index;
                    if (target >= fi) return null;
                    return self.liftForFuncIndex(target);
                },
                .import, .alias => return null,
            }
        }
        // Fallback for hand-built TypeInfos without a populated func space:
        // the historical lift-ordinal walk.
        var li: u32 = 0;
        for (self.canons.items) |c| {
            if (c != .lift) continue;
            if (li == fi) return c.lift;
            li += 1;
        }
        return null;
    }

    /// Introspect every typed func export (ADR-0183 F1): top-level func
    /// exports AND funcs nested in exported instances (wit-bindgen
    /// interface exports), the latter path-qualified `<iface>#<func>` —
    /// exactly the form `resolveFuncType` / `invokeTyped` accept. Free
    /// the result via `freeExportedFuncs` (names are alloc-owned; types
    /// borrow from this `TypeInfo`).
    pub fn exportedFuncs(self: *const TypeInfo, alloc: Allocator) Allocator.Error![]ExportedFunc {
        var out: std.ArrayList(ExportedFunc) = .empty;
        errdefer {
            for (out.items) |f| alloc.free(f.name);
            out.deinit(alloc);
        }
        for (self.exports.items) |e| {
            switch (std.meta.activeTag(e.sort)) {
                .func => {
                    const ft = self.resolveFuncType(e.name) orelse continue;
                    try out.append(alloc, .{ .name = try alloc.dupe(u8, e.name), .ty = ft });
                },
                .instance => switch (self.localInstanceDef(e.index) orelse continue) {
                    .inline_exports => |exps| for (exps) |ie| {
                        if (std.meta.activeTag(ie.sort) != .func) continue;
                        try self.appendQualifiedFunc(&out, alloc, e.name, ie.name);
                    },
                    .instantiate => |it| {
                        if (it.component >= self.nested_scans.items.len) continue;
                        for (self.nested_scans.items[it.component].func_exports) |fe| {
                            try self.appendQualifiedFunc(&out, alloc, e.name, fe.name);
                        }
                    },
                },
                else => {},
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// Append `<iface>#<func>` when the path resolves to a concrete
    /// functype (non-resolving entries are skipped, mirroring the
    /// top-level walk — alias-minted signatures stay deferred).
    fn appendQualifiedFunc(
        self: *const TypeInfo,
        out: *std.ArrayList(ExportedFunc),
        alloc: Allocator,
        iface: []const u8,
        fname: []const u8,
    ) Allocator.Error!void {
        const path = try std.fmt.allocPrint(alloc, "{s}#{s}", .{ iface, fname });
        const ft = self.resolveFuncType(path) orelse {
            alloc.free(path);
            return;
        };
        try out.append(alloc, .{ .name = path, .ty = ft });
    }

    /// Resolve a component `func` export (by name) to its `canon lift` and the
    /// underlying core exports — so the host invokes the resolved core funcs
    /// instead of guessing names. Assumes the func index space is populated by
    /// `canon lift`s in order (true for a single-component leaf; func imports /
    /// aliases occupy earlier slots and are handled when a component uses them).
    pub fn resolveLiftedFunc(self: *const TypeInfo, export_name: []const u8) ?ResolvedLift {
        const fi = self.exportedFuncIndex(export_name) orelse return null;
        const lift = self.liftForFuncIndex(fi) orelse return null;
        return .{
            .core_func = self.resolveCoreFuncExport(lift.core_func) orelse return null,
            .realloc = if (lift.opts.realloc) |r| self.resolveCoreFuncExport(r) else null,
            .post_return = if (lift.opts.post_return) |p| self.resolveCoreFuncExport(p) else null,
            .string_encoding = lift.opts.string_encoding,
            .is_async = lift.opts.is_async,
            .callback = if (lift.opts.callback) |cb| self.resolveCoreFuncExport(cb) else null,
        };
    }
};

pub const Error = error{
    Truncated,
    InvalidValType,
    InvalidDefType,
    InvalidFuncType,
    InvalidTypeIndex,
    InvalidName,
    InvalidExternDesc,
    InvalidSort,
    /// A malformed `canon` definition / `canonopt`.
    InvalidCanon,
    /// A malformed `core:instance` / `alias` definition.
    InvalidInstance,
    InvalidAlias,
    /// A `canon` builtin not yet decoded (async / stream / future / thread).
    UnsupportedCanon,
    /// `enum` with zero labels (spec requires `> 0`).
    EmptyEnum,
    /// `flags` label count outside `0 < n <= 32` (spec cap).
    InvalidFlagsCount,
    /// A spec-defined form not yet decoded (compound defvaltype → B-chunks;
    /// component/instance/resource type → C-chunks). Typed deferral, not a
    /// silent skip (`no_workaround`).
    UnsupportedTypeForm,
    TrailingBytes,
    OutOfMemory,
} || leb128.Error;

// ============================================================
// Primitive decode helpers (operate on a section body + cursor)
// ============================================================

fn primFromOpcode(op: u8) Error!PrimValType {
    return switch (op) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x7a, 0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x64 => @enumFromInt(op),
        // Compound defvaltype opcodes are valid deftypes but never inline
        // valtypes; in a valtype position they are malformed.
        else => Error.InvalidValType,
    };
}

/// `valtype ::= typeidx | primvaltype` via the negative-SLEB128 scheme.
fn decodeValType(body: []const u8, pos: *usize) Error!ValType {
    const v = try leb128.readSleb128(i64, body, pos);
    if (v < 0) return .{ .primitive = try primFromOpcode(@intCast(v & 0x7f)) };
    if (v > std.math.maxInt(u32)) return Error.InvalidTypeIndex;
    return .{ .type_index = @intCast(v) };
}

/// `label' ::= len:u32 label` / `name ::= len:u32 bytes` — a length-prefixed
/// borrowed slice (no prefix byte).
fn decodeLabel(body: []const u8, pos: *usize) Error![]const u8 {
    const len = try leb128.readUleb128(u32, body, pos);
    const len_usize: usize = @intCast(len);
    if (len_usize > body.len - pos.*) return Error.InvalidName;
    const s = body[pos.* .. pos.* + len_usize];
    pos.* += len_usize;
    return s;
}

/// `vec(label')` — a length-prefixed sequence of length-prefixed labels
/// (enum/flags label lists). Labels borrow from the input.
fn decodeLabelVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const []const u8 {
    const count = try leb128.readUleb128(u32, body, pos);
    var labels: std.ArrayList([]const u8) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try labels.append(arena, try decodeLabel(body, pos));
    }
    return labels.toOwnedSlice(arena);
}

/// `importname' ::= (0x00|0x01) len name | 0x02 len name versionsuffix`.
/// The 0x00/0x01 prefixes are the pre-1.0 plain/interface distinction (both
/// yield the base name); 0x02 carries a trailing semver suffix, read and
/// dropped (spec: "ignored for validation except diagnostics"). Returns the
/// base name (borrowed).
fn decodeImportExportName(body: []const u8, pos: *usize) Error![]const u8 {
    if (pos.* >= body.len) return Error.Truncated;
    const prefix = body[pos.*];
    pos.* += 1;
    switch (prefix) {
        0x00, 0x01 => return try decodeLabel(body, pos),
        0x02 => {
            const name = try decodeLabel(body, pos);
            _ = try decodeLabel(body, pos); // versionsuffix — dropped
            return name;
        },
        else => return Error.InvalidName,
    }
}

fn decodeFuncType(arena: Allocator, body: []const u8, pos: *usize, is_async: bool) Error!FuncType {
    const param_count = try leb128.readUleb128(u32, body, pos);
    var params: std.ArrayList(NamedVal) = .empty;
    var i: u32 = 0;
    while (i < param_count) : (i += 1) {
        const name = try decodeLabel(body, pos);
        const ty = try decodeValType(body, pos);
        try params.append(arena, .{ .name = name, .ty = ty });
    }

    const result = try decodeResultList(body, pos);
    return .{ .params = try params.toOwnedSlice(arena), .result = result, .is_async = is_async };
}

/// `resultlist ::= 0x00 valtype | 0x01 0x00` — a single optional result.
/// Shared by `functype` and `canon task.return`.
fn decodeResultList(body: []const u8, pos: *usize) Error!?ValType {
    if (pos.* >= body.len) return Error.InvalidFuncType;
    const tag = body[pos.*];
    pos.* += 1;
    return switch (tag) {
        0x00 => try decodeValType(body, pos),
        0x01 => blk: {
            if (pos.* >= body.len or body[pos.*] != 0x00) return Error.InvalidFuncType;
            pos.* += 1;
            break :blk null;
        },
        else => Error.InvalidFuncType,
    };
}

/// Store a `ValType` on the arena and return a stable pointer (for the
/// recursive list/option element types).
fn allocValType(arena: Allocator, ty: ValType) Error!*const ValType {
    const p = try arena.create(ValType);
    p.* = ty;
    return p;
}

/// `vec(labelvaltype)` — record fields (named, typed).
fn decodeNamedValVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const NamedVal {
    const count = try leb128.readUleb128(u32, body, pos);
    var out: std.ArrayList(NamedVal) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeLabel(body, pos);
        try out.append(arena, .{ .name = name, .ty = try decodeValType(body, pos) });
    }
    return out.toOwnedSlice(arena);
}

/// `vec(valtype)` — tuple element types.
fn decodeValTypeVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const ValType {
    const count = try leb128.readUleb128(u32, body, pos);
    var out: std.ArrayList(ValType) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) try out.append(arena, try decodeValType(body, pos));
    return out.toOwnedSlice(arena);
}

/// `<T>? ::= 0x00 | 0x01 T` — an optional valtype.
fn decodeOptionalValType(body: []const u8, pos: *usize) Error!?ValType {
    if (pos.* >= body.len) return Error.Truncated;
    const tag = body[pos.*];
    pos.* += 1;
    return switch (tag) {
        0x00 => null,
        0x01 => try decodeValType(body, pos),
        else => Error.InvalidDefType,
    };
}

/// `vec(case)` — `case ::= label' valtype? 0x00` (the trailing `0x00` is the
/// retired `refines` field, required to be zero in the current spec).
fn decodeCaseVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const Case {
    const count = try leb128.readUleb128(u32, body, pos);
    var out: std.ArrayList(Case) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeLabel(body, pos);
        const payload = try decodeOptionalValType(body, pos);
        if (pos.* >= body.len or body[pos.*] != 0x00) return Error.InvalidDefType;
        pos.* += 1;
        try out.append(arena, .{ .name = name, .payload = payload });
    }
    return out.toOwnedSlice(arena);
}

fn decodeDefType(arena: Allocator, body: []const u8, pos: *usize) Error!DefType {
    // resourcetype (0x3f/0x3e) sits BELOW 0x40 — as sleb it reads positive
    // (the sign bit 0x40 is clear), unlike every other deftype op. Peek raw.
    if (pos.* < body.len and (body[pos.*] == 0x3f or body[pos.*] == 0x3e)) {
        const op_raw = body[pos.*];
        pos.* += 1;
        if (op_raw == 0x3e) return Error.UnsupportedTypeForm; // async dtor form
        // rep valtype: 0x7f (i32) / 0x7e (i64 🐘).
        if (pos.* >= body.len) return Error.Truncated;
        const rep = body[pos.*];
        pos.* += 1;
        if (rep != 0x7f and rep != 0x7e) return Error.InvalidDefType;
        if (pos.* >= body.len) return Error.Truncated;
        const has_dtor = body[pos.*];
        pos.* += 1;
        var dtor: ?u32 = null;
        if (has_dtor == 0x01) {
            dtor = try leb128.readUleb128(u32, body, pos);
        } else if (has_dtor != 0x00) return Error.InvalidDefType;
        return .{ .resource = .{ .dtor = dtor } };
    }
    const v = try leb128.readSleb128(i64, body, pos);
    if (v >= 0) return Error.InvalidDefType; // a deftype is never a bare typeidx
    const op: u8 = @intCast(v & 0x7f);
    return switch (op) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x7a, 0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x64 => .{ .value = .{ .primitive = @enumFromInt(op) } },
        0x40 => .{ .func = try decodeFuncType(arena, body, pos, false) },
        0x43 => .{ .func = try decodeFuncType(arena, body, pos, true) },
        0x6d => blk: { // enum: vec(label')
            const labels = try decodeLabelVec(arena, body, pos);
            if (labels.len == 0) break :blk Error.EmptyEnum;
            break :blk .{ .enum_ = .{ .labels = labels } };
        },
        0x6e => blk: { // flags: vec(label'), 0 < n <= 32
            const labels = try decodeLabelVec(arena, body, pos);
            if (labels.len == 0 or labels.len > 32) break :blk Error.InvalidFlagsCount;
            break :blk .{ .flags = .{ .labels = labels } };
        },
        0x72 => blk: { // record: vec(labelvaltype), >0 fields
            const fields = try decodeNamedValVec(arena, body, pos);
            if (fields.len == 0) break :blk Error.InvalidDefType;
            break :blk .{ .record = .{ .fields = fields } };
        },
        0x71 => blk: { // variant: vec(case), >0 cases
            const cases = try decodeCaseVec(arena, body, pos);
            if (cases.len == 0) break :blk Error.InvalidDefType;
            break :blk .{ .variant = .{ .cases = cases } };
        },
        0x70 => .{ .list = .{ .element = try allocValType(arena, try decodeValType(body, pos)), .fixed_length = null } },
        0x67 => blk: { // fixed-length list: valtype len:u32
            const elem = try allocValType(arena, try decodeValType(body, pos));
            break :blk .{ .list = .{ .element = elem, .fixed_length = try leb128.readUleb128(u32, body, pos) } };
        },
        0x6f => blk: { // tuple: vec(valtype), >0
            const tys = try decodeValTypeVec(arena, body, pos);
            if (tys.len == 0) break :blk Error.InvalidDefType;
            break :blk .{ .tuple = .{ .types = tys } };
        },
        0x6b => .{ .option = .{ .payload = try allocValType(arena, try decodeValType(body, pos)) } },
        0x6a => blk: { // result: ok? err?
            const ok = try decodeOptionalValType(body, pos);
            break :blk .{ .result = .{ .ok = ok, .err = try decodeOptionalValType(body, pos) } };
        },
        0x69 => .{ .own = try leb128.readUleb128(u32, body, pos) },
        0x68 => .{ .borrow = try leb128.readUleb128(u32, body, pos) },
        // stream<t?> / future<t?> (CM-async, WASI 0.3): the element type is an
        // OPTIONAL valtype (`<valtype>?` = 0x00 | 0x01 valtype).
        0x66 => .{ .stream = .{ .payload = try decodeOptionalValType(body, pos) } },
        0x65 => .{ .future = .{ .payload = try decodeOptionalValType(body, pos) } },
        0x41 => .{ .component_type = try decodeComponentType(arena, body, pos) },
        0x42 => .{ .instance_type = try decodeInstanceType(arena, body, pos) },

        else => Error.InvalidDefType,
    };
}

/// `alias ::= sort aliastarget` (shared by the alias section + instancedecls).
fn decodeAlias(body: []const u8, pos: *usize) Error!Alias {
    const sort = try decodeSort(body, pos);
    if (pos.* >= body.len) return Error.Truncated;
    const tt = body[pos.*];
    pos.* += 1;
    const target: AliasTarget = switch (tt) {
        0x00 => blk: {
            const inst = try leb128.readUleb128(u32, body, pos);
            break :blk .{ .component_export = .{ .instance = inst, .name = try decodeLabel(body, pos) } };
        },
        0x01 => blk: {
            const inst = try leb128.readUleb128(u32, body, pos);
            break :blk .{ .core_export = .{ .instance = inst, .name = try decodeLabel(body, pos) } };
        },
        0x02 => blk: {
            const ct = try leb128.readUleb128(u32, body, pos);
            break :blk .{ .outer = .{ .count = ct, .index = try leb128.readUleb128(u32, body, pos) } };
        },
        else => return Error.InvalidAlias,
    };
    return .{ .sort = sort, .target = target };
}

/// `instancedecl ::= 0x00 core:type | 0x01 type | 0x02 alias | 0x04 exportdecl`.
fn decodeInstanceDecl(arena: Allocator, body: []const u8, pos: *usize) Error!InstanceDecl {
    if (pos.* >= body.len) return Error.Truncated;
    const tag = body[pos.*];
    pos.* += 1;
    return switch (tag) {
        // core:type inside an instancetype — not used by the P2-CLI WASI types.
        0x00 => Error.UnsupportedTypeForm,
        0x01 => blk: {
            const dt = try arena.create(DefType);
            dt.* = try decodeDefType(arena, body, pos);
            break :blk .{ .type_def = dt };
        },
        0x02 => .{ .alias = try decodeAlias(body, pos) },
        0x04 => blk: {
            const name = try decodeImportExportName(body, pos);
            break :blk .{ .export_decl = .{ .name = name, .desc = try decodeExternDesc(body, pos) } };
        },
        else => Error.InvalidInstance,
    };
}

/// `instancetype ::= 0x42 vec(instancedecl)`.
fn decodeInstanceType(arena: Allocator, body: []const u8, pos: *usize) Error!InstanceType {
    const count = try leb128.readUleb128(u32, body, pos);
    var decls: std.ArrayList(InstanceDecl) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) try decls.append(arena, try decodeInstanceDecl(arena, body, pos));
    return .{ .decls = try decls.toOwnedSlice(arena) };
}

/// `componenttype ::= 0x41 vec(componentdecl)`;
/// `componentdecl ::= 0x03 importdecl | instancedecl`.
fn decodeComponentType(arena: Allocator, body: []const u8, pos: *usize) Error!ComponentType {
    const count = try leb128.readUleb128(u32, body, pos);
    var decls: std.ArrayList(ComponentDecl) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos.* >= body.len) return Error.Truncated;
        if (body[pos.*] == 0x03) {
            pos.* += 1;
            const name = try decodeImportExportName(body, pos);
            try decls.append(arena, .{ .import_decl = .{ .name = name, .desc = try decodeExternDesc(body, pos) } });
        } else {
            try decls.append(arena, .{ .instance_decl = try decodeInstanceDecl(arena, body, pos) });
        }
    }
    return .{ .decls = try decls.toOwnedSlice(arena) };
}

/// `sort ::= 0x00 core:sort | 0x01 func | 0x02 value | 0x03 type | 0x04
/// component | 0x05 instance`.
fn decodeSort(body: []const u8, pos: *usize) Error!Sort {
    if (pos.* >= body.len) return Error.Truncated;
    const sort_byte = body[pos.*];
    pos.* += 1;
    return switch (sort_byte) {
        0x00 => blk: {
            if (pos.* >= body.len) return Error.Truncated;
            const cs = body[pos.*];
            pos.* += 1;
            break :blk .{ .core = @enumFromInt(cs) };
        },
        0x01 => .func,
        0x02 => .value,
        0x03 => .type,
        0x04 => .component,
        0x05 => .instance,
        else => Error.InvalidSort,
    };
}

fn decodeSortIdx(body: []const u8, pos: *usize) Error!struct { sort: Sort, index: u32 } {
    const sort = try decodeSort(body, pos);
    return .{ .sort = sort, .index = try leb128.readUleb128(u32, body, pos) };
}

fn decodeExternDesc(body: []const u8, pos: *usize) Error!ExternDesc {
    if (pos.* >= body.len) return Error.Truncated;
    const tag = body[pos.*];
    pos.* += 1;
    switch (tag) {
        0x00 => {
            if (pos.* >= body.len or body[pos.*] != 0x11) return Error.InvalidExternDesc;
            pos.* += 1; // 0x11 = core:sort module
            return .{ .core_module = try leb128.readUleb128(u32, body, pos) };
        },
        0x01 => return .{ .func = try leb128.readUleb128(u32, body, pos) },
        0x04 => return .{ .component = try leb128.readUleb128(u32, body, pos) },
        0x05 => return .{ .instance = try leb128.readUleb128(u32, body, pos) },
        0x02 => { // value bound: 0x00 eq valueidx | 0x01 valtype
            if (pos.* >= body.len) return Error.Truncated;
            const vtag = body[pos.*];
            pos.* += 1;
            return switch (vtag) {
                0x00 => blk: { // eq valueidx
                    _ = try leb128.readUleb128(u32, body, pos);
                    break :blk .{ .value_bound = null };
                },
                0x01 => .{ .value_bound = try decodeValType(body, pos) },
                else => Error.InvalidExternDesc,
            };
        },
        0x03 => { // type bound: 0x00 eq typeidx | 0x01 sub resource
            if (pos.* >= body.len) return Error.Truncated;
            const tb = body[pos.*];
            pos.* += 1;
            return switch (tb) {
                0x00 => .{ .type_bound = .{ .eq = try leb128.readUleb128(u32, body, pos) } },
                0x01 => .{ .type_bound = .sub_resource },
                else => Error.InvalidExternDesc,
            };
        },
        else => return Error.InvalidExternDesc,
    }
}

// ============================================================
// Section-level decode
// ============================================================

fn decodeTypeSection(arena: Allocator, out: *std.ArrayList(DefType), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try out.append(arena, try decodeDefType(arena, body, &pos));
    }
    if (pos != body.len) return Error.TrailingBytes;
}

fn decodeImportSection(arena: Allocator, out: *std.ArrayList(Import), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeImportExportName(body, &pos);
        const desc = try decodeExternDesc(body, &pos);
        try out.append(arena, .{ .name = name, .desc = desc });
    }
    if (pos != body.len) return Error.TrailingBytes;
}

fn decodeExportSection(arena: Allocator, out: *std.ArrayList(Export), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeImportExportName(body, &pos);
        const si = try decodeSortIdx(body, &pos);
        // externdesc? ::= 0x00 (none) | 0x01 externdesc
        if (pos >= body.len) return Error.Truncated;
        const has_desc = body[pos];
        pos += 1;
        const desc: ?ExternDesc = switch (has_desc) {
            0x00 => null,
            0x01 => try decodeExternDesc(body, &pos),
            else => return Error.InvalidExternDesc,
        };
        try out.append(arena, .{ .name = name, .sort = si.sort, .index = si.index, .desc = desc });
    }
    if (pos != body.len) return Error.TrailingBytes;
}

/// `opts ::= vec(canonopt)` (`Binary.md`). Decodes the canonical-ABI options;
/// async (0x06) / callback (0x07) defer to the async phase.

// ---- nested-component scan (resource-generativity rule input) ----

/// Recursively scan a nested component's binary for type-sort OUTER
/// aliases (alias sections) and deeper nested components. Decode errors
/// inside the nested binary propagate (an unparseable inner component is
/// an invalid component).
fn scanNestedComponent(a: std.mem.Allocator, bytes: []const u8) Error!NestedComponentScan {
    // arena-allocated; no deinit (the TypeInfo arena owns everything). A
    // malformed nested binary = an invalid component (decode errors map).
    const inner = decode.decode(a, bytes) catch |e| return switch (e) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidDefType,
    };
    var outer_refs: std.ArrayList(OuterTypeRef) = .empty;
    var children: std.ArrayList(NestedComponentScan) = .empty;
    var func_imports: std.ArrayList([]const u8) = .empty;
    var func_exports: std.ArrayList(NestedFuncExport) = .empty;
    for (inner.sections.items) |sec| switch (sec.id) {
        .alias => {
            var tmp: std.ArrayList(Alias) = .empty;
            try decodeAliasSection(a, &tmp, sec.body);
            for (tmp.items) |al| {
                if (std.meta.activeTag(al.sort) != .type) continue;
                switch (al.target) {
                    .outer => |o| try outer_refs.append(a, .{ .count = o.count, .index = o.index }),
                    else => {},
                }
            }
        },
        .import => {
            var tmp: std.ArrayList(Import) = .empty;
            try decodeImportSection(a, &tmp, sec.body);
            for (tmp.items) |imp| switch (imp.desc) {
                .func => try func_imports.append(a, imp.name),
                else => {},
            };
        },
        .@"export" => {
            var tmp: std.ArrayList(Export) = .empty;
            try decodeExportSection(a, &tmp, sec.body);
            for (tmp.items) |ex| {
                if (std.meta.activeTag(ex.sort) == .func)
                    try func_exports.append(a, .{ .name = ex.name, .index = ex.index });
            }
        },
        .component => try children.append(a, try scanNestedComponent(a, sec.body)),
        else => {},
    };
    return .{
        .outer_type_aliases = outer_refs.items,
        .children = children.items,
        .func_import_names = func_imports.items,
        .func_exports = func_exports.items,
    };
}

fn decodeCanonOpts(body: []const u8, pos: *usize) Error!CanonOpts {
    var opts: CanonOpts = .{};
    const count = try leb128.readUleb128(u32, body, pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos.* >= body.len) return Error.Truncated;
        const tag = body[pos.*];
        pos.* += 1;
        switch (tag) {
            0x00 => opts.string_encoding = .utf8,
            0x01 => opts.string_encoding = .utf16,
            0x02 => opts.string_encoding = .latin1_utf16,
            0x03 => opts.memory = try leb128.readUleb128(u32, body, pos),
            0x04 => opts.realloc = try leb128.readUleb128(u32, body, pos),
            0x05 => opts.post_return = try leb128.readUleb128(u32, body, pos),
            0x06 => opts.is_async = true, // CM-async `async`
            0x07 => opts.callback = try leb128.readUleb128(u32, body, pos), // `callback` core:funcidx
            else => return Error.InvalidCanon,
        }
    }
    return opts;
}

/// `async?` immediate (`Binary.md`): a single byte 0x00 (sync) | 0x01 (async).
fn decodeAsyncFlag(body: []const u8, pos: *usize) Error!bool {
    if (pos.* >= body.len) return Error.Truncated;
    const b = body[pos.*];
    pos.* += 1;
    return switch (b) {
        0x00 => false,
        0x01 => true,
        else => return Error.InvalidCanon,
    };
}

/// `canon stream.*`/`future.*` (0x0e–0x1b): `op t:<typeidx>` then, per op,
/// `opts` (read/write) or an `async?` flag (cancel-read/write).
fn decodeStreamFutureCanon(op: StreamFutureOp, body: []const u8, pos: *usize) Error!Canon {
    const type_index = try leb128.readUleb128(u32, body, pos);
    var sf: @FieldType(Canon, "stream_future") = .{ .op = op, .type_index = type_index };
    switch (op) {
        .stream_read, .stream_write, .future_read, .future_write => sf.opts = try decodeCanonOpts(body, pos),
        .stream_cancel_read, .stream_cancel_write, .future_cancel_read, .future_cancel_write => sf.is_async = try decodeAsyncFlag(body, pos),
        // new / drop-readable / drop-writable carry only the element typeidx.
        .stream_new, .stream_drop_readable, .stream_drop_writable, .future_new, .future_drop_readable, .future_drop_writable => {},
    }
    return .{ .stream_future = sf };
}

/// `canon waitable-set.{wait,poll}` (0x20/0x21): `cancel?` flag byte (0x00/0x01)
/// then a `core:memidx` (where the event tuple is written).
fn decodeWaitableSetWait(op: WaitableSetOp, body: []const u8, pos: *usize) Error!Canon {
    const cancellable = try decodeFlagByte(body, pos);
    const memory = try leb128.readUleb128(u32, body, pos);
    return .{ .waitable_set = .{ .op = op, .cancellable = cancellable, .memory = memory } };
}

/// A one-byte 0x00/0x01 flag (`async?` / `cancel?` in `Binary.md`).
fn decodeFlagByte(body: []const u8, pos: *usize) Error!bool {
    if (pos.* >= body.len) return Error.UnsupportedCanon;
    const b = body[pos.*];
    pos.* += 1;
    return switch (b) {
        0x00 => false,
        0x01 => true,
        else => Error.UnsupportedCanon,
    };
}

/// `canon context.{get,set}` operands: `t:<core valtype>` (only i32/i64 are
/// valid per `CanonicalABI.md`) + the slot index.
fn decodeContextSlot(body: []const u8, pos: *usize) Error!ContextSlot {
    if (pos.* >= body.len) return Error.Truncated;
    const vt = body[pos.*];
    pos.* += 1;
    const is_i64 = switch (vt) {
        0x7f => false,
        0x7e => true,
        else => return Error.UnsupportedCanon,
    };
    return .{ .is_i64 = is_i64, .slot = try leb128.readUleb128(u32, body, pos) };
}

fn decodeCanonSection(arena: Allocator, out: *std.ArrayList(Canon), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos >= body.len) return Error.Truncated;
        const op = body[pos];
        pos += 1;
        const canon: Canon = switch (op) {
            0x00 => blk: { // canon lift: 0x00 funcidx opts typeidx
                if (pos >= body.len or body[pos] != 0x00) return Error.InvalidCanon;
                pos += 1;
                const core_func = try leb128.readUleb128(u32, body, &pos);
                const opts = try decodeCanonOpts(body, &pos);
                break :blk .{ .lift = .{ .core_func = core_func, .opts = opts, .type_index = try leb128.readUleb128(u32, body, &pos) } };
            },
            0x01 => blk: { // canon lower: 0x01 funcidx opts
                if (pos >= body.len or body[pos] != 0x00) return Error.InvalidCanon;
                pos += 1;
                const func = try leb128.readUleb128(u32, body, &pos);
                break :blk .{ .lower = .{ .func = func, .opts = try decodeCanonOpts(body, &pos) } };
            },
            0x02 => .{ .resource_new = try leb128.readUleb128(u32, body, &pos) },
            0x03 => .{ .resource_drop = try leb128.readUleb128(u32, body, &pos) },
            0x04 => .{ .resource_rep = try leb128.readUleb128(u32, body, &pos) },
            0x09 => blk: { // canon task.return: 0x09 resultlist opts
                const result = try decodeResultList(body, &pos);
                break :blk .{ .task_return = .{ .result = result, .opts = try decodeCanonOpts(body, &pos) } };
            },
            0x0e => try decodeStreamFutureCanon(.stream_new, body, &pos),
            0x0f => try decodeStreamFutureCanon(.stream_read, body, &pos),
            0x10 => try decodeStreamFutureCanon(.stream_write, body, &pos),
            0x11 => try decodeStreamFutureCanon(.stream_cancel_read, body, &pos),
            0x12 => try decodeStreamFutureCanon(.stream_cancel_write, body, &pos),
            0x13 => try decodeStreamFutureCanon(.stream_drop_readable, body, &pos),
            0x14 => try decodeStreamFutureCanon(.stream_drop_writable, body, &pos),
            0x15 => try decodeStreamFutureCanon(.future_new, body, &pos),
            0x16 => try decodeStreamFutureCanon(.future_read, body, &pos),
            0x17 => try decodeStreamFutureCanon(.future_write, body, &pos),
            0x18 => try decodeStreamFutureCanon(.future_cancel_read, body, &pos),
            0x19 => try decodeStreamFutureCanon(.future_cancel_write, body, &pos),
            0x1a => try decodeStreamFutureCanon(.future_drop_readable, body, &pos),
            0x1b => try decodeStreamFutureCanon(.future_drop_writable, body, &pos),
            0x1f => .{ .waitable_set = .{ .op = .new } },
            0x20 => try decodeWaitableSetWait(.wait, body, &pos),
            0x21 => try decodeWaitableSetWait(.poll, body, &pos),
            0x22 => .{ .waitable_set = .{ .op = .drop } },
            0x23 => .{ .waitable_set = .{ .op = .join } },
            0x05 => .task_cancel,
            0x06 => .{ .subtask_cancel = .{ .is_async = try decodeFlagByte(body, &pos) } },
            0x0a => .{ .context_get = try decodeContextSlot(body, &pos) },
            0x0b => .{ .context_set = try decodeContextSlot(body, &pos) },
            0x0c => .{ .thread_yield = .{ .cancellable = try decodeFlagByte(body, &pos) } },
            0x0d => .subtask_drop,
            // error-context (0x1c–0x1e), backpressure (0x24/0x25) and the 🧵
            // thread builtins (0x26+) defer.
            else => return Error.UnsupportedCanon,
        };
        try out.append(arena, canon);
    }
    if (pos != body.len) return Error.TrailingBytes;
}

fn decodeCoreSortIdx(body: []const u8, pos: *usize) Error!struct { sort: CoreSort, index: u32 } {
    if (pos.* >= body.len) return Error.Truncated;
    const cs: CoreSort = @enumFromInt(body[pos.*]);
    pos.* += 1;
    return .{ .sort = cs, .index = try leb128.readUleb128(u32, body, pos) };
}

/// `core:instance` section (id 2) = `vec(core:instance)`.
fn decodeCoreInstanceSection(arena: Allocator, out: *std.ArrayList(CoreInstance), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos >= body.len) return Error.Truncated;
        const tag = body[pos];
        pos += 1;
        switch (tag) {
            0x00 => { // instantiate moduleidx vec(instantiatearg)
                const module = try leb128.readUleb128(u32, body, &pos);
                const argc = try leb128.readUleb128(u32, body, &pos);
                var args: std.ArrayList(CoreInstantiateArg) = .empty;
                var j: u32 = 0;
                while (j < argc) : (j += 1) {
                    const name = try decodeLabel(body, &pos);
                    if (pos >= body.len or body[pos] != 0x12) return Error.InvalidInstance;
                    pos += 1; // 0x12 = instance sort tag
                    try args.append(arena, .{ .name = name, .instance = try leb128.readUleb128(u32, body, &pos) });
                }
                try out.append(arena, .{ .instantiate = .{ .module = module, .args = try args.toOwnedSlice(arena) } });
            },
            0x01 => { // vec(core:inlineexport)
                const ec = try leb128.readUleb128(u32, body, &pos);
                var exps: std.ArrayList(CoreInlineExport) = .empty;
                var j: u32 = 0;
                while (j < ec) : (j += 1) {
                    const name = try decodeLabel(body, &pos);
                    const si = try decodeCoreSortIdx(body, &pos);
                    try exps.append(arena, .{ .name = name, .sort = si.sort, .index = si.index });
                }
                try out.append(arena, .{ .inline_exports = try exps.toOwnedSlice(arena) });
            },
            else => return Error.InvalidInstance,
        }
    }
    if (pos != body.len) return Error.TrailingBytes;
}

/// `instance` section (id 5) = `vec(instance)` (component level).
fn decodeInstanceSection(arena: Allocator, out: *std.ArrayList(ComponentInstanceDef), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos >= body.len) return Error.Truncated;
        const tag = body[pos];
        pos += 1;
        switch (tag) {
            0x00 => { // instantiate componentidx vec(instantiatearg)
                const component = try leb128.readUleb128(u32, body, &pos);
                const argc = try leb128.readUleb128(u32, body, &pos);
                var args: std.ArrayList(ComponentInstantiateArg) = .empty;
                var j: u32 = 0;
                while (j < argc) : (j += 1) {
                    const name = try decodeLabel(body, &pos);
                    const si = try decodeSortIdx(body, &pos);
                    try args.append(arena, .{ .name = name, .sort = si.sort, .index = si.index });
                }
                try out.append(arena, .{ .instantiate = .{ .component = component, .args = try args.toOwnedSlice(arena) } });
            },
            0x01 => { // vec(inlineexport)
                const ec = try leb128.readUleb128(u32, body, &pos);
                var exps: std.ArrayList(ComponentInlineExport) = .empty;
                var j: u32 = 0;
                while (j < ec) : (j += 1) {
                    const name = try decodeImportExportName(body, &pos);
                    const si = try decodeSortIdx(body, &pos);
                    try exps.append(arena, .{ .name = name, .sort = si.sort, .index = si.index });
                }
                try out.append(arena, .{ .inline_exports = try exps.toOwnedSlice(arena) });
            },
            else => return Error.InvalidInstance,
        }
    }
    if (pos != body.len) return Error.TrailingBytes;
}

/// `alias` section (id 6) = `vec(alias)`; `alias ::= sort aliastarget`.
fn decodeAliasSection(arena: Allocator, out: *std.ArrayList(Alias), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) try out.append(arena, try decodeAlias(body, &pos));
    if (pos != body.len) return Error.TrailingBytes;
}

/// Decode the type index space + imports/exports + canon defs of an
/// already-walked component (`decode.decode`). The returned `TypeInfo` owns its
/// allocations (`deinit`) but borrows `name` slices from the component input.
pub fn decodeTypeInfo(parent: Allocator, component: *const decode.Component) Error!TypeInfo {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const a = arena.allocator();

    var deftypes: std.ArrayList(DefType) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var exports: std.ArrayList(Export) = .empty;
    var canons: std.ArrayList(Canon) = .empty;
    var core_instances: std.ArrayList(CoreInstance) = .empty;
    var component_instances: std.ArrayList(ComponentInstanceDef) = .empty;
    var aliases: std.ArrayList(Alias) = .empty;
    var core_funcs: std.ArrayList(CoreFuncDef) = .empty;
    var core_tables: std.ArrayList(AliasTarget) = .empty;
    var component_funcs: std.ArrayList(ComponentFuncDef) = .empty;
    var instance_origins: std.ArrayList(InstanceOrigin) = .empty;
    var type_space: std.ArrayList(TypeSpaceEntry) = .empty;
    var core_module_count: u32 = 0;
    var component_count: u32 = 0;
    var core_type_count: u32 = 0;
    var core_memory_count: u32 = 0;
    var core_global_count: u32 = 0;
    var alias_space_before: std.ArrayList(AliasSpaceBefore) = .empty;
    var core_types: std.ArrayList(CoreTypeDef) = .empty;
    var nested_scans: std.ArrayList(NestedComponentScan) = .empty;

    for (component.sections.items) |sec| {
        switch (sec.id) {
            .core_module => core_module_count += 1,
            .component => component_count += 1,
            else => {},
        }
        // Track per-kind counts before this section so the newly-decoded entries
        // append to the core-/component-func and instance index spaces in binary
        // (section) order — entries from different sections must interleave by
        // their true definition order (a lower's func operand and an instance
        // alias both index spaces populated across several sections).
        const imports_before = imports.items.len;
        const canons_before = canons.items.len;
        const aliases_before = aliases.items.len;
        const cinst_before = component_instances.items.len;
        const deftypes_before = deftypes.items.len;
        const exports_before = exports.items.len;
        switch (sec.id) {
            .type => try decodeTypeSection(a, &deftypes, sec.body),
            .import => try decodeImportSection(a, &imports, sec.body),
            .@"export" => try decodeExportSection(a, &exports, sec.body),
            .canon => try decodeCanonSection(a, &canons, sec.body),
            .core_instance => try decodeCoreInstanceSection(a, &core_instances, sec.body),
            .instance => try decodeInstanceSection(a, &component_instances, sec.body),
            .alias => try decodeAliasSection(a, &aliases, sec.body),
            .component => try nested_scans.append(a, try scanNestedComponent(a, sec.body)),
            .core_type => {
                // Section body = vec(core:deftype); each def mints one
                // core-type index.
                var cpos: usize = 0;
                const cn = try leb128.readUleb128(u32, sec.body, &cpos);
                var ci: u32 = 0;
                while (ci < cn) : (ci += 1) {
                    const def = try core_scan.decodeCoreDefType(a, sec.body, &cpos);
                    if (def == .other) {
                        // Unmodeled (GC) form: its body is unconsumed, so
                        // the rest of this vec cannot be parsed. Count the
                        // remaining defs (index-space size stays correct —
                        // no false rejects downstream) and stop decoding.
                        core_type_count += cn - ci;
                        break;
                    }
                    try core_types.append(a, .{
                        .def = def,
                        .space_before = core_type_count,
                    });
                    core_type_count += 1;
                }
            },
            else => {}, // other sections decoded in later chunks
        }
        switch (sec.id) {
            .type => for (deftypes.items[deftypes_before..], deftypes_before..) |_, abs| {
                try type_space.append(a, .{ .def = @intCast(abs) });
            },
            .import => for (imports.items[imports_before..], imports_before..) |imp, abs| switch (imp.desc) {
                .func => try component_funcs.append(a, .{ .import = @intCast(abs) }),
                .instance => try instance_origins.append(a, .{ .import = imp.name }),
                .type_bound => try type_space.append(a, .{ .named = .{ .import = @intCast(abs) } }),
                else => {},
            },
            .canon => for (canons.items[canons_before..], canons_before..) |c, abs| switch (c) {
                .lower => |l| try core_funcs.append(a, .{ .lower = .{ .func = l.func, .opts = l.opts } }),
                .task_cancel => try core_funcs.append(a, .task_cancel),
                .subtask_cancel => |sc| try core_funcs.append(a, .{ .subtask_cancel = .{ .is_async = sc.is_async } }),
                .subtask_drop => try core_funcs.append(a, .subtask_drop),
                .context_get => |cg| try core_funcs.append(a, .{ .context_get = cg }),
                .context_set => |cs| try core_funcs.append(a, .{ .context_set = cs }),
                .thread_yield => |ty| try core_funcs.append(a, .{ .thread_yield = .{ .cancellable = ty.cancellable } }),
                .resource_new => |t| try core_funcs.append(a, .{ .resource_new = t }),
                .resource_drop => |t| try core_funcs.append(a, .{ .resource_drop = t }),
                .resource_rep => |t| try core_funcs.append(a, .{ .resource_rep = t }),
                .stream_future => |sf| try core_funcs.append(a, .{ .stream_future = .{ .op = sf.op, .type_index = sf.type_index } }),
                .task_return => |tr| try core_funcs.append(a, .{ .task_return = .{ .result = tr.result, .opts = tr.opts } }),
                .waitable_set => |ws| try core_funcs.append(a, .{ .waitable_set = .{ .op = ws.op, .cancellable = ws.cancellable, .memory = ws.memory } }),
                .lift => try component_funcs.append(a, .{ .lift = @intCast(abs) }),
            },
            .alias => for (aliases.items[aliases_before..], aliases_before..) |al, al_abs| {
                try alias_space_before.append(a, .{
                    .type_space = @intCast(type_space.items.len),
                    .core_types = core_type_count,
                });
                switch (al.sort) {
                    .core => |cs| switch (cs) {
                        .func => try core_funcs.append(a, .{ .alias = al.target }),
                        .table => try core_tables.append(a, al.target),
                        .memory => core_memory_count += 1,
                        .global => core_global_count += 1,
                        .type => core_type_count += 1,
                        else => {},
                    },
                    .func => try component_funcs.append(a, .{ .alias = al.target }),
                    .instance => try instance_origins.append(a, .{ .alias = @intCast(al_abs) }),
                    .type => try type_space.append(a, .{ .named = .{ .alias = @intCast(al_abs) } }),
                    else => {},
                }
            },
            .instance => for (component_instances.items[cinst_before..], cinst_before..) |_, abs| {
                try instance_origins.append(a, .{ .local = @intCast(abs) });
            },
            .@"export" => for (exports.items[exports_before..], exports_before..) |*ex, ex_abs| {
                // An export ADDS to its sort's index space (D-527). Appending in
                // definition order keeps every later sortidx in bounds; omitting
                // the func case shifted all of them after the first export.
                //
                // Record the space size BEFORE the append: that is the bound the
                // export's own sortidx must satisfy. Reading the final size
                // instead lets an export satisfy itself.
                switch (ex.sort) {
                    .type => {
                        ex.sort_space_len_at_def = @intCast(type_space.items.len);
                        try type_space.append(a, .{ .named = .{ .@"export" = @intCast(ex_abs) } });
                    },
                    .func => {
                        ex.sort_space_len_at_def = @intCast(component_funcs.items.len);
                        try component_funcs.append(a, .{ .re_export = @intCast(ex_abs) });
                    },
                    .instance => {
                        ex.sort_space_len_at_def = @intCast(instance_origins.items.len);
                        try instance_origins.append(a, .{ .re_export = @intCast(ex_abs) });
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    return .{
        .arena = arena,
        .deftypes = deftypes,
        // The type-index space = type-section defs + type-sort aliases + type
        // imports + type exports (the four minting forms), in definition order.
        .type_space_len = @intCast(type_space.items.len),
        .type_space = type_space,
        .core_module_count = core_module_count,
        .component_count = component_count,
        .core_type_count = core_type_count,
        .core_memory_count = core_memory_count,
        .core_global_count = core_global_count,
        .alias_space_before = alias_space_before,
        .core_types = core_types,
        .nested_scans = nested_scans,
        .imports = imports,
        .exports = exports,
        .canons = canons,
        .core_instances = core_instances,
        .component_instances = component_instances,
        .aliases = aliases,
        .core_funcs = core_funcs,
        .core_tables = core_tables,
        .component_funcs = component_funcs,
        .instance_origins = instance_origins,
    };
}
