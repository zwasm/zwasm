//! WASI snapshot-1 type substrate (Phase 4 / §9.4 / 4.1).
//!
//! Declares the data shapes the `wasi_snapshot_preview1.*` host
//! functions consume / produce — types only, no behaviour. Per
//! ROADMAP §P13 (type up-front), the layouts here are fixed so
//! later tasks (4.3 args / environ / proc_exit, 4.4 fd_*, 4.5
//! path_open / fdstat, 4.6 clock / random / poll) can populate
//! handlers without redesigning the substrate.
//!
//! All numeric types are sized to match WASI's 32-bit Wasm-host
//! convention: `Size`, `Fd`, `Iovec.buf`, `Iovec.buf_len` are
//! u32 (Wasm pointers are 32-bit); `Filesize`, `Timestamp`,
//! `Rights` are u64. `Errno` is u16; `Fdflags` / `Oflags` /
//! `Fstflags` are u16 bit-flags; `Filetype` / `Whence` /
//! `Advice` are u8.
//!
//! Reference shapes (read, never copy): the `wasi-rs` bindings
//! (`crates/wasip1/src/lib_generated.rs`) and wasmtime's
//! `crates/wasi-common`. Spec source of truth:
//! `WebAssembly/WASI/legacy/preview1/witx/typenames.witx`.
//!
//! Zone 2 (`src/wasi/`) — may import Zone 0 (`util/`) and
//! Zone 1 (`ir/`, `runtime/`, …). MUST NOT import Zone 2-other
//! (`interp/`, `jit*/`) or Zone 3 (`c_api/`, `cli/`).

const std = @import("std");

// ============================================================
// Scalar aliases
// ============================================================

/// 32-bit Wasm-side `size_t` (Wasm pointers are 32-bit).
pub const Size = u32;

/// Number of bytes that fits in a file. WASI uses u64 to
/// support files larger than 4 GiB.
pub const Filesize = u64;

/// Nanoseconds since the Unix epoch (or another monotonic
/// reference, depending on `Clockid`).
pub const Timestamp = u64;

/// File descriptor — small unsigned integer that indexes into
/// the host's fd table. Stdin / stdout / stderr take 0 / 1 / 2;
/// preopens follow.
pub const Fd = u32;

/// Signed seek delta for `fd_seek`.
pub const Filedelta = i64;

/// Cookie used by `fd_readdir` to resume between dirents.
pub const Dircookie = u64;
pub const Dirnamlen = u32;
pub const Inode = u64;
pub const Device = u64;
pub const Linkcount = u64;
pub const Userdata = u64;

// ============================================================
// Errno — 16-bit error code
// ============================================================

/// WASI snapshot-1 errno values. Numeric values match
/// `WebAssembly/WASI/legacy/preview1/witx/typenames.witx` —
/// stable across all snapshot-1 implementations. Tagged
/// `non_exhaustive` because future WASI versions may add
/// codes; switch statements should `else => …` accordingly.
pub const Errno = enum(u16) {
    success = 0,
    @"2big" = 1,
    acces = 2,
    addrinuse = 3,
    addrnotavail = 4,
    afnosupport = 5,
    again = 6,
    already = 7,
    badf = 8,
    badmsg = 9,
    busy = 10,
    canceled = 11,
    child = 12,
    connaborted = 13,
    connrefused = 14,
    connreset = 15,
    deadlk = 16,
    destaddrreq = 17,
    dom = 18,
    dquot = 19,
    exist = 20,
    fault = 21,
    fbig = 22,
    hostunreach = 23,
    idrm = 24,
    ilseq = 25,
    inprogress = 26,
    intr = 27,
    inval = 28,
    io = 29,
    isconn = 30,
    isdir = 31,
    loop = 32,
    mfile = 33,
    mlink = 34,
    msgsize = 35,
    multihop = 36,
    nametoolong = 37,
    netdown = 38,
    netreset = 39,
    netunreach = 40,
    nfile = 41,
    nobufs = 42,
    nodev = 43,
    noent = 44,
    noexec = 45,
    nolck = 46,
    nolink = 47,
    nomem = 48,
    nomsg = 49,
    noprotoopt = 50,
    nospc = 51,
    nosys = 52,
    notconn = 53,
    notdir = 54,
    notempty = 55,
    notrecoverable = 56,
    notsock = 57,
    notsup = 58,
    notty = 59,
    nxio = 60,
    overflow = 61,
    ownerdead = 62,
    perm = 63,
    pipe = 64,
    proto = 65,
    protonosupport = 66,
    prototype = 67,
    range = 68,
    rofs = 69,
    spipe = 70,
    srch = 71,
    stale = 72,
    timedout = 73,
    txtbsy = 74,
    xdev = 75,
    notcapable = 76,
    _,
};

