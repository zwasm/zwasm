// FILE-SIZE-EXEMPT: the complete wasi 0.3 host layer (fs3/sock3/http3 + async-lowered table + hook targets; ADR-0207 (c), M4-measured 2026-08-12); a per-proposal 3-way sub-split would force pub-leak of the hook targets through hooksTable/registerP3Arms (ADR-0099 N2), so cohesion wins while under the 2500 exempt cap.
//! WASI **0.3** (P3) host layer — fs3 / sock3 / http3 trampolines, the
//! async-lowered binding table, and the classifier's P3 arm registration
//! (ADR-0207 (c); file name reserved by ADR-0190). Depends ONLY on the
//! substrate `component_wasi_ctx.zig`; the substrate reaches back into this
//! layer exclusively through `WasiP2Ctx.P3Hooks` (`hooksTable` below).

const std = @import("std");
const dbg = @import("../support/dbg.zig");

const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_path = @import("../wasi/path.zig");
const wasi_p1 = @import("../wasi/preview1.zig");
const p2sock = @import("../wasi/p2_sockets.zig");
const p3http = @import("../wasi/p3_http.zig");
const adapter = @import("../wasi/adapter.zig");
const async_mod = @import("../feature/component/async.zig");
const Caller = @import("../zwasm/caller.zig").Caller;
const Linker = @import("../zwasm/linker.zig").Linker;
const Engine = @import("../zwasm/engine.zig").Engine;

const ctx_mod = @import("component_wasi_ctx.zig");
const WasiP2Ctx = ctx_mod.WasiP2Ctx;
const WasiP2Error = ctx_mod.WasiP2Error;
const Memory = ctx_mod.Memory;
const FilestatResult = ctx_mod.FilestatResult;
const PendingClientSend = ctx_mod.PendingClientSend;
const ctxMemory = ctx_mod.ctxMemory;
const ctxIo = ctx_mod.ctxIo;
const ctxTcpSocket = ctx_mod.ctxTcpSocket;
const ctxUdpSocket = ctx_mod.ctxUdpSocket;
const descriptorFilestat = ctx_mod.descriptorFilestat;
const pathFilestat = ctx_mod.pathFilestat;
const decodeIpSocketAddress = ctx_mod.decodeIpSocketAddress;
const writeIpSocketAddressResult = ctx_mod.writeIpSocketAddressResult;
const mapAsyncFault = ctx_mod.mapAsyncFault;
const SUBTASK_RETURNED = ctx_mod.SUBTASK_RETURNED;
const p2WaitUntil = ctx_mod.p2WaitUntil;
const p2WaitFor = ctx_mod.p2WaitFor;

/// The substrate→P3 hook table (ADR-0207): the six fn-pointers the shared
/// engine / drop / poll paths call instead of naming P3 symbols.
pub fn hooksTable() WasiP2Ctx.P3Hooks {
    return .{
        .drop_transferred_end = http3DropTransferredEnd,
        .udp_receive_complete = sock3UdpReceiveComplete,
        .fail_file_stream = fs3FailFileStream,
        .resolve_send_future = sock3ResolveSendFuture,
        .sock_err_code = sockErrToFs3Code,
        .dir_stream_read = fs3DirStreamRead,
    };
}

/// Install the hook table on a ctx whose components may carry P3 resources.
pub fn installP3Hooks(ctx: *WasiP2Ctx) void {
    ctx.p3_hooks = hooksTable();
}

// ============================================================
// wasi:filesystem@0.3.0 (ADR-0205 phase B)
// ============================================================
// The 0.3 descriptor surface. Async funcs arrive ASYNC-LOWERED from
// wit-bindgen guests and complete eagerly (ADR-0205 D5): flat params ≤ 4 stay
// flat (+ retptr), larger signatures spill to ONE args pointer (+ retptr);
// results always land at retptr; the trampoline returns the packed subtask
// status (eager = RETURNED). The via-stream/read-directory funcs are PLAIN
// funcs (sync-lowered) minting host-peer streams like the ADR-0190 stdio
// pattern, but against file fds at tracked positions.

/// 0.3 `error-code` variant ordinals (0.2's `would-block` was REMOVED, so the
/// generations renumber; 36 = the `other(option<string>)` catch-all).
fn errnoToFs3ErrorCode(errno: wasi_p1.Errno) u8 {
    return switch (errno) {
        .acces => 0,
        .already => 1,
        .badf => 2,
        .busy => 3,
        .deadlk => 4,
        .dquot => 5,
        .exist => 6,
        .fbig => 7,
        .ilseq => 8,
        .inprogress => 9,
        .intr => 10,
        .inval => 11,
        .io => 12,
        .isdir => 13,
        .loop => 14,
        .mlink => 15,
        .msgsize => 16,
        .nametoolong => 17,
        .nodev => 18,
        .noent => 19,
        .nolck => 20,
        .nomem => 21,
        .nospc => 22,
        .notdir => 23,
        .notempty => 24,
        .notrecoverable => 25,
        .notsup => 26,
        .notty => 27,
        .nxio => 28,
        .overflow => 29,
        .perm => 30,
        .pipe => 31,
        .rofs => 32,
        .spipe => 33,
        .txtbsy => 34,
        .xdev => 35,
        // P1's sandbox-escape errno; 0.3 names the same condition
        // `not-permitted` ("reaches a directory outside of the base
        // directory ... fails with error-code::not-permitted").
        .notcapable => 30,
        else => 36,
    };
}

/// 0.3 `descriptor-type` VARIANT ordinals (0.2 was an enum with `unknown` at
/// 0; 0.3 drops it and appends `other(option<string>)` = 7).
fn filetypeToFs3DescriptorType(ft: wasi_p1.Filetype) u8 {
    return switch (ft) {
        .block_device => 0,
        .character_device => 1,
        .directory => 2,
        .symbolic_link => 4,
        .regular_file => 5,
        .socket_dgram, .socket_stream => 6,
        else => 7,
    };
}

/// Store `result.err(error-code)` at `retptr` for a 0.3 result whose payload
/// slot sits at `payload_off` (8 for align-8 ok payloads, 4 otherwise).
/// error-code = variant{disc u8 @0, `other`'s option<string> @4 → none}.
fn writeFs3Err(mem: Memory, retptr: u32, payload_off: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1)); // result disc: err
    try mem.write(retptr + payload_off, errnoToFs3ErrorCode(errno));
    try mem.write(retptr + payload_off + 4, @as(u8, 0)); // option<string>: none
}

/// Write a 0.3 `descriptor-type` variant (16 B, align 4) at `ptr`.
fn writeFs3DescriptorType(mem: Memory, ptr: u32, ft: wasi_p1.Filetype) WasiP2Error!void {
    try mem.write(ptr, filetypeToFs3DescriptorType(ft));
    try mem.write(ptr + 4, @as(u8, 0)); // `other`'s option<string>: none
}

/// Resolve a descriptor handle to its P1 fd (shared fs3 front-half).
fn fs3Fd(ctx: *WasiP2Ctx, handle: u32) WasiP2Error!wasi_p1.Fd {
    return @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, handle));
}

/// `[async-lower][method]descriptor.stat` (self, retptr) — store
/// `result<descriptor-stat, error-code>` in the 0.3 layout: disc@0, payload@8;
/// descriptor-stat = %type@0 (16 B variant), link-count@16, size@24, then
/// three `option<instant>` @32/56/80 (disc@0, instant{seconds s64@8, ns u32@16}).
fn fs3Stat(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    try writeFs3StatResult(mem, retptr, try descriptorFilestat(ctx, mem, fd));
    return SUBTASK_RETURNED;
}

fn fs3StatAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const dirfd = try fs3Fd(ctx, self_handle);
    try writeFs3StatResult(mem, retptr, try pathFilestat(ctx, mem, dirfd, path_flags, path_ptr, path_len));
    return SUBTASK_RETURNED;
}

fn writeFs3StatResult(mem: Memory, retptr: u32, r: FilestatResult) WasiP2Error!void {
    switch (r) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            const base = retptr + 8;
            try writeFs3DescriptorType(mem, base, fs.filetype);
            try mem.write(base + 16, @as(u64, fs.nlink));
            try mem.write(base + 24, @as(u64, fs.size));
            inline for (.{ .{ base + 32, fs.atim }, .{ base + 56, fs.mtim }, .{ base + 80, fs.ctim } }) |t| {
                try mem.write(t[0], @as(u8, 1)); // option disc: some
                try mem.write(t[0] + 8, @as(i64, @intCast(t[1] / std.time.ns_per_s)));
                try mem.write(t[0] + 16, @as(u32, @intCast(t[1] % std.time.ns_per_s)));
            }
        },
        .err => |errno| try writeFs3Err(mem, retptr, 8, errno),
    }
}

/// `get-type` (self, retptr) — `result<descriptor-type, error-code>`: disc@0,
/// payload@4 (align 4).
fn fs3GetType(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0));
            try writeFs3DescriptorType(mem, retptr + 4, fs.filetype);
        },
        .err => |errno| try writeFs3Err(mem, retptr, 4, errno),
    }
    return SUBTASK_RETURNED;
}

/// `get-flags` (self, retptr) — `result<descriptor-flags, error-code>`;
/// descriptor-flags = 6 flags → one byte (read=1, write=2,
/// mutate-directory=32). Derived from the object kind: files read+write,
/// directories read+mutate-directory (the host does not model O_RDONLY opens).
fn fs3GetFlags(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| {
            // Reflect the open-time EFFECTIVE flags when recorded; preopens
            // and 0.2-opened descriptors derive from kind.
            const flags: u8 = if (ctx.descriptor_open_flags.get(self_handle)) |req|
                req & (1 | 2 | 32)
            else if (fs.filetype == .directory) 1 | 32 else 1 | 2;
            try mem.write(retptr, @as(u8, 0));
            try mem.write(retptr + 4, flags);
        },
        .err => |errno| try writeFs3Err(mem, retptr, 4, errno),
    }
    return SUBTASK_RETURNED;
}

/// `result<_, error-code>` writer (unit ok): disc@0, err payload@4.
fn writeFs3UnitResult(mem: Memory, retptr: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    if (errno == .success) {
        try mem.write(retptr, @as(u8, 0));
    } else {
        try writeFs3Err(mem, retptr, 4, errno);
    }
}

fn fs3Sync(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_fd.fdSync(ctx.host, try fs3Fd(ctx, self_handle)));
    return SUBTASK_RETURNED;
}

fn fs3SyncData(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_fd.fdDatasync(ctx.host, try fs3Fd(ctx, self_handle)));
    return SUBTASK_RETURNED;
}

fn fs3SetSize(caller: *Caller, self_handle: u32, size_raw: i64, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    // A descriptor opened without WRITE must refuse resizing (WASI#712;
    // official filesystem-set-size.wasm asserts it).
    if (ctx.descriptor_open_flags.get(self_handle)) |req| {
        if (req & 2 == 0) {
            try writeFs3Err(mem, retptr, 4, .badf);
            return SUBTASK_RETURNED;
        }
    }
    try writeFs3UnitResult(mem, retptr, wasi_fd.fdFilestatSetSize(ctx.host, try fs3Fd(ctx, self_handle), @bitCast(size_raw)));
    return SUBTASK_RETURNED;
}

/// `advise` (self, offset, length, advice, retptr) — 0.3 advice ordinals
/// match P1's (normal..no-reuse).
fn fs3Advise(caller: *Caller, self_handle: u32, offset_raw: i64, len_raw: i64, advice: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const errno = wasi_fd.fdAdvise(ctx.host, try fs3Fd(ctx, self_handle), @bitCast(offset_raw), @bitCast(len_raw), @intCast(advice & 0xff));
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

fn fs3CreateDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_path.pathCreateDirectory(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_ptr, path_len));
    return SUBTASK_RETURNED;
}

fn fs3RemoveDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_path.pathRemoveDirectory(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_ptr, path_len));
    return SUBTASK_RETURNED;
}

fn fs3UnlinkFileAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_fd.pathUnlinkFile(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_ptr, path_len));
    return SUBTASK_RETURNED;
}

