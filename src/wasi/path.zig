//! WASI 0.1 `path_*` handlers (D-278): filesystem operations relative to a
//! preopen `.dir` fd. Each resolves the dirfd + bounds-checks the guest path
//! + rejects `..`-escape (the WASI sandbox contract, mirroring `fd.zig`'s
//! `pathOpen` front-half), then delegates to the cross-platform `std.Io.Dir`
//! API (NOT `std.posix.*` — those hardcode POSIX `c_int` fds and break Win64;
//! see lesson windowsmini-reconciliation).
//!
//! Zone 2 (`src/wasi/`) — siblings: p1.zig / host.zig / fd.zig / clocks.zig.

const std = @import("std");
const builtin = @import("builtin");

const p1 = @import("preview1.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

// ============================================================
// Shared resolution + error mapping
// ============================================================

fn sliceMemConst(mem: []const u8, ptr: u32, len: u32) ?[]const u8 {
    const end = @as(usize, ptr) + @as(usize, len);
    if (end > mem.len) return null;
    return mem[ptr..end];
}

/// Reject a guest path that would leave the preopen it is resolved against.
///
/// preview1 confines every path to its preopen, but `..` is not itself the
/// violation: a path that dips through `..` and comes back stays inside and
/// must resolve. Only an absolute path, or one whose `..` segments ascend PAST
/// the root, escapes.
///
/// This is a CHECK, not a rewrite. The path reaches the host exactly as the
/// guest wrote it, so `.`, `..` and trailing separators keep their POSIX
/// meaning — `f/.` and `f/..` on a regular file stay `notdir`, which a folded
/// path would silently turn into a successful open of `f`.
///
/// The walk is lexical, so it cannot see a symlink component that redirects
/// the real resolution; that is the follow-time confinement D-315 tracks, and
/// it is unchanged by this.
pub fn confine(path: []const u8) p1.Errno {
    if (path.len == 0) return .noent;
    if (path[0] == '/') return .notcapable;
    // An interior NUL would be truncated by the host's C path conversion, so
    // the guest would silently open a DIFFERENT path than the one it named.
    if (std.mem.findScalar(u8, path, 0) != null) return .inval;

    var depth: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return .notcapable; // ascends above the preopen root
            depth -= 1;
            continue;
        }
        depth += 1;
    }
    return .success;
}

