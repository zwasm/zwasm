// FILE-SIZE-EXEMPT: codegen op registry — pure data, structurally homogeneous (per ADR-0086 §Consequences)
//! Codegen op registry — pure data extracted from
//! `dispatch_collector.zig` per ADR-0086 (mirror of ADR-0082's
//! ir/dispatch_collector_ops.zig).
//!
//! Per-arch op-module imports + the three `collected_<axis>_ops`
//! tuples (`collected_arm64_ops`, `collected_x86_64_ops`,
//! `collected_x86_64_ctx_ops`). The dispatcher framework
//! (validateArchOpModule, migratedArchOpCount, dispatch,
//! dispatchX86_64Ctx) + comptime validation stays in
//! `dispatch_collector.zig`; this file is the data side.
//!
//! Zone 2 (`src/engine/codegen/`).

const arm64_i32_add = @import("arm64/ops/wasm_1_0/i32_add.zig");
const arm64_i32_sub = @import("arm64/ops/wasm_1_0/i32_sub.zig");
const arm64_i32_mul = @import("arm64/ops/wasm_1_0/i32_mul.zig");
const arm64_i32_and = @import("arm64/ops/wasm_1_0/i32_and.zig");
const arm64_i32_or = @import("arm64/ops/wasm_1_0/i32_or.zig");
const arm64_i32_xor = @import("arm64/ops/wasm_1_0/i32_xor.zig");
const arm64_i64_add = @import("arm64/ops/wasm_1_0/i64_add.zig");
const arm64_i64_sub = @import("arm64/ops/wasm_1_0/i64_sub.zig");
const arm64_i64_mul = @import("arm64/ops/wasm_1_0/i64_mul.zig");
const arm64_i64_and = @import("arm64/ops/wasm_1_0/i64_and.zig");
const arm64_i64_or = @import("arm64/ops/wasm_1_0/i64_or.zig");
const arm64_i64_xor = @import("arm64/ops/wasm_1_0/i64_xor.zig");
const arm64_i32_eq = @import("arm64/ops/wasm_1_0/i32_eq.zig");
const arm64_i32_ne = @import("arm64/ops/wasm_1_0/i32_ne.zig");
const arm64_i32_lt_s = @import("arm64/ops/wasm_1_0/i32_lt_s.zig");
const arm64_i32_lt_u = @import("arm64/ops/wasm_1_0/i32_lt_u.zig");
const arm64_i32_gt_s = @import("arm64/ops/wasm_1_0/i32_gt_s.zig");
const arm64_i32_gt_u = @import("arm64/ops/wasm_1_0/i32_gt_u.zig");
const arm64_i32_le_s = @import("arm64/ops/wasm_1_0/i32_le_s.zig");
const arm64_i32_le_u = @import("arm64/ops/wasm_1_0/i32_le_u.zig");
const arm64_i32_ge_s = @import("arm64/ops/wasm_1_0/i32_ge_s.zig");
const arm64_i32_ge_u = @import("arm64/ops/wasm_1_0/i32_ge_u.zig");
const arm64_i64_eq = @import("arm64/ops/wasm_1_0/i64_eq.zig");
const arm64_i64_ne = @import("arm64/ops/wasm_1_0/i64_ne.zig");
const arm64_i64_lt_s = @import("arm64/ops/wasm_1_0/i64_lt_s.zig");
const arm64_i64_lt_u = @import("arm64/ops/wasm_1_0/i64_lt_u.zig");
const arm64_i64_gt_s = @import("arm64/ops/wasm_1_0/i64_gt_s.zig");
const arm64_i64_gt_u = @import("arm64/ops/wasm_1_0/i64_gt_u.zig");
const arm64_i64_le_s = @import("arm64/ops/wasm_1_0/i64_le_s.zig");
const arm64_i64_le_u = @import("arm64/ops/wasm_1_0/i64_le_u.zig");
const arm64_i64_ge_s = @import("arm64/ops/wasm_1_0/i64_ge_s.zig");
const arm64_i64_ge_u = @import("arm64/ops/wasm_1_0/i64_ge_u.zig");
const arm64_i32_eqz = @import("arm64/ops/wasm_1_0/i32_eqz.zig");
const arm64_i64_eqz = @import("arm64/ops/wasm_1_0/i64_eqz.zig");
const arm64_i32_shl = @import("arm64/ops/wasm_1_0/i32_shl.zig");
const arm64_i32_shr_s = @import("arm64/ops/wasm_1_0/i32_shr_s.zig");
const arm64_i32_shr_u = @import("arm64/ops/wasm_1_0/i32_shr_u.zig");
const arm64_i32_rotl = @import("arm64/ops/wasm_1_0/i32_rotl.zig");
const arm64_i32_rotr = @import("arm64/ops/wasm_1_0/i32_rotr.zig");
const arm64_i64_shl = @import("arm64/ops/wasm_1_0/i64_shl.zig");
const arm64_i64_shr_s = @import("arm64/ops/wasm_1_0/i64_shr_s.zig");
const arm64_i64_shr_u = @import("arm64/ops/wasm_1_0/i64_shr_u.zig");
const arm64_i64_rotl = @import("arm64/ops/wasm_1_0/i64_rotl.zig");
const arm64_i64_rotr = @import("arm64/ops/wasm_1_0/i64_rotr.zig");
const arm64_i32_clz = @import("arm64/ops/wasm_1_0/i32_clz.zig");
const arm64_i32_ctz = @import("arm64/ops/wasm_1_0/i32_ctz.zig");
const arm64_i32_popcnt = @import("arm64/ops/wasm_1_0/i32_popcnt.zig");
const arm64_i64_clz = @import("arm64/ops/wasm_1_0/i64_clz.zig");
const arm64_i64_ctz = @import("arm64/ops/wasm_1_0/i64_ctz.zig");
const arm64_i64_popcnt = @import("arm64/ops/wasm_1_0/i64_popcnt.zig");
const arm64_i32_extend8_s = @import("arm64/ops/wasm_2_0/i32_extend8_s.zig");
const arm64_i32_extend16_s = @import("arm64/ops/wasm_2_0/i32_extend16_s.zig");
const arm64_i64_extend8_s = @import("arm64/ops/wasm_2_0/i64_extend8_s.zig");
const arm64_i64_extend16_s = @import("arm64/ops/wasm_2_0/i64_extend16_s.zig");
const arm64_i64_extend32_s = @import("arm64/ops/wasm_2_0/i64_extend32_s.zig");

const arm64_i32_trunc_sat_f32_s = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f32_s.zig");
const arm64_i32_trunc_sat_f32_u = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f32_u.zig");
const arm64_i32_trunc_sat_f64_s = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f64_s.zig");
const arm64_i32_trunc_sat_f64_u = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f64_u.zig");
const arm64_i64_trunc_sat_f32_s = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f32_s.zig");
const arm64_i64_trunc_sat_f32_u = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f32_u.zig");
const arm64_i64_trunc_sat_f64_s = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f64_s.zig");
const arm64_i64_trunc_sat_f64_u = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f64_u.zig");
const arm64_v128_not = @import("arm64/ops/wasm_2_0/v128_not.zig");
const arm64_v128_and = @import("arm64/ops/wasm_2_0/v128_and.zig");
const arm64_v128_or = @import("arm64/ops/wasm_2_0/v128_or.zig");
const arm64_v128_xor = @import("arm64/ops/wasm_2_0/v128_xor.zig");
const arm64_v128_andnot = @import("arm64/ops/wasm_2_0/v128_andnot.zig");
const arm64_v128_bitselect = @import("arm64/ops/wasm_2_0/v128_bitselect.zig");

const arm64_i8x16_add = @import("arm64/ops/wasm_2_0/i8x16_add.zig");
const arm64_i8x16_sub = @import("arm64/ops/wasm_2_0/i8x16_sub.zig");
const arm64_i16x8_add = @import("arm64/ops/wasm_2_0/i16x8_add.zig");
const arm64_i16x8_sub = @import("arm64/ops/wasm_2_0/i16x8_sub.zig");
const arm64_i16x8_mul = @import("arm64/ops/wasm_2_0/i16x8_mul.zig");
const arm64_i32x4_add = @import("arm64/ops/wasm_2_0/i32x4_add.zig");
const arm64_i32x4_sub = @import("arm64/ops/wasm_2_0/i32x4_sub.zig");
const arm64_i32x4_mul = @import("arm64/ops/wasm_2_0/i32x4_mul.zig");
const arm64_i16x8_extmul_low_i8x16_s = @import("arm64/ops/wasm_2_0/i16x8_extmul_low_i8x16_s.zig");
const arm64_i16x8_extmul_high_i8x16_s = @import("arm64/ops/wasm_2_0/i16x8_extmul_high_i8x16_s.zig");
const arm64_i16x8_extmul_low_i8x16_u = @import("arm64/ops/wasm_2_0/i16x8_extmul_low_i8x16_u.zig");
const arm64_i16x8_extmul_high_i8x16_u = @import("arm64/ops/wasm_2_0/i16x8_extmul_high_i8x16_u.zig");
const arm64_i32x4_extmul_low_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_extmul_low_i16x8_s.zig");
const arm64_i32x4_extmul_high_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_extmul_high_i16x8_s.zig");
const arm64_i32x4_extmul_low_i16x8_u = @import("arm64/ops/wasm_2_0/i32x4_extmul_low_i16x8_u.zig");
const arm64_i32x4_extmul_high_i16x8_u = @import("arm64/ops/wasm_2_0/i32x4_extmul_high_i16x8_u.zig");
const arm64_i32x4_dot_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_dot_i16x8_s.zig");
const arm64_i8x16_add_sat_s = @import("arm64/ops/wasm_2_0/i8x16_add_sat_s.zig");
const arm64_i8x16_add_sat_u = @import("arm64/ops/wasm_2_0/i8x16_add_sat_u.zig");
const arm64_i8x16_sub_sat_s = @import("arm64/ops/wasm_2_0/i8x16_sub_sat_s.zig");
const arm64_i8x16_sub_sat_u = @import("arm64/ops/wasm_2_0/i8x16_sub_sat_u.zig");
const arm64_i16x8_add_sat_s = @import("arm64/ops/wasm_2_0/i16x8_add_sat_s.zig");
const arm64_i16x8_add_sat_u = @import("arm64/ops/wasm_2_0/i16x8_add_sat_u.zig");
const arm64_i16x8_sub_sat_s = @import("arm64/ops/wasm_2_0/i16x8_sub_sat_s.zig");
const arm64_i16x8_sub_sat_u = @import("arm64/ops/wasm_2_0/i16x8_sub_sat_u.zig");
const arm64_i16x8_q15mulr_sat_s = @import("arm64/ops/wasm_2_0/i16x8_q15mulr_sat_s.zig");
const arm64_i16x8_extadd_pairwise_i8x16_s = @import("arm64/ops/wasm_2_0/i16x8_extadd_pairwise_i8x16_s.zig");
const arm64_i16x8_extadd_pairwise_i8x16_u = @import("arm64/ops/wasm_2_0/i16x8_extadd_pairwise_i8x16_u.zig");
const arm64_i32x4_extadd_pairwise_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_extadd_pairwise_i16x8_s.zig");
const arm64_i32x4_extadd_pairwise_i16x8_u = @import("arm64/ops/wasm_2_0/i32x4_extadd_pairwise_i16x8_u.zig");
const arm64_i64x2_extmul_low_i32x4_s = @import("arm64/ops/wasm_2_0/i64x2_extmul_low_i32x4_s.zig");
const arm64_i64x2_extmul_high_i32x4_s = @import("arm64/ops/wasm_2_0/i64x2_extmul_high_i32x4_s.zig");
const arm64_i64x2_extmul_low_i32x4_u = @import("arm64/ops/wasm_2_0/i64x2_extmul_low_i32x4_u.zig");
const arm64_i64x2_extmul_high_i32x4_u = @import("arm64/ops/wasm_2_0/i64x2_extmul_high_i32x4_u.zig");
const arm64_i64x2_add = @import("arm64/ops/wasm_2_0/i64x2_add.zig");
const arm64_i64x2_sub = @import("arm64/ops/wasm_2_0/i64x2_sub.zig");
const arm64_i8x16_neg = @import("arm64/ops/wasm_2_0/i8x16_neg.zig");
const arm64_i8x16_abs = @import("arm64/ops/wasm_2_0/i8x16_abs.zig");
const arm64_i16x8_neg = @import("arm64/ops/wasm_2_0/i16x8_neg.zig");
const arm64_i16x8_abs = @import("arm64/ops/wasm_2_0/i16x8_abs.zig");
const arm64_i32x4_neg = @import("arm64/ops/wasm_2_0/i32x4_neg.zig");
const arm64_i32x4_abs = @import("arm64/ops/wasm_2_0/i32x4_abs.zig");
const arm64_i64x2_neg = @import("arm64/ops/wasm_2_0/i64x2_neg.zig");
const arm64_i64x2_abs = @import("arm64/ops/wasm_2_0/i64x2_abs.zig");
const arm64_i8x16_eq = @import("arm64/ops/wasm_2_0/i8x16_eq.zig");
const arm64_i8x16_ne = @import("arm64/ops/wasm_2_0/i8x16_ne.zig");
const arm64_i8x16_lt_s = @import("arm64/ops/wasm_2_0/i8x16_lt_s.zig");
const arm64_i8x16_lt_u = @import("arm64/ops/wasm_2_0/i8x16_lt_u.zig");
const arm64_i8x16_gt_s = @import("arm64/ops/wasm_2_0/i8x16_gt_s.zig");
const arm64_i8x16_gt_u = @import("arm64/ops/wasm_2_0/i8x16_gt_u.zig");
const arm64_i8x16_le_s = @import("arm64/ops/wasm_2_0/i8x16_le_s.zig");
const arm64_i8x16_le_u = @import("arm64/ops/wasm_2_0/i8x16_le_u.zig");
const arm64_i8x16_ge_s = @import("arm64/ops/wasm_2_0/i8x16_ge_s.zig");
const arm64_i8x16_ge_u = @import("arm64/ops/wasm_2_0/i8x16_ge_u.zig");

const x86_64_i8x16_eq = @import("x86_64/ops/wasm_2_0/i8x16_eq.zig");
const x86_64_i8x16_ne = @import("x86_64/ops/wasm_2_0/i8x16_ne.zig");
const x86_64_i8x16_lt_s = @import("x86_64/ops/wasm_2_0/i8x16_lt_s.zig");
const x86_64_i8x16_lt_u = @import("x86_64/ops/wasm_2_0/i8x16_lt_u.zig");
const x86_64_i8x16_gt_s = @import("x86_64/ops/wasm_2_0/i8x16_gt_s.zig");
const x86_64_i8x16_gt_u = @import("x86_64/ops/wasm_2_0/i8x16_gt_u.zig");
const x86_64_i8x16_le_s = @import("x86_64/ops/wasm_2_0/i8x16_le_s.zig");
const x86_64_i8x16_le_u = @import("x86_64/ops/wasm_2_0/i8x16_le_u.zig");
const x86_64_i8x16_ge_s = @import("x86_64/ops/wasm_2_0/i8x16_ge_s.zig");
const x86_64_i8x16_ge_u = @import("x86_64/ops/wasm_2_0/i8x16_ge_u.zig");

const arm64_i16x8_eq = @import("arm64/ops/wasm_2_0/i16x8_eq.zig");
const arm64_i16x8_ne = @import("arm64/ops/wasm_2_0/i16x8_ne.zig");
const arm64_i16x8_lt_s = @import("arm64/ops/wasm_2_0/i16x8_lt_s.zig");
const arm64_i16x8_lt_u = @import("arm64/ops/wasm_2_0/i16x8_lt_u.zig");
const arm64_i16x8_gt_s = @import("arm64/ops/wasm_2_0/i16x8_gt_s.zig");
const arm64_i16x8_gt_u = @import("arm64/ops/wasm_2_0/i16x8_gt_u.zig");
const arm64_i16x8_le_s = @import("arm64/ops/wasm_2_0/i16x8_le_s.zig");
const arm64_i16x8_le_u = @import("arm64/ops/wasm_2_0/i16x8_le_u.zig");
const arm64_i16x8_ge_s = @import("arm64/ops/wasm_2_0/i16x8_ge_s.zig");
const arm64_i16x8_ge_u = @import("arm64/ops/wasm_2_0/i16x8_ge_u.zig");

