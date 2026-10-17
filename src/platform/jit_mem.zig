//! JIT executable-memory primitives (sub-7.4a).
//!
//! Allocates a page-aligned region that JIT-emitted bytes are
//! written to, then flips its protection so the CPU can execute
//! the bytes. Per-OS implementation:
//!
//! - macOS aarch64 (hardened runtime): MAP_JIT + per-thread W^X
//!   toggle (`pthread_jit_write_protect_np`) + I-cache
//!   invalidation.
//! - Linux x86_64 and aarch64 (D-045 chunk 10, #547): plain `mmap`
//!   with PROT_READ|WRITE|EXEC (Linux doesn't enforce W^X on user
//!   mmap unless SELinux/etc explicitly does). setWritable is a
//!   no-op since the page is always RWX; setExecutable is one too
//!   on x86_64, and on aarch64 it syncs the I-cache.
//! - Windows x86_64 (D-045 chunk 12): `NtAllocateVirtualMemory`
//!   with PAGE_EXECUTE_READWRITE (mirror of the Linux-RWX
//!   shape; CFG / ACG aren't enforced for processes that don't
//!   opt in, so RWX user pages are accepted by default).
//!   setExecutable / setWritable are no-ops on this branch
//!   too.
//!
//! Zone 0 (`src/platform/`) — depends only on Zig stdlib.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    /// Page allocation failed (mmap / VirtualAlloc).
    AllocationFailed,
    /// Write→execute protection flip failed.
    ProtectionFailed,
    /// Host platform doesn't yet have a JIT-mem implementation.
    NotImplemented,
};

/// Allocation-rounding granularity. macOS aarch64 = 16K; Linux = 4K
/// (mmap will round up itself, but we pre-round so the JitBlock's
/// `bytes.len` matches the actual mapping — except on a 16K/64K-page
/// aarch64 kernel, where the mapping is longer and its tail unused;
/// munmap rounds the length up the same way).
const page_size: usize = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
    16 * 1024
else
    4 * 1024;

/// macOS uses MAP_JIT + per-thread W^X (`pthread_jit_write_protect_np`) on
/// BOTH aarch64 (Apple Silicon) and x86_64 (Intel, under hardened runtime).
/// x86_64-macos is not a 3-host gate target; this branch exists so the JIT can
/// run under Rosetta on an Apple-Silicon Mac (`x86_64-macos` build → Rosetta
/// exec), giving the x86_64 codegen a local correctness loop (D-265 Phase IV).
const macos_jit: bool = builtin.os.tag == .macos and
    (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64);

const linux_rwx: bool = builtin.os.tag == .linux and
    (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);

/// A page-aligned RWX region holding JIT-emitted bytes. Lifetime
/// owned by the caller; pair `alloc` with `free`.
pub const JitBlock = struct {
    bytes: []align(page_size) u8,

    /// Cast the block's start to a function pointer of type `Fn`.
    /// Caller is responsible for matching the actual emitted
    /// signature; mismatch produces undefined behaviour.
    pub fn asFnPtr(self: JitBlock, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.bytes.ptr));
    }
};

/// Allocate `size` bytes of JIT-capable RX memory, initially
/// writable on the current thread. Caller writes bytes into
/// `block.bytes`, then calls `setExecutable(block)` to publish.
pub fn alloc(size: usize) Error!JitBlock {
    if (size == 0) return Error.AllocationFailed;
    const rounded = (size + page_size - 1) & ~(page_size - 1);

    if (macos_jit) {
        const prot: std.c.vm_prot_t = .{ .READ = true, .WRITE = true, .EXEC = true };
        const flags: std.c.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true };
        const ptr = std.c.mmap(null, rounded, prot, flags, -1, 0);
        if (ptr == std.c.MAP_FAILED) return Error.AllocationFailed;
        const aligned: [*]align(page_size) u8 = @ptrCast(@alignCast(ptr));
        // MAP_JIT pages start in the W mode for the current thread
        // (per-thread W^X). Caller writes; setExecutable flips.
        return .{ .bytes = aligned[0..rounded] };
    }

    if (linux_rwx) {
        // D-045 chunk 10: Linux mmap-RWX.
        const prot: std.posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = true };
        const flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const result = std.posix.mmap(null, rounded, prot, flags, -1, 0) catch return Error.AllocationFailed;
        return .{ .bytes = @alignCast(result[0..rounded]) };
    }

    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        // D-045 chunk 12: Windows x86_64 RWX page via
        // NtAllocateVirtualMemory. Mirror of the Linux-RWX shape
        // (PAGE.EXECUTE_READWRITE = single combined RWX page).
        // zig 0.16 stable exposes the low-level extern only;
        // wrapper-with-error-union landed post-0.16.
        var base_addr: ?*anyopaque = null;
        var alloc_size: std.os.windows.SIZE_T = rounded;
        const status = std.os.windows.ntdll.NtAllocateVirtualMemory(
            std.os.windows.GetCurrentProcess(),
            @ptrCast(&base_addr),
            0,
            &alloc_size,
            .{ .COMMIT = true, .RESERVE = true },
            .{ .EXECUTE_READWRITE = true },
        );
        if (status != .SUCCESS) return Error.AllocationFailed;
        const ptr = base_addr orelse return Error.AllocationFailed;
        const aligned: [*]align(page_size) u8 = @ptrCast(@alignCast(ptr));
        return .{ .bytes = aligned[0..rounded] };
    }

    return Error.NotImplemented;
}