/// A symlink TARGET escapes the preopen root if, resolved relative to the
/// directory that holds the link, it would ascend above the root (or is
/// absolute). This is the PLANT-time half of cap-std-style confinement: it
/// stops a guest from CREATING, through zwasm's own API, a symlink that points
/// outside the sandbox — the primary "plant then read through it" escalation.
/// `link_sub` is the link's path relative to the preopen root, as the guest
/// wrote it — `confine` has passed it, so it is relative and stays inside, but
/// it may still carry `.` and `..`, which the depth walk below folds.
///
/// Following a PRE-EXISTING on-disk symlink that escapes is the separate
/// follow-time confinement (RESOLVE_BENEATH / component walk) tracked by D-315;
/// this lexical check is sound and matches the WASI host policy for creation.
fn symlinkTargetEscapes(link_sub: []const u8, target: []const u8) bool {
    if (target.len > 0 and target[0] == '/') return true; // absolute target
    // Depth of the directory containing the link, relative to the preopen root.
    var depth: usize = 0;
    var lit = std.mem.tokenizeScalar(u8, link_sub, '/');
    while (lit.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        depth += 1;
    }
    if (depth > 0) depth -= 1; // drop the link's own final component
    var tit = std.mem.tokenizeScalar(u8, target, '/');
    while (tit.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return true; // would ascend above the preopen root
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    return false;
}

const Resolved = struct { dir: std.Io.Dir, sub: []const u8 };

/// Resolve `(dirfd, path_ptr, path_len)` to a host `Dir` + bounded guest path,
/// and check that `needed` — the right the witx doc comment names for the
/// calling operation — is present in the dirfd's `fs_rights_base`. Returns the
/// errno on failure (`.success` when `out` is populated).
fn resolve(host: *Host, mem: []const u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32, needed: p1.Rights, out: *Resolved) p1.Errno {
    const path = sliceMemConst(mem, path_ptr, path_len) orelse return .fault;
    // POSIX: the empty path resolves to nothing (ENOENT). Guarded here because
    // std.Io panics on the resulting EINVAL in debug builds ("programmer bug").
    if (path.len == 0) return .noent;
    const ce = confine(path);
    if (ce != .success) return ce;
    const slot = host.translateFd(dirfd) orelse return .badf;
    if (slot.kind != .dir) return .notdir;
    if (!slot.has(needed)) return .notcapable;
    const handle = slot.host_handle orelse return .notdir;
    out.* = .{ .dir = .{ .handle = handle }, .sub = path };
    return .success;
}

/// Map a `std.Io.Dir`/`File` filesystem error to a WASI errno. The arms cover
/// the union of the create/delete/rename/link/readlink/stat error sets.
fn mapDirErr(err: anyerror) p1.Errno {
    return switch (err) {
        error.FileNotFound => .noent,
        // NT invalid object names ("" / reserved chars) have no WASI errno of
        // their own; POSIX would have said ENOENT.
        error.BadPathName => .noent,
        error.PathAlreadyExists => .exist,
        error.AccessDenied, error.PermissionDenied => .acces,
        error.NotDir => .notdir,
        error.IsDir => .isdir,
        error.DirNotEmpty => .notempty,
        error.SymLinkLoop => .loop,
        error.NotLink => .inval,
        error.NameTooLong => .nametoolong,
        error.NoSpaceLeft => .nospc,
        error.ReadOnlyFileSystem => .rofs,
        error.FileBusy => .busy,
        error.RenameAcrossMountPoints => .xdev,
        else => .io,
    };
}

// ============================================================
// path_create_directory / path_remove_directory
// ============================================================

/// `path_create_directory(dirfd, path) → errno` — create a directory relative
/// to the preopen `dirfd` (`std.Io.Dir.createDir`).
pub fn pathCreateDirectory(host: *Host, mem: []const u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, p1.RIGHTS_PATH_CREATE_DIRECTORY, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    r.dir.createDir(io, r.sub, std.Io.File.Permissions.default_dir) catch |err| return mapDirErr(err);
    return .success;
}

/// `path_remove_directory(dirfd, path) → errno` — remove an empty directory
/// relative to `dirfd` (`std.Io.Dir.deleteDir`; non-empty → `notempty`).
pub fn pathRemoveDirectory(host: *Host, mem: []const u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, p1.RIGHTS_PATH_REMOVE_DIRECTORY, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    // rmdir(".") is EINVAL per POSIX; guarded because std.Io panics on the
    // unexpected EINVAL in debug builds.
    if (std.mem.eql(u8, r.sub, ".") or std.mem.eql(u8, r.sub, "./")) return .inval;
    r.dir.deleteDir(io, r.sub) catch |err| return mapDirErr(err);
    return .success;
}

// ============================================================
// path_rename / path_link
// ============================================================

/// `path_rename(old_dirfd, old_path, new_dirfd, new_path) → errno` — rename
/// (move) a path across two preopen dirfds (`std.Io.Dir.rename`). Both ends are
/// resolved + escape-guarded.
pub fn pathRename(host: *Host, mem: []const u8, old_dirfd: p1.Fd, old_ptr: u32, old_len: u32, new_dirfd: p1.Fd, new_ptr: u32, new_len: u32) p1.Errno {
    var ro: Resolved = undefined;
    const e1 = resolve(host, mem, old_dirfd, old_ptr, old_len, p1.RIGHTS_PATH_RENAME_SOURCE, &ro);
    if (e1 != .success) return e1;
    var rn: Resolved = undefined;
    const e2 = resolve(host, mem, new_dirfd, new_ptr, new_len, p1.RIGHTS_PATH_RENAME_TARGET, &rn);
    if (e2 != .success) return e2;
    const io = host.io orelse return .nosys;
    // rename involving "." is EINVAL/EBUSY per POSIX; guarded because std.Io
    // panics on the unexpected EINVAL in debug builds.
    if (std.mem.eql(u8, ro.sub, ".") or std.mem.eql(u8, ro.sub, "./") or
        std.mem.eql(u8, rn.sub, ".") or std.mem.eql(u8, rn.sub, "./")) return .inval;
    ro.dir.rename(ro.sub, rn.dir, rn.sub, io) catch |err| return mapDirErr(err);
    return .success;
}

/// `path_link(old_dirfd, old_flags, old_path, new_dirfd, new_path) → errno` —
/// create a hard link at `new_path` to the existing `old_path`
/// (`std.Io.Dir.hardLink`). `old_flags` bit 0 = follow-symlinks.
pub fn pathLink(host: *Host, mem: []const u8, old_dirfd: p1.Fd, old_flags: u32, old_ptr: u32, old_len: u32, new_dirfd: p1.Fd, new_ptr: u32, new_len: u32) p1.Errno {
    var ro: Resolved = undefined;
    const e1 = resolve(host, mem, old_dirfd, old_ptr, old_len, p1.RIGHTS_PATH_LINK_SOURCE, &ro);
    if (e1 != .success) return e1;
    var rn: Resolved = undefined;
    const e2 = resolve(host, mem, new_dirfd, new_ptr, new_len, p1.RIGHTS_PATH_LINK_TARGET, &rn);
    if (e2 != .success) return e2;
    const io = host.io orelse return .nosys;
    const follow = old_flags & p1.LOOKUPFLAGS_SYMLINK_FOLLOW != 0;
    if (builtin.os.tag == .windows) return winPathLink(ro.dir, ro.sub, rn.dir, rn.sub, follow);
    ro.dir.hardLink(ro.sub, rn.dir, rn.sub, io, .{
        .follow_symlinks = follow,
    }) catch |err| return mapDirErr(err);
    return .success;
}

/// Windows `linkat`: the pinned stdlib's `dirHardLink` is a blanket
/// `OperationUnsupported` on windows, so the NT primitive is composed
/// directly — open the source relative to its directory handle
/// (NON_DIRECTORY_FILE: hardlinking a directory must fail acces per the
/// filesystem WIT, matching what CreateHardLinkW itself reports) and issue
/// FILE_LINK_INFORMATION (class `.Link`) targeting the destination
/// directory handle.
fn winPathLink(old_dir: std.Io.Dir, old_sub: []const u8, new_dir: std.Io.Dir, new_sub: []const u8, follow: bool) p1.Errno {
    const w = std.os.windows;
    const T = std.Io.Threaded;
    // NT resolves "." relative to a handle as an invalid object name, not as
    // the directory itself — pre-map it to the directory-source contract.
    if (std.mem.eql(u8, old_sub, ".")) return .acces;
    const old_ws = T.sliceToPrefixedFileW(old_dir.handle, old_sub, .{}) catch return .noent;
    const old_span = old_ws.span();
    const old_root = if (std.Io.Dir.path.isAbsoluteWindowsWtf16(old_span)) null else old_dir.handle;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var src: w.HANDLE = undefined;
    switch (w.ntdll.NtCreateFile(
        &src,
        .{ .STANDARD = .{ .SYNCHRONIZE = true } },
        &.{ .RootDirectory = old_root, .ObjectName = @constCast(&w.UNICODE_STRING.init(old_span)) },
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .IO = .SYNCHRONOUS_NONALERT, .NON_DIRECTORY_FILE = true, .OPEN_REPARSE_POINT = !follow },
        null,
        0,
    )) {
        .SUCCESS => {},
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return .noent,
        .OBJECT_NAME_INVALID => return .noent,
        .FILE_IS_A_DIRECTORY => return .acces,
        .ACCESS_DENIED => return .acces,
        else => return .io,
    }
    defer w.CloseHandle(src);
    const new_ws = T.sliceToPrefixedFileW(new_dir.handle, new_sub, .{}) catch return .noent;
    const new_span = new_ws.span();
    const new_root = if (std.Io.Dir.path.isAbsoluteWindowsWtf16(new_span)) null else new_dir.handle;
    // POSIX linkat: an existing destination is EEXIST, unconditionally. NT's
    // FILE_LINK_INFORMATION with ReplaceIfExists=FALSE silently SUCCEEDS when
    // the destination resolves to the linked file itself (link-to-self), so
    // existence is probed up front.
    {
        var probe_iosb: w.IO_STATUS_BLOCK = undefined;
        var probe: w.HANDLE = undefined;
        switch (w.ntdll.NtCreateFile(
            &probe,
            .{ .STANDARD = .{ .SYNCHRONIZE = true } },
            &.{ .RootDirectory = new_root, .ObjectName = @constCast(&w.UNICODE_STRING.init(new_span)) },
            &probe_iosb,
            null,
            .{ .NORMAL = true },
            .VALID_FLAGS,
            .OPEN,
            .{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
            null,
            0,
        )) {
            .SUCCESS => {
                w.CloseHandle(probe);
                return .exist;
            },
            else => {},
        }
    }
    // FILE_LINK_INFORMATION is a variable-length record: fixed header +
    // inline UTF-16 FileName. The FileName field must sit at ITS declared
    // offset (20 on x64 — right after FileNameLength), NOT at the
    // padded-to-8 @sizeOf of a header-only struct: NT reads FileNameLength
    // bytes from the field offset, so a misplace silently creates a
    // garbage-prefixed link name.
    const LinkInfo = extern struct {
        ReplaceIfExists: w.BOOLEAN,
        RootDirectory: ?w.HANDLE,
        FileNameLength: w.ULONG,
        FileName: [1]w.WCHAR,
    };
    const name_off = @offsetOf(LinkInfo, "FileName");
    var buf: [name_off + @sizeOf(T.WindowsPathSpace)]u8 align(@alignOf(LinkInfo)) = undefined;
    const name_bytes = std.mem.sliceAsBytes(new_span);
    const info: *LinkInfo = @ptrCast(&buf);
    info.ReplaceIfExists = .FALSE;
    info.RootDirectory = new_root;
    info.FileNameLength = @intCast(name_bytes.len);
    @memcpy(buf[name_off..][0..name_bytes.len], name_bytes);
    var iosb2: w.IO_STATUS_BLOCK = undefined;
    return switch (w.ntdll.NtSetInformationFile(
        src,
        &iosb2,
        &buf,
        @intCast(name_off + name_bytes.len),
        .Link,
    )) {
        .SUCCESS => .success,
        .OBJECT_NAME_COLLISION => .exist,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => .noent,
        .OBJECT_NAME_INVALID => .noent,
        .ACCESS_DENIED => .acces,
        .NOT_SAME_DEVICE => .xdev,
        else => .io,
    };
}

// ============================================================
// path_symlink / path_readlink
// ============================================================

/// `path_symlink(target, target_len, dirfd, link_path, link_path_len) → errno`
/// — create a symlink at `link_path` (relative to `dirfd`, escape-guarded)
/// whose contents are `target`. The target is escape-checked against the
/// preopen root (`symlinkTargetEscapes`): a guest cannot plant a symlink that
/// points outside the sandbox (`notcapable`).
pub fn pathSymlink(host: *Host, mem: []const u8, target_ptr: u32, target_len: u32, dirfd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    const target = sliceMemConst(mem, target_ptr, target_len) orelse return .fault;
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, p1.RIGHTS_PATH_SYMLINK, &r);
    if (e != .success) return e;
    if (symlinkTargetEscapes(r.sub, target)) return .notcapable;
    const io = host.io orelse return .nosys;
    r.dir.symLink(io, target, r.sub, .{}) catch |err| return mapDirErr(err);
    return .success;
}