const arm64_i32x4_eq = @import("arm64/ops/wasm_2_0/i32x4_eq.zig");
const arm64_i32x4_ne = @import("arm64/ops/wasm_2_0/i32x4_ne.zig");
const arm64_i32x4_lt_s = @import("arm64/ops/wasm_2_0/i32x4_lt_s.zig");
const arm64_i32x4_lt_u = @import("arm64/ops/wasm_2_0/i32x4_lt_u.zig");
const arm64_i32x4_gt_s = @import("arm64/ops/wasm_2_0/i32x4_gt_s.zig");
const arm64_i32x4_gt_u = @import("arm64/ops/wasm_2_0/i32x4_gt_u.zig");
const arm64_i32x4_le_s = @import("arm64/ops/wasm_2_0/i32x4_le_s.zig");
const arm64_i32x4_le_u = @import("arm64/ops/wasm_2_0/i32x4_le_u.zig");
const arm64_i32x4_ge_s = @import("arm64/ops/wasm_2_0/i32x4_ge_s.zig");
const arm64_i32x4_ge_u = @import("arm64/ops/wasm_2_0/i32x4_ge_u.zig");

const arm64_i64x2_eq = @import("arm64/ops/wasm_2_0/i64x2_eq.zig");
const arm64_i64x2_ne = @import("arm64/ops/wasm_2_0/i64x2_ne.zig");
const arm64_i64x2_lt_s = @import("arm64/ops/wasm_2_0/i64x2_lt_s.zig");
const arm64_i64x2_gt_s = @import("arm64/ops/wasm_2_0/i64x2_gt_s.zig");
const arm64_i64x2_le_s = @import("arm64/ops/wasm_2_0/i64x2_le_s.zig");
const arm64_i64x2_ge_s = @import("arm64/ops/wasm_2_0/i64x2_ge_s.zig");

const arm64_i8x16_avgr_u = @import("arm64/ops/wasm_2_0/i8x16_avgr_u.zig");
const arm64_i16x8_avgr_u = @import("arm64/ops/wasm_2_0/i16x8_avgr_u.zig");

const arm64_call = @import("arm64/ops/wasm_1_0/call.zig");
const arm64_call_indirect = @import("arm64/ops/wasm_1_0/call_indirect.zig");

const arm64_ref_is_null = @import("arm64/ops/wasm_1_0/ref_is_null.zig");
const arm64_i8x16_splat = @import("arm64/ops/wasm_2_0/i8x16_splat.zig");
const arm64_i16x8_splat = @import("arm64/ops/wasm_2_0/i16x8_splat.zig");
const arm64_i32x4_splat = @import("arm64/ops/wasm_2_0/i32x4_splat.zig");
const arm64_i64x2_splat = @import("arm64/ops/wasm_2_0/i64x2_splat.zig");
const arm64_f32x4_splat = @import("arm64/ops/wasm_2_0/f32x4_splat.zig");
const arm64_f64x2_splat = @import("arm64/ops/wasm_2_0/f64x2_splat.zig");

const x86_64_ref_is_null = @import("x86_64/ops/wasm_1_0/ref_is_null.zig");
const x86_64_i8x16_splat = @import("x86_64/ops/wasm_2_0/i8x16_splat.zig");
const x86_64_i16x8_splat = @import("x86_64/ops/wasm_2_0/i16x8_splat.zig");
const x86_64_i32x4_splat = @import("x86_64/ops/wasm_2_0/i32x4_splat.zig");
const x86_64_i64x2_splat = @import("x86_64/ops/wasm_2_0/i64x2_splat.zig");
const x86_64_f32x4_splat = @import("x86_64/ops/wasm_2_0/f32x4_splat.zig");
const x86_64_f64x2_splat = @import("x86_64/ops/wasm_2_0/f64x2_splat.zig");

const arm64_i32_trunc_f32_s = @import("arm64/ops/wasm_1_0/i32_trunc_f32_s.zig");
const arm64_i32_trunc_f32_u = @import("arm64/ops/wasm_1_0/i32_trunc_f32_u.zig");
const arm64_i64_trunc_f32_s = @import("arm64/ops/wasm_1_0/i64_trunc_f32_s.zig");
const arm64_i64_trunc_f32_u = @import("arm64/ops/wasm_1_0/i64_trunc_f32_u.zig");
const arm64_i32_trunc_f64_s = @import("arm64/ops/wasm_1_0/i32_trunc_f64_s.zig");
const arm64_i32_trunc_f64_u = @import("arm64/ops/wasm_1_0/i32_trunc_f64_u.zig");
const arm64_i64_trunc_f64_s = @import("arm64/ops/wasm_1_0/i64_trunc_f64_s.zig");
const arm64_i64_trunc_f64_u = @import("arm64/ops/wasm_1_0/i64_trunc_f64_u.zig");

const arm64_block = @import("arm64/ops/wasm_1_0/block.zig");
const arm64_loop = @import("arm64/ops/wasm_1_0/loop.zig");
const arm64_br_if = @import("arm64/ops/wasm_1_0/br_if.zig");
const arm64_br_table = @import("arm64/ops/wasm_1_0/br_table.zig");
const arm64_if_ = @import("arm64/ops/wasm_1_0/if_.zig");
const arm64_else_ = @import("arm64/ops/wasm_1_0/else_.zig");

const arm64_memory_fill = @import("arm64/ops/wasm_1_0/memory_fill.zig");
const arm64_memory_copy = @import("arm64/ops/wasm_1_0/memory_copy.zig");
const arm64_memory_init = @import("arm64/ops/wasm_1_0/memory_init.zig");

const arm64_i32_load = @import("arm64/ops/wasm_1_0/i32_load.zig");
const arm64_i32_load8_s = @import("arm64/ops/wasm_1_0/i32_load8_s.zig");
const arm64_i32_load8_u = @import("arm64/ops/wasm_1_0/i32_load8_u.zig");
const arm64_i32_load16_s = @import("arm64/ops/wasm_1_0/i32_load16_s.zig");
const arm64_i32_load16_u = @import("arm64/ops/wasm_1_0/i32_load16_u.zig");
const arm64_i32_store = @import("arm64/ops/wasm_1_0/i32_store.zig");
const arm64_i32_store8 = @import("arm64/ops/wasm_1_0/i32_store8.zig");
const arm64_i32_store16 = @import("arm64/ops/wasm_1_0/i32_store16.zig");
const arm64_i64_load = @import("arm64/ops/wasm_1_0/i64_load.zig");
const arm64_i64_load8_s = @import("arm64/ops/wasm_1_0/i64_load8_s.zig");
const arm64_i64_load8_u = @import("arm64/ops/wasm_1_0/i64_load8_u.zig");
const arm64_i64_load16_s = @import("arm64/ops/wasm_1_0/i64_load16_s.zig");
const arm64_i64_load16_u = @import("arm64/ops/wasm_1_0/i64_load16_u.zig");
const arm64_i64_load32_s = @import("arm64/ops/wasm_1_0/i64_load32_s.zig");
const arm64_i64_load32_u = @import("arm64/ops/wasm_1_0/i64_load32_u.zig");
const arm64_i64_store = @import("arm64/ops/wasm_1_0/i64_store.zig");
const arm64_i64_store8 = @import("arm64/ops/wasm_1_0/i64_store8.zig");
const arm64_i64_store16 = @import("arm64/ops/wasm_1_0/i64_store16.zig");
const arm64_i64_store32 = @import("arm64/ops/wasm_1_0/i64_store32.zig");
const arm64_f32_load = @import("arm64/ops/wasm_1_0/f32_load.zig");
const arm64_f32_store = @import("arm64/ops/wasm_1_0/f32_store.zig");
const arm64_f64_load = @import("arm64/ops/wasm_1_0/f64_load.zig");
const arm64_f64_store = @import("arm64/ops/wasm_1_0/f64_store.zig");

const arm64_global_get = @import("arm64/ops/wasm_1_0/global_get.zig");
const arm64_global_set = @import("arm64/ops/wasm_1_0/global_set.zig");
const arm64_table_get = @import("arm64/ops/wasm_1_0/table_get.zig");
const arm64_table_set = @import("arm64/ops/wasm_1_0/table_set.zig");
const arm64_table_size = @import("arm64/ops/wasm_1_0/table_size.zig");
const arm64_table_grow = @import("arm64/ops/wasm_1_0/table_grow.zig");
const arm64_table_fill = @import("arm64/ops/wasm_1_0/table_fill.zig");
const arm64_table_copy = @import("arm64/ops/wasm_1_0/table_copy.zig");
const arm64_table_init = @import("arm64/ops/wasm_1_0/table_init.zig");

const arm64_i8x16_swizzle = @import("arm64/ops/wasm_2_0/i8x16_swizzle.zig");
const arm64_i8x16_relaxed_swizzle = @import("arm64/ops/wasm_3_0/i8x16_relaxed_swizzle.zig");
const arm64_i8x16_popcnt = @import("arm64/ops/wasm_2_0/i8x16_popcnt.zig");
const arm64_f32x4_convert_i32x4_s = @import("arm64/ops/wasm_2_0/f32x4_convert_i32x4_s.zig");
const arm64_f32x4_convert_i32x4_u = @import("arm64/ops/wasm_2_0/f32x4_convert_i32x4_u.zig");
const arm64_f64x2_convert_low_i32x4_s = @import("arm64/ops/wasm_2_0/f64x2_convert_low_i32x4_s.zig");
const arm64_f64x2_promote_low_f32x4 = @import("arm64/ops/wasm_2_0/f64x2_promote_low_f32x4.zig");
const arm64_f32x4_demote_f64x2_zero = @import("arm64/ops/wasm_2_0/f32x4_demote_f64x2_zero.zig");
const arm64_i32x4_trunc_sat_f32x4_s = @import("arm64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_s.zig");
const arm64_i32x4_trunc_sat_f32x4_u = @import("arm64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_u.zig");

const arm64_i8x16_narrow_i16x8_s = @import("arm64/ops/wasm_2_0/i8x16_narrow_i16x8_s.zig");
const arm64_i8x16_narrow_i16x8_u = @import("arm64/ops/wasm_2_0/i8x16_narrow_i16x8_u.zig");
const arm64_i16x8_narrow_i32x4_s = @import("arm64/ops/wasm_2_0/i16x8_narrow_i32x4_s.zig");
const arm64_i16x8_narrow_i32x4_u = @import("arm64/ops/wasm_2_0/i16x8_narrow_i32x4_u.zig");
const arm64_i16x8_extend_low_i8x16_s = @import("arm64/ops/wasm_2_0/i16x8_extend_low_i8x16_s.zig");
const arm64_i16x8_extend_high_i8x16_s = @import("arm64/ops/wasm_2_0/i16x8_extend_high_i8x16_s.zig");
const arm64_i16x8_extend_low_i8x16_u = @import("arm64/ops/wasm_2_0/i16x8_extend_low_i8x16_u.zig");
const arm64_i16x8_extend_high_i8x16_u = @import("arm64/ops/wasm_2_0/i16x8_extend_high_i8x16_u.zig");
const arm64_i32x4_extend_low_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_extend_low_i16x8_s.zig");
const arm64_i32x4_extend_high_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_extend_high_i16x8_s.zig");
const arm64_i32x4_extend_low_i16x8_u = @import("arm64/ops/wasm_2_0/i32x4_extend_low_i16x8_u.zig");
const arm64_i32x4_extend_high_i16x8_u = @import("arm64/ops/wasm_2_0/i32x4_extend_high_i16x8_u.zig");
const arm64_i64x2_extend_low_i32x4_s = @import("arm64/ops/wasm_2_0/i64x2_extend_low_i32x4_s.zig");
const arm64_i64x2_extend_high_i32x4_s = @import("arm64/ops/wasm_2_0/i64x2_extend_high_i32x4_s.zig");
const arm64_i64x2_extend_low_i32x4_u = @import("arm64/ops/wasm_2_0/i64x2_extend_low_i32x4_u.zig");
const arm64_i64x2_extend_high_i32x4_u = @import("arm64/ops/wasm_2_0/i64x2_extend_high_i32x4_u.zig");

const arm64_v128_any_true = @import("arm64/ops/wasm_2_0/v128_any_true.zig");
const arm64_i8x16_all_true = @import("arm64/ops/wasm_2_0/i8x16_all_true.zig");
const arm64_i16x8_all_true = @import("arm64/ops/wasm_2_0/i16x8_all_true.zig");
const arm64_i32x4_all_true = @import("arm64/ops/wasm_2_0/i32x4_all_true.zig");
const arm64_i64x2_all_true = @import("arm64/ops/wasm_2_0/i64x2_all_true.zig");
const arm64_i8x16_bitmask = @import("arm64/ops/wasm_2_0/i8x16_bitmask.zig");
const arm64_i16x8_bitmask = @import("arm64/ops/wasm_2_0/i16x8_bitmask.zig");
const arm64_i32x4_bitmask = @import("arm64/ops/wasm_2_0/i32x4_bitmask.zig");
const arm64_i64x2_bitmask = @import("arm64/ops/wasm_2_0/i64x2_bitmask.zig");

const arm64_f32x4_eq = @import("arm64/ops/wasm_2_0/f32x4_eq.zig");
const arm64_f32x4_ne = @import("arm64/ops/wasm_2_0/f32x4_ne.zig");
const arm64_f32x4_lt = @import("arm64/ops/wasm_2_0/f32x4_lt.zig");
const arm64_f32x4_gt = @import("arm64/ops/wasm_2_0/f32x4_gt.zig");
const arm64_f32x4_le = @import("arm64/ops/wasm_2_0/f32x4_le.zig");
const arm64_f32x4_ge = @import("arm64/ops/wasm_2_0/f32x4_ge.zig");
const arm64_f64x2_eq = @import("arm64/ops/wasm_2_0/f64x2_eq.zig");
const arm64_f64x2_ne = @import("arm64/ops/wasm_2_0/f64x2_ne.zig");
const arm64_f64x2_lt = @import("arm64/ops/wasm_2_0/f64x2_lt.zig");
const arm64_f64x2_gt = @import("arm64/ops/wasm_2_0/f64x2_gt.zig");
const arm64_f64x2_le = @import("arm64/ops/wasm_2_0/f64x2_le.zig");
const arm64_f64x2_ge = @import("arm64/ops/wasm_2_0/f64x2_ge.zig");

const arm64_f32x4_abs = @import("arm64/ops/wasm_2_0/f32x4_abs.zig");
const arm64_f32x4_neg = @import("arm64/ops/wasm_2_0/f32x4_neg.zig");
const arm64_f32x4_sqrt = @import("arm64/ops/wasm_2_0/f32x4_sqrt.zig");
const arm64_f32x4_ceil = @import("arm64/ops/wasm_2_0/f32x4_ceil.zig");
const arm64_f32x4_floor = @import("arm64/ops/wasm_2_0/f32x4_floor.zig");
const arm64_f32x4_trunc = @import("arm64/ops/wasm_2_0/f32x4_trunc.zig");
const arm64_f32x4_nearest = @import("arm64/ops/wasm_2_0/f32x4_nearest.zig");
const arm64_f64x2_abs = @import("arm64/ops/wasm_2_0/f64x2_abs.zig");
const arm64_f64x2_neg = @import("arm64/ops/wasm_2_0/f64x2_neg.zig");
const arm64_f64x2_sqrt = @import("arm64/ops/wasm_2_0/f64x2_sqrt.zig");
const arm64_f64x2_ceil = @import("arm64/ops/wasm_2_0/f64x2_ceil.zig");
const arm64_f64x2_floor = @import("arm64/ops/wasm_2_0/f64x2_floor.zig");
const arm64_f64x2_trunc = @import("arm64/ops/wasm_2_0/f64x2_trunc.zig");
const arm64_f64x2_nearest = @import("arm64/ops/wasm_2_0/f64x2_nearest.zig");

