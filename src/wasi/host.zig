//! WASI host capability table (Phase 4 / §9.4 / 4.2).
//!
//! Holds the pre-instantiation state a `wasi_snapshot_preview1`
//! module needs from its host: argv, environ, fd table (with
//! stdin / stdout / stderr pre-populated at index 0 / 1 / 2),
//! preopens. The §9.4 / 4.3+ syscall handlers consume this
//! struct; the §9.4 / 4.7 import-resolution wires it onto a
//! `Runtime`.
//!
//! No syscall behaviour lives here yet — `Host` is the typed
//! container only (per ROADMAP §P13). The std.process.Init
//! adapter (`Host.initFromProcess`) lands in §9.4 / 4.7
//! alongside the binding integration.
//!
//! Zone 2 (`src/wasi/`) — may import Zone 0 (`util/`) +
//! Zone 1 + Zone 2-self. MUST NOT import Zone 2-other
//! (`interp/`, `jit*/`) or Zone 3 (`c_api/`, `cli/`).

const std = @import("std");

const p1 = @import("preview1.zig");

const Allocator = std.mem.Allocator;

/// Classification of an entry in `Host.fd_table`. The 0/1/2
/// slots are always `.stdin` / `.stdout` / `.stderr`. `.file` /
/// `.dir` are populated when a guest opens or pre-opens a path.
/// `.closed` marks a freed slot — the table reuses indices
/// rather than shrinking.
pub const FdKind = enum(u8) {
    stdin,
    stdout,
    stderr,
    file,
    dir,
    closed,
};

/// One row of the host's fd table. Placeholder fields for the
/// underlying file handle / preopen path land alongside the
/// §9.4 / 4.4 (`fd_read` / `fd_write`) and §9.4 / 4.5
/// (`path_open`) handlers — this chunk wires the kind +
/// rights only.
pub const OpenFd = struct {
    kind: FdKind,
    rights_base: p1.Rights = 0,
    rights_inheriting: p1.Rights = 0,
    /// `fdstat.fs_flags` — the writable subset of the WASI
    /// snapshot-1 fd flags (FDFLAGS_APPEND / NONBLOCK / SYNC /
    /// DSYNC / RSYNC). Updated via `fd_fdstat_set_flags`; read
    /// out via `fd_fdstat_get`.
    fs_flags: p1.Fdflags = 0,
    /// Host-OS file handle for `.dir` (preopen-root) and
    /// `.file` (post-`path_open`) slots. Null for stdio
    /// kinds. The `.dir` flavour is set by `addPreopen`; the
    /// `.file` flavour is set by `pathOpen` (§9.4 / 4.5
    /// chunk b).
    host_handle: ?std.posix.fd_t = null,
    /// Logical sequential cursor for a `.file` slot, in bytes from the file
    /// start. `fd_read`/`fd_write` use positional IO at this offset and advance
    /// it (Zig 0.16 `std.Io.File` is positional-only — no OS-cursor seek);
    /// `fd_seek` sets it, `fd_tell` reads it. `fd_pread`/`fd_pwrite` take an
    /// explicit offset and do NOT touch it (WASI). One exception: while
    /// `fs_flags` carries FDFLAGS_APPEND, `fd_write` ignores this cursor as a
    /// destination and writes at end-of-file, then leaves the cursor there.
    pos: u64 = 0,

    /// True when this fd carries every bit in `needed`. A preview1 call is
    /// gated by the rights its witx doc comment names; an fd whose
    /// `fs_rights_base` is missing one owes the guest `notcapable`.
    pub fn has(self: *const OpenFd, needed: p1.Rights) bool {
        return self.rights_base & needed == needed;
    }
};

/// One environment-variable entry. Both `key` and `value` are
/// owned by the Host's allocator and freed in `deinit`.
pub const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// One preopen — a host-side directory the guest sees at
/// `guest_path`. The `host_fd` is a host-OS file descriptor
/// pointing at the directory; the §9.4 / 4.5 (`path_open`)
/// handler combines it with guest-supplied relative paths via
/// `openat` to enforce the no-`..`-escape rule. `guest_path`
/// is owned by the Host's allocator.
pub const PreopenEntry = struct {
    host_fd: std.posix.fd_t,
    guest_path: []const u8,
};