/// `path_readlink(dirfd, path, buf, buf_len, *bufused_out) → errno` — read the
/// symlink at `path` into the guest buffer (`std.Io.Dir.readLink`), writing the
/// byte count to `bufused`. A non-symlink path → `inval` (NotLink).
pub fn pathReadlink(host: *Host, mem: []u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32, buf_ptr: u32, buf_len: u32, bufused_ptr: u32) p1.Errno {
    if (@as(usize, bufused_ptr) + 4 > mem.len) return .fault;
    const buf = blk: {
        const end = @as(usize, buf_ptr) + @as(usize, buf_len);
        if (end > mem.len) return .fault;
        break :blk mem[buf_ptr..end];
    };
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, p1.RIGHTS_PATH_READLINK, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    const n = r.dir.readLink(io, r.sub, buf) catch |err| return mapDirErr(err);
    std.mem.writeInt(u32, mem[bufused_ptr..][0..4], @intCast(n), .little);
    return .success;
}

// ============================================================
// path_filestat_get / path_filestat_set_times
// ============================================================

fn filetypeFromKind(kind: std.Io.File.Kind) p1.Filetype {
    return switch (kind) {
        .file => .regular_file,
        .directory => .directory,
        .sym_link => .symbolic_link,
        .block_device => .block_device,
        .character_device => .character_device,
        .named_pipe, .unix_domain_socket, .whiteout, .door, .event_port, .unknown => .unknown,
    };
}