// ============================================================
// Filetype + Whence + Advice + Clockid + PreopenType
// ============================================================

pub const Filetype = enum(u8) {
    unknown = 0,
    block_device = 1,
    character_device = 2,
    directory = 3,
    regular_file = 4,
    socket_dgram = 5,
    socket_stream = 6,
    symbolic_link = 7,
    _,
};

pub const Whence = enum(u8) {
    set = 0,
    cur = 1,
    end = 2,
    _,
};

pub const Advice = enum(u8) {
    normal = 0,
    sequential = 1,
    random = 2,
    willneed = 3,
    dontneed = 4,
    noreuse = 5,
    _,
};

pub const Clockid = enum(u32) {
    realtime = 0,
    monotonic = 1,
    process_cputime_id = 2,
    thread_cputime_id = 3,
    _,
};

pub const PreopenType = enum(u8) {
    dir = 0,
    _,
};

pub const EventType = enum(u8) {
    clock = 0,
    fd_read = 1,
    fd_write = 2,
    _,
};

pub const Signal = enum(u8) {
    none = 0,
    hup = 1,
    int = 2,
    quit = 3,
    ill = 4,
    trap = 5,
    abrt = 6,
    bus = 7,
    fpe = 8,
    kill = 9,
    usr1 = 10,
    segv = 11,
    usr2 = 12,
    pipe = 13,
    alrm = 14,
    term = 15,
    _,
};

// ============================================================
// Bit-flag aliases
// ============================================================

/// File-descriptor flags (`O_APPEND` / `O_NONBLOCK` / etc.).
/// Bit values match the witx `fdflags` flagsdef.
pub const Fdflags = u16;
pub const FDFLAGS_APPEND: Fdflags = 0x0001;
pub const FDFLAGS_DSYNC: Fdflags = 0x0002;
pub const FDFLAGS_NONBLOCK: Fdflags = 0x0004;
pub const FDFLAGS_RSYNC: Fdflags = 0x0008;
pub const FDFLAGS_SYNC: Fdflags = 0x0010;

/// `path_open` open flags.
pub const Oflags = u16;
pub const OFLAGS_CREAT: Oflags = 0x0001;
pub const OFLAGS_DIRECTORY: Oflags = 0x0002;
pub const OFLAGS_EXCL: Oflags = 0x0004;
pub const OFLAGS_TRUNC: Oflags = 0x0008;

