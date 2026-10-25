//! Transparent on-disk compilation cache (ADR-0203 D5 / D-508).
//!
//! `zwasm run --cache[=DIR] x.wasm` keys the module by content hash and
//! reuses the `.cwasm` artifact a previous run produced — a cache HIT skips
//! parse/validate/codegen entirely and loads through the SAME full-fidelity
//! path as `zwasm run x.cwasm` (cache-hit == cache-miss by construction,
//! ADR-0203 D2; measured cold-start tax ~110 ms on 3 MB Go modules).
//!
//! Layout (the wazero model — versioned dir, no config hash: the
//! codegen-affecting knobs live in the directory name, so a version / arch /
//! OS / bounds-mode change makes old entries silently unreachable). Caveat:
//! dev builds between releases share the version string; `--cache-clear` is
//! the escape hatch (format-version drift is caught by the entry gate below).
//!
//!   <root>/zwasm-<version>-<arch>-<os>-<bounds>/<sha256-hex>.cwasm
//!
//! Failure discipline (ADR-0203 D5): ANY cache-side defect degrades — a
//! read failure or an entry failing the cheap gate (header magic / format
//! version / arch / section bounds) is a MISS (the bad entry is deleted,
//! self-heal); a store failure only loses the next run's speedup. The cache
//! can never make `run` fail. Writes go to a unique temp sibling then
//! atomic-rename, so a reader never sees a partially-written entry.
//! Eviction v1 = none; `zwasm run --cache-clear` deletes this build's
//! versioned subdirectory only.
//!
//! Trust model (the wasmtime/wazero posture): entries are native code
//! executed as the user — write access to the cache directory means
//! arbitrary code execution. User-owned dir (0755/644 via umask), no
//! content integrity beyond the entry gate; point `--cache=DIR` only at
//! trusted locations.
//!
//! Zone 3 (`src/cli/`).

const std = @import("std");
const builtin = @import("builtin");

const zwasm = @import("zwasm");
const runner = @import("../engine/runner.zig");
const produce = @import("../engine/codegen/aot/produce.zig");
const format = @import("../engine/codegen/aot/format.zig");
const limits = @import("limits.zig");

/// `zwasm-<version>-<arch>-<os>-<bounds>` — the versioned cache
/// subdirectory. Bounds mode is the one codegen knob not implied by the
/// binary itself (`--engine`-independent; process-global, ADR-0202).
pub fn subdirName(buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "zwasm-{s}-{s}-{s}-{s}", .{
        zwasm.version,
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(runner.boundsChecksMode()),
    });
}

/// SHA-256 of the module bytes, lowercase hex — the cache key. Content
/// hash only: everything else that affects codegen is in `subdirName`.
pub fn keyHex(wasm_bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wasm_bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Return `.cwasm` artifact bytes for `wasm_bytes` — from the cache when
/// present, otherwise compile + produce + best-effort store. Caller owns
/// the returned slice. Only compile/produce errors propagate; cache I/O
/// failures degrade to miss/no-store per the module doc.
pub fn lookupOrProduce(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    wasm_bytes: []const u8,
) ![]u8 {
    var sub_buf: [96]u8 = undefined;
    const sub = try subdirName(&sub_buf);
    const key = keyHex(wasm_bytes);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}.cwasm", .{ root, sub, &key });
    defer gpa.free(path);
    const cwd = std.Io.Dir.cwd();

    // HIT — but only after the cheap entry gate (header + section bounds):
    // a corrupt / truncated / format-drifted entry is DELETED (self-heal)
    // and degrades to a miss, never to a failed run (ADR-0203 D5).
    if (cwd.readFileAlloc(io, path, gpa, .limited(limits.max_file_bytes))) |cached| {
        if (entryIsValid(cached)) return cached;
        gpa.free(cached);
        cwd.deleteFile(io, path) catch {
            // EXEMPT-FALLBACK: self-heal delete is best-effort (ADR-0203 D5);
            // the fresh compile below re-stores over the bad entry anyway.
        };
    } else |_| {
        // EXEMPT-FALLBACK: cache read failure = MISS by design (ADR-0203 D5
        // — the cache can never make `run` fail); we fall through to a
        // fresh compile below.
    }

    // MISS — fresh compile + produce (errors here are the caller's).
    var compiled = try runner.compileWasmForAot(gpa, wasm_bytes);
    const cwasm = blk: {
        defer compiled.deinit(gpa);
        break :blk try produce.produceFromCompiledWasm(gpa, &compiled, wasm_bytes);
    };
    errdefer gpa.free(cwasm);

    // Best-effort store: mkdir -p + temp write + atomic rename. An artifact
    // above the read cap is skipped — it could never be hit back.
    if (cwasm.len <= limits.max_file_bytes) store(gpa, io, root, sub, &key, cwasm) catch {
        // EXEMPT-FALLBACK: cache write failure only loses the speedup for
        // the NEXT run (ADR-0203 D5); this run proceeds with the artifact.
    };
    return cwasm;
}

