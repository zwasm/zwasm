//! Wasm SIMD-128 prefix-`0xFD` validator — extracted from `validator.zig`
//! per ADR-0083 Phase 1.
//!
//! Contains the `dispatchPrefixFD` entry function (called from
//! `validator.Validator.dispatch()` 0xFD arm) plus all SIMD-specific
//! op helpers (load/store shape decoders, lane/memarg validation,
//! splat/extract/replace/shuffle/binop/unop/bitselect/shift).
//!
//! All functions are free functions taking `*Validator` as the
//! first argument (since Validator's struct definition lives in
//! `validator.zig`; method syntax cannot span files). Within this
//! file, intra-SIMD calls are rewritten from `self.opSimdX(...)`
//! to `opSimdX(self, ...)`.
//!
//! Validator-level helpers (`popExpect`, `pushType`, `readLaneIdx`,
//! state field access) are reached via `self.<method>()` /
//! `self.<field>` syntax — Zig resolves these via Validator's
//! namespace declaration in validator.zig.
//!
//! Zone 1 (`src/validate/`).

const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");

const validator = @import("validator.zig");
const Validator = validator.Validator;
const Error = validator.Error;
const ValType = zir.ValType;

/// Wasm SIMD-128 prefix-`0xFD` sub-opcode dispatch (§9.9 per
/// ADR-0041 + Revision 2). MVP catalogue lands the
/// foundational op shapes; remaining sub-opcodes extend
/// across §9.4 IR + 9.5-9.8 emit chunks per ADR-0041's
/// chunk plan. Sub-opcode numbering follows the Wasm SIMD
/// proposal (WebAssembly/testsuite `proposals/simd/*.wast`).
pub fn dispatchPrefixFD(self: *Validator) Error!void {
    const sub = try leb128.readUleb128(u32, self.body, &self.pos);
    switch (sub) {
        // Loads — natural alignment per Wasm SIMD spec §3.3.7.
        // align_log2 ≤ log2(natural_bytes); Error.InvalidAlignment otherwise.
        0 => try opSimdLoad(self, 4), // v128.load (16 bytes → log2=4)
        1, 2, 3, 4, 5, 6 => try opSimdLoad(self, 3), // load{8x8,16x4,32x2}_{s,u} (8 bytes → log2=3)
        7 => try opSimdLoad(self, 0), // v128.load8_splat (1 byte)
        8 => try opSimdLoad(self, 1), // v128.load16_splat (2 bytes)
        9 => try opSimdLoad(self, 2), // v128.load32_splat (4 bytes)
        10 => try opSimdLoad(self, 3), // v128.load64_splat (8 bytes)
        92 => try opSimdLoad(self, 2), // v128.load32_zero (4 bytes)
        93 => try opSimdLoad(self, 3), // v128.load64_zero (8 bytes)

        // Store: pop v128 + i32 addr (memarg).
        11 => try opSimdStore(self, 4), // v128.store (16 bytes → log2=4)

        // v128.const: 16 immediate bytes; push v128.
        12 => try opSimdConst(self),

        // i8x16.shuffle: 16 immediate lane bytes; pop 2× v128, push v128.
        13 => try opSimdShuffle(self),

        // i8x16.swizzle: pop 2× v128, push v128.
        14 => try opSimdBinop(self),

        // Splat ops: pop scalar (per shape), push v128.
        15 => try opSimdSplat(self, .i32), // i8x16.splat (i32 input, narrowed at runtime)
        16 => try opSimdSplat(self, .i32), // i16x8.splat
        17 => try opSimdSplat(self, .i32), // i32x4.splat
        18 => try opSimdSplat(self, .i64), // i64x2.splat
        19 => try opSimdSplat(self, .f32), // f32x4.splat
        20 => try opSimdSplat(self, .f64), // f64x2.splat

        // extract_lane / replace_lane: read 1-byte lane immediate.
        // Lane count per shape: i8x16=16, i16x8=8, i32x4=4,
        // i64x2=2, f32x4=4, f64x2=2 (Wasm SIMD spec §3.3.6.X).
        21, 22 => try opSimdExtractLane(self, .i32, 16), // i8x16.extract_lane_{s,u}
        23 => try opSimdReplaceLane(self, .i32, 16), // i8x16.replace_lane
        24, 25 => try opSimdExtractLane(self, .i32, 8), // i16x8.extract_lane_{s,u}
        26 => try opSimdReplaceLane(self, .i32, 8), // i16x8.replace_lane
        27 => try opSimdExtractLane(self, .i32, 4), // i32x4.extract_lane
        28 => try opSimdReplaceLane(self, .i32, 4), // i32x4.replace_lane
        29 => try opSimdExtractLane(self, .i64, 2), // i64x2.extract_lane
        30 => try opSimdReplaceLane(self, .i64, 2), // i64x2.replace_lane
        31 => try opSimdExtractLane(self, .f32, 4), // f32x4.extract_lane
        32 => try opSimdReplaceLane(self, .f32, 4), // f32x4.replace_lane
        33 => try opSimdExtractLane(self, .f64, 2), // f64x2.extract_lane
        34 => try opSimdReplaceLane(self, .f64, 2), // f64x2.replace_lane

        // Comparison ops (relops, sub 35..76): pop 2× v128, push
        // v128 mask. §9.9 / 9.9-f-1 splits the bitwise unop +
        // 3-op cases out of the binop range (was approximated
        // as binop in the 9.4 MVP; rejected the simd_bitwise.0
        // fixture's `not` / `bitselect` exports with
        // StackUnderflow because the operand-stack pop count
        // didn't match).
        35...76 => try opSimdBinop(self),
        77 => try opSimdUnop(self), // v128.not — pop 1 v128, push 1 v128
        78, 79, 80, 81 => try opSimdBinop(self), // v128.{and, or, xor, andnot}
        82 => try opSimdBitselect(self), // v128.bitselect — pop 3× v128, push v128

        // any_true (sub 83): pop v128, push i32.
        83 => try opSimdAllTrueOrAnyTrue(self),

        // §9.7 / 9.7-ba — load_lane × 4, store_lane × 4.
        // memarg + lane byte; load_lane pops (i32, v128) + pushes
        // v128; store_lane pops (i32, v128) + pushes nothing.
        // Lane count + max align_log2 per access width:
        //   load/store8  → 16 lanes, align ≤ 0 (1 byte natural)
        //   load/store16 → 8  lanes, align ≤ 1 (2 bytes)
        //   load/store32 → 4  lanes, align ≤ 2 (4 bytes)
        //   load/store64 → 2  lanes, align ≤ 3 (8 bytes)
        // (Wasm SIMD spec §4.3.4 + §3.3.7).
        84 => try opSimdLoadLane(self, 16, 0), // v128.load8_lane
        85 => try opSimdLoadLane(self, 8, 1), // v128.load16_lane
        86 => try opSimdLoadLane(self, 4, 2), // v128.load32_lane
        87 => try opSimdLoadLane(self, 2, 3), // v128.load64_lane
        88 => try opSimdStoreLane(self, 16, 0), // v128.store8_lane
        89 => try opSimdStoreLane(self, 8, 1), // v128.store16_lane
        90 => try opSimdStoreLane(self, 4, 2), // v128.store32_lane
        91 => try opSimdStoreLane(self, 2, 3), // v128.store64_lane

        // §9.9 / 9.9-f-6 — int arith range (94..211). Split out
        // unop arms to fix StackUnderflow for `i*.neg / abs /
        // popcnt / extend_low/high / extadd_pairwise_*` (all
        // pop 1 v128, push 1 v128). Per Wasm SIMD spec opcode
        // table:
        //   96/97/98 i8x16.{abs,neg,popcnt}
        //   124/125 i16x8.extadd_pairwise_i8x16_{s,u}
        //   126/127 i32x4.extadd_pairwise_i16x8_{s,u}
        //   128/129 i16x8.{abs,neg}
        //   135..138 i16x8.extend_{low,high}_i8x16_{s,u} (per spec
        //            0x87..0x8A; the prior 134..137 numbering was
        //            off-by-one — 9.9-g-7 corrects it.)
        //   160/161 i32x4.{abs,neg}
        //   167..170 i32x4.extend_{low,high}_i16x8_{s,u} (per spec
        //            0xA7..0xAA; off-by-one corrected at 9.9-g-7).
        //   192/193 i64x2.{abs,neg}
        //   199..202 i64x2.extend_{low,high}_i32x4_{s,u} (per spec
        //            0xC7..0xCA; numbering already correct).
        96,
        97,
        98,
        124,
        125,
        126,
        127,
        128,
        129,
        135,
        136,
        137,
        138,
        160,
        161,
        167,
        168,
        169,
        170,
        192,
        193,
        199,
        200,
        201,
        202,
        // D-457 systemic close: FP rounding + demote/promote are UNARY (pop 1
        // v128, push 1). The 9.4 MVP swept them into the binop fallthrough — the
        // same miscount that hid the convert ops (248..255) — and the old corpus
        // had no simd_*_rounding / simd_conversions to surface the StackUnderflow.
        //   94  f32x4.demote_f64x2_zero / 95 f64x2.promote_low_f32x4
        //   103..106 f32x4.{ceil, floor, trunc, nearest}
        //   116/117/122/148 f64x2.{ceil, floor, trunc, nearest}
        94,
        95,
        103,
        104,
        105,
        106,
        116,
        117,
        122,
        148,
        => try opSimdUnop(self),
        // Everything else in 94..211 stays binop (cmp / arith /
        // shifts / saturated arith / dot / extmul / etc.).
        // bitmask sub-ops 100/132/164/196 routed above to
        // opSimdAllTrueOrAnyTrue (1-pop v128, push i32).
        // 94/95 (demote/promote) + 103..106/116/117/122/148 (FP rounding) moved
        // to the unop arm above (D-457); 101/102/133/134 (narrow) stay binop.
        101,
        102,
        110,
        111,
        112,
        113,
        114,
        115,
        118,
        119,
        120,
        121,
        123,
        130,
        133,
        134,
        142,
        143,
        144,
        145,
        146,
        147,
        149,
        150,
        151,
        152,
        153,
        154,
        155,
        156,
        157,
        158,
        159,
        162,
        165,
        166,
        174,
        175,
        176,
        177,
        178,
        179,
        180,
        181,
        182,
        183,
        184,
        185,
        186,
        187,
        188,
        189,
        190,
        191,
        194,
        197,
        198,
        206,
        207,
        208,
        209,
        210,
        211, // i64x2 add/.../sub etc.
        // 213 i64x2.mul (per §9.9 / 9.9-f-8).
        213, // §9.9 / 9.9-f-8 — i64x2.mul (handler-side multi-instr synthesis on ARM64 since NEON has no MUL.2D).
        // D-457 systemic close: i64x2.extmul_{low,high}_i32x4_{s,u} (220..223,
        // 0xDC..0xDF) were absent → NotImplemented at validate. The i16x8/i32x4
        // extmul siblings (156..159 / 188..191) were present; only the 64-bit
        // lane shape was missed, and the old corpus had no simd_i64x2_extmul.
        220,
        221,
        222,
        223,
        => try opSimdBinop(self),

        // §9.9 / 9.9-g-2 — i64x2 comparison ops 214..219.
        // i64x2.{eq, ne, lt_s, gt_s, le_s, ge_s}; spec only
        // defines signed cmp for the 64-bit lane shape.
        214, 215, 216, 217, 218, 219 => try opSimdBinop(self),

        // §9.9 / 9.9-g-7 — int shift family. Wasm SIMD shifts
        // pop (i32_amount, v128_value), push v128. Per spec
        // (BinarySIMD.md):
        //   107..109 (0x6B..6D) i8x16.{shl, shr_s, shr_u}
        //   139..141 (0x8B..8D) i16x8.{shl, shr_s, shr_u}
        //   171..173 (0xAB..AD) i32x4.{shl, shr_s, shr_u}
        //   203..205 (0xCB..CD) i64x2.{shl, shr_s, shr_u}
        // ARM64 emit currently only handles shl; shr_s/shr_u
        // surface as UnsupportedOp at compile (next chunk wires
        // the NEG-then-(U|S)SHL synthesis).
        // i8x16
        107,
        108,
        109,
        // i16x8
        139,
        140,
        141,
        // i32x4
        171,
        172,
        173,
        // i64x2
        203,
        204,
        205,
        => try opSimdShift(self),

        // §9.9 / 9.9-g-3 + 9.9-g-19 — int reductions to i32.
        //   all_true (99/131/163/195): every-lane-non-zero predicate.
        //   bitmask (100/132/164/196): high-bit-of-each-lane → bitmask.
        // All 8 share the same validator shape (pop v128, push i32);
        // bitmask emit handlers land per ADR-0051 (arm64) + cranelift
        // PMOVMSKB recipe (x86_64).
        // all_true (i8x16 / i16x8 / i32x4 / i64x2)
        99,
        131,
        163,
        195,
        // bitmask (i8x16 / i16x8 / i32x4 / i64x2)
        100,
        132,
        164,
        196,
        => try opSimdAllTrueOrAnyTrue(self),

        // §9.9 / 9.9-f-5 — split FP arith range. Sub-opcodes
        // 224..255 cover f32x4 + f64x2 ops; the 9.4 MVP
        // routed all as binop, miscounting unop arms (abs,
        // neg, sqrt) that pop only 1 v128.
        //   224 f32x4.abs / 225 f32x4.neg / 227 f32x4.sqrt
        //   236 f64x2.abs / 237 f64x2.neg / 239 f64x2.sqrt
        // are unops; 228..235 + 240..247 stay binops.
        224, 225, 227, 236, 237, 239 => try opSimdUnop(self),
        226, 228...235, 238, 240...247 => try opSimdBinop(self),
        // 248..255 are the float↔int LANE-CONVERSION ops, all UNARY (pop 1
        // v128, push 1 v128) — the 9.4 MVP's `240...255` binop range wrongly
        // swept them in, so a module using any of them failed validation
        // (i32x4.trunc_sat_f32x4_{s,u}=248/249, f32x4.convert_i32x4_{s,u}=
        // 250/251, i32x4.trunc_sat_f64x2_{s,u}_zero=252/253,
        // f64x2.convert_low_i32x4_{s,u}=254/255). The official simd corpus
        // never exercised them; wasmtime int-to-float-splat caught it (ADR-0192).
        248...255 => try opSimdUnop(self),

        // §17.4 — relaxed-SIMD (proposal Phase-5/W3C-Rec). Sub 0x100..0x113
        // (256..275). Validator only checks the operand-stack shape; the
        // implementation-defined latitude is resolved deterministically at
        // emit (uniform interp-less/JIT-both-arches choice — see 17.4 bundle).
        //   256       i8x16.relaxed_swizzle               2-pop
        //   257..260  i32x4.relaxed_trunc_*               1-pop
        //   261..264  f{32,64}x4.relaxed_{madd,nmadd}     3-pop
        //   265..268  *.relaxed_laneselect                3-pop
        //   269..272  f{32,64}x4.relaxed_{min,max}        2-pop
        //   273       i16x8.relaxed_q15mulr_s             2-pop
        //   274       i16x8.relaxed_dot_i8x16_i7x16_s     2-pop
        //   275       i32x4.relaxed_dot_i8x16_i7x16_add_s 3-pop
        256, 269, 270, 271, 272, 273, 274 => try opSimdBinop(self),
        257, 258, 259, 260 => try opSimdUnop(self),
        261, 262, 263, 264, 265, 266, 267, 268, 275 => try opSimdBitselect(self),

        else => return Error.NotImplemented,
    }
}