/// File-system rights — the capability bits a file descriptor carries.
/// The complete witx `$rights` flags record: 30 bits, in declaration
/// order, each `1 << <its documented Bit:>`. Every bit names the call it
/// gates; the `gate` comments below are the witx doc text, condensed.
/// Source: `WebAssembly/WASI` `preview1/witx/typenames.witx` (branch
/// `wasi-0.1`, fae981bae14809d91f9bc2d63852d461f331d161).
pub const Rights = u64;
pub const RIGHTS_FD_DATASYNC: Rights = 1 << 0; // fd_datasync
pub const RIGHTS_FD_READ: Rights = 1 << 1; // fd_read, sock_recv; fd_pread with FD_SEEK
pub const RIGHTS_FD_SEEK: Rights = 1 << 2; // fd_seek (implies FD_TELL)
pub const RIGHTS_FD_FDSTAT_SET_FLAGS: Rights = 1 << 3; // fd_fdstat_set_flags
pub const RIGHTS_FD_SYNC: Rights = 1 << 4; // fd_sync
pub const RIGHTS_FD_TELL: Rights = 1 << 5; // fd_tell, fd_seek(cur, 0)
pub const RIGHTS_FD_WRITE: Rights = 1 << 6; // fd_write, sock_send; fd_pwrite with FD_SEEK
pub const RIGHTS_FD_ADVISE: Rights = 1 << 7; // fd_advise
pub const RIGHTS_FD_ALLOCATE: Rights = 1 << 8; // fd_allocate
pub const RIGHTS_PATH_CREATE_DIRECTORY: Rights = 1 << 9; // path_create_directory
pub const RIGHTS_PATH_CREATE_FILE: Rights = 1 << 10; // path_open with OFLAGS_CREAT
pub const RIGHTS_PATH_LINK_SOURCE: Rights = 1 << 11; // path_link (source dir)
pub const RIGHTS_PATH_LINK_TARGET: Rights = 1 << 12; // path_link (target dir)
pub const RIGHTS_PATH_OPEN: Rights = 1 << 13; // path_open
pub const RIGHTS_FD_READDIR: Rights = 1 << 14; // fd_readdir
pub const RIGHTS_PATH_READLINK: Rights = 1 << 15; // path_readlink
pub const RIGHTS_PATH_RENAME_SOURCE: Rights = 1 << 16; // path_rename (source dir)
pub const RIGHTS_PATH_RENAME_TARGET: Rights = 1 << 17; // path_rename (target dir)
pub const RIGHTS_PATH_FILESTAT_GET: Rights = 1 << 18; // path_filestat_get
pub const RIGHTS_PATH_FILESTAT_SET_SIZE: Rights = 1 << 19; // path_open with OFLAGS_TRUNC
pub const RIGHTS_PATH_FILESTAT_SET_TIMES: Rights = 1 << 20; // path_filestat_set_times
pub const RIGHTS_FD_FILESTAT_GET: Rights = 1 << 21; // fd_filestat_get
pub const RIGHTS_FD_FILESTAT_SET_SIZE: Rights = 1 << 22; // fd_filestat_set_size
pub const RIGHTS_FD_FILESTAT_SET_TIMES: Rights = 1 << 23; // fd_filestat_set_times
pub const RIGHTS_PATH_SYMLINK: Rights = 1 << 24; // path_symlink
pub const RIGHTS_PATH_REMOVE_DIRECTORY: Rights = 1 << 25; // path_remove_directory
pub const RIGHTS_PATH_UNLINK_FILE: Rights = 1 << 26; // path_unlink_file
pub const RIGHTS_POLL_FD_READWRITE: Rights = 1 << 27; // poll_oneoff fd_read/fd_write
pub const RIGHTS_SOCK_SHUTDOWN: Rights = 1 << 28; // sock_shutdown
pub const RIGHTS_SOCK_ACCEPT: Rights = 1 << 29; // sock_accept

/// Every defined bit. Bit 30 and above are unassigned in preview1, so this
/// is also the mask that keeps a complement (`~x`) inside the schema.
pub const RIGHTS_ALL: Rights = (1 << 30) - 1;

/// The rights a preopened directory advertises in `fs_rights_base` — the
/// operations a guest may perform *through this fd itself*. Directory-scoped
/// only: no FD_READ / FD_WRITE / FD_SEEK, which apply to file contents.
pub const RIGHTS_DIRECTORY_BASE: Rights = RIGHTS_PATH_CREATE_DIRECTORY |
    RIGHTS_PATH_CREATE_FILE | RIGHTS_PATH_LINK_SOURCE | RIGHTS_PATH_LINK_TARGET |
    RIGHTS_PATH_OPEN | RIGHTS_FD_READDIR | RIGHTS_PATH_READLINK |
    RIGHTS_PATH_RENAME_SOURCE | RIGHTS_PATH_RENAME_TARGET | RIGHTS_PATH_FILESTAT_GET |
    RIGHTS_PATH_FILESTAT_SET_SIZE | RIGHTS_PATH_FILESTAT_SET_TIMES |
    RIGHTS_FD_FILESTAT_GET | RIGHTS_FD_FILESTAT_SET_TIMES | RIGHTS_PATH_SYMLINK |
    RIGHTS_PATH_REMOVE_DIRECTORY | RIGHTS_PATH_UNLINK_FILE;

