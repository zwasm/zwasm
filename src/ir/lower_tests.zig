//! Tests for `src/frontend/lowerer.zig` (§9.5 / 5.2 carve-out
//! to keep the lowerer under §A2's 1000-line soft cap; the
//! per-feature lowerer split mirroring ROADMAP §A12 stays
//! queued for §9.1 / 1.7).
//!
//! Tests reach the lowerer only through its public API
//! (`lowerFunctionBody`, `Error`).

const std = @import("std");

const lowerer = @import("lower.zig");
const zir = @import("zir.zig");

const lowerFunctionBody = lowerer.lowerFunctionBody;
const Error = lowerer.Error;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const BlockKind = zir.BlockKind;
const BlockInfo = zir.BlockInfo;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;

const testing = std.testing;

const empty_sig: FuncType = .{ .params = &.{}, .results = &.{} };
const i32_arr = [_]ValType{.i32};
const i32_result_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };

fn newFunc(sig: FuncType) ZirFunc {
    return ZirFunc.init(0, sig, &.{});
}

test "lower: bare end emits a single .end instr and no blocks" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    try lowerFunctionBody(testing.allocator, &[_]u8{0x0B}, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 1), f.instrs.items.len);
    try testing.expectEqual(ZirOp.end, f.instrs.items[0].op);
    try testing.expectEqual(@as(usize, 0), f.blocks.items.len);
}

test "lower: i32.const + drop + end packs sleb128 value into payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // i32.const -1 (sleb 0x7F), drop, end
    try lowerFunctionBody(testing.allocator, &[_]u8{ 0x41, 0x7F, 0x1A, 0x0B }, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 3), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), f.instrs.items[0].payload);
    try testing.expectEqual(ZirOp.drop, f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[2].op);
}

test "lower: ref.as_non_null (0xD4) emits .ref.as_non_null" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // ref.null func ; ref.as_non_null ; drop ; end. ref.as_non_null is
    // opcode 0xD4 (0xD3 is GC ref.eq); pre-fix lower decoded 0xD3.
    try lowerFunctionBody(testing.allocator, &[_]u8{ 0xD0, 0x70, 0xD4, 0x1A, 0x0B }, &f, &.{}, &.{});

    try testing.expectEqual(ZirOp.@"ref.null", f.instrs.items[0].op);
    try testing.expectEqual(ZirOp.@"ref.as_non_null", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.drop, f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[3].op);
}

test "lower: i64.const splits low32/high32 across payload+extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // i64.const -1 → sleb128 0x7F → bitcast u64 = 0xFFFF_FFFF_FFFF_FFFF
    try lowerFunctionBody(testing.allocator, &[_]u8{ 0x42, 0x7F, 0x1A, 0x0B }, &f, &.{}, &.{});

    const inst = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"i64.const", inst.op);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), inst.payload);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), inst.extra);
}

test "lower: f32.const stores raw little-endian bits in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // f32.const 1.0  -> bits 0x3F800000 little-endian: 0x00 0x00 0x80 0x3F
    const body = [_]u8{ 0x43, 0x00, 0x00, 0x80, 0x3F, 0x1A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(ZirOp.@"f32.const", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0x3F800000), f.instrs.items[0].payload);
}

test "lower: f64.const splits raw bits across payload+extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // f64.const 1.0 -> bits 0x3FF0_0000_0000_0000 little-endian
    const body = [_]u8{
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
        0x1A, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    const inst = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"f64.const", inst.op);
    try testing.expectEqual(@as(u32, 0x0000_0000), inst.payload);
    try testing.expectEqual(@as(u32, 0x3FF0_0000), inst.extra);
}

test "lower: nested block records BlockInfo with patched end_inst" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);

    // (block (result i32) i32.const 7) end_block end_fn
    const body = [_]u8{ 0x02, 0x7F, 0x41, 0x07, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 1), f.blocks.items.len);
    const blk = f.blocks.items[0];
    try testing.expectEqual(BlockKind.block, blk.kind);
    try testing.expectEqual(@as(u32, 0), blk.start_inst);
    try testing.expectEqual(@as(u32, 2), blk.end_inst);

    const open = f.instrs.items[0];
    try testing.expectEqual(ZirOp.block, open.op);
    try testing.expectEqual(@as(u32, 0), open.payload);
    // extra = arity (chunk-3 encoding switch); 0x7F was a single
    // valtype, so arity = 1.
    try testing.expectEqual(@as(u32, 1), open.extra);

    const close = f.instrs.items[2];
    try testing.expectEqual(ZirOp.end, close.op);
    try testing.expectEqual(@as(u32, 0), close.payload);
}