const arm64_f32x4_add = @import("arm64/ops/wasm_2_0/f32x4_add.zig");
const arm64_f32x4_sub = @import("arm64/ops/wasm_2_0/f32x4_sub.zig");
const arm64_f32x4_mul = @import("arm64/ops/wasm_2_0/f32x4_mul.zig");
const arm64_f32x4_div = @import("arm64/ops/wasm_2_0/f32x4_div.zig");
const arm64_f32x4_min = @import("arm64/ops/wasm_2_0/f32x4_min.zig");
const arm64_f32x4_max = @import("arm64/ops/wasm_2_0/f32x4_max.zig");
const arm64_f32x4_pmin = @import("arm64/ops/wasm_2_0/f32x4_pmin.zig");
const arm64_f32x4_pmax = @import("arm64/ops/wasm_2_0/f32x4_pmax.zig");
const arm64_f64x2_add = @import("arm64/ops/wasm_2_0/f64x2_add.zig");
const arm64_f64x2_sub = @import("arm64/ops/wasm_2_0/f64x2_sub.zig");
const arm64_f64x2_mul = @import("arm64/ops/wasm_2_0/f64x2_mul.zig");
const arm64_f64x2_div = @import("arm64/ops/wasm_2_0/f64x2_div.zig");
const arm64_f64x2_min = @import("arm64/ops/wasm_2_0/f64x2_min.zig");
const arm64_f64x2_max = @import("arm64/ops/wasm_2_0/f64x2_max.zig");
const arm64_f64x2_pmin = @import("arm64/ops/wasm_2_0/f64x2_pmin.zig");
const arm64_f64x2_pmax = @import("arm64/ops/wasm_2_0/f64x2_pmax.zig");

const arm64_i8x16_min_s = @import("arm64/ops/wasm_2_0/i8x16_min_s.zig");
const arm64_i8x16_min_u = @import("arm64/ops/wasm_2_0/i8x16_min_u.zig");
const arm64_i8x16_max_s = @import("arm64/ops/wasm_2_0/i8x16_max_s.zig");
const arm64_i8x16_max_u = @import("arm64/ops/wasm_2_0/i8x16_max_u.zig");
const arm64_i16x8_min_s = @import("arm64/ops/wasm_2_0/i16x8_min_s.zig");
const arm64_i16x8_min_u = @import("arm64/ops/wasm_2_0/i16x8_min_u.zig");
const arm64_i16x8_max_s = @import("arm64/ops/wasm_2_0/i16x8_max_s.zig");
const arm64_i16x8_max_u = @import("arm64/ops/wasm_2_0/i16x8_max_u.zig");
const arm64_i32x4_min_s = @import("arm64/ops/wasm_2_0/i32x4_min_s.zig");
const arm64_i32x4_min_u = @import("arm64/ops/wasm_2_0/i32x4_min_u.zig");
const arm64_i32x4_max_s = @import("arm64/ops/wasm_2_0/i32x4_max_s.zig");
const arm64_i32x4_max_u = @import("arm64/ops/wasm_2_0/i32x4_max_u.zig");

const arm64_i8x16_shl = @import("arm64/ops/wasm_2_0/i8x16_shl.zig");
const arm64_i8x16_shr_s = @import("arm64/ops/wasm_2_0/i8x16_shr_s.zig");
const arm64_i8x16_shr_u = @import("arm64/ops/wasm_2_0/i8x16_shr_u.zig");
const arm64_i16x8_shl = @import("arm64/ops/wasm_2_0/i16x8_shl.zig");
const arm64_i16x8_shr_s = @import("arm64/ops/wasm_2_0/i16x8_shr_s.zig");
const arm64_i16x8_shr_u = @import("arm64/ops/wasm_2_0/i16x8_shr_u.zig");
const arm64_i32x4_shl = @import("arm64/ops/wasm_2_0/i32x4_shl.zig");
const arm64_i32x4_shr_s = @import("arm64/ops/wasm_2_0/i32x4_shr_s.zig");
const arm64_i32x4_shr_u = @import("arm64/ops/wasm_2_0/i32x4_shr_u.zig");
const arm64_i64x2_shl = @import("arm64/ops/wasm_2_0/i64x2_shl.zig");
const arm64_i64x2_shr_s = @import("arm64/ops/wasm_2_0/i64x2_shr_s.zig");
const arm64_i64x2_shr_u = @import("arm64/ops/wasm_2_0/i64x2_shr_u.zig");

const x86_64_i16x8_eq = @import("x86_64/ops/wasm_2_0/i16x8_eq.zig");
const x86_64_i16x8_ne = @import("x86_64/ops/wasm_2_0/i16x8_ne.zig");
const x86_64_i16x8_lt_s = @import("x86_64/ops/wasm_2_0/i16x8_lt_s.zig");
const x86_64_i16x8_lt_u = @import("x86_64/ops/wasm_2_0/i16x8_lt_u.zig");
const x86_64_i16x8_gt_s = @import("x86_64/ops/wasm_2_0/i16x8_gt_s.zig");
const x86_64_i16x8_gt_u = @import("x86_64/ops/wasm_2_0/i16x8_gt_u.zig");
const x86_64_i16x8_le_s = @import("x86_64/ops/wasm_2_0/i16x8_le_s.zig");
const x86_64_i16x8_le_u = @import("x86_64/ops/wasm_2_0/i16x8_le_u.zig");
const x86_64_i16x8_ge_s = @import("x86_64/ops/wasm_2_0/i16x8_ge_s.zig");
const x86_64_i16x8_ge_u = @import("x86_64/ops/wasm_2_0/i16x8_ge_u.zig");

const x86_64_i32x4_eq = @import("x86_64/ops/wasm_2_0/i32x4_eq.zig");
const x86_64_i32x4_ne = @import("x86_64/ops/wasm_2_0/i32x4_ne.zig");
const x86_64_i32x4_lt_s = @import("x86_64/ops/wasm_2_0/i32x4_lt_s.zig");
const x86_64_i32x4_lt_u = @import("x86_64/ops/wasm_2_0/i32x4_lt_u.zig");
const x86_64_i32x4_gt_s = @import("x86_64/ops/wasm_2_0/i32x4_gt_s.zig");
const x86_64_i32x4_gt_u = @import("x86_64/ops/wasm_2_0/i32x4_gt_u.zig");
const x86_64_i32x4_le_s = @import("x86_64/ops/wasm_2_0/i32x4_le_s.zig");
const x86_64_i32x4_le_u = @import("x86_64/ops/wasm_2_0/i32x4_le_u.zig");
const x86_64_i32x4_ge_s = @import("x86_64/ops/wasm_2_0/i32x4_ge_s.zig");
const x86_64_i32x4_ge_u = @import("x86_64/ops/wasm_2_0/i32x4_ge_u.zig");

const x86_64_i64x2_eq = @import("x86_64/ops/wasm_2_0/i64x2_eq.zig");
const x86_64_i64x2_ne = @import("x86_64/ops/wasm_2_0/i64x2_ne.zig");
const x86_64_i64x2_lt_s = @import("x86_64/ops/wasm_2_0/i64x2_lt_s.zig");
const x86_64_i64x2_gt_s = @import("x86_64/ops/wasm_2_0/i64x2_gt_s.zig");
const x86_64_i64x2_le_s = @import("x86_64/ops/wasm_2_0/i64x2_le_s.zig");
const x86_64_i64x2_ge_s = @import("x86_64/ops/wasm_2_0/i64x2_ge_s.zig");

const x86_64_i8x16_swizzle = @import("x86_64/ops/wasm_2_0/i8x16_swizzle.zig");
const x86_64_i8x16_relaxed_swizzle = @import("x86_64/ops/wasm_3_0/i8x16_relaxed_swizzle.zig");
const x86_64_i32x4_dot_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_dot_i16x8_s.zig");
const x86_64_i16x8_q15mulr_sat_s = @import("x86_64/ops/wasm_2_0/i16x8_q15mulr_sat_s.zig");
const x86_64_f32x4_convert_i32x4_s = @import("x86_64/ops/wasm_2_0/f32x4_convert_i32x4_s.zig");
const x86_64_f32x4_convert_i32x4_u = @import("x86_64/ops/wasm_2_0/f32x4_convert_i32x4_u.zig");
const x86_64_f64x2_convert_low_i32x4_s = @import("x86_64/ops/wasm_2_0/f64x2_convert_low_i32x4_s.zig");
const x86_64_f64x2_promote_low_f32x4 = @import("x86_64/ops/wasm_2_0/f64x2_promote_low_f32x4.zig");
const x86_64_f32x4_demote_f64x2_zero = @import("x86_64/ops/wasm_2_0/f32x4_demote_f64x2_zero.zig");
const x86_64_i32x4_trunc_sat_f32x4_s = @import("x86_64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_s.zig");
const x86_64_i32x4_trunc_sat_f32x4_u = @import("x86_64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_u.zig");

const x86_64_i16x8_extmul_low_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extmul_low_i8x16_s.zig");
const x86_64_i16x8_extmul_high_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extmul_high_i8x16_s.zig");
const x86_64_i16x8_extmul_low_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extmul_low_i8x16_u.zig");
const x86_64_i16x8_extmul_high_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extmul_high_i8x16_u.zig");
const x86_64_i32x4_extmul_low_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extmul_low_i16x8_s.zig");
const x86_64_i32x4_extmul_high_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extmul_high_i16x8_s.zig");
const x86_64_i32x4_extmul_low_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extmul_low_i16x8_u.zig");
const x86_64_i32x4_extmul_high_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extmul_high_i16x8_u.zig");
const x86_64_i64x2_extmul_low_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extmul_low_i32x4_s.zig");
const x86_64_i64x2_extmul_high_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extmul_high_i32x4_s.zig");
const x86_64_i64x2_extmul_low_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extmul_low_i32x4_u.zig");
const x86_64_i64x2_extmul_high_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extmul_high_i32x4_u.zig");
const x86_64_i16x8_extadd_pairwise_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extadd_pairwise_i8x16_s.zig");
const x86_64_i16x8_extadd_pairwise_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extadd_pairwise_i8x16_u.zig");
const x86_64_i32x4_extadd_pairwise_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extadd_pairwise_i16x8_s.zig");
const x86_64_i32x4_extadd_pairwise_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extadd_pairwise_i16x8_u.zig");

const x86_64_i8x16_narrow_i16x8_s = @import("x86_64/ops/wasm_2_0/i8x16_narrow_i16x8_s.zig");
const x86_64_i8x16_narrow_i16x8_u = @import("x86_64/ops/wasm_2_0/i8x16_narrow_i16x8_u.zig");
const x86_64_i16x8_narrow_i32x4_s = @import("x86_64/ops/wasm_2_0/i16x8_narrow_i32x4_s.zig");
const x86_64_i16x8_narrow_i32x4_u = @import("x86_64/ops/wasm_2_0/i16x8_narrow_i32x4_u.zig");
const x86_64_i16x8_extend_low_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extend_low_i8x16_s.zig");
const x86_64_i16x8_extend_high_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extend_high_i8x16_s.zig");
const x86_64_i16x8_extend_low_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extend_low_i8x16_u.zig");
const x86_64_i16x8_extend_high_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extend_high_i8x16_u.zig");
const x86_64_i32x4_extend_low_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extend_low_i16x8_s.zig");
const x86_64_i32x4_extend_high_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extend_high_i16x8_s.zig");
const x86_64_i32x4_extend_low_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extend_low_i16x8_u.zig");
const x86_64_i32x4_extend_high_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extend_high_i16x8_u.zig");
const x86_64_i64x2_extend_low_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extend_low_i32x4_s.zig");
const x86_64_i64x2_extend_high_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extend_high_i32x4_s.zig");
const x86_64_i64x2_extend_low_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extend_low_i32x4_u.zig");
const x86_64_i64x2_extend_high_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extend_high_i32x4_u.zig");

const x86_64_v128_any_true = @import("x86_64/ops/wasm_2_0/v128_any_true.zig");
const x86_64_i8x16_all_true = @import("x86_64/ops/wasm_2_0/i8x16_all_true.zig");
const x86_64_i16x8_all_true = @import("x86_64/ops/wasm_2_0/i16x8_all_true.zig");
const x86_64_i32x4_all_true = @import("x86_64/ops/wasm_2_0/i32x4_all_true.zig");
const x86_64_i64x2_all_true = @import("x86_64/ops/wasm_2_0/i64x2_all_true.zig");
const x86_64_i8x16_bitmask = @import("x86_64/ops/wasm_2_0/i8x16_bitmask.zig");
const x86_64_i16x8_bitmask = @import("x86_64/ops/wasm_2_0/i16x8_bitmask.zig");
const x86_64_i32x4_bitmask = @import("x86_64/ops/wasm_2_0/i32x4_bitmask.zig");
const x86_64_i64x2_bitmask = @import("x86_64/ops/wasm_2_0/i64x2_bitmask.zig");

const x86_64_f32x4_eq = @import("x86_64/ops/wasm_2_0/f32x4_eq.zig");
const x86_64_f32x4_ne = @import("x86_64/ops/wasm_2_0/f32x4_ne.zig");
const x86_64_f32x4_lt = @import("x86_64/ops/wasm_2_0/f32x4_lt.zig");
const x86_64_f32x4_gt = @import("x86_64/ops/wasm_2_0/f32x4_gt.zig");
const x86_64_f32x4_le = @import("x86_64/ops/wasm_2_0/f32x4_le.zig");
const x86_64_f32x4_ge = @import("x86_64/ops/wasm_2_0/f32x4_ge.zig");
const x86_64_f64x2_eq = @import("x86_64/ops/wasm_2_0/f64x2_eq.zig");
const x86_64_f64x2_ne = @import("x86_64/ops/wasm_2_0/f64x2_ne.zig");
const x86_64_f64x2_lt = @import("x86_64/ops/wasm_2_0/f64x2_lt.zig");
const x86_64_f64x2_gt = @import("x86_64/ops/wasm_2_0/f64x2_gt.zig");
const x86_64_f64x2_le = @import("x86_64/ops/wasm_2_0/f64x2_le.zig");
const x86_64_f64x2_ge = @import("x86_64/ops/wasm_2_0/f64x2_ge.zig");

const x86_64_f32x4_abs = @import("x86_64/ops/wasm_2_0/f32x4_abs.zig");
const x86_64_f32x4_neg = @import("x86_64/ops/wasm_2_0/f32x4_neg.zig");
const x86_64_f32x4_sqrt = @import("x86_64/ops/wasm_2_0/f32x4_sqrt.zig");
const x86_64_f32x4_ceil = @import("x86_64/ops/wasm_2_0/f32x4_ceil.zig");
const x86_64_f32x4_floor = @import("x86_64/ops/wasm_2_0/f32x4_floor.zig");
const x86_64_f32x4_trunc = @import("x86_64/ops/wasm_2_0/f32x4_trunc.zig");
const x86_64_f32x4_nearest = @import("x86_64/ops/wasm_2_0/f32x4_nearest.zig");
const x86_64_f64x2_abs = @import("x86_64/ops/wasm_2_0/f64x2_abs.zig");
const x86_64_f64x2_neg = @import("x86_64/ops/wasm_2_0/f64x2_neg.zig");
const x86_64_f64x2_sqrt = @import("x86_64/ops/wasm_2_0/f64x2_sqrt.zig");
const x86_64_f64x2_ceil = @import("x86_64/ops/wasm_2_0/f64x2_ceil.zig");
const x86_64_f64x2_floor = @import("x86_64/ops/wasm_2_0/f64x2_floor.zig");
const x86_64_f64x2_trunc = @import("x86_64/ops/wasm_2_0/f64x2_trunc.zig");
const x86_64_f64x2_nearest = @import("x86_64/ops/wasm_2_0/f64x2_nearest.zig");