/// A preopen REQUEST queued by a config builder that has no io
/// token at config time (the C-API `zwasm_wasi_config_preopen_dir`,
/// ADR-0184). Both paths are owned by the Host's allocator.
/// `materializePendingPreopens` opens `host_path` via `Host.io` at
/// instantiation time and promotes the entry into `preopens`.
pub const PendingPreopen = struct {
    host_path: []const u8,
    guest_path: []const u8,
};

/// Default rights granted to inherited stdio fds. Mirrors the
/// witx `fdflags` defaults a `wasi-libc`-compiled guest expects
/// from a vanilla preopen-style stdin / stdout / stderr.
const STDIO_READ_RIGHTS: p1.Rights = p1.RIGHTS_FD_READ | p1.RIGHTS_POLL_FD_READWRITE;
const STDIO_WRITE_RIGHTS: p1.Rights = p1.RIGHTS_FD_WRITE | p1.RIGHTS_POLL_FD_READWRITE;

pub const Host = struct {
    alloc: Allocator,
    args: [][]const u8 = &.{},
    envs: []EnvEntry = &.{},
    preopens: []PreopenEntry = &.{},
    /// Preopen requests awaiting an io token (ADR-0184); drained
    /// by `materializePendingPreopens` at instantiation.
    pending_preopens: std.ArrayList(PendingPreopen) = .empty,
    /// Directory handles opened BY the Host (pending-preopen
    /// materialization). Closed at `deinit`; handles passed in
    /// via `addPreopen` stay caller-owned and are NOT closed.
    owned_preopen_fds: std.ArrayList(std.posix.fd_t) = .empty,
    fd_table: std.ArrayList(OpenFd) = .empty,
    /// Set by `proc_exit` (`src/wasi/proc.zig`) to the requested
    /// exit code; the dispatch surface checks this after each
    /// host-call to short-circuit further execution and surface
    /// the exit code through the binding's Trap path.
    exit_code: ?u32 = null,
    /// Optional capture buffers for fd 1 / fd 2 (`fd_write`).
    /// When non-null, `fd_write` appends to these instead of
    /// the real host stdio — tests use this to assert on
    /// guest-emitted output. The §9.4 / 4.8 `zwasm run` CLI
    /// wires real stdout / stderr at instantiation by leaving
    /// these null and setting `stdout_writer` / `stderr_writer`
    /// (forthcoming in 4.7/4.8).
    stdout_buffer: ?*std.ArrayList(u8) = null,
    stderr_buffer: ?*std.ArrayList(u8) = null,
    /// Allocator used to GROW the caller-owned `stdout_buffer` / `stderr_buffer`.
    /// When null the Host's own `alloc` is used. An embedder that owns the
    /// capture buffers (e.g. cljw `wasm/run`) sets this to the SAME allocator it
    /// will free / `toOwnedSlice` them with, so the buffer's grow-allocator and
    /// the caller's free-allocator agree (no cross-allocator invalid-free).
    capture_alloc: ?Allocator = null,
    /// Cap on how many bytes each capture buffer may accumulate. `null` =
    /// unbounded, which is what every caller got before this existed and what
    /// they still get by default.
    ///
    /// Capture buffers hold GUEST-CHOSEN volumes of data in HOST memory, and no
    /// other budget bounds them: fuel bounds instructions, and bytes-per-
    /// instruction is entirely the guest's choice. Measured from cljw
    /// (`wasm/run`, its D-349): a guest looping on a 64-byte `fd_write` buffered
    /// 64,000,000 bytes for 1,000,000 fuel — 64 bytes per unit — so under
    /// zwasm's own 1e9 default fuel the host would buffer ~64 GB before the fuel
    /// trap fired.
    ///
    /// The cap is PER BUFFER, so an embedder capping both stdout and stderr
    /// bounds itself at 2x this number.
    max_capture_bytes: ?u64 = null,
    /// Set once a capture buffer hit `max_capture_bytes`. The embedder reports
    /// it; zwasm does not decide what a truncated capture means to the caller.
    capture_truncated: bool = false,
    /// Optional source of bytes for `fd_read` over fd 0 (stdin).
    /// Tests set both; `stdin_pos` is mutated as the guest reads.
    stdin_bytes: ?[]const u8 = null,
    /// When `stdin_bytes` is null, serve the guest's fd 0 from the host
    /// process's own stdin, one `fd_read` at a time (#257). A byte slice
    /// would have to be read to EOF before the guest runs, which caps the
    /// input and blocks on a pipe that never closes; reading on demand has
    /// neither problem and lets a terminal work interactively. Needs `io`.
    stdin_inherit: bool = false,
    stdin_pos: usize = 0,
    /// `std.Io` value used for filesystem syscalls (`path_open`,
    /// future `fd_read` / `fd_write` over file fds). Set by the
    /// binding at instance setup (§9.4 / 4.7+) from the engine's
    /// io context; tests pass `std.testing.io`. When null, fs
    /// syscalls return `Errno.nosys`.
    io: ?std.Io = null,

    /// Construct a Host with stdio fds 0 / 1 / 2 pre-populated.
    /// Callers grow `args` / `envs` / `preopens` via the
    /// respective setters before consuming the table.
    pub fn init(alloc: Allocator) !Host {
        var h: Host = .{ .alloc = alloc };
        try h.fd_table.append(alloc, .{ .kind = .stdin, .rights_base = STDIO_READ_RIGHTS });
        try h.fd_table.append(alloc, .{ .kind = .stdout, .rights_base = STDIO_WRITE_RIGHTS });
        try h.fd_table.append(alloc, .{ .kind = .stderr, .rights_base = STDIO_WRITE_RIGHTS });
        return h;
    }

    pub fn deinit(self: *Host) void {
        for (self.args) |a| self.alloc.free(a);
        self.alloc.free(self.args);
        for (self.envs) |e| {
            self.alloc.free(e.key);
            self.alloc.free(e.value);
        }
        self.alloc.free(self.envs);
        for (self.preopens) |p| self.alloc.free(p.guest_path);
        self.alloc.free(self.preopens);
        for (self.pending_preopens.items) |p| {
            self.alloc.free(p.host_path);
            self.alloc.free(p.guest_path);
        }
        self.pending_preopens.deinit(self.alloc);
        // Host-opened preopen dirs need the io they were opened
        // with; it is always set when owned fds exist (materialize
        // requires it) unless the embedder cleared it afterwards.
        if (self.io) |io| {
            for (self.owned_preopen_fds.items) |fd| {
                const d: std.Io.Dir = .{ .handle = fd };
                d.close(io);
            }
        }
        self.owned_preopen_fds.deinit(self.alloc);
        self.fd_table.deinit(self.alloc);
    }

    /// Queue a preopen request for `materializePendingPreopens`
    /// (ADR-0184 — config builders without an io token). Copies
    /// both paths.
    pub fn addPendingPreopen(self: *Host, host_path: []const u8, guest_path: []const u8) !void {
        const host_copy = try self.alloc.dupe(u8, host_path);
        errdefer self.alloc.free(host_copy);
        const guest_copy = try self.alloc.dupe(u8, guest_path);
        errdefer self.alloc.free(guest_copy);
        try self.pending_preopens.append(self.alloc, .{
            .host_path = host_copy,
            .guest_path = guest_copy,
        });
    }

    /// Open every queued preopen request via `Host.io` and promote
    /// it into `preopens` (ADR-0184; instantiation-time so errors
    /// surface where wasm-c-api reports them). Promotion is
    /// per-entry: on failure the failing request (and any after
    /// it) stays pending and the error propagates — the caller
    /// fails instantiation. No-op when nothing is pending.
    pub fn materializePendingPreopens(self: *Host) !void {
        if (self.pending_preopens.items.len == 0) return;
        const io = self.io orelse return error.NoHostIo;
        while (self.pending_preopens.items.len > 0) {
            const entry = self.pending_preopens.items[0];
            const dir = try std.Io.Dir.cwd().openDir(io, entry.host_path, .{ .iterate = true });
            errdefer dir.close(io);
            try self.owned_preopen_fds.append(self.alloc, dir.handle);
            errdefer _ = self.owned_preopen_fds.pop();
            _ = try self.addPreopen(dir.handle, entry.guest_path);
            self.alloc.free(entry.host_path);
            self.alloc.free(entry.guest_path);
            _ = self.pending_preopens.orderedRemove(0);
        }
    }

    /// Replace the args slice with a deep copy of `src`. Existing
    /// args are released first so this is a "set" semantics, not
    /// an "append".
    pub fn setArgs(self: *Host, src: []const []const u8) !void {
        for (self.args) |a| self.alloc.free(a);
        self.alloc.free(self.args);
        const buf = try self.alloc.alloc([]const u8, src.len);
        errdefer self.alloc.free(buf);
        var copied: usize = 0;
        errdefer for (buf[0..copied]) |a| self.alloc.free(a);
        for (src, 0..) |s, i| {
            buf[i] = try self.alloc.dupe(u8, s);
            copied += 1;
        }
        self.args = buf;
    }

    /// Replace the envs slice. `keys` and `vals` must have the
    /// same length; pairs are stored independently so a future
    /// `environ_get` can write them in any order.
    pub fn setEnvs(self: *Host, keys: []const []const u8, vals: []const []const u8) !void {
        if (keys.len != vals.len) return error.EnvsKeyValueLengthMismatch;
        for (self.envs) |e| {
            self.alloc.free(e.key);
            self.alloc.free(e.value);
        }
        self.alloc.free(self.envs);
        const buf = try self.alloc.alloc(EnvEntry, keys.len);
        errdefer self.alloc.free(buf);
        var copied: usize = 0;
        errdefer for (buf[0..copied]) |e| {
            self.alloc.free(e.key);
            self.alloc.free(e.value);
        };
        for (keys, vals, 0..) |k, v, i| {
            const k_copy = try self.alloc.dupe(u8, k);
            errdefer self.alloc.free(k_copy);
            const v_copy = try self.alloc.dupe(u8, v);
            buf[i] = .{ .key = k_copy, .value = v_copy };
            copied += 1;
        }
        self.envs = buf;
    }

    /// Append a preopen and reserve an fd-table slot for it.
    /// Returns the guest fd (3, 4, …) the preopen now occupies;
    /// the corresponding `OpenFd.kind` is `.dir`.
    pub fn addPreopen(
        self: *Host,
        host_fd: std.posix.fd_t,
        guest_path: []const u8,
    ) !p1.Fd {
        const path_copy = try self.alloc.dupe(u8, guest_path);
        errdefer self.alloc.free(path_copy);
        const new_preopens = try self.alloc.realloc(self.preopens, self.preopens.len + 1);
        new_preopens[self.preopens.len] = .{ .host_fd = host_fd, .guest_path = path_copy };
        self.preopens = new_preopens;
        try self.fd_table.append(self.alloc, .{
            .kind = .dir,
            .rights_base = p1.RIGHTS_DIRECTORY_BASE,
            .rights_inheriting = p1.RIGHTS_DIRECTORY_INHERITING,
            .host_handle = host_fd,
        });
        return @intCast(self.fd_table.items.len - 1);
    }

    /// Resolve a guest fd to its `OpenFd` slot. Returns `null`
    /// for out-of-range fds; callers translate that to
    /// `Errno.badf`. Closed slots return a non-null pointer to
    /// a row whose `kind == .closed` — also a `badf` from the
    /// caller's perspective.
    pub fn translateFd(self: *Host, guest_fd: p1.Fd) ?*OpenFd {
        if (guest_fd >= self.fd_table.items.len) return null;
        return &self.fd_table.items[guest_fd];
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Host.init: stdio fds pre-populated at 0/1/2 with default rights" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    try testing.expectEqual(@as(usize, 3), h.fd_table.items.len);
    try testing.expectEqual(FdKind.stdin, h.fd_table.items[0].kind);
    try testing.expectEqual(FdKind.stdout, h.fd_table.items[1].kind);
    try testing.expectEqual(FdKind.stderr, h.fd_table.items[2].kind);
    // Stdio carries POLL_FD_READWRITE alongside its read/write right: a guest
    // that polls stdin/stdout/stderr is the ordinary case, not a privilege.
    try testing.expectEqual(p1.RIGHTS_FD_READ | p1.RIGHTS_POLL_FD_READWRITE, h.fd_table.items[0].rights_base);
    try testing.expectEqual(p1.RIGHTS_FD_WRITE | p1.RIGHTS_POLL_FD_READWRITE, h.fd_table.items[1].rights_base);
}

test "Host.translateFd: stdio resolves; out-of-range returns null" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    const slot = h.translateFd(1) orelse return error.MissingStdout;
    try testing.expectEqual(FdKind.stdout, slot.kind);
    try testing.expect(h.translateFd(99) == null);
}