test "lower: structref blocktype (0x6B) lowers with arity 1 (10.G cycle 144)" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // Wasm 3.0 GC §5.3.4: 0x6B = structref single-byte blocktype.
    // Pre-fix readBlockArity rejected SLEB -21 as BadBlockType (sibling
    // of validator.readBlockType). unreachable body keeps the block
    // dead so no ref.null lowering is needed — the opener still records
    // arity via readBlockArity.
    //   0x02 0x6B — block (result structref)
    //   0x00      — unreachable
    //   0x0B 0x0B — end block ; end fn
    const body = [_]u8{ 0x02, 0x6B, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    const open = f.instrs.items[0];
    try testing.expectEqual(ZirOp.block, open.op);
    // 0x6B (structref) is a single result valtype → arity 1.
    try testing.expectEqual(@as(u32, 1), open.extra);
}

test "lower: br carries depth in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // block { br 0 } end_fn
    const body = [_]u8{ 0x02, 0x40, 0x0C, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    const br = f.instrs.items[1];
    try testing.expectEqual(ZirOp.br, br.op);
    try testing.expectEqual(@as(u32, 0), br.payload);
}

test "lower: D-093 (d-1) — dead-code i32.add after br is not emitted" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);

    // Mirror of br.wast `nested-block-value`:
    //   i32.const 1
    //   block (result i32)
    //     i32.const 4
    //     i32.const 8
    //     br 0
    //     i32.add        ; dead — must NOT land in ZIR
    //   end
    //   i32.add
    //   end_fn
    const body = [_]u8{
        0x41, 0x01, // i32.const 1
        0x02, 0x7F, // block (result i32)
        0x41, 0x04, // i32.const 4
        0x41, 0x08, // i32.const 8
        0x0C, 0x00, // br 0
        0x6A, // i32.add  (dead)
        0x0B, // end (block)
        0x6A, // i32.add
        0x0B, // end_fn
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    // Expected ZIR (no dead i32.add):
    //   .@"i32.const"(1)
    //   .block(0, arity=1)
    //   .@"i32.const"(4)
    //   .@"i32.const"(8)
    //   .br(0)
    //   .end(block_idx=0)
    //   .@"i32.add"
    //   .end(function)
    try testing.expectEqual(@as(usize, 8), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[0].op);
    try testing.expectEqual(ZirOp.block, f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[3].op);
    try testing.expectEqual(ZirOp.br, f.instrs.items[4].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[5].op);
    try testing.expectEqual(ZirOp.@"i32.add", f.instrs.items[6].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[7].op);
}

test "lower: each instruction records its opcode's body offset; dead code records none" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);

    const body = [_]u8{
        0x41, 0x01, // @0  i32.const 1
        0x02, 0x7F, // @2  block (result i32)
        0x41, 0x04, // @4  i32.const 4
        0x41, 0x08, // @6  i32.const 8
        0x0C, 0x00, // @8  br 0
        0x6A, // @10 i32.add (dead)
        0x0B, // @11 end (block)
        0x6A, // @12 i32.add
        0x0B, // @13 end_fn
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqualSlices(u32, &.{ 0, 2, 4, 6, 8, 11, 12, 13 }, f.src_offsets.items);
    try testing.expectEqual(f.instrs.items.len, f.src_offsets.items.len);
}

test "lower: a prefixed opcode records the offset of its prefix byte" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);

    const body = [_]u8{
        0x43, 0x00, 0x00, 0x00, 0x00, // @0 f32.const 0
        0xFC, 0x00, // @5 i32.trunc_sat_f32_s
        0x0B, // @7 end
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqualSlices(u32, &.{ 0, 5, 7 }, f.src_offsets.items);
}