/// `v128.const`: 16 immediate bytes; push v128.
pub fn opSimdConst(self: *Validator) Error!void {
    if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
    self.pos += 16;
    try self.pushType(.v128);
}

/// `i8x16.shuffle`: 16 immediate lane bytes; pop 2× v128, push v128.
/// Each lane byte must be < 32 (per spec; lane indices into the
/// concatenated 32-byte input). Validator enforces lane-bound; emit
/// pass uses the immediate at code-emit time.
pub fn opSimdShuffle(self: *Validator) Error!void {
    if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
    for (self.body[self.pos..][0..16]) |lane| {
        if (lane >= 32) return Error.BadValType;
    }
    self.pos += 16;
    try self.popExpect(.v128);
    try self.popExpect(.v128);
    try self.pushType(.v128);
}

/// SIMD splat (`i8x16.splat`, `i32x4.splat`, …): pop a scalar of
/// the source-element type; push v128.
pub fn opSimdSplat(self: *Validator, src: ValType) Error!void {
    try self.popExpect(src);
    try self.pushType(.v128);
}

/// Read + range-check a 1-byte SIMD lane-index immediate.
/// Wasm SIMD spec §3.3.6.X: the immediate `lane_idx` MUST be
/// `< lane_count`. Validation-time reject (Error.InvalidLaneIndex),
/// not a deferred runtime trap (the prior "deferred to emit"
/// comment was wrong — fixed at §9.12-E / B133).
pub fn readLaneIdx(self: *Validator, lane_count: u8) Error!void {
    if (self.pos >= self.body.len) return Error.UnexpectedEnd;
    const lane_idx = self.body[self.pos];
    self.pos += 1;
    if (lane_idx >= lane_count) return Error.InvalidLaneIndex;
}

