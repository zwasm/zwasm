//! WASI path resolution beneath a directory fd (D-315): every WASI 0.1, 0.2
//! and 0.3 call that hands a guest path to the host resolves it here, one
//! component at a time from the dirfd's handle, so the result stays beneath
//! that directory whatever symlinks the path meets.
//!
//! Zone 2 (`src/wasi/`) — called by path.zig / fd.zig.

const std = @import("std");
const builtin = @import("builtin");

const p1 = @import("preview1.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

/// The most symlinks one resolution expands before it is `loop` (Linux's
/// MAXSYMLINKS).
const max_symlink_expansions = 40;

/// Whether a symlink in the FINAL component is expanded. An intermediate one
/// always is. A trailing separator expands the final one too, as POSIX
/// resolves `link/` through the link — except under `never`: `rmdir`,
/// `rename` and `unlink` do not follow `link/` on Linux, which answers
/// ENOTDIR, while macOS follows it. `never` answers `notdir` there without
/// handing the host a name it might follow.
pub const Follow = enum { follow_final, no_follow_final, never };

/// A guest path resolved beneath `root`: the directory `dir` that holds its
/// final component, and that component as `name` — `.` when the path names
/// `dir` itself, with any trailing separator the guest wrote. `name` is never
/// a symlink when the resolution followed it (at the time it was checked), and
/// never contains a separator other than trailing ones, so an operation on
/// `(dir, name)` stays beneath `root` when it does not follow a symlink.
/// `depth` is how many directories `dir` sits below `root`.
pub const Resolved = struct {
    dir: std.Io.Dir,
    name: []const u8,
    depth: usize,
    /// `stack.items[0]` is `root`, borrowed; the rest are owned, one per
    /// directory between `root` and `dir`.
    stack: std.ArrayList(std.Io.Dir) = .empty,
    /// The remaining path after a symlink was spliced in; `name` may point here.
    spliced: ?[]u8 = null,

    pub fn deinit(self: *Resolved, alloc: std.mem.Allocator, io: std.Io) void {
        if (self.stack.items.len > 1) std.Io.Dir.closeMany(io, self.stack.items[1..]);
        self.stack.deinit(alloc);
        if (self.spliced) |s| alloc.free(s);
        self.* = undefined;
    }
};

/// Resolve `path` (already `confine`d: relative, no interior NUL) beneath
/// `root`. Each intermediate component is opened as a directory without
/// following it; a symlink is read and its target spliced in front of what is
/// left, and resolution continues from the directory that holds the link. `..`
/// returns to the directory the walk came from, so it never names anything
/// above `root`: that, an absolute symlink target, or a drive-prefixed
/// component is `notcapable`, what `confine` answers for a path that leaves
/// the preopen. On success `out` holds handles the caller releases with
/// `Resolved.deinit`; on failure it holds none.
///
/// Where this refuses what the kernel's own resolution admits:
/// - a path deeper than the process's descriptor limit is `mfile`: the walk
///   holds one handle per directory, and other opens in the process can fail
///   while it does;
/// - on macOS, a directory with search but not read permission is `acces` in
///   the middle of a path, since each component is opened `O_RDONLY`;
/// - on Windows, a reparse point that is not a symlink or junction is
///   `notcapable` in the middle of a path and `io` as a followed final name.
pub fn resolve(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, follow: Follow, out: *Resolved) p1.Errno {
    out.* = .{ .dir = root, .name = ".", .depth = 0 };
    const e = walk(alloc, io, root, path, follow, out);
    if (e != .success) out.deinit(alloc, io);
    return e;
}

fn walk(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, follow: Follow, out: *Resolved) p1.Errno {
    out.stack.append(alloc, root) catch return .nomem;
    var link_buf: [4096]u8 = undefined;
    var rest: []const u8 = path;
    var expansions: usize = 0;
    while (true) {
        const start = skipSeps(rest, 0);
        if (start == rest.len) break; // nothing after the last directory: it is named itself
        const end = std.mem.findAnyPos(u8, rest, start, separators) orelse rest.len;
        const comp = rest[start..end];
        const final = skipSeps(rest, end) == rest.len;
        if (hasDrivePrefix(comp)) return .notcapable;
        const top = out.stack.items[out.stack.items.len - 1];
        if (std.mem.eql(u8, comp, ".")) {
            if (final) {
                out.name = rest[start..];
                break;
            }
        } else if (std.mem.eql(u8, comp, "..")) {
            if (out.stack.items.len == 1) return .notcapable;
            top.close(io);
            out.stack.items.len -= 1;
            if (final) break;
        } else if (final) {
            if (follow != .follow_final and end == rest.len) {
                out.name = rest[start..];
                break;
            }
            const target = top.readLink(io, comp, &link_buf) catch |err| switch (err) {
                // Not a symlink, or nothing there yet: the operation answers.
                error.NotLink, error.FileNotFound => {
                    out.name = rest[start..];
                    break;
                },
                else => return mapErr(err),
            };
            if (follow == .never) return .notdir;
            const se = splice(alloc, out, link_buf[0..target], rest[end..], &expansions);
            if (se != .success) return se;
            rest = out.spliced.?;
            continue;
        } else switch (openComponent(io, top, comp, &link_buf)) {
            .dir => |d| out.stack.append(alloc, d) catch {
                d.close(io);
                return .nomem;
            },
            .link => |target| {
                const se = splice(alloc, out, target, rest[end..], &expansions);
                if (se != .success) return se;
                rest = out.spliced.?;
                continue;
            },
            .err => |e| return e,
        }
        rest = rest[end..];
    }
    out.dir = out.stack.items[out.stack.items.len - 1];
    out.depth = out.stack.items.len - 1;
    return .success;
}

/// An O_CREAT open of `name` in `dir` that follows no final symlink, which
/// `createFile` has no option for: an exclusive create (O_EXCL follows no
/// final symlink), and a name that already exists reopened no-follow, so a
/// symlink there is `SymLinkLoop`. A name removed between the two is created
/// again, up to `max_create_attempts` times. `existed` says it was reopened,
/// and the caller applies O_TRUNC then. For POSIX: on Windows a no-follow open
/// makes the handle asynchronous.
pub fn createNoFollow(io: std.Io, dir: std.Io.Dir, name: []const u8) std.Io.File.OpenError!Created {
    return createNoFollowObserved(io, dir, name, NoObserver{});
}

pub const Created = struct { file: std.Io.File, existed: bool };

/// How many times `createNoFollow` tries the exclusive create, while the name
/// keeps disappearing between that and the reopen.
const max_create_attempts = 4;

const NoObserver = struct {
    fn taken(_: NoObserver) void {
        // Production observes nothing; only tests change the directory here.
    }
};

/// `createNoFollow` with `observer.taken()` run each time the exclusive create
/// finds the name taken, before the reopen: a test changes the directory there.
fn createNoFollowObserved(io: std.Io, dir: std.Io.Dir, name: []const u8, observer: anytype) std.Io.File.OpenError!Created {
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        if (dir.createFile(io, name, .{ .read = true, .exclusive = true })) |f| {
            return .{ .file = f, .existed = false };
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        }
        observer.taken();
        if (dir.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false })) |f| {
            return .{ .file = f, .existed = true };
        } else |err| switch (err) {
            error.FileNotFound => if (attempt == max_create_attempts) return err,
            else => |e| return e,
        }
    }
}