test "lower: D-093 (d-1) — nested block inside dead code emits no ZirInstrs" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    //   block
    //     br 0
    //     block (result i32)   ; dead — block + content + end skipped
    //       i32.const 7
    //     end
    //   end
    //   end_fn
    const body = [_]u8{
        0x02, 0x40, // block (empty)
        0x0C, 0x00, // br 0
        0x02, 0x7F, // block (result i32) — dead
        0x41, 0x07, // i32.const 7      — dead
        0x0B, // end (inner)      — dead
        0x0B, // end (outer)      — reachable
        0x0B, // end_fn
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    // Expected ZIR: .block, .br, .end (outer block), .end (fn).
    try testing.expectEqual(@as(usize, 4), f.instrs.items.len);
    try testing.expectEqual(ZirOp.block, f.instrs.items[0].op);
    try testing.expectEqual(ZirOp.br, f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[3].op);
    // Only the outer block lands in `blocks` — the inner dead-code
    // block contributes nothing.
    try testing.expectEqual(@as(usize, 1), f.blocks.items.len);
}

test "lower: D-093 (d-1) — else after then-arm br is reachable" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    //   block
    //     i32.const 1
    //     if (empty)
    //       br 1             ; out of block
    //       nop              ; dead
    //     else
    //       nop              ; reachable
    //     end
    //   end
    //   end_fn
    const body = [_]u8{
        0x02, 0x40, // block
        0x41, 0x01, // i32.const 1
        0x04, 0x40, // if
        0x0C, 0x01, // br 1
        0x01, // nop (dead)
        0x05, // else
        0x01, // nop (reachable)
        0x0B, // end (if)
        0x0B, // end (block)
        0x0B, // end_fn
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    // Find the two .nop slots. Only the else-arm nop should
    // land — the post-br nop in the then-arm is dead-skipped.
    var nop_count: usize = 0;
    for (f.instrs.items) |ins| {
        if (ins.op == .nop) nop_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), nop_count);
}

test "lower: local.{get,set,tee} carry index in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // local.get 3 ; local.set 1 ; local.tee 2 ; end
    const body = [_]u8{ 0x20, 0x03, 0x21, 0x01, 0x22, 0x02, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(ZirOp.@"local.get", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 3), f.instrs.items[0].payload);
    try testing.expectEqual(ZirOp.@"local.set", f.instrs.items[1].op);
    try testing.expectEqual(@as(u32, 1), f.instrs.items[1].payload);
    try testing.expectEqual(ZirOp.@"local.tee", f.instrs.items[2].op);
    try testing.expectEqual(@as(u32, 2), f.instrs.items[2].payload);
}

test "lower: if/else updates block kind to else_open" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // i32.const 1 ; if (empty) ; else ; end ; end_fn
    const body = [_]u8{ 0x41, 0x01, 0x04, 0x40, 0x05, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 1), f.blocks.items.len);
    try testing.expectEqual(BlockKind.else_open, f.blocks.items[0].kind);

    // Verify the emitted ops in order: i32.const, if, else, end (block), end (fn)
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[0].op);
    try testing.expectEqual(ZirOp.@"if", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"else", f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[3].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[4].op);
}

test "lower: NotImplemented for unknown opcode" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0xFF, 0x0B }, &f, &.{}, &.{});
    try testing.expectError(Error.NotImplemented, r);
}

test "lower: trailing bytes after function-level end fail" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0x0B, 0x00 }, &f, &.{}, &.{});
    try testing.expectError(Error.TrailingBytes, r);
}

test "lower: bad blocktype rejected" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0x02 (block) followed by 0x60 (not a valid blocktype byte for MVP)
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0x02, 0x60, 0x0B, 0x0B }, &f, &.{}, &.{});
    try testing.expectError(Error.BadBlockType, r);
}

test "lower: i32.add binop produces a single instr with no payload" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);
    // i32.const 1 ; i32.const 2 ; i32.add ; end
    const body = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 4), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.add", f.instrs.items[2].op);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[2].payload);
}