/// Read + range-check a SIMD memarg's alignment immediate.
/// Wasm spec §3.3.7 + Wasm 3.0 §5.4.6 memory64 memarg encoding:
/// the align uleb's bit 6 (0x40) is the memidx-presence flag —
/// when set, a memidx uleb follows the align and the effective
/// log2-align is `align & 0x3F` (low 6 bits). The validator
/// range-checks the effective alignment against the op's
/// natural alignment (Error.InvalidAlignment).
///
/// memidx is decoded-and-discarded — the runtime instantiate
/// path rejects multi-memory > 1 per ADR-0111 D5, so memidx
/// must be 0 in valid modules. Reading it here keeps the
/// validator in sync with the lowerer's `emitMemarg` and
/// `emitMemargLane` shape.
///
/// §9.12-E / B134. Non-SIMD opLoad / opStore read theirs with
/// `readMemargCheckAlign`.
pub fn readSimdMemarg(self: *Validator, max_align_log2: u8) Error!u32 {
    const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
    const has_memidx = (raw_align & 0x40) != 0;
    const align_log2: u32 = if (has_memidx) (raw_align & 0x3F) else raw_align;
    if (align_log2 > max_align_log2) return Error.InvalidAlignment;
    var memidx: u32 = 0;
    if (has_memidx) {
        memidx = try leb128.readUleb128(u32, self.body, &self.pos);
    }
    _ = try leb128.readUleb128(u32, self.body, &self.pos); // offset
    return memidx;
}