/// `readlink-at` (self, path, retptr) → `result<string, error-code>`
/// (string align 4 → payload@4: ptr@4, len@8; target in fresh cabi_realloc
/// backing).
fn fs3ReadlinkAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const dirfd = try fs3Fd(ctx, self_handle);
    const cap: u32 = 4096;
    const buf_ptr = try ctx.reallocGuest(cap, 1);
    const used_ptr = try ctx.reallocGuest(4, 4);
    const errno = wasi_path.pathReadlink(ctx.host, mem.slice(), dirfd, path_ptr, path_len, buf_ptr, cap, used_ptr);
    if (errno != .success) {
        try writeFs3Err(mem, retptr, 4, errno);
        return SUBTASK_RETURNED;
    }
    const used = try mem.read(u32, used_ptr);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, buf_ptr);
    try mem.write(retptr + 8, used);
    return SUBTASK_RETURNED;
}

// -- spilled-args family: the Canonical ABI passes > 4-flat async-lowered
// params through ONE args pointer; layouts are the params-record layouts.

/// `open-at` args record: self@0(u32), path-flags@4(u8 flags),
/// path@8(ptr,len), open-flags@16(u8), %flags@17(u8). Result:
/// `result<own<descriptor>, error-code>` (handle@4).
fn fs3OpenAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const path_ptr = try mem.read(u32, argsptr + 8);
    const path_len = try mem.read(u32, argsptr + 12);
    const open_flags = try mem.read(u8, argsptr + 16);
    const dirfd = try fs3Fd(ctx, self_handle);
    const oflags: wasi_p1.Oflags = @intCast(open_flags & 0x0F);
    // The component model has no rights: the preopen IS the sandbox. Ask for
    // everything the target type can carry and let `path_open` clamp against
    // the parent's inheriting set.
    const rights = wasi_p1.rightsForRightlessOpen(oflags);
    const scratch = try ctx.reallocGuest(4, 4);
    const errno = wasi_fd.pathOpen(ctx.host, mem.slice(), dirfd, 0, path_ptr, path_len, oflags, rights.base, rights.inheriting, 0, scratch);
    if (errno != .success) {
        try writeFs3Err(mem, retptr, 4, errno);
        return SUBTASK_RETURNED;
    }
    const opened_fd = try mem.read(u32, scratch);
    const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, opened_fd);
    // The EFFECTIVE flags `get-flags` reads back (official
    // filesystem-flags-and-type.wasm): no read/write requested → READ by
    // default; CREATE/TRUNCATE imply WRITE (without implying READ).
    var dflags = try mem.read(u8, argsptr + 17);
    if (dflags & 3 == 0) dflags |= 1;
    if (open_flags & (0x1 | 0x8) != 0) dflags |= 2;
    try ctx.descriptor_open_flags.put(ctx.alloc, handle, dflags);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
    return SUBTASK_RETURNED;
}

/// One decoded `new-timestamp` (24 B variant, align 8: disc@0, instant@8).
const Fs3NewTimestamp = struct { ns: u64, set: bool, now: bool };

fn readFs3NewTimestamp(mem: Memory, ptr: u32) WasiP2Error!Fs3NewTimestamp {
    const disc = try mem.read(u8, ptr);
    return switch (disc) {
        0 => .{ .ns = 0, .set = false, .now = false }, // no-change
        1 => .{ .ns = 0, .set = false, .now = true }, // now
        else => blk: {
            const secs = try mem.read(i64, ptr + 8);
            const nanos = try mem.read(u32, ptr + 16);
            // Pre-epoch instants clamp to 0 (P1 timestamps are unsigned ns).
            const total: u64 = if (secs < 0) 0 else @as(u64, @intCast(secs)) *| std.time.ns_per_s +| nanos;
            break :blk .{ .ns = total, .set = true, .now = false };
        },
    };
}

fn fs3FstflagsOf(atim: Fs3NewTimestamp, mtim: Fs3NewTimestamp) wasi_p1.Fstflags {
    var f: u16 = 0;
    if (atim.set) f |= 1; // ATIM
    if (atim.now) f |= 2; // ATIM_NOW
    if (mtim.set) f |= 4; // MTIM
    if (mtim.now) f |= 8; // MTIM_NOW
    return @bitCast(f);
}

/// `set-times` args record: self@0, atim new-timestamp@8, mtim@32.
fn fs3SetTimes(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const atim = try readFs3NewTimestamp(mem, argsptr + 8);
    const mtim = try readFs3NewTimestamp(mem, argsptr + 32);
    const errno = wasi_fd.fdFilestatSetTimes(ctx.host, try fs3Fd(ctx, self_handle), atim.ns, mtim.ns, fs3FstflagsOf(atim, mtim));
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `set-times-at` args record: self@0, path-flags@4(u8), path@8(8),
/// atim@16(24, align 8), mtim@40(24).
fn fs3SetTimesAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const path_flags = try mem.read(u8, argsptr + 4);
    const path_ptr = try mem.read(u32, argsptr + 8);
    const path_len = try mem.read(u32, argsptr + 12);
    const atim = try readFs3NewTimestamp(mem, argsptr + 16);
    const mtim = try readFs3NewTimestamp(mem, argsptr + 40);
    const errno = wasi_path.pathFilestatSetTimes(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_flags, path_ptr, path_len, atim.ns, mtim.ns, fs3FstflagsOf(atim, mtim));
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `rename-at` args record: self@0, old-path@4(8), new-descriptor@12(u32),
/// new-path@16(8).
fn fs3RenameAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const old_ptr = try mem.read(u32, argsptr + 4);
    const old_len = try mem.read(u32, argsptr + 8);
    const new_desc = try mem.read(u32, argsptr + 12);
    const new_ptr = try mem.read(u32, argsptr + 16);
    const new_len = try mem.read(u32, argsptr + 20);
    const errno = wasi_path.pathRename(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), old_ptr, old_len, try fs3Fd(ctx, new_desc), new_ptr, new_len);
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `symlink-at` args record: self@0, old-path@4(8), new-path@12(8).
fn fs3SymlinkAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const old_ptr = try mem.read(u32, argsptr + 4);
    const old_len = try mem.read(u32, argsptr + 8);
    const new_ptr = try mem.read(u32, argsptr + 12);
    const new_len = try mem.read(u32, argsptr + 16);
    const errno = wasi_path.pathSymlink(ctx.host, mem.slice(), old_ptr, old_len, try fs3Fd(ctx, self_handle), new_ptr, new_len);
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `link-at` args record: self@0, old-path-flags@4(u8), old-path@8(8),
/// new-descriptor@16(u32), new-path@20(8).
fn fs3LinkAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const old_flags = try mem.read(u8, argsptr + 4);
    const old_ptr = try mem.read(u32, argsptr + 8);
    const old_len = try mem.read(u32, argsptr + 12);
    const new_desc = try mem.read(u32, argsptr + 16);
    const new_ptr = try mem.read(u32, argsptr + 20);
    const new_len = try mem.read(u32, argsptr + 24);
    const errno = wasi_path.pathLink(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), old_flags, old_ptr, old_len, try fs3Fd(ctx, new_desc), new_ptr, new_len);
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `is-same-object` (self, other, retptr) → bool (no error case): P1 dev+ino
/// equality.
fn fs3IsSameObject(caller: *Caller, self_handle: u32, other_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const a = try descriptorFilestat(ctx, mem, try fs3Fd(ctx, self_handle));
    const b = try descriptorFilestat(ctx, mem, try fs3Fd(ctx, other_handle));
    const same = switch (a) {
        .ok => |fa| switch (b) {
            .ok => |fb| fa.dev == fb.dev and fa.ino == fb.ino,
            .err => false,
        },
        .err => false,
    };
    try mem.write(retptr, @as(u8, @intFromBool(same)));
    return SUBTASK_RETURNED;
}

/// `metadata-hash` family → `result<metadata-hash-value{lower,upper},
/// error-code>` (payload@8): a Wyhash over (dev, ino, size, mtim) — stable
/// while the object is unmodified, changes when it changes (the spec's
/// encouraged properties; none is required).
fn fs3HashOf(fs: wasi_p1.Filestat) [2]u64 {
    var h = std.hash.Wyhash.init(0x7a77_6173_6d5f_6673); // "zwasm_fs"
    h.update(std.mem.asBytes(&fs.dev));
    h.update(std.mem.asBytes(&fs.ino));
    h.update(std.mem.asBytes(&fs.size));
    h.update(std.mem.asBytes(&fs.mtim));
    const lo = h.final();
    var h2 = std.hash.Wyhash.init(lo);
    h2.update(std.mem.asBytes(&fs.ino));
    return .{ lo, h2.final() };
}

fn writeFs3HashResult(mem: Memory, retptr: u32, r: FilestatResult) WasiP2Error!void {
    switch (r) {
        .ok => |fs| {
            const hv = fs3HashOf(fs);
            try mem.write(retptr, @as(u8, 0));
            try mem.write(retptr + 8, hv[0]);
            try mem.write(retptr + 16, hv[1]);
        },
        .err => |errno| try writeFs3Err(mem, retptr, 8, errno),
    }
}

fn fs3MetadataHash(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3HashResult(mem, retptr, try descriptorFilestat(ctx, mem, try fs3Fd(ctx, self_handle)));
    return SUBTASK_RETURNED;
}

fn fs3MetadataHashAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3HashResult(mem, retptr, try pathFilestat(ctx, mem, try fs3Fd(ctx, self_handle), path_flags, path_ptr, path_len));
    return SUBTASK_RETURNED;
}

// -- via-stream data plane (plain funcs, sync-lowered) --

/// `read-via-stream` (self, offset, retptr) → tuple<stream<u8>,
/// future<result<_,error-code>>> (stream handle@retptr, future@retptr+4):
/// the host is the stream's WRITER, supplying bytes preread from the file at
/// the tracked position (ADR-0190 pattern on a positional fd).
fn fs3ReadViaStream(caller: *Caller, self_handle: u32, offset_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_file_streams.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, .{ .fd = fd, .pos = @bitCast(offset_raw), .result_future = fut.readable });
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

/// `write-via-stream` (self, data readable-stream, offset) → future handle:
/// the guest hands over the READABLE end of its data stream; the host drains
/// it as a positional file sink.
fn fs3WriteViaStream(caller: *Caller, self_handle: u32, data_handle: u32, offset_raw: i64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const fd = try fs3Fd(ctx, self_handle);
    return fs3RegisterFileSink(ctx, fd, data_handle, @bitCast(offset_raw)) catch |e| mapAsyncFault(e);
}

/// `append-via-stream` (self, data) → future handle: the sink position starts
/// at the current file size.
fn fs3AppendViaStream(caller: *Caller, self_handle: u32, data_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    const size: u64 = switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| fs.size,
        .err => 0,
    };
    return fs3RegisterFileSink(ctx, fd, data_handle, size) catch |e| mapAsyncFault(e);
}

fn fs3RegisterFileSink(ctx: *WasiP2Ctx, fd: wasi_p1.Fd, data_handle: u32, pos: u64) WasiP2Error!u32 {
    // Copy the shared id out BEFORE minting the future pair — the mint grows
    // the end table and invalidates `get`'s pointer.
    const shared_id = blk: {
        const end = try ctx.streams.get(data_handle);
        if (end.kind != .stream) return WasiP2Error.InvalidHandle;
        break :blk end.shared;
    };
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_file_streams.put(ctx.alloc, shared_id, .{ .fd = fd, .pos = pos, .result_future = fut.readable });
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try fs3DrainParkedWrite(ctx, shared_id);
    return fut.readable;
}

/// A writer PARKED on this stream before the host role existed
/// (`futures::join!` ordering): drain its recorded span into the file now and
/// deliver its STREAM_WRITE completion event.
fn fs3DrainParkedWrite(ctx: *WasiP2Ctx, shared_id: u32) WasiP2Error!void {
    const sh = try ctx.shared.get(shared_id);
    const pending = switch (sh.*) {
        .stream => |*st| st.pending orelse return,
        .future, .subtask => return,
    };
    if (pending.side != .writable) return;
    const pw = ctx.pending_writes.get(pending.waitable) orelse return;
    const role = ctx.host_file_streams.getPtr(shared_id) orelse return;
    const mem = try ctx.memory();
    const bytes = mem.sliceAt(pw.ptr, pw.count * pw.elem_size) catch return WasiP2Error.OutOfBounds;
    const errno = wasi_fd.pwriteSlice(ctx.host, role.fd, bytes, role.pos);
    const writer = try ctx.streams.get(pending.waitable);
    if (errno != .success) {
        _ = try fs3FailFileStream(ctx, writer, role, errno);
        return;
    }
    role.pos += bytes.len;
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .stream_write, .index = pending.waitable, .payload = (async_mod.ReturnCode{ .completed = @intCast(pw.count) }).encode() });
    switch (sh.*) {
        .stream => |*st| st.pending = null,
        .future, .subtask => {},
    }
    _ = ctx.pending_writes.remove(pending.waitable);
}

