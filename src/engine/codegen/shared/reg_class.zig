//! Per-class register-class invariants (Zone 2).
//!
//! `zir.RegClass` (Zone 1) names the classes; this module owns
//! the per-class invariants the regalloc consults independently
//! of the physical register inventory (which is per-arch and
//! lives in `src/jit_<arch>/abi.zig`, Phase 7.2). The 3-way
//! split is the W54-class lesson made structural — folding any
//! two of "class identity / per-class invariants / physical
//! register inventory" together is what produced v1's D117
//! dual-entry-self-call workaround.
//!
//! Phase 7.0 scope: name the classes (in zir.zig — done with
//! D-014 refinement) + supply the lookup table here. Real
//! register tables land at 7.2; the regalloc that consumes
//! both lands at 7.1.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");

pub const RegClass = zir.RegClass;

/// Per-class invariants the regalloc consults independently of
/// per-arch register inventory.
///
/// - `width_bits` is the value width the class holds (operand
///   width during emit; spill slot stride during spilling).
///   GPR / FPR are 64-bit on the targeted ARM64 / x86_64 ABIs;
///   SIMD is the 128-bit V/X register.
///
/// - `spill_align_bytes` is the alignment a spill slot for this
///   class must satisfy — distinct from `width_bits` because
///   SIMD's natural alignment can be tighter than its width on
///   some ABIs (here we keep alignment == width / 8 since both
///   target ABIs honour that).
///
/// - `is_special_cache` is the W54-class flag. When true, the
///   regalloc must treat the slot as a per-function-or-better
///   live range that survives across calls without per-callsite
///   save/restore — the "live range is the slot itself" model
///   from the W54 post-mortem. The per-arch ABI then nails the
///   slot to a specific physical register; the regalloc must
///   not re-assign it.
pub const RegClassInfo = struct {
    width_bits: u16,
    spill_align_bytes: u8,
    is_special_cache: bool,
};

/// Table indexed by `@intFromEnum(class)`. Indexed access keeps
/// the regalloc inner loop branch-free; the order MUST match
/// the variant declaration order in `zir.RegClass`. The
/// trailing `_` non-exhaustive sentinel in `RegClass` is not
/// represented here — `info()` returns null for it so callers
/// can prove "we cover every named class" at the regalloc layer.
const info_table = [_]RegClassInfo{
    // gpr — 64-bit general-purpose; ARM64 X-registers, x86_64 R-registers.
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = false },
    // fpr — 64-bit FP scalar; ARM64 D-registers, x86_64 XMM low half.
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = false },
    // simd — 128-bit SIMD; ARM64 V-registers (full), x86_64 XMM full.
    .{ .width_bits = 128, .spill_align_bytes = 16, .is_special_cache = false },
    // inst_ptr_special — the inst_ptr cache (W54 / D117 lesson).
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = true },
    // vm_ptr_special — the runtime base pointer.
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = true },
    // simd_base_special — the SIMD-lane base pointer (Phase 9+).
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = true },
};

// Compile-time check that the table entry count matches the
// number of named variants in `RegClass`. If a variant is
// added or removed, this assertion forces the table edit at
// the same compile, preventing the W54-class drift between
// "class declared" and "class invariants known".
comptime {
    const named_count = @typeInfo(RegClass).@"enum".field_names.len;
    if (info_table.len != named_count) {
        @compileError("info_table length must match the number of named RegClass variants");
    }
}

/// Look up the per-class invariants. Returns null for the
/// non-exhaustive `_` placeholder (i.e. an out-of-range future
/// variant added without a corresponding info entry — caught at
/// runtime since the comptime block above guards against
/// in-tree drift).
pub fn info(class: RegClass) ?RegClassInfo {
    const idx = @backingInt(class);
    if (idx >= info_table.len) return null;
    return info_table[idx];
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "info: every named RegClass variant resolves" {
    const ti = @typeInfo(RegClass).@"enum";
    inline for (ti.field_names, ti.field_values) |f_name, f_value| {
        const class: RegClass = @fromBackingInt(@intCast(f_value));
        const got = info(class) orelse {
            std.debug.print("missing info for variant {s}\n", .{f_name});
            return error.MissingInfo;
        };
        try testing.expect(got.width_bits >= 64);
        try testing.expect(got.spill_align_bytes >= 8);
    }
}

test "info: special-cache flag set exactly for the three *_special variants" {
    try testing.expect(!info(.gpr).?.is_special_cache);
    try testing.expect(!info(.fpr).?.is_special_cache);
    try testing.expect(!info(.simd).?.is_special_cache);
    try testing.expect(info(.inst_ptr_special).?.is_special_cache);
    try testing.expect(info(.vm_ptr_special).?.is_special_cache);
    try testing.expect(info(.simd_base_special).?.is_special_cache);
}

test "info: SIMD class is the only 128-bit width" {
    var simd_count: u8 = 0;
    inline for (@typeInfo(RegClass).@"enum".field_values) |f_value| {
        const got = info(@fromBackingInt(@intCast(f_value))).?;
        if (got.width_bits == 128) simd_count += 1;
    }
    try testing.expectEqual(@as(u8, 1), simd_count);
}
