//! Per-op stack effect table — extracted from `liveness.zig` per
//! ADR-0088.
//!
//! Pure mapping `ZirOp → ?StackEffect` (pops + pushes counts).
//! No methods, no state. Re-exported by `liveness.zig` so callers
//! continue to reach `liveness.StackEffect` / `liveness.stackEffect`
//! identically.
//!
//! Zone 1 (`src/ir/analysis/`).

const zir = @import("../zir.zig");
const ZirOp = zir.ZirOp;

pub const StackEffect = struct { pops: u8, pushes: u8 };

/// Stack effect of an MVP op for liveness purposes. Returns
/// `null` for ops the analysis does not yet model (control flow,
/// memory ops, pseudo opcodes); callers translate that into the
/// appropriate error.
///
/// Exposed (pub since §9.9 / 9.9-d-6 / D-061) so
/// `regalloc.populateShapeTags` can mirror this same vreg
/// numbering — keeping the two in sync without duplicating
/// the catalogue.
pub fn stackEffect(op: ZirOp) ?StackEffect {
    return switch (op) {
        // 0 → 0
        .nop => .{ .pops = 0, .pushes = 0 },
        // 0 → 1
        .@"i32.const",
        .@"i64.const",
        .@"f32.const",
        .@"f64.const",
        .@"local.get",
        .@"global.get",
        // Wasm 3.0 GC (10.G): struct.new_default pops nothing (the
        // alloc trampoline zero-inits) and pushes the GcRef (anyref =
        // u32, `.scalar`/GPR per ADR-0116 D4). struct.new (variadic
        // pops) is special-cased in liveness.compute, not here.
        .@"struct.new_default",
        => .{ .pops = 0, .pushes = 1 },
        // 1 → 0
        .drop,
        .@"local.set",
        .@"global.set",
        => .{ .pops = 1, .pushes = 0 },
        // local.tee — operand-stack-transparent per emit's
        // semantics (STR top → local slot, no pop/push). The
        // pop=1/push=1 form would close the input vreg's range
        // and fabricate a fresh vreg, opening a regalloc reuse
        // window the subsequent push could clobber. See the
        // dedicated dispatch arm in `compute()` for the
        // last-use extension. populateShapeTags also matches
        // (no shape_tag increment at local.tee).
        .@"local.tee" => .{ .pops = 0, .pushes = 0 },
        // any.convert_extern / extern.convert_any (10.G) are pure identity:
        // externref and anyref share the Value.ref slot, the distinction is
        // validator-only. The operand flows through unchanged → transparent
        // 0→0 (like local.tee, no fresh vreg). Emit is a no-op. Modelling these
        // 1→1 would close the input vreg's range + fabricate a fresh (never-
        // written) result vreg → ref.test/ref.cast on the result read garbage
        // (the reverted +39-fail attempt). See lesson
        // jit-liveness-must-mirror-emit-pushed-vregs.
        .@"any.convert_extern", .@"extern.convert_any" => .{ .pops = 0, .pushes = 0 },
        // ref.as_non_null (10.R, D-220) is operand-stack-TRANSPARENT, not
        // 1→1: both emitters pop the src vreg, null-check it in place, and
        // push the SAME vreg back — no result vreg, no MOV. (ref.cast /
        // ref.test ARE 1→1 because their value comes out of a trampoline
        // CALL and needs a vreg to land in; this one produces nothing.)
        // Modelling it 1→1 closed the operand's range and fabricated a
        // never-written result vreg, so the allocator handed the operand's
        // register to the next value while the narrowed ref was still live
        // → silent wrong answers, no trap (#245). Unlike any.convert_extern
        // its emit READS that register, so it also takes the last-use
        // extension arm in `compute()`, next to br_on_null (same pop-then-
        // re-append shape). See lesson
        // jit-liveness-must-mirror-emit-pushed-vregs.
        .@"ref.as_non_null" => .{ .pops = 0, .pushes = 0 },
        // atomic.fence (threads, ADR-0168): 0 → 0, no operands.
        .@"atomic.fence" => .{ .pops = 0, .pushes = 0 },
        // 1 → 1 testop / unop (i32 / i64 / f32 / f64)
        .@"i32.eqz",
        .@"i32.clz",
        .@"i32.ctz",
        .@"i32.popcnt",
        .@"i64.eqz",
        .@"i64.clz",
        .@"i64.ctz",
        .@"i64.popcnt",
        .@"f32.abs",
        .@"f32.neg",
        .@"f32.ceil",
        .@"f32.floor",
        .@"f32.trunc",
        .@"f32.nearest",
        .@"f32.sqrt",
        .@"f64.abs",
        .@"f64.neg",
        .@"f64.ceil",
        .@"f64.floor",
        .@"f64.trunc",
        .@"f64.nearest",
        .@"f64.sqrt",
        // conversions 1 → 1
        .@"i32.wrap_i64",
        .@"i32.trunc_f32_s",
        .@"i32.trunc_f32_u",
        .@"i32.trunc_f64_s",
        .@"i32.trunc_f64_u",
        .@"i64.extend_i32_s",
        .@"i64.extend_i32_u",
        .@"i64.trunc_f32_s",
        .@"i64.trunc_f32_u",
        .@"i64.trunc_f64_s",
        .@"i64.trunc_f64_u",
        .@"f32.convert_i32_s",
        .@"f32.convert_i32_u",
        .@"f32.convert_i64_s",
        .@"f32.convert_i64_u",
        .@"f32.demote_f64",
        .@"f64.convert_i32_s",
        .@"f64.convert_i32_u",
        .@"f64.convert_i64_s",
        .@"f64.convert_i64_u",
        .@"f64.promote_f32",
        .@"i32.reinterpret_f32",
        .@"i64.reinterpret_f64",
        .@"f32.reinterpret_i32",
        .@"f64.reinterpret_i64",
        // Wasm 2.0 sat_trunc (sub-h5).
        .@"i32.trunc_sat_f32_s",
        .@"i32.trunc_sat_f32_u",
        .@"i32.trunc_sat_f64_s",
        .@"i32.trunc_sat_f64_u",
        .@"i64.trunc_sat_f32_s",
        .@"i64.trunc_sat_f32_u",
        .@"i64.trunc_sat_f64_s",
        .@"i64.trunc_sat_f64_u",
        // Wasm 2.0 sign-extension ops (§9.7 / 7.9 chunk c).
        // Wasm spec §4.4.1.4 (extendN_s) — pop one int, push the
        // sign-extended same-width int. Same 1→1 stack shape as
        // any unary integer op.
        .@"i32.extend8_s",
        .@"i32.extend16_s",
        .@"i64.extend8_s",
        .@"i64.extend16_s",
        .@"i64.extend32_s",
        // Wasm 3.0 GC i31 (10.G). 1 → 1 scalar (anyref is a u32 on
        // the operand stack per ADR-0116 D4, regalloc-classed like
        // i32 — `.scalar` shape tag). `ref.i31` pops i32 pushes
        // i31ref; `i31.get_{s,u}` pops i31ref pushes i32.
        .@"ref.i31",
        .@"i31.get_s",
        .@"i31.get_u",
        // Wasm 3.0 GC (10.G): struct.get pops the struct GcRef, pushes
        // the loaded field Value (1 → 1 scalar; ADR-0116 §3a). get_s/get_u
        // are the packed (i8/i16) sign/zero-extending variants — same shape.
        .@"struct.get",
        .@"struct.get_s",
        .@"struct.get_u",
        // array.new_default pops the i32 length, pushes the GcRef (the
        // alloc trampoline zero-inits). array.len pops the array GcRef,
        // pushes the i32 length. Both 1 → 1.
        .@"array.new_default",
        .@"array.len",
        // ref.test / ref.test_null (R-1) pop one reftype, push i32 (0/1). 1 → 1.
        .@"ref.test",
        .@"ref.test_null",
        // ref.cast (R-2) pops one reftype, pushes it back (cast or trap). 1 → 1.
        .@"ref.cast",
        // ref.cast_null (R-3) — like ref.cast but null passes. 1 → 1.
        .@"ref.cast_null",
        => .{ .pops = 1, .pushes = 1 },
        // 2 → 1 binop
        .@"i32.add",
        .@"i32.sub",
        .@"i32.mul",
        .@"i32.div_s",
        .@"i32.div_u",
        .@"i32.rem_s",
        .@"i32.rem_u",
        .@"i32.and",
        .@"i32.or",
        .@"i32.xor",
        .@"i32.shl",
        .@"i32.shr_s",
        .@"i32.shr_u",
        .@"i32.rotl",
        .@"i32.rotr",
        .@"i64.add",
        .@"i64.sub",
        .@"i64.mul",
        .@"i64.div_s",
        .@"i64.div_u",
        .@"i64.rem_s",
        .@"i64.rem_u",
        .@"i64.and",
        .@"i64.or",
        .@"i64.xor",
        .@"i64.shl",
        .@"i64.shr_s",
        .@"i64.shr_u",
        .@"i64.rotl",
        .@"i64.rotr",
        .@"f32.add",
        .@"f32.sub",
        .@"f32.mul",
        .@"f32.div",
        .@"f32.min",
        .@"f32.max",
        .@"f32.copysign",
        .@"f64.add",
        .@"f64.sub",
        .@"f64.mul",
        .@"f64.div",
        .@"f64.min",
        .@"f64.max",
        .@"f64.copysign",
        // 2 → 1 relop
        .@"i32.eq",
        .@"i32.ne",
        .@"i32.lt_s",
        .@"i32.lt_u",
        .@"i32.gt_s",
        .@"i32.gt_u",
        .@"i32.le_s",
        .@"i32.le_u",
        .@"i32.ge_s",
        .@"i32.ge_u",
        .@"i64.eq",
        .@"i64.ne",
        .@"i64.lt_s",
        .@"i64.lt_u",
        .@"i64.gt_s",
        .@"i64.gt_u",
        .@"i64.le_s",
        .@"i64.le_u",
        .@"i64.ge_s",
        .@"i64.ge_u",
        .@"f32.eq",
        .@"f32.ne",
        .@"f32.lt",
        .@"f32.gt",
        .@"f32.le",
        .@"f32.ge",
        .@"f64.eq",
        .@"f64.ne",
        .@"f64.lt",
        .@"f64.gt",
        .@"f64.le",
        .@"f64.ge",
        // Wasm 3.0 GC (10.G): array.get pops the array GcRef + i32 index,
        // pushes the loaded element (2 → 1; bounds-checked, ADR-0116 §3a).
        .@"array.get",
        // array.get_s (A-6a) / array.get_u (A-6b) — same shape as array.get
        // (pop ref + idx, push the sign/zero-extended i32). 2 → 1.
        .@"array.get_s",
        .@"array.get_u",
        // array.new pops the init value + i32 length, pushes the GcRef
        // (the trampoline allocs + fills). 2 → 1.
        .@"array.new",
        // array.new_data (A-10) pops offset + size, pushes the GcRef (the
        // trampoline allocs + copies from the data segment). 2 → 1.
        .@"array.new_data",
        // array.new_elem (A-10b) pops offset + size, pushes the GcRef (the
        // trampoline allocs + copies refs from the element segment). 2 → 1.
        .@"array.new_elem",
        // atomic rmw binops (threads, ADR-0168) — 2→1 (pop addr+val, push old).
        .@"i32.atomic.rmw.add",
        .@"i64.atomic.rmw.add",
        .@"i32.atomic.rmw8.add_u",
        .@"i32.atomic.rmw16.add_u",
        .@"i64.atomic.rmw8.add_u",
        .@"i64.atomic.rmw16.add_u",
        .@"i64.atomic.rmw32.add_u",
        .@"i32.atomic.rmw.sub",
        .@"i64.atomic.rmw.sub",
        .@"i32.atomic.rmw8.sub_u",
        .@"i32.atomic.rmw16.sub_u",
        .@"i64.atomic.rmw8.sub_u",
        .@"i64.atomic.rmw16.sub_u",
        .@"i64.atomic.rmw32.sub_u",
        .@"i32.atomic.rmw.and",
        .@"i64.atomic.rmw.and",
        .@"i32.atomic.rmw8.and_u",
        .@"i32.atomic.rmw16.and_u",
        .@"i64.atomic.rmw8.and_u",
        .@"i64.atomic.rmw16.and_u",
        .@"i64.atomic.rmw32.and_u",
        .@"i32.atomic.rmw.or",
        .@"i64.atomic.rmw.or",
        .@"i32.atomic.rmw8.or_u",
        .@"i32.atomic.rmw16.or_u",
        .@"i64.atomic.rmw8.or_u",
        .@"i64.atomic.rmw16.or_u",
        .@"i64.atomic.rmw32.or_u",
        .@"i32.atomic.rmw.xor",
        .@"i64.atomic.rmw.xor",
        .@"i32.atomic.rmw8.xor_u",
        .@"i32.atomic.rmw16.xor_u",
        .@"i64.atomic.rmw8.xor_u",
        .@"i64.atomic.rmw16.xor_u",
        .@"i64.atomic.rmw32.xor_u",
        .@"i32.atomic.rmw.xchg",
        .@"i64.atomic.rmw.xchg",
        .@"i32.atomic.rmw8.xchg_u",
        .@"i32.atomic.rmw16.xchg_u",
        .@"i64.atomic.rmw8.xchg_u",
        .@"i64.atomic.rmw16.xchg_u",
        .@"i64.atomic.rmw32.xchg_u",
        => .{ .pops = 2, .pushes = 1 },
        // 3 → 1 select
        .select, .select_typed => .{ .pops = 3, .pushes = 1 },
        // atomic cmpxchg (threads, ADR-0168) — 3→1 (pop addr+expected+replacement, push old).
        .@"i32.atomic.rmw.cmpxchg",
        .@"i64.atomic.rmw.cmpxchg",
        .@"i32.atomic.rmw8.cmpxchg_u",
        .@"i32.atomic.rmw16.cmpxchg_u",
        .@"i64.atomic.rmw8.cmpxchg_u",
        .@"i64.atomic.rmw16.cmpxchg_u",
        .@"i64.atomic.rmw32.cmpxchg_u",
        => .{ .pops = 3, .pushes = 1 },
        // memory.atomic.notify (threads, ADR-0168) — 2→1 (pop count+addr, push woken).
        .@"memory.atomic.notify" => .{ .pops = 2, .pushes = 1 },
        // memory.atomic.wait{32,64} (threads, ADR-0168) — 3→1 (pop timeout+expected+addr, push status).
        .@"memory.atomic.wait32",
        .@"memory.atomic.wait64",
        => .{ .pops = 3, .pushes = 1 },
        // wide-arithmetic (ADR-0168 v0.2) — the first MULTI-RESULT ops.
        // add128/sub128: 4→2 (two 128-bit lo,hi operands → lo,hi result);
        // mul_wide_s/u: 2→2 (a,b → full 128-bit lo,hi product).
        .@"i64.add128",
        .@"i64.sub128",
        => .{ .pops = 4, .pushes = 2 },
        .@"i64.mul_wide_s",
        .@"i64.mul_wide_u",
        => .{ .pops = 2, .pushes = 2 },
        // memory loads (1 → 1; pop addr, push value)
        .@"i32.load",
        .@"i32.atomic.load", // threads (ADR-0168) — same shape as i32.load
        .@"i64.atomic.load",
        .@"i32.atomic.load8_u",
        .@"i32.atomic.load16_u",
        .@"i64.atomic.load8_u",
        .@"i64.atomic.load16_u",
        .@"i64.atomic.load32_u",
        .@"i32.load8_s",
        .@"i32.load8_u",
        .@"i32.load16_s",
        .@"i32.load16_u",
        .@"i64.load",
        .@"i64.load8_s",
        .@"i64.load8_u",
        .@"i64.load16_s",
        .@"i64.load16_u",
        .@"i64.load32_s",
        .@"i64.load32_u",
        .@"f32.load",
        .@"f64.load",
        => .{ .pops = 1, .pushes = 1 },
        // memory stores (2 → 0; pop addr + value)
        .@"i32.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        .@"f32.store",
        .@"f64.store",
        .@"i32.atomic.store", // threads (ADR-0168) — same 2→0 shape as the plain stores
        .@"i64.atomic.store",
        .@"i32.atomic.store8",
        .@"i32.atomic.store16",
        .@"i64.atomic.store8",
        .@"i64.atomic.store16",
        .@"i64.atomic.store32",
        => .{ .pops = 2, .pushes = 0 },
        // memory.size (0 → 1) / memory.grow (1 → 1)
        .@"memory.size" => .{ .pops = 0, .pushes = 1 },
        .@"memory.grow" => .{ .pops = 1, .pushes = 1 },
        // Wasm spec §4.4.7 (bulk memory) — pop dst, src/val, n.
        // No result is pushed.
        .@"memory.copy", .@"memory.fill" => .{ .pops = 3, .pushes = 0 },
        // §9.9 / 9.9-m-3b: memory.init pops dst, src, n (3) and
        // pushes nothing; dataidx is in `payload`. data.drop /
        // elem.drop are 0 → 0 (no operand stack effect; dropped
        // flag is JIT-handled via `payload`).
        .@"memory.init" => .{ .pops = 3, .pushes = 0 },
        .@"data.drop", .@"elem.drop" => .{ .pops = 0, .pushes = 0 },
        // §9.9 / 9.9-m-2a (per ADR-0058): table.* family stack
        // effects. Wasm spec §4.4.10–§4.4.16 (table instructions).
        //   table.get x: 1 → 1 (pop i32 idx; push reftype value)
        //   table.set x: 2 → 0 (pop reftype val; pop i32 idx)
        //   table.size x: 0 → 1 (push i32 current length)
        //   table.grow x: 2 → 1 (pop init reftype + n i32; push i32 prev_size or -1)
        //   table.fill x: 3 → 0 (pop dst i32, val reftype, n i32)
        //   table.copy x y / table.init x y: 3 → 0 (pop dst, src, n)
        .@"table.get" => .{ .pops = 1, .pushes = 1 },
        .@"table.set" => .{ .pops = 2, .pushes = 0 },
        // Wasm 3.0 GC (10.G): struct.set pops the value + struct GcRef,
        // stores into the field slot, pushes nothing (fixed 2→0).
        .@"struct.set" => .{ .pops = 2, .pushes = 0 },
        .@"table.size" => .{ .pops = 0, .pushes = 1 },
        .@"table.grow" => .{ .pops = 2, .pushes = 1 },
        .@"table.fill", .@"table.copy", .@"table.init" => .{ .pops = 3, .pushes = 0 },
        // Wasm 3.0 GC (10.G): array.set pops the array GcRef + i32 index +
        // value, stores into the element slot (3 → 0; bounds-checked).
        .@"array.set" => .{ .pops = 3, .pushes = 0 },
        // array.fill (A-7) pops ref + idx + value + count, no result. 4 → 0.
        .@"array.fill" => .{ .pops = 4, .pushes = 0 },
        // array.copy (A-9) pops dst_ref + dst_off + src_ref + src_off + len. 5 → 0.
        .@"array.copy" => .{ .pops = 5, .pushes = 0 },
        // array.init_data/init_elem (A-11) pop ref + dst_off + src_off + len,
        // copy a segment slice in-place, push nothing. 4 → 0.
        .@"array.init_data", .@"array.init_elem" => .{ .pops = 4, .pushes = 0 },
        // ref.eq (A-8) pops two eqrefs, pushes i32 (identity compare). 2 → 1.
        .@"ref.eq" => .{ .pops = 2, .pushes = 1 },
        // §9.9 / 9.9-m-1a/b (per ADR-0056): reference-typed ops.
        //   ref.null t: 0 → 1 (pushes a null reftype)
        //   ref.is_null: 1 → 1 (pop reftype, push i32 test result)
        //   ref.func x: 0 → 1 (pushes funcref for func x)
        .@"ref.null", .@"ref.func" => .{ .pops = 0, .pushes = 1 },
        .@"ref.is_null" => .{ .pops = 1, .pushes = 1 },
        // ============================================================
        // Wasm 2.0 SIMD (v128) — §9.9 / 9.9-d.
        // Wasm spec §4.4.6 (vector instructions).
        // ============================================================
        // 0 → 1: const.
        .@"v128.const" => .{ .pops = 0, .pushes = 1 },
        // 1 → 1: memory loads (pop addr, push v128).
        .@"v128.load",
        .@"v128.load8x8_s",
        .@"v128.load8x8_u",
        .@"v128.load16x4_s",
        .@"v128.load16x4_u",
        .@"v128.load32x2_s",
        .@"v128.load32x2_u",
        .@"v128.load8_splat",
        .@"v128.load16_splat",
        .@"v128.load32_splat",
        .@"v128.load64_splat",
        .@"v128.load32_zero",
        .@"v128.load64_zero",
        => .{ .pops = 1, .pushes = 1 },
        // 2 → 0: stores (pop addr + value).
        .@"v128.store" => .{ .pops = 2, .pushes = 0 },
        // 2 → 1: load_lane (pop addr + v128 src, merge byte from
        // mem into one lane).
        .@"v128.load8_lane",
        .@"v128.load16_lane",
        .@"v128.load32_lane",
        .@"v128.load64_lane",
        => .{ .pops = 2, .pushes = 1 },
        // 2 → 0: store_lane (pop addr + v128 src).
        .@"v128.store8_lane",
        .@"v128.store16_lane",
        .@"v128.store32_lane",
        .@"v128.store64_lane",
        => .{ .pops = 2, .pushes = 0 },
        // 1 → 1: splat from scalar (pop scalar, push v128).
        .@"i8x16.splat",
        .@"i16x8.splat",
        .@"i32x4.splat",
        .@"i64x2.splat",
        .@"f32x4.splat",
        .@"f64x2.splat",
        // 1 → 1: extract_lane (pop v128, push scalar; imm in
        // payload).
        .@"i8x16.extract_lane_s",
        .@"i8x16.extract_lane_u",
        .@"i16x8.extract_lane_s",
        .@"i16x8.extract_lane_u",
        .@"i32x4.extract_lane",
        .@"i64x2.extract_lane",
        .@"f32x4.extract_lane",
        .@"f64x2.extract_lane",
        // 1 → 1: bitwise unop / popcnt / abs / neg.
        .@"v128.not",
        .@"i8x16.abs",
        .@"i16x8.abs",
        .@"i32x4.abs",
        .@"i64x2.abs",
        .@"i8x16.neg",
        .@"i16x8.neg",
        .@"i32x4.neg",
        .@"i64x2.neg",
        .@"i8x16.popcnt",
        // 1 → 1: FP unop.
        .@"f32x4.abs",
        .@"f32x4.neg",
        .@"f32x4.sqrt",
        .@"f32x4.ceil",
        .@"f32x4.floor",
        .@"f32x4.trunc",
        .@"f32x4.nearest",
        .@"f64x2.abs",
        .@"f64x2.neg",
        .@"f64x2.sqrt",
        .@"f64x2.ceil",
        .@"f64x2.floor",
        .@"f64x2.trunc",
        .@"f64x2.nearest",
        // 1 → 1: relaxed-SIMD trunc (17.4).
        .@"i32x4.relaxed_trunc_f32x4_s",
        .@"i32x4.relaxed_trunc_f32x4_u",
        .@"i32x4.relaxed_trunc_f64x2_s_zero",
        .@"i32x4.relaxed_trunc_f64x2_u_zero",
        // 1 → 1: extend low/high.
        .@"i16x8.extend_low_i8x16_s",
        .@"i16x8.extend_high_i8x16_s",
        .@"i16x8.extend_low_i8x16_u",
        .@"i16x8.extend_high_i8x16_u",
        .@"i32x4.extend_low_i16x8_s",
        .@"i32x4.extend_high_i16x8_s",
        .@"i32x4.extend_low_i16x8_u",
        .@"i32x4.extend_high_i16x8_u",
        .@"i64x2.extend_low_i32x4_s",
        .@"i64x2.extend_high_i32x4_s",
        .@"i64x2.extend_low_i32x4_u",
        .@"i64x2.extend_high_i32x4_u",
        // 1 → 1: extadd_pairwise.
        .@"i16x8.extadd_pairwise_i8x16_s",
        .@"i16x8.extadd_pairwise_i8x16_u",
        .@"i32x4.extadd_pairwise_i16x8_s",
        .@"i32x4.extadd_pairwise_i16x8_u",
        // 1 → 1: FP convert / promote / demote / trunc_sat.
        .@"f32x4.convert_i32x4_s",
        .@"f32x4.convert_i32x4_u",
        .@"f64x2.convert_low_i32x4_s",
        .@"f64x2.convert_low_i32x4_u",
        .@"f64x2.promote_low_f32x4",
        .@"f32x4.demote_f64x2_zero",
        .@"i32x4.trunc_sat_f32x4_s",
        .@"i32x4.trunc_sat_f32x4_u",
        .@"i32x4.trunc_sat_f64x2_s_zero",
        .@"i32x4.trunc_sat_f64x2_u_zero",
        // 1 → 1: bitmask / all_true / any_true (pop v128, push i32).
        .@"v128.any_true",
        .@"i8x16.all_true",
        .@"i16x8.all_true",
        .@"i32x4.all_true",
        .@"i64x2.all_true",
        .@"i8x16.bitmask",
        .@"i16x8.bitmask",
        .@"i32x4.bitmask",
        .@"i64x2.bitmask",
        => .{ .pops = 1, .pushes = 1 },
        // 2 → 1: bitwise binop.
        .@"v128.and",
        .@"v128.or",
        .@"v128.xor",
        .@"v128.andnot",
        // 2 → 1: integer add/sub/mul.
        .@"i8x16.add",
        .@"i8x16.sub",
        .@"i16x8.add",
        .@"i16x8.sub",
        .@"i16x8.mul",
        .@"i32x4.add",
        .@"i32x4.sub",
        .@"i32x4.mul",
        .@"i64x2.add",
        .@"i64x2.sub",
        .@"i64x2.mul",
        // 2 → 1: saturating arith + avgr.
        .@"i8x16.add_sat_s",
        .@"i8x16.add_sat_u",
        .@"i8x16.sub_sat_s",
        .@"i8x16.sub_sat_u",
        .@"i16x8.add_sat_s",
        .@"i16x8.add_sat_u",
        .@"i16x8.sub_sat_s",
        .@"i16x8.sub_sat_u",
        .@"i8x16.avgr_u",
        .@"i16x8.avgr_u",
        // 2 → 1: min/max.
        .@"i8x16.min_s",
        .@"i8x16.min_u",
        .@"i8x16.max_s",
        .@"i8x16.max_u",
        .@"i16x8.min_s",
        .@"i16x8.min_u",
        .@"i16x8.max_s",
        .@"i16x8.max_u",
        .@"i32x4.min_s",
        .@"i32x4.min_u",
        .@"i32x4.max_s",
        .@"i32x4.max_u",
        // 2 → 1: int compare.
        .@"i8x16.eq",
        .@"i8x16.ne",
        .@"i8x16.lt_s",
        .@"i8x16.lt_u",
        .@"i8x16.gt_s",
        .@"i8x16.gt_u",
        .@"i8x16.le_s",
        .@"i8x16.le_u",
        .@"i8x16.ge_s",
        .@"i8x16.ge_u",
        .@"i16x8.eq",
        .@"i16x8.ne",
        .@"i16x8.lt_s",
        .@"i16x8.lt_u",
        .@"i16x8.gt_s",
        .@"i16x8.gt_u",
        .@"i16x8.le_s",
        .@"i16x8.le_u",
        .@"i16x8.ge_s",
        .@"i16x8.ge_u",
        .@"i32x4.eq",
        .@"i32x4.ne",
        .@"i32x4.lt_s",
        .@"i32x4.lt_u",
        .@"i32x4.gt_s",
        .@"i32x4.gt_u",
        .@"i32x4.le_s",
        .@"i32x4.le_u",
        .@"i32x4.ge_s",
        .@"i32x4.ge_u",
        .@"i64x2.eq",
        .@"i64x2.ne",
        .@"i64x2.lt_s",
        .@"i64x2.gt_s",
        .@"i64x2.le_s",
        .@"i64x2.ge_s",
        // 2 → 1: FP compare.
        .@"f32x4.eq",
        .@"f32x4.ne",
        .@"f32x4.lt",
        .@"f32x4.gt",
        .@"f32x4.le",
        .@"f32x4.ge",
        .@"f64x2.eq",
        .@"f64x2.ne",
        .@"f64x2.lt",
        .@"f64x2.gt",
        .@"f64x2.le",
        .@"f64x2.ge",
        // 2 → 1: FP arith.
        .@"f32x4.add",
        .@"f32x4.sub",
        .@"f32x4.mul",
        .@"f32x4.div",
        .@"f32x4.min",
        .@"f32x4.max",
        .@"f32x4.pmin",
        .@"f32x4.pmax",
        .@"f64x2.add",
        .@"f64x2.sub",
        .@"f64x2.mul",
        .@"f64x2.div",
        .@"f64x2.min",
        .@"f64x2.max",
        .@"f64x2.pmin",
        .@"f64x2.pmax",
        // 2 → 1: shifts (pop v128 + i32 count).
        .@"i8x16.shl",
        .@"i8x16.shr_s",
        .@"i8x16.shr_u",
        .@"i16x8.shl",
        .@"i16x8.shr_s",
        .@"i16x8.shr_u",
        .@"i32x4.shl",
        .@"i32x4.shr_s",
        .@"i32x4.shr_u",
        .@"i64x2.shl",
        .@"i64x2.shr_s",
        .@"i64x2.shr_u",
        // 2 → 1: shuffle (2 v128 + 16-byte imm) / swizzle.
        .@"i8x16.shuffle",
        .@"i8x16.swizzle",
        // 2 → 1: replace_lane (pop v128 + scalar; imm in payload).
        .@"i8x16.replace_lane",
        .@"i16x8.replace_lane",
        .@"i32x4.replace_lane",
        .@"i64x2.replace_lane",
        .@"f32x4.replace_lane",
        .@"f64x2.replace_lane",
        // 2 → 1: narrow saturating (2 v128 → 1 v128).
        .@"i8x16.narrow_i16x8_s",
        .@"i8x16.narrow_i16x8_u",
        .@"i16x8.narrow_i32x4_s",
        .@"i16x8.narrow_i32x4_u",
        // 2 → 1: ext multiply / dot / q15mulr.
        .@"i16x8.q15mulr_sat_s",
        .@"i32x4.dot_i16x8_s",
        .@"i16x8.extmul_low_i8x16_s",
        .@"i16x8.extmul_high_i8x16_s",
        .@"i16x8.extmul_low_i8x16_u",
        .@"i16x8.extmul_high_i8x16_u",
        .@"i32x4.extmul_low_i16x8_s",
        .@"i32x4.extmul_high_i16x8_s",
        .@"i32x4.extmul_low_i16x8_u",
        .@"i32x4.extmul_high_i16x8_u",
        .@"i64x2.extmul_low_i32x4_s",
        .@"i64x2.extmul_high_i32x4_s",
        .@"i64x2.extmul_low_i32x4_u",
        .@"i64x2.extmul_high_i32x4_u",
        // 2 → 1: relaxed-SIMD binops (17.4) — swizzle / min / max / q15mulr / dot_s.
        .@"i8x16.relaxed_swizzle",
        .@"f32x4.relaxed_min",
        .@"f32x4.relaxed_max",
        .@"f64x2.relaxed_min",
        .@"f64x2.relaxed_max",
        .@"i16x8.relaxed_q15mulr_s",
        .@"i16x8.relaxed_dot_i8x16_i7x16_s",
        => .{ .pops = 2, .pushes = 1 },
        // 3 → 1: bitselect (a, b, mask) + relaxed-SIMD ternops (17.4) —
        // madd/nmadd (a*b+c), laneselect (a, b, mask), dot_add (a, b, acc).
        .@"v128.bitselect",
        .@"f32x4.relaxed_madd",
        .@"f32x4.relaxed_nmadd",
        .@"f64x2.relaxed_madd",
        .@"f64x2.relaxed_nmadd",
        .@"i8x16.relaxed_laneselect",
        .@"i16x8.relaxed_laneselect",
        .@"i32x4.relaxed_laneselect",
        .@"i64x2.relaxed_laneselect",
        .@"i32x4.relaxed_dot_i8x16_i7x16_add_s",
        => .{ .pops = 3, .pushes = 1 },
        else => null,
    };
}
