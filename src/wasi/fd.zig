// FILE-SIZE-EXEMPT: uniform WASI-0.1 fd_* syscall catalog sharing the bounds-checked memory helpers (N1/N2 on split); 41% tests P4-alone (investigated 2026-08-12, per ADR-0099)
//! WASI 0.1 fd_* handlers (Phase 4 / §9.4 / 4.4).
//!
//! Stdio-only first pass — fds 0 / 1 / 2. Arbitrary file fds
//! land alongside `path_open` in §9.4 / 4.5; this chunk wires
//! the dispatch shape and the gather/scatter ciovec / iovec
//! mechanics so 4.5 only adds the per-fd backing.
//!
//! Scope:
//! - `fd_write(fd, ciovec_ptr, ciovec_count, *nwritten)` — only
//!   fds 1 (stdout) and 2 (stderr) succeed; fd 0 returns `notsup`,
//!   fds 3+ return `badf` (no preopens openable yet).
//! - `fd_read(fd, iovec_ptr, iovec_count, *nread)` — only fd 0
//!   (stdin) succeeds; others return `notsup`.
//! - `fd_close(fd)` — stdio fds return `success` (noop, matches
//!   wasmtime); other valid fds flip the slot to `.closed`;
//!   out-of-range returns `badf`.
//! - `fd_seek(fd, offset, whence, *new_pos)` — stdio returns
//!   `spipe` (illegal seek on a pipe).
//! - `fd_tell(fd, *pos)` — same.
//!
//! Output for fd 1 / fd 2 routes through `host.stdout_buffer` /
//! `host.stderr_buffer` when those are set (test capture path);
//! when null, this layer treats the write as a no-op success
//! (production wiring lives in §9.4 / 4.7 / 4.8 — the binding's
//! import-resolution code installs the host's real stdout /
//! stderr writers at instance setup).
//!
//! Zone 2 (`src/wasi/`) — siblings: p1.zig, host.zig, proc.zig.

const std = @import("std");

const p1 = @import("preview1.zig");
const host_mod = @import("host.zig");
const dbg = @import("../support/dbg.zig");

const Host = host_mod.Host;

// ============================================================
// Memory access helpers (bounds-checked)
// ============================================================

fn readU32LE(mem: []const u8, offset: u32) ?u32 {
    if (@as(usize, offset) + 4 > mem.len) return null;
    return std.mem.readInt(u32, mem[offset..][0..4], .little);
}

fn writeU32LE(mem: []u8, offset: u32, value: u32) p1.Errno {
    if (@as(usize, offset) + 4 > mem.len) return .fault;
    std.mem.writeInt(u32, mem[offset..][0..4], value, .little);
    return .success;
}

fn writeU64LE(mem: []u8, offset: u32, value: u64) p1.Errno {
    if (@as(usize, offset) + 8 > mem.len) return .fault;
    std.mem.writeInt(u64, mem[offset..][0..8], value, .little);
    return .success;
}

// Slice into guest memory bounded by guest buf+len. Returns
// null on out-of-bounds; callers translate to `Errno.fault`.
fn sliceMem(mem: []u8, buf: u32, buf_len: u32) ?[]u8 {
    const end = @as(usize, buf) + @as(usize, buf_len);
    if (end > mem.len) return null;
    return mem[buf..end];
}

fn sliceMemConst(mem: []const u8, buf: u32, buf_len: u32) ?[]const u8 {
    const end = @as(usize, buf) + @as(usize, buf_len);
    if (end > mem.len) return null;
    return mem[buf..end];
}

// ============================================================
// fd_write
// ============================================================

/// `fd_write(fd, ciovec_ptr, ciovec_count, *nwritten_out) → errno`
/// — gather write of `ciovec_count` Ciovec entries into the host
/// fd. Each Ciovec is `{ buf: u32, buf_len: u32 }` (8 bytes,
/// little-endian) at `ciovec_ptr + i * 8`. The total bytes
/// successfully written is reported in `*nwritten_out`.
pub fn fdWrite(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    ciovec_ptr: u32,
    ciovec_count: u32,
    nwritten_ptr: u32,
) p1.Errno {
    // Validate the fd is writable up front (an empty write is a no-op for
    // every sink) so an empty gather (count 0) still reports badf / notsup /
    // isdir as before; the per-slice `writeSlice` re-validates per ciovec.
    const guard = writeSlice(host, fd, &.{});
    if (guard != .success) return guard;

    if (dbg.on("wasi.iovec")) {
        std.debug.print("[wasi.iovec] ENTER fd={d} ciovec_ptr={d} ciovec_count={d}\n", .{ fd, ciovec_ptr, ciovec_count });
    }

    var total: u32 = 0;
    var i: u32 = 0;
    while (i < ciovec_count) : (i += 1) {
        const entry_off = ciovec_ptr + i * 8;
        const buf = readU32LE(mem, entry_off) orelse return .fault;
        const buf_len = readU32LE(mem, entry_off + 4) orelse return .fault;
        // D-489 differential primitive: the iovec the host receives is engine-
        // independent ground truth — diff interp vs x86_64-jit to lock the miscompile.
        if (dbg.on("wasi.iovec")) {
            std.debug.print("[wasi.iovec] fd={d} i={d} ciovec_ptr={d} buf={d} len={d}\n", .{ fd, i, ciovec_ptr, buf, buf_len });
        }
        const slice = sliceMemConst(mem, buf, buf_len) orelse return .fault;
        const e = writeSlice(host, fd, slice);
        if (e != .success) return e;
        total += buf_len;
    }
    return writeU32LE(mem, nwritten_ptr, total);
}

/// Write one contiguous byte range to `fd`, applying the same stdout/stderr
/// capture-buffer / file-cursor / real-process-stream routing as `fdWrite`.
/// Used by `fdWrite`'s ciovec loop and by the WASI-P2 output-stream
/// trampoline, where `list<u8>` is a flat `(ptr, len)` rather than a ciovec.
pub fn writeSlice(host: *Host, fd: p1.Fd, bytes: []const u8) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    // The fd's TYPE decides whether the operation exists at all; only then does
    // the capability decide whether THIS fd may perform it. Keeping that order
    // is what preserves `isdir` / `notsup` / `spipe` as the answers a guest
    // gets from a stream or a directory — measured against wasmtime 47, which
    // reports the type error for every one of these.
    switch (slot.kind) {
        .stdout, .stderr, .file => {},
        .stdin => return .notsup,
        .dir => return .isdir,
        .closed => return .badf,
    }
    if (!slot.has(p1.RIGHTS_FD_WRITE)) return .notcapable;

    // stdout/stderr route to a capture buffer (or are dropped); a file fd
    // writes to the host file at its cursor via std.Io.File (D-243 cycle 2).
    var file_opt: ?std.Io.File = null;
    const buffer: ?*std.ArrayList(u8) = switch (slot.kind) {
        .stdout => host.stdout_buffer,
        .stderr => host.stderr_buffer,
        .file => fblk: {
            file_opt = .{ .handle = slot.host_handle orelse return .badf, .flags = .{ .nonblocking = false } };
            break :fblk null;
        },
        .stdin, .dir, .closed => unreachable, // rejected above
    };
    const io_opt = host.io;
    if (file_opt != null and io_opt == null) return .nosys;

    // stdout/stderr with NO capture buffer but a live io context (the CLI
    // `run` path) route to the real process stream — otherwise `zwasm run`
    // silently drops guest output. Without a buffer AND without io (headless),
    // the write is a no-op success.
    //
    // `!builtin.is_test`: a unit-test build must NEVER touch the real process
    // fd 1/2 — Zig's `--listen=-` test runner speaks its result protocol over
    // the test process's stdout, so a guest stdout write there corrupts that
    // stream and the runner panics on EndOfStream when the build closes the pipe
    // ("failed command: …/test … --listen=-" AFTER every test has already
    // passed). Same reason `platform/signal.zig` guards its fd-2 write with
    // `!builtin.is_test`. Tests that assert on guest output use a capture buffer
    // (the `buffer` path below); the no-capture case is safe to drop in tests.
    const std_stream: ?std.Io.File = if (!@import("builtin").is_test and buffer == null and file_opt == null and io_opt != null)
        switch (slot.kind) {
            .stdout => std.Io.File.stdout(),
            .stderr => std.Io.File.stderr(),
            .stdin, .dir, .file, .closed => null,
        }
    else
        null;

    if (buffer) |b| {
        // A capped capture reports `.nospc` rather than silently accepting the
        // write: the guest asked to write N bytes and fewer were kept, and
        // "no space left on device" is the errno a real fd would give. Report
        // it AFTER keeping what fits, so the caller sees a prefix rather than
        // losing the tail of the last useful line.
        var to_write = bytes;
        var capped = false;
        if (host.max_capture_bytes) |cap| {
            if (b.items.len >= cap) {
                host.capture_truncated = true;
                return .nospc;
            }
            const room = cap - b.items.len;
            if (bytes.len > room) {
                to_write = bytes[0..@intCast(room)];
                capped = true;
            }
        }
        b.appendSlice(host.capture_alloc orelse host.alloc, to_write) catch return .nomem;
        if (capped) {
            host.capture_truncated = true;
            return .nospc;
        }
    }
    if (file_opt) |f| {
        // Positional write at the slot's logical cursor + advance (mirrors
        // fdReadFile; std.Io.File is positional-only).
        f.writePositionalAll(io_opt.?, bytes, slot.pos) catch return .io;
        slot.pos += bytes.len;
    }
    if (std_stream) |s| s.writeStreamingAll(io_opt.?, bytes) catch return .io;
    return .success;
}

// ============================================================
// fd_read
// ============================================================

/// `fd_read(fd, iovec_ptr, iovec_count, *nread_out) → errno` —
/// scatter read into `iovec_count` Iovec entries from the host
/// fd. Stdio-only first pass: fd 0 reads from
/// `host.stdin_bytes`; advances `host.stdin_pos`. EOF (no more
/// bytes) returns success with `*nread_out = 0`.
pub fn fdRead(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    iovec_ptr: u32,
    iovec_count: u32,
    nread_ptr: u32,
) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .file => {},
        .stdout, .stderr => return .notsup,
        .dir => return .isdir,
        .closed => return .badf,
    }
    if (!slot.has(p1.RIGHTS_FD_READ)) return .notcapable;
    if (slot.kind == .file) return fdReadFile(host, mem, slot, iovec_ptr, iovec_count, nread_ptr);

    var total: u32 = 0;
    var i: u32 = 0;
    while (i < iovec_count) : (i += 1) {
        const entry_off = iovec_ptr + i * 8;
        const buf = readU32LE(mem, entry_off) orelse return .fault;
        const buf_len = readU32LE(mem, entry_off + 4) orelse return .fault;
        const dst = sliceMem(mem, buf, buf_len) orelse return .fault;

        const n = readStdinSlice(host, dst);
        if (n == 0) break; // EOF or no stdin source
        total += @intCast(n);
        if (n < dst.len) break; // short read; spec lets us stop
    }
    return writeU32LE(mem, nread_ptr, total);
}

/// Read up to `dest.len` bytes from `host.stdin_bytes` into `dest`, advancing
/// `stdin_pos`. Returns the count read (0 = EOF / no source). Factored from
/// `fdRead` so the WASI-P2 `input-stream.read` trampoline reuses the same source
/// (it reads into a cabi_realloc'd guest buffer rather than iovecs).
pub fn readStdinSlice(host: *Host, dest: []u8) usize {
    const src = host.stdin_bytes orelse return 0;
    const remaining = src.len - host.stdin_pos;
    const n = @min(remaining, dest.len);
    @memcpy(dest[0..n], src[host.stdin_pos .. host.stdin_pos + n]);
    host.stdin_pos += n;
    return n;
}

/// Scatter-read a file fd into the iovecs at the file's cursor via
/// std.Io.File (D-243 cycle 2). A short read (n < iovec len) is EOF and
/// stops the scatter, per the WASI fd_read contract.
fn fdReadFile(host: *Host, mem: []u8, slot: *host_mod.OpenFd, iovec_ptr: u32, iovec_count: u32, nread_ptr: u32) p1.Errno {
    const handle = slot.host_handle orelse return .badf;
    const io = host.io orelse return .nosys;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < iovec_count) : (i += 1) {
        const entry_off = iovec_ptr + i * 8;
        const buf = readU32LE(mem, entry_off) orelse return .fault;
        const buf_len = readU32LE(mem, entry_off + 4) orelse return .fault;
        const dst = sliceMem(mem, buf, buf_len) orelse return .fault;
        if (dst.len == 0) continue;
        // Positional read at the slot's logical cursor (std.Io.File is
        // positional-only — no OS-cursor seek). EOF returns 0 (NOT
        // error.EndOfStream, cf. fd_pread); WASI reports it as nread=0, success.
        const n: usize = file.readPositional(io, &[_][]u8{dst}, slot.pos) catch return .io;
        if (n == 0) break; // EOF
        total += @intCast(n);
        slot.pos += n;
        if (n < dst.len) break; // short read

    }
    return writeU32LE(mem, nread_ptr, total);
}