test "lower: Wasm 2.0 sat-trunc 0xFC 0..7 emit matching ZirOps" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // Eight (f-const, 0xFC <sub>, drop) triplets, then end.
    // Pattern repeats f32.const for sub-ops 0,1,4,5 and f64.const
    // for 2,3,6,7.
    const body = [_]u8{
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x1A,
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x01, 0x1A,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xFC, 0x02, 0x1A, 0x44, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x03, 0x1A,
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x04, 0x1A,
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x05, 0x1A,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xFC, 0x06, 0x1A, 0x44, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x07, 0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    // Each triplet emits 3 instrs (const, sat-trunc, drop); 8 triplets
    // + final end instr → 25 instrs total.
    try testing.expectEqual(@as(usize, 25), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f32_s", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f32_u", f.instrs.items[4].op);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f64_s", f.instrs.items[7].op);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f64_u", f.instrs.items[10].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f32_s", f.instrs.items[13].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f32_u", f.instrs.items[16].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f64_s", f.instrs.items[19].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f64_u", f.instrs.items[22].op);
}

test "lower: memory.copy (0xFC 10) emits ZirOp.memory.copy" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.copy ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x00, 0x00, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"memory.copy", f.instrs.items[3].op);
}

test "lower: memory.fill (0xFC 11) emits ZirOp.memory.fill" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0B, 0x00, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"memory.fill", f.instrs.items[3].op);
}

test "lower: memory.init (0xFC 8) emits ZirOp.memory.init with dataidx payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x05, 0x00, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const init = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"memory.init", init.op);
    try testing.expectEqual(@as(u32, 5), init.payload);
}

test "lower: table.get / table.set / table.size carry tableidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; table.get 3 ; drop ; ref.null funcref ; i32.const 0 ;
    // ref.null funcref ; table.set 4 ; table.size 5 ; drop ; end
    const body = [_]u8{
        0x41, 0x00, 0x25, 0x03, 0x1A,
        0x41, 0x00, 0xD0, 0x70, 0x26,
        0x04, 0xFC, 0x10, 0x05, 0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"table.get", f.instrs.items[1].op);
    try testing.expectEqual(@as(u32, 3), f.instrs.items[1].payload);
    try testing.expectEqual(ZirOp.@"table.set", f.instrs.items[5].op);
    try testing.expectEqual(@as(u32, 4), f.instrs.items[5].payload);
    try testing.expectEqual(ZirOp.@"table.size", f.instrs.items[6].op);
    try testing.expectEqual(@as(u32, 5), f.instrs.items[6].payload);
}

test "lower: table.grow / table.fill carry tableidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // ref.null funcref ; i32.const 1 ; table.grow 7 ; drop ; end
    const body = [_]u8{
        0xD0, 0x70, 0x41, 0x01, 0xFC, 0x0F, 0x07, 0x1A, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const grow = f.instrs.items[2];
    try testing.expectEqual(ZirOp.@"table.grow", grow.op);
    try testing.expectEqual(@as(u32, 7), grow.payload);
}

test "lower: table.init carries elemidx in payload, tableidx in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0C, 0x02, 0x07, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const init_op = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"table.init", init_op.op);
    try testing.expectEqual(@as(u32, 2), init_op.payload);
    try testing.expectEqual(@as(u32, 7), init_op.extra);
}

test "lower: elem.drop carries elemidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0x0D, 0x05, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const drop = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"elem.drop", drop.op);
    try testing.expectEqual(@as(u32, 5), drop.payload);
}

test "lower: table.copy carries dst-tableidx in payload, src in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; table.copy 3 5 ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0E, 0x03, 0x05, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const cp = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"table.copy", cp.op);
    try testing.expectEqual(@as(u32, 3), cp.payload);
    try testing.expectEqual(@as(u32, 5), cp.extra);
}

test "lower: table.fill emits table.fill with tableidx" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0xD0, 0x70, 0x41, 0x00,
        0xFC, 0x11, 0x09, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const fill = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"table.fill", fill.op);
    try testing.expectEqual(@as(u32, 9), fill.payload);
}

test "lower: select_typed (0x1C 01 0x7F) emits select_typed with reftype byte in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00,
        0x41, 0x00,
        0x41, 0x00,
        0x1C, 0x01,
        0x7F, 0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const sel = f.instrs.items[3];
    try testing.expectEqual(ZirOp.select_typed, sel.op);
    try testing.expectEqual(@as(u32, 0x7F), sel.extra);
}

test "lower: select_typed with count != 1 → UnexpectedOpcode" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0x1C, 0x02, 0x7F, 0x7F, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectError(Error.UnexpectedOpcode, r);
}

