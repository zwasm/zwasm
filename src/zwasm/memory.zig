//! `Memory` — typed view onto an instance's linear memory per
//! ADR-0109 §3.4 + `docs/zig_api_design.md` §3.4.
//!
//! Wraps the runtime's flat `memory: []u8` slice (Wasm spec §4.2.8)
//! so Zig hosts can read / write typed scalars through it without
//! going through `wasm_memory_t*`. v0.1 scope: scalar integer
//! read / write + raw byte slice. `grow` and v128 lane access
//! land in J.5+ (`docs/zig_api_design.md` §3.4 / Phase 10.M).

const std = @import("std");

const _runtime = @import("../runtime/runtime.zig");
const _runner = @import("../engine/runner.zig"); // ADR-0200 JIT engine (Zone 2; `lib`-exempt)

pub const Memory = struct {
    /// Engine the view reads through (ADR-0200 increment 5). Interp wraps
    /// the `*Runtime`'s flat slice; JIT reads the live `vm_base`/`mem_limit`
    /// pair on `JitInstance.owned.rt`, which `growMemory` keeps in sync.
    backing: Backing,

    pub const Backing = union(enum) {
        interp: *_runtime.Runtime,
        jit: *_runner.JitInstance,
    };

    pub const Error = error{ OutOfBoundsLoad, OutOfBoundsStore };

    /// Current linear-memory bytes for whichever engine backs this view.
    fn liveBytes(self: Memory) []u8 {
        return switch (self.backing) {
            .interp => |rt| rt.memory,
            .jit => |jit| jit.owned.rt.vm_base[0..jit.owned.rt.mem_limit],
        };
    }

    /// Wasm spec §4.2.8 — returns the raw underlying byte slice.
    /// Lifetime ties to the owning `Instance`.
    pub fn slice(self: Memory) []u8 {
        return self.liveBytes();
    }

    /// Wasm spec §4.4.7 — page size 65536 bytes.
    pub fn size(self: Memory) u32 {
        return @intCast(self.liveBytes().len / 65536);
    }

    /// Wasm spec §4.4.7 (memory.load) — little-endian typed read.
    /// Supported `T`: i8 / u8 / i16 / u16 / i32 / u32 / i64 / u64 /
    /// f32 / f64. The float types round-trip via bit-cast (no NaN
    /// canonicalisation per ADR-0109 §3.4 + `zig_api_design.md` §4.3).
    pub fn read(self: Memory, comptime T: type, addr: u32) Error!T {
        const sz = @sizeOf(T);
        const mem = self.liveBytes();
        if (@as(u64, addr) + sz > mem.len) return error.OutOfBoundsLoad;
        const bytes = mem[addr..][0..sz];
        return switch (T) {
            f32 => @bitCast(std.mem.readInt(u32, bytes, .little)),
            f64 => @bitCast(std.mem.readInt(u64, bytes, .little)),
            else => std.mem.readInt(T, bytes, .little),
        };
    }

    /// Wasm spec §4.4.7 (memory.store) — little-endian typed write.
    pub fn write(self: Memory, addr: u32, val: anytype) Error!void {
        const T = @TypeOf(val);
        const sz = @sizeOf(T);
        const mem = self.liveBytes();
        if (@as(u64, addr) + sz > mem.len) return error.OutOfBoundsStore;
        const bytes = mem[addr..][0..sz];
        switch (T) {
            f32 => std.mem.writeInt(u32, bytes, @bitCast(val), .little),
            f64 => std.mem.writeInt(u64, bytes, @bitCast(val), .little),
            else => std.mem.writeInt(T, bytes, val, .little),
        }
    }

    /// `read` of element `index` of a `T` array at `base`. The address is
    /// computed in u64, so an index past the end is the load's trap.
    pub fn readElem(self: Memory, comptime T: type, base: u32, index: u32) Error!T {
        const addr = @as(u64, base) + @as(u64, index) * @sizeOf(T);
        return self.read(T, std.math.cast(u32, addr) orelse return error.OutOfBoundsLoad);
    }

    /// `write` counterpart of `readElem`.
    pub fn writeElem(self: Memory, base: u32, index: u32, val: anytype) Error!void {
        const addr = @as(u64, base) + @as(u64, index) * @sizeOf(@TypeOf(val));
        return self.write(std.math.cast(u32, addr) orelse return error.OutOfBoundsStore, val);
    }

    /// Wasm spec §4.2.8 — bounds-checked sub-slice `[offset, offset+len)`
    /// onto linear memory (a mutable view; writes through it persist).
    /// `OutOfBoundsLoad` when the window exceeds the current memory size.
    /// Use over `slice()` when an embedder wants a checked window rather
    /// than the whole backing store.
    pub fn sliceAt(self: Memory, offset: u32, len: u32) Error![]u8 {
        const mem = self.liveBytes();
        if (@as(u64, offset) + len > mem.len) return error.OutOfBoundsLoad;
        return mem[offset..][0..len];
    }

    /// Wasm spec §4.4.7 (memory.grow) — grow memory0 by `delta` pages
    /// (64 KiB each), zero-filling the new region. Returns the PREVIOUS
    /// page count on success, or `null` when the growth is refused (the
    /// module's declared max would be exceeded, an arithmetic overflow,
    /// or the host allocator failed). Mirrors wasmtime's `Memory::grow`
    /// (no trap — grow failure is a recoverable, expected outcome).
    pub fn grow(self: Memory, delta: u32) ?u32 {
        switch (self.backing) {
            .interp => |rt| {
                const old_pages = rt.growMemory(0, delta) orelse return null;
                return @intCast(old_pages);
            },
            .jit => |jit| return jit.growMemory(delta),
        }
    }
};