// ============================================================
// fd_close / fd_seek / fd_tell
// ============================================================

/// `fd_close(fd) → errno`. Stdio fds return `success` (noop,
/// matches wasmtime). Other valid fds flip the slot to
/// `.closed`. Out-of-range fd: `badf`.
pub fn fdClose(host: *Host, fd: p1.Fd) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .success,
        .closed => return .badf,
        .file, .dir => {
            slot.kind = .closed;
            return .success;
        },
    }
}

/// `fd_renumber(from, to) → errno` — renumber fd `from` onto `to`: `to` now
/// refers to `from`'s open file and `from` is closed. Mirrors `fd_close`'s
/// slot-only model (the host fd is not eagerly closed — process-lifetime, as
/// in `fdClose`); `to`'s prior slot is overwritten. Both must be in range.
pub fn fdRenumber(host: *Host, from: p1.Fd, to: p1.Fd) p1.Errno {
    const slot_from = host.translateFd(from) orelse return .badf;
    if (slot_from.kind == .closed) return .badf;
    const slot_to = host.translateFd(to) orelse return .badf;
    if (from == to) return .success;
    slot_to.* = slot_from.*;
    slot_from.kind = .closed;
    slot_from.host_handle = null;
    return .success;
}

/// `fd_seek(fd, offset, whence, *new_pos_out) → errno`. Moves the `.file`
/// slot's logical cursor (`slot.pos`) per `whence` (set/cur/end) and writes the
/// resulting absolute offset. Stdio/pipes are not seekable → `spipe`; a negative
/// resulting offset or an unknown `whence` → `inval`. `end` reads the host file
/// size via `File.stat`. (std.Io.File is positional-only; the cursor lives in
/// the slot, see `OpenFd.pos`.)
pub fn fdSeek(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    offset: i64,
    whence: u8,
    new_pos_ptr: u32,
) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .spipe,
        // A directory has no byte offset to move. POSIX would say EISDIR, and
        // that is one of the three answers the official `directory_seek`
        // accepts (`notsup`, which this used to give, is not).
        .dir => return .isdir,
        .closed => return .badf,
        .file => {},
    }
    // witx: FD_TELL covers the offset-preserving form (`cur` + 0); anything
    // that can move the cursor needs FD_SEEK. FD_SEEK "implies FD_TELL", so it
    // satisfies the offset-preserving form on its own.
    const preserves_offset = whence == @intFromEnum(p1.Whence.cur) and offset == 0;
    const may_seek = slot.has(p1.RIGHTS_FD_SEEK) or
        (preserves_offset and slot.has(p1.RIGHTS_FD_TELL));
    if (!may_seek) return .notcapable;
    const handle = slot.host_handle orelse return .badf;
    const io = host.io orelse return .nosys;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    const base: i128 = switch (@as(p1.Whence, @enumFromInt(whence))) {
        .set => 0,
        .cur => @intCast(slot.pos),
        .end => blk: {
            const st = file.stat(io) catch return .io;
            break :blk @intCast(st.size);
        },
        _ => return .inval,
    };
    const new_pos: i128 = base + offset;
    if (new_pos < 0) return .inval;
    slot.pos = @intCast(new_pos);
    return writeU64LE(mem, new_pos_ptr, @intCast(new_pos));
}

/// `fd_tell(fd, *pos_out) → errno`. Writes the `.file` slot's current logical
/// cursor (`slot.pos`). Stdio/pipes have no position → `spipe`.
pub fn fdTell(host: *Host, mem: []u8, fd: p1.Fd, pos_ptr: u32) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .spipe,
        .dir => return .isdir,
        .closed => return .badf,
        .file => {},
    }
    // FD_SEEK "implies rights::fd_tell" (witx), so either bit answers for it.
    if (!slot.has(p1.RIGHTS_FD_TELL) and !slot.has(p1.RIGHTS_FD_SEEK)) return .notcapable;
    return writeU64LE(mem, pos_ptr, slot.pos);
}

// ============================================================
// fd_sync / fd_datasync / fd_advise  (D-278)
// ============================================================

/// `fd_sync(fd) → errno` — flush a file fd's data + metadata to disk
/// via `std.Io.File.sync`. Stdio fds have nothing host-buffered at
/// this layer → `success` noop; closed → `badf`.
pub fn fdSync(host: *Host, fd: p1.Fd) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .success,
        .closed => return .badf,
        .file, .dir => {
            if (!slot.has(p1.RIGHTS_FD_SYNC)) return .notcapable;
            const io = host.io orelse return .nosys;
            const handle = slot.host_handle orelse return .badf;
            const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
            file.sync(io) catch return .io;
            return .success;
        },
    }
}

/// `fd_datasync(fd) → errno` — flush a file fd's data. Routed through the
/// same cross-platform `std.Io.File.sync` as `fd_sync`: datasync's contract
/// only *permits* skipping a metadata flush (an optimisation), so a full
/// sync satisfies it. `std.posix.fdatasync` is NOT usable here — on Windows
/// `fd_t` is a HANDLE (`*anyopaque`), which that POSIX signature rejects.
pub fn fdDatasync(host: *Host, fd: p1.Fd) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .success,
        .closed => return .badf,
        .file, .dir => {
            if (!slot.has(p1.RIGHTS_FD_DATASYNC)) return .notcapable;
            const io = host.io orelse return .nosys;
            const handle = slot.host_handle orelse return .badf;
            const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
            file.sync(io) catch return .io;
            return .success;
        },
    }
}

/// `fd_advise(fd, offset, len, advice) → errno` — declare an access
/// pattern. The advice is purely a hint (the WASI/POSIX contract lets
/// a host ignore it), so we validate the fd + advice tag and return
/// `success` without forcing a non-portable `posix_fadvise` (absent on
/// macOS). Invalid advice (> 5) → `inval`; non-file fd → `spipe`.
pub fn fdAdvise(host: *Host, fd: p1.Fd, offset: u64, len: u64, advice: u8) p1.Errno {
    _ = offset;
    _ = len;
    if (advice > 5) return .inval; // normal/sequential/random/willneed/dontneed/noreuse
    const slot = host.translateFd(fd) orelse return .badf;
    return switch (slot.kind) {
        .stdin, .stdout, .stderr => .spipe,
        // Advisory information applies to file data; a directory has none
        // (official filesystem-advise.wasm asserts bad-descriptor).
        .closed, .dir => .badf,
        .file => if (slot.has(p1.RIGHTS_FD_ADVISE)) .success else .notcapable,
    };
}

// ============================================================
// fd_pread / fd_pwrite  (D-278)
// ============================================================

/// `fd_pread(fd, iovec_ptr, iovec_count, offset, *nread_out) → errno` —
/// positional scatter read at an explicit `offset` that does NOT move the
/// fd cursor (`std.Io.File.readPositional`). EOF returns success with the
/// short/zero total. File-only: stdio → `spipe`, dir → `isdir`.
pub fn fdPread(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    iovec_ptr: u32,
    iovec_count: u32,
    offset: u64,
    nread_ptr: u32,
) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .file => {},
        .stdin, .stdout, .stderr => return .spipe,
        .dir => return .isdir,
        .closed => return .badf,
    }
    // witx: FD_READ "includes the right to invoke fd_pread" only when FD_SEEK
    // is also held — positional IO is a seek plus a read.
    if (!slot.has(p1.RIGHTS_FD_READ | p1.RIGHTS_FD_SEEK)) return .notcapable;
    const handle = slot.host_handle orelse return .badf;
    const io = host.io orelse return .nosys;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    var total: u32 = 0;
    var cur_off = offset;
    var i: u32 = 0;
    while (i < iovec_count) : (i += 1) {
        const entry_off = iovec_ptr + i * 8;
        const buf = readU32LE(mem, entry_off) orelse return .fault;
        const buf_len = readU32LE(mem, entry_off + 4) orelse return .fault;
        const dst = sliceMem(mem, buf, buf_len) orelse return .fault;
        if (dst.len == 0) continue;
        const n = file.readPositional(io, &[_][]u8{dst}, cur_off) catch return .io;
        if (n == 0) break; // EOF
        total += @intCast(n);
        cur_off += n;
        if (n < dst.len) break; // short read
    }
    return writeU32LE(mem, nread_ptr, total);
}

/// `fd_pwrite(fd, ciovec_ptr, ciovec_count, offset, *nwritten_out) → errno`
/// — positional gather write at `offset` without moving the fd cursor
/// (`std.Io.File.writePositional`). File-only, same kind handling as
/// `fd_pread`.
pub fn fdPwrite(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    ciovec_ptr: u32,
    ciovec_count: u32,
    offset: u64,
    nwritten_ptr: u32,
) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .file => {},
        .stdin, .stdout, .stderr => return .spipe,
        .dir => return .isdir,
        .closed => return .badf,
    }
    if (!slot.has(p1.RIGHTS_FD_WRITE | p1.RIGHTS_FD_SEEK)) return .notcapable;
    const handle = slot.host_handle orelse return .badf;
    const io = host.io orelse return .nosys;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    var total: u32 = 0;
    var cur_off = offset;
    var i: u32 = 0;
    while (i < ciovec_count) : (i += 1) {
        const entry_off = ciovec_ptr + i * 8;
        const buf = readU32LE(mem, entry_off) orelse return .fault;
        const buf_len = readU32LE(mem, entry_off + 4) orelse return .fault;
        const src = sliceMemConst(mem, buf, buf_len) orelse return .fault;
        if (src.len == 0) continue;
        const n = file.writePositional(io, &[_][]const u8{src}, cur_off) catch return .io;
        total += @intCast(n);
        cur_off += n;
        if (n < src.len) break; // short write
    }
    return writeU32LE(mem, nwritten_ptr, total);
}

/// Positionally write one contiguous byte range to a file `fd` at `offset`
/// (no cursor move). The slice-level analogue of `fdPwrite`'s ciovec loop —
/// used by the WASI-P2 `descriptor.write` trampoline, where `list<u8>` is a
/// flat `(ptr, len)`. File fds only (stdio → `spipe`, dir → `isdir`).
pub fn pwriteSlice(host: *Host, fd: p1.Fd, bytes: []const u8, offset: u64) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .file => {},
        .stdin, .stdout, .stderr => return .spipe,
        .dir => return .isdir,
        .closed => return .badf,
    }
    const handle = slot.host_handle orelse return .badf;
    const io = host.io orelse return .nosys;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    if (bytes.len == 0) return .success;
    _ = file.writePositional(io, &[_][]const u8{bytes}, offset) catch return .io;
    return .success;
}

/// Positional read into one contiguous byte range (mirror of `pwriteSlice`;
/// the WASI-0.3 file via-stream source reads through this). `n_out` receives
/// the byte count (0 = EOF).
pub fn preadSlice(host: *Host, fd: p1.Fd, dest: []u8, offset: u64, n_out: *usize) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .file => {},
        .stdin, .stdout, .stderr => return .spipe,
        .dir => return .isdir,
        .closed => return .badf,
    }
    const handle = slot.host_handle orelse return .badf;
    const io = host.io orelse return .nosys;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    if (dest.len == 0) {
        n_out.* = 0;
        return .success;
    }
    var bufs = [_][]u8{dest};
    n_out.* = file.readPositional(io, &bufs, offset) catch return .io;
    return .success;
}

// ============================================================
// fd_fdstat_get / fd_fdstat_set_flags  (§9.4 / 4.5 chunk a)
// ============================================================

fn filetypeFor(kind: host_mod.FdKind) p1.Filetype {
    return switch (kind) {
        .stdin, .stdout, .stderr => .character_device,
        .file => .regular_file,
        .dir => .directory,
        .closed => .unknown,
    };
}