const Step = union(enum) { dir: std.Io.Dir, link: []const u8, err: p1.Errno };

/// Open one intermediate component of `dir` as a directory, not following it.
/// A symlink there comes back as its target.
fn openComponent(io: std.Io, dir: std.Io.Dir, name: []const u8, link_buf: []u8) Step {
    const d = dir.openDir(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        // A no-follow directory open of a symlink: ELOOP on Linux and macOS,
        // ENOTDIR for Linux's O_PATH form.
        error.SymLinkLoop, error.NotDir => return readLinkStep(io, dir, name, link_buf, mapErr(err)),
        else => return .{ .err = mapErr(err) },
    };
    if (comptime builtin.os.tag != .windows) return .{ .dir = d };
    // NT opens a directory symlink or junction ITSELF under OPEN_REPARSE_POINT,
    // as a directory, so the kind has to be asked. A reparse point that is not
    // a name surrogate stat-s as `unknown` and is not walked through.
    const st = d.stat(io) catch |err| {
        d.close(io);
        return .{ .err = mapErr(err) };
    };
    switch (st.kind) {
        .directory => return .{ .dir = d },
        .sym_link => {
            d.close(io);
            return readLinkStep(io, dir, name, link_buf, .notdir);
        },
        else => {
            d.close(io);
            return .{ .err = .notcapable };
        },
    }
}