fn setTimestampOf(flags: p1.Fstflags, now_bit: p1.Fstflags, set_bit: p1.Fstflags, ns: u64) std.Io.File.SetTimestamp {
    if (flags & now_bit != 0) return .now;
    if (flags & set_bit != 0) return .{ .new = std.Io.Timestamp.fromNanoseconds(@intCast(ns)) };
    return .unchanged;
}

/// `path_filestat_get(dirfd, lookupflags, path, *filestat_out) → errno` — stat
/// a path relative to `dirfd` (`std.Io.Dir.statFile`) and write the 64-byte
/// `Filestat`. `lookupflags` bit 0 = follow-symlinks.
pub fn pathFilestatGet(host: *Host, mem: []u8, dirfd: p1.Fd, lookupflags: u32, path_ptr: u32, path_len: u32, filestat_ptr: u32) p1.Errno {
    const dst = blk: {
        const end = @as(usize, filestat_ptr) + @sizeOf(p1.Filestat);
        if (end > mem.len) return .fault;
        break :blk mem[filestat_ptr..end];
    };
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, p1.RIGHTS_PATH_FILESTAT_GET, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    const st = r.dir.statFile(io, r.sub, .{ .follow_symlinks = lookupflags & p1.LOOKUPFLAGS_SYMLINK_FOLLOW != 0 }) catch |err| return mapDirErr(err);
    const atim_ns: i96 = if (st.atime) |a| a.nanoseconds else st.mtime.nanoseconds;
    const fs: p1.Filestat = .{
        .dev = 0,
        .ino = @intCast(st.inode),
        .filetype = filetypeFromKind(st.kind),
        .nlink = @intCast(st.nlink),
        .size = st.size,
        .atim = if (atim_ns > 0) @intCast(atim_ns) else 0,
        .mtim = if (st.mtime.nanoseconds > 0) @intCast(st.mtime.nanoseconds) else 0,
        .ctim = if (st.ctime.nanoseconds > 0) @intCast(st.ctime.nanoseconds) else 0,
    };
    @memcpy(dst, std.mem.asBytes(&fs));
    return .success;
}