const x86_64_f32x4_add = @import("x86_64/ops/wasm_2_0/f32x4_add.zig");
const x86_64_f32x4_sub = @import("x86_64/ops/wasm_2_0/f32x4_sub.zig");
const x86_64_f32x4_mul = @import("x86_64/ops/wasm_2_0/f32x4_mul.zig");
const x86_64_f32x4_div = @import("x86_64/ops/wasm_2_0/f32x4_div.zig");
const x86_64_f32x4_min = @import("x86_64/ops/wasm_2_0/f32x4_min.zig");
const x86_64_f32x4_max = @import("x86_64/ops/wasm_2_0/f32x4_max.zig");
const x86_64_f32x4_pmin = @import("x86_64/ops/wasm_2_0/f32x4_pmin.zig");
const x86_64_f32x4_pmax = @import("x86_64/ops/wasm_2_0/f32x4_pmax.zig");
const x86_64_f64x2_add = @import("x86_64/ops/wasm_2_0/f64x2_add.zig");
const x86_64_f64x2_sub = @import("x86_64/ops/wasm_2_0/f64x2_sub.zig");
const x86_64_f64x2_mul = @import("x86_64/ops/wasm_2_0/f64x2_mul.zig");
const x86_64_f64x2_div = @import("x86_64/ops/wasm_2_0/f64x2_div.zig");
const x86_64_f64x2_min = @import("x86_64/ops/wasm_2_0/f64x2_min.zig");
const x86_64_f64x2_max = @import("x86_64/ops/wasm_2_0/f64x2_max.zig");
const x86_64_f64x2_pmin = @import("x86_64/ops/wasm_2_0/f64x2_pmin.zig");
const x86_64_f64x2_pmax = @import("x86_64/ops/wasm_2_0/f64x2_pmax.zig");

const x86_64_i8x16_add_sat_s = @import("x86_64/ops/wasm_2_0/i8x16_add_sat_s.zig");
const x86_64_i8x16_add_sat_u = @import("x86_64/ops/wasm_2_0/i8x16_add_sat_u.zig");
const x86_64_i8x16_sub_sat_s = @import("x86_64/ops/wasm_2_0/i8x16_sub_sat_s.zig");
const x86_64_i8x16_sub_sat_u = @import("x86_64/ops/wasm_2_0/i8x16_sub_sat_u.zig");
const x86_64_i8x16_avgr_u = @import("x86_64/ops/wasm_2_0/i8x16_avgr_u.zig");
const x86_64_i16x8_add_sat_s = @import("x86_64/ops/wasm_2_0/i16x8_add_sat_s.zig");
const x86_64_i16x8_add_sat_u = @import("x86_64/ops/wasm_2_0/i16x8_add_sat_u.zig");
const x86_64_i16x8_sub_sat_s = @import("x86_64/ops/wasm_2_0/i16x8_sub_sat_s.zig");
const x86_64_i16x8_sub_sat_u = @import("x86_64/ops/wasm_2_0/i16x8_sub_sat_u.zig");
const x86_64_i16x8_avgr_u = @import("x86_64/ops/wasm_2_0/i16x8_avgr_u.zig");

const x86_64_i8x16_min_s = @import("x86_64/ops/wasm_2_0/i8x16_min_s.zig");
const x86_64_i8x16_min_u = @import("x86_64/ops/wasm_2_0/i8x16_min_u.zig");
const x86_64_i8x16_max_s = @import("x86_64/ops/wasm_2_0/i8x16_max_s.zig");
const x86_64_i8x16_max_u = @import("x86_64/ops/wasm_2_0/i8x16_max_u.zig");
const x86_64_i16x8_min_s = @import("x86_64/ops/wasm_2_0/i16x8_min_s.zig");
const x86_64_i16x8_min_u = @import("x86_64/ops/wasm_2_0/i16x8_min_u.zig");
const x86_64_i16x8_max_s = @import("x86_64/ops/wasm_2_0/i16x8_max_s.zig");
const x86_64_i16x8_max_u = @import("x86_64/ops/wasm_2_0/i16x8_max_u.zig");
const x86_64_i32x4_min_s = @import("x86_64/ops/wasm_2_0/i32x4_min_s.zig");
const x86_64_i32x4_min_u = @import("x86_64/ops/wasm_2_0/i32x4_min_u.zig");
const x86_64_i32x4_max_s = @import("x86_64/ops/wasm_2_0/i32x4_max_s.zig");
const x86_64_i32x4_max_u = @import("x86_64/ops/wasm_2_0/i32x4_max_u.zig");

const x86_64_i8x16_shl = @import("x86_64/ops/wasm_2_0/i8x16_shl.zig");
const x86_64_i8x16_shr_s = @import("x86_64/ops/wasm_2_0/i8x16_shr_s.zig");
const x86_64_i8x16_shr_u = @import("x86_64/ops/wasm_2_0/i8x16_shr_u.zig");
const x86_64_i16x8_shl = @import("x86_64/ops/wasm_2_0/i16x8_shl.zig");
const x86_64_i16x8_shr_s = @import("x86_64/ops/wasm_2_0/i16x8_shr_s.zig");
const x86_64_i16x8_shr_u = @import("x86_64/ops/wasm_2_0/i16x8_shr_u.zig");
const x86_64_i32x4_shl = @import("x86_64/ops/wasm_2_0/i32x4_shl.zig");
const x86_64_i32x4_shr_s = @import("x86_64/ops/wasm_2_0/i32x4_shr_s.zig");
const x86_64_i32x4_shr_u = @import("x86_64/ops/wasm_2_0/i32x4_shr_u.zig");
const x86_64_i64x2_shl = @import("x86_64/ops/wasm_2_0/i64x2_shl.zig");
const x86_64_i64x2_shr_s = @import("x86_64/ops/wasm_2_0/i64x2_shr_s.zig");
const x86_64_i64x2_shr_u = @import("x86_64/ops/wasm_2_0/i64x2_shr_u.zig");

const x86_64_i8x16_neg = @import("x86_64/ops/wasm_2_0/i8x16_neg.zig");
const x86_64_i8x16_abs = @import("x86_64/ops/wasm_2_0/i8x16_abs.zig");
const x86_64_i16x8_neg = @import("x86_64/ops/wasm_2_0/i16x8_neg.zig");
const x86_64_i16x8_abs = @import("x86_64/ops/wasm_2_0/i16x8_abs.zig");
const x86_64_i32x4_neg = @import("x86_64/ops/wasm_2_0/i32x4_neg.zig");
const x86_64_i32x4_abs = @import("x86_64/ops/wasm_2_0/i32x4_abs.zig");
const x86_64_i64x2_neg = @import("x86_64/ops/wasm_2_0/i64x2_neg.zig");
const x86_64_i64x2_abs = @import("x86_64/ops/wasm_2_0/i64x2_abs.zig");

const x86_64_v128_not = @import("x86_64/ops/wasm_2_0/v128_not.zig");
const x86_64_v128_and = @import("x86_64/ops/wasm_2_0/v128_and.zig");
const x86_64_v128_or = @import("x86_64/ops/wasm_2_0/v128_or.zig");
const x86_64_v128_xor = @import("x86_64/ops/wasm_2_0/v128_xor.zig");
const x86_64_v128_andnot = @import("x86_64/ops/wasm_2_0/v128_andnot.zig");
const x86_64_v128_bitselect = @import("x86_64/ops/wasm_2_0/v128_bitselect.zig");

const x86_64_i8x16_add = @import("x86_64/ops/wasm_2_0/i8x16_add.zig");
const x86_64_i8x16_sub = @import("x86_64/ops/wasm_2_0/i8x16_sub.zig");
const x86_64_i16x8_add = @import("x86_64/ops/wasm_2_0/i16x8_add.zig");
const x86_64_i16x8_sub = @import("x86_64/ops/wasm_2_0/i16x8_sub.zig");
const x86_64_i16x8_mul = @import("x86_64/ops/wasm_2_0/i16x8_mul.zig");
const x86_64_i32x4_add = @import("x86_64/ops/wasm_2_0/i32x4_add.zig");
const x86_64_i32x4_sub = @import("x86_64/ops/wasm_2_0/i32x4_sub.zig");
const x86_64_i32x4_mul = @import("x86_64/ops/wasm_2_0/i32x4_mul.zig");
const x86_64_i64x2_add = @import("x86_64/ops/wasm_2_0/i64x2_add.zig");
const x86_64_i64x2_sub = @import("x86_64/ops/wasm_2_0/i64x2_sub.zig");

const x86_64_i32_trunc_sat_f32_s = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f32_s.zig");
const x86_64_i32_trunc_sat_f32_u = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f32_u.zig");
const x86_64_i32_trunc_sat_f64_s = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f64_s.zig");
const x86_64_i32_trunc_sat_f64_u = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f64_u.zig");
const x86_64_i64_trunc_sat_f32_s = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f32_s.zig");
const x86_64_i64_trunc_sat_f32_u = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f32_u.zig");
const x86_64_i64_trunc_sat_f64_s = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f64_s.zig");
const x86_64_i64_trunc_sat_f64_u = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f64_u.zig");

const arm64_i32_div_s = @import("arm64/ops/wasm_1_0/i32_div_s.zig");
const arm64_i32_div_u = @import("arm64/ops/wasm_1_0/i32_div_u.zig");
const arm64_i32_rem_s = @import("arm64/ops/wasm_1_0/i32_rem_s.zig");
const arm64_i32_rem_u = @import("arm64/ops/wasm_1_0/i32_rem_u.zig");
const arm64_i64_div_s = @import("arm64/ops/wasm_1_0/i64_div_s.zig");
const arm64_i64_div_u = @import("arm64/ops/wasm_1_0/i64_div_u.zig");
const arm64_i64_rem_s = @import("arm64/ops/wasm_1_0/i64_rem_s.zig");
const arm64_i64_rem_u = @import("arm64/ops/wasm_1_0/i64_rem_u.zig");
const arm64_i32_wrap_i64 = @import("arm64/ops/wasm_1_0/i32_wrap_i64.zig");
const arm64_i64_extend_i32_s = @import("arm64/ops/wasm_1_0/i64_extend_i32_s.zig");
const arm64_i64_extend_i32_u = @import("arm64/ops/wasm_1_0/i64_extend_i32_u.zig");

const arm64_f32_add = @import("arm64/ops/wasm_1_0/f32_add.zig");
const arm64_f32_sub = @import("arm64/ops/wasm_1_0/f32_sub.zig");
const arm64_f32_mul = @import("arm64/ops/wasm_1_0/f32_mul.zig");
const arm64_f32_div = @import("arm64/ops/wasm_1_0/f32_div.zig");
const arm64_f64_add = @import("arm64/ops/wasm_1_0/f64_add.zig");
const arm64_f64_sub = @import("arm64/ops/wasm_1_0/f64_sub.zig");
const arm64_f64_mul = @import("arm64/ops/wasm_1_0/f64_mul.zig");
const arm64_f64_div = @import("arm64/ops/wasm_1_0/f64_div.zig");
const arm64_f32_eq = @import("arm64/ops/wasm_1_0/f32_eq.zig");
const arm64_f32_ne = @import("arm64/ops/wasm_1_0/f32_ne.zig");
const arm64_f32_lt = @import("arm64/ops/wasm_1_0/f32_lt.zig");
const arm64_f32_gt = @import("arm64/ops/wasm_1_0/f32_gt.zig");
const arm64_f32_le = @import("arm64/ops/wasm_1_0/f32_le.zig");
const arm64_f32_ge = @import("arm64/ops/wasm_1_0/f32_ge.zig");
const arm64_f64_eq = @import("arm64/ops/wasm_1_0/f64_eq.zig");
const arm64_f64_ne = @import("arm64/ops/wasm_1_0/f64_ne.zig");
const arm64_f64_lt = @import("arm64/ops/wasm_1_0/f64_lt.zig");
const arm64_f64_gt = @import("arm64/ops/wasm_1_0/f64_gt.zig");
const arm64_f64_le = @import("arm64/ops/wasm_1_0/f64_le.zig");
const arm64_f64_ge = @import("arm64/ops/wasm_1_0/f64_ge.zig");
const arm64_f32_abs = @import("arm64/ops/wasm_1_0/f32_abs.zig");
const arm64_f32_neg = @import("arm64/ops/wasm_1_0/f32_neg.zig");
const arm64_f32_sqrt = @import("arm64/ops/wasm_1_0/f32_sqrt.zig");
const arm64_f32_ceil = @import("arm64/ops/wasm_1_0/f32_ceil.zig");
const arm64_f32_floor = @import("arm64/ops/wasm_1_0/f32_floor.zig");
const arm64_f32_trunc = @import("arm64/ops/wasm_1_0/f32_trunc.zig");
const arm64_f32_nearest = @import("arm64/ops/wasm_1_0/f32_nearest.zig");
const arm64_f64_abs = @import("arm64/ops/wasm_1_0/f64_abs.zig");
const arm64_f64_neg = @import("arm64/ops/wasm_1_0/f64_neg.zig");
const arm64_f64_sqrt = @import("arm64/ops/wasm_1_0/f64_sqrt.zig");
const arm64_f64_ceil = @import("arm64/ops/wasm_1_0/f64_ceil.zig");
const arm64_f64_floor = @import("arm64/ops/wasm_1_0/f64_floor.zig");
const arm64_f64_trunc = @import("arm64/ops/wasm_1_0/f64_trunc.zig");
const arm64_f64_nearest = @import("arm64/ops/wasm_1_0/f64_nearest.zig");
const arm64_f32_min = @import("arm64/ops/wasm_1_0/f32_min.zig");
const arm64_f32_max = @import("arm64/ops/wasm_1_0/f32_max.zig");
const arm64_f64_min = @import("arm64/ops/wasm_1_0/f64_min.zig");
const arm64_f64_max = @import("arm64/ops/wasm_1_0/f64_max.zig");
const arm64_f32_copysign = @import("arm64/ops/wasm_1_0/f32_copysign.zig");
const arm64_f64_copysign = @import("arm64/ops/wasm_1_0/f64_copysign.zig");
const arm64_f32_convert_i32_s = @import("arm64/ops/wasm_1_0/f32_convert_i32_s.zig");
const arm64_f32_convert_i32_u = @import("arm64/ops/wasm_1_0/f32_convert_i32_u.zig");
const arm64_f32_convert_i64_s = @import("arm64/ops/wasm_1_0/f32_convert_i64_s.zig");
const arm64_f32_convert_i64_u = @import("arm64/ops/wasm_1_0/f32_convert_i64_u.zig");
const arm64_f64_convert_i32_s = @import("arm64/ops/wasm_1_0/f64_convert_i32_s.zig");
const arm64_f64_convert_i32_u = @import("arm64/ops/wasm_1_0/f64_convert_i32_u.zig");
const arm64_f64_convert_i64_s = @import("arm64/ops/wasm_1_0/f64_convert_i64_s.zig");
const arm64_f64_convert_i64_u = @import("arm64/ops/wasm_1_0/f64_convert_i64_u.zig");
const arm64_i32_reinterpret_f32 = @import("arm64/ops/wasm_1_0/i32_reinterpret_f32.zig");
const arm64_i64_reinterpret_f64 = @import("arm64/ops/wasm_1_0/i64_reinterpret_f64.zig");
const arm64_f32_reinterpret_i32 = @import("arm64/ops/wasm_1_0/f32_reinterpret_i32.zig");
const arm64_f64_reinterpret_i64 = @import("arm64/ops/wasm_1_0/f64_reinterpret_i64.zig");
const arm64_f32_demote_f64 = @import("arm64/ops/wasm_1_0/f32_demote_f64.zig");
const arm64_f64_promote_f32 = @import("arm64/ops/wasm_1_0/f64_promote_f32.zig");