/// A file via-stream copy failed: record the 0.3 error-code on the stream's
/// result future, close the stream (DROPPED), and report the drop to the
/// caller — the guest then reads the error from the future.
fn fs3FailFileStream(ctx: *WasiP2Ctx, end: *async_mod.StreamFutureEnd, role: *WasiP2Ctx.FileStreamRole, errno: wasi_p1.Errno) WasiP2Error!u32 {
    if (role.result_future != 0) {
        if (ctx.host_result_futures.getPtr(role.result_future)) |v| v.* = errnoToFs3ErrorCode(errno);
    }
    switch ((try ctx.shared.get(end.shared)).*) {
        .stream => |*sh_s| sh_s.dropped = true,
        .future, .subtask => return WasiP2Error.InvalidHandle,
    }
    end.state = .done;
    return (async_mod.ReturnCode{ .dropped = 0 }).encode();
}

test "D-444 II: fs3FailFileStream — drops the shared stream + resolves the role future" {
    const testing = std.testing;
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();

    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    const end = try ctx.streams.get(pair.readable);
    var role: WasiP2Ctx.FileStreamRole = .{ .fd = 3, .pos = 0, .result_future = fut.readable };

    const rc = try fs3FailFileStream(&ctx, end, &role, .badf);
    try testing.expectEqual((async_mod.ReturnCode{ .dropped = 0 }).encode(), rc);
    try testing.expectEqual(@as(?u8, 2), ctx.host_result_futures.get(fut.readable).?); // badf → ordinal 2
    try testing.expectEqual(async_mod.CopyState.done, end.state);
    try testing.expect((try ctx.shared.get(end.shared)).stream.dropped);
    // A future-kind end is a caller bug, not a stream failure.
    const fut_end = try ctx.streams.get(fut.readable);
    try testing.expectError(WasiP2Error.InvalidHandle, fs3FailFileStream(&ctx, fut_end, &role, .badf));
}

/// `read-directory` (self, retptr) → tuple<stream<directory-entry>, future>:
/// register a P1 readdir cursor under the stream's shared id; the stream-read
/// path marshals `directory-entry` records (24 B, align 4: %type@0 (16),
/// name string@16 (ptr,len)) with names in fresh cabi_realloc backings.
fn fs3ReadDirectory(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    const state_index: u32 = @intCast(ctx.dir_streams.items.len);
    ctx.dir_streams.append(ctx.alloc, .{ .fd = fd, .cookie = 0 }) catch return WasiP2Error.OutOfMemory;
    try ctx.host_dir_streams.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, state_index);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

/// Bind one ASYNC-lowered host import (`canon lower ... async`): the timer
/// waits (genuinely async) + the wasi:filesystem@0.3.0 async funcs
/// (async-EAGER per ADR-0205 D5; flat params ≤ 4 stay flat + retptr, larger
/// signatures spill to one args-ptr + retptr; each returns the packed subtask
/// status). Any op outside this table completes eagerly through its SYNC
/// trampoline only — an async lower of it is unreached by the conformance
/// corpus, so reject until its phase (C sockets / D http) binds it.
pub fn defineAsyncLoweredOp(lk: *Linker, ns: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !void {
    const binds = .{
        .{ adapter.P2Op.clocks_wait_until, fn (*Caller, i64) WasiP2Error!u32, p2WaitUntil },
        .{ adapter.P2Op.clocks_wait_for, fn (*Caller, i64) WasiP2Error!u32, p2WaitFor },
        .{ adapter.P2Op.fs3_stat, fn (*Caller, u32, u32) WasiP2Error!u32, fs3Stat },
        .{ adapter.P2Op.fs3_get_type, fn (*Caller, u32, u32) WasiP2Error!u32, fs3GetType },
        .{ adapter.P2Op.fs3_get_flags, fn (*Caller, u32, u32) WasiP2Error!u32, fs3GetFlags },
        .{ adapter.P2Op.fs3_sync, fn (*Caller, u32, u32) WasiP2Error!u32, fs3Sync },
        .{ adapter.P2Op.fs3_sync_data, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SyncData },
        .{ adapter.P2Op.fs3_metadata_hash, fn (*Caller, u32, u32) WasiP2Error!u32, fs3MetadataHash },
        .{ adapter.P2Op.fs3_set_size, fn (*Caller, u32, i64, u32) WasiP2Error!u32, fs3SetSize },
        .{ adapter.P2Op.fs3_advise, fn (*Caller, u32, i64, i64, u32, u32) WasiP2Error!u32, fs3Advise },
        .{ adapter.P2Op.fs3_stat_at, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!u32, fs3StatAt },
        .{ adapter.P2Op.fs3_metadata_hash_at, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!u32, fs3MetadataHashAt },
        .{ adapter.P2Op.fs3_create_directory_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3CreateDirectoryAt },
        .{ adapter.P2Op.fs3_remove_directory_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3RemoveDirectoryAt },
        .{ adapter.P2Op.fs3_unlink_file_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3UnlinkFileAt },
        .{ adapter.P2Op.fs3_readlink_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3ReadlinkAt },
        .{ adapter.P2Op.fs3_is_same_object, fn (*Caller, u32, u32, u32) WasiP2Error!u32, fs3IsSameObject },
        .{ adapter.P2Op.fs3_open_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3OpenAt },
        .{ adapter.P2Op.fs3_set_times, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SetTimes },
        .{ adapter.P2Op.fs3_set_times_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SetTimesAt },
        .{ adapter.P2Op.fs3_rename_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3RenameAt },
        .{ adapter.P2Op.fs3_symlink_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SymlinkAt },
        .{ adapter.P2Op.fs3_link_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3LinkAt },
        .{ adapter.P2Op.sock3_tcp_connect, fn (*Caller, u32, u32) WasiP2Error!u32, sock3TcpConnect },
        .{ adapter.P2Op.sock3_udp_send, fn (*Caller, u32, u32) WasiP2Error!u32, sock3UdpSend },
        .{ adapter.P2Op.sock3_udp_receive, fn (*Caller, u32, u32) WasiP2Error!u32, sock3UdpReceive },
        .{ adapter.P2Op.sock3_resolve_addresses, fn (*Caller, u32, u32, u32) WasiP2Error!u32, sock3ResolveAddresses },
        .{ adapter.P2Op.http3_client_send, fn (*Caller, u32, u32) WasiP2Error!u32, http3ClientSend },
    };
    inline for (binds) |b| {
        if (op == b[0]) return lk.defineFuncCtx(ns, name, ctx, b[1], b[2]);
    }
    return error.UnsupportedWasiImport;
}

test "D-444 II: defineAsyncLoweredOp — binds table ops, rejects async-lowering a sync-only op" {
    const testing = std.testing;
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var lk = eng.linker();
    defer lk.deinit();

    try defineAsyncLoweredOp(&lk, "wasi:clocks/monotonic-clock@0.3.0", "wait-until", .clocks_wait_until, &ctx);
    // An op outside the async table must be rejected, not silently sync-bound
    // (the fallthrough the classifier's negative path relies on).
    try testing.expectError(error.UnsupportedWasiImport, defineAsyncLoweredOp(&lk, "wasi:random/random@0.2.3", "get-random-bytes", .random_get_bytes, &ctx));
}

/// Read up to `count` `directory-entry` records from the P1 readdir cursor at
/// `dir_streams[state_index]` into guest memory at `ptr` (record = 24 B,
/// align 4: %type variant@0 (16), name string@16 (ptr@16, len@20); names land
/// in fresh cabi_realloc backings). P1's synthetic "."/".." are skipped.
/// Exhaustion with nothing read = the stream closes (DROPPED), so the guest
/// never spins on 0-entry completions.
fn fs3DirStreamRead(ctx: *WasiP2Ctx, state_index: u32, end: *async_mod.StreamFutureEnd, ptr: u32, count: u32) WasiP2Error!u32 {
    if (state_index >= ctx.dir_streams.items.len) return WasiP2Error.InvalidHandle;
    const state = &ctx.dir_streams.items[state_index];
    const mem = try ctx.memory();
    const buf_len: u32 = 4096;
    const buf_ptr = try ctx.reallocGuest(buf_len, 8);
    const used_ptr = try ctx.reallocGuest(4, 4);
    var filled: u32 = 0;
    outer: while (filled < count) {
        const errno = wasi_fd.fdReaddir(ctx.host, mem.slice(), state.fd, buf_ptr, buf_len, state.cookie, used_ptr);
        if (errno != .success) return WasiP2Error.WriteFailed;
        const used = try mem.read(u32, used_ptr);
        if (used < 24) break :outer; // stream end
        const d_next = try mem.read(u64, buf_ptr);
        const d_namlen = try mem.read(u32, buf_ptr + 16);
        const d_type = try mem.read(u8, buf_ptr + 20);
        if (used < 24 + d_namlen) return WasiP2Error.OutOfBounds; // > 4 KiB name
        state.cookie = d_next;
        const name = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const name_ptr = if (d_namlen == 0) 0 else try ctx.reallocGuest(d_namlen, 1);
        if (d_namlen != 0) {
            const dest = mem.sliceAt(name_ptr, d_namlen) catch return WasiP2Error.OutOfBounds;
            // Re-slice the source: reallocGuest may have moved/grown memory.
            const src = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
            @memcpy(dest, src);
        }
        const rec = ptr + filled * 24;
        const p1_ft: wasi_p1.Filetype = @enumFromInt(d_type);
        try writeFs3DescriptorType(mem, rec, p1_ft);
        try mem.write(rec + 16, name_ptr);
        try mem.write(rec + 20, d_namlen);
        filled += 1;
    }
    if (filled == 0) {
        switch ((try ctx.shared.get(end.shared)).*) {
            .stream => |*s| s.dropped = true,
            .future, .subtask => return WasiP2Error.InvalidHandle,
        }
        end.state = .done;
        return (async_mod.ReturnCode{ .dropped = 0 }).encode();
    }
    return (async_mod.ReturnCode{ .completed = @intCast(filled) }).encode();
}

// ============================================================
// wasi:sockets@0.3.0 (ADR-0205 phase C)
// ============================================================
// The 0.3 socket surface: `tcp-socket`/`udp-socket` resources on the CM-async
// data plane. Sync plain funcs (create/bind/listen/receive/getters/setters)
// bind directly; `tcp.connect` + `udp.send`/`udp.receive` arrive ASYNC-LOWERED
// and complete eagerly (blocking on the loopback-class targets the corpus
// exercises); `tcp.listen`/`send`/`receive` mint host SOCKET stream peers
// (accept / tx / rx) like the fs3 file peers.

/// 0.3 `wasi:sockets/types` `error-code` variant ordinals (0.2's `unknown`/
/// `would-block` removed; `other(option<string>)` = 14 is the catch-all).
fn sockErrToFs3Code(e: anyerror) u8 {
    return switch (e) {
        error.AccessDenied, error.PermissionDenied => 0,
        error.OptionUnsupported, error.SocketModeUnsupported, error.Unsupported => 1,
        error.InvalidArgument, error.FamilyMismatch => 2,
        error.OutOfMemory, error.SystemResources => 3,
        error.Timeout, error.ConnectionTimedOut, error.WouldBlock => 4,
        error.InvalidState, error.NotInProgress, error.AlreadyBound, error.AlreadyListening, error.AlreadyConnected, error.NotConnected => 5,
        error.AddressNotAvailable, error.AddressUnavailable => 6,
        error.AddressInUse => 7,
        error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown => 8,
        error.ConnectionRefused => 9,
        error.BrokenPipe => 10,
        error.ConnectionResetByPeer => 11,
        error.ConnectionAborted => 12,
        error.MessageTooBig, error.MessageOversize => 13,
        else => 14,
    };
}

test "D-444 II: sockErrToFs3Code — every 0.3 error-code ordinal, incl. the catch-all" {
    const cases = [_]struct { e: anyerror, code: u8 }{
        .{ .e = error.AccessDenied, .code = 0 },
        .{ .e = error.PermissionDenied, .code = 0 },
        .{ .e = error.Unsupported, .code = 1 },
        .{ .e = error.InvalidArgument, .code = 2 },
        .{ .e = error.FamilyMismatch, .code = 2 },
        .{ .e = error.OutOfMemory, .code = 3 },
        .{ .e = error.Timeout, .code = 4 },
        .{ .e = error.WouldBlock, .code = 4 },
        .{ .e = error.InvalidState, .code = 5 },
        .{ .e = error.AlreadyBound, .code = 5 },
        .{ .e = error.NotConnected, .code = 5 },
        .{ .e = error.AddressNotAvailable, .code = 6 },
        .{ .e = error.AddressInUse, .code = 7 },
        .{ .e = error.NetworkUnreachable, .code = 8 },
        .{ .e = error.HostUnreachable, .code = 8 },
        .{ .e = error.ConnectionRefused, .code = 9 },
        .{ .e = error.BrokenPipe, .code = 10 },
        .{ .e = error.ConnectionResetByPeer, .code = 11 },
        .{ .e = error.ConnectionAborted, .code = 12 },
        .{ .e = error.MessageTooBig, .code = 13 },
        .{ .e = error.Unexpected, .code = 14 }, // catch-all `other`
    };
    for (cases) |c| try std.testing.expectEqual(c.code, sockErrToFs3Code(c.e));
}

/// `result.err(error-code)` for a 0.3 sockets result whose payload slot sits
/// at `payload_off` (the error-code variant: disc u8, `other`'s
/// option<string> at +4 → none).
fn writeSock3Err(mem: Memory, retptr: u32, payload_off: u32, e: anyerror) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + payload_off, sockErrToFs3Code(e));
    try mem.write(retptr + payload_off + 4, @as(u8, 0));
}