test "Host.setArgs: deep-copies caller-supplied args" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    var src_buf: [3][]const u8 = .{ "zwasm", "run", "hello.wasm" };
    try h.setArgs(&src_buf);
    try testing.expectEqual(@as(usize, 3), h.args.len);
    try testing.expectEqualStrings("zwasm", h.args[0]);
    try testing.expectEqualStrings("hello.wasm", h.args[2]);
    // Mutating the source array doesn't leak into the host copy.
    src_buf[0] = "X";
    try testing.expectEqualStrings("zwasm", h.args[0]);
}

test "Host.setEnvs: paired keys + vals deep-copied" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    const keys: [2][]const u8 = .{ "PATH", "HOME" };
    const vals: [2][]const u8 = .{ "/usr/bin:/bin", "/root" };
    try h.setEnvs(&keys, &vals);
    try testing.expectEqual(@as(usize, 2), h.envs.len);
    try testing.expectEqualStrings("PATH", h.envs[0].key);
    try testing.expectEqualStrings("/root", h.envs[1].value);
}

test "Host.setEnvs: length mismatch errors out" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    const keys: [1][]const u8 = .{"A"};
    const vals: [2][]const u8 = .{ "1", "2" };
    try testing.expectError(error.EnvsKeyValueLengthMismatch, h.setEnvs(&keys, &vals));
}