fn readLinkStep(io: std.Io, dir: std.Io.Dir, name: []const u8, link_buf: []u8, not_link: p1.Errno) Step {
    const n = dir.readLink(io, name, link_buf) catch |err| return .{ .err = switch (err) {
        error.NotLink => not_link,
        else => mapErr(err),
    } };
    return .{ .link = link_buf[0..n] };
}

/// Replace what is left of the path with `target` followed by `after` (the
/// separators and components after the link). An absolute or drive-prefixed
/// target leaves `root`; an empty one names nothing.
fn splice(alloc: std.mem.Allocator, out: *Resolved, target: []const u8, after: []const u8, expansions: *usize) p1.Errno {
    if (target.len == 0) return .noent;
    if (path_mod.isSep(target[0]) or hasDrivePrefix(target)) return .notcapable;
    expansions.* += 1;
    if (expansions.* > max_symlink_expansions) return .loop;
    const next = alloc.alloc(u8, target.len + after.len) catch return .nomem;
    @memcpy(next[0..target.len], target);
    @memcpy(next[target.len..], after);
    if (out.spliced) |s| alloc.free(s);
    out.spliced = next;
    return .success;
}

fn skipSeps(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and path_mod.isSep(s[i])) i += 1;
    return i;
}

/// The separators, the drive-prefix rule and the errno mapping `confine` and
/// the `path_*` handlers use, so the text check and the walk agree on what
/// leaves the root.
const path_mod = @import("path.zig");
const separators = path_mod.separators;
const hasDrivePrefix = path_mod.hasDrivePrefix;
const mapErr = path_mod.mapDirErr;

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const fd_mod = @import("fd.zig");
const skip = @import("../test_support/skip.zig");

/// A preopen at `<tmp>/pre` with `<tmp>/outside.txt` and `<tmp>/outdir/` next
/// to it, so a resolution that leaves the preopen has something to find.
const BeneathFixture = struct {
    tmp: std.testing.TmpDir,
    pre: std.Io.Dir,
    host: Host,
    dirfd: p1.Fd,

    fn init(self: *BeneathFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDir(testing.io, "pre", std.Io.File.Permissions.default_dir);
        try self.tmp.dir.createDir(testing.io, "outdir", std.Io.File.Permissions.default_dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "OUTSIDE" });
        self.pre = try self.tmp.dir.openDir(testing.io, "pre", .{ .iterate = true });
        errdefer self.pre.close(testing.io);
        self.host = try Host.init(testing.allocator);
        self.host.io = testing.io;
        self.dirfd = try self.host.addPreopen(self.pre.handle, "/");
    }

    fn deinit(self: *BeneathFixture) void {
        for (self.host.fd_table.items[self.dirfd + 1 ..]) |slot| {
            if (slot.kind != .closed) if (slot.host_handle) |h| (std.Io.Dir{ .handle = h }).close(testing.io);
        }
        self.host.deinit();
        self.pre.close(testing.io);
        self.tmp.cleanup();
    }

    /// Plant a symlink as the host, not the guest: one a guest could not create.
    /// Skips the test where the host denies unprivileged symlink creation
    /// (Windows without Developer Mode).
    fn plant(dir: std.Io.Dir, target: []const u8, link: []const u8) !void {
        dir.symLink(testing.io, target, link, .{}) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => |e| if (builtin.os.tag == .windows) return skip.phaseEnd(.win64) else return e,
            else => |e| return e,
        };
    }

    fn outsideUntouched(self: *BeneathFixture) !void {
        const data = try self.tmp.dir.readFileAlloc(testing.io, "outside.txt", testing.allocator, .limited(64));
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("OUTSIDE", data);
        _ = try self.tmp.dir.statFile(testing.io, "outdir", .{});
    }
};