fn writeSock3UnitResult(mem: Memory, retptr: u32, err: ?anyerror) WasiP2Error!void {
    if (err) |e| return writeSock3Err(mem, retptr, 4, e);
    try mem.write(retptr, @as(u8, 0));
}

/// Address classification for the WIT's unicast-only contracts.
fn sock3IsMulticastOrBroadcast(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| (a.bytes[0] >= 224 and a.bytes[0] <= 239) or
            (a.bytes[0] == 255 and a.bytes[1] == 255 and a.bytes[2] == 255 and a.bytes[3] == 255),
        .ip6 => |a| a.bytes[0] == 0xff,
    };
}

/// `::ffff:a.b.c.d` — the WIT rejects IPv4-mapped IPv6 on every path.
fn sock3IsV4MappedV6(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => false,
        .ip6 => |a| std.mem.allEqual(u8, a.bytes[0..10], 0) and a.bytes[10] == 0xff and a.bytes[11] == 0xff,
    };
}

fn sock3IsAnyAddr(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| a.bytes[0] == 0 and a.bytes[1] == 0 and a.bytes[2] == 0 and a.bytes[3] == 0,
        .ip6 => |a| std.mem.allEqual(u8, &a.bytes, 0),
    };
}

/// `[static]tcp-socket.create` (family, retptr) → result<own, error-code>.
fn sock3TcpCreate(caller: *Caller, family: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (family > 1) return writeSock3Err(mem, retptr, 4, error.InvalidArgument);
    const idx: u32 = @intCast(ctx.tcp_sockets.items.len);
    ctx.tcp_sockets.append(ctx.alloc, p2sock.TcpSocket.create(@enumFromInt(family))) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

fn sock3TcpSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p2sock.TcpSocket {
    return ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
}

/// `tcp.bind` (self, disc, p0..p10, retptr) — the 0.3 one-shot bind (the 0.2
/// start/finish pair collapsed).
fn sock3TcpBind(caller: *Caller, self: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsV4MappedV6(addr))
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    const io = try ctxIo(ctx);
    sock.startBind(io, addr) catch |e| return writeSock3UnitResult(mem, retptr, e);
    sock.finishBind() catch |e| return writeSock3UnitResult(mem, retptr, e);
    sock.bindNow(io) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

/// `[async-lower]tcp.connect` — spilled args (self@0, addr variant@4: disc
/// u8@+4, payload@+8). Completes eagerly (a blocking loopback-class connect).
fn sock3TcpConnect(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self = try mem.read(u32, argsptr);
    const addr = (try readSock3AddrVariant(mem, argsptr + 4)) orelse {
        try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
        return SUBTASK_RETURNED;
    };
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsAnyAddr(addr) or sock3IsV4MappedV6(addr) or switch (addr) {
        .ip4 => |a| a.port == 0,
        .ip6 => |a| a.port == 0,
    }) {
        try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
        return SUBTASK_RETURNED;
    }
    const sock = try sock3TcpSelf(ctx, self);
    const io = try ctxIo(ctx);
    // Explicitly bound (the 0.3 `bind` → `connect` transition) takes the
    // raw bound-connect composition; everything else the std connect.
    if (sock.state == .bound) {
        sock.connectFromBound(io, addr) catch |e| {
            try writeSock3UnitResult(mem, retptr, e);
            return SUBTASK_RETURNED;
        };
    } else sock.startConnect(io, addr) catch |e| {
        try writeSock3UnitResult(mem, retptr, e);
        return SUBTASK_RETURNED;
    };
    sock.finishConnect() catch |e| {
        try writeSock3UnitResult(mem, retptr, e);
        return SUBTASK_RETURNED;
    };
    try writeSock3UnitResult(mem, retptr, null);
    return SUBTASK_RETURNED;
}

/// An in-memory `ip-socket-address` variant (disc u8@0, payload@4; ipv4
/// record port u16@0 + 4 bytes; ipv6 port@0, flow u32@4, 8×u16 segments@8,
/// scope@24).
fn readSock3AddrVariant(mem: Memory, base: u32) WasiP2Error!?std.Io.net.IpAddress {
    const disc = try mem.read(u8, base);
    const pay = base + 4;
    switch (disc) {
        0 => {
            const port = try mem.read(u16, pay);
            return .{ .ip4 = .{ .port = port, .bytes = .{
                try mem.read(u8, pay + 2),
                try mem.read(u8, pay + 3),
                try mem.read(u8, pay + 4),
                try mem.read(u8, pay + 5),
            } } };
        },
        1 => {
            const port = try mem.read(u16, pay);
            const flow = try mem.read(u32, pay + 4);
            var bytes: [16]u8 = undefined;
            for (0..8) |i| {
                const seg = try mem.read(u16, pay + 8 + @as(u32, @intCast(i * 2)));
                bytes[i * 2] = @intCast(seg >> 8);
                bytes[i * 2 + 1] = @truncate(seg);
            }
            return .{ .ip6 = .{ .port = port, .bytes = bytes, .flow = flow } };
        },
        else => return null,
    }
}

/// `tcp.listen` (self, retptr) → result<stream<tcp-socket>, error-code>: mint
/// the accept stream (host ACCEPT peer keyed by its shared id).
fn sock3TcpListen(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    {
        const sock = try ctxTcpSocket(ctx, rep);
        const io = try ctxIo(ctx);
        sock.listenNow(io) catch |e| return writeSock3Err(mem, retptr, 4, e);
    }
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    try ctx.host_accept_streams.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, rep);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, pair.readable);
}

/// `tcp.send` (self, data readable-stream) → future handle: the host drains
/// the guest's stream into the connected socket.
fn sock3TcpSend(caller: *Caller, self: u32, data_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    const shared_id = blk: {
        const end = try ctx.streams.get(data_handle);
        if (end.kind != .stream) return WasiP2Error.InvalidHandle;
        break :blk end.shared;
    };
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    if ((try ctxTcpSocket(ctx, rep)).state != .connected) {
        // Not connected → err(invalid-state) future (official
        // sockets-tcp-send test_connected_state; mirrors receive).
        try ctx.host_result_futures.put(ctx.alloc, fut.readable, sockErrToFs3Code(error.InvalidState));
        return fut.readable;
    }
    // NOT eager: the future resolves at tx-drop / drain-error time
    // (sock3ResolveSendFuture) — the guest awaits it before writing under
    // `futures::join!`, so an eager ok would hide later drain failures
    // (official sockets-tcp-receive test_drop_read_half).
    try ctx.host_tcp_tx.put(ctx.alloc, shared_id, .{ .rep = rep, .fut = fut.readable });
    try sock3DrainParkedTcpWrite(ctx, shared_id);
    return fut.readable;
}

/// Resolve a `tcp.send` result future (ok = null / err = 0.3 error-code).
/// The send future is NOT eager — the guest usually awaits it BEFORE the
/// data stream is written+dropped (`futures::join!`), so the outcome lands
/// here at drain-error / tx-drop time: record it for a not-yet-issued read,
/// and complete an already-parked read in place (marshal + FUTURE_READ
/// event). First resolution wins (a drain error is not overwritten by the
/// ok of the subsequent drop).
fn sock3ResolveSendFuture(ctx: *WasiP2Ctx, fut_handle: u32, outcome: ?u8) WasiP2Error!void {
    const gop = try ctx.host_result_futures.getOrPut(ctx.alloc, fut_handle);
    if (gop.found_existing) return;
    gop.value_ptr.* = outcome;
    const pr = ctx.pending_reads.get(fut_handle) orelse return;
    const end = ctx.streams.get(fut_handle) catch return;
    const mem = try ctx.memory();
    if (outcome) |code| {
        const buf = mem.sliceAt(pr.ptr, 9) catch return WasiP2Error.OutOfBounds;
        buf[0] = 1;
        buf[4] = code;
        buf[8] = 0;
    } else {
        const buf = mem.sliceAt(pr.ptr, 1) catch return WasiP2Error.OutOfBounds;
        buf[0] = 0;
    }
    end.state = .done;
    end.setPendingEvent(.{ .code = .future_read, .index = fut_handle, .payload = (async_mod.ReturnCode{ .completed = 0 }).encode() });
    _ = ctx.pending_reads.remove(fut_handle);
}

test "D-444 II: sock3ResolveSendFuture — first outcome wins; no parked read = record only" {
    const testing = std.testing;
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();

    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    // No parked read: the outcome is recorded for the later future-read...
    try sock3ResolveSendFuture(&ctx, fut.readable, 9); // connection-refused
    try std.testing.expectEqual(@as(?u8, 9), ctx.host_result_futures.get(fut.readable).?);
    try testing.expectEqual(async_mod.CopyState.idle, (try ctx.streams.get(fut.readable)).state);
    // ...and a second resolution never overwrites the first (drain-error vs
    // late-success races collapse to first-wins).
    try sock3ResolveSendFuture(&ctx, fut.readable, null);
    try testing.expectEqual(@as(?u8, 9), ctx.host_result_futures.get(fut.readable).?);
}

/// A writer parked before `tcp.send` registered the socket sink: drain now.
fn sock3DrainParkedTcpWrite(ctx: *WasiP2Ctx, shared_id: u32) WasiP2Error!void {
    const sh = try ctx.shared.get(shared_id);
    const pending = switch (sh.*) {
        .stream => |*st| st.pending orelse return,
        .future, .subtask => return,
    };
    if (pending.side != .writable) return;
    const pw = ctx.pending_writes.get(pending.waitable) orelse return;
    const role = ctx.host_tcp_tx.get(shared_id) orelse return;
    const mem = try ctx.memory();
    const bytes = mem.sliceAt(pw.ptr, pw.count * pw.elem_size) catch return WasiP2Error.OutOfBounds;
    const sock = try ctxTcpSocket(ctx, role.rep);
    const io = try ctxIo(ctx);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = sock.send(io, bytes[off..]) catch |e| {
            try sock3ResolveSendFuture(ctx, role.fut, sockErrToFs3Code(e));
            break;
        };
        if (n == 0) break;
        off += n;
    }
    const writer = try ctx.streams.get(pending.waitable);
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .stream_write, .index = pending.waitable, .payload = (async_mod.ReturnCode{ .completed = @intCast(pw.count) }).encode() });
    switch (sh.*) {
        .stream => |*st| st.pending = null,
        .future, .subtask => {},
    }
    _ = ctx.pending_writes.remove(pending.waitable);
}

/// `tcp.receive` (self, retptr) → tuple<stream<u8>, future<...>>: the host
/// supplies bytes recv'd from the connected socket.
fn sock3TcpReceive(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    const sockp = try ctxTcpSocket(ctx, rep);
    const usable = sockp.state == .connected and !sockp.rx_taken;
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    if (usable) {
        sockp.rx_taken = true;
        try ctx.host_tcp_rx.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, rep);
        try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    } else {
        // Not connected (or `receive` already taken — it is single-shot) →
        // err(invalid-state) future + an immediately-closed stream
        // (official sockets-tcp-receive test_connected_state /
        // test_multiple_receive).
        try ctx.host_result_futures.put(ctx.alloc, fut.readable, sockErrToFs3Code(error.InvalidState));
        switch ((try ctx.shared.get((try ctx.streams.get(pair.readable)).shared)).*) {
            .stream => |*st| st.dropped = true,
            else => {},
        }
    }
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