test "lower: ref.null (0xD0 0x70) emits ZirOp.ref.null with reftype byte in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD0, 0x70, 0x1A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const rn = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"ref.null", rn.op);
    try testing.expectEqual(@as(u32, 0x70), rn.extra);
}

test "lower: ref.is_null (0xD1) emits a no-immediate instr" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD0, 0x70, 0xD1, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"ref.is_null", f.instrs.items[1].op);
}

test "lower: ref.func (0xD2) carries funcidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD2, 0x09, 0x1A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const rf = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"ref.func", rf.op);
    try testing.expectEqual(@as(u32, 9), rf.payload);
}

test "lower: ref.null with bad reftype byte → BadBlockType" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD0, 0x55, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectError(Error.BadBlockType, r);
}

test "lower: data.drop (0xFC 9) emits ZirOp.data.drop with dataidx payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0x09, 0x07, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    const drop = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"data.drop", drop.op);
    try testing.expectEqual(@as(u32, 7), drop.payload);
}

test "lower: memory.copy with non-zero memidx packs dst/src into payload/extra (10.M cycle 67)" {
    // Pre-cycle-67: lower rejected non-zero memidx with BadBlockType
    // (reserved-byte semantics). Post-cycle-67: the bytes are LEB-
    // decoded as dst_memidx + src_memidx and packed into the
    // emitted ZirInstr's payload / extra fields (Wasm 3.0 multi-
    // memory proposal). The body below is `memory.copy dst=0 src=1`.
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0x0A, 0x00, 0x01, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    // The single emitted instr is `memory.copy` with payload=0, extra=1.
    try testing.expect(f.instrs.items.len >= 1);
    const mc = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"memory.copy", mc.op);
    try testing.expectEqual(@as(u64, 0), mc.payload);
    try testing.expectEqual(@as(u32, 1), mc.extra);
}

test "lower: 0xFC unknown sub-opcode → NotImplemented" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0xFF, 0x01, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectError(Error.NotImplemented, r);
}

test "lower: Wasm 2.0 sign-ext opcodes 0xC0..0xC4 emit matching ZirOps" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; i32.extend8_s ; drop
    // i32.const 0 ; i32.extend16_s ; drop
    // i64.const 0 ; i64.extend8_s ; drop
    // i64.const 0 ; i64.extend16_s ; drop
    // i64.const 0 ; i64.extend32_s ; drop
    // end
    const body = [_]u8{
        0x41, 0x00, 0xC0, 0x1A,
        0x41, 0x00, 0xC1, 0x1A,
        0x42, 0x00, 0xC2, 0x1A,
        0x42, 0x00, 0xC3, 0x1A,
        0x42, 0x00, 0xC4, 0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(ZirOp.@"i32.extend8_s", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"i32.extend16_s", f.instrs.items[4].op);
    try testing.expectEqual(ZirOp.@"i64.extend8_s", f.instrs.items[7].op);
    try testing.expectEqual(ZirOp.@"i64.extend16_s", f.instrs.items[10].op);
    try testing.expectEqual(ZirOp.@"i64.extend32_s", f.instrs.items[13].op);
}

test "lower: multivalue block via s33 typeidx — extra = arity (#results)" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // module_types[0] = ([] -> [i32, i32, i32])
    const empty_arr = [_]ValType{};
    const triple = [_]ValType{ .i32, .i32, .i32 };
    const types = [_]FuncType{.{ .params = &empty_arr, .results = &triple }};
    // block (typeidx 0) ; end ; end
    const body = [_]u8{ 0x02, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &types, &.{});

    const open = f.instrs.items[0];
    try testing.expectEqual(ZirOp.block, open.op);
    try testing.expectEqual(@as(u32, 3), open.extra);
}

test "lower: multivalue block typeidx with non-empty params lowers (D-035 chunk-d035-a)" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const i32_arr_local = [_]ValType{.i32};
    const types = [_]FuncType{.{ .params = &i32_arr_local, .results = &i32_arr_local }};
    const body = [_]u8{ 0x02, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &types, &.{});
    // D-093 (d-6): extra now packs both arities — high byte =
    // param_arity, low byte = result_arity. For this typeidx
    // (params = [i32], results = [i32]), expect (1<<8)|1 = 257.
    try testing.expectEqual(ZirOp.block, f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, (1 << 8) | 1), f.instrs.items[0].extra);
}