const x86_64_i32_reinterpret_f32 = @import("x86_64/ops/wasm_1_0/i32_reinterpret_f32.zig");
const x86_64_i64_reinterpret_f64 = @import("x86_64/ops/wasm_1_0/i64_reinterpret_f64.zig");
const x86_64_f32_reinterpret_i32 = @import("x86_64/ops/wasm_1_0/f32_reinterpret_i32.zig");
const x86_64_f64_reinterpret_i64 = @import("x86_64/ops/wasm_1_0/f64_reinterpret_i64.zig");
const x86_64_f32_demote_f64 = @import("x86_64/ops/wasm_1_0/f32_demote_f64.zig");
const x86_64_f64_promote_f32 = @import("x86_64/ops/wasm_1_0/f64_promote_f32.zig");

const x86_64_f32_add = @import("x86_64/ops/wasm_1_0/f32_add.zig");
const x86_64_f32_sub = @import("x86_64/ops/wasm_1_0/f32_sub.zig");
const x86_64_f32_mul = @import("x86_64/ops/wasm_1_0/f32_mul.zig");
const x86_64_f32_div = @import("x86_64/ops/wasm_1_0/f32_div.zig");
const x86_64_f64_add = @import("x86_64/ops/wasm_1_0/f64_add.zig");
const x86_64_f64_sub = @import("x86_64/ops/wasm_1_0/f64_sub.zig");
const x86_64_f64_mul = @import("x86_64/ops/wasm_1_0/f64_mul.zig");
const x86_64_f64_div = @import("x86_64/ops/wasm_1_0/f64_div.zig");
const x86_64_f32_eq = @import("x86_64/ops/wasm_1_0/f32_eq.zig");
const x86_64_f32_ne = @import("x86_64/ops/wasm_1_0/f32_ne.zig");
const x86_64_f32_lt = @import("x86_64/ops/wasm_1_0/f32_lt.zig");
const x86_64_f32_gt = @import("x86_64/ops/wasm_1_0/f32_gt.zig");
const x86_64_f32_le = @import("x86_64/ops/wasm_1_0/f32_le.zig");
const x86_64_f32_ge = @import("x86_64/ops/wasm_1_0/f32_ge.zig");
const x86_64_f64_eq = @import("x86_64/ops/wasm_1_0/f64_eq.zig");
const x86_64_f64_ne = @import("x86_64/ops/wasm_1_0/f64_ne.zig");
const x86_64_f64_lt = @import("x86_64/ops/wasm_1_0/f64_lt.zig");
const x86_64_f64_gt = @import("x86_64/ops/wasm_1_0/f64_gt.zig");
const x86_64_f64_le = @import("x86_64/ops/wasm_1_0/f64_le.zig");
const x86_64_f64_ge = @import("x86_64/ops/wasm_1_0/f64_ge.zig");
const x86_64_f32_abs = @import("x86_64/ops/wasm_1_0/f32_abs.zig");
const x86_64_f32_neg = @import("x86_64/ops/wasm_1_0/f32_neg.zig");
const x86_64_f32_sqrt = @import("x86_64/ops/wasm_1_0/f32_sqrt.zig");
const x86_64_f32_ceil = @import("x86_64/ops/wasm_1_0/f32_ceil.zig");
const x86_64_f32_floor = @import("x86_64/ops/wasm_1_0/f32_floor.zig");
const x86_64_f32_trunc = @import("x86_64/ops/wasm_1_0/f32_trunc.zig");
const x86_64_f32_nearest = @import("x86_64/ops/wasm_1_0/f32_nearest.zig");
const x86_64_f64_abs = @import("x86_64/ops/wasm_1_0/f64_abs.zig");
const x86_64_f64_neg = @import("x86_64/ops/wasm_1_0/f64_neg.zig");
const x86_64_f64_sqrt = @import("x86_64/ops/wasm_1_0/f64_sqrt.zig");
const x86_64_f64_ceil = @import("x86_64/ops/wasm_1_0/f64_ceil.zig");
const x86_64_f64_floor = @import("x86_64/ops/wasm_1_0/f64_floor.zig");
const x86_64_f64_trunc = @import("x86_64/ops/wasm_1_0/f64_trunc.zig");
const x86_64_f64_nearest = @import("x86_64/ops/wasm_1_0/f64_nearest.zig");
const x86_64_f32_min = @import("x86_64/ops/wasm_1_0/f32_min.zig");
const x86_64_f32_max = @import("x86_64/ops/wasm_1_0/f32_max.zig");
const x86_64_f64_min = @import("x86_64/ops/wasm_1_0/f64_min.zig");
const x86_64_f64_max = @import("x86_64/ops/wasm_1_0/f64_max.zig");
const x86_64_f32_copysign = @import("x86_64/ops/wasm_1_0/f32_copysign.zig");
const x86_64_f64_copysign = @import("x86_64/ops/wasm_1_0/f64_copysign.zig");
const x86_64_f32_convert_i32_s = @import("x86_64/ops/wasm_1_0/f32_convert_i32_s.zig");
const x86_64_f32_convert_i32_u = @import("x86_64/ops/wasm_1_0/f32_convert_i32_u.zig");
const x86_64_f32_convert_i64_s = @import("x86_64/ops/wasm_1_0/f32_convert_i64_s.zig");
const x86_64_f32_convert_i64_u = @import("x86_64/ops/wasm_1_0/f32_convert_i64_u.zig");
const x86_64_f64_convert_i32_s = @import("x86_64/ops/wasm_1_0/f64_convert_i32_s.zig");
const x86_64_f64_convert_i32_u = @import("x86_64/ops/wasm_1_0/f64_convert_i32_u.zig");
const x86_64_f64_convert_i64_s = @import("x86_64/ops/wasm_1_0/f64_convert_i64_s.zig");
const x86_64_f64_convert_i64_u = @import("x86_64/ops/wasm_1_0/f64_convert_i64_u.zig");

const x86_64_i32_wrap_i64 = @import("x86_64/ops/wasm_1_0/i32_wrap_i64.zig");
const x86_64_i64_extend_i32_s = @import("x86_64/ops/wasm_1_0/i64_extend_i32_s.zig");
const x86_64_i64_extend_i32_u = @import("x86_64/ops/wasm_1_0/i64_extend_i32_u.zig");

// x86_64 per-op files using the `(ctx, ins)` shape (ADR-0075),
// tracked in `collected_x86_64_ctx_ops` (see below).
const x86_64_i32_div_s = @import("x86_64/ops/wasm_1_0/i32_div_s.zig");
const x86_64_i32_div_u = @import("x86_64/ops/wasm_1_0/i32_div_u.zig");
const x86_64_i32_rem_s = @import("x86_64/ops/wasm_1_0/i32_rem_s.zig");
const x86_64_i32_rem_u = @import("x86_64/ops/wasm_1_0/i32_rem_u.zig");
const x86_64_i64_div_s = @import("x86_64/ops/wasm_1_0/i64_div_s.zig");
const x86_64_i64_div_u = @import("x86_64/ops/wasm_1_0/i64_div_u.zig");
const x86_64_i64_rem_s = @import("x86_64/ops/wasm_1_0/i64_rem_s.zig");
const x86_64_i64_rem_u = @import("x86_64/ops/wasm_1_0/i64_rem_u.zig");
const x86_64_i32_trunc_f32_s = @import("x86_64/ops/wasm_1_0/i32_trunc_f32_s.zig");
const x86_64_i32_trunc_f64_s = @import("x86_64/ops/wasm_1_0/i32_trunc_f64_s.zig");
const x86_64_i64_trunc_f32_s = @import("x86_64/ops/wasm_1_0/i64_trunc_f32_s.zig");
const x86_64_i64_trunc_f64_s = @import("x86_64/ops/wasm_1_0/i64_trunc_f64_s.zig");
const x86_64_i32_trunc_f32_u = @import("x86_64/ops/wasm_1_0/i32_trunc_f32_u.zig");
const x86_64_i32_trunc_f64_u = @import("x86_64/ops/wasm_1_0/i32_trunc_f64_u.zig");
const x86_64_i64_trunc_f32_u = @import("x86_64/ops/wasm_1_0/i64_trunc_f32_u.zig");
const x86_64_i64_trunc_f64_u = @import("x86_64/ops/wasm_1_0/i64_trunc_f64_u.zig");
const x86_64_i32_load = @import("x86_64/ops/wasm_1_0/i32_load.zig");
const x86_64_i32_load8_s = @import("x86_64/ops/wasm_1_0/i32_load8_s.zig");
const x86_64_i32_load8_u = @import("x86_64/ops/wasm_1_0/i32_load8_u.zig");
const x86_64_i32_load16_s = @import("x86_64/ops/wasm_1_0/i32_load16_s.zig");
const x86_64_i32_load16_u = @import("x86_64/ops/wasm_1_0/i32_load16_u.zig");
const x86_64_i32_store = @import("x86_64/ops/wasm_1_0/i32_store.zig");
const x86_64_i32_store8 = @import("x86_64/ops/wasm_1_0/i32_store8.zig");
const x86_64_i32_store16 = @import("x86_64/ops/wasm_1_0/i32_store16.zig");
const x86_64_i64_load = @import("x86_64/ops/wasm_1_0/i64_load.zig");
const x86_64_i64_load8_s = @import("x86_64/ops/wasm_1_0/i64_load8_s.zig");
const x86_64_i64_load8_u = @import("x86_64/ops/wasm_1_0/i64_load8_u.zig");
const x86_64_i64_load16_s = @import("x86_64/ops/wasm_1_0/i64_load16_s.zig");
const x86_64_i64_load16_u = @import("x86_64/ops/wasm_1_0/i64_load16_u.zig");
const x86_64_i64_load32_s = @import("x86_64/ops/wasm_1_0/i64_load32_s.zig");
const x86_64_i64_load32_u = @import("x86_64/ops/wasm_1_0/i64_load32_u.zig");
const x86_64_i64_store = @import("x86_64/ops/wasm_1_0/i64_store.zig");
const x86_64_i64_store8 = @import("x86_64/ops/wasm_1_0/i64_store8.zig");
const x86_64_i64_store16 = @import("x86_64/ops/wasm_1_0/i64_store16.zig");
const x86_64_i64_store32 = @import("x86_64/ops/wasm_1_0/i64_store32.zig");
const x86_64_f32_load = @import("x86_64/ops/wasm_1_0/f32_load.zig");
const x86_64_f64_load = @import("x86_64/ops/wasm_1_0/f64_load.zig");
const x86_64_f32_store = @import("x86_64/ops/wasm_1_0/f32_store.zig");
const x86_64_f64_store = @import("x86_64/ops/wasm_1_0/f64_store.zig");
const x86_64_memory_fill = @import("x86_64/ops/wasm_1_0/memory_fill.zig");
const x86_64_memory_copy = @import("x86_64/ops/wasm_1_0/memory_copy.zig");
const x86_64_memory_init = @import("x86_64/ops/wasm_1_0/memory_init.zig");
const x86_64_global_get = @import("x86_64/ops/wasm_1_0/global_get.zig");
const x86_64_global_set = @import("x86_64/ops/wasm_1_0/global_set.zig");
const x86_64_table_get = @import("x86_64/ops/wasm_1_0/table_get.zig");
const x86_64_table_set = @import("x86_64/ops/wasm_1_0/table_set.zig");
const x86_64_table_size = @import("x86_64/ops/wasm_1_0/table_size.zig");
const x86_64_table_grow = @import("x86_64/ops/wasm_1_0/table_grow.zig");
const x86_64_table_fill = @import("x86_64/ops/wasm_1_0/table_fill.zig");
const x86_64_table_copy = @import("x86_64/ops/wasm_1_0/table_copy.zig");
const x86_64_table_init = @import("x86_64/ops/wasm_1_0/table_init.zig");
const x86_64_call = @import("x86_64/ops/wasm_1_0/call.zig");
const x86_64_call_indirect = @import("x86_64/ops/wasm_1_0/call_indirect.zig");
const x86_64_block = @import("x86_64/ops/wasm_1_0/block.zig");
const x86_64_loop = @import("x86_64/ops/wasm_1_0/loop.zig");
const x86_64_i32_const = @import("x86_64/ops/wasm_1_0/i32_const.zig");
const x86_64_i64_const = @import("x86_64/ops/wasm_1_0/i64_const.zig");
const x86_64_f32_const = @import("x86_64/ops/wasm_1_0/f32_const.zig");
const x86_64_f64_const = @import("x86_64/ops/wasm_1_0/f64_const.zig");
const x86_64_ref_null = @import("x86_64/ops/wasm_1_0/ref_null.zig");
const x86_64_ref_func = @import("x86_64/ops/wasm_1_0/ref_func.zig");
const x86_64_drop = @import("x86_64/ops/wasm_1_0/drop.zig");
const x86_64_select = @import("x86_64/ops/wasm_1_0/select.zig");
const x86_64_memory_size = @import("x86_64/ops/wasm_1_0/memory_size.zig");
const x86_64_memory_grow = @import("x86_64/ops/wasm_1_0/memory_grow.zig");
const x86_64_nop = @import("x86_64/ops/wasm_1_0/nop.zig");
const x86_64_unreachable = @import("x86_64/ops/wasm_1_0/unreachable_.zig");
const x86_64_return = @import("x86_64/ops/wasm_1_0/return_.zig");
const x86_64_br = @import("x86_64/ops/wasm_1_0/br.zig");
const x86_64_br_if = @import("x86_64/ops/wasm_1_0/br_if.zig");
const x86_64_br_table = @import("x86_64/ops/wasm_1_0/br_table.zig");
const x86_64_if = @import("x86_64/ops/wasm_1_0/if_.zig");
const x86_64_else = @import("x86_64/ops/wasm_1_0/else_.zig");
const x86_64_end = @import("x86_64/ops/wasm_1_0/end_.zig");
const x86_64_local_get = @import("x86_64/ops/wasm_1_0/local_get.zig");
const x86_64_local_set = @import("x86_64/ops/wasm_1_0/local_set.zig");
const x86_64_local_tee = @import("x86_64/ops/wasm_1_0/local_tee.zig");