fn sock3TcpLocalAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    const addr = sock.localAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3TcpRemoteAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    const addr = sock.remoteAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3TcpIsListening(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try sock3TcpSelf(ctx, self);
    return @intFromBool(sock.state == .listening);
}

fn sock3TcpFamily(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try sock3TcpSelf(ctx, self);
    return @intFromEnum(sock.family);
}

fn sock3TcpSetBacklog(caller: *Caller, self: u32, value: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    if (value == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    sock.setListenBacklog(value) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

// -- TCP option getters/setters (stored-value model; the OS socket is lazy,
// so options are recorded with the spec's clamp-permitting semantics) --

fn writeSock3OkU8(mem: Memory, retptr: u32, v: u8) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, v);
}

fn writeSock3OkU32(mem: Memory, retptr: u32, v: u32) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, v);
}

fn writeSock3OkU64(mem: Memory, retptr: u32, v: u64) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 8, v);
}

fn sock3TcpKaEnabledGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU8(mem, retptr, @intFromBool((try sock3TcpSelf(ctx, self)).opt_keep_alive));
}

fn sock3TcpKaEnabledSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    (try sock3TcpSelf(ctx, self)).opt_keep_alive = value != 0;
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpKaIdleGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_ka_idle_ns);
}

fn sock3TcpKaIdleSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    // Clamp to whole seconds ≥ 1 (TCP_KEEPIDLE granularity) — read-back may
    // differ from the set value per the WIT contract.
    (try sock3TcpSelf(ctx, self)).opt_ka_idle_ns = @max(v - v % std.time.ns_per_s, std.time.ns_per_s);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpKaIntervalGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_ka_interval_ns);
}

fn sock3TcpKaIntervalSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_ka_interval_ns = @max(v - v % std.time.ns_per_s, std.time.ns_per_s);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpKaCountGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU32(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_ka_count);
}

fn sock3TcpKaCountSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (value == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_ka_count = value;
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpHopGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU8(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_hop_limit);
}

fn sock3TcpHopSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (value == 0 or value > 255) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_hop_limit = @intCast(value);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpRcvbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_rcvbuf);
}

fn sock3TcpRcvbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_rcvbuf = @min(v, 8 << 20); // clamp to 8 MiB
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpSndbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_sndbuf);
}

fn sock3TcpSndbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_sndbuf = @min(v, 8 << 20);
    try writeSock3UnitResult(mem, retptr, null);
}

// -- UDP --

fn sock3UdpCreate(caller: *Caller, family: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (family > 1) return writeSock3Err(mem, retptr, 4, error.InvalidArgument);
    const idx: u32 = @intCast(ctx.udp_sockets.items.len);
    ctx.udp_sockets.append(ctx.alloc, p2sock.UdpSocket.create(@enumFromInt(family))) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.UDP_SOCKET3_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

fn sock3UdpSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p2sock.UdpSocket {
    return ctxUdpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.UDP_SOCKET3_RT, self));
}

fn sock3UdpBind(caller: *Caller, self: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsV4MappedV6(addr))
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    sock.bind(try ctxIo(ctx), addr) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpConnect(caller: *Caller, self: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsAnyAddr(addr) or sock3IsV4MappedV6(addr) or switch (addr) {
        .ip4 => |a| a.port == 0,
        .ip6 => |a| a.port == 0,
    }) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    sock.connect(try ctxIo(ctx), addr) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpDisconnect(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    sock.disconnect(try ctxIo(ctx)) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

/// Structural equality of two socket addresses (port + raw address bytes).
fn sock3AddrEql(a: std.Io.net.IpAddress, b: std.Io.net.IpAddress) bool {
    return switch (a) {
        .ip4 => |x| switch (b) {
            .ip4 => |y| x.port == y.port and std.mem.eql(u8, &x.bytes, &y.bytes),
            .ip6 => false,
        },
        .ip6 => |x| switch (b) {
            .ip6 => |y| x.port == y.port and std.mem.eql(u8, &x.bytes, &y.bytes),
            .ip4 => false,
        },
    };
}

/// `[async-lower]udp.send` — spilled args: self@0, data list@4 (ptr,len),
/// remote option<ip-socket-address>@12 (disc u8@12, addr variant@16).
fn sock3UdpSend(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self = try mem.read(u32, argsptr);
    const data_ptr = try mem.read(u32, argsptr + 4);
    const data_len = try mem.read(u32, argsptr + 8);
    const has_remote = (try mem.read(u8, argsptr + 12)) != 0;
    const sock = try sock3UdpSelf(ctx, self);
    const dest: std.Io.net.IpAddress = blk: {
        if (has_remote) {
            const a = (try readSock3AddrVariant(mem, argsptr + 16)) orelse {
                try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
                return SUBTASK_RETURNED;
            };
            break :blk a;
        }
        break :blk sock.remote orelse {
            try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
            return SUBTASK_RETURNED;
        };
    };
    // Pre-OS validation — an EINVAL sendto is an errnoBug PANIC in the
    // pinned stdlib, so the invalid-argument classes never reach the OS:
    // family mismatch / unspecified ip / port 0, and a connected socket
    // only sends to its own remote.
    if (has_remote) {
        const fam_ok = switch (dest) {
            .ip4 => sock.family == .ipv4,
            .ip6 => sock.family == .ipv6,
        };
        const port_zero = switch (dest) {
            .ip4 => |a| a.port == 0,
            .ip6 => |a| a.port == 0,
        };
        if (!fam_ok or port_zero or sock3IsAnyAddr(dest)) {
            try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
            return SUBTASK_RETURNED;
        }
        if (sock.remote) |r| if (!sock3AddrEql(dest, r)) {
            try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
            return SUBTASK_RETURNED;
        };
    }
    const bytes = mem.sliceAt(data_ptr, data_len) catch return WasiP2Error.OutOfBounds;
    sock.sendTo(try ctxIo(ctx), dest, bytes) catch |e| {
        try writeSock3UnitResult(mem, retptr, e);
        return SUBTASK_RETURNED;
    };
    try writeSock3UnitResult(mem, retptr, null);
    return SUBTASK_RETURNED;
}

/// `[async-lower]udp.receive` (self, retptr) →
/// result<tuple<list<u8>, ip-socket-address>, error-code>: ok payload@4 =
/// list (ptr,len)@4..12 + address variant@12 (disc u8@12, case record@16).
fn sock3UdpReceive(caller: *Caller, self: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.UDP_SOCKET3_RT, self);
    const sock = try ctxUdpSocket(ctx, rep);
    if (sock.socket == null) {
        // Unbound → invalid-state (official udp-receive test_not_bound).
        try writeSock3Err(mem, retptr, 4, error.InvalidState);
        return SUBTASK_RETURNED;
    }
    if (sock.readyIn() catch false) {
        try sock3UdpReceiveComplete(ctx, rep, retptr);
        return SUBTASK_RETURNED;
    }
    // No datagram queued → park as a subtask waitable (the timer pattern):
    // `pollBlockedUdpReceives` completes it at readiness. Receiving eagerly
    // here would block the whole runtime and starve the guest's own
    // sending task (official udp-receive test_receive_data joins both).
    const h = try ctx.streams.add(.{
        .kind = .subtask,
        .side = .readable,
        .elem_type = null,
        .subtask_state = .started,
    });
    try ctx.blocked_udp_receives.put(ctx.alloc, h, .{ .rep = rep, .retptr = retptr });
    return @intFromEnum(async_mod.SubtaskState.started) | (h << 4);
}

/// The receive proper: recvfrom into a fresh guest buffer + marshal the
/// `result<tuple<list<u8>, ip-socket-address>, _>` ok payload at `retptr`.
/// Shared by the eager (data already queued) and parked-completion paths.
fn sock3UdpReceiveComplete(ctx: *WasiP2Ctx, rep: u32, retptr: u32) WasiP2Error!void {
    const mem = try ctx.memory();
    const sock = try ctxUdpSocket(ctx, rep);
    const buf_ptr = try ctx.reallocGuest(65536, 1);
    const buf = mem.sliceAt(buf_ptr, 65536) catch return WasiP2Error.OutOfBounds;
    const r = sock.receiveFrom(try ctxIo(ctx), buf) catch |e| {
        return writeSock3Err(mem, retptr, 4, e);
    };
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, buf_ptr);
    try mem.write(retptr + 8, @as(u32, @intCast(r.n)));
    switch (r.from) {
        .ip4 => |a| {
            try mem.write(retptr + 12, @as(u8, 0));
            try mem.write(retptr + 16, a.port);
            for (a.bytes, 0..) |b, i| try mem.write(retptr + 18 + @as(u32, @intCast(i)), b);
        },
        .ip6 => |a| {
            try mem.write(retptr + 12, @as(u8, 1));
            try mem.write(retptr + 16, a.port);
            try mem.write(retptr + 20, a.flow);
            for (0..8) |i| {
                const seg: u16 = (@as(u16, a.bytes[i * 2]) << 8) | a.bytes[i * 2 + 1];
                try mem.write(retptr + 24 + @as(u32, @intCast(i * 2)), seg);
            }
            try mem.write(retptr + 40, @as(u32, 0)); // scope-id
        },
    }
}

// ============================================================
// wasi:http/types@0.3.0 (ADR-0205 phase D)
// ============================================================
// The `fields` resource: data model in src/wasi/p3_http.zig; these
// trampolines marshal guest memory. Canonical shapes: field-name = string
// (ptr,len), field-value = list<u8> (ptr,len), entries/copy-all elems =
// (name_ptr, name_len, val_ptr, val_len) 16 B; `result<_, header-error>` =
// disc u8@0, err variant disc u8@4, `other`'s option<string> none u8@8.

fn ctxHttpFields(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p3http.HttpFields {
    if (rep >= ctx.http_fields.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_fields.items[rep];
}

fn http3FieldsSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpFields {
    const rep = ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, self) catch
        try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, self);
    return ctxHttpFields(ctx, rep);
}

fn http3MintFields(ctx: *WasiP2Ctx, fields: p3http.HttpFields) WasiP2Error!u32 {
    const idx: u32 = @intCast(ctx.http_fields.items.len);
    ctx.http_fields.append(ctx.alloc, fields) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_RT, idx);
}

/// `result<_, header-error>` (ok = null).
fn writeHeaderErrResult(mem: Memory, retptr: u32, e: ?p3http.FieldsError) WasiP2Error!void {
    if (e) |err| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, p3http.headerErrorOrdinal(err));
        try mem.write(retptr + 8, @as(u8, 0)); // other's option<string>: none
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3FieldsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return http3MintFields(ctx, .{});
}

fn http3FieldsFromList(caller: *Caller, entries_ptr: u32, entries_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    var fields: p3http.HttpFields = .{};
    var i: u32 = 0;
    while (i < entries_len) : (i += 1) {
        const rec = entries_ptr + i * 16;
        const name = mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4)) catch return WasiP2Error.OutOfBounds;
        const value = mem.sliceAt(try mem.read(u32, rec + 8), try mem.read(u32, rec + 12)) catch return WasiP2Error.OutOfBounds;
        if (dbg.on("async.host")) std.debug.print("[host] fields.from-list [{d}] name='{s}' value='{s}'\n", .{ i, name, value });
        fields.appendChecked(ctx.alloc, name, value) catch |e| {
            fields.deinit(ctx.alloc);
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 4, p3http.headerErrorOrdinal(e));
            try mem.write(retptr + 8, @as(u8, 0));
            return;
        };
    }
    const handle = try http3MintFields(ctx, fields);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

/// Marshal one nested byte blob (string / list<u8>) into its OWN guest
/// allocation. Nested lists must NOT share the outer table's block: the
/// guest's lift takes per-element buffer OWNERSHIP (Vec::from_raw_parts)
/// and frees the outer table separately — a packed single block gets
/// recycled by the guest allocator mid-lift, corrupting the data. A
/// zero-length blob writes a 4-aligned dangling pointer (the guest never
/// dereferences or frees a capacity-0 buffer).
fn http3AllocBlob(ctx: *WasiP2Ctx, mem: Memory, bytes: []const u8) WasiP2Error!u32 {
    if (bytes.len == 0) return 4;
    const p = try ctx.reallocGuest(@intCast(bytes.len), 1);
    const dest = mem.sliceAt(p, @intCast(bytes.len)) catch return WasiP2Error.OutOfBounds;
    @memcpy(dest, bytes);
    return p;
}