// ============================================================
// §9.9 / 9.4 — SIMD-128 prefix-`0xFD` lower tests
// (per ADR-0041). Mirrors the validator's 9.3 catalogue and
// ensures emitted ZirOps + payloads match the spec sub-opcode
// → ZirOp mapping.
// ============================================================

test "lower (simd): v128.const records 16-byte immediate via simd_consts pool" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x0C [16 bytes] 0x0B
    var body: [19]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0C;
    @memset(body[2..18], 0x42); // recognisable pattern
    body[18] = 0x0B;
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"v128.const", f.instrs.items[0].op);
    // Payload per ADR-0042 = index into func.simd_consts pool.
    try testing.expectEqual(@as(u32, 0), f.instrs.items[0].payload);
    // simd_consts[0] is the 16-byte literal copied from body bytes [2..18].
    try testing.expect(f.simd_consts != null);
    try testing.expectEqual(@as(usize, 1), f.simd_consts.?.len);
    for (f.simd_consts.?[0]) |b| try testing.expectEqual(@as(u8, 0x42), b);
}

test "lower (simd): v128.load passes memarg through emitMemarg" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x00 align=4 offset=0x10 0x0B
    const body = [_]u8{ 0xFD, 0x00, 0x04, 0x10, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"v128.load", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0x10), f.instrs.items[0].payload); // offset
    // pack(align=4, memidx=0) = (0 << 5) | 4 = 4 (legacy single-memory)
    const ex = zir.MemArgExtra.unpack(f.instrs.items[0].extra);
    try testing.expectEqual(@as(u5, 4), ex.align_pow2);
    try testing.expectEqual(@as(u8, 0), ex.memidx);
}

test "lower (memarg): bit-6 align flag carries explicit memidx (Wasm 3.0 §5.4.6)" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.load with align uleb = 0x42 (= 0x40 | 2 → memidx LEB follows;
    // effective align=2); memidx=1; offset=0x08
    const body = [_]u8{ 0x28, 0x42, 0x01, 0x08, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"i32.load", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0x08), f.instrs.items[0].payload);
    const ex = zir.MemArgExtra.unpack(f.instrs.items[0].extra);
    try testing.expectEqual(@as(u5, 2), ex.align_pow2);
    try testing.expectEqual(@as(u8, 1), ex.memidx);
}

test "lower (memarg): align without bit-6 → implicit memidx=0" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.store align=2 offset=0 (no memidx LEB)
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x36, 0x02, 0x00, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    // instr[2] is the store (after two const ops)
    try testing.expectEqual(ZirOp.@"i32.store", f.instrs.items[2].op);
    const ex = zir.MemArgExtra.unpack(f.instrs.items[2].extra);
    try testing.expectEqual(@as(u5, 2), ex.align_pow2);
    try testing.expectEqual(@as(u8, 0), ex.memidx);
}

test "lower (memarg): align > 31 → Error.BadMemarg" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.load align=32 (= 0x20; without bit-6 flag); offset=0
    const body = [_]u8{ 0x28, 0x20, 0x00, 0x0B };
    try testing.expectError(error.BadMemarg, lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{}));
}

test "lower (simd): v128.store routes via emitMemarg" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFD, 0x0B, 0x00, 0x00, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"v128.store", f.instrs.items[0].op);
}

test "lower (simd): i32x4.splat emits without payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x11 (sub 17) 0x0B
    const body = [_]u8{ 0xFD, 0x11, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"i32x4.splat", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[0].payload);
}

test "lower (simd): all 6 splat shapes resolve to distinct ZirOps" {
    const cases = [_]struct { sub: u8, op: ZirOp }{
        .{ .sub = 15, .op = .@"i8x16.splat" },
        .{ .sub = 16, .op = .@"i16x8.splat" },
        .{ .sub = 17, .op = .@"i32x4.splat" },
        .{ .sub = 18, .op = .@"i64x2.splat" },
        .{ .sub = 19, .op = .@"f32x4.splat" },
        .{ .sub = 20, .op = .@"f64x2.splat" },
    };
    for (cases) |c| {
        var f = newFunc(empty_sig);
        defer f.deinit(testing.allocator);
        const body = [_]u8{ 0xFD, c.sub, 0x0B };
        try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
        try testing.expectEqual(c.op, f.instrs.items[0].op);
    }
}