const x86_64_i32_add = @import("x86_64/ops/wasm_1_0/i32_add.zig");
const x86_64_i32_sub = @import("x86_64/ops/wasm_1_0/i32_sub.zig");
const x86_64_i32_mul = @import("x86_64/ops/wasm_1_0/i32_mul.zig");
const x86_64_i32_and = @import("x86_64/ops/wasm_1_0/i32_and.zig");
const x86_64_i32_or = @import("x86_64/ops/wasm_1_0/i32_or.zig");
const x86_64_i32_xor = @import("x86_64/ops/wasm_1_0/i32_xor.zig");
const x86_64_i64_add = @import("x86_64/ops/wasm_1_0/i64_add.zig");
const x86_64_i64_sub = @import("x86_64/ops/wasm_1_0/i64_sub.zig");
const x86_64_i64_mul = @import("x86_64/ops/wasm_1_0/i64_mul.zig");
const x86_64_i64_and = @import("x86_64/ops/wasm_1_0/i64_and.zig");
const x86_64_i64_or = @import("x86_64/ops/wasm_1_0/i64_or.zig");
const x86_64_i64_xor = @import("x86_64/ops/wasm_1_0/i64_xor.zig");
const x86_64_i32_eq = @import("x86_64/ops/wasm_1_0/i32_eq.zig");
const x86_64_i32_ne = @import("x86_64/ops/wasm_1_0/i32_ne.zig");
const x86_64_i32_lt_s = @import("x86_64/ops/wasm_1_0/i32_lt_s.zig");
const x86_64_i32_lt_u = @import("x86_64/ops/wasm_1_0/i32_lt_u.zig");
const x86_64_i32_gt_s = @import("x86_64/ops/wasm_1_0/i32_gt_s.zig");
const x86_64_i32_gt_u = @import("x86_64/ops/wasm_1_0/i32_gt_u.zig");
const x86_64_i32_le_s = @import("x86_64/ops/wasm_1_0/i32_le_s.zig");
const x86_64_i32_le_u = @import("x86_64/ops/wasm_1_0/i32_le_u.zig");
const x86_64_i32_ge_s = @import("x86_64/ops/wasm_1_0/i32_ge_s.zig");
const x86_64_i32_ge_u = @import("x86_64/ops/wasm_1_0/i32_ge_u.zig");
const x86_64_i64_eq = @import("x86_64/ops/wasm_1_0/i64_eq.zig");
const x86_64_i64_ne = @import("x86_64/ops/wasm_1_0/i64_ne.zig");
const x86_64_i64_lt_s = @import("x86_64/ops/wasm_1_0/i64_lt_s.zig");
const x86_64_i64_lt_u = @import("x86_64/ops/wasm_1_0/i64_lt_u.zig");
const x86_64_i64_gt_s = @import("x86_64/ops/wasm_1_0/i64_gt_s.zig");
const x86_64_i64_gt_u = @import("x86_64/ops/wasm_1_0/i64_gt_u.zig");
const x86_64_i64_le_s = @import("x86_64/ops/wasm_1_0/i64_le_s.zig");
const x86_64_i64_le_u = @import("x86_64/ops/wasm_1_0/i64_le_u.zig");
const x86_64_i64_ge_s = @import("x86_64/ops/wasm_1_0/i64_ge_s.zig");
const x86_64_i64_ge_u = @import("x86_64/ops/wasm_1_0/i64_ge_u.zig");
const x86_64_i32_eqz = @import("x86_64/ops/wasm_1_0/i32_eqz.zig");
const x86_64_i64_eqz = @import("x86_64/ops/wasm_1_0/i64_eqz.zig");
const x86_64_i32_shl = @import("x86_64/ops/wasm_1_0/i32_shl.zig");
const x86_64_i32_shr_s = @import("x86_64/ops/wasm_1_0/i32_shr_s.zig");
const x86_64_i32_shr_u = @import("x86_64/ops/wasm_1_0/i32_shr_u.zig");
const x86_64_i32_rotl = @import("x86_64/ops/wasm_1_0/i32_rotl.zig");
const x86_64_i32_rotr = @import("x86_64/ops/wasm_1_0/i32_rotr.zig");
const x86_64_i64_shl = @import("x86_64/ops/wasm_1_0/i64_shl.zig");
const x86_64_i64_shr_s = @import("x86_64/ops/wasm_1_0/i64_shr_s.zig");
const x86_64_i64_shr_u = @import("x86_64/ops/wasm_1_0/i64_shr_u.zig");
const x86_64_i64_rotl = @import("x86_64/ops/wasm_1_0/i64_rotl.zig");
const x86_64_i64_rotr = @import("x86_64/ops/wasm_1_0/i64_rotr.zig");
const x86_64_i32_clz = @import("x86_64/ops/wasm_1_0/i32_clz.zig");
const x86_64_i32_ctz = @import("x86_64/ops/wasm_1_0/i32_ctz.zig");
const x86_64_i32_popcnt = @import("x86_64/ops/wasm_1_0/i32_popcnt.zig");
const x86_64_i64_clz = @import("x86_64/ops/wasm_1_0/i64_clz.zig");
const x86_64_i64_ctz = @import("x86_64/ops/wasm_1_0/i64_ctz.zig");
const x86_64_i64_popcnt = @import("x86_64/ops/wasm_1_0/i64_popcnt.zig");
const x86_64_i32_extend8_s = @import("x86_64/ops/wasm_2_0/i32_extend8_s.zig");
const x86_64_i32_extend16_s = @import("x86_64/ops/wasm_2_0/i32_extend16_s.zig");
const x86_64_i64_extend8_s = @import("x86_64/ops/wasm_2_0/i64_extend8_s.zig");
const x86_64_i64_extend16_s = @import("x86_64/ops/wasm_2_0/i64_extend16_s.zig");
const x86_64_i64_extend32_s = @import("x86_64/ops/wasm_2_0/i64_extend32_s.zig");

// Wasm 3.0 EH (ADR-0114) — arm64 throw / throw_ref dispatch INLINE
// in arm64/emit.zig (NOT in collected_arm64_ops) because the
// per-op file cannot set the legacy `dead_code` local; x86_64
// per-op file has ctx.dead_code and routes here.
const arm64_try_table = @import("arm64/ops/wasm_3_0/try_table.zig");
const x86_64_try_table = @import("x86_64/ops/wasm_3_0/try_table.zig");
const x86_64_throw = @import("x86_64/ops/wasm_3_0/throw.zig");
const x86_64_throw_ref = @import("x86_64/ops/wasm_3_0/throw_ref.zig");
const x86_64_return_call = @import("x86_64/ops/wasm_3_0/return_call.zig");
const x86_64_return_call_indirect = @import("x86_64/ops/wasm_3_0/return_call_indirect.zig");
const x86_64_call_ref = @import("x86_64/ops/wasm_3_0/call_ref.zig");
const x86_64_return_call_ref = @import("x86_64/ops/wasm_3_0/return_call_ref.zig");

// function-references — ref.as_non_null JIT emit (ADR-0123 D2:
// representation-independent null-check, generic-trap).
const arm64_ref_as_non_null = @import("arm64/ops/wasm_3_0/ref_as_non_null.zig");
const x86_64_ref_as_non_null = @import("x86_64/ops/wasm_3_0/ref_as_non_null.zig");

// br_on_null JIT emit. x86_64 re-uses the existing
// captureOrEmitBlockMergeMov via the ctx-shape wrapper
// `captureOrEmitBlockMergeMovCtx` added to x86_64/op_control.zig
// (D-194 Path B; no full br_if migration required).
const arm64_br_on_null = @import("arm64/ops/wasm_3_0/br_on_null.zig");
const x86_64_br_on_null = @import("x86_64/ops/wasm_3_0/br_on_null.zig");

// br_on_non_null JIT emit (arm64); x86_64 shares the same
// captureOrEmitBlockMergeMovCtx wrapper (D-194 Path B).
const arm64_br_on_non_null = @import("arm64/ops/wasm_3_0/br_on_non_null.zig");
const x86_64_br_on_non_null = @import("x86_64/ops/wasm_3_0/br_on_non_null.zig");

// GC i31 op family (ref.i31 / i31.get_s / i31.get_u), both arches.
// Non-allocating shift+tag. x86_64 in ctx_ops (the `emit(ctx,ins)`
// tuple, alongside the other v3_0 ops).
const arm64_ref_i31 = @import("arm64/ops/wasm_3_0/ref_i31.zig");
const arm64_i31_get_s = @import("arm64/ops/wasm_3_0/i31_get_s.zig");
const arm64_i31_get_u = @import("arm64/ops/wasm_3_0/i31_get_u.zig");
// GC struct ops (arm64 first; x86_64 = D-211). struct.new_default
// allocates via the jitGcAlloc trampoline; struct.get loads a
// uniform 8-byte field slot off the gc_heap slab.
const arm64_struct_new_default = @import("arm64/ops/wasm_3_0/struct_new_default.zig");
const arm64_struct_get = @import("arm64/ops/wasm_3_0/struct_get.zig");
const arm64_struct_get_s = @import("arm64/ops/wasm_3_0/struct_get_s.zig");
const arm64_struct_get_u = @import("arm64/ops/wasm_3_0/struct_get_u.zig");
// struct.new (variadic) — allocs then stores field operands (force-spilled
// across the alloc BLR per ADR-0060 amend). x86_64 = follow-on.
const arm64_struct_new = @import("arm64/ops/wasm_3_0/struct_new.zig");
const arm64_struct_set = @import("arm64/ops/wasm_3_0/struct_set.zig");
// GC array.new_default (alloc) + array.len.
const arm64_array_new_default = @import("arm64/ops/wasm_3_0/array_new_default.zig");
const arm64_array_len = @import("arm64/ops/wasm_3_0/array_len.zig");
// array.get / array.set (register-offset element access + bounds-check).
const arm64_array_get = @import("arm64/ops/wasm_3_0/array_get.zig");
const arm64_array_set = @import("arm64/ops/wasm_3_0/array_set.zig");
// array.new (alloc + trampoline fill).
const arm64_array_new = @import("arm64/ops/wasm_3_0/array_new.zig");
// array.new_fixed (variadic alloc + inline element stores).
const arm64_array_new_fixed = @import("arm64/ops/wasm_3_0/array_new_fixed.zig");
// array.get_s (packed i8/i16 load + sign-extend).
const arm64_array_get_s = @import("arm64/ops/wasm_3_0/array_get_s.zig");
// array.get_u (packed i8/i16 load + zero-extend).
const arm64_array_get_u = @import("arm64/ops/wasm_3_0/array_get_u.zig");
// array.fill (trampoline; bounds-check + fill in Zig).
const arm64_array_fill = @import("arm64/ops/wasm_3_0/array_fill.zig");
// ref.eq (identity compare → i32; no trampoline).
const arm64_ref_eq = @import("arm64/ops/wasm_3_0/ref_eq.zig");
// array.copy (trampoline; null+bounds-check + overlap copy in Zig).
const arm64_array_copy = @import("arm64/ops/wasm_3_0/array_copy.zig");
// array.new_data (trampoline; alloc + copy from data segment).
const arm64_array_new_data = @import("arm64/ops/wasm_3_0/array_new_data.zig");
// array.new_elem (trampoline; alloc + direct ref copy from elem segment).
const arm64_array_new_elem = @import("arm64/ops/wasm_3_0/array_new_elem.zig");
// array.init_data (trampoline; in-place copy from data segment).
const arm64_array_init_data = @import("arm64/ops/wasm_3_0/array_init_data.zig");
// array.init_elem (trampoline; in-place direct ref copy from elem segment).
const arm64_array_init_elem = @import("arm64/ops/wasm_3_0/array_init_elem.zig");
// ref.test / ref.test_null (trampoline; subtype check → i32, no trap).
const arm64_ref_test = @import("arm64/ops/wasm_3_0/ref_test.zig");
const arm64_ref_test_null = @import("arm64/ops/wasm_3_0/ref_test_null.zig");
// ref.cast (trampoline; subtype check → ref or trap-on-0).
const arm64_ref_cast = @import("arm64/ops/wasm_3_0/ref_cast.zig");
// ref.cast_null (reuses jitGcRefTest+nullbit; null passes, mismatch traps).
const arm64_ref_cast_null = @import("arm64/ops/wasm_3_0/ref_cast_null.zig");
const x86_64_ref_i31 = @import("x86_64/ops/wasm_3_0/ref_i31.zig");
const x86_64_i31_get_s = @import("x86_64/ops/wasm_3_0/i31_get_s.zig");
const x86_64_i31_get_u = @import("x86_64/ops/wasm_3_0/i31_get_u.zig");
const x86_64_struct_new_default = @import("x86_64/ops/wasm_3_0/struct_new_default.zig");
const x86_64_struct_get = @import("x86_64/ops/wasm_3_0/struct_get.zig");
const x86_64_struct_get_s = @import("x86_64/ops/wasm_3_0/struct_get_s.zig");
const x86_64_struct_get_u = @import("x86_64/ops/wasm_3_0/struct_get_u.zig");
const x86_64_struct_new = @import("x86_64/ops/wasm_3_0/struct_new.zig");
const x86_64_struct_set = @import("x86_64/ops/wasm_3_0/struct_set.zig");
const x86_64_array_new_default = @import("x86_64/ops/wasm_3_0/array_new_default.zig");
const x86_64_array_len = @import("x86_64/ops/wasm_3_0/array_len.zig");
const x86_64_array_get = @import("x86_64/ops/wasm_3_0/array_get.zig");
const x86_64_array_set = @import("x86_64/ops/wasm_3_0/array_set.zig");
const x86_64_array_new = @import("x86_64/ops/wasm_3_0/array_new.zig");
const x86_64_array_new_fixed = @import("x86_64/ops/wasm_3_0/array_new_fixed.zig");
const x86_64_array_get_s = @import("x86_64/ops/wasm_3_0/array_get_s.zig");
const x86_64_array_get_u = @import("x86_64/ops/wasm_3_0/array_get_u.zig");
const x86_64_array_fill = @import("x86_64/ops/wasm_3_0/array_fill.zig");
const x86_64_ref_eq = @import("x86_64/ops/wasm_3_0/ref_eq.zig");
const x86_64_array_copy = @import("x86_64/ops/wasm_3_0/array_copy.zig");
const x86_64_array_new_data = @import("x86_64/ops/wasm_3_0/array_new_data.zig");
const x86_64_array_new_elem = @import("x86_64/ops/wasm_3_0/array_new_elem.zig");
const x86_64_array_init_data = @import("x86_64/ops/wasm_3_0/array_init_data.zig");
const x86_64_array_init_elem = @import("x86_64/ops/wasm_3_0/array_init_elem.zig");
const x86_64_ref_test = @import("x86_64/ops/wasm_3_0/ref_test.zig");
const x86_64_ref_test_null = @import("x86_64/ops/wasm_3_0/ref_test_null.zig");
const x86_64_ref_cast = @import("x86_64/ops/wasm_3_0/ref_cast.zig");
const x86_64_ref_cast_null = @import("x86_64/ops/wasm_3_0/ref_cast_null.zig");

// GC br_on_cast / br_on_cast_fail — cast (jitGcRefTest) + conditional
// BRANCH via the shared `branchOnReg`. The ref is PEEKed (stays as
// block-result top); `_fail` inverts the bool. Both arches;
// `*_fail.zig` re-exports `*.zig`'s emit (sense from `ins.op`).
const arm64_br_on_cast = @import("arm64/ops/wasm_3_0/br_on_cast.zig");
const arm64_br_on_cast_fail = @import("arm64/ops/wasm_3_0/br_on_cast_fail.zig");
const x86_64_br_on_cast = @import("x86_64/ops/wasm_3_0/br_on_cast.zig");
const x86_64_br_on_cast_fail = @import("x86_64/ops/wasm_3_0/br_on_cast_fail.zig");