/// `path_filestat_set_times(dirfd, lookupflags, path, atim, mtim, fst_flags)
/// → errno` — set a path's access/modify timestamps (`std.Io.Dir.setTimestamps`).
/// Explicit-value + `*_NOW` for one stamp → `inval`.
pub fn pathFilestatSetTimes(host: *Host, mem: []const u8, dirfd: p1.Fd, lookupflags: u32, path_ptr: u32, path_len: u32, atim: u64, mtim: u64, fst_flags: p1.Fstflags) p1.Errno {
    if (fst_flags & p1.FSTFLAGS_ATIM != 0 and fst_flags & p1.FSTFLAGS_ATIM_NOW != 0) return .inval;
    if (fst_flags & p1.FSTFLAGS_MTIM != 0 and fst_flags & p1.FSTFLAGS_MTIM_NOW != 0) return .inval;
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, p1.RIGHTS_PATH_FILESTAT_SET_TIMES, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    const atime = setTimestampOf(fst_flags, p1.FSTFLAGS_ATIM_NOW, p1.FSTFLAGS_ATIM, atim);
    const mtime = setTimestampOf(fst_flags, p1.FSTFLAGS_MTIM_NOW, p1.FSTFLAGS_MTIM, mtim);
    // Pre-probe existence: Threaded's setTimestamps op treats ENOENT as an
    // UNEXPECTED errno (posix.unexpectedErrno → error.Unexpected → `.io`),
    // losing the `noent` the guest is owed for a missing path.
    r.dir.access(io, r.sub, .{}) catch |err| return mapDirErr(err);
    if (comptime builtin.os.tag == .windows) {
        // Zig 0.16 std has NO `dirSetTimestamps` on Windows (`@panic("TODO")`)
        // — it would crash the runtime. Open the file and use the
        // cross-platform `File.setTimestamps` (verified on Win64 via
        // `fd_filestat_set_times`); the symlink-follow nuance is lost on this
        // path (openFile follows by default).
        var file = r.dir.openFile(io, r.sub, .{ .mode = .read_write }) catch |err| return mapDirErr(err);
        defer file.close(io);
        file.setTimestamps(io, .{ .access_timestamp = atime, .modify_timestamp = mtime }) catch |err| return mapDirErr(err);
    } else {
        r.dir.setTimestamps(io, r.sub, .{
            .follow_symlinks = lookupflags & p1.LOOKUPFLAGS_SYMLINK_FOLLOW != 0,
            .access_timestamp = atime,
            .modify_timestamp = mtime,
        }) catch |err| return mapDirErr(err);
    }
    return .success;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn writeGuestPath(mem: []u8, off: usize, name: []const u8) void {
    @memcpy(mem[off .. off + name.len], name);
}

test "pathCreateDirectory / pathRemoveDirectory: round-trip on a real preopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    writeGuestPath(&mem, 0, "newdir");
    try testing.expectEqual(p1.Errno.success, pathCreateDirectory(&h, &mem, dirfd, 0, 6));
    // The directory now exists on the host.
    const st = tmp.dir.statFile(testing.io, "newdir", .{}) catch return error.DirNotCreated;
    try testing.expectEqual(std.Io.File.Kind.directory, st.kind);

    try testing.expectEqual(p1.Errno.success, pathRemoveDirectory(&h, &mem, dirfd, 0, 6));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "newdir", .{}));
}