/// The rights a preopened directory advertises in `fs_rights_inheriting` —
/// the ceiling on every fd derived from it. A filesystem preopen never hands
/// out socket capabilities, so it is every bit except the two `sock_*` ones.
pub const RIGHTS_DIRECTORY_INHERITING: Rights =
    RIGHTS_ALL & ~(RIGHTS_SOCK_SHUTDOWN | RIGHTS_SOCK_ACCEPT);

/// Rights that mean something on a DIRECTORY fd. `path_open` is allowed to
/// return fewer rights than requested when they "do not apply to the type of
/// file being opened" (witx `path_open`); seeking, writing and resizing name
/// file-content operations, so a directory fd never carries them.
pub const RIGHTS_DIRECTORY_APPLICABLE: Rights =
    RIGHTS_ALL & ~(RIGHTS_FD_SEEK | RIGHTS_FD_WRITE | RIGHTS_FD_FILESTAT_SET_SIZE);

/// The `(base, inheriting)` a caller with NO rights model should hand
/// `path_open` — the component-model `open-at` paths, where the preopen IS the
/// sandbox and WASI 0.2/0.3 has no rights concept at all.
///
/// `base` drops the file-content rights for a directory target, because
/// `path_open` answers `isdir` to a write right on one. `inheriting` is
/// **never** masked: `RIGHTS_DIRECTORY_APPLICABLE` is a rule about what THIS
/// fd may do, not about what it may hand down, and masking it would silently
/// strip FD_WRITE from every file later opened under the directory.
///
/// A FILE target is deliberately not filetype-masked, so its `fd_fdstat_get`
/// reports directory rights it can never use. Two reasons to leave it: the
/// fd-type dispatch answers `notdir` before any capability check, so the bits
/// are unreachable rather than merely unused; and wasmtime 47.0.3 reports the
/// same set on a regular file (measured: `0x3FFFFFBF`, everything but
/// `fd_write`). Masking them is a one-line change if that trade is re-taken.
///
/// The `FD_WRITE` in a file target's base also decides the HOST open mode, so
/// every file reached through `open-at` is opened read/write and a read-only
/// host file cannot be opened for reading at all. That is #254 — the fix is to
/// derive these from the caller's `descriptor-flags`, which P3 already decodes
/// one statement too late — and it predates this helper.
pub fn rightsForRightlessOpen(oflags: Oflags) struct { base: Rights, inheriting: Rights } {
    const dir_target = (oflags & OFLAGS_DIRECTORY) != 0;
    return .{
        .base = if (dir_target)
            RIGHTS_DIRECTORY_INHERITING & RIGHTS_DIRECTORY_APPLICABLE
        else
            RIGHTS_DIRECTORY_INHERITING,
        .inheriting = RIGHTS_DIRECTORY_INHERITING,
    };
}

/// `fd_filestat_set_times` / `path_filestat_set_times` flags.
pub const Fstflags = u16;
pub const FSTFLAGS_ATIM: Fstflags = 0x0001;
pub const FSTFLAGS_ATIM_NOW: Fstflags = 0x0002;
pub const FSTFLAGS_MTIM: Fstflags = 0x0004;
pub const FSTFLAGS_MTIM_NOW: Fstflags = 0x0008;

/// `path_open` lookup flags.
pub const Lookupflags = u32;
pub const LOOKUPFLAGS_SYMLINK_FOLLOW: Lookupflags = 0x0001;