/// `fd_fdstat_get(fd, *fdstat_out) → errno` — write the
/// 24-byte `Fdstat` block. Layout per witx:
///   offset 0  : u8  filetype
///   offset 1  : u8  reserved (zero)
///   offset 2  : u16 fs_flags  (little-endian)
///   offset 4  : u32 reserved (zero)
///   offset 8  : u64 fs_rights_base  (little-endian)
///   offset 16 : u64 fs_rights_inheriting (little-endian)
pub fn fdFdstatGet(
    host: *const Host,
    mem: []u8,
    fd: p1.Fd,
    fdstat_ptr: u32,
) p1.Errno {
    if (@as(usize, fdstat_ptr) + 24 > mem.len) return .fault;
    if (fd >= host.fd_table.items.len) return .badf;
    const slot = &host.fd_table.items[fd];
    if (slot.kind == .closed) return .badf;

    const dst = mem[fdstat_ptr..][0..24];
    @memset(dst, 0);
    dst[0] = @intFromEnum(filetypeFor(slot.kind));
    std.mem.writeInt(u16, dst[2..4], slot.fs_flags, .little);
    std.mem.writeInt(u64, dst[8..16], slot.rights_base, .little);
    std.mem.writeInt(u64, dst[16..24], slot.rights_inheriting, .little);
    return .success;
}

/// `fd_fdstat_set_flags(fd, flags) → errno` — replace the
/// writable-subset flags on the slot. Only the flag bits the
/// witx schema allows on update are persisted (APPEND / DSYNC
/// / NONBLOCK / RSYNC / SYNC); other bits are silently
/// ignored, matching wasmtime.
pub fn fdFdstatSetFlags(host: *Host, fd: p1.Fd, flags: p1.Fdflags) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind == .closed) return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => {},
        .file, .dir, .closed => if (!slot.has(p1.RIGHTS_FD_FDSTAT_SET_FLAGS)) return .notcapable,
    }
    const allowed: p1.Fdflags = p1.FDFLAGS_APPEND | p1.FDFLAGS_DSYNC |
        p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_RSYNC | p1.FDFLAGS_SYNC;
    slot.fs_flags = flags & allowed;
    return .success;
}

/// `fd_fdstat_set_rights(fd, fs_rights_base, fs_rights_inheriting) → errno` —
/// restrict (never widen) the capability set on an fd. WASI rights are
/// monotonically droppable: a request for any bit the slot does not already
/// hold is `notcapable`; otherwise the narrowed sets are stored.
pub fn fdFdstatSetRights(host: *Host, fd: p1.Fd, rights_base: p1.Rights, rights_inheriting: p1.Rights) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind == .closed) return .badf;
    if (rights_base & ~slot.rights_base != 0) return .notcapable;
    if (rights_inheriting & ~slot.rights_inheriting != 0) return .notcapable;
    slot.rights_base = rights_base;
    slot.rights_inheriting = rights_inheriting;
    return .success;
}

// ============================================================
// path_open  (§9.4 / 4.5 chunk b)
// ============================================================

fn pathHasParentEscape(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return true;
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

/// The rights a `path_open`ed fd receives. Two clamps, both from the witx
/// `path_open` contract: a derived fd can never exceed the parent directory's
/// `fs_rights_inheriting` ("rights that apply to file descriptors derived
/// from it"), and the host may return fewer rights than requested when they
/// "do not apply to the type of file being opened" — which is how a directory
/// fd loses `fd_seek` even when the guest asked for it.
const DerivedRights = struct { base: p1.Rights, inheriting: p1.Rights };

fn deriveRights(
    parent: *const host_mod.OpenFd,
    req_base: p1.Rights,
    req_inheriting: p1.Rights,
    is_dir: bool,
) DerivedRights {
    const ceiling = parent.rights_inheriting;
    var base = req_base & ceiling;
    if (is_dir) base &= p1.RIGHTS_DIRECTORY_APPLICABLE;
    return .{ .base = base, .inheriting = req_inheriting & ceiling };
}

fn mapOpenError(err: anyerror) p1.Errno {
    return switch (err) {
        error.FileNotFound => .noent,
        // NT invalid object names ("" / reserved chars) have no WASI errno of
        // their own; POSIX would have said ENOENT.
        error.BadPathName => .noent,
        error.AccessDenied, error.PermissionDenied => .acces,
        error.IsDir => .isdir,
        error.NotDir => .notdir,
        error.SymLinkLoop => .loop,
        error.NameTooLong => .nametoolong,
        error.PathAlreadyExists => .exist,
        error.NoSpaceLeft => .nospc,
        error.SystemResources, error.SystemFdQuotaExceeded, error.ProcessFdQuotaExceeded => .nfile,
        else => .io,
    };
}

/// Build a `std.Io.File.SetTimestamp` from a WASI fstflags pair
/// (`*_NOW` → now, `*` set → the explicit `ns` value, neither → unchanged).
fn setTimestampOf(flags: p1.Fstflags, now_bit: p1.Fstflags, set_bit: p1.Fstflags, ns: u64) std.Io.File.SetTimestamp {
    if (flags & now_bit != 0) return .now;
    if (flags & set_bit != 0) return .{ .new = std.Io.Timestamp.fromNanoseconds(@intCast(ns)) };
    return .unchanged;
}

/// `fd_filestat_set_times(fd, atim, mtim, fst_flags) → errno` — set the
/// access/modify timestamps of a file fd via `std.Io.File.setTimestamps`.
/// Setting both the explicit-value and the `*_NOW` bit for one timestamp is
/// `inval`. File/dir only (stdio → `spipe`, closed → `badf`).
pub fn fdFilestatSetTimes(host: *Host, fd: p1.Fd, atim: u64, mtim: u64, fst_flags: p1.Fstflags) p1.Errno {
    if (fst_flags & p1.FSTFLAGS_ATIM != 0 and fst_flags & p1.FSTFLAGS_ATIM_NOW != 0) return .inval;
    if (fst_flags & p1.FSTFLAGS_MTIM != 0 and fst_flags & p1.FSTFLAGS_MTIM_NOW != 0) return .inval;
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .spipe,
        .closed => return .badf,
        .file, .dir => {},
    }
    if (!slot.has(p1.RIGHTS_FD_FILESTAT_SET_TIMES)) return .notcapable;
    const io = host.io orelse return .nosys;
    const handle = slot.host_handle orelse return .badf;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    file.setTimestamps(io, .{
        .access_timestamp = setTimestampOf(fst_flags, p1.FSTFLAGS_ATIM_NOW, p1.FSTFLAGS_ATIM, atim),
        .modify_timestamp = setTimestampOf(fst_flags, p1.FSTFLAGS_MTIM_NOW, p1.FSTFLAGS_MTIM, mtim),
    }) catch return .io;
    return .success;
}

fn mapSetLengthError(err: anyerror) p1.Errno {
    return switch (err) {
        error.FileTooBig => .fbig,
        error.AccessDenied, error.PermissionDenied => .acces,
        error.NonResizable => .inval,
        else => .io,
    };
}

/// `fd_filestat_set_size(fd, size) → errno` — truncate or zero-extend a file
/// fd to exactly `size` bytes via `std.Io.File.setLength`. File only
/// (dir → `isdir`, stdio → `spipe`, closed → `badf`).
pub fn fdFilestatSetSize(host: *Host, fd: p1.Fd, size: u64) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .spipe,
        .dir => return .isdir,
        .closed => return .badf,
        .file => {},
    }
    if (!slot.has(p1.RIGHTS_FD_FILESTAT_SET_SIZE)) return .notcapable;
    const io = host.io orelse return .nosys;
    const handle = slot.host_handle orelse return .badf;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    file.setLength(io, size) catch |err| return mapSetLengthError(err);
    return .success;
}

/// `fd_allocate(fd, offset, len) → errno` — ensure the file holds at least
/// `offset + len` bytes (the WASI/POSIX `posix_fallocate` contract: grow +
/// zero-fill, never shrink, never truncate existing data). Implemented as a
/// guarded grow: stat the current size and `setLength` up only when short.
pub fn fdAllocate(host: *Host, fd: p1.Fd, offset: u64, len: u64) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .spipe,
        .dir => return .isdir,
        .closed => return .badf,
        .file => {},
    }
    if (!slot.has(p1.RIGHTS_FD_ALLOCATE)) return .notcapable;
    const io = host.io orelse return .nosys;
    const handle = slot.host_handle orelse return .badf;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    const need = std.math.add(u64, offset, len) catch return .fbig;
    const st = file.stat(io) catch |err| return mapOpenError(err);
    if (st.size < need) file.setLength(io, need) catch |err| return mapSetLengthError(err);
    return .success;
}

// ============================================================
// sock_* (D-278) — WASI socket surface
// ============================================================
//
// This runtime's fd table holds NO socket fds: preview1 has no socket-creation
// syscalls (connect/bind/listen are wasi-sockets extensions, not preview1), so
// a socket can only reach the guest via a host preopen-socket mechanism
// (wasmtime's `--listen`), which zwasm does not expose (tracked D-281). So
// every sock_* validates the fd and returns `notsock` for a non-socket fd
// (`badf` for an invalid/closed one) — the spec-correct errno for these fds,
// NOT a stub. A future `.socket` FdKind + host socket-preopen would extend
// these to real I/O.

fn sockFdCheck(host: *Host, fd: p1.Fd) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind == .closed) return .badf;
    return .notsock;
}

/// `sock_accept(fd, fdflags, *new_fd) → errno`.
pub fn sockAccept(host: *Host, fd: p1.Fd) p1.Errno {
    return sockFdCheck(host, fd);
}
/// `sock_recv(fd, ri_data, ri_data_len, ri_flags, *ro_datalen, *ro_flags) → errno`.
pub fn sockRecv(host: *Host, fd: p1.Fd) p1.Errno {
    return sockFdCheck(host, fd);
}
/// `sock_send(fd, si_data, si_data_len, si_flags, *so_datalen) → errno`.
pub fn sockSend(host: *Host, fd: p1.Fd) p1.Errno {
    return sockFdCheck(host, fd);
}
/// `sock_shutdown(fd, how) → errno`.
pub fn sockShutdown(host: *Host, fd: p1.Fd) p1.Errno {
    return sockFdCheck(host, fd);
}

// ============================================================
// fd_readdir  (D-278)
// ============================================================

/// Write one WASI `dirent` (24-byte header + name, no NUL) into `buf` at
/// `*written`, truncating if the buffer runs out. Returns false when the entry
/// could not be written in full — the WASI signal that the caller must retry
/// with a larger buffer (bufused == buf_len).
fn writeDirent(buf: []u8, written: *usize, d_next: u64, d_ino: u64, d_type: p1.Filetype, name: []const u8) bool {
    var hdr: [24]u8 = @splat(0);
    std.mem.writeInt(u64, hdr[0..8], d_next, .little);
    std.mem.writeInt(u64, hdr[8..16], d_ino, .little);
    std.mem.writeInt(u32, hdr[16..20], @intCast(name.len), .little);
    hdr[20] = @intFromEnum(d_type);

    const hdr_n = @min(hdr.len, buf.len - written.*);
    @memcpy(buf[written.* .. written.* + hdr_n], hdr[0..hdr_n]);
    written.* += hdr_n;
    if (hdr_n < hdr.len) return false; // truncated mid-header → buffer full

    const name_n = @min(name.len, buf.len - written.*);
    @memcpy(buf[written.* .. written.* + name_n], name[0..name_n]);
    written.* += name_n;
    return name_n == name.len;
}

/// `fd_readdir(fd, buf, buf_len, cookie, *bufused_out) → errno` — enumerate a
/// directory fd's entries into `buf`. `cookie` is an ordinal resume token (0 =
/// start); each entry's `d_next` is the cookie to resume AFTER it. The host
/// `std.Io.Dir` iterator has no seekdir, so cookie is treated as an index and
/// the iteration restarts each call (skip `cookie` entries). Synthesises `.`
/// and `..` first (ino 0, directory) as WASI/POSIX consumers expect.
pub fn fdReaddir(host: *Host, mem: []u8, fd: p1.Fd, buf_ptr: u32, buf_len: u32, cookie: u64, bufused_ptr: u32) p1.Errno {
    if (@as(usize, bufused_ptr) + 4 > mem.len) return .fault;
    const buf = sliceMem(mem, buf_ptr, buf_len) orelse return .fault;
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .dir => {},
        .closed => return .badf,
        .stdin, .stdout, .stderr, .file => return .notdir,
    }
    if (!slot.has(p1.RIGHTS_FD_READDIR)) return .notcapable;
    const io = host.io orelse return .nosys;
    const handle = slot.host_handle orelse return .badf;
    const dir: std.Io.Dir = .{ .handle = handle };

    var written: usize = 0;
    var idx: u64 = 0;

    // Synthetic "." then "..".
    inline for ([_][]const u8{ ".", ".." }) |dot| {
        if (idx >= cookie and !writeDirent(buf, &written, idx + 1, 0, .directory, dot)) {
            std.mem.writeInt(u32, mem[bufused_ptr..][0..4], @intCast(written), .little);
            return .success;
        }
        idx += 1;
    }

    var it = dir.iterate();
    while (it.next(io) catch return .io) |entry| {
        if (idx >= cookie) {
            if (!writeDirent(buf, &written, idx + 1, @intCast(entry.inode), kindToFiletype(entry.kind), entry.name)) break;
        }
        idx += 1;
    }
    std.mem.writeInt(u32, mem[bufused_ptr..][0..4], @intCast(written), .little);
    return .success;
}