/// SIMD v128.load family — natural alignment varies per op
/// (load=16, loadXxY=8, load*_splat per element width). Pop
/// i32 addr, push v128.
pub fn opSimdLoad(self: *Validator, max_align_log2: u8) Error!void {
    if (self.memory_count == 0) return Error.UnknownMemory;
    const memidx = try readSimdMemarg(self, max_align_log2);
    try self.popExpect(self.memIdxTypeAt(memidx)); // address (i64 for memory64)
    try self.pushType(.v128);
}

/// SIMD v128.store — 16-byte natural alignment (max_align_log2=4).
/// Pop v128 + addr (i64 for memory64).
pub fn opSimdStore(self: *Validator, max_align_log2: u8) Error!void {
    if (self.memory_count == 0) return Error.UnknownMemory;
    const memidx = try readSimdMemarg(self, max_align_log2);
    try self.popExpect(.v128);
    try self.popExpect(self.memIdxTypeAt(memidx));
}

/// SIMD extract_lane (`i8x16.extract_lane_s`, `f32x4.extract_lane`,
/// …): read 1-byte lane immediate; pop v128; push scalar.
pub fn opSimdExtractLane(self: *Validator, dst: ValType, lane_count: u8) Error!void {
    try readLaneIdx(self, lane_count);
    try self.popExpect(.v128);
    try self.pushType(dst);
}