// ============================================================
// Compound shapes (extern struct — Wasm-memory layout)
// ============================================================

/// `iovec` — a (buf, len) pair the guest passes to `fd_read`.
/// `buf` is a 32-bit Wasm pointer into linear memory. The host
/// dereferences it via `Runtime.memory[buf .. buf + buf_len]`.
pub const Iovec = extern struct {
    buf: u32,
    buf_len: Size,
};

/// `ciovec` — same shape as `Iovec` but const-pointer flavoured
/// for `fd_write`. Distinct type so the host can't accidentally
/// store into a guest's read-only buffer view.
pub const Ciovec = extern struct {
    buf: u32,
    buf_len: Size,
};

/// `fdstat` — what `fd_fdstat_get` writes back. 24 bytes:
/// 1 + 1(pad) + 2(flags) + 4(pad) + 8(rights) + 8(rights inh).
pub const Fdstat = extern struct {
    fs_filetype: Filetype,
    _pad0: u8 = 0,
    fs_flags: Fdflags,
    _pad1: u32 = 0,
    fs_rights_base: Rights,
    fs_rights_inheriting: Rights,
};

/// `filestat` — what `fd_filestat_get` / `path_filestat_get`
/// write back. 64 bytes total.
pub const Filestat = extern struct {
    dev: Device,
    ino: Inode,
    filetype: Filetype,
    _pad: [7]u8 = .{0} ** 7,
    nlink: Linkcount,
    size: Filesize,
    atim: Timestamp,
    mtim: Timestamp,
    ctim: Timestamp,
};

/// `prestat` — `fd_prestat_get` writes this for each preopen
/// fd; tagged on `pr_type` and (for dir) carries the guest-
/// path length. The follow-up `fd_prestat_dir_name` then reads
/// the name itself. Size: 1 + 3 pad + 4 = 8 bytes.
pub const Prestat = extern struct {
    pr_type: PreopenType,
    _pad: [3]u8 = .{0} ** 3,
    pr_name_len: Size,
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Iovec / Ciovec are 8 bytes (u32 buf + u32 len)" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Iovec));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Ciovec));
}

test "Errno: spec-conformant values for the load-bearing tags" {
    try testing.expectEqual(@as(u16, 0), @intFromEnum(Errno.success));
    try testing.expectEqual(@as(u16, 8), @intFromEnum(Errno.badf));
    try testing.expectEqual(@as(u16, 28), @intFromEnum(Errno.inval));
    try testing.expectEqual(@as(u16, 44), @intFromEnum(Errno.noent));
    try testing.expectEqual(@as(u16, 52), @intFromEnum(Errno.nosys));
    try testing.expectEqual(@as(u16, 54), @intFromEnum(Errno.notdir));
    try testing.expectEqual(@as(u16, 76), @intFromEnum(Errno.notcapable));
}

test "Filetype: spec values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Filetype.unknown));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Filetype.directory));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Filetype.regular_file));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(Filetype.symbolic_link));
}

test "Whence: spec values + Clockid: spec values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Whence.set));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Whence.cur));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Whence.end));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(Clockid.realtime));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(Clockid.monotonic));
}

test "Fdflags / Oflags / Rights: spec bit values" {
    try testing.expectEqual(@as(Fdflags, 0x0001), FDFLAGS_APPEND);
    try testing.expectEqual(@as(Fdflags, 0x0004), FDFLAGS_NONBLOCK);
    try testing.expectEqual(@as(Oflags, 0x0001), OFLAGS_CREAT);
    try testing.expectEqual(@as(Oflags, 0x0008), OFLAGS_TRUNC);
    try testing.expectEqual(@as(Rights, 0x0000000000000002), RIGHTS_FD_READ);
    try testing.expectEqual(@as(Rights, 0x0000000000000040), RIGHTS_FD_WRITE);
}