test "lower (simd): i32x4.extract_lane stores lane byte in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x1B (sub 27 = i32x4.extract_lane) lane=2 0x0B
    const body = [_]u8{ 0xFD, 0x1B, 0x02, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"i32x4.extract_lane", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 2), f.instrs.items[0].payload);
}

test "lower (simd): i8x16.shuffle records immediate via simd_consts pool" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    var body: [19]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0D;
    var i: usize = 0;
    while (i < 16) : (i += 1) body[2 + i] = @intCast(i); // lanes 0..15 (all < 32)
    body[18] = 0x0B;
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"i8x16.shuffle", f.instrs.items[0].op);
    // Payload per ADR-0042 = index into func.simd_consts pool.
    try testing.expectEqual(@as(u32, 0), f.instrs.items[0].payload);
    try testing.expect(f.simd_consts != null);
    try testing.expectEqual(@as(usize, 1), f.simd_consts.?.len);
    for (f.simd_consts.?[0], 0..) |b, idx| try testing.expectEqual(@as(u8, @intCast(idx)), b);
}

test "lower (simd): i8x16.shuffle rejects lane >= 32" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    var body: [19]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0D;
    @memset(body[2..18], 0);
    body[10] = 32; // out-of-range lane
    body[18] = 0x0B;
    try testing.expectError(Error.BadBlockType, lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{}));
}

test "lower (simd): v128.const truncated immediate fails" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x0C followed by 8 bytes (truncated) + 0x0B
    var body: [11]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0C;
    @memset(body[2..10], 0);
    body[10] = 0x0B;
    try testing.expectError(Error.UnexpectedEnd, lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{}));
}

test "lower (simd): unknown 0xFD sub-opcode → NotImplemented" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD with sub 276 (0x94 0x02 LEB128) — beyond the relaxed-simd range
    // (≤275), genuinely unmapped. (Was 250 = f32x4.convert_i32x4_s, now lowered
    // per D-457.)
    const body = [_]u8{ 0xFD, 0x94, 0x02, 0x0B };
    try testing.expectError(Error.NotImplemented, lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{}));
}

// Wasm 3.0 EH try_table catch-metadata lowering (10.E-5a).

test "lower (try_table): empty catch vec → LandingPad with empty catch slice" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // try_table () (count=0) end ; end_fn
    const body = [_]u8{ 0x1F, 0x40, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expect(f.eh_landing_pads != null);
    try testing.expectEqual(@as(usize, 1), f.eh_landing_pads.?.len);
    const lp = f.eh_landing_pads.?[0];
    try testing.expectEqual(@as(u32, 0), lp.block_idx);
    try testing.expectEqual(@as(u32, 0), lp.catches_start);
    try testing.expectEqual(@as(u32, 0), lp.catches_end);
    try testing.expect(f.eh_catch_entries == null);
}

test "lower (try_table): catch + catch_all vec stored in eh_catch_entries" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // try_table () count=2
    //   0x00 catch tag_idx=7 label_idx=0
    //   0x02 catch_all label_idx=1
    // end ; end_fn
    //
    // Outer label_idx=1 is the function frame; outer 0 is the
    // try_table itself. Validator label-range checks are not
    // enforced at lower time, so this body lowers regardless.
    const body = [_]u8{ 0x1F, 0x40, 0x02, 0x00, 0x07, 0x00, 0x02, 0x01, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 1), f.eh_landing_pads.?.len);
    const lp = f.eh_landing_pads.?[0];
    try testing.expectEqual(@as(u32, 0), lp.catches_start);
    try testing.expectEqual(@as(u32, 2), lp.catches_end);

    try testing.expect(f.eh_catch_entries != null);
    try testing.expectEqual(@as(usize, 2), f.eh_catch_entries.?.len);

    const c0 = f.eh_catch_entries.?[0];
    try testing.expectEqual(zir.CatchKind.catch_, c0.kind);
    try testing.expectEqual(@as(u32, 7), c0.tag_idx);
    try testing.expectEqual(@as(u32, 0), c0.label_idx);

    const c1 = f.eh_catch_entries.?[1];
    try testing.expectEqual(zir.CatchKind.catch_all, c1.kind);
    try testing.expectEqual(@as(u32, 0), c1.tag_idx);
    try testing.expectEqual(@as(u32, 1), c1.label_idx);
}

