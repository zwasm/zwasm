// DBG-INIT-EXEMPT: addTest target in build.zig — only the in-file test blocks run; this main is never executed.
//! EH frequency runner skeleton (10.T-3; benchmark scaffolding
//! pending Phase 8b).
//!
//! Per Phase 10 design plan §3.4 — sweeps the throw-rate ×
//! catch-depth matrix to verify try_table 0-byte emit (ADR-0114
//! §"Context" invariant 2) does not regress the non-throwing
//! fast path.
//!
//! Matrix:
//!
//!   throw_rate ∈ {0%, 1%, 50%, 100%}
//!   catch_depth ∈ {1, 10, 100}
//!
//! Pass criteria:
//!   - 0% throw_rate: latency matches baseline within 1%
//!     (try_table costs ZERO in fast path per ADR-0114 §"Decision" D3)
//!   - 100% throw_rate: throw → FP-walk unwind → catch is bounded
//!     by catch_depth × O(frame-chain-walk)
//!
//! Status (2026-05-28): **EH codegen shipped** across the
//! 10.E-payload-prop bundle + D-181/D-182/D-183/D-184 cycles
//! (single-frame + cross-frame + multi-frame + payload + multi-
//! catch all green on Mac aarch64 + Linux x86_64 SysV per
//! `src/engine/runner.zig` regression tests). What's still
//! pending is the **benchmark scaffolding**: per-cell module
//! generation, latency measurement harness, baseline comparison
//! against the non-EH `bench/results/history.yaml`. That work
//! belongs at Phase 8b (bench infra; ADR-0012 §3) per design
//! plan §3.4 — NOT at Phase 10 (impl). Until then, this runner
//! reports SKIP-P10-EH-BENCH-GAP per cell + exits 0 so test-all
//! stays green regardless.
//!
//! Per ROADMAP §10 / 10.T-3 + design plan §3.4 "test strategy".

const std = @import("std");

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

const ThrowRate = enum { p0, p1, p50, p100 };
const CatchDepth = enum(u32) { d1 = 1, d10 = 10, d100 = 100 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("[eh_frequency_runner] skeleton (EH codegen SHIPPED 2026-05-28; benchmark scaffolding pending Phase 8b)\n", .{});
    inline for (.{ ThrowRate.p0, .p1, .p50, .p100 }) |rate| {
        inline for (.{ CatchDepth.d1, .d10, .d100 }) |depth| {
            try stdout.print("  [SKIP-P10-EH-BENCH-GAP] throw_rate={s} catch_depth={d} — awaits Phase 8b bench infra (ADR-0012 §3 + design plan §3.4)\n", .{ @tagName(rate), @intFromEnum(depth) });
        }
    }
    try stdout.flush();
}

test "eh_frequency_runner: matrix enumerates 4 throw_rate × 3 catch_depth = 12 cells" {
    var count: usize = 0;
    inline for (.{ ThrowRate.p0, .p1, .p50, .p100 }) |_| {
        inline for (.{ CatchDepth.d1, .d10, .d100 }) |_| {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 12), count);
}