test "pathFilestatGet / pathFilestatSetTimes: stat a path + set its mtim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "hello" });
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    writeGuestPath(&mem, 0, "f.txt");
    const FS = 16; // filestat_ptr
    try testing.expectEqual(p1.Errno.success, pathFilestatGet(&h, &mem, dirfd, p1.LOOKUPFLAGS_SYMLINK_FOLLOW, 0, 5, FS));
    try testing.expectEqual(@as(u8, @intFromEnum(p1.Filetype.regular_file)), mem[FS + 16]); // filetype @+16
    try testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, mem[FS + 32 ..][0..8], .little)); // size @+32

    // Set mtim to 3.0s (whole second) and read it back @+48.
    try testing.expectEqual(p1.Errno.success, pathFilestatSetTimes(&h, &mem, dirfd, 0, 0, 5, 0, 3_000_000_000, p1.FSTFLAGS_MTIM));
    try testing.expectEqual(p1.Errno.success, pathFilestatGet(&h, &mem, dirfd, 0, 0, 5, FS));
    try testing.expectEqual(@as(u64, 3_000_000_000), std.mem.readInt(u64, mem[FS + 48 ..][0..8], .little));

    // Conflicting explicit+NOW → inval; a missing path → noent.
    try testing.expectEqual(p1.Errno.inval, pathFilestatSetTimes(&h, &mem, dirfd, 0, 0, 5, 0, 0, p1.FSTFLAGS_MTIM | p1.FSTFLAGS_MTIM_NOW));
    writeGuestPath(&mem, 0, "nope!");
    try testing.expectEqual(p1.Errno.noent, pathFilestatGet(&h, &mem, dirfd, 0, 0, 5, FS));
}

test "symlinkTargetEscapes: lexical containment of a symlink target vs the preopen root" {
    // Within the root (depth math, link in root: parent depth 0).
    try testing.expect(!symlinkTargetEscapes("link", "target.txt"));
    try testing.expect(!symlinkTargetEscapes("link", "./a/b"));
    // Link in root, target ascends → escape.
    try testing.expect(symlinkTargetEscapes("link", "../outside"));
    try testing.expect(symlinkTargetEscapes("link", "/etc/passwd")); // absolute
    // Link one dir deep: parent depth 1, one `..` returns to root (ok).
    try testing.expect(!symlinkTargetEscapes("a/link", "../b"));
    try testing.expect(!symlinkTargetEscapes("a/link", "../a/b"));
    // Link one dir deep, two `..` ascends above the root → escape.
    try testing.expect(symlinkTargetEscapes("a/link", "../../b"));
    // Descent then equal ascent stays within.
    try testing.expect(!symlinkTargetEscapes("a/b/link", "../../x")); // parent depth 2 → 0
    try testing.expect(symlinkTargetEscapes("a/b/link", "../../../x")); // depth 2 → -1 escape
    // `..` interleaved with names that net-escape mid-walk.
    try testing.expect(symlinkTargetEscapes("link", "a/../../x")); // 0→1→0→-1 escape
}