test "Host.addPreopen: extends fd_table; new slot is .dir at fd 3" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    // host_fd is opaque to this layer (4.5 path_open
    // dereferences it). Use a typed-undefined sentinel — fd_t
    // is `c_int` on Mac / Linux but `HANDLE` (`*anyopaque`) on
    // Windows; `undefined` is the only literal that types
    // portably. The test never reads the value back.
    const fake_fd: std.posix.fd_t = undefined;
    const fd = try h.addPreopen(fake_fd, "/sandbox");
    try testing.expectEqual(@as(p1.Fd, 3), fd);
    try testing.expectEqual(@as(usize, 1), h.preopens.len);
    try testing.expectEqualStrings("/sandbox", h.preopens[0].guest_path);

    const slot = h.translateFd(fd) orelse return error.MissingPreopen;
    try testing.expectEqual(FdKind.dir, slot.kind);
    try testing.expect((slot.rights_base & p1.RIGHTS_PATH_OPEN) != 0);
}

test "Host.deinit: leak-clean after addPreopen + setArgs + setEnvs" {
    // testing.allocator is leak-detecting; this test fails the
    // run if any of the dupes leak.
    var h = try Host.init(testing.allocator);

    var args: [2][]const u8 = .{ "zwasm", "hello" };
    try h.setArgs(&args);
    const keys: [1][]const u8 = .{"K"};
    const vals: [1][]const u8 = .{"V"};
    try h.setEnvs(&keys, &vals);
    const fake_fd: std.posix.fd_t = undefined;
    _ = try h.addPreopen(fake_fd, "/p");

    h.deinit();
}