fn guestPath(mem: []u8, off: u32, name: []const u8) u32 {
    @memcpy(mem[off..][0..name.len], name);
    return @intCast(name.len);
}

test "path_* refuse a path whose symlink leads above the preopen (notcapable)" {
    var f: BeneathFixture = undefined;
    try f.init();
    defer f.deinit();
    try BeneathFixture.plant(f.pre, "..", "esc");
    try BeneathFixture.plant(f.pre, "../outside.txt", "fesc");
    try BeneathFixture.plant(f.pre, ".", "dot");
    try BeneathFixture.plant(f.tmp.dir, "outside.txt", "outlink");
    const h = &f.host;
    const d = f.dirfd;

    const follow = p1.LOOKUPFLAGS_SYMLINK_FOLLOW;
    var mem: [512]u8 = @splat(0);

    // An intermediate symlink, a final one followed, and `..` past a symlink
    // that names the root.
    for ([_]struct { p: []const u8, dirflags: u32 }{
        .{ .p = "esc/outside.txt", .dirflags = follow },
        .{ .p = "esc/outside.txt", .dirflags = 0 },
        .{ .p = "fesc", .dirflags = follow },
        .{ .p = "dot/../outside.txt", .dirflags = follow },
        .{ .p = "dot/esc/outside.txt", .dirflags = follow },
        .{ .p = "esc/pre/esc/outside.txt", .dirflags = follow },
    }) |c| {
        const n = guestPath(&mem, 0, c.p);
        try testing.expectEqual(p1.Errno.notcapable, fd_mod.pathOpen(h, &mem, d, c.dirflags, 0, n, 0, p1.RIGHTS_FD_READ, 0, 0, 256));
    }
    var n = guestPath(&mem, 0, "esc/outdir");
    try testing.expectEqual(p1.Errno.notcapable, fd_mod.pathOpen(h, &mem, d, follow, 0, n, p1.OFLAGS_DIRECTORY, p1.RIGHTS_FD_READDIR, 0, 0, 256));
    n = guestPath(&mem, 0, "esc/created.txt");
    try testing.expectEqual(p1.Errno.notcapable, fd_mod.pathOpen(h, &mem, d, follow, 0, n, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE, 0, 0, 256));
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(testing.io, "created.txt", .{}));

    n = guestPath(&mem, 0, "esc/outside.txt");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathFilestatGet(h, &mem, d, follow, 0, n, 256));
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathFilestatSetTimes(h, &mem, d, follow, 0, n, 0, 0, p1.FSTFLAGS_MTIM_NOW));
    try testing.expectEqual(p1.Errno.notcapable, fd_mod.pathUnlinkFile(h, &mem, d, 0, n));
    var n2 = guestPath(&mem, 64, "moved");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathRename(h, &mem, d, 0, n, d, 64, n2));
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathRename(h, &mem, d, 64, n2, d, 0, n));
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathLink(h, &mem, d, 0, 0, n, d, 64, n2));
    n = guestPath(&mem, 0, "fesc");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathFilestatGet(h, &mem, d, follow, 0, n, 256));
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathFilestatSetTimes(h, &mem, d, follow, 0, n, 0, 0, p1.FSTFLAGS_MTIM_NOW));
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathLink(h, &mem, d, follow, 0, n, d, 64, n2));
    try testing.expectError(error.FileNotFound, f.pre.statFile(testing.io, "moved", .{}));

    n = guestPath(&mem, 0, "esc/newdir");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathCreateDirectory(h, &mem, d, 0, n));
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(testing.io, "newdir", .{}));
    n = guestPath(&mem, 0, "esc/outdir");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathRemoveDirectory(h, &mem, d, 0, n));
    n = guestPath(&mem, 0, "esc/planted");
    n2 = guestPath(&mem, 64, "x");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathSymlink(h, &mem, 64, n2, d, 0, n));
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(testing.io, "planted", .{ .follow_symlinks = false }));
    n = guestPath(&mem, 0, "esc/outlink");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathReadlink(h, &mem, d, 0, n, 128, 64, 256));

    try f.outsideUntouched();
}