/// Marshal `list<field-value>`: the elem table is one allocation, each
/// value another (see `http3AllocBlob`); (ptr,len) lands at `retptr`.
fn http3WriteValueList(ctx: *WasiP2Ctx, mem: Memory, retptr: u32, values: []const []const u8) WasiP2Error!void {
    const base = if (values.len == 0) 4 else try ctx.reallocGuest(@intCast(values.len * 8), 4);
    for (values, 0..) |v, i| {
        const p = try http3AllocBlob(ctx, mem, v);
        const rec = base + @as(u32, @intCast(i * 8));
        try mem.write(rec, p);
        try mem.write(rec + 4, @as(u32, @intCast(v.len)));
    }
    try mem.write(retptr, base);
    try mem.write(retptr + 4, @as(u32, @intCast(values.len)));
}

fn http3FieldsGet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    fields.get(&values, ctx.alloc, name) catch return WasiP2Error.OutOfMemory;
    try http3WriteValueList(ctx, mem, retptr, values.items);
}

fn http3FieldsHas(caller: *Caller, self: u32, name_ptr: u32, name_len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    return @intFromBool(fields.has(name));
}

fn http3FieldsSet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, values_ptr: u32, values_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    var i: u32 = 0;
    while (i < values_len) : (i += 1) {
        const rec = values_ptr + i * 8;
        const v = mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4)) catch return WasiP2Error.OutOfBounds;
        values.append(ctx.alloc, v) catch return WasiP2Error.OutOfMemory;
    }
    fields.set(ctx.alloc, name, values.items) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    fields.delete(ctx.alloc, name) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsGetAndDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |v| ctx.alloc.free(v);
        out.deinit(ctx.alloc);
    }
    fields.getAndDelete(&out, ctx.alloc, name) catch |e| {
        // result<list<field-value>, header-error> err: disc@0, err disc@4,
        // other's option none@8 (same offsets as the unit form).
        return writeHeaderErrResult(mem, retptr, e);
    };
    try mem.write(retptr, @as(u8, 0));
    try http3WriteValueList(ctx, mem, retptr + 4, out.items);
}

fn http3FieldsAppend(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, value_ptr: u32, value_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    const value = mem.sliceAt(value_ptr, value_len) catch return WasiP2Error.OutOfBounds;
    fields.append(ctx.alloc, name, value) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsCopyAll(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    // Elem table = one allocation; each name string and value list its own
    // (per-element buffer ownership — see http3AllocBlob).
    const items = fields.entries.items;
    const base = if (items.len == 0) 4 else try ctx.reallocGuest(@intCast(items.len * 16), 4);
    for (items, 0..) |p, i| {
        const np = try http3AllocBlob(ctx, mem, p.name);
        const vp = try http3AllocBlob(ctx, mem, p.value);
        const rec = base + @as(u32, @intCast(i * 16));
        try mem.write(rec, np);
        try mem.write(rec + 4, @as(u32, @intCast(p.name.len)));
        try mem.write(rec + 8, vp);
        try mem.write(rec + 12, @as(u32, @intCast(p.value.len)));
    }
    try mem.write(retptr, base);
    try mem.write(retptr + 4, @as(u32, @intCast(items.len)));
}

fn http3FieldsClone(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const src = try http3FieldsSelf(ctx, self);
    var copy: p3http.HttpFields = .{};
    src.cloneInto(ctx.alloc, &copy) catch {
        copy.deinit(ctx.alloc);
        return WasiP2Error.OutOfMemory;
    };
    return http3MintFields(ctx, copy);
}

// -- request / response / request-options (ADR-0205 phase D-2) --

/// Release a stream/future end TRANSFERRED into a request/response at
/// `new` time (the guest's own handle moved to the host): the peer must
/// observe DROPPED or its writer task never completes.
pub fn http3DropTransferredEnd(ctx: *WasiP2Ctx, handle: u32) void {
    if (handle == 0) return;
    _ = ctx.host_result_futures.remove(handle);
    _ = ctx.pending_reads.remove(handle);
    // EXEMPT-FALLBACK: destructor — a stale/already-dropped end is benign (D-568)
    async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, handle) catch {};
}

fn http3RequestSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpRequest {
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, self);
    if (rep >= ctx.http_requests.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_requests.items[rep];
}

fn http3ReqoptsSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpRequestOptions {
    const rep = ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_RT, self) catch
        try ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_VIEW_RT, self);
    if (rep >= ctx.http_reqopts.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_reqopts.items[rep];
}

fn http3ResponseSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpResponse {
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_RESPONSE_RT, self);
    if (rep >= ctx.http_responses.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_responses.items[rep];
}

/// `request.new` (headers, option<stream<u8>>, trailers future,
/// option<own<request-options>>, retptr) — consumes the headers (and
/// options) own handles: their storage now belongs to the request and both
/// become immutable. Returns tuple<request, future<result<_, error-code>>>
/// at retptr; the transmission future stays unresolved until a send.
fn http3RequestNew(caller: *Caller, headers: u32, contents_disc: u32, contents: u32, trailers_fut: u32, opts_disc: u32, opts: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const headers_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    (try ctxHttpFields(ctx, headers_rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    var options_rep: ?u32 = null;
    if (opts_disc != 0) {
        const orep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_RT, opts);
        (try http3ReqoptsSelf(ctx, opts)).immutable = true;
        _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQOPTS_RT, opts);
        options_rep = orep;
    }
    const idx: u32 = @intCast(ctx.http_requests.items.len);
    ctx.http_requests.append(ctx.alloc, .{
        .headers_rep = headers_rep,
        .options_rep = options_rep,
        .contents_stream = if (contents_disc != 0) contents else null,
        .trailers_future = trailers_fut,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, idx);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try mem.write(retptr, handle);
    try mem.write(retptr + 4, fut.readable);
}

fn http3RequestGetMethod(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    switch (req.method) {
        .other => |s| {
            try mem.write(retptr, @as(u8, 9));
            const p = try http3AllocBlob(ctx, mem, s);
            try mem.write(retptr + 4, p);
            try mem.write(retptr + 8, @as(u32, @intCast(s.len)));
        },
        else => try mem.write(retptr, @as(u8, @intFromEnum(std.meta.activeTag(req.method)))),
    }
}

fn http3RequestSetMethod(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc < 9) {
        req.method.deinit(ctx.alloc);
        req.method = switch (disc) {
            0 => .get,
            1 => .head,
            2 => .post,
            3 => .put,
            4 => .delete,
            5 => .connect,
            6 => .options,
            7 => .trace,
            8 => .patch,
            else => unreachable,
        };
        return 0;
    }
    const name = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    if (!p3http.validMethod(name)) return 1;
    // other("GET") etc. normalizes to the enum case (wasi-http#194).
    inline for (p3http.Method.known_names) |k| {
        if (std.mem.eql(u8, name, k.name)) {
            req.method.deinit(ctx.alloc);
            req.method = @unionInit(p3http.Method, @tagName(k.tag), {});
            return 0;
        }
    }
    const copy = ctx.alloc.dupe(u8, name) catch return WasiP2Error.OutOfMemory;
    req.method.deinit(ctx.alloc);
    req.method = .{ .other = copy };
    return 0;
}

/// Write `option<string>` (disc u8@0, ptr@4, len@8) from an optional slice.
fn http3WriteOptString(ctx: *WasiP2Ctx, mem: Memory, retptr: u32, s: ?[]const u8) WasiP2Error!void {
    if (s) |str| {
        try mem.write(retptr, @as(u8, 1));
        const p = try http3AllocBlob(ctx, mem, str);
        try mem.write(retptr + 4, p);
        try mem.write(retptr + 8, @as(u32, @intCast(str.len)));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// Store an optional validated string field (dupe + free old).
fn http3SetOptString(ctx: *WasiP2Ctx, slot: *?[]u8, s: ?[]const u8) WasiP2Error!void {
    if (slot.*) |old| ctx.alloc.free(old);
    slot.* = if (s) |str| ctx.alloc.dupe(u8, str) catch return WasiP2Error.OutOfMemory else null;
}

fn http3RequestGetPwq(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    try http3WriteOptString(ctx, mem, retptr, req.path_with_query);
}

fn http3RequestSetPwq(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc == 0) {
        try http3SetOptString(ctx, &req.path_with_query, null);
        return 0;
    }
    const s = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    if (!p3http.validPathWithQuery(s)) return 1;
    // The corpus pins "" → "/" (an empty path serializes as "/").
    try http3SetOptString(ctx, &req.path_with_query, if (s.len == 0) "/" else s);
    return 0;
}

fn http3RequestGetScheme(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    const sc = req.scheme orelse {
        try mem.write(retptr, @as(u8, 0));
        return;
    };
    try mem.write(retptr, @as(u8, 1));
    switch (sc) {
        .http => try mem.write(retptr + 4, @as(u8, 0)),
        .https => try mem.write(retptr + 4, @as(u8, 1)),
        .other => |s| {
            try mem.write(retptr + 4, @as(u8, 2));
            const p = try http3AllocBlob(ctx, mem, s);
            try mem.write(retptr + 8, p);
            try mem.write(retptr + 12, @as(u32, @intCast(s.len)));
        },
    }
}

fn http3RequestSetScheme(caller: *Caller, self: u32, opt_disc: u32, scheme_disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (opt_disc == 0) {
        if (req.scheme) |*old| old.deinit(ctx.alloc);
        req.scheme = null;
        return 0;
    }
    var next: p3http.Scheme = undefined;
    switch (scheme_disc) {
        0 => next = .http,
        1 => next = .https,
        else => {
            const s = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
            if (!p3http.validScheme(s)) return 1;
            // other("http"/"https") normalizes to the enum case (#194).
            if (std.mem.eql(u8, s, "http")) {
                next = .http;
            } else if (std.mem.eql(u8, s, "https")) {
                next = .https;
            } else {
                next = .{ .other = ctx.alloc.dupe(u8, s) catch return WasiP2Error.OutOfMemory };
            }
        },
    }
    if (req.scheme) |*old| old.deinit(ctx.alloc);
    req.scheme = next;
    return 0;
}

fn http3RequestGetAuthority(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    try http3WriteOptString(ctx, mem, retptr, req.authority);
}

fn http3RequestSetAuthority(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc == 0) {
        try http3SetOptString(ctx, &req.authority, null);
        return 0;
    }
    const s = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    if (!p3http.validAuthority(s)) return 1;
    try http3SetOptString(ctx, &req.authority, s);
    return 0;
}

fn http3RequestGetOptions(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (req.options_rep) |orep| {
        const h = try ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_VIEW_RT, orep);
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, h);
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3RequestGetHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const req = try http3RequestSelf(ctx, self);
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, req.headers_rep);
}

/// `response.new` (headers, option<stream<u8>>, trailers future, retptr) →
/// tuple<response, future<result<_, error-code>>>.
fn http3ResponseNew(caller: *Caller, headers: u32, contents_disc: u32, contents: u32, trailers_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const headers_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    (try ctxHttpFields(ctx, headers_rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    const idx: u32 = @intCast(ctx.http_responses.items.len);
    ctx.http_responses.append(ctx.alloc, .{
        .headers_rep = headers_rep,
        .contents_stream = if (contents_disc != 0) contents else null,
        .trailers_future = trailers_fut,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_RESPONSE_RT, idx);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try mem.write(retptr, handle);
    try mem.write(retptr + 4, fut.readable);
}

fn http3ResponseGetStatus(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return (try http3ResponseSelf(ctx, self)).status;
}

fn http3ResponseSetStatus(caller: *Caller, self: u32, status: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const resp = try http3ResponseSelf(ctx, self);
    // A valid HTTP status code is 100..=599.
    if (status < 100 or status > 599) return 1;
    resp.status = @intCast(status);
    return 0;
}

fn http3ResponseGetHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const resp = try http3ResponseSelf(ctx, self);
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, resp.headers_rep);
}

fn http3ReqoptsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const idx: u32 = @intCast(ctx.http_reqopts.items.len);
    ctx.http_reqopts.append(ctx.alloc, .{}) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_RT, idx);
}