/// Free a block previously returned by `alloc`.
///
/// **Sentinel guard (D-077 discharge, §9.9 / 9.9-h-6)**: empty
/// modules (`func_bodies.len == 0` at link time) carry an
/// empty static sentinel slice (`&[_:0]u8{}`) instead of an
/// mmap-backed region. Calling munmap on a zero-length /
/// non-page-aligned pointer returns `EINVAL`; `std.posix.munmap`
/// asserts INVAL → `unreachable` on Linux, panicking the
/// process. The guard short-circuits at `bytes.len == 0` on
/// every platform — there is nothing to release. With the guard
/// in place, both macOS and Linux use `std.posix.munmap`
/// (§9.12-D / ADR-0070 migration; previously the macOS branch
/// used `std.c.munmap` to discard the return out of caution).
pub fn free(block: JitBlock) void {
    if (block.bytes.len == 0) return;
    if (macos_jit) {
        std.posix.munmap(block.bytes);
        return;
    }
    if (linux_rwx) {
        std.posix.munmap(block.bytes);
        return;
    }
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        // MEM.FREE.RELEASE requires size = 0 and addr = the
        // original base returned by NtAllocateVirtualMemory.
        var addr: ?*anyopaque = block.bytes.ptr;
        var size: std.os.windows.SIZE_T = 0;
        _ = std.os.windows.ntdll.NtFreeVirtualMemory(
            std.os.windows.GetCurrentProcess(),
            @ptrCast(&addr),
            &size,
            .{ .RELEASE = true },
        );
        return;
    }
}

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: ?*anyopaque, len: usize) void;

/// Flip `block` from writable to executable for the current
/// thread + invalidate the I-cache so freshly-written bytes are
/// visible to the CPU's instruction fetch.
pub fn setExecutable(block: JitBlock) Error!void {
    if (macos_jit) {
        pthread_jit_write_protect_np(1); // 1 = re-enable W^X (RX)
        // I-cache invalidation is a no-op on x86_64 (Intel SDM Vol 3 §11.6:
        // self-modifying-code coherency is automatic) but the call is cheap and
        // keeps the macos branch uniform.
        sys_icache_invalidate(@ptrCast(block.bytes.ptr), block.bytes.len);
        return;
    }
    if (linux_rwx) {
        // The page is RWX from alloc. x86_64 keeps the I-cache coherent
        // with D-cache writes (Intel SDM Vol 3 §11.6); aarch64 does not.
        if (builtin.cpu.arch == .aarch64) syncInstructionCache(block.bytes);
        return;
    }
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        // Same as Linux: PAGE_EXECUTE_READWRITE means the page is
        // already executable; x86_64 I/D coherency holds.
        return;
    }
    return Error.NotImplemented;
}

/// Flip `block` back to writable for the current thread, e.g. to
/// patch `call_fixups` after initial publish. Pair with
/// `setExecutable`.
pub fn setWritable(block: JitBlock) Error!void {
    _ = block; // Mac uses pthread_jit_write_protect_np (no block);
    // Linux + Windows are no-ops (page is RWX).
    if (macos_jit) {
        pthread_jit_write_protect_np(0); // 0 = disable W^X (RW)
        return;
    }
    if (linux_rwx) {
        return;
    }
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        return;
    }
    return Error.NotImplemented;
}