test "path_symlink checks a target from the directory the link really lands in" {
    // `d -> .` makes `d/e` a name in the root itself, so a target of `..` there
    // leaves the preopen even though `d/e` is one level down as text.
    var f: BeneathFixture = undefined;
    try f.init();
    defer f.deinit();
    var mem: [128]u8 = @splat(0);
    const dot = guestPath(&mem, 0, ".");
    const dotdot = guestPath(&mem, 8, "..");
    const d = guestPath(&mem, 16, "d");
    const de = guestPath(&mem, 24, "d/e");
    const e = path_mod.pathSymlink(&f.host, &mem, 0, dot, f.dirfd, 16, d);
    if (builtin.os.tag == .windows and (e == .acces or e == .perm)) return skip.phaseEnd(.win64); // no unprivileged symlinks
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathSymlink(&f.host, &mem, 8, dotdot, f.dirfd, 24, de));
    try testing.expectError(error.FileNotFound, f.pre.statFile(testing.io, "e", .{ .follow_symlinks = false }));
}

test "path_* follow a symlink that stays inside the preopen, and refuse a loop or an absolute target" {
    var f: BeneathFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.pre.createDir(testing.io, "sub", std.Io.File.Permissions.default_dir);
    try f.pre.writeFile(testing.io, .{ .sub_path = "sub/f.txt", .data = "in" });
    try BeneathFixture.plant(f.pre, "sub", "in");
    try BeneathFixture.plant(f.pre, "sub/f.txt", "lf");
    try BeneathFixture.plant(f.pre, "../sub", "sub/self");
    try BeneathFixture.plant(f.pre, "l2", "l1");
    try BeneathFixture.plant(f.pre, "l1", "l2");
    try BeneathFixture.plant(f.pre, if (builtin.os.tag == .windows) "C:\\" else "/", "abs");

    const follow = p1.LOOKUPFLAGS_SYMLINK_FOLLOW;
    var mem: [512]u8 = @splat(0);

    for ([_][]const u8{ "in/f.txt", "lf", "in/../sub/f.txt", "sub/self/self/f.txt", "in/self/../in/f.txt" }) |p| {
        const n = guestPath(&mem, 0, p);
        try testing.expectEqual(p1.Errno.success, fd_mod.pathOpen(&f.host, &mem, f.dirfd, follow, 0, n, 0, p1.RIGHTS_FD_READ, 0, 0, 256));
        try testing.expectEqual(p1.Errno.success, path_mod.pathFilestatGet(&f.host, &mem, f.dirfd, follow, 0, n, 256));
        try testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, mem[256 + 32 ..][0..8], .little));
    }
    var n = guestPath(&mem, 0, "in/new.txt");
    try testing.expectEqual(p1.Errno.success, fd_mod.pathOpen(&f.host, &mem, f.dirfd, follow, 0, n, p1.OFLAGS_CREAT, p1.RIGHTS_FD_WRITE, 0, 0, 256));
    _ = try f.pre.statFile(testing.io, "sub/new.txt", .{});

    n = guestPath(&mem, 0, "l1/x");
    try testing.expectEqual(p1.Errno.loop, fd_mod.pathOpen(&f.host, &mem, f.dirfd, follow, 0, n, 0, p1.RIGHTS_FD_READ, 0, 0, 256));
    n = guestPath(&mem, 0, "abs/x");
    try testing.expectEqual(p1.Errno.notcapable, fd_mod.pathOpen(&f.host, &mem, f.dirfd, follow, 0, n, 0, p1.RIGHTS_FD_READ, 0, 0, 256));
    n = guestPath(&mem, 0, "abs");
    try testing.expectEqual(p1.Errno.notcapable, path_mod.pathFilestatGet(&f.host, &mem, f.dirfd, follow, 0, n, 256));
}