test "pathSymlink: refuses to plant a symlink whose target escapes the preopen (notcapable)" {
    // POSIX-only: Windows symlink creation needs a privilege. comptime
    // early-return, not a skip. The escape CHECK itself is platform-independent
    // and fully covered by the pure `symlinkTargetEscapes` test above; this only
    // exercises the host create path.
    // SIBLING-AT: src/wasi/path.zig (pathSymlink delegates to cross-platform
    // std.Io.Dir.symLink after the escape guard; Win64 build verified via
    // `zig build -Dtarget=x86_64-windows-gnu`, per skip.zig ADR-0122 D3).
    if (comptime builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    // target = "../escape" (len 9) @0; link path "lnk" (len 3) @16.
    writeGuestPath(&mem, 0, "../escape");
    writeGuestPath(&mem, 16, "lnk");
    try testing.expectEqual(p1.Errno.notcapable, pathSymlink(&h, &mem, 0, 9, dirfd, 16, 3));
    // The link must NOT have been created on the host.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "lnk", .{}));

    // An absolute target is likewise refused.
    writeGuestPath(&mem, 32, "/etc/passwd");
    try testing.expectEqual(p1.Errno.notcapable, pathSymlink(&h, &mem, 32, 11, dirfd, 16, 3));
}

test "pathSymlink / pathReadlink: create a symlink and read its target back" {
    // POSIX-only: Windows symlink creation needs a privilege + readlink error
    // mapping diverges. comptime early-return, not a skip.
    // SIBLING-AT: src/wasi/path.zig (pathSymlink/pathReadlink delegate to cross-
    // platform std.Io.Dir.{symLink,readLink}; Win64 build verified via
    // `zig build -Dtarget=x86_64-windows-gnu`, per skip.zig ADR-0122 D3).
    if (comptime builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    writeGuestPath(&mem, 0, "target.txt"); // target (link contents) @0, len 10
    writeGuestPath(&mem, 16, "lnk"); // link path @16, len 3
    const sym_e = pathSymlink(&h, &mem, 0, 10, dirfd, 16, 3);
    // A platform that denies unprivileged symlink creation (e.g. Windows
    // without Developer Mode) returns acces — the handler is correct; skip the
    // round-trip assertion there. Mac/Linux create + read it back fully.
    if (sym_e == .acces) return;
    try testing.expectEqual(p1.Errno.success, sym_e);

    // readlink the symlink into buf @32, write bufused @64.
    try testing.expectEqual(p1.Errno.success, pathReadlink(&h, &mem, dirfd, 16, 3, 32, 32, 64));
    const n = std.mem.readInt(u32, mem[64..68], .little);
    try testing.expectEqual(@as(u32, 10), n);
    try testing.expectEqualStrings("target.txt", mem[32 .. 32 + n]);

    // readlink on a non-symlink → inval (NotLink).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain", .data = "x" });
    writeGuestPath(&mem, 96, "plain");
    try testing.expectEqual(p1.Errno.inval, pathReadlink(&h, &mem, dirfd, 96, 5, 32, 32, 64));
}

test "pathRename / pathLink: move a file and hard-link it" {
    // POSIX-only: Windows rename/hardlink filesystem semantics diverge (move-
    // over-target rules + hardlink support). comptime early-return, NOT a skip.
    // SIBLING-AT: src/wasi/path.zig (pathRename/pathLink delegate to cross-
    // platform std.Io.Dir.{rename,hardLink}; Win64 build verified via
    // `zig build -Dtarget=x86_64-windows-gnu`, per skip.zig ADR-0122 D3).
    if (comptime builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "data" });
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    writeGuestPath(&mem, 0, "a.txt"); // @0 len 5
    writeGuestPath(&mem, 16, "b.txt"); // @16 len 5
    try testing.expectEqual(p1.Errno.success, pathRename(&h, &mem, dirfd, 0, 5, dirfd, 16, 5));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "a.txt", .{}));
    _ = tmp.dir.statFile(testing.io, "b.txt", .{}) catch return error.RenameTargetMissing;

    // hard-link b.txt → c.txt; both resolve to the same inode (size matches).
    writeGuestPath(&mem, 32, "c.txt"); // @32 len 5
    const link_e = pathLink(&h, &mem, dirfd, 0, 16, 5, dirfd, 32, 5);
    if (link_e == .acces) return; // platform without unprivileged hardlink support
    try testing.expectEqual(p1.Errno.success, link_e);
    const st = tmp.dir.statFile(testing.io, "c.txt", .{}) catch return error.LinkMissing;
    try testing.expectEqual(@as(u64, 4), st.size);

    // Renaming a missing source → noent.
    writeGuestPath(&mem, 48, "ghost");
    try testing.expectEqual(p1.Errno.noent, pathRename(&h, &mem, dirfd, 48, 5, dirfd, 0, 5));
}