/// Make bytes written through the D-side visible to instruction fetch
/// (Arm ARM B2.4.4): clean D to the point of unification, invalidate I,
/// then `isb`. CTR_EL0.IDC (bit 28) / DIC (bit 29) say the hardware
/// already does a step, and the line sizes come from CTR_EL0 too. This
/// is the sequence compiler-rt's `__clear_cache` runs; it is not linked
/// here because ADR-0070 has no `__clear_cache` site.
fn syncInstructionCache(bytes: []const u8) void {
    const start = @intFromPtr(bytes.ptr);
    const end = start + bytes.len;
    const ctr = asm volatile ("mrs %[ctr], ctr_el0"
        : [ctr] "=r" (-> u64),
    );
    if ((ctr >> 28) & 1 == 0) {
        const line = @as(usize, 4) << @intCast((ctr >> 16) & 0xf);
        var addr = start & ~(line - 1);
        while (addr < end) : (addr += line) {
            asm volatile ("dc cvau, %[addr]"
                :
                : [addr] "r" (addr),
                : .{ .memory = true });
        }
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    if ((ctr >> 29) & 1 == 0) {
        const line = @as(usize, 4) << @intCast(ctr & 0xf);
        var addr = start & ~(line - 1);
        while (addr < end) : (addr += line) {
            asm volatile ("ic ivau, %[addr]"
                :
                : [addr] "r" (addr),
                : .{ .memory = true });
        }
        asm volatile ("dsb ish" ::: .{ .memory = true });
    }
    asm volatile ("isb" ::: .{ .memory = true });
}

const testing = std.testing;
const skip = @import("../test_support/skip.zig");

test "JitBlock: emit native const-42 fn + execute, returns 42" {
    // D-193 / ADR-0122 D3: portable via comptime per-arch machine code.
    // The alloc + W^X toggle + exec primitive (this file) is host-
    // portable; only the instruction bytes are arch-specific, so both
    // arm64 + x86_64 run the SAME test (no skipped sibling → no
    // SIBLING-AT). Win deferred per ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var block = try alloc(page_size);
    defer free(block);
    // Block starts writable (MAP_JIT + thread W^X disabled on macOS);
    // request W mode explicitly for this thread.
    try setWritable(block);
    switch (builtin.cpu.arch) {
        .aarch64 => {
            const inst = @import("../engine/codegen/arm64/inst.zig");
            std.mem.writeInt(u32, block.bytes[0..4], inst.encMovzImm16(0, 42), .little);
            std.mem.writeInt(u32, block.bytes[4..8], inst.encRet(30), .little);
        },
        .x86_64 => {
            // mov eax, 42 (B8 2A 00 00 00) ; ret (C3) — Intel SDM Vol 2
            // (B8+rd MOV r32,imm32; C3 RET). EAX is the callconv(.c)
            // integer return register on both SysV + Win64.
            const code = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
            @memcpy(block.bytes[0..code.len], &code);
        },
        else => @compileError("unsupported arch for JIT exec test"),
    }

    try setExecutable(block);
    const Fn = *const fn () callconv(.c) u32;
    const f = block.asFnPtr(Fn);
    try testing.expectEqual(@as(u32, 42), f());
}

test "JitBlock: bytes rewritten after a publish execute on the next publish (#547)" {
    // A stale I-cache line would still return 42 on aarch64-linux, where
    // setExecutable is the only thing that syncs it.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var block = try alloc(page_size);
    defer free(block);
    const Fn = *const fn () callconv(.c) u32;
    for ([_]u16{ 42, 7 }) |value| {
        try setWritable(block);
        switch (builtin.cpu.arch) {
            .aarch64 => {
                const inst = @import("../engine/codegen/arm64/inst.zig");
                std.mem.writeInt(u32, block.bytes[0..4], inst.encMovzImm16(0, value), .little);
                std.mem.writeInt(u32, block.bytes[4..8], inst.encRet(30), .little);
            },
            .x86_64 => {
                const code = [_]u8{ 0xB8, @intCast(value), 0x00, 0x00, 0x00, 0xC3 };
                @memcpy(block.bytes[0..code.len], &code);
            },
            else => @compileError("unsupported arch for JIT exec test"),
        }
        try setExecutable(block);
        try testing.expectEqual(@as(u32, value), block.asFnPtr(Fn)());
    }
}

test "JitBlock: alloc(0) returns AllocationFailed" {
    try testing.expectError(Error.AllocationFailed, alloc(0));
}