test "a WASI 0.1 guest that plants a symlink to leave its preopen is refused, run as `zwasm run --dir <tmp>/pre:/` runs it" {
    // test/wasi/path_beneath/*.wat: each plants symlinks inside the preopen and
    // then opens or creates through them. The exit code is the first errno
    // (76 = notcapable), offset by the step that returned it.
    const run = @import("../cli/run.zig");
    for ([_]struct { file: []const u8, exit: u8 }{
        .{ .file = "symlink_then_dotdot", .exit = 76 },
        .{ .file = "symlink_chain_open", .exit = 140 + 76 },
        .{ .file = "symlink_chain_create", .exit = 140 + 76 },
    }) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(testing.io, "pre", std.Io.File.Permissions.default_dir);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "OUTSIDE" });
        var path_buf: [256]u8 = undefined;
        const fixture = try std.mem.print(&path_buf, "test/wasi/path_beneath/{s}.wasm", .{c.file});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture, testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(bytes);
        var pre_buf: [256]u8 = undefined;
        const pre = try std.mem.print(&pre_buf, ".zig-cache/tmp/{s}/pre", .{&tmp.sub_path});
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);

        const code = try run.runWasmCapturedFull(testing.allocator, testing.io, bytes, &.{}, &out, null, .none, null, &.{.{ .host_path = pre, .guest_path = "/" }}, &.{}, &.{}, null, .{});
        // 100 + acces: the first symlink was refused for want of the privilege,
        // which only a host without unprivileged symlinks does (Windows without
        // Developer Mode).
        if (builtin.os.tag == .windows and code == 100 + @backingInt(p1.Errno.acces)) return skip.phaseEnd(.win64);
        try testing.expectEqual(c.exit, code);
        try testing.expectEqualStrings("", out.items);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "created.txt", .{}));
    }
}

test "createNoFollow: a new name is created, an existing file reopened, and a final symlink is not followed" {
    // POSIX only: `pathOpen` uses it there, and on Windows a no-follow open of
    // a file symlink opens the link itself instead of refusing.
    // SIBLING-AT: src/wasi/fd.zig (pathOpen keeps `createFile` for an O_CREAT
    // open on Windows).
    if (comptime builtin.os.tag == .windows) return;
    var f: BeneathFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.pre.writeFile(testing.io, .{ .sub_path = "old.txt", .data = "kept" });
    try BeneathFixture.plant(f.pre, "../outside.txt", "lnk");
    try BeneathFixture.plant(f.pre, "../fresh.txt", "dangling");

    const made = try createNoFollow(testing.io, f.pre, "new.txt");
    made.file.close(testing.io);
    try testing.expect(!made.existed);
    const old = try createNoFollow(testing.io, f.pre, "old.txt");
    old.file.close(testing.io);
    try testing.expect(old.existed);
    const data = try f.pre.readFileAlloc(testing.io, "old.txt", testing.allocator, .limited(16));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("kept", data);

    try testing.expectError(error.SymLinkLoop, createNoFollow(testing.io, f.pre, "lnk"));
    try testing.expectError(error.SymLinkLoop, createNoFollow(testing.io, f.pre, "dangling"));
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(testing.io, "fresh.txt", .{}));
    try f.outsideUntouched();
}