/// `path_open(dirfd, dirflags, path, oflags, rights_base,
/// rights_inheriting, fdflags, *opened_fd_out) → errno` —
/// opens a path RELATIVE to a preopen `dirfd`. Strict scope:
///
/// - `dirfd` must resolve to an `OpenFd` of kind `.dir`
///   (preopens are the only roots) → `notdir` otherwise.
/// - The path string spans `mem[path_ptr .. path_ptr +
///   path_len]`. Out-of-bounds → `fault`.
/// - Path must be relative and contain no `..` segments —
///   absolute paths or any traversal escape returns
///   `notcapable`. The kernel-side `openat` would also block
///   most escapes, but the explicit pre-check is part of the
///   WASI security contract.
/// - Open is delegated to `std.Io.Dir{.fd = slot.host_handle}
///   .openFile(io, ...)`. Errors map through `mapOpenError`.
///
/// On success, a new `.file` (or `.dir`) slot is appended to
/// `host.fd_table`; the new guest fd is written to
/// `opened_fd_ptr`. `oflags` CREAT / TRUNC / EXCL / DIRECTORY are
/// honoured (see the body). `dirflags` (the symlink-follow bit) is
/// currently IGNORED — follow-time symlink confinement is the
/// blocked half of D-315.
pub fn pathOpen(
    host: *Host,
    mem: []u8,
    dirfd: p1.Fd,
    dirflags: u32,
    path_ptr: u32,
    path_len: u32,
    oflags: p1.Oflags,
    fs_rights_base: p1.Rights,
    fs_rights_inheriting: p1.Rights,
    fdflags: p1.Fdflags,
    opened_fd_ptr: u32,
) p1.Errno {
    _ = dirflags;

    // Bounds-check the path slice.
    const path_end = @as(usize, path_ptr) + @as(usize, path_len);
    if (path_end > mem.len) return .fault;
    const path = mem[path_ptr..path_end];
    // POSIX: the empty path is ENOENT. Must be pre-OS: NT resolves "" against
    // a RootDirectory handle as the directory itself.
    if (path.len == 0) return .noent;
    if (pathHasParentEscape(path)) return .notcapable;

    // Resolve dirfd.
    const dir_slot = host.translateFd(dirfd) orelse return .badf;
    if (dir_slot.kind != .dir) return .notdir;
    // witx: PATH_OPEN gates the call; PATH_CREATE_FILE and
    // PATH_FILESTAT_SET_SIZE gate the `creat` and `trunc` open-flags.
    var needed: p1.Rights = p1.RIGHTS_PATH_OPEN;
    if ((oflags & p1.OFLAGS_CREAT) != 0) needed |= p1.RIGHTS_PATH_CREATE_FILE;
    if ((oflags & p1.OFLAGS_TRUNC) != 0) needed |= p1.RIGHTS_PATH_FILESTAT_SET_SIZE;
    if (!dir_slot.has(needed)) return .notcapable;
    const dir_handle = dir_slot.host_handle orelse return .notdir;

    // Filesystem syscalls require an io context; tests / production
    // callers must thread one onto the Host before calling.
    const io = host.io orelse return .nosys;

    const dir: std.Io.Dir = .{ .handle = dir_handle };

    // OFLAGS_DIRECTORY — open a sub-DIRECTORY (`fd_readdir` / further
    // `path_*` calls resolve against it). The new slot mirrors a preopen's
    // `.dir` shape so the descendant fd composes with every dir-taking op.
    if ((oflags & p1.OFLAGS_DIRECTORY) != 0)
        return openDirSlot(host, io, dir, dir_slot, path, fs_rights_base, fs_rights_inheriting, fdflags, mem, opened_fd_ptr, .reject_write);

    // WASI `oflags` select create/trunc/excl; `fs_rights_base` selects the
    // access mode. O_CREAT → createFile (a `std::fs::File::create` guest);
    // else openFile read-only / read-write per RIGHTS_FD_WRITE.
    const wants_write = (fs_rights_base & p1.RIGHTS_FD_WRITE) != 0;
    // O_TRUNC resizes the file, so the handle must be writable even when the
    // guest asked for no FD_WRITE right (official `truncation_rights`).
    //
    // Consequence, deliberate: a truncate-open of a file the process cannot
    // write is now `acces` from the open itself, where it used to be `inval`
    // from `setLength` on a read-only handle one step later. The old answer
    // was an artifact of doing the truncate in two parts, and it is why
    // `truncation_rights` was red; wasmtime 47.0.3 answers `acces` too
    // (measured on a 0444 file).
    const needs_writable_handle = wants_write or (oflags & p1.OFLAGS_TRUNC) != 0;
    const file = if ((oflags & p1.OFLAGS_CREAT) != 0)
        dir.createFile(io, path, .{
            .read = true,
            .truncate = (oflags & p1.OFLAGS_TRUNC) != 0,
            .exclusive = (oflags & p1.OFLAGS_EXCL) != 0,
        }) catch |err| return mapOpenError(err)
    else blk: {
        const f = dir.openFile(io, path, .{ .mode = if (needs_writable_handle) .read_write else .read_only }) catch |err| {
            // POSIX-style guests (Go's os.Open before ReadDir) open a
            // directory read-only WITHOUT OFLAGS_DIRECTORY; mirror the
            // kernel by falling back to a directory open. wasmtime answers
            // `isdir` here instead, but only the OFLAGS_DIRECTORY form is
            // pinned by the official corpus, and this fallback is load-bearing
            // for real guests.
            if (err == error.IsDir)
                return openDirSlot(host, io, dir, dir_slot, path, fs_rights_base, fs_rights_inheriting, fdflags, mem, opened_fd_ptr, .allow_write);
            return mapOpenError(err);
        };
        // O_TRUNC without O_CREAT (a bare truncate-open; the 0.3 `truncate`
        // open-flag arrives standalone).
        if ((oflags & p1.OFLAGS_TRUNC) != 0) f.setLength(io, 0) catch |err| return mapSetLengthError(err);
        break :blk f;
    };

    // Reserve the new fd_table slot.
    const rights = deriveRights(dir_slot, fs_rights_base, fs_rights_inheriting, false);
    host.fd_table.append(host.alloc, .{
        .kind = .file,
        .rights_base = rights.base,
        .rights_inheriting = rights.inheriting,
        .fs_flags = fdflags,
        .host_handle = file.handle,
    }) catch {
        file.close(io);
        return .nomem;
    };
    const new_fd: p1.Fd = @intCast(host.fd_table.items.len - 1);

    return writeU32LE(mem, opened_fd_ptr, new_fd);
}

/// Whether a requested write right makes a directory target `isdir`. An
/// explicit `OFLAGS_DIRECTORY` open says yes; the `error.IsDir` fallback from a
/// plain open says no, because POSIX-style guests reach it read-only by design.
const WriteRightPolicy = enum { reject_write, allow_write };

/// `pathOpen` back-half for a DIRECTORY target: open `path` (relative to
/// `dir`) iterable and append a `.dir` fd-table slot (the same shape a
/// preopen root gets, so the descendant fd composes with every dir-taking op).
fn openDirSlot(
    host: *Host,
    io: std.Io,
    dir: std.Io.Dir,
    parent: *const host_mod.OpenFd,
    path: []const u8,
    fs_rights_base: p1.Rights,
    fs_rights_inheriting: p1.Rights,
    fdflags: p1.Fdflags,
    mem: []u8,
    opened_fd_ptr: u32,
    policy: WriteRightPolicy,
) p1.Errno {
    const sub = dir.openDir(io, path, .{ .iterate = true }) catch |err| return mapOpenError(err);
    // A directory cannot be opened for writing, and preview1 says so through
    // the requested rights rather than a mode flag. The check has to come
    // AFTER the open: a missing path is `noent` and a regular file is its own
    // error, and neither may be masked by the capability clash.
    if (policy == .reject_write and (fs_rights_base & p1.RIGHTS_FD_WRITE) != 0) {
        var d = sub;
        d.close(io);
        return .isdir;
    }
    const rights = deriveRights(parent, fs_rights_base, fs_rights_inheriting, true);
    host.fd_table.append(host.alloc, .{
        .kind = .dir,
        .rights_base = rights.base,
        .rights_inheriting = rights.inheriting,
        .fs_flags = fdflags,
        .host_handle = sub.handle,
    }) catch {
        var d = sub;
        d.close(io);
        return .nomem;
    };
    return writeU32LE(mem, opened_fd_ptr, @intCast(host.fd_table.items.len - 1));
}

/// Map a host `std.Io.File.Kind` to the WASI preview1 `Filetype` tag.
fn kindToFiletype(kind: std.Io.File.Kind) p1.Filetype {
    return switch (kind) {
        .file => .regular_file,
        .directory => .directory,
        .sym_link => .symbolic_link,
        .block_device => .block_device,
        .character_device => .character_device,
        .named_pipe, .unix_domain_socket, .whiteout, .door, .event_port, .unknown => .unknown,
    };
}

/// Wasm WASI snapshot-1 `fd_filestat_get` — write the `Filestat` of an
/// open fd. Stdio fds report `character_device` (what wasi-libc expects
/// for a tty-like stream); a `.file` / `.dir` slot with a host handle is
/// `stat`-ed via `std.Io.File.stat`. Out-of-range / closed → `badf`.
pub fn fdFilestatGet(host: *Host, mem: []u8, fd: p1.Fd, filestat_ptr: u32) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind == .closed) return .badf;
    switch (slot.kind) {
        // A stdio stream's filestat is synthetic, not a capability the guest
        // holds over a filesystem object; wasmtime answers it too.
        .stdin, .stdout, .stderr => {},
        .file, .dir, .closed => if (!slot.has(p1.RIGHTS_FD_FILESTAT_GET)) return .notcapable,
    }
    const dst = sliceMem(mem, filestat_ptr, @sizeOf(p1.Filestat)) orelse return .fault;

    const fs: p1.Filestat = switch (slot.kind) {
        .stdin, .stdout, .stderr => .{
            .dev = 0,
            .ino = 0,
            .filetype = .character_device,
            .nlink = 1,
            .size = 0,
            .atim = 0,
            .mtim = 0,
            .ctim = 0,
        },
        .closed => return .badf,
        .file, .dir => blk: {
            const handle = slot.host_handle orelse return .badf;
            const io = host.io orelse return .nosys;
            const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
            const st = file.stat(io) catch |err| return mapOpenError(err);
            const atim_ns: i96 = if (st.atime) |a| a.nanoseconds else st.mtime.nanoseconds;
            break :blk .{
                .dev = 0,
                .ino = @intCast(st.inode),
                .filetype = kindToFiletype(st.kind),
                .nlink = @intCast(st.nlink),
                .size = st.size,
                .atim = if (atim_ns > 0) @intCast(atim_ns) else 0,
                .mtim = if (st.mtime.nanoseconds > 0) @intCast(st.mtime.nanoseconds) else 0,
                .ctim = if (st.ctime.nanoseconds > 0) @intCast(st.ctime.nanoseconds) else 0,
            };
        },
    };
    @memcpy(dst, std.mem.asBytes(&fs));
    return .success;
}