/// Tuple of all arm64 per-op modules.
pub const collected_arm64_ops = .{
    arm64_i32_add,
    arm64_i32_sub,
    arm64_i32_mul,
    arm64_i32_and,
    arm64_i32_or,
    arm64_i32_xor,
    arm64_i64_add,
    arm64_i64_sub,
    arm64_i64_mul,
    arm64_i64_and,
    arm64_i64_or,
    arm64_i64_xor,
    arm64_i32_eq,
    arm64_i32_ne,
    arm64_i32_lt_s,
    arm64_i32_lt_u,
    arm64_i32_gt_s,
    arm64_i32_gt_u,
    arm64_i32_le_s,
    arm64_i32_le_u,
    arm64_i32_ge_s,
    arm64_i32_ge_u,
    arm64_i64_eq,
    arm64_i64_ne,
    arm64_i64_lt_s,
    arm64_i64_lt_u,
    arm64_i64_gt_s,
    arm64_i64_gt_u,
    arm64_i64_le_s,
    arm64_i64_le_u,
    arm64_i64_ge_s,
    arm64_i64_ge_u,
    arm64_i32_eqz,
    arm64_i64_eqz,
    arm64_i32_shl,
    arm64_i32_shr_s,
    arm64_i32_shr_u,
    arm64_i32_rotl,
    arm64_i32_rotr,
    arm64_i64_shl,
    arm64_i64_shr_s,
    arm64_i64_shr_u,
    arm64_i64_rotl,
    arm64_i64_rotr,
    arm64_i32_clz,
    arm64_i32_ctz,
    arm64_i32_popcnt,
    arm64_i64_clz,
    arm64_i64_ctz,
    arm64_i64_popcnt,
    arm64_i32_extend8_s,
    arm64_i32_extend16_s,
    arm64_i64_extend8_s,
    arm64_i64_extend16_s,
    arm64_i64_extend32_s,
    arm64_i32_div_s,
    arm64_i32_div_u,
    arm64_i32_rem_s,
    arm64_i32_rem_u,
    arm64_i64_div_s,
    arm64_i64_div_u,
    arm64_i64_rem_s,
    arm64_i64_rem_u,
    arm64_i32_wrap_i64,
    arm64_i64_extend_i32_s,
    arm64_i64_extend_i32_u,
    arm64_f32_add,
    arm64_f32_sub,
    arm64_f32_mul,
    arm64_f32_div,
    arm64_f64_add,
    arm64_f64_sub,
    arm64_f64_mul,
    arm64_f64_div,
    arm64_f32_eq,
    arm64_f32_ne,
    arm64_f32_lt,
    arm64_f32_gt,
    arm64_f32_le,
    arm64_f32_ge,
    arm64_f64_eq,
    arm64_f64_ne,
    arm64_f64_lt,
    arm64_f64_gt,
    arm64_f64_le,
    arm64_f64_ge,
    arm64_f32_abs,
    arm64_f32_neg,
    arm64_f32_sqrt,
    arm64_f32_ceil,
    arm64_f32_floor,
    arm64_f32_trunc,
    arm64_f32_nearest,
    arm64_f64_abs,
    arm64_f64_neg,
    arm64_f64_sqrt,
    arm64_f64_ceil,
    arm64_f64_floor,
    arm64_f64_trunc,
    arm64_f64_nearest,
    arm64_f32_min,
    arm64_f32_max,
    arm64_f64_min,
    arm64_f64_max,
    arm64_f32_copysign,
    arm64_f64_copysign,
    arm64_f32_convert_i32_s,
    arm64_f32_convert_i32_u,
    arm64_f32_convert_i64_s,
    arm64_f32_convert_i64_u,
    arm64_f64_convert_i32_s,
    arm64_f64_convert_i32_u,
    arm64_f64_convert_i64_s,
    arm64_f64_convert_i64_u,
    arm64_i32_trunc_sat_f32_s,
    arm64_i32_trunc_sat_f32_u,
    arm64_i32_trunc_sat_f64_s,
    arm64_i32_trunc_sat_f64_u,
    arm64_i64_trunc_sat_f32_s,
    arm64_i64_trunc_sat_f32_u,
    arm64_i64_trunc_sat_f64_s,
    arm64_i64_trunc_sat_f64_u,
    arm64_i32_reinterpret_f32,
    arm64_i64_reinterpret_f64,
    arm64_f32_reinterpret_i32,
    arm64_f64_reinterpret_i64,
    arm64_f32_demote_f64,
    arm64_f64_promote_f32,
    arm64_v128_not,
    arm64_v128_and,
    arm64_v128_or,
    arm64_v128_xor,
    arm64_v128_andnot,
    arm64_v128_bitselect,
    arm64_i8x16_add,
    arm64_i8x16_sub,
    arm64_i16x8_add,
    arm64_i16x8_sub,
    arm64_i16x8_mul,
    arm64_i32x4_add,
    arm64_i32x4_sub,
    arm64_i32x4_mul,
    arm64_i16x8_extmul_low_i8x16_s,
    arm64_i16x8_extmul_high_i8x16_s,
    arm64_i16x8_extmul_low_i8x16_u,
    arm64_i16x8_extmul_high_i8x16_u,
    arm64_i32x4_extmul_low_i16x8_s,
    arm64_i32x4_extmul_high_i16x8_s,
    arm64_i32x4_extmul_low_i16x8_u,
    arm64_i32x4_extmul_high_i16x8_u,
    arm64_i32x4_dot_i16x8_s,
    arm64_i8x16_add_sat_s,
    arm64_i8x16_add_sat_u,
    arm64_i8x16_sub_sat_s,
    arm64_i8x16_sub_sat_u,
    arm64_i16x8_add_sat_s,
    arm64_i16x8_add_sat_u,
    arm64_i16x8_sub_sat_s,
    arm64_i16x8_sub_sat_u,
    arm64_i16x8_q15mulr_sat_s,
    arm64_i16x8_extadd_pairwise_i8x16_s,
    arm64_i16x8_extadd_pairwise_i8x16_u,
    arm64_i32x4_extadd_pairwise_i16x8_s,
    arm64_i32x4_extadd_pairwise_i16x8_u,
    arm64_i64x2_extmul_low_i32x4_s,
    arm64_i64x2_extmul_high_i32x4_s,
    arm64_i64x2_extmul_low_i32x4_u,
    arm64_i64x2_extmul_high_i32x4_u,
    arm64_i64x2_add,
    arm64_i64x2_sub,
    arm64_i8x16_neg,
    arm64_i8x16_abs,
    arm64_i16x8_neg,
    arm64_i16x8_abs,
    arm64_i32x4_neg,
    arm64_i32x4_abs,
    arm64_i64x2_neg,
    arm64_i64x2_abs,
    arm64_i8x16_eq,
    arm64_i8x16_ne,
    arm64_i8x16_lt_s,
    arm64_i8x16_lt_u,
    arm64_i8x16_gt_s,
    arm64_i8x16_gt_u,
    arm64_i8x16_le_s,
    arm64_i8x16_le_u,
    arm64_i8x16_ge_s,
    arm64_i8x16_ge_u,
    arm64_i16x8_eq,
    arm64_i16x8_ne,
    arm64_i16x8_lt_s,
    arm64_i16x8_lt_u,
    arm64_i16x8_gt_s,
    arm64_i16x8_gt_u,
    arm64_i16x8_le_s,
    arm64_i16x8_le_u,
    arm64_i16x8_ge_s,
    arm64_i16x8_ge_u,
    arm64_i32x4_eq,
    arm64_i32x4_ne,
    arm64_i32x4_lt_s,
    arm64_i32x4_lt_u,
    arm64_i32x4_gt_s,
    arm64_i32x4_gt_u,
    arm64_i32x4_le_s,
    arm64_i32x4_le_u,
    arm64_i32x4_ge_s,
    arm64_i32x4_ge_u,
    arm64_i64x2_eq,
    arm64_i64x2_ne,
    arm64_i64x2_lt_s,
    arm64_i64x2_gt_s,
    arm64_i64x2_le_s,
    arm64_i64x2_ge_s,
    arm64_i8x16_shl,
    arm64_i8x16_shr_s,
    arm64_i8x16_shr_u,
    arm64_i16x8_shl,
    arm64_i16x8_shr_s,
    arm64_i16x8_shr_u,
    arm64_i32x4_shl,
    arm64_i32x4_shr_s,
    arm64_i32x4_shr_u,
    arm64_i64x2_shl,
    arm64_i64x2_shr_s,
    arm64_i64x2_shr_u,
    arm64_i8x16_min_s,
    arm64_i8x16_min_u,
    arm64_i8x16_max_s,
    arm64_i8x16_max_u,
    arm64_i16x8_min_s,
    arm64_i16x8_min_u,
    arm64_i16x8_max_s,
    arm64_i16x8_max_u,
    arm64_i32x4_min_s,
    arm64_i32x4_min_u,
    arm64_i32x4_max_s,
    arm64_i32x4_max_u,
    arm64_i8x16_avgr_u,
    arm64_i16x8_avgr_u,
    arm64_f32x4_add,
    arm64_f32x4_sub,
    arm64_f32x4_mul,
    arm64_f32x4_div,
    arm64_f32x4_min,
    arm64_f32x4_max,
    arm64_f32x4_pmin,
    arm64_f32x4_pmax,
    arm64_f64x2_add,
    arm64_f64x2_sub,
    arm64_f64x2_mul,
    arm64_f64x2_div,
    arm64_f64x2_min,
    arm64_f64x2_max,
    arm64_f64x2_pmin,
    arm64_f64x2_pmax,
    arm64_f32x4_abs,
    arm64_f32x4_neg,
    arm64_f32x4_sqrt,
    arm64_f32x4_ceil,
    arm64_f32x4_floor,
    arm64_f32x4_trunc,
    arm64_f32x4_nearest,
    arm64_f64x2_abs,
    arm64_f64x2_neg,
    arm64_f64x2_sqrt,
    arm64_f64x2_ceil,
    arm64_f64x2_floor,
    arm64_f64x2_trunc,
    arm64_f64x2_nearest,
    arm64_f32x4_eq,
    arm64_f32x4_ne,
    arm64_f32x4_lt,
    arm64_f32x4_gt,
    arm64_f32x4_le,
    arm64_f32x4_ge,
    arm64_f64x2_eq,
    arm64_f64x2_ne,
    arm64_f64x2_lt,
    arm64_f64x2_gt,
    arm64_f64x2_le,
    arm64_f64x2_ge,
    arm64_v128_any_true,
    arm64_i8x16_all_true,
    arm64_i16x8_all_true,
    arm64_i32x4_all_true,
    arm64_i64x2_all_true,
    arm64_i8x16_bitmask,
    arm64_i16x8_bitmask,
    arm64_i32x4_bitmask,
    arm64_i64x2_bitmask,
    arm64_i8x16_narrow_i16x8_s,
    arm64_i8x16_narrow_i16x8_u,
    arm64_i16x8_narrow_i32x4_s,
    arm64_i16x8_narrow_i32x4_u,
    arm64_i16x8_extend_low_i8x16_s,
    arm64_i16x8_extend_high_i8x16_s,
    arm64_i16x8_extend_low_i8x16_u,
    arm64_i16x8_extend_high_i8x16_u,
    arm64_i32x4_extend_low_i16x8_s,
    arm64_i32x4_extend_high_i16x8_s,
    arm64_i32x4_extend_low_i16x8_u,
    arm64_i32x4_extend_high_i16x8_u,
    arm64_i64x2_extend_low_i32x4_s,
    arm64_i64x2_extend_high_i32x4_s,
    arm64_i64x2_extend_low_i32x4_u,
    arm64_i64x2_extend_high_i32x4_u,
    arm64_i8x16_swizzle,
    arm64_i8x16_relaxed_swizzle,
    arm64_i8x16_popcnt,
    arm64_f32x4_convert_i32x4_s,
    arm64_f32x4_convert_i32x4_u,
    arm64_f64x2_convert_low_i32x4_s,
    arm64_f64x2_promote_low_f32x4,
    arm64_f32x4_demote_f64x2_zero,
    arm64_i32x4_trunc_sat_f32x4_s,
    arm64_i32x4_trunc_sat_f32x4_u,
    arm64_global_get,
    arm64_global_set,
    arm64_table_get,
    arm64_table_set,
    arm64_table_size,
    arm64_table_grow,
    arm64_table_fill,
    arm64_table_copy,
    arm64_table_init,
    arm64_i32_load,
    arm64_i32_load8_s,
    arm64_i32_load8_u,
    arm64_i32_load16_s,
    arm64_i32_load16_u,
    arm64_i32_store,
    arm64_i32_store8,
    arm64_i32_store16,
    arm64_i64_load,
    arm64_i64_load8_s,
    arm64_i64_load8_u,
    arm64_i64_load16_s,
    arm64_i64_load16_u,
    arm64_i64_load32_s,
    arm64_i64_load32_u,
    arm64_i64_store,
    arm64_i64_store8,
    arm64_i64_store16,
    arm64_i64_store32,
    arm64_f32_load,
    arm64_f32_store,
    arm64_f64_load,
    arm64_f64_store,
    arm64_memory_fill,
    arm64_memory_copy,
    arm64_memory_init,
    arm64_call,
    arm64_call_indirect,
    arm64_block,
    arm64_loop,
    arm64_br_if,
    arm64_br_table,
    arm64_if_,
    arm64_else_,
    arm64_i32_trunc_f32_s,
    arm64_i32_trunc_f32_u,
    arm64_i64_trunc_f32_s,
    arm64_i64_trunc_f32_u,
    arm64_i32_trunc_f64_s,
    arm64_i32_trunc_f64_u,
    arm64_i64_trunc_f64_s,
    arm64_i64_trunc_f64_u,
    arm64_ref_is_null,
    arm64_i8x16_splat,
    arm64_i16x8_splat,
    arm64_i32x4_splat,
    arm64_i64x2_splat,
    arm64_f32x4_splat,
    arm64_f64x2_splat,
    arm64_try_table,
    arm64_ref_as_non_null,
    arm64_br_on_null,
    arm64_br_on_non_null,
    arm64_ref_i31,
    arm64_i31_get_s,
    arm64_i31_get_u,
    arm64_struct_new_default,
    arm64_struct_get,
    arm64_struct_get_s,
    arm64_struct_get_u,
    arm64_struct_new,
    arm64_struct_set,
    arm64_array_new_default,
    arm64_array_len,
    arm64_array_get,
    arm64_array_set,
    arm64_array_new,
    arm64_array_new_fixed,
    arm64_array_get_s,
    arm64_array_get_u,
    arm64_array_fill,
    arm64_ref_eq,
    arm64_array_copy,
    arm64_array_new_data,
    arm64_array_new_elem,
    arm64_array_init_data,
    arm64_array_init_elem,
    arm64_ref_test,
    arm64_ref_test_null,
    arm64_ref_cast,
    arm64_ref_cast_null,
    arm64_br_on_cast,
    arm64_br_on_cast_fail,
};

/// Tuple of x86_64 per-op modules on the legacy args-tuple emit shape.
/// Empty: every x86_64 op uses the `(ctx, ins)` shape and is
/// registered in `collected_x86_64_ctx_ops` below.
pub const collected_x86_64_ops = .{
    // (empty — see docstring above)
};