/// SIMD replace_lane (`i8x16.replace_lane`, `f64x2.replace_lane`,
/// …): read 1-byte lane immediate; pop scalar + v128; push v128.
pub fn opSimdReplaceLane(self: *Validator, src: ValType, lane_count: u8) Error!void {
    try readLaneIdx(self, lane_count);
    try self.popExpect(src);
    try self.popExpect(.v128);
    try self.pushType(.v128);
}

/// SIMD load_lane: memarg (align uleb + offset uleb) + 1-byte
/// lane immediate. Pop v128 + i32 idx; push v128 (modified).
/// `max_align_log2` enforces per-access-width natural alignment
/// (load8=0, load16=1, load32=2, load64=3).
pub fn opSimdLoadLane(self: *Validator, lane_count: u8, max_align_log2: u8) Error!void {
    if (self.memory_count == 0) return Error.UnknownMemory;
    const memidx = try readSimdMemarg(self, max_align_log2);
    try readLaneIdx(self, lane_count);
    try self.popExpect(.v128);
    try self.popExpect(self.memIdxTypeAt(memidx)); // address (i64 for memory64)
    try self.pushType(.v128);
}

/// SIMD store_lane: memarg + 1-byte lane immediate. Pop v128 +
/// addr (i64 for memory64); push nothing.
pub fn opSimdStoreLane(self: *Validator, lane_count: u8, max_align_log2: u8) Error!void {
    if (self.memory_count == 0) return Error.UnknownMemory;
    const memidx = try readSimdMemarg(self, max_align_log2);
    try readLaneIdx(self, lane_count);
    try self.popExpect(.v128);
    try self.popExpect(self.memIdxTypeAt(memidx));
}