/// Wasm WASI snapshot-1 `path_unlink_file` — delete a file relative to a
/// preopen `.dir` fd. Mirrors `pathOpen`'s front-half (preopen resolution
/// + `..`-escape guard) then `std.Io.Dir.deleteFile`. Non-preopen dirfd →
/// `notdir`; absolute / `..`-escaping path → `notcapable`.
pub fn pathUnlinkFile(host: *Host, mem: []u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    const path = sliceMemConst(mem, path_ptr, path_len) orelse return .fault;
    // POSIX: the empty path is ENOENT. Must be pre-OS: NT resolves "" against
    // a RootDirectory handle as the directory itself (delete would hit the dir).
    if (path.len == 0) return .noent;
    if (pathHasParentEscape(path)) return .notcapable;
    const dir_slot = host.translateFd(dirfd) orelse return .badf;
    if (dir_slot.kind != .dir) return .notdir;
    if (!dir_slot.has(p1.RIGHTS_PATH_UNLINK_FILE)) return .notcapable;
    const dir_handle = dir_slot.host_handle orelse return .notdir;
    const io = host.io orelse return .nosys;
    const dir: std.Io.Dir = .{ .handle = dir_handle };
    dir.deleteFile(io, path) catch |err| return mapOpenError(err);
    return .success;
}

/// Guest-path of the preopen backing a `.dir` slot, matched by the
/// slot's host handle (preopens are the only `.dir` fds with a host
/// handle registered in `host.preopens`). Null when the slot is not
/// a registered preopen.
fn preopenName(host: *Host, slot: *const host_mod.OpenFd) ?[]const u8 {
    const h = slot.host_handle orelse return null;
    for (host.preopens) |p| {
        if (p.host_fd == h) return p.guest_path;
    }
    return null;
}

/// Wasm WASI snapshot-1 `fd_prestat_get` — for a preopen `.dir` fd,
/// write its `Prestat` (tag + guest-path length). A non-preopen or
/// out-of-range fd returns `badf`; the guest's preopen-discovery loop
/// (call fd 3, 4, … until badf) relies on that to terminate.
pub fn fdPrestatGet(host: *Host, mem: []u8, fd: p1.Fd, prestat_ptr: u32) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind != .dir) return .badf;
    const name = preopenName(host, slot) orelse return .badf;
    const dst = sliceMem(mem, prestat_ptr, @sizeOf(p1.Prestat)) orelse return .fault;
    const ps: p1.Prestat = .{ .pr_type = .dir, .pr_name_len = @intCast(name.len) };
    @memcpy(dst, std.mem.asBytes(&ps));
    return .success;
}

/// Wasm WASI snapshot-1 `fd_prestat_dir_name` — copy a preopen's
/// guest path into the guest buffer (truncated to `path_len`). The
/// guest sizes the buffer from the `fd_prestat_get` name length.
pub fn fdPrestatDirName(host: *Host, mem: []u8, fd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind != .dir) return .badf;
    const name = preopenName(host, slot) orelse return .badf;
    const dst = sliceMem(mem, path_ptr, path_len) orelse return .fault;
    const n = @min(name.len, dst.len);
    @memcpy(dst[0..n], name[0..n]);
    return .success;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "fdWrite: stdout capture buffer accumulates writes" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    h.stdout_buffer = &capture;

    // Memory layout: ciovec at offset 0 (8 bytes); string at 8.
    var mem: [32]u8 = @splat(0);
    std.mem.writeInt(u32, mem[0..4], 8, .little); // buf = 8
    std.mem.writeInt(u32, mem[4..8], 3, .little); // buf_len = 3
    @memcpy(mem[8..11], "hi\n");

    const n_off: u32 = 16;
    const e = fdWrite(&h, &mem, 1, 0, 1, n_off);
    try testing.expectEqual(p1.Errno.success, e);

    try testing.expectEqualStrings("hi\n", capture.items);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, mem[16..20], .little));
}

test "fdWrite: stderr with no capture buffer routes to the real process stream (CLI path)" {
    // The CLI `run` path sets no capture buffer; with a live io context, fd 1/2
    // must reach the real process stream (else `zwasm run` silently drops
    // output). Tested on fd 2 (stderr) — writing to fd 1 would corrupt the zig
    // test --listen protocol. The single byte to stderr is harmless noise.
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io; // io set, no stderr_buffer → real stderr
    var mem: [32]u8 = @splat(0);
    mem[8] = 'x';
    std.mem.writeInt(u32, mem[0..4], 8, .little); // ciovec.buf = 8
    std.mem.writeInt(u32, mem[4..8], 1, .little); // ciovec.len = 1
    try testing.expectEqual(p1.Errno.success, fdWrite(&h, &mem, 2, 0, 1, 16));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, mem[16..20], .little));

    // No io AND no buffer (headless) → drop as a no-op success.
    h.io = null;
    try testing.expectEqual(p1.Errno.success, fdWrite(&h, &mem, 2, 0, 1, 16));
}

test "fdWrite: gather write across multiple ciovecs" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    h.stdout_buffer = &capture;

    // Two ciovecs: (16, 5) "hello" + (24, 1) "\n"
    var mem: [64]u8 = @splat(0);
    std.mem.writeInt(u32, mem[0..4], 16, .little);
    std.mem.writeInt(u32, mem[4..8], 5, .little);
    std.mem.writeInt(u32, mem[8..12], 24, .little);
    std.mem.writeInt(u32, mem[12..16], 1, .little);
    @memcpy(mem[16..21], "hello");
    mem[24] = '\n';

    const nwritten: u32 = 32;
    const e = fdWrite(&h, &mem, 1, 0, 2, nwritten);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqualStrings("hello\n", capture.items);
    try testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, mem[32..36], .little));
}

test "fdWrite: stdin (fd=0) returns notsup" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = fdWrite(&h, &mem, 0, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notsup, e);
}

test "fdWrite: out-of-range fd returns badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = fdWrite(&h, &mem, 99, 0, 0, 0);
    try testing.expectEqual(p1.Errno.badf, e);
}

test "fdWrite: out-of-bounds ciovec buf returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    // ciovec at 0: buf=200 (way past mem.len=16), buf_len=4.
    std.mem.writeInt(u32, mem[0..4], 200, .little);
    std.mem.writeInt(u32, mem[4..8], 4, .little);
    const e = fdWrite(&h, &mem, 1, 0, 1, 8);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "fdRead: stdin reads from host.stdin_bytes; EOF returns nread=0" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.stdin_bytes = "abc";

    var mem: [16]u8 = @splat(0);
    std.mem.writeInt(u32, mem[0..4], 8, .little); // iovec.buf = 8
    std.mem.writeInt(u32, mem[4..8], 4, .little); // iovec.buf_len = 4

    const e1 = fdRead(&h, &mem, 0, 0, 1, 12);
    try testing.expectEqual(p1.Errno.success, e1);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, mem[12..16], .little));
    try testing.expectEqualStrings("abc", mem[8..11]);
    try testing.expectEqual(@as(usize, 3), h.stdin_pos);

    // Second read: EOF.
    @memset(&mem, 0);
    std.mem.writeInt(u32, mem[0..4], 8, .little);
    std.mem.writeInt(u32, mem[4..8], 4, .little);
    const e2 = fdRead(&h, &mem, 0, 0, 1, 12);
    try testing.expectEqual(p1.Errno.success, e2);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, mem[12..16], .little));
}

test "fdRead: stdout (fd=1) returns notsup" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = fdRead(&h, &mem, 1, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notsup, e);
}

test "fdClose: stdio = success-noop; out-of-range = badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    try testing.expectEqual(p1.Errno.success, fdClose(&h, 0));
    try testing.expectEqual(p1.Errno.success, fdClose(&h, 1));
    try testing.expectEqual(p1.Errno.success, fdClose(&h, 2));
    // Stdio still resolvable post-close.
    try testing.expect(h.translateFd(1) != null);
    try testing.expectEqual(p1.Errno.badf, fdClose(&h, 99));
}

test "fdSeek / fdTell: stdio returns spipe" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [8]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.spipe, fdSeek(&h, &mem, 1, 0, 0, 0));
    try testing.expectEqual(p1.Errno.spipe, fdTell(&h, &mem, 0, 0));
}

test "fdFdstatGet: stdout writes 24-byte block (character_device, RIGHTS_FD_WRITE)" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [32]u8 = @splat(0xAB);
    const e = fdFdstatGet(&h, &mem, 1, 0);
    try testing.expectEqual(p1.Errno.success, e);
    // filetype = character_device (2)
    try testing.expectEqual(@as(u8, @intFromEnum(p1.Filetype.character_device)), mem[0]);
    // reserved byte zeroed
    try testing.expectEqual(@as(u8, 0), mem[1]);
    // fs_flags = 0
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, mem[2..4], .little));
    // rights_base = RIGHTS_FD_WRITE (default for fd 1)
    try testing.expectEqual(p1.RIGHTS_FD_WRITE, std.mem.readInt(u64, mem[8..16], .little));
    // rights_inheriting = 0
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, mem[16..24], .little));
    // The 25th byte should be untouched.
    try testing.expectEqual(@as(u8, 0xAB), mem[24]);
}

test "fdFdstatGet: out-of-range fd returns badf; out-of-bounds ptr returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [32]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.badf, fdFdstatGet(&h, &mem, 99, 0));
    try testing.expectEqual(p1.Errno.fault, fdFdstatGet(&h, &mem, 1, 100));
}

test "fdSync / fdDatasync: real file fd succeeds; stdio noop; closed badf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..28], "synced.txt\x00\x00"[0..12]);
    const oe = pathOpen(&h, &mem, dirfd, 0, 16, 10, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE | p1.RIGHTS_FD_SYNC | p1.RIGHTS_FD_DATASYNC, 0, 0, 32);
    try testing.expectEqual(p1.Errno.success, oe);
    const fd = std.mem.readInt(u32, mem[32..36], .little);

    try testing.expectEqual(p1.Errno.success, fdSync(&h, fd));
    try testing.expectEqual(p1.Errno.success, fdDatasync(&h, fd));
    // stdout = success noop; out-of-range / closed = badf.
    try testing.expectEqual(p1.Errno.success, fdSync(&h, 1));
    try testing.expectEqual(p1.Errno.badf, fdSync(&h, 999));

    const slot = h.translateFd(fd).?;
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
    try testing.expectEqual(p1.Errno.badf, fdSync(&h, fd));
    try testing.expectEqual(p1.Errno.badf, fdDatasync(&h, fd));
}

test "fdPwrite / fdPread: positional round-trip at an offset (no cursor move)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[0..8], "pos.txt\x00");
    // Positional IO is a seek plus a read/write, so it needs FD_SEEK too.
    const oe = pathOpen(&h, &mem, dirfd, 0, 0, 7, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE | p1.RIGHTS_FD_READ | p1.RIGHTS_FD_SEEK, 0, 0, 96);
    try testing.expectEqual(p1.Errno.success, oe);
    const fd = std.mem.readInt(u32, mem[96..100], .little);

    // ciovec at mem[16]: {buf=24, len=5}; payload "WORLD" at mem[24].
    std.mem.writeInt(u32, mem[16..20], 24, .little);
    std.mem.writeInt(u32, mem[20..24], 5, .little);
    @memcpy(mem[24..29], "WORLD");
    try testing.expectEqual(p1.Errno.success, fdPwrite(&h, &mem, fd, 16, 1, 3, 64));
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, mem[64..68], .little));

    // iovec at mem[40]: {buf=48, len=5}; pread the same offset back.
    std.mem.writeInt(u32, mem[40..44], 48, .little);
    std.mem.writeInt(u32, mem[44..48], 5, .little);
    try testing.expectEqual(p1.Errno.success, fdPread(&h, &mem, fd, 40, 1, 3, 68));
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, mem[68..72], .little));
    try testing.expectEqualStrings("WORLD", mem[48..53]);

    const slot = h.translateFd(fd).?;
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "sock_*: notsock on a non-socket fd, badf on an invalid fd" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    // stdin (fd 0) is a valid fd but not a socket → notsock.
    try testing.expectEqual(p1.Errno.notsock, sockAccept(&h, 0));
    try testing.expectEqual(p1.Errno.notsock, sockRecv(&h, 1));
    try testing.expectEqual(p1.Errno.notsock, sockSend(&h, 2));
    try testing.expectEqual(p1.Errno.notsock, sockShutdown(&h, 0));
    // Out-of-range fd → badf.
    try testing.expectEqual(p1.Errno.badf, sockRecv(&h, 999));
    try testing.expectEqual(p1.Errno.badf, sockShutdown(&h, 999));
}