/// x86_64 per-op modules using the `(ctx, ins)` emit signature
/// (ADR-0075). Separate from `collected_x86_64_ops` because the legacy
/// dispatcher's `args` tuple shape is incompatible at comptime.
pub const collected_x86_64_ctx_ops = .{
    x86_64_i32_div_s,
    x86_64_i32_div_u,
    x86_64_i32_rem_s,
    x86_64_i32_rem_u,
    x86_64_i64_div_s,
    x86_64_i64_div_u,
    x86_64_i64_rem_s,
    x86_64_i64_rem_u,
    x86_64_i32_trunc_f32_s,
    x86_64_i32_trunc_f64_s,
    x86_64_i64_trunc_f32_s,
    x86_64_i64_trunc_f64_s,
    x86_64_i32_trunc_f32_u,
    x86_64_i32_trunc_f64_u,
    x86_64_i64_trunc_f32_u,
    x86_64_i64_trunc_f64_u,
    x86_64_i32_trunc_sat_f32_s,
    x86_64_i32_trunc_sat_f64_s,
    x86_64_i64_trunc_sat_f32_s,
    x86_64_i64_trunc_sat_f64_s,
    x86_64_i32_trunc_sat_f32_u,
    x86_64_i32_trunc_sat_f64_u,
    x86_64_i64_trunc_sat_f32_u,
    x86_64_i64_trunc_sat_f64_u,
    x86_64_f32_convert_i32_s,
    x86_64_f32_convert_i64_s,
    x86_64_f64_convert_i32_s,
    x86_64_f64_convert_i64_s,
    x86_64_f32_convert_i32_u,
    x86_64_f64_convert_i32_u,
    x86_64_f32_convert_i64_u,
    x86_64_f64_convert_i64_u,
    x86_64_i32_reinterpret_f32,
    x86_64_i64_reinterpret_f64,
    x86_64_f32_reinterpret_i32,
    x86_64_f64_reinterpret_i64,
    x86_64_f64_promote_f32,
    x86_64_f32_demote_f64,
    x86_64_i32_load,
    x86_64_i32_load8_s,
    x86_64_i32_load8_u,
    x86_64_i32_load16_s,
    x86_64_i32_load16_u,
    x86_64_i32_store,
    x86_64_i32_store8,
    x86_64_i32_store16,
    x86_64_i64_load,
    x86_64_i64_load8_s,
    x86_64_i64_load8_u,
    x86_64_i64_load16_s,
    x86_64_i64_load16_u,
    x86_64_i64_load32_s,
    x86_64_i64_load32_u,
    x86_64_i64_store,
    x86_64_i64_store8,
    x86_64_i64_store16,
    x86_64_i64_store32,
    x86_64_f32_load,
    x86_64_f64_load,
    x86_64_f32_store,
    x86_64_f64_store,
    x86_64_memory_fill,
    x86_64_memory_copy,
    x86_64_memory_init,
    x86_64_global_get,
    x86_64_global_set,
    x86_64_table_get,
    x86_64_table_set,
    x86_64_table_size,
    x86_64_table_grow,
    x86_64_table_fill,
    x86_64_table_copy,
    x86_64_table_init,
    x86_64_call,
    x86_64_call_indirect,
    x86_64_block,
    x86_64_loop,
    x86_64_i32_const,
    x86_64_i64_const,
    x86_64_f32_const,
    x86_64_f64_const,
    x86_64_ref_null,
    x86_64_ref_func,
    x86_64_drop,
    x86_64_select,
    x86_64_memory_size,
    x86_64_memory_grow,
    x86_64_nop,
    x86_64_unreachable,
    x86_64_return,
    x86_64_br,
    x86_64_br_if,
    x86_64_br_table,
    x86_64_if,
    x86_64_else,
    x86_64_end,
    x86_64_local_get,
    x86_64_local_set,
    x86_64_local_tee,
    x86_64_i32_add,
    x86_64_i32_sub,
    x86_64_i32_mul,
    x86_64_i32_and,
    x86_64_i32_or,
    x86_64_i32_xor,
    x86_64_i64_add,
    x86_64_i64_sub,
    x86_64_i64_mul,
    x86_64_i64_and,
    x86_64_i64_or,
    x86_64_i64_xor,
    x86_64_i32_eq,
    x86_64_i32_ne,
    x86_64_i32_lt_s,
    x86_64_i32_lt_u,
    x86_64_i32_gt_s,
    x86_64_i32_gt_u,
    x86_64_i32_le_s,
    x86_64_i32_le_u,
    x86_64_i32_ge_s,
    x86_64_i32_ge_u,
    x86_64_i64_eq,
    x86_64_i64_ne,
    x86_64_i64_lt_s,
    x86_64_i64_lt_u,
    x86_64_i64_gt_s,
    x86_64_i64_gt_u,
    x86_64_i64_le_s,
    x86_64_i64_le_u,
    x86_64_i64_ge_s,
    x86_64_i64_ge_u,
    x86_64_i32_shl,
    x86_64_i32_shr_s,
    x86_64_i32_shr_u,
    x86_64_i32_rotl,
    x86_64_i32_rotr,
    x86_64_i64_shl,
    x86_64_i64_shr_s,
    x86_64_i64_shr_u,
    x86_64_i64_rotl,
    x86_64_i64_rotr,
    x86_64_i32_clz,
    x86_64_i32_ctz,
    x86_64_i32_popcnt,
    x86_64_i64_clz,
    x86_64_i64_ctz,
    x86_64_i64_popcnt,
    x86_64_i32_eqz,
    x86_64_i64_eqz,
    x86_64_i32_extend8_s,
    x86_64_i32_extend16_s,
    x86_64_i64_extend8_s,
    x86_64_i64_extend16_s,
    x86_64_i64_extend32_s,
    x86_64_i32_wrap_i64,
    x86_64_i64_extend_i32_s,
    x86_64_i64_extend_i32_u,
    x86_64_f32_add,
    x86_64_f32_sub,
    x86_64_f32_mul,
    x86_64_f32_div,
    x86_64_f64_add,
    x86_64_f64_sub,
    x86_64_f64_mul,
    x86_64_f64_div,
    x86_64_f32_eq,
    x86_64_f32_ne,
    x86_64_f32_lt,
    x86_64_f32_gt,
    x86_64_f32_le,
    x86_64_f32_ge,
    x86_64_f64_eq,
    x86_64_f64_ne,
    x86_64_f64_lt,
    x86_64_f64_gt,
    x86_64_f64_le,
    x86_64_f64_ge,
    x86_64_f32_abs,
    x86_64_f32_neg,
    x86_64_f32_sqrt,
    x86_64_f32_ceil,
    x86_64_f32_floor,
    x86_64_f32_trunc,
    x86_64_f32_nearest,
    x86_64_f64_abs,
    x86_64_f64_neg,
    x86_64_f64_sqrt,
    x86_64_f64_ceil,
    x86_64_f64_floor,
    x86_64_f64_trunc,
    x86_64_f64_nearest,
    x86_64_f32_min,
    x86_64_f32_max,
    x86_64_f64_min,
    x86_64_f64_max,
    x86_64_f32_copysign,
    x86_64_f64_copysign,
    x86_64_v128_not,
    x86_64_v128_and,
    x86_64_v128_andnot,
    x86_64_v128_or,
    x86_64_v128_xor,
    x86_64_v128_bitselect,
    x86_64_i8x16_add,
    x86_64_i8x16_sub,
    x86_64_i16x8_add,
    x86_64_i16x8_sub,
    x86_64_i16x8_mul,
    x86_64_i32x4_add,
    x86_64_i32x4_sub,
    x86_64_i32x4_mul,
    x86_64_i64x2_add,
    x86_64_i64x2_sub,
    x86_64_i8x16_neg,
    x86_64_i16x8_neg,
    x86_64_i32x4_neg,
    x86_64_i64x2_neg,
    x86_64_i8x16_abs,
    x86_64_i16x8_abs,
    x86_64_i32x4_abs,
    x86_64_i64x2_abs,
    x86_64_i8x16_eq,
    x86_64_i8x16_ne,
    x86_64_i8x16_lt_s,
    x86_64_i8x16_lt_u,
    x86_64_i8x16_gt_s,
    x86_64_i8x16_gt_u,
    x86_64_i8x16_le_s,
    x86_64_i8x16_le_u,
    x86_64_i8x16_ge_s,
    x86_64_i8x16_ge_u,
    x86_64_i16x8_eq,
    x86_64_i16x8_ne,
    x86_64_i16x8_lt_s,
    x86_64_i16x8_lt_u,
    x86_64_i16x8_gt_s,
    x86_64_i16x8_gt_u,
    x86_64_i16x8_le_s,
    x86_64_i16x8_le_u,
    x86_64_i16x8_ge_s,
    x86_64_i16x8_ge_u,
    x86_64_i32x4_eq,
    x86_64_i32x4_ne,
    x86_64_i32x4_lt_s,
    x86_64_i32x4_lt_u,
    x86_64_i32x4_gt_s,
    x86_64_i32x4_gt_u,
    x86_64_i32x4_le_s,
    x86_64_i32x4_le_u,
    x86_64_i32x4_ge_s,
    x86_64_i32x4_ge_u,
    x86_64_i64x2_eq,
    x86_64_i64x2_ne,
    x86_64_i64x2_lt_s,
    x86_64_i64x2_gt_s,
    x86_64_i64x2_le_s,
    x86_64_i64x2_ge_s,
    x86_64_i8x16_shl,
    x86_64_i8x16_shr_s,
    x86_64_i8x16_shr_u,
    x86_64_i16x8_shl,
    x86_64_i16x8_shr_s,
    x86_64_i16x8_shr_u,
    x86_64_i32x4_shl,
    x86_64_i32x4_shr_s,
    x86_64_i32x4_shr_u,
    x86_64_i64x2_shl,
    x86_64_i64x2_shr_s,
    x86_64_i64x2_shr_u,
    x86_64_i8x16_min_s,
    x86_64_i8x16_min_u,
    x86_64_i8x16_max_s,
    x86_64_i8x16_max_u,
    x86_64_i16x8_min_s,
    x86_64_i16x8_min_u,
    x86_64_i16x8_max_s,
    x86_64_i16x8_max_u,
    x86_64_i32x4_min_s,
    x86_64_i32x4_min_u,
    x86_64_i32x4_max_s,
    x86_64_i32x4_max_u,
    x86_64_i8x16_add_sat_s,
    x86_64_i8x16_add_sat_u,
    x86_64_i8x16_sub_sat_s,
    x86_64_i8x16_sub_sat_u,
    x86_64_i16x8_add_sat_s,
    x86_64_i16x8_add_sat_u,
    x86_64_i16x8_sub_sat_s,
    x86_64_i16x8_sub_sat_u,
    x86_64_i8x16_avgr_u,
    x86_64_i16x8_avgr_u,
    x86_64_f32x4_add,
    x86_64_f32x4_sub,
    x86_64_f32x4_mul,
    x86_64_f32x4_div,
    x86_64_f32x4_min,
    x86_64_f32x4_max,
    x86_64_f32x4_pmin,
    x86_64_f32x4_pmax,
    x86_64_f64x2_add,
    x86_64_f64x2_sub,
    x86_64_f64x2_mul,
    x86_64_f64x2_div,
    x86_64_f64x2_min,
    x86_64_f64x2_max,
    x86_64_f64x2_pmin,
    x86_64_f64x2_pmax,
    x86_64_f32x4_abs,
    x86_64_f32x4_neg,
    x86_64_f32x4_sqrt,
    x86_64_f32x4_ceil,
    x86_64_f32x4_floor,
    x86_64_f32x4_trunc,
    x86_64_f32x4_nearest,
    x86_64_f64x2_abs,
    x86_64_f64x2_neg,
    x86_64_f64x2_sqrt,
    x86_64_f64x2_ceil,
    x86_64_f64x2_floor,
    x86_64_f64x2_trunc,
    x86_64_f64x2_nearest,
    x86_64_f32x4_eq,
    x86_64_f32x4_ne,
    x86_64_f32x4_lt,
    x86_64_f32x4_gt,
    x86_64_f32x4_le,
    x86_64_f32x4_ge,
    x86_64_f64x2_eq,
    x86_64_f64x2_ne,
    x86_64_f64x2_lt,
    x86_64_f64x2_gt,
    x86_64_f64x2_le,
    x86_64_f64x2_ge,
    x86_64_v128_any_true,
    x86_64_i8x16_all_true,
    x86_64_i16x8_all_true,
    x86_64_i32x4_all_true,
    x86_64_i64x2_all_true,
    x86_64_i8x16_bitmask,
    x86_64_i16x8_bitmask,
    x86_64_i32x4_bitmask,
    x86_64_i64x2_bitmask,
    x86_64_i16x8_extend_low_i8x16_s,
    x86_64_i16x8_extend_low_i8x16_u,
    x86_64_i16x8_extend_high_i8x16_s,
    x86_64_i16x8_extend_high_i8x16_u,
    x86_64_i32x4_extend_low_i16x8_s,
    x86_64_i32x4_extend_low_i16x8_u,
    x86_64_i32x4_extend_high_i16x8_s,
    x86_64_i32x4_extend_high_i16x8_u,
    x86_64_i64x2_extend_low_i32x4_s,
    x86_64_i64x2_extend_low_i32x4_u,
    x86_64_i64x2_extend_high_i32x4_s,
    x86_64_i64x2_extend_high_i32x4_u,
    x86_64_i8x16_narrow_i16x8_s,
    x86_64_i8x16_narrow_i16x8_u,
    x86_64_i16x8_narrow_i32x4_s,
    x86_64_i16x8_narrow_i32x4_u,
    x86_64_i16x8_extmul_low_i8x16_s,
    x86_64_i16x8_extmul_high_i8x16_s,
    x86_64_i16x8_extmul_low_i8x16_u,
    x86_64_i16x8_extmul_high_i8x16_u,
    x86_64_i32x4_extmul_low_i16x8_s,
    x86_64_i32x4_extmul_high_i16x8_s,
    x86_64_i32x4_extmul_low_i16x8_u,
    x86_64_i32x4_extmul_high_i16x8_u,
    x86_64_i64x2_extmul_low_i32x4_s,
    x86_64_i64x2_extmul_high_i32x4_s,
    x86_64_i64x2_extmul_low_i32x4_u,
    x86_64_i64x2_extmul_high_i32x4_u,
    x86_64_ref_is_null,
    x86_64_i8x16_splat,
    x86_64_i16x8_splat,
    x86_64_i32x4_splat,
    x86_64_i64x2_splat,
    x86_64_f32x4_splat,
    x86_64_f64x2_splat,
    x86_64_i8x16_swizzle,
    x86_64_i8x16_relaxed_swizzle,
    x86_64_i16x8_extadd_pairwise_i8x16_s,
    x86_64_i16x8_extadd_pairwise_i8x16_u,
    x86_64_i32x4_extadd_pairwise_i16x8_s,
    x86_64_i32x4_extadd_pairwise_i16x8_u,
    x86_64_i32x4_dot_i16x8_s,
    x86_64_i16x8_q15mulr_sat_s,
    x86_64_f32x4_convert_i32x4_s,
    x86_64_f32x4_convert_i32x4_u,
    x86_64_f64x2_convert_low_i32x4_s,
    x86_64_f64x2_promote_low_f32x4,
    x86_64_f32x4_demote_f64x2_zero,
    x86_64_i32x4_trunc_sat_f32x4_s,
    x86_64_i32x4_trunc_sat_f32x4_u,
    // Wasm 3.0 EH (ADR-0114 D2) — try_table routes here for its
    // `exception_table_builder` invariant assert.
    x86_64_try_table,
    x86_64_throw,
    x86_64_throw_ref,
    // ADR-0112 D4 — return_call emit delegates to
    // op_tail_call.emitDirectReturnCall (sibling arm64 wired via the
    // manual switch in arm64/emit.zig).
    x86_64_return_call,
    // ADR-0112 D4 — return_call_indirect emit delegates to
    // op_tail_call.emitIndirectReturnCall (JMP R11 path; sibling arm64
    // wired via manual switch in arm64/emit.zig).
    x86_64_return_call_indirect,
    // function-references — call_ref JIT (op_call.emitCallRefCtx;
    // sibling arm64 via manual switch in emit.zig).
    x86_64_call_ref,
    // return_call_ref JIT (op_tail_call.emitReturnCallRef; sibling
    // arm64 via manual switch in emit.zig).
    x86_64_return_call_ref,
    x86_64_ref_as_non_null,
    // br_on_null / br_on_non_null JIT emit (D-194 discharge Path B
    // via captureOrEmitBlockMergeMovCtx wrapper).
    x86_64_br_on_null,
    x86_64_br_on_non_null,
    // GC-on-JIT i31 family (mirror of arm64; D-211).
    x86_64_ref_i31,
    x86_64_i31_get_s,
    x86_64_i31_get_u,
    x86_64_struct_new_default,
    x86_64_struct_get,
    x86_64_struct_get_s,
    x86_64_struct_get_u,
    x86_64_struct_new,
    x86_64_struct_set,
    x86_64_array_new_default,
    x86_64_array_len,
    x86_64_array_get,
    x86_64_array_set,
    x86_64_array_new,
    x86_64_array_new_fixed,
    x86_64_array_get_s,
    x86_64_array_get_u,
    x86_64_array_fill,
    x86_64_ref_eq,
    x86_64_array_copy,
    x86_64_array_new_data,
    x86_64_array_new_elem,
    x86_64_array_init_data,
    x86_64_array_init_elem,
    x86_64_ref_test,
    x86_64_ref_test_null,
    x86_64_ref_cast,
    x86_64_ref_cast_null,
    x86_64_br_on_cast,
    x86_64_br_on_cast_fail,
};