/// Generic v128 binop (and/or/xor, integer add/sub/mul, shifts,
/// comparisons, etc. — anything that pops 2 v128 and pushes 1).
pub fn opSimdBinop(self: *Validator) Error!void {
    try self.popExpect(.v128);
    try self.popExpect(.v128);
    try self.pushType(.v128);
}

/// Generic v128 unop (`v128.not`, `i8x16.abs`, etc. — pop 1 v128,
/// push 1 v128).
pub fn opSimdUnop(self: *Validator) Error!void {
    try self.popExpect(.v128);
    try self.pushType(.v128);
}

/// `v128.bitselect`: pop 3× v128 (val1, val2, mask), push v128.
/// Wasm spec §3.3.6.6 (bitselect).
pub fn opSimdBitselect(self: *Validator) Error!void {
    try self.popExpect(.v128);
    try self.popExpect(.v128);
    try self.popExpect(.v128);
    try self.pushType(.v128);
}

/// SIMD int shift (`i*x*.shl/shr_s/shr_u`): pop i32 amount,
/// pop v128 value, push v128. Wasm SIMD spec §3.3.6.
pub fn opSimdShift(self: *Validator) Error!void {
    try self.popExpect(.i32);
    try self.popExpect(.v128);
    try self.pushType(.v128);
}

/// `v128.any_true` / `i8x16.all_true` / etc.: pop v128, push i32.
pub fn opSimdAllTrueOrAnyTrue(self: *Validator) Error!void {
    try self.popExpect(.v128);
    try self.pushType(.i32);
}