test "fdRenumber: moves an fd onto another; source becomes badf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x", .data = "12345" }); // 5 bytes
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "y", .data = "z" }); // 1 byte
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[100..101], "x");
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 100, 1, 0, p1.RIGHTS_FD_READ | p1.RIGHTS_FD_FILESTAT_GET, 0, 0, 108));
    const fd_x = std.mem.readInt(u32, mem[108..112], .little);
    @memcpy(mem[100..101], "y");
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 100, 1, 0, p1.RIGHTS_FD_READ | p1.RIGHTS_FD_FILESTAT_GET, 0, 0, 108));
    const fd_y = std.mem.readInt(u32, mem[108..112], .little);

    // Renumber x onto y: fd_y now holds x's 5-byte file; fd_x is closed.
    try testing.expectEqual(p1.Errno.success, fdRenumber(&h, fd_x, fd_y));
    try testing.expectEqual(p1.Errno.success, fdFilestatGet(&h, &mem, fd_y, 0));
    try testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, mem[32..40], .little)); // Filestat.size @32
    try testing.expectEqual(p1.Errno.badf, fdFilestatGet(&h, &mem, fd_x, 0)); // source closed

    // Self-renumber is a no-op; out-of-range either side → badf.
    try testing.expectEqual(p1.Errno.success, fdRenumber(&h, fd_y, fd_y));
    try testing.expectEqual(p1.Errno.badf, fdRenumber(&h, 999, fd_y));
    try testing.expectEqual(p1.Errno.badf, fdRenumber(&h, fd_y, 999));

    const slot = h.translateFd(fd_y).?;
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "fdReaddir: enumerates '.', '..', real entries; cookie resumes past them" {
    // `.iterate = true` — Linux `Dir.iterate()` (getdents) requires the dir fd
    // to be opened iterably or it panics BADF (macOS is lenient). Production
    // preopens open with `.iterate = true` (cli/run.zig); mirror that here.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f1", .data = "a" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f2", .data = "bb" });
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [512]u8 = @splat(0);
    const USED = 480;
    try testing.expectEqual(p1.Errno.success, fdReaddir(&h, &mem, dirfd, 0, 400, 0, USED));
    const used = std.mem.readInt(u32, mem[USED..][0..4], .little);

    var found = [_]bool{ false, false, false, false }; // ., .., f1, f2
    var count: usize = 0;
    var off: usize = 0;
    while (off + 24 <= used) {
        const namlen = std.mem.readInt(u32, mem[off + 16 ..][0..4], .little);
        const dtype = mem[off + 20];
        off += 24;
        if (off + namlen > used) break; // truncated tail
        const name = mem[off .. off + namlen];
        if (std.mem.eql(u8, name, ".")) {
            found[0] = true;
        } else if (std.mem.eql(u8, name, "..")) {
            found[1] = true;
        } else if (std.mem.eql(u8, name, "f1")) {
            found[2] = true;
            try testing.expectEqual(@as(u8, @intFromEnum(p1.Filetype.regular_file)), dtype);
        } else if (std.mem.eql(u8, name, "f2")) {
            found[3] = true;
        }
        off += namlen;
        count += 1;
    }
    try testing.expect(found[0] and found[1] and found[2] and found[3]);
    try testing.expectEqual(@as(usize, 4), count);

    // cookie=2 skips "." and ".." → only the 2 real entries remain.
    @memset(&mem, 0);
    try testing.expectEqual(p1.Errno.success, fdReaddir(&h, &mem, dirfd, 0, 400, 2, USED));
    const used2 = std.mem.readInt(u32, mem[USED..][0..4], .little);
    var c2: usize = 0;
    var o2: usize = 0;
    while (o2 + 24 <= used2) {
        const nl = std.mem.readInt(u32, mem[o2 + 16 ..][0..4], .little);
        o2 += 24;
        if (o2 + nl > used2) break;
        try testing.expect(!std.mem.eql(u8, mem[o2 .. o2 + nl], ".") and !std.mem.eql(u8, mem[o2 .. o2 + nl], ".."));
        o2 += nl;
        c2 += 1;
    }
    try testing.expectEqual(@as(usize, 2), c2);

    try testing.expectEqual(p1.Errno.notdir, fdReaddir(&h, &mem, 1, 0, 400, 0, USED));
    try testing.expectEqual(p1.Errno.badf, fdReaddir(&h, &mem, 999, 0, 400, 0, USED));
}

test "fdFdstatSetRights: narrows rights; re-widening is notcapable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");
    var mem: [128]u8 = @splat(0);
    @memcpy(mem[0..8], "rt.txt\x00\x00"[0..8]);
    const oe = pathOpen(&h, &mem, dirfd, 0, 0, 6, p1.OFLAGS_CREAT, p1.RIGHTS_FD_READ | p1.RIGHTS_FD_WRITE, 0, 0, 96);
    try testing.expectEqual(p1.Errno.success, oe);
    const fd = std.mem.readInt(u32, mem[96..100], .little);
    try testing.expect(h.translateFd(fd).?.rights_base & p1.RIGHTS_FD_WRITE != 0);

    // Drop WRITE → success; the slot now holds only READ.
    try testing.expectEqual(p1.Errno.success, fdFdstatSetRights(&h, fd, p1.RIGHTS_FD_READ, 0));
    try testing.expectEqual(@as(p1.Rights, p1.RIGHTS_FD_READ), h.translateFd(fd).?.rights_base);
    // Re-request the now-absent WRITE bit → notcapable (rights only narrow).
    try testing.expectEqual(p1.Errno.notcapable, fdFdstatSetRights(&h, fd, p1.RIGHTS_FD_READ | p1.RIGHTS_FD_WRITE, 0));
    try testing.expectEqual(p1.Errno.badf, fdFdstatSetRights(&h, 999, 0, 0));

    const slot = h.translateFd(fd).?;
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "fdFilestatSetSize / fdAllocate: truncate-extend exact, allocate grows-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[0..8], "sz.txt\x00\x00"[0..8]);
    const oe = pathOpen(&h, &mem, dirfd, 0, 0, 6, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE |
        p1.RIGHTS_FD_FILESTAT_SET_SIZE | p1.RIGHTS_FD_ALLOCATE | p1.RIGHTS_FD_FILESTAT_GET, 0, 0, 96);
    try testing.expectEqual(p1.Errno.success, oe);
    const fd = std.mem.readInt(u32, mem[96..100], .little);

    const sizeOf = struct {
        fn f(hh: *Host, m: []u8, ffd: p1.Fd) u64 {
            _ = fdFilestatGet(hh, m, ffd, 0);
            return std.mem.readInt(u64, m[32..40], .little); // Filestat.size @32
        }
    }.f;

    // set_size to exactly 100, then truncate back to 4.
    try testing.expectEqual(p1.Errno.success, fdFilestatSetSize(&h, fd, 100));
    try testing.expectEqual(@as(u64, 100), sizeOf(&h, &mem, fd));
    try testing.expectEqual(p1.Errno.success, fdFilestatSetSize(&h, fd, 4));
    try testing.expectEqual(@as(u64, 4), sizeOf(&h, &mem, fd));

    // allocate grows to offset+len=50; a smaller request never shrinks.
    try testing.expectEqual(p1.Errno.success, fdAllocate(&h, fd, 10, 40));
    try testing.expectEqual(@as(u64, 50), sizeOf(&h, &mem, fd));
    try testing.expectEqual(p1.Errno.success, fdAllocate(&h, fd, 0, 20));
    try testing.expectEqual(@as(u64, 50), sizeOf(&h, &mem, fd));

    // stdio / out-of-range rejections.
    try testing.expectEqual(p1.Errno.spipe, fdFilestatSetSize(&h, 1, 0));
    try testing.expectEqual(p1.Errno.badf, fdAllocate(&h, 999, 0, 1));

    const slot = h.translateFd(fd).?;
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "fdFilestatSetTimes: set mtim and read it back via fdFilestatGet" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[0..8], "tim.txt\x00");
    const oe = pathOpen(&h, &mem, dirfd, 0, 0, 7, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE |
        p1.RIGHTS_FD_FILESTAT_SET_TIMES | p1.RIGHTS_FD_FILESTAT_GET, 0, 0, 96);
    try testing.expectEqual(p1.Errno.success, oe);
    const fd = std.mem.readInt(u32, mem[96..100], .little);

    // 2.0s exactly — a whole second survives any filesystem mtime granularity.
    try testing.expectEqual(p1.Errno.success, fdFilestatSetTimes(&h, fd, 0, 2_000_000_000, p1.FSTFLAGS_MTIM));
    try testing.expectEqual(p1.Errno.success, fdFilestatGet(&h, &mem, fd, 0));
    // Filestat.mtim is at byte offset 48 (dev8 ino8 type1 pad7 nlink8 size8 atim8 mtim8 ctim8).
    try testing.expectEqual(@as(u64, 2_000_000_000), std.mem.readInt(u64, mem[48..56], .little));

    // Conflicting explicit + NOW for one timestamp → inval.
    try testing.expectEqual(p1.Errno.inval, fdFilestatSetTimes(&h, fd, 0, 0, p1.FSTFLAGS_MTIM | p1.FSTFLAGS_MTIM_NOW));
    // stdio → spipe; out-of-range → badf.
    try testing.expectEqual(p1.Errno.spipe, fdFilestatSetTimes(&h, 1, 0, 0, p1.FSTFLAGS_MTIM_NOW));
    try testing.expectEqual(p1.Errno.badf, fdFilestatSetTimes(&h, 999, 0, 0, p1.FSTFLAGS_MTIM_NOW));

    const slot = h.translateFd(fd).?;
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "fdPread / fdPwrite: stdio is spipe; out-of-range is badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [32]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.spipe, fdPread(&h, &mem, 0, 0, 1, 0, 16));
    try testing.expectEqual(p1.Errno.spipe, fdPwrite(&h, &mem, 1, 0, 1, 0, 16));
    try testing.expectEqual(p1.Errno.badf, fdPread(&h, &mem, 999, 0, 1, 0, 16));
}

test "fdAdvise: valid advice on a stdio fd is spipe; invalid advice is inval; bad fd is badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    // advice tag is validated before the fd, so an out-of-range advice wins.
    try testing.expectEqual(p1.Errno.inval, fdAdvise(&h, 1, 0, 0, 6));
    // valid advice on stdout → spipe (not a seekable file).
    try testing.expectEqual(p1.Errno.spipe, fdAdvise(&h, 1, 0, 0, 0));
    try testing.expectEqual(p1.Errno.badf, fdAdvise(&h, 999, 0, 0, 3));
}

test "pathOpen: rejects parent-escape and absolute paths with notcapable" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    const fake_fd: std.posix.fd_t = undefined;
    const dirfd = try h.addPreopen(fake_fd, "/sandbox");

    // "../escape"
    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..25], "../escape");
    const e1 = pathOpen(&h, &mem, dirfd, 0, 16, 9, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notcapable, e1);

    // "/etc/passwd"
    @memset(&mem, 0);
    @memcpy(mem[16..27], "/etc/passwd");
    const e2 = pathOpen(&h, &mem, dirfd, 0, 16, 11, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notcapable, e2);
}

test "pathOpen: returns notdir when dirfd is not a preopen" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..23], "foo.txt");
    // fd 1 = stdout (not a .dir).
    const e = pathOpen(&h, &mem, 1, 0, 16, 7, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notdir, e);
}