test "lower (try_table): catch_ref + catch_all_ref kinds preserved" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // try_table () count=2 (catch_ref 3 0) (catch_all_ref 0) end ; end_fn
    const body = [_]u8{ 0x1F, 0x40, 0x02, 0x01, 0x03, 0x00, 0x03, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 2), f.eh_catch_entries.?.len);
    try testing.expectEqual(zir.CatchKind.catch_ref, f.eh_catch_entries.?[0].kind);
    try testing.expectEqual(@as(u32, 3), f.eh_catch_entries.?[0].tag_idx);
    try testing.expectEqual(zir.CatchKind.catch_all_ref, f.eh_catch_entries.?[1].kind);
    try testing.expectEqual(@as(u32, 0), f.eh_catch_entries.?[1].tag_idx);
}

test "lower (try_table): nested try_tables get distinct LandingPads with flat catch entries" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // try_table () count=1 (catch_all 1)
    //   try_table () count=1 (catch_all 0)
    //   end
    // end ; end_fn
    const body = [_]u8{
        0x1F, 0x40, 0x01, 0x02, 0x01,
        0x1F, 0x40, 0x01, 0x02, 0x00,
        0x0B, 0x0B, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});

    try testing.expectEqual(@as(usize, 2), f.eh_landing_pads.?.len);
    // Outer try_table is appended first; inner second.
    const outer = f.eh_landing_pads.?[0];
    const inner = f.eh_landing_pads.?[1];
    try testing.expectEqual(@as(u32, 0), outer.block_idx);
    try testing.expectEqual(@as(u32, 1), inner.block_idx);
    try testing.expectEqual(@as(u32, 0), outer.catches_start);
    try testing.expectEqual(@as(u32, 1), outer.catches_end);
    try testing.expectEqual(@as(u32, 1), inner.catches_start);
    try testing.expectEqual(@as(u32, 2), inner.catches_end);

    try testing.expectEqual(@as(usize, 2), f.eh_catch_entries.?.len);
    try testing.expectEqual(@as(u32, 1), f.eh_catch_entries.?[0].label_idx);
    try testing.expectEqual(@as(u32, 0), f.eh_catch_entries.?[1].label_idx);
}

test "lower (try_table): malformed catch kind rejected" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // try_table () count=1 kind=0x05 (invalid)
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x05, 0x00, 0x0B, 0x0B };
    try testing.expectError(Error.BadBlockType, lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{}));
}

// 10.M-5b: SIMD lane-memarg with Wasm 3.0 bit-6 memidx encoding.

test "lower (simd): v128.load8_lane with bit-6 memidx — memidx is decoded-and-discarded" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x54 (load8_lane sub-opcode) align=0x40 (= bit-6 set, effective 0)
    // memidx=0 offset=0x08 lane=3 end
    const body = [_]u8{ 0xFD, 0x54, 0x40, 0x00, 0x08, 0x03, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"v128.load8_lane", f.instrs.items[0].op);
    // payload = offset (memidx discarded; lane variants' extra holds lane byte)
    try testing.expectEqual(@as(u32, 0x08), f.instrs.items[0].payload);
    // extra = lane byte (= 3).
    try testing.expectEqual(@as(u32, 3), f.instrs.items[0].extra);
}

test "lower (simd): v128.store32_lane without bit-6 → legacy 2-uleb shape still works" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x5A (store32_lane sub-opcode) align=2 offset=0x10 lane=1 end
    const body = [_]u8{ 0xFD, 0x5A, 0x02, 0x10, 0x01, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"v128.store32_lane", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0x10), f.instrs.items[0].payload);
    try testing.expectEqual(@as(u32, 1), f.instrs.items[0].extra);
}

test "lower (simd): v128.load64_lane with bit-6 + non-zero memidx — memidx decoded-and-discarded" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0xFD 0x57 (load64_lane sub-opcode) align=0x43 (= bit-6 | 3) memidx=2 offset=0 lane=0 end
    const body = [_]u8{ 0xFD, 0x57, 0x43, 0x02, 0x00, 0x00, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{}, &.{});
    try testing.expectEqual(ZirOp.@"v128.load64_lane", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[0].payload);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[0].extra);
}