test "path_* resolution: escape / non-dir / out-of-bounds rejections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    writeGuestPath(&mem, 0, "../escape");
    try testing.expectEqual(p1.Errno.notcapable, pathCreateDirectory(&h, &mem, dirfd, 0, 9));
    // Non-preopen dirfd (stdout) → notdir.
    writeGuestPath(&mem, 0, "x");
    try testing.expectEqual(p1.Errno.notdir, pathCreateDirectory(&h, &mem, 1, 0, 1));
    // Out-of-bounds path slice → fault.
    try testing.expectEqual(p1.Errno.fault, pathRemoveDirectory(&h, &mem, dirfd, 60, 20));
    // Removing a missing directory → noent.
    writeGuestPath(&mem, 0, "ghost");
    try testing.expectEqual(p1.Errno.noent, pathRemoveDirectory(&h, &mem, dirfd, 0, 5));
}

// ============================================================
// Path confinement
// ============================================================

test "confine: a `..` that stays inside the preopen root is allowed" {
    // The literal path the official `interesting_paths` opens and expects to
    // resolve — it dips through `..` twice and comes back.
    try testing.expectEqual(p1.Errno.success, confine("dir/.//nested/../../dir/nested/../nested///./file"));
    try testing.expectEqual(p1.Errno.success, confine("a/b"));
    try testing.expectEqual(p1.Errno.success, confine("./a/./b"));
    try testing.expectEqual(p1.Errno.success, confine("a/b/../c"));
    try testing.expectEqual(p1.Errno.success, confine("a/../b"));
    try testing.expectEqual(p1.Errno.success, confine("."));
    try testing.expectEqual(p1.Errno.success, confine("a/.."));
}

test "confine: leaving the preopen root is notcapable" {
    try testing.expectEqual(p1.Errno.notcapable, confine("/dir/nested/file"));
    try testing.expectEqual(p1.Errno.notcapable, confine("/"));
    try testing.expectEqual(p1.Errno.notcapable, confine(".."));
    try testing.expectEqual(p1.Errno.notcapable, confine("../escape"));
    try testing.expectEqual(p1.Errno.notcapable, confine("dir/nested/../../../dir/nested/file"));
    // Balanced to exactly the root is still inside it.
    try testing.expectEqual(p1.Errno.success, confine("dir/.."));
}

test "confine: the empty path and an interior NUL are rejected" {
    try testing.expectEqual(p1.Errno.noent, confine(""));
    // The host's C path conversion would truncate at the NUL and resolve a
    // DIFFERENT path than the guest named.
    try testing.expectEqual(p1.Errno.inval, confine("dir/nested/file\x00"));
}

test "confine: POSIX meaning survives, because the path is not rewritten" {
    // A fold would drop these components and turn `f/.` into a successful open
    // of `f`; the host has to see them to answer `notdir`. Verified end to end
    // against wasmtime 47.3: `f/.`, `f/./.` and `f/..` are all `notdir` there.
    for ([_][]const u8{ "f/.", "f/./.", "f/..", "f/", "dir/nested/", "dir/nested/file/" }) |p| {
        try testing.expectEqual(p1.Errno.success, confine(p));
    }
}