/// `option<duration>`: disc u8@0, u64 value@8 (align 8).
fn http3WriteOptDuration(mem: Memory, retptr: u32, v: ?u64) WasiP2Error!void {
    if (v) |ns| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 8, ns);
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// `result<_, request-options-error>`: disc@0; err variant disc@4 (0 =
/// not-supported, 1 = immutable, 2 = other), other's option none@8.
fn http3WriteReqoptsSetResult(mem: Memory, retptr: u32, immutable: bool) WasiP2Error!void {
    if (immutable) {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, @as(u8, 1));
        try mem.write(retptr + 8, @as(u8, 0));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3ReqoptsConnectGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).connect_timeout_ns);
}

fn http3ReqoptsConnectSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.connect_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

fn http3ReqoptsFirstByteGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).first_byte_timeout_ns);
}

fn http3ReqoptsFirstByteSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.first_byte_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

fn http3ReqoptsBetweenBytesGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).between_bytes_timeout_ns);
}

fn http3ReqoptsBetweenBytesSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.between_bytes_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

/// `[static]request.consume-body` (this, res future, retptr) →
/// tuple<stream<u8>, future<result<option<trailers>, error-code>>>: hand
/// out the stored body ends. A bodiless request gets an immediately-CLOSED
/// stream (collect → empty) and, when no guest trailers future was
/// transferred (harness-built requests), a host-resolved `ok(none)` one.
/// Consumes `this` (handle slot only — headers/options views stay valid)
/// and releases the guest's error-report future.
fn http3RequestConsumeBody(caller: *Caller, this: u32, res_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, this);
    const contents = req.contents_stream orelse blk: {
        const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
        // Dropping the writable half closes the stream for the reader.
        try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, pair.writable);
        break :blk pair.readable;
    };
    const trailers = if (req.trailers_future != 0) req.trailers_future else blk: {
        const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        try ctx.host_trailer_ok_futures.put(ctx.alloc, fut.readable, {});
        break :blk fut.readable;
    };
    req.contents_stream = null;
    req.trailers_future = 0;
    http3DropTransferredEnd(ctx, res_fut);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQUEST_RT, this);
    try mem.write(retptr, contents);
    try mem.write(retptr + 4, trailers);
}

/// `[static]response.consume-body` — the response-side mirror of the
/// request form: hand out the stored body ends (host-built responses from
/// `client.send` carry `host_body_bytes`-served streams; a bodiless one
/// gets a CLOSED stream and a host-resolved `ok(none)` trailers future).
fn http3ResponseConsumeBody(caller: *Caller, this: u32, res_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const resp = try http3ResponseSelf(ctx, this);
    const contents = resp.contents_stream orelse blk: {
        const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
        try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, pair.writable);
        break :blk pair.readable;
    };
    const trailers = if (resp.trailers_future != 0) resp.trailers_future else blk: {
        const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        try ctx.host_trailer_ok_futures.put(ctx.alloc, fut.readable, {});
        break :blk fut.readable;
    };
    resp.contents_stream = null;
    resp.trailers_future = 0;
    http3DropTransferredEnd(ctx, res_fut);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_RESPONSE_RT, this);
    try mem.write(retptr, contents);
    try mem.write(retptr + 4, trailers);
}

/// `[async-lower]wasi:http/client.send` (request, retptr): consumes the
/// request handle and PARKS as a subtask — the request body is a guest
/// stream fed by a guest writer task, so the blocking exchange can only
/// run once the guest closes it (`pollPendingClientSends`). A bodiless
/// request resolves at the first poll (its shared is never written).
fn http3ClientSend(caller: *Caller, request: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, request);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQUEST_RT, request);
    const h = try ctx.streams.add(.{
        .kind = .subtask,
        .side = .readable,
        .elem_type = null,
        .subtask_state = .started,
    });
    const pcs = ctx.alloc.create(PendingClientSend) catch return WasiP2Error.OutOfMemory;
    pcs.* = .{ .req_rep = rep, .retptr = retptr, .subtask = h };
    ctx.pending_client_sends.append(ctx.alloc, pcs) catch {
        ctx.alloc.destroy(pcs);
        return WasiP2Error.OutOfMemory;
    };
    const req = try ctxHttpRequest(ctx, rep);
    if (req.contents_stream) |cs| {
        const end = try ctx.streams.get(cs);
        pcs.body_shared = end.shared;
        try http3RegisterCaptureSink(ctx, end.shared, &pcs.body);
    }
    // Release the request's trailers future (the guest holds the writer and
    // parks it; nothing reads request trailers on the client path) so its
    // writer observes DROPPED. `resources.drop` here bypasses p2ResourceDrop,
    // so the transferred-end release must be explicit.
    http3DropTransferredEnd(ctx, req.trailers_future);
    req.trailers_future = 0;
    return @intFromEnum(async_mod.SubtaskState.started) | (h << 4);
}

fn ctxHttpRequest(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p3http.HttpRequest {
    if (rep >= ctx.http_requests.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_requests.items[rep];
}

/// Resolve parked `client.send`s whose request body is complete (the body
/// stream's writer dropped — or no body at all): run the blocking HTTP
/// exchange, mint the response resource, marshal the result, and flip the
/// subtask to RETURNED (the timer-fire shape).
pub fn pollPendingClientSends(self: *WasiP2Ctx) WasiP2Error!bool {
    if (self.pending_client_sends.items.len == 0) return false;
    var progressed = false;
    var i: usize = 0;
    while (i < self.pending_client_sends.items.len) {
        const pcs = self.pending_client_sends.items[i];
        const body_done = if (pcs.body_shared) |sid| blk: {
            const sh = self.shared.get(sid) catch break :blk true;
            break :blk switch (sh.*) {
                .stream => |s| s.dropped,
                .future, .subtask => true,
            };
        } else true;
        if (!body_done) {
            i += 1;
            continue;
        }
        try http3PerformSend(self, pcs);
        if (pcs.body_shared) |sid| _ = self.host_capture_sinks.remove(sid);
        pcs.body.deinit(self.alloc);
        self.alloc.destroy(pcs);
        _ = self.pending_client_sends.orderedRemove(i);
        progressed = true;
    }
    return progressed;
}

/// The blocking HTTP exchange for one resolved `client.send`: std.http
/// Client against the request's scheme/authority/path, the response minted
/// as a host-built resource (`host_body_bytes`-served body; trailers via
/// the resolved-ok(none) future at consume-body). result<own<response>,
/// error-code> marshals at retptr with payload offset 8 (error-code
/// carries u64 cases).
fn http3PerformSend(self: *WasiP2Ctx, pcs: *PendingClientSend) WasiP2Error!void {
    const mem = try self.memory();
    const io = try ctxIo(self);
    const req = try ctxHttpRequest(self, pcs.req_rep);
    const fail = struct {
        fn write(m: Memory, retptr: u32, sub: *async_mod.StreamFutureEnd, h: u32) WasiP2Error!void {
            try m.write(retptr, @as(u8, 1));
            // error-code `internal-error(option<string>)` = ordinal 37, none.
            try m.write(retptr + 8, @as(u8, 37));
            try m.write(retptr + 16, @as(u8, 0));
            sub.subtask_state = .returned;
            sub.setPendingEvent(.{ .code = .subtask, .index = h, .payload = @intFromEnum(async_mod.SubtaskState.returned) });
        }
    };
    const sub = try self.streams.get(pcs.subtask);
    const authority = req.authority orelse return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    const path = req.path_with_query orelse "/";
    const url = std.fmt.allocPrint(self.alloc, "http://{s}{s}", .{ authority, path }) catch return WasiP2Error.OutOfMemory;
    defer self.alloc.free(url);
    const uri = std.Uri.parse(url) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    const method: std.http.Method = switch (req.method) {
        .get => .GET,
        .head => .HEAD,
        .post => .POST,
        .put => .PUT,
        .delete => .DELETE,
        .connect => .CONNECT,
        .options => .OPTIONS,
        .trace => .TRACE,
        .patch => .PATCH,
        .other => return fail.write(mem, pcs.retptr, sub, pcs.subtask),
    };
    // Request headers from the fields model; content-length is computed by
    // the std client from the body.
    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(self.alloc);
    if (req.headers_rep < self.http_fields.items.len) {
        for (self.http_fields.items[req.headers_rep].entries.items) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, "content-length")) continue;
            extra.append(self.alloc, .{ .name = p.name, .value = p.value }) catch return WasiP2Error.OutOfMemory;
        }
    }
    var client: std.http.Client = .{ .allocator = self.alloc, .io = io };
    defer client.deinit();
    var hreq = client.request(method, uri, .{ .extra_headers = extra.items }) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    defer hreq.deinit();
    hreq.sendBodyComplete(pcs.body.items) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    var redirect_buf: [2048]u8 = undefined;
    var hresp = hreq.receiveHead(&redirect_buf) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);

    // Response headers → an immutable fields entry.
    const fields_idx: u32 = @intCast(self.http_fields.items.len);
    self.http_fields.append(self.alloc, .{}) catch return WasiP2Error.OutOfMemory;
    var hit = hresp.head.iterateHeaders();
    while (hit.next()) |hd| {
        self.http_fields.items[fields_idx].appendChecked(self.alloc, hd.name, hd.value) catch continue;
    }
    self.http_fields.items[fields_idx].immutable = true;

    // Response body → a host-served stream.
    var transfer_buf: [4096]u8 = undefined;
    const rdr = hresp.reader(&transfer_buf);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(self.alloc);
    while (true) {
        const chunk = rdr.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return fail.write(mem, pcs.retptr, sub, pcs.subtask),
        };
        body.appendSlice(self.alloc, chunk) catch return WasiP2Error.OutOfMemory;
        rdr.toss(chunk.len);
    }
    var contents: ?u32 = null;
    if (body.items.len > 0) {
        const pair = try async_mod.newStreamPair(&self.streams, &self.shared, null);
        const shared_id = (try self.streams.get(pair.readable)).shared;
        const copy = self.alloc.dupe(u8, body.items) catch return WasiP2Error.OutOfMemory;
        try self.host_body_bytes.put(self.alloc, shared_id, .{ .data = copy });
        contents = pair.readable;
    }
    const resp_idx: u32 = @intCast(self.http_responses.items.len);
    self.http_responses.append(self.alloc, .{
        .status = @intFromEnum(hresp.head.status),
        .headers_rep = fields_idx,
        .contents_stream = contents,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try self.resources.new(WasiP2Ctx.HTTP_RESPONSE_RT, resp_idx);
    try mem.write(pcs.retptr, @as(u8, 0));
    try mem.write(pcs.retptr + 8, handle);
    // Re-fetch: newStreamPair/http_* appends above may have grown the
    // streams table, dangling the `sub` pointer taken at entry.
    const sub2 = try self.streams.get(pcs.subtask);
    sub2.subtask_state = .returned;
    sub2.setPendingEvent(.{ .code = .subtask, .index = pcs.subtask, .payload = @intFromEnum(async_mod.SubtaskState.returned) });
}

/// Register a harness capture sink for `shared_id`, draining a write that
/// parked before registration (the guest's spawned body writer may run
/// before the harness learns the response's stream id).
pub fn http3RegisterCaptureSink(ctx: *WasiP2Ctx, shared_id: u32, cap: *std.ArrayList(u8)) WasiP2Error!void {
    try ctx.host_capture_sinks.put(ctx.alloc, shared_id, cap);
    const sh = try ctx.shared.get(shared_id);
    const pending = switch (sh.*) {
        .stream => |*st| st.pending orelse return,
        .future, .subtask => return,
    };
    if (pending.side != .writable) return;
    const pw = ctx.pending_writes.get(pending.waitable) orelse return;
    const mem = try ctx.memory();
    const bytes = mem.sliceAt(pw.ptr, pw.count * pw.elem_size) catch return WasiP2Error.OutOfBounds;
    cap.appendSlice(ctx.alloc, bytes) catch return WasiP2Error.OutOfMemory;
    const writer = try ctx.streams.get(pending.waitable);
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .stream_write, .index = pending.waitable, .payload = (async_mod.ReturnCode{ .completed = @intCast(pw.count) }).encode() });
    switch (sh.*) {
        .stream => |*st| st.pending = null,
        .future, .subtask => {},
    }
    _ = ctx.pending_writes.remove(pending.waitable);
}