test "createNoFollow creates the name again when it is removed between the exclusive create and the reopen" {
    // POSIX only, as the test above.
    // SIBLING-AT: src/wasi/fd.zig (pathOpen keeps `createFile` for an O_CREAT
    // open on Windows).
    if (comptime builtin.os.tag == .windows) return;
    var f: BeneathFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.pre.writeFile(testing.io, .{ .sub_path = "cache.bin", .data = "old" });

    // Removes the name once, after the exclusive create has found it.
    const Remover = struct {
        dir: std.Io.Dir,
        calls: usize = 0,
        fn taken(self: *@This()) void {
            self.calls += 1;
            if (self.calls == 1) self.dir.deleteFile(testing.io, "cache.bin") catch |err| std.debug.panic("deleteFile: {s}", .{@errorName(err)});
        }
    };
    var remover: Remover = .{ .dir = f.pre };
    const c = try createNoFollowObserved(testing.io, f.pre, "cache.bin", &remover);
    c.file.close(testing.io);
    try testing.expect(!c.existed);
    try testing.expectEqual(@as(usize, 1), remover.calls);
    const st = try f.pre.statFile(testing.io, "cache.bin", .{});
    try testing.expectEqual(@as(u64, 0), st.size);
}

test "path_open O_CREAT|O_TRUNC of an existing FIFO opens it, as the kernel ignores O_TRUNC there" {
    // Linux only: std makes a FIFO only through `linux.mknodat`.
    // SIBLING-AT: src/wasi/fd.zig (pathOpen's `c.existed and trunc` branch,
    // the same on every POSIX host).
    if (comptime builtin.os.tag != .linux) return;
    var f: BeneathFixture = undefined;
    try f.init();
    defer f.deinit();
    const linux = std.os.linux;
    try testing.expectEqual(@as(usize, 0), linux.mknodat(f.pre.handle, "fifo", linux.S.IFIFO | 0o600, 0));
    var mem: [64]u8 = @splat(0);
    const n = guestPath(&mem, 0, "fifo");
    try testing.expectEqual(p1.Errno.success, fd_mod.pathOpen(&f.host, &mem, f.dirfd, p1.LOOKUPFLAGS_SYMLINK_FOLLOW, 0, n, p1.OFLAGS_CREAT | p1.OFLAGS_TRUNC, p1.RIGHTS_FD_READ | p1.RIGHTS_FD_WRITE, 0, 0, 32));
}

test "path_remove_directory / path_rename / path_unlink_file of `link/` are notdir and follow nothing" {
    // Linux answers ENOTDIR for these without following the link, and macOS
    // follows it, so the host is never handed `link/`. `l -> .` reached the
    // host as `./`, which `rmdir` answers EINVAL and std turns into a panic.
    var f: BeneathFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.pre.createDir(testing.io, "sub", std.Io.File.Permissions.default_dir);
    try BeneathFixture.plant(f.pre, ".", "l");
    try BeneathFixture.plant(f.pre, "sub", "ld");
    try f.pre.writeFile(testing.io, .{ .sub_path = "x", .data = "x" });
    var mem: [64]u8 = @splat(0);
    const x = guestPath(&mem, 32, "x");
    for ([_][]const u8{ "l/", "ld/", "l//" }) |p| {
        @memset(mem[0..32], 0);
        const n = guestPath(&mem, 0, p);
        try testing.expectEqual(p1.Errno.notdir, path_mod.pathRemoveDirectory(&f.host, &mem, f.dirfd, 0, n));
        try testing.expectEqual(p1.Errno.notdir, path_mod.pathRename(&f.host, &mem, f.dirfd, 0, n, f.dirfd, 32, x));
        try testing.expectEqual(p1.Errno.notdir, path_mod.pathRename(&f.host, &mem, f.dirfd, 32, x, f.dirfd, 0, n));
        try testing.expectEqual(p1.Errno.notdir, fd_mod.pathUnlinkFile(&f.host, &mem, f.dirfd, 0, n));
    }
    _ = try f.pre.statFile(testing.io, "sub", .{});
    _ = try f.pre.statFile(testing.io, "l", .{ .follow_symlinks = false });
    _ = try f.pre.statFile(testing.io, "ld", .{ .follow_symlinks = false });
}