/// Cheap HIT gate (ADR-0203 D5): header parses (magic / format version /
/// arch matches this binary) and every section lies inside the file — so a
/// corrupt, truncated, or format-drifted entry degrades to a miss WITHOUT
/// paying the full deserialize. Content beyond that stays the run path's
/// business (same trust boundary as running a `.cwasm` directly).
fn entryIsValid(cwasm: []const u8) bool {
    const h = format.parseHeader(cwasm) catch return false;
    const want_arch: u32 = switch (builtin.target.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => return false,
    };
    if (h.arch != want_arch) return false;
    const sections = [_][2]u32{
        .{ h.code_offset, h.code_size },
        .{ h.metadata_offset, h.metadata_size },
        .{ h.types_offset, h.types_size },
        .{ h.relocs_offset, h.relocs_size },
        .{ h.exports_offset, h.exports_size },
        .{ h.globals_offset, h.globals_size },
        .{ h.memory_init_offset, h.memory_init_size },
        .{ h.elem_offset, h.elem_size },
        .{ h.imports_offset, h.imports_size },
        .{ h.wasm_bytes_offset, h.wasm_bytes_size },
        .{ h.func_extras_offset, h.func_extras_size },
        .{ h.eh_offset, h.eh_size },
    };
    for (sections) |s| {
        if (@as(u64, s[0]) + s[1] > cwasm.len) return false;
    }
    return true;
}

fn store(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    sub: []const u8,
    key: *const [64]u8,
    cwasm: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, sub });
    defer gpa.free(dir_path);
    try cwd.createDirPath(io, dir_path);
    // Unique temp name per writer: with a SHARED temp path, P1's atomic
    // rename could publish P2's partially-written bytes to a third reader.
    // Random suffix keeps writers disjoint; rename is atomic on POSIX + NTFS
    // and concurrent finals carry identical content (key = content hash).
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}/{s}.{x:0>16}.tmp", .{
        dir_path, key, std.mem.readInt(u64, &rnd, .little),
    });
    defer gpa.free(tmp_path);
    const final_path = try std.fmt.allocPrint(gpa, "{s}/{s}.cwasm", .{ dir_path, key });
    defer gpa.free(final_path);
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = cwasm });
    errdefer cwd.deleteFile(io, tmp_path) catch {
        // EXEMPT-FALLBACK: temp-file cleanup after a failed rename is
        // best-effort (ADR-0203 D5); a stray .tmp is inert garbage.
    };
    try cwd.rename(tmp_path, cwd, final_path, io);
}

/// `--cache-clear`: delete THIS build's versioned subdirectory (other
/// versions' entries are other builds' business).
pub fn clear(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    var sub_buf: [96]u8 = undefined;
    const sub = try subdirName(&sub_buf);
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, sub });
    defer gpa.free(dir_path);
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {
        // EXEMPT-FALLBACK: nothing to clear / already gone is success for
        // `--cache-clear` (idempotent; ADR-0203 D5).
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "cache: subdirName carries version, arch, os, and bounds mode" {
    var buf: [96]u8 = undefined;
    const sub = try subdirName(&buf);
    try testing.expect(std.mem.startsWith(u8, sub, "zwasm-"));
    try testing.expect(std.mem.find(u8, sub, zwasm.version) != null);
    try testing.expect(std.mem.find(u8, sub, @tagName(builtin.target.cpu.arch)) != null);
    try testing.expect(std.mem.endsWith(u8, sub, @tagName(runner.boundsChecksMode())));
}

test "cache: keyHex is a stable content hash" {
    const a = keyHex("hello");
    const b = keyHex("hello");
    const c = keyHex("hellp");
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expect(!std.mem.eql(u8, &a, &c));
}

test "cache: miss produces + stores; hit returns identical artifact bytes; corrupt entry degrades to miss" {
    // `() -> i32` returning 42, exported "f".
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
        0x2a, 0x0b,
    };
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/cache-test-root";
    // EXEMPT-FALLBACK: test-scratch cleanup — absent tree == already clean (ADR-0203 D5).
    cwd.deleteTree(io, root) catch {};
    // EXEMPT-FALLBACK: test-scratch cleanup — absent tree == already clean (ADR-0203 D5).
    defer cwd.deleteTree(io, root) catch {};

    // MISS: compile + store.
    const first = try lookupOrProduce(testing.allocator, io, root, &wasm);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.eql(u8, first[0..4], "CWAS"));

    // The entry landed at the expected path.
    var sub_buf: [96]u8 = undefined;
    const sub = try subdirName(&sub_buf);
    const key = keyHex(&wasm);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}/{s}.cwasm", .{ root, sub, &key });
    defer testing.allocator.free(path);
    const stored = try cwd.readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(stored);
    try testing.expectEqualSlices(u8, first, stored);

    // HIT: byte-identical artifact without recompiling.
    const second = try lookupOrProduce(testing.allocator, io, root, &wasm);
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);

    // Corrupt entries degrade to a self-healed MISS (ADR-0203 D5 — the
    // cache can never make `run` fail): each shape must come back as the
    // recompiled, byte-identical artifact AND leave a healed entry on disk.
    const corrupt_shapes = [_][]const u8{
        "CWASgarbage", // magic ok, header truncated
        &@as([200]u8, @splat(0)), // no magic at all
        first[0 .. first.len / 2], // valid header, truncated body
    };
    for (corrupt_shapes) |shape| {
        try cwd.writeFile(io, .{ .sub_path = path, .data = shape });
        const healed = try lookupOrProduce(testing.allocator, io, root, &wasm);
        defer testing.allocator.free(healed);
        try testing.expectEqualSlices(u8, first, healed);
        const on_disk = try cwd.readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(on_disk);
        try testing.expectEqualSlices(u8, first, on_disk);
    }

    // --cache-clear removes the versioned subdir; the next lookup is a miss
    // that recompiles and restores the entry.
    try clear(testing.allocator, io, root);
    try testing.expectError(error.FileNotFound, cwd.readFileAlloc(io, path, testing.allocator, .limited(1 << 20)));
    const third = try lookupOrProduce(testing.allocator, io, root, &wasm);
    defer testing.allocator.free(third);
    try testing.expectEqualSlices(u8, first, third);
}