test "Fdstat: 24-byte layout per witx" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(Fdstat));
    const fs: Fdstat = .{
        .fs_filetype = .regular_file,
        .fs_flags = FDFLAGS_APPEND,
        .fs_rights_base = RIGHTS_FD_READ | RIGHTS_FD_WRITE,
        .fs_rights_inheriting = 0,
    };
    try testing.expectEqual(Filetype.regular_file, fs.fs_filetype);
    try testing.expectEqual(@as(Fdflags, 0x0001), fs.fs_flags);
}

test "Filestat: 64-byte layout per witx" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Filestat));
}

test "Prestat: 8-byte tag + name-len shape" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Prestat));
    const ps: Prestat = .{ .pr_type = .dir, .pr_name_len = 5 };
    try testing.expectEqual(@as(Size, 5), ps.pr_name_len);
}

test "Scalar aliases: width matches WASI 32-bit Wasm convention" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Size));
    try testing.expectEqual(@as(usize, 4), @sizeOf(Fd));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Filesize));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Timestamp));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Rights));
}

test "Rights: each flag is 1 << its witx Bit index, in declaration order" {
    // `preview1/docs.md` renders a `Bit: N` for every flag; witx assigns them
    // in declaration order from 0. Listing them here in that order makes a
    // transposed pair a compile-visible off-by-one rather than a guest that
    // silently loses a capability.
    const in_order = [_]Rights{
        RIGHTS_FD_DATASYNC,             RIGHTS_FD_READ,
        RIGHTS_FD_SEEK,                 RIGHTS_FD_FDSTAT_SET_FLAGS,
        RIGHTS_FD_SYNC,                 RIGHTS_FD_TELL,
        RIGHTS_FD_WRITE,                RIGHTS_FD_ADVISE,
        RIGHTS_FD_ALLOCATE,             RIGHTS_PATH_CREATE_DIRECTORY,
        RIGHTS_PATH_CREATE_FILE,        RIGHTS_PATH_LINK_SOURCE,
        RIGHTS_PATH_LINK_TARGET,        RIGHTS_PATH_OPEN,
        RIGHTS_FD_READDIR,              RIGHTS_PATH_READLINK,
        RIGHTS_PATH_RENAME_SOURCE,      RIGHTS_PATH_RENAME_TARGET,
        RIGHTS_PATH_FILESTAT_GET,       RIGHTS_PATH_FILESTAT_SET_SIZE,
        RIGHTS_PATH_FILESTAT_SET_TIMES, RIGHTS_FD_FILESTAT_GET,
        RIGHTS_FD_FILESTAT_SET_SIZE,    RIGHTS_FD_FILESTAT_SET_TIMES,
        RIGHTS_PATH_SYMLINK,            RIGHTS_PATH_REMOVE_DIRECTORY,
        RIGHTS_PATH_UNLINK_FILE,        RIGHTS_POLL_FD_READWRITE,
        RIGHTS_SOCK_SHUTDOWN,           RIGHTS_SOCK_ACCEPT,
    };
    try testing.expectEqual(@as(usize, 30), in_order.len);
    for (in_order, 0..) |bit, i| try testing.expectEqual(@as(Rights, 1) << @intCast(i), bit);
    var union_of: Rights = 0;
    for (in_order) |bit| union_of |= bit;
    try testing.expectEqual(RIGHTS_ALL, union_of);
}