fn http3ReqoptsClone(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const src = (try http3ReqoptsSelf(ctx, self)).*;
    const idx: u32 = @intCast(ctx.http_reqopts.items.len);
    ctx.http_reqopts.append(ctx.alloc, .{
        .connect_timeout_ns = src.connect_timeout_ns,
        .first_byte_timeout_ns = src.first_byte_timeout_ns,
        .between_bytes_timeout_ns = src.between_bytes_timeout_ns,
    }) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_RT, idx);
}

fn sock3UdpLocalAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = sock.localAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3UdpRemoteAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = sock.remoteAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3UdpFamily(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try sock3UdpSelf(ctx, self);
    return @intFromEnum(sock.family);
}

fn sock3UdpHopGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU8(mem, retptr, (try sock3UdpSelf(ctx, self)).opt_hop_limit);
}

fn sock3UdpHopSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (value == 0 or value > 255) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3UdpSelf(ctx, self)).opt_hop_limit = @intCast(value);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpRcvbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3UdpSelf(ctx, self)).opt_rcvbuf);
}

fn sock3UdpRcvbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3UdpSelf(ctx, self)).opt_rcvbuf = @min(v, 8 << 20);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpSndbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3UdpSelf(ctx, self)).opt_sndbuf);
}

fn sock3UdpSndbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3UdpSelf(ctx, self)).opt_sndbuf = @min(v, 8 << 20);
    try writeSock3UnitResult(mem, retptr, null);
}

/// `[async-lower]ip-name-lookup.resolve-addresses` (name ptr, len, retptr):
/// IP literals parse locally per the WIT; a real resolver is a seam the
/// corpus does not exercise — non-literals resolve only for "localhost".
fn sock3ResolveAddresses(caller: *Caller, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var addrs: [32]std.Io.net.IpAddress = undefined;
    const n = p2sock.resolveAddresses(try ctxIo(ctx), name, &addrs) catch |e| {
        // ip-name-lookup has its OWN error-code variant (ordinals per its
        // WIT declaration order; `other(option<string>)` = 5, none).
        const code: u8 = switch (e) {
            error.InvalidName => 1,
            error.NameUnresolvable => 2,
            error.TemporaryResolverFailure => 3,
            error.PermanentResolverFailure => 4,
            error.ResolverFailure, error.Canceled => 5,
        };
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, code);
        try mem.write(retptr + 8, @as(u8, 0));
        return SUBTASK_RETURNED;
    };
    // ok: list<ip-address>; ip-address variant = disc u8@0, payload@2
    // (ipv4 4×u8 / ipv6 8×u16-le) → elem size 18 align 2.
    const base = try ctx.reallocGuest(@intCast(n * 18), 2);
    for (addrs[0..n], 0..) |a, i| {
        const elem_ptr = base + @as(u32, @intCast(i * 18));
        switch (a) {
            .ip4 => |v| {
                try mem.write(elem_ptr, @as(u8, 0));
                for (v.bytes, 0..) |b, j| try mem.write(elem_ptr + 2 + @as(u32, @intCast(j)), b);
            },
            .ip6 => |v| {
                try mem.write(elem_ptr, @as(u8, 1));
                for (0..8) |j| {
                    const seg: u16 = (@as(u16, v.bytes[j * 2]) << 8) | v.bytes[j * 2 + 1];
                    try mem.write(elem_ptr + 2 + @as(u32, @intCast(j * 2)), seg);
                }
            },
        }
    }
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, base);
    try mem.write(retptr + 8, @as(u32, @intCast(n)));
    return SUBTASK_RETURNED;
}

/// The classifier's P3 arms (ADR-0207): bind the sync-lowered
/// wasi:{filesystem,sockets,http}@0.3.0 plain funcs. Returns false for a
/// non-P3 op (the caller's exhaustive P2 switch handles it).
pub fn registerP3Arms(lk: *Linker, module: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !bool {
    switch (op) {
        // wasi:sockets@0.3.0 plain funcs (sync-lowered by wit-bindgen).
        .sock3_tcp_create => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpCreate),
        .sock3_tcp_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, sock3TcpBind),
        .sock3_tcp_listen => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpListen),
        .sock3_tcp_send => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, sock3TcpSend),
        .sock3_tcp_receive => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpReceive),
        .sock3_tcp_local_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpLocalAddress),
        .sock3_tcp_remote_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpRemoteAddress),
        .sock3_tcp_is_listening => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, sock3TcpIsListening),
        .sock3_tcp_family => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, sock3TcpFamily),
        .sock3_tcp_set_backlog => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, sock3TcpSetBacklog),
        .sock3_tcp_ka_enabled_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaEnabledGet),
        .sock3_tcp_ka_enabled_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3TcpKaEnabledSet),
        .sock3_tcp_ka_idle_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaIdleGet),
        .sock3_tcp_ka_idle_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpKaIdleSet),
        .sock3_tcp_ka_interval_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaIntervalGet),
        .sock3_tcp_ka_interval_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpKaIntervalSet),
        .sock3_tcp_ka_count_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaCountGet),
        .sock3_tcp_ka_count_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3TcpKaCountSet),
        .sock3_tcp_hop_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpHopGet),
        .sock3_tcp_hop_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3TcpHopSet),
        .sock3_tcp_rcvbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpRcvbufGet),
        .sock3_tcp_rcvbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpRcvbufSet),
        .sock3_tcp_sndbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpSndbufGet),
        .sock3_tcp_sndbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpSndbufSet),
        .sock3_udp_create => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpCreate),
        .sock3_udp_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, sock3UdpBind),
        .sock3_udp_connect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, sock3UdpConnect),
        .sock3_udp_disconnect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpDisconnect),
        .sock3_udp_local_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpLocalAddress),
        .sock3_udp_remote_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpRemoteAddress),
        .sock3_udp_family => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, sock3UdpFamily),
        .sock3_udp_hop_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpHopGet),
        .sock3_udp_hop_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3UdpHopSet),
        .sock3_udp_rcvbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpRcvbufGet),
        .sock3_udp_rcvbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3UdpRcvbufSet),
        .sock3_udp_sndbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpSndbufGet),
        .sock3_udp_sndbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3UdpSndbufSet),
        // The async-func sockets surface (connect / udp send / udp receive /
        // resolve-addresses) arrives ASYNC-lowered — sync lowers unreached.
        .sock3_tcp_connect, .sock3_udp_send, .sock3_udp_receive, .sock3_resolve_addresses => return error.UnsupportedWasiImport,
        // wasi:http/types@0.3.0 `fields` (sync plain funcs; ADR-0205 phase D).
        .http3_fields_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, http3FieldsNew),
        .http3_fields_from_list => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3FieldsFromList),
        .http3_fields_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsGet),
        .http3_fields_has => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!u32, http3FieldsHas),
        .http3_fields_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3FieldsSet),
        .http3_fields_delete => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsDelete),
        .http3_fields_get_and_delete => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsGetAndDelete),
        .http3_fields_append => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3FieldsAppend),
        .http3_fields_copy_all => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3FieldsCopyAll),
        .http3_fields_clone => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3FieldsClone),
        .http3_request_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3RequestNew),
        .http3_request_get_method => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetMethod),
        .http3_request_set_method => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetMethod),
        .http3_request_get_pwq => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetPwq),
        .http3_request_set_pwq => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetPwq),
        .http3_request_get_scheme => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetScheme),
        .http3_request_set_scheme => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetScheme),
        .http3_request_get_authority => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetAuthority),
        .http3_request_set_authority => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetAuthority),
        .http3_request_get_options => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetOptions),
        .http3_request_get_headers => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3RequestGetHeaders),
        .http3_response_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!void, http3ResponseNew),
        .http3_response_get_status => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3ResponseGetStatus),
        .http3_response_set_status => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, http3ResponseSetStatus),
        .http3_response_get_headers => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3ResponseGetHeaders),
        .http3_reqopts_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, http3ReqoptsNew),
        .http3_reqopts_connect_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsConnectGet),
        .http3_reqopts_connect_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsConnectSet),
        .http3_reqopts_first_byte_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsFirstByteGet),
        .http3_reqopts_first_byte_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsFirstByteSet),
        .http3_reqopts_between_bytes_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsBetweenBytesGet),
        .http3_reqopts_between_bytes_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsBetweenBytesSet),
        .http3_reqopts_clone => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3ReqoptsClone),
        .http3_request_consume_body => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3RequestConsumeBody),
        .http3_response_consume_body => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3ResponseConsumeBody),
        // client.send arrives ASYNC-lowered; a sync lower is unreached.
        .http3_client_send => return error.UnsupportedWasiImport,
        // wasi:filesystem@0.3.0 plain funcs (sync-lowered by wit-bindgen).
        .fs3_read_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, fs3ReadViaStream),
        .fs3_write_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64) WasiP2Error!u32, fs3WriteViaStream),
        .fs3_append_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, fs3AppendViaStream),
        .fs3_read_directory => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, fs3ReadDirectory),
        // The fs3 async-func surface arrives ASYNC-lowered (defineAsyncLoweredOp);
        // a sync lower of it is unreached by the conformance corpus — fail loudly.
        .fs3_stat, .fs3_stat_at, .fs3_get_type, .fs3_get_flags, .fs3_set_times, .fs3_set_times_at, .fs3_set_size, .fs3_advise, .fs3_sync, .fs3_sync_data, .fs3_open_at, .fs3_create_directory_at, .fs3_remove_directory_at, .fs3_unlink_file_at, .fs3_readlink_at, .fs3_rename_at, .fs3_symlink_at, .fs3_link_at, .fs3_is_same_object, .fs3_metadata_hash, .fs3_metadata_hash_at => return error.UnsupportedWasiImport,
        // Every non-P3 op belongs to the facade classifier; listing the
        // tags (not `else`) keeps this switch compile-time exhaustive too.
        .cli_get_stdout, .cli_get_stderr, .cli_get_stdin, .cli_stdout_write_via_stream, .cli_stderr_write_via_stream, .cli_stdin_read_via_stream, .out_stream_write, .out_stream_blocking_write_and_flush, .out_stream_blocking_flush, .out_stream_drop, .in_stream_read, .in_stream_blocking_read, .in_stream_drop, .cli_exit, .cli_exit_with_code, .clocks_wall_now, .clocks_monotonic_now, .clocks_system_now, .clocks_system_get_resolution, .clocks_monotonic_get_resolution, .clocks_wait_until, .clocks_wait_for, .random_get_bytes, .fs_descriptor_read, .fs_descriptor_write, .fs_descriptor_open_at, .fs_descriptor_sync, .fs_descriptor_stat, .fs_descriptor_get_type, .fs_descriptor_drop, .fs_get_directories, .poll_pollable_ready, .poll_pollable_block, .poll_poll, .in_stream_subscribe, .out_stream_subscribe, .clocks_subscribe_instant, .clocks_subscribe_duration, .cli_get_environment, .cli_get_arguments, .cli_initial_cwd, .cli_get_terminal_stdin, .cli_get_terminal_stdout, .cli_get_terminal_stderr, .out_stream_check_write, .random_get_u64, .random_insecure_get_bytes, .random_insecure_get_u64, .random_insecure_seed, .fs_descriptor_stat_at, .fs_descriptor_create_directory_at, .fs_descriptor_link_at, .fs_descriptor_readlink_at, .fs_descriptor_remove_directory_at, .fs_descriptor_rename_at, .fs_descriptor_symlink_at, .fs_descriptor_sync_data, .fs_descriptor_unlink_file_at, .fs_descriptor_read_directory, .fs_dir_entry_stream_read, .fs_dir_entry_stream_drop, .io_resource_drop, .fs_stub_via_stream_offset, .fs_stub_via_stream, .fs_stub_get_flags, .fs_stub_metadata_hash, .sock_instance_network, .sock_create_tcp, .sock_tcp_start_bind, .sock_tcp_finish_bind, .sock_tcp_start_connect, .sock_tcp_finish_connect, .sock_tcp_subscribe, .sock_tcp_shutdown, .sock_tcp_is_listening, .sock_tcp_drop, .sock_tcp_start_listen, .sock_tcp_finish_listen, .sock_tcp_accept, .sock_tcp_local_address, .sock_tcp_remote_address, .sock_tcp_set_backlog, .sock_stub_unit2, .sock_stub_unit3i, .sock_stub_unit3l, .sock_stub_unit15, .sock_stub_val1, .sock_stub_val4, .sock_stub_val8, .sock_stub_val15_4, .sock_stub_resolve, .sock_stub_recv, .sock_stub_send, .sock_stub_subscribe => return false,
    }
    return true;
}