test "pathOpen: out-of-bounds path slice returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    const fake_fd: std.posix.fd_t = undefined;
    const dirfd = try h.addPreopen(fake_fd, "/sandbox");
    var mem: [16]u8 = @splat(0);
    // path_ptr=10, path_len=20 → end=30 past mem.len=16.
    const e = pathOpen(&h, &mem, dirfd, 0, 10, 20, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "pathOpen: happy path opens an existing file inside a real preopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.txt", .data = "Hi" });

    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..25], "hello.txt");
    const e = pathOpen(&h, &mem, dirfd, 0, 16, 9, 0, p1.RIGHTS_FD_READ, 0, 0, 32);
    try testing.expectEqual(p1.Errno.success, e);

    const new_fd = std.mem.readInt(u32, mem[32..36], .little);
    // fd table starts at 3 stdio + 1 preopen = 4 entries; new fd
    // is appended at index 4.
    try testing.expectEqual(@as(u32, 4), new_fd);

    const slot = h.translateFd(new_fd) orelse return error.MissingFile;
    try testing.expectEqual(host_mod.FdKind.file, slot.kind);
    // Close the host file via std.Io.File. The flags field is
    // not load-bearing for close (the close vtable just looks
    // at the handle), so the default `.nonblocking = false`
    // suffices. Production cleanup will route through
    // `fd_close` once that's wired with `io`.
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "pathOpen: O_CREAT creates a new file inside a real preopen (D-243)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..28], "created.txt\x00"[0..12]);
    // oflags = OFLAGS_CREAT, rights include FD_WRITE → createFile.
    const e = pathOpen(&h, &mem, dirfd, 0, 16, 11, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE, 0, 0, 32);
    try testing.expectEqual(p1.Errno.success, e);

    // The file now exists on the host inside the preopen dir.
    const st = tmp.dir.statFile(testing.io, "created.txt", .{}) catch return error.FileNotCreated;
    try testing.expectEqual(std.Io.File.Kind.file, st.kind);

    const new_fd = std.mem.readInt(u32, mem[32..36], .little);
    const slot = h.translateFd(new_fd) orelse return error.MissingFile;
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "fdWrite + fdRead round-trip through a real file fd (D-243 cycle 2)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[16..22], "rt.txt");

    // Create + write "hello fd" via a file fd.
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 16, 6, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE, 0, 0, 100));
    const wfd = std.mem.readInt(u32, mem[100..104], .little);
    @memcpy(mem[48..56], "hello fd");
    std.mem.writeInt(u32, mem[32..36], 48, .little); // ciovec.buf
    std.mem.writeInt(u32, mem[36..40], 8, .little); // ciovec.len
    try testing.expectEqual(p1.Errno.success, fdWrite(&h, &mem, wfd, 32, 1, 104));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, mem[104..108], .little));

    // Reopen for read and read it back (fresh fd → cursor at 0).
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 16, 6, 0, p1.RIGHTS_FD_READ, 0, 0, 100));
    const rfd = std.mem.readInt(u32, mem[100..104], .little);
    std.mem.writeInt(u32, mem[32..36], 64, .little); // iovec.buf
    std.mem.writeInt(u32, mem[36..40], 32, .little); // iovec.len (capacity)
    try testing.expectEqual(p1.Errno.success, fdRead(&h, &mem, rfd, 32, 1, 108));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, mem[108..112], .little)); // nread
    try testing.expectEqualStrings("hello fd", mem[64..72]);
}

test "fd_seek + fd_tell move + report the file cursor (set/cur/end whence)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "seek.txt", .data = "0123456789" });
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[16..24], "seek.txt");
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 16, 8, 0, p1.RIGHTS_FD_READ | p1.RIGHTS_FD_SEEK | p1.RIGHTS_FD_TELL, 0, 0, 100));
    const fd = std.mem.readInt(u32, mem[100..104], .little);
    const slot = h.translateFd(fd).?;
    defer {
        const f: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
        f.close(testing.io);
        slot.kind = .closed;
    }

    // iovec scratch at mem[64..]; result slots at mem[104..] (nread) + mem[116..] (new_pos).
    std.mem.writeInt(u32, mem[32..36], 64, .little); // iovec.buf

    // read 5 → "01234", cursor advances to 5
    std.mem.writeInt(u32, mem[36..40], 5, .little); // iovec.len
    try testing.expectEqual(p1.Errno.success, fdRead(&h, &mem, fd, 32, 1, 104));
    try testing.expectEqualStrings("01234", mem[64..69]);

    // tell → 5
    try testing.expectEqual(p1.Errno.success, fdTell(&h, &mem, fd, 116));
    try testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, mem[116..124], .little));

    // seek SET 2 → new_pos 2; read 3 → "234"
    try testing.expectEqual(p1.Errno.success, fdSeek(&h, &mem, fd, 2, @intFromEnum(p1.Whence.set), 116));
    try testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, mem[116..124], .little));
    std.mem.writeInt(u32, mem[36..40], 3, .little);
    try testing.expectEqual(p1.Errno.success, fdRead(&h, &mem, fd, 32, 1, 104));
    try testing.expectEqualStrings("234", mem[64..67]);

    // seek END -3 (size 10) → 7; read 3 → "789" (cursor now 10)
    try testing.expectEqual(p1.Errno.success, fdSeek(&h, &mem, fd, -3, @intFromEnum(p1.Whence.end), 116));
    try testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, mem[116..124], .little));
    try testing.expectEqual(p1.Errno.success, fdRead(&h, &mem, fd, 32, 1, 104));
    try testing.expectEqualStrings("789", mem[64..67]);

    // seek CUR -10 (from 10) → 0
    try testing.expectEqual(p1.Errno.success, fdSeek(&h, &mem, fd, -10, @intFromEnum(p1.Whence.cur), 116));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, mem[116..124], .little));

    // a negative resulting offset is invalid
    try testing.expectEqual(p1.Errno.inval, fdSeek(&h, &mem, fd, -1, @intFromEnum(p1.Whence.cur), 116));
}

test "fdFdstatSetFlags: persists allowed bits + masks unknown ones" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    // Set NONBLOCK | APPEND | (some unknown high bit).
    const requested: p1.Fdflags = p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_APPEND | 0x8000;
    const e = fdFdstatSetFlags(&h, 1, requested);
    try testing.expectEqual(p1.Errno.success, e);
    const slot = h.translateFd(1).?;
    try testing.expectEqual(@as(p1.Fdflags, p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_APPEND), slot.fs_flags);

    // Round-trip: fdstat_get reflects the new flags.
    var mem: [32]u8 = @splat(0);
    _ = fdFdstatGet(&h, &mem, 1, 0);
    try testing.expectEqual(
        @as(u16, p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_APPEND),
        std.mem.readInt(u16, mem[2..4], .little),
    );
}

test "fdPrestatGet: no preopens → fd 3 is badf (the go_math_big discovery-loop terminator)" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [32]u8 = @splat(0);
    // No preopens registered (fd_table = stdin/stdout/stderr only).
    try testing.expectEqual(p1.Errno.badf, fdPrestatGet(&h, &mem, 3, 0));
    // stdio fds are not dirs either.
    try testing.expectEqual(p1.Errno.badf, fdPrestatGet(&h, &mem, 1, 0));
}

test "fdPrestatGet + fdPrestatDirName: a preopen reports its Prestat + dir name" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    // host_fd is opaque to these calls (stored, never derefed). Use a typed
    // `fd_t` rather than a bare `99` — fd_t is i32 on POSIX but `*anyopaque`
    // (HANDLE) on Windows, where a comptime_int won't coerce (D-247-adjacent
    // windowsmini compile fix; mirrors the fake_fd above).
    const fake_fd: std.posix.fd_t = undefined;
    const fd = try h.addPreopen(fake_fd, "/sandbox");
    var mem: [32]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.success, fdPrestatGet(&h, &mem, fd, 0));
    // Prestat: pr_type=.dir (0) @0, pr_name_len @4 = len("/sandbox")=8.
    try testing.expectEqual(@as(u8, 0), mem[0]);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, mem[4..8], .little));
    // dir name copied into the guest buffer.
    try testing.expectEqual(p1.Errno.success, fdPrestatDirName(&h, &mem, fd, 8, 8));
    try testing.expectEqualStrings("/sandbox", mem[8..16]);
}

test "fdFilestatGet: stdout reports character_device; bad fd is badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [64]u8 = @splat(0xAA);
    try testing.expectEqual(p1.Errno.success, fdFilestatGet(&h, &mem, 1, 0));
    // Filestat.filetype is at offset 16 (dev u64 @0, ino u64 @8, filetype @16).
    try testing.expectEqual(@as(u8, @intFromEnum(p1.Filetype.character_device)), mem[16]);
    try testing.expectEqual(p1.Errno.badf, fdFilestatGet(&h, &mem, 99, 0));
}

test "pathUnlinkFile: non-preopen dirfd is notdir; bad fd is badf; .. escape is notcapable" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem = [_]u8{ 'a', '.', 't', 'x', 't' } ++ [_]u8{0} ** 16;
    // fd 1 (stdout) is not a .dir → notdir.
    try testing.expectEqual(p1.Errno.notdir, pathUnlinkFile(&h, &mem, 1, 0, 5));
    // out-of-range fd → badf.
    try testing.expectEqual(p1.Errno.badf, pathUnlinkFile(&h, &mem, 99, 0, 5));
    // a `..` traversal is rejected before any fd work.
    @memcpy(mem[0..3], "../");
    try testing.expectEqual(p1.Errno.notcapable, pathUnlinkFile(&h, &mem, 1, 0, 3));
}

test "fdWrite: max_capture_bytes bounds a capture buffer and reports nospc" {
    // D-349, found from cljw. Nothing else bounds a capture buffer: fuel bounds
    // instructions, and bytes-per-instruction is the guest's choice. Measured
    // from the consumer side, a 64-byte-per-iteration guest buffered 64 MB per
    // 1e6 fuel — so ~64 GB under zwasm's own default fuel.
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    h.stdout_buffer = &capture;
    h.max_capture_bytes = 5;

    var mem: [32]u8 = @splat(0);
    @memcpy(mem[8..12], "abcd");
    std.mem.writeInt(u32, mem[0..4], 8, .little); // ciovec.buf
    std.mem.writeInt(u32, mem[4..8], 4, .little); // ciovec.len = 4

    // First write fits entirely.
    try testing.expectEqual(p1.Errno.success, fdWrite(&h, &mem, 1, 0, 1, 16));
    try testing.expectEqualStrings("abcd", capture.items);
    try testing.expect(!h.capture_truncated);

    // Second write has room for one byte: the prefix is KEPT (a caller is
    // better served by a truncated tail than by losing the whole write) and the
    // errno is nospc, the one a real fd gives when the device is full.
    try testing.expectEqual(p1.Errno.nospc, fdWrite(&h, &mem, 1, 0, 1, 16));
    try testing.expectEqualStrings("abcda", capture.items);
    try testing.expect(h.capture_truncated);

    // Third write has no room at all — still nospc, and nothing grows.
    try testing.expectEqual(p1.Errno.nospc, fdWrite(&h, &mem, 1, 0, 1, 16));
    try testing.expectEqual(@as(usize, 5), capture.items.len);

    // A null cap is the default and is unbounded — the behaviour every existing
    // caller had before this axis existed.
    var h2 = try Host.init(testing.allocator);
    defer h2.deinit();
    var cap2: std.ArrayList(u8) = .empty;
    defer cap2.deinit(testing.allocator);
    h2.stdout_buffer = &cap2;
    var i: usize = 0;
    while (i < 10) : (i += 1) try testing.expectEqual(p1.Errno.success, fdWrite(&h2, &mem, 1, 0, 1, 16));
    try testing.expectEqual(@as(usize, 40), cap2.items.len);
    try testing.expect(!h2.capture_truncated);
}

// ============================================================
// Rights: derivation + enforcement
// ============================================================
test "deriveRights: a derived fd cannot exceed the parent's inheriting set" {
    const parent: host_mod.OpenFd = .{
        .kind = .dir,
        .rights_base = p1.RIGHTS_DIRECTORY_BASE,
        .rights_inheriting = p1.RIGHTS_FD_READ | p1.RIGHTS_FD_SEEK,
    };
    // Asking for more than the parent may hand down is not an error — witx
    // lets `path_open` return an fd with fewer rights than requested.
    const r = deriveRights(&parent, p1.RIGHTS_ALL, p1.RIGHTS_ALL, false);
    try testing.expectEqual(p1.RIGHTS_FD_READ | p1.RIGHTS_FD_SEEK, r.base);
    try testing.expectEqual(p1.RIGHTS_FD_READ | p1.RIGHTS_FD_SEEK, r.inheriting);

    // Asking for less keeps less.
    const narrow = deriveRights(&parent, p1.RIGHTS_FD_READ, 0, false);
    try testing.expectEqual(p1.RIGHTS_FD_READ, narrow.base);
    try testing.expectEqual(@as(p1.Rights, 0), narrow.inheriting);
}

test "deriveRights: a directory fd never carries fd_seek or fd_write" {
    const parent: host_mod.OpenFd = .{
        .kind = .dir,
        .rights_base = p1.RIGHTS_DIRECTORY_BASE,
        .rights_inheriting = p1.RIGHTS_DIRECTORY_INHERITING,
    };
    // `directory_seek` asks for FD_SEEK on an OFLAGS_DIRECTORY open and then
    // asserts the fd does NOT report it back.
    const dir = deriveRights(&parent, p1.RIGHTS_FD_SEEK | p1.RIGHTS_FD_READDIR, p1.RIGHTS_ALL, true);
    try testing.expectEqual(@as(p1.Rights, 0), dir.base & p1.RIGHTS_FD_SEEK);
    try testing.expectEqual(p1.RIGHTS_FD_READDIR, dir.base & p1.RIGHTS_FD_READDIR);
    // The mask is a filetype rule, not a capability one: it applies to the fd
    // itself, never to what the fd may hand down.
    try testing.expect(dir.inheriting & p1.RIGHTS_FD_SEEK != 0);

    // The same request against a regular file keeps the seek right.
    const file = deriveRights(&parent, p1.RIGHTS_FD_SEEK, 0, false);
    try testing.expectEqual(p1.RIGHTS_FD_SEEK, file.base);
}