test "Host.addPendingPreopen + materializePendingPreopens: opens via io, promotes (ADR-0184)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = threaded.io();

    try h.addPendingPreopen(".", "/sandbox");
    try testing.expectEqual(@as(usize, 1), h.pending_preopens.items.len);
    try testing.expectEqual(@as(usize, 0), h.preopens.len);

    try h.materializePendingPreopens();
    try testing.expectEqual(@as(usize, 0), h.pending_preopens.items.len);
    try testing.expectEqual(@as(usize, 1), h.preopens.len);
    try testing.expectEqualStrings("/sandbox", h.preopens[0].guest_path);
    const slot = h.translateFd(3) orelse return error.MissingPreopen;
    try testing.expectEqual(FdKind.dir, slot.kind);
    // Idempotent once drained.
    try h.materializePendingPreopens();
    try testing.expectEqual(@as(usize, 1), h.preopens.len);
}

test "Host.materializePendingPreopens: pending without io errors" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    try h.addPendingPreopen(".", "/sandbox");
    try testing.expectError(error.NoHostIo, h.materializePendingPreopens());
}

test "Host.materializePendingPreopens: nonexistent path errors; failed entry stays pending" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = threaded.io();
    try h.addPendingPreopen("definitely/not/a/real/dir-zwasm", "/x");
    try testing.expectError(error.FileNotFound, h.materializePendingPreopens());
    try testing.expectEqual(@as(usize, 1), h.pending_preopens.items.len);
    try testing.expectEqual(@as(usize, 0), h.preopens.len);
}

test "Host.deinit: leak-clean with un-materialized pending preopens" {
    var h = try Host.init(testing.allocator);
    try h.addPendingPreopen("/tmp", "/t");
    try h.addPendingPreopen("/var", "/v");
    h.deinit();
}