const _zwasm = @import("../zwasm.zig");
const testing = std.testing;

test "Memory.grow: success returns prev pages + expands; cap refusal → null" {
    // (module (memory 1 2) (export "mem" (memory 0)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x05, 0x04, 0x01, 0x01, 0x01, 0x02, // memory: min 1, max 2
        0x07, 0x07, 0x01, 0x03, 'm', 'e', 'm', 0x02, 0x00, // export "mem" = memory 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    var mem = inst.memory().?;
    try testing.expectEqual(@as(u32, 1), mem.size());
    // grow 1 → 2 pages: returns prev (1), size reflects the alias re-sync.
    try testing.expectEqual(@as(?u32, 1), mem.grow(1));
    try testing.expectEqual(@as(u32, 2), mem.size());
    // grow past declared max (2) → refused, memory unchanged.
    try testing.expectEqual(@as(?u32, null), mem.grow(1));
    try testing.expectEqual(@as(u32, 2), mem.size());
}

test "Memory.sliceAt: in-bounds window is a mutable view; OOB → error" {
    // (module (memory 1) (export "mem" (memory 0)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x05, 0x03, 0x01, 0x00, 0x01, // memory: min 1
        0x07, 0x07, 0x01, 0x03, 'm', 'e', 'm', 0x02, 0x00, // export "mem" = memory 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const mem = inst.memory().?;
    const win = try mem.sliceAt(8, 4);
    try testing.expectEqual(@as(usize, 4), win.len);
    win[0] = 0xAB; // mutate through the view…
    try testing.expectEqual(@as(u8, 0xAB), try mem.read(u8, 8)); // …visible via read
    // window crossing the 1-page (65536) boundary → OOB.
    try testing.expectError(error.OutOfBoundsLoad, mem.sliceAt(65530, 16));
}

test "Memory.readElem/writeElem: element addresses past u32 are the access's trap" {
    // (module (memory 1) (export "mem" (memory 0)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x05, 0x03, 0x01, 0x00, 0x01, // memory: min 1
        0x07, 0x07, 0x01, 0x03, 'm', 'e', 'm', 0x02, 0x00, // export "mem" = memory 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const mem = inst.memory().?;
    try mem.writeElem(16, 3, @as(u32, 0xCAFE));
    try testing.expectEqual(@as(u32, 0xCAFE), try mem.read(u32, 28));
    try testing.expectEqual(@as(u32, 0xCAFE), try mem.readElem(u32, 16, 3));
    try testing.expectError(error.OutOfBoundsStore, mem.writeElem(0xFFFF_FFF0, 0x4000_0000, @as(u32, 1)));
    try testing.expectError(error.OutOfBoundsLoad, mem.readElem(u32, 4, 0x4000_0000));
}

test "Memory engine=.jit: read/write/grow through the live JIT vm_base view (ADR-0200 incr 5)" {
    // (module (memory 1 2) (func (export "f") (result i32) i32.const 42)
    //         (export "mem" (memory 0)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->i32
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x05, 0x04, 0x01, 0x01, 0x01, 0x02, // memory: min 1, max 2
        0x07, 0x0b, 0x02, 0x01, 'f', 0x00, 0x00, 0x03, 'm', 'e', 'm', 0x02, 0x00, // exports "f"(func0) "mem"(mem0)
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();
    try testing.expect(inst.handle.runtime == null); // JIT-backed

    var mem = inst.memory().?;
    try testing.expectEqual(@as(u32, 1), mem.size());
    // write/read round-trips through the JIT-owned linear memory.
    try mem.write(16, @as(u32, 0xDEADBEEF));
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try mem.read(u32, 16));
    // grow 1 → 2 pages: prev (1); a fresh view sees the larger size after the
    // realloc moved vm_base (the facade reloads vm_base/mem_limit each call).
    try testing.expectEqual(@as(?u32, 1), mem.grow(1));
    try testing.expectEqual(@as(u32, 2), mem.size());
    // pre-grow bytes survive the realloc move.
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try mem.read(u32, 16));
    // grow past declared max (2) → refused, memory unchanged.
    try testing.expectEqual(@as(?u32, null), mem.grow(1));
    try testing.expectEqual(@as(u32, 2), mem.size());
}