test "path_open: a write right on a directory target is isdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");
    const root: std.Io.Dir = .{ .handle = tmp.dir.handle };
    try root.createDir(testing.io, "sub", std.Io.File.Permissions.default_dir);

    var mem: [64]u8 = @splat(0);
    @memcpy(mem[0..3], "sub");
    // Read rights on a directory are fine; asking to write one is not.
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 3, p1.OFLAGS_DIRECTORY, p1.RIGHTS_FD_READ, 0, 0, 32));
    try testing.expectEqual(p1.Errno.isdir, pathOpen(&h, &mem, dirfd, 0, 0, 3, p1.OFLAGS_DIRECTORY, p1.RIGHTS_FD_READ | p1.RIGHTS_FD_WRITE, 0, 0, 32));
    // Without OFLAGS_DIRECTORY the open falls back to a directory open — the
    // POSIX-style pattern (Go's os.Open before ReadDir) that predates rights.
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 3, 0, p1.RIGHTS_FD_WRITE, 0, 0, 32));

    // The clash must not mask what the target actually is. A guest probing for
    // a directory with write rights is owed `noent` for a missing path, not a
    // capability answer that says the path exists. wasmtime 47.0.3 agrees on
    // all three (measured: noent / its own not-a-directory error / isdir).
    @memset(mem[0..64], 0);
    @memcpy(mem[0..4], "nope");
    const write_dir = p1.OFLAGS_DIRECTORY;
    try testing.expectEqual(p1.Errno.noent, pathOpen(&h, &mem, dirfd, 0, 0, 4, write_dir, p1.RIGHTS_FD_WRITE, 0, 0, 32));
    try testing.expectEqual(p1.Errno.noent, pathOpen(&h, &mem, dirfd, 0, 0, 4, write_dir, p1.RIGHTS_FD_READ, 0, 0, 32));

    // And a regular file answers the same way with or without the write right.
    @memset(mem[0..64], 0);
    @memcpy(mem[0..5], "f.txt");
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 5, p1.OFLAGS_CREAT, 0, 0, 0, 32));
    const with_write = pathOpen(&h, &mem, dirfd, 0, 0, 5, write_dir, p1.RIGHTS_FD_WRITE, 0, 0, 32);
    const read_only = pathOpen(&h, &mem, dirfd, 0, 0, 5, write_dir, p1.RIGHTS_FD_READ, 0, 0, 32);
    try testing.expectEqual(read_only, with_write);
    try testing.expect(with_write != .isdir);
}

/// Push a `.file` slot carrying exactly `rights` and return its guest fd. No
/// host handle: every test below asserts the rights check fires BEFORE the
/// handle is touched, so a `badf` here would mean the gate ran too late.
fn pushRightsOnlyFile(h: *Host, rights: p1.Rights) !p1.Fd {
    try h.fd_table.append(h.alloc, .{ .kind = .file, .rights_base = rights });
    return @intCast(h.fd_table.items.len - 1);
}

test "rights gate: a call the fd cannot make is notcapable, not badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [64]u8 = @splat(0);

    const no_read = try pushRightsOnlyFile(&h, p1.RIGHTS_FD_WRITE);
    try testing.expectEqual(p1.Errno.notcapable, fdRead(&h, &mem, no_read, 0, 1, 32));

    const no_write = try pushRightsOnlyFile(&h, p1.RIGHTS_FD_READ);
    try testing.expectEqual(p1.Errno.notcapable, fdWrite(&h, &mem, no_write, 0, 1, 32));

    const bare = try pushRightsOnlyFile(&h, 0);
    try testing.expectEqual(p1.Errno.notcapable, fdSync(&h, bare));
    try testing.expectEqual(p1.Errno.notcapable, fdDatasync(&h, bare));
    try testing.expectEqual(p1.Errno.notcapable, fdAdvise(&h, bare, 0, 0, 0));
    try testing.expectEqual(p1.Errno.notcapable, fdAllocate(&h, bare, 0, 1));
    try testing.expectEqual(p1.Errno.notcapable, fdFilestatGet(&h, &mem, bare, 0));
    try testing.expectEqual(p1.Errno.notcapable, fdFilestatSetSize(&h, bare, 0));
    try testing.expectEqual(p1.Errno.notcapable, fdFilestatSetTimes(&h, bare, 0, 0, 0));
    try testing.expectEqual(p1.Errno.notcapable, fdFdstatSetFlags(&h, bare, 0));

    // fd_readdir needs a directory to reach its rights check at all.
    try h.fd_table.append(h.alloc, .{ .kind = .dir });
    const bare_dir: p1.Fd = @intCast(h.fd_table.items.len - 1);
    try testing.expectEqual(p1.Errno.notcapable, fdReaddir(&h, &mem, bare_dir, 0, 8, 0, 32));

    // Positional IO is a seek plus a read/write, so it needs both bits.
    const read_only = try pushRightsOnlyFile(&h, p1.RIGHTS_FD_READ);
    try testing.expectEqual(p1.Errno.notcapable, fdPread(&h, &mem, read_only, 0, 1, 0, 32));
    const write_only = try pushRightsOnlyFile(&h, p1.RIGHTS_FD_WRITE);
    try testing.expectEqual(p1.Errno.notcapable, fdPwrite(&h, &mem, write_only, 0, 1, 0, 32));

    // A closed or out-of-range fd is still badf — the rights check must not
    // shadow the identity check.
    try testing.expectEqual(p1.Errno.badf, fdRead(&h, &mem, 99, 0, 1, 32));
}

test "rights gate: fd_seek implies fd_tell, and only fd_seek moves the cursor" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [64]u8 = @splat(0);

    // FD_TELL alone: the offset-preserving form clears the gate (it reaches
    // the missing handle and reports badf); a real seek does not.
    const tell_only = try pushRightsOnlyFile(&h, p1.RIGHTS_FD_TELL);
    try testing.expectEqual(p1.Errno.badf, fdSeek(&h, &mem, tell_only, 0, @intFromEnum(p1.Whence.cur), 32));
    try testing.expectEqual(p1.Errno.notcapable, fdSeek(&h, &mem, tell_only, 1, @intFromEnum(p1.Whence.set), 32));

    // FD_SEEK alone: witx says it implies FD_TELL, so both forms clear.
    const seek_only = try pushRightsOnlyFile(&h, p1.RIGHTS_FD_SEEK);
    try testing.expectEqual(p1.Errno.badf, fdSeek(&h, &mem, seek_only, 0, @intFromEnum(p1.Whence.cur), 32));
    try testing.expectEqual(p1.Errno.success, fdTell(&h, &mem, seek_only, 32));

    // Neither bit: both forms are notcapable.
    const bare = try pushRightsOnlyFile(&h, 0);
    try testing.expectEqual(p1.Errno.notcapable, fdSeek(&h, &mem, bare, 0, @intFromEnum(p1.Whence.cur), 32));
    try testing.expectEqual(p1.Errno.notcapable, fdTell(&h, &mem, bare, 32));
}

test "rights gate: path_open's oflags each need their own right" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    @memcpy(mem[0..4], "file");

    // Drop PATH_CREATE_FILE: a plain open still works, OFLAGS_CREAT does not.
    h.fd_table.items[dirfd].rights_base = p1.RIGHTS_DIRECTORY_BASE & ~p1.RIGHTS_PATH_CREATE_FILE;
    try testing.expectEqual(p1.Errno.notcapable, pathOpen(&h, &mem, dirfd, 0, 0, 4, p1.OFLAGS_CREAT, 0, 0, 0, 32));

    // Restore it, create the file, then drop PATH_FILESTAT_SET_SIZE and watch
    // OFLAGS_TRUNC lose its right (official `truncation_rights`).
    h.fd_table.items[dirfd].rights_base = p1.RIGHTS_DIRECTORY_BASE;
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 4, p1.OFLAGS_CREAT, 0, 0, 0, 32));
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 4, p1.OFLAGS_TRUNC, 0, 0, 0, 32));
    h.fd_table.items[dirfd].rights_base = p1.RIGHTS_DIRECTORY_BASE & ~p1.RIGHTS_PATH_FILESTAT_SET_SIZE;
    try testing.expectEqual(p1.Errno.notcapable, pathOpen(&h, &mem, dirfd, 0, 0, 4, p1.OFLAGS_TRUNC, 0, 0, 0, 32));

    // And PATH_OPEN itself gates the call outright.
    h.fd_table.items[dirfd].rights_base = 0;
    try testing.expectEqual(p1.Errno.notcapable, pathOpen(&h, &mem, dirfd, 0, 0, 4, 0, 0, 0, 0, 32));
}

test "rights gate: a file under a component-opened subdirectory is still writable" {
    // The WASI 0.2/0.3 `open-at` trampolines have no rights model, so they ask
    // `path_open` for whatever `rightsForRightlessOpen` allows. If a directory
    // open narrowed the INHERITING ceiling as well as its own base, this write
    // would be `notcapable` — the fd under it would never have been granted
    // FD_WRITE in the first place.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");
    const root: std.Io.Dir = .{ .handle = tmp.dir.handle };
    try root.createDir(testing.io, "sub", std.Io.File.Permissions.default_dir);

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[0..3], "sub");
    const dr = p1.rightsForRightlessOpen(p1.OFLAGS_DIRECTORY);
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 3, p1.OFLAGS_DIRECTORY, dr.base, dr.inheriting, 0, 96));
    const subfd = std.mem.readInt(u32, mem[96..100], .little);

    @memset(mem[0..128], 0);
    @memcpy(mem[0..5], "f.txt");
    const fr = p1.rightsForRightlessOpen(p1.OFLAGS_CREAT);
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, subfd, 0, 0, 5, p1.OFLAGS_CREAT, fr.base, fr.inheriting, 0, 96));
    const ffd = std.mem.readInt(u32, mem[96..100], .little);

    @memcpy(mem[48..56], "hello fd");
    std.mem.writeInt(u32, mem[32..36], 48, .little);
    std.mem.writeInt(u32, mem[36..40], 8, .little);
    try testing.expectEqual(p1.Errno.success, fdWrite(&h, &mem, ffd, 32, 1, 104));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, mem[104..108], .little));
}

test "rights gate: the two ways to reach a directory hold the same capabilities" {
    // A preopen advertises RIGHTS_DIRECTORY_BASE; the component-model
    // `open-at` path has no rights model and asks through
    // `rightsForRightlessOpen`. If those disagree, the same directory answers
    // differently depending on which interface opened it — measured on
    // `fd_sync` / `fd_datasync` / `fd_fdstat_set_flags`, the three the type
    // dispatch lets through to a `.dir` slot.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");
    const root: std.Io.Dir = .{ .handle = tmp.dir.handle };
    try root.createDir(testing.io, "a", std.Io.File.Permissions.default_dir);
    try root.createDir(testing.io, "b", std.Io.File.Permissions.default_dir);

    var mem: [128]u8 = @splat(0);
    @memcpy(mem[0..1], "a");
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 1, p1.OFLAGS_DIRECTORY, p1.RIGHTS_DIRECTORY_BASE, p1.RIGHTS_DIRECTORY_INHERITING, 0, 96));
    const via_preopen = std.mem.readInt(u32, mem[96..100], .little);

    @memcpy(mem[0..1], "b");
    const rr = p1.rightsForRightlessOpen(p1.OFLAGS_DIRECTORY);
    try testing.expectEqual(p1.Errno.success, pathOpen(&h, &mem, dirfd, 0, 0, 1, p1.OFLAGS_DIRECTORY, rr.base, rr.inheriting, 0, 96));
    const via_open_at = std.mem.readInt(u32, mem[96..100], .little);

    try testing.expectEqual(h.translateFd(via_preopen).?.rights_base, h.translateFd(via_open_at).?.rights_base);
    try testing.expectEqual(fdSync(&h, via_preopen), fdSync(&h, via_open_at));
    try testing.expectEqual(fdDatasync(&h, via_preopen), fdDatasync(&h, via_open_at));
    try testing.expectEqual(fdFdstatSetFlags(&h, via_preopen, 0), fdFdstatSetFlags(&h, via_open_at, 0));
}