test "Rights: a preopen advertises every right path_open_preopen demands" {
    // `directory_base_rights()` in the official corpus, verbatim. The comment
    // there calls it "more brittle than we wanted to test for" — userland
    // expects this set on ANY directory, so a missing bit is a guest that
    // gives up before it calls anything.
    const required_base = RIGHTS_PATH_CREATE_DIRECTORY | RIGHTS_PATH_CREATE_FILE |
        RIGHTS_PATH_LINK_SOURCE | RIGHTS_PATH_LINK_TARGET | RIGHTS_PATH_OPEN |
        RIGHTS_FD_READDIR | RIGHTS_PATH_READLINK | RIGHTS_PATH_RENAME_SOURCE |
        RIGHTS_PATH_RENAME_TARGET | RIGHTS_PATH_SYMLINK | RIGHTS_PATH_REMOVE_DIRECTORY |
        RIGHTS_PATH_UNLINK_FILE | RIGHTS_PATH_FILESTAT_GET | RIGHTS_PATH_FILESTAT_SET_TIMES |
        RIGHTS_FD_FILESTAT_GET | RIGHTS_FD_FILESTAT_SET_TIMES;
    try testing.expectEqual(required_base, RIGHTS_DIRECTORY_BASE & required_base);

    // `directory_inheriting_rights()` = the base set plus the file rights.
    const required_inheriting = required_base | RIGHTS_FD_DATASYNC | RIGHTS_FD_READ |
        RIGHTS_FD_SEEK | RIGHTS_FD_FDSTAT_SET_FLAGS | RIGHTS_FD_SYNC | RIGHTS_FD_TELL |
        RIGHTS_FD_WRITE | RIGHTS_FD_ADVISE | RIGHTS_FD_ALLOCATE | RIGHTS_FD_FILESTAT_GET |
        RIGHTS_FD_FILESTAT_SET_SIZE | RIGHTS_FD_FILESTAT_SET_TIMES | RIGHTS_POLL_FD_READWRITE;
    try testing.expectEqual(required_inheriting, RIGHTS_DIRECTORY_INHERITING & required_inheriting);

    // A directory fd carries no file-content rights of its own, and a
    // filesystem preopen hands out no socket capabilities.
    try testing.expectEqual(@as(Rights, 0), RIGHTS_DIRECTORY_BASE &
        (RIGHTS_FD_READ | RIGHTS_FD_WRITE | RIGHTS_FD_SEEK));
    try testing.expectEqual(@as(Rights, 0), RIGHTS_DIRECTORY_INHERITING &
        (RIGHTS_SOCK_SHUTDOWN | RIGHTS_SOCK_ACCEPT));

    // `truncation_rights` reaches its real assertions only if the preopen can
    // hand PATH_FILESTAT_SET_SIZE down; without it the test skips its body.
    try testing.expect(RIGHTS_DIRECTORY_BASE & RIGHTS_PATH_FILESTAT_SET_SIZE != 0);
    try testing.expect(RIGHTS_DIRECTORY_INHERITING & RIGHTS_PATH_FILESTAT_SET_SIZE != 0);
}

test "rightsForRightlessOpen: the filetype mask never reaches the inheriting ceiling" {
    // A directory target drops the file-content rights from `base`, because
    // `path_open` answers `isdir` to a write right on a directory.
    const dir = rightsForRightlessOpen(OFLAGS_DIRECTORY);
    try testing.expectEqual(@as(Rights, 0), dir.base & RIGHTS_FD_WRITE);
    try testing.expectEqual(@as(Rights, 0), dir.base & RIGHTS_FD_SEEK);

    // But NOT from `inheriting`. Masking that records a ceiling without
    // FD_WRITE, and every file later opened under the directory then has its
    // own base clamped to match — a component that opens a subdirectory and
    // writes a file inside it gets `notcapable`.
    try testing.expectEqual(RIGHTS_DIRECTORY_INHERITING, dir.inheriting);
    try testing.expect(dir.inheriting & RIGHTS_FD_WRITE != 0);
    try testing.expect(dir.inheriting & RIGHTS_FD_SEEK != 0);

    // A file target is asked for the whole ceiling on both.
    const file = rightsForRightlessOpen(0);
    try testing.expectEqual(RIGHTS_DIRECTORY_INHERITING, file.base);
    try testing.expectEqual(RIGHTS_DIRECTORY_INHERITING, file.inheriting);
}

test "Rights: DIRECTORY_APPLICABLE drops exactly the file-content rights" {
    try testing.expectEqual(
        RIGHTS_FD_SEEK | RIGHTS_FD_WRITE | RIGHTS_FD_FILESTAT_SET_SIZE,
        RIGHTS_ALL & ~RIGHTS_DIRECTORY_APPLICABLE,
    );
}
