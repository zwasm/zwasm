// FILE-SIZE-EXEMPT: the single P2→P1 name-map concern; largest data block is 27% — under P2's 40% bar (investigated 2026-08-12, per ADR-0099)
//! WASI **Preview 2 → Preview 1 adapter** name-map (CM campaign chunk D1;
//! WASI-P2 `wasi:cli` / `wasi:io` / `wasi:clocks` / `wasi:random` WIT).
//!
//! A P2 component imports component-level WASI interfaces (`wasi:cli/stdout`,
//! `wasi:io/streams`, …). The Component Model host wires those imports to this
//! adapter, which maps each (interface, func) onto the EXISTING Preview 1
//! implementation (`wasi/preview1.zig` + `wasi/fd.zig`) — reusing the P1 impl
//! wholesale per the survey (`component_model_survey`). This file is the pure
//! NAME-MAP + classifier (D1-1); the resource-stream → fd bridge + the host
//! wiring land in D1-2+. Gated `-Dwasi=preview2`.
//!
//! No-copy: v1 `component.zig` `WasiAdapter`/`p2_to_p1_map` is a flat
//! interface→p1-module table; re-derived here as a typed `(interface, func) →
//! P2Op → P1Target` classifier so the integration dispatches without string
//! re-parsing.

const std = @import("std");
const p1 = @import("preview1.zig");
const ctypes = @import("../feature/component/types.zig");

pub const Gen = ctypes.WasiGen;

/// Which generations a table row serves (ADR-0205 D1). Default = both: most
/// funcs are shape-identical across 0.2/0.3; rows whose shapes DIVERGE carry
/// an explicit single-generation mask.
pub const Gens = packed struct { p2: bool = true, p3: bool = true };
const p2_only: Gens = .{ .p3 = false };
const p3_only: Gens = .{ .p2 = false };

/// The `wasi:filesystem/types` `error-code` enum (0.2.x), every member in WIT
/// declaration order with no explicit values: an `enum` lowers to its
/// declaration ordinal in the Canonical ABI, so the order IS the encoding.
pub const P2ErrorCode = enum(u8) {
    access,
    would_block,
    already,
    bad_descriptor,
    busy,
    deadlock,
    quota,
    exist,
    file_too_large,
    illegal_byte_sequence,
    in_progress,
    interrupted,
    invalid,
    io,
    is_directory,
    loop,
    too_many_links,
    message_size,
    name_too_long,
    no_device,
    no_entry,
    no_lock,
    insufficient_memory,
    insufficient_space,
    not_directory,
    not_empty,
    not_recoverable,
    unsupported,
    no_tty,
    no_such_device,
    overflow,
    not_permitted,
    pipe,
    read_only,
    invalid_seek,
    text_file_busy,
    cross_device,
};

/// D-307: map a Preview-1 `errno` onto the canonical Preview-2
/// `wasi:filesystem/types` `error-code` ordinal, so a P2 trampoline can write
/// `result.err(error-code)` instead of trapping on a P1 failure. Errnos with no
/// P2 counterpart (the network/STREAM-only ones) fall back to `io`.
pub fn errnoToP2ErrorCode(errno: p1.Errno) P2ErrorCode {
    return switch (errno) {
        .acces => .access,
        .again => .would_block,
        .already => .already,
        .badf => .bad_descriptor,
        .busy => .busy,
        .exist => .exist,
        .fbig => .file_too_large,
        .ilseq => .illegal_byte_sequence,
        .inprogress => .in_progress,
        .intr => .interrupted,
        .inval => .invalid,
        .isdir => .is_directory,
        .loop => .loop,
        .mlink => .too_many_links,
        .msgsize => .message_size,
        .nametoolong => .name_too_long,
        .nodev => .no_device,
        .noent => .no_entry,
        .nomem => .insufficient_memory,
        .nospc => .insufficient_space,
        .notdir => .not_directory,
        .notempty => .not_empty,
        .notsup => .unsupported,
        .overflow => .overflow,
        .perm => .not_permitted,
        .pipe => .pipe,
        .rofs => .read_only,
        .spipe => .invalid_seek,
        .xdev => .cross_device,
        else => .io,
    };
}

/// The CLI-subset P2 operations the adapter recognises. The richer P2 surface
/// (full filesystem / poll / sockets) extends this in later chunks.
pub const P2Op = enum {
    // wasi:cli/{stdout,stderr,stdin} — acquire the std stream resources.
    cli_get_stdout,
    cli_get_stderr,
    cli_get_stdin,
    // WASI 0.3 async stdio (ADR-0190): the host is the stream's reader peer.
    cli_stdout_write_via_stream,
    cli_stderr_write_via_stream,
    // ...and the writer peer (stdin source, the read direction).
    cli_stdin_read_via_stream,
    // wasi:io/streams — output-stream methods.
    out_stream_write,
    out_stream_blocking_write_and_flush,
    out_stream_blocking_flush,
    out_stream_drop,
    // wasi:io/streams — input-stream methods.
    in_stream_read,
    in_stream_blocking_read,
    in_stream_drop,
    // wasi:cli/exit. `exit-with-code` is the 0.3.0 addition (arbitrary u8).
    cli_exit,
    cli_exit_with_code,
    // wasi:clocks.
    clocks_wall_now,
    clocks_monotonic_now,
    // wasi:clocks@0.3.0 (official WASI 0.3.0): `wall-clock` was RENAMED
    // `system-clock` with `instant{seconds: s64, nanoseconds: u32}`, and both
    // clocks gained `get-resolution`. The 0.3.0 async `wait-until`/`wait-for`
    // need a scheduler-wired timer waitable, not a sync trampoline (D-524).
    clocks_system_now,
    clocks_system_get_resolution,
    clocks_monotonic_get_resolution,
    // wasi:clocks/monotonic-clock@0.3.0 `wait-until`/`wait-for` — async funcs
    // served by a TIMER subtask waitable on the P3 scheduler (ADR-0205 phase A);
    // bound only under an async `canon lower`.
    clocks_wait_until,
    clocks_wait_for,
    // wasi:random.
    random_get_bytes,
    // wasi:filesystem/types — `descriptor` resource methods. A descriptor is a
    // P1 fd; these forward to the seekable-fd P1 ops (the stream-via methods
    // that MINT new stream resources land in a later chunk).
    fs_descriptor_read,
    fs_descriptor_write,
    fs_descriptor_open_at,
    fs_descriptor_sync,
    fs_descriptor_stat,
    fs_descriptor_get_type,
    fs_descriptor_drop,
    // wasi:filesystem/preopens.
    fs_get_directories,
    // wasi:io/poll — pollable resource + the poll free func. A synchronous host
    // is always ready, so these are bookkeeping-only (no P1 syscall).
    poll_pollable_ready,
    poll_pollable_block,
    poll_poll,
    // `subscribe`-style methods that mint a pollable.
    in_stream_subscribe,
    out_stream_subscribe,
    clocks_subscribe_instant,
    clocks_subscribe_duration,
    // wasi:cli/environment — a sandboxed host reports an empty environment /
    // argv and no initial cwd.
    cli_get_environment,
    cli_get_arguments,
    cli_initial_cwd,
    // wasi:cli/terminal-* — a non-tty host returns `none` (no terminal).
    cli_get_terminal_stdin,
    cli_get_terminal_stdout,
    cli_get_terminal_stderr,
    // wasi:io/streams — output-stream.check-write: an always-writable sync host
    // returns a large byte permit.
    out_stream_check_write,
    // wasi:random — free-func u64 variant.
    random_get_u64,
    // wasi:random/insecure — pseudo-random; the contract permits a non-crypto
    // source, so a host's secure fill over-satisfies it (same handler/P1 target).
    random_insecure_get_bytes,
    random_insecure_get_u64,
    // wasi:random/insecure-seed — a 128-bit hash seed (tuple<u64,u64>).
    random_insecure_seed,
    // wasi:filesystem/types — path-addressed descriptor methods (the *-at
    // family) + sync-data. Each maps onto the existing P1 path_* facility;
    // the dirfd is resolved from the descriptor handle rep at call time.
    fs_descriptor_stat_at,
    fs_descriptor_create_directory_at,
    fs_descriptor_link_at,
    fs_descriptor_readlink_at,
    fs_descriptor_remove_directory_at,
    fs_descriptor_rename_at,
    fs_descriptor_symlink_at,
    fs_descriptor_sync_data,
    fs_descriptor_unlink_file_at,
    // wasi:filesystem/types — directory iteration (the entry stream is a
    // host-modeled resource whose rep indexes per-run cursor state).
    fs_descriptor_read_directory,
    fs_dir_entry_stream_read,
    fs_dir_entry_stream_drop,
    // wasi:filesystem/types@0.3.0 (ADR-0205 phase B) — the async-func
    // descriptor surface (async-lowered by wit-bindgen guests, served
    // async-EAGER per D5) + the via-stream data plane (plain funcs, host
    // stream peers like the ADR-0190 stdio pattern but on file fds).
    fs3_stat,
    fs3_stat_at,
    fs3_get_type,
    fs3_get_flags,
    fs3_set_times,
    fs3_set_times_at,
    fs3_set_size,
    fs3_advise,
    fs3_sync,
    fs3_sync_data,
    fs3_open_at,
    fs3_create_directory_at,
    fs3_remove_directory_at,
    fs3_unlink_file_at,
    fs3_readlink_at,
    fs3_rename_at,
    fs3_symlink_at,
    fs3_link_at,
    fs3_is_same_object,
    fs3_metadata_hash,
    fs3_metadata_hash_at,
    fs3_read_via_stream,
    fs3_write_via_stream,
    fs3_append_via_stream,
    fs3_read_directory,
    // wasi:sockets@0.3.0 (ADR-0205 phase C) — the async-rebased socket
    // surface (create/bind/listen/getters sync; connect + udp send/receive +
    // resolve-addresses async-lowered; listen/send/receive mint host socket
    // stream peers).
    sock3_tcp_create,
    sock3_tcp_bind,
    sock3_tcp_connect,
    sock3_tcp_listen,
    sock3_tcp_send,
    sock3_tcp_receive,
    sock3_tcp_local_addr,
    sock3_tcp_remote_addr,
    sock3_tcp_is_listening,
    sock3_tcp_family,
    sock3_tcp_set_backlog,
    sock3_tcp_ka_enabled_get,
    sock3_tcp_ka_enabled_set,
    sock3_tcp_ka_idle_get,
    sock3_tcp_ka_idle_set,
    sock3_tcp_ka_interval_get,
    sock3_tcp_ka_interval_set,
    sock3_tcp_ka_count_get,
    sock3_tcp_ka_count_set,
    sock3_tcp_hop_get,
    sock3_tcp_hop_set,
    sock3_tcp_rcvbuf_get,
    sock3_tcp_rcvbuf_set,
    sock3_tcp_sndbuf_get,
    sock3_tcp_sndbuf_set,
    sock3_udp_create,
    sock3_udp_bind,
    sock3_udp_connect,
    sock3_udp_disconnect,
    sock3_udp_send,
    sock3_udp_receive,
    sock3_udp_local_addr,
    sock3_udp_remote_addr,
    sock3_udp_family,
    sock3_udp_hop_get,
    sock3_udp_hop_set,
    sock3_udp_rcvbuf_get,
    sock3_udp_rcvbuf_set,
    sock3_udp_sndbuf_get,
    sock3_udp_sndbuf_set,
    sock3_resolve_addresses,
    // wasi:http/types@0.3.0 (ADR-0205 phase D): the `fields` resource.
    http3_fields_new,
    http3_fields_from_list,
    http3_fields_get,
    http3_fields_has,
    http3_fields_set,
    http3_fields_delete,
    http3_fields_get_and_delete,
    http3_fields_append,
    http3_fields_copy_all,
    http3_fields_clone,
    http3_request_new,
    http3_request_get_method,
    http3_request_set_method,
    http3_request_get_pwq,
    http3_request_set_pwq,
    http3_request_get_scheme,
    http3_request_set_scheme,
    http3_request_get_authority,
    http3_request_set_authority,
    http3_request_get_options,
    http3_request_get_headers,
    http3_response_new,
    http3_response_get_status,
    http3_response_set_status,
    http3_response_get_headers,
    http3_reqopts_new,
    http3_reqopts_connect_get,
    http3_reqopts_connect_set,
    http3_reqopts_first_byte_get,
    http3_reqopts_first_byte_set,
    http3_reqopts_between_bytes_get,
    http3_reqopts_between_bytes_set,
    http3_reqopts_clone,
    http3_request_consume_body,
    http3_response_consume_body,
    http3_client_send,
    // wasi:io / wasi:cli resource drops a full wasi:cli world imports
    // directly (error / pollable / terminal handles); all route to the
    // generic drop.
    io_resource_drop,
    // wasi:filesystem/types stream-mint + get-flags methods rust-std links
    // but a CLI/TCP guest never calls — honest err(unsupported), the
    // FILESYSTEM error-code ordinal (27). rust-std's fs::read / fs::write
    // reach the via-stream pair, so a guest that reads or writes a file
    // still fails here.
    fs_stub_via_stream_offset,
    fs_stub_via_stream,
    fs_stub_get_flags,
    // wasi:filesystem/types metadata-hash + metadata-hash-at — wasi-libc fills
    // st_ino / d_ino from them, so rust-std's fs::metadata, File::metadata and
    // read_dir import BOTH; a world without the `-at` row fails to LINK, not
    // to call. Real: a hash over the P1 filestat (shared with the 0.3 host).
    fs_descriptor_metadata_hash,
    fs_descriptor_metadata_hash_at,
    // wasi:sockets (ADR-0180 Phase 1) — TCP-client subset with REAL
    // implementations; everything else is an HONEST err(not-supported)
    // stub op shared by core-signature shape (the spec's typed signal for
    // an unavailable feature, not a silent skip).
    sock_instance_network,
    sock_create_tcp,
    sock_tcp_start_bind,
    sock_tcp_finish_bind,
    sock_tcp_start_connect,
    sock_tcp_finish_connect,
    sock_tcp_subscribe,
    sock_tcp_shutdown,
    sock_tcp_is_listening,
    sock_tcp_drop,
    // ADR-0180 Phase 2: listeners + addresses.
    sock_tcp_start_listen,
    sock_tcp_finish_listen,
    sock_tcp_accept,
    sock_tcp_local_address,
    sock_tcp_remote_address,
    sock_tcp_set_backlog,
    // not-supported stub shapes: unit results (err@+1) by core arity...
    sock_stub_unit2,
    sock_stub_unit3i,
    sock_stub_unit3l,
    sock_stub_unit15,
    // ...and value results by err-payload offset (ok-arm alignment).
    sock_stub_val1,
    sock_stub_val4,
    sock_stub_val8,
    sock_stub_val15_4,
    sock_stub_resolve,
    sock_stub_recv,
    sock_stub_send,
    sock_stub_subscribe,
};

/// What P1 facility a `P2Op` ultimately drives (so the D1-2 integration maps
/// without re-parsing names).
pub const P1Target = union(enum) {
    /// Acquire/operate the std stream resource for this fd (1=stdout, 2=stderr,
    /// 0=stdin). `get-*` mint a handle; stream methods forward to fd ops.
    std_stream: u32,
    /// Forward a stream write to P1 `fd_write` on the bound fd.
    fd_write: u32,
    /// Forward a stream read to P1 `fd_read` on the bound fd.
    fd_read: u32,
    /// No P1 syscall (handle bookkeeping only — flush/drop on a std stream).
    noop,
    /// P1 `proc_exit`.
    proc_exit,
    /// P1 `clock_time_get` for the given clock id (0=realtime, 1=monotonic).
    clock_time_get: u32,
    /// P1 `clock_res_get` for the given clock id (0=realtime, 1=monotonic).
    clock_res_get: u32,
    /// P1 `random_get`.
    random_get,
    /// `descriptor` (P1 fd) ops — the fd is resolved from the handle rep at
    /// call time, so these carry no fixed fd.
    fd_pread,
    fd_pwrite,
    /// P1 `path_open` relative to a directory descriptor.
    path_open,
    fd_sync,
    fd_filestat_get,
    fd_fdstat_get,
    fd_close,
    /// P1 preopens enumeration (`fd_prestat_get` / `fd_prestat_dir_name`).
    preopens_get_directories,
    /// P1 path_* ops relative to a directory descriptor (dirfd from the
    /// handle rep at call time) + fd_datasync.
    path_filestat_get,
    path_create_directory,
    path_link,
    path_readlink,
    path_remove_directory,
    path_rename,
    path_symlink,
    fd_datasync,
    path_unlink_file,
    /// P1 `fd_readdir` (the entry-stream cursor lives host-side).
    fd_readdir,
    /// No P1 facility — the wasi:sockets host backing is `std.Io.net`
    /// (ADR-0180; `src/wasi/p2_sockets.zig`).
    sockets_host,
};

pub fn p1Target(op: P2Op) P1Target {
    return switch (op) {
        .cli_get_stdout => .{ .std_stream = 1 },
        .cli_get_stderr => .{ .std_stream = 2 },
        .cli_get_stdin => .{ .std_stream = 0 },
        .out_stream_write, .out_stream_blocking_write_and_flush => .{ .fd_write = 1 }, // fd resolved from the handle at call time
        .out_stream_blocking_flush, .out_stream_drop, .in_stream_drop => .noop,
        // WASI 0.3 write-via-stream is served by a dedicated host-peer trampoline
        // (ADR-0190), not the generic P1-target path.
        .cli_stdout_write_via_stream, .cli_stderr_write_via_stream, .cli_stdin_read_via_stream => .noop,
        .in_stream_read, .in_stream_blocking_read => .{ .fd_read = 0 },
        .cli_exit, .cli_exit_with_code => .proc_exit,
        .clocks_wall_now => .{ .clock_time_get = 0 },
        .clocks_monotonic_now => .{ .clock_time_get = 1 },
        // Timer waits read the monotonic clock but resolve via the scheduler's
        // timer waitable, not a P1 syscall at the trampoline.
        .clocks_wait_until, .clocks_wait_for => .{ .clock_time_get = 1 },
        .clocks_system_now => .{ .clock_time_get = 0 },
        .clocks_system_get_resolution => .{ .clock_res_get = 0 },
        .clocks_monotonic_get_resolution => .{ .clock_res_get = 1 },
        .random_get_bytes => .random_get,
        .fs_descriptor_read => .fd_pread,
        .fs_descriptor_write => .fd_pwrite,
        .fs_descriptor_open_at => .path_open,
        .fs_descriptor_sync => .fd_sync,
        .fs_descriptor_stat => .fd_filestat_get,
        .fs_descriptor_get_type => .fd_fdstat_get,
        .fs_descriptor_drop => .fd_close,
        .fs_get_directories => .preopens_get_directories,
        .random_get_u64 => .random_get,
        .random_insecure_get_bytes, .random_insecure_get_u64, .random_insecure_seed => .random_get,
        .fs_descriptor_stat_at => .path_filestat_get,
        .fs_descriptor_create_directory_at => .path_create_directory,
        .fs_descriptor_link_at => .path_link,
        .fs_descriptor_readlink_at => .path_readlink,
        .fs_descriptor_remove_directory_at => .path_remove_directory,
        .fs_descriptor_rename_at => .path_rename,
        .fs_descriptor_symlink_at => .path_symlink,
        .fs_descriptor_sync_data => .fd_datasync,
        .fs_descriptor_unlink_file_at => .path_unlink_file,
        .fs_descriptor_read_directory, .fs_dir_entry_stream_read => .fd_readdir,
        .fs_dir_entry_stream_drop => .noop,
        .io_resource_drop => .noop,
        .fs_stub_via_stream_offset, .fs_stub_via_stream, .fs_stub_get_flags => .noop,
        .fs_descriptor_metadata_hash => .fd_filestat_get,
        .fs_descriptor_metadata_hash_at => .path_filestat_get,
        // wasi:sockets — no P1 facility; the host backing is std.Io.net
        // (src/wasi/p2_sockets.zig), not a preview1 syscall.
        .sock_instance_network,
        .sock_create_tcp,
        .sock_tcp_start_bind,
        .sock_tcp_finish_bind,
        .sock_tcp_start_connect,
        .sock_tcp_finish_connect,
        .sock_tcp_subscribe,
        .sock_tcp_shutdown,
        .sock_tcp_is_listening,
        .sock_tcp_drop,
        .sock_tcp_start_listen,
        .sock_tcp_finish_listen,
        .sock_tcp_accept,
        .sock_tcp_local_address,
        .sock_tcp_remote_address,
        .sock_tcp_set_backlog,
        .sock_stub_unit2,
        .sock_stub_unit3i,
        .sock_stub_unit3l,
        .sock_stub_unit15,
        .sock_stub_val1,
        .sock_stub_val4,
        .sock_stub_val8,
        .sock_stub_val15_4,
        .sock_stub_resolve,
        .sock_stub_recv,
        .sock_stub_send,
        .sock_stub_subscribe,
        => .sockets_host,
        // wasi:filesystem@0.3.0 (ADR-0205 phase B): bound directly to the fs3
        // trampolines (async-eager / host stream peers), not via a P1Target row.
        .fs3_stat,
        .fs3_stat_at,
        .fs3_get_type,
        .fs3_get_flags,
        .fs3_set_times,
        .fs3_set_times_at,
        .fs3_set_size,
        .fs3_advise,
        .fs3_sync,
        .fs3_sync_data,
        .fs3_open_at,
        .fs3_create_directory_at,
        .fs3_remove_directory_at,
        .fs3_unlink_file_at,
        .fs3_readlink_at,
        .fs3_rename_at,
        .fs3_symlink_at,
        .fs3_link_at,
        .fs3_is_same_object,
        .fs3_metadata_hash,
        .fs3_metadata_hash_at,
        .fs3_read_via_stream,
        .fs3_write_via_stream,
        .fs3_append_via_stream,
        .fs3_read_directory,
        .sock3_tcp_create,
        .sock3_tcp_bind,
        .sock3_tcp_connect,
        .sock3_tcp_listen,
        .sock3_tcp_send,
        .sock3_tcp_receive,
        .sock3_tcp_local_addr,
        .sock3_tcp_remote_addr,
        .sock3_tcp_is_listening,
        .sock3_tcp_family,
        .sock3_tcp_set_backlog,
        .sock3_tcp_ka_enabled_get,
        .sock3_tcp_ka_enabled_set,
        .sock3_tcp_ka_idle_get,
        .sock3_tcp_ka_idle_set,
        .sock3_tcp_ka_interval_get,
        .sock3_tcp_ka_interval_set,
        .sock3_tcp_ka_count_get,
        .sock3_tcp_ka_count_set,
        .sock3_tcp_hop_get,
        .sock3_tcp_hop_set,
        .sock3_tcp_rcvbuf_get,
        .sock3_tcp_rcvbuf_set,
        .sock3_tcp_sndbuf_get,
        .sock3_tcp_sndbuf_set,
        .sock3_udp_create,
        .sock3_udp_bind,
        .sock3_udp_connect,
        .sock3_udp_disconnect,
        .sock3_udp_send,
        .sock3_udp_receive,
        .sock3_udp_local_addr,
        .sock3_udp_remote_addr,
        .sock3_udp_family,
        .sock3_udp_hop_get,
        .sock3_udp_hop_set,
        .sock3_udp_rcvbuf_get,
        .sock3_udp_rcvbuf_set,
        .sock3_udp_sndbuf_get,
        .sock3_udp_sndbuf_set,
        .sock3_resolve_addresses,
        .http3_fields_new,
        .http3_fields_from_list,
        .http3_fields_get,
        .http3_fields_has,
        .http3_fields_set,
        .http3_fields_delete,
        .http3_fields_get_and_delete,
        .http3_fields_append,
        .http3_fields_copy_all,
        .http3_fields_clone,
        .http3_request_new,
        .http3_request_get_method,
        .http3_request_set_method,
        .http3_request_get_pwq,
        .http3_request_set_pwq,
        .http3_request_get_scheme,
        .http3_request_set_scheme,
        .http3_request_get_authority,
        .http3_request_set_authority,
        .http3_request_get_options,
        .http3_request_get_headers,
        .http3_response_new,
        .http3_response_get_status,
        .http3_response_set_status,
        .http3_response_get_headers,
        .http3_reqopts_new,
        .http3_reqopts_connect_get,
        .http3_reqopts_connect_set,
        .http3_reqopts_first_byte_get,
        .http3_reqopts_first_byte_set,
        .http3_reqopts_between_bytes_get,
        .http3_reqopts_between_bytes_set,
        .http3_reqopts_clone,
        .http3_request_consume_body,
        .http3_response_consume_body,
        .http3_client_send,
        => .noop,
        // Poll + subscribe: no P1 facility (always-ready host bookkeeping).
        .poll_pollable_ready,
        .poll_pollable_block,
        .poll_poll,
        .in_stream_subscribe,
        .out_stream_subscribe,
        .clocks_subscribe_instant,
        .clocks_subscribe_duration,
        .cli_get_environment,
        .cli_get_arguments,
        .cli_initial_cwd,
        .cli_get_terminal_stdin,
        .cli_get_terminal_stdout,
        .cli_get_terminal_stderr,
        .out_stream_check_write,
        => .noop,
    };
}

/// True if `interface` (e.g. `"wasi:cli/stdout"`, possibly with an `@version`
/// already stripped by the importname decoder) is a WASI P2 interface the
/// adapter handles.
pub fn isWasiP2Interface(interface: []const u8) bool {
    return std.mem.startsWith(u8, interface, "wasi:");
}

const Entry = struct { iface: []const u8, func: []const u8, op: P2Op, gens: Gens = .{} };

/// The P2 (interface, func) → `P2Op` table (CLI subset). Method names follow
/// the WIT canonical encoding `[method]output-stream.write` etc.; we match the
/// trailing `.<method>` for resource methods and the bare func for free funcs.
const table = [_]Entry{
    .{ .iface = "wasi:cli/stdout", .func = "get-stdout", .op = .cli_get_stdout },
    .{ .iface = "wasi:cli/stderr", .func = "get-stderr", .op = .cli_get_stderr },
    .{ .iface = "wasi:cli/stdin", .func = "get-stdin", .op = .cli_get_stdin },
    .{ .iface = "wasi:cli/exit", .func = "exit", .op = .cli_exit },
    .{ .iface = "wasi:cli/exit", .func = "exit-with-code", .op = .cli_exit_with_code },
    // WASI 0.3 (Preview 3) async stdio: the host becomes a stream peer
    // (ADR-0190). write-via-stream(stream<u8>) -> future<result<_,error-code>>.
    .{ .iface = "wasi:cli/stdout", .func = "write-via-stream", .op = .cli_stdout_write_via_stream },
    .{ .iface = "wasi:cli/stderr", .func = "write-via-stream", .op = .cli_stderr_write_via_stream },
    .{ .iface = "wasi:cli/stdin", .func = "read-via-stream", .op = .cli_stdin_read_via_stream },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.write", .op = .out_stream_write },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.blocking-write-and-flush", .op = .out_stream_blocking_write_and_flush },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.blocking-flush", .op = .out_stream_blocking_flush },
    .{ .iface = "wasi:io/streams", .func = "[resource-drop]output-stream", .op = .out_stream_drop },
    .{ .iface = "wasi:io/streams", .func = "[method]input-stream.read", .op = .in_stream_read },
    .{ .iface = "wasi:io/streams", .func = "[method]input-stream.blocking-read", .op = .in_stream_blocking_read },
    .{ .iface = "wasi:io/streams", .func = "[resource-drop]input-stream", .op = .in_stream_drop },
    .{ .iface = "wasi:clocks/wall-clock", .func = "now", .op = .clocks_wall_now },
    .{ .iface = "wasi:clocks/monotonic-clock", .func = "now", .op = .clocks_monotonic_now },
    // Official WASI 0.3.0 clock surface (renamed/extended vs the 0.2 WIT).
    .{ .iface = "wasi:clocks/system-clock", .func = "now", .op = .clocks_system_now },
    .{ .iface = "wasi:clocks/system-clock", .func = "get-resolution", .op = .clocks_system_get_resolution },
    .{ .iface = "wasi:clocks/monotonic-clock", .func = "get-resolution", .op = .clocks_monotonic_get_resolution },
    .{ .iface = "wasi:clocks/monotonic-clock", .func = "wait-until", .op = .clocks_wait_until },
    .{ .iface = "wasi:clocks/monotonic-clock", .func = "wait-for", .op = .clocks_wait_for },
    .{ .iface = "wasi:random/random", .func = "get-random-bytes", .op = .random_get_bytes },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.read", .op = .fs_descriptor_read, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.write", .op = .fs_descriptor_write, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.open-at", .op = .fs_descriptor_open_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.sync", .op = .fs_descriptor_sync, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.stat", .op = .fs_descriptor_stat, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.get-type", .op = .fs_descriptor_get_type, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[resource-drop]descriptor", .op = .fs_descriptor_drop },
    .{ .iface = "wasi:filesystem/preopens", .func = "get-directories", .op = .fs_get_directories },
    .{ .iface = "wasi:io/poll", .func = "[method]pollable.ready", .op = .poll_pollable_ready },
    .{ .iface = "wasi:io/poll", .func = "[method]pollable.block", .op = .poll_pollable_block },
    .{ .iface = "wasi:io/poll", .func = "poll", .op = .poll_poll },
    .{ .iface = "wasi:io/streams", .func = "[method]input-stream.subscribe", .op = .in_stream_subscribe },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.subscribe", .op = .out_stream_subscribe },
    .{ .iface = "wasi:clocks/monotonic-clock", .func = "subscribe-instant", .op = .clocks_subscribe_instant },
    .{ .iface = "wasi:clocks/monotonic-clock", .func = "subscribe-duration", .op = .clocks_subscribe_duration },
    .{ .iface = "wasi:cli/environment", .func = "get-environment", .op = .cli_get_environment },
    .{ .iface = "wasi:cli/environment", .func = "get-arguments", .op = .cli_get_arguments },
    .{ .iface = "wasi:cli/environment", .func = "initial-cwd", .op = .cli_initial_cwd },
    // 0.3.0 renamed `initial-cwd` → `get-initial-cwd` (same shape).
    .{ .iface = "wasi:cli/environment", .func = "get-initial-cwd", .op = .cli_initial_cwd },
    .{ .iface = "wasi:cli/terminal-stdin", .func = "get-terminal-stdin", .op = .cli_get_terminal_stdin },
    .{ .iface = "wasi:cli/terminal-stdout", .func = "get-terminal-stdout", .op = .cli_get_terminal_stdout },
    .{ .iface = "wasi:cli/terminal-stderr", .func = "get-terminal-stderr", .op = .cli_get_terminal_stderr },
    .{ .iface = "wasi:io/streams", .func = "[method]output-stream.check-write", .op = .out_stream_check_write },
    .{ .iface = "wasi:random/random", .func = "get-random-u64", .op = .random_get_u64 },
    .{ .iface = "wasi:random/insecure", .func = "get-insecure-random-bytes", .op = .random_insecure_get_bytes },
    .{ .iface = "wasi:random/insecure", .func = "get-insecure-random-u64", .op = .random_insecure_get_u64 },
    .{ .iface = "wasi:random/insecure-seed", .func = "insecure-seed", .op = .random_insecure_seed },
    // 0.3.0 renamed `insecure-seed` → `get-insecure-seed` (same shape).
    .{ .iface = "wasi:random/insecure-seed", .func = "get-insecure-seed", .op = .random_insecure_seed },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.stat-at", .op = .fs_descriptor_stat_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.create-directory-at", .op = .fs_descriptor_create_directory_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.link-at", .op = .fs_descriptor_link_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.readlink-at", .op = .fs_descriptor_readlink_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.remove-directory-at", .op = .fs_descriptor_remove_directory_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.rename-at", .op = .fs_descriptor_rename_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.symlink-at", .op = .fs_descriptor_symlink_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.sync-data", .op = .fs_descriptor_sync_data, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.unlink-file-at", .op = .fs_descriptor_unlink_file_at, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.read-directory", .op = .fs_descriptor_read_directory, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]directory-entry-stream.read-directory-entry", .op = .fs_dir_entry_stream_read },
    .{ .iface = "wasi:filesystem/types", .func = "[resource-drop]directory-entry-stream", .op = .fs_dir_entry_stream_drop },

    .{ .iface = "wasi:io/error", .func = "[resource-drop]error", .op = .io_resource_drop },
    .{ .iface = "wasi:io/poll", .func = "[resource-drop]pollable", .op = .io_resource_drop },
    .{ .iface = "wasi:cli/terminal-input", .func = "[resource-drop]terminal-input", .op = .io_resource_drop },
    .{ .iface = "wasi:cli/terminal-output", .func = "[resource-drop]terminal-output", .op = .io_resource_drop },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.read-via-stream", .op = .fs_stub_via_stream_offset, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.write-via-stream", .op = .fs_stub_via_stream_offset, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.append-via-stream", .op = .fs_stub_via_stream, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.get-flags", .op = .fs_stub_get_flags, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.metadata-hash", .op = .fs_descriptor_metadata_hash, .gens = p2_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.metadata-hash-at", .op = .fs_descriptor_metadata_hash_at, .gens = p2_only },
    .{ .iface = "wasi:sockets/instance-network", .func = "instance-network", .op = .sock_instance_network },
    .{ .iface = "wasi:sockets/tcp-create-socket", .func = "create-tcp-socket", .op = .sock_create_tcp },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.start-bind", .op = .sock_tcp_start_bind },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.finish-bind", .op = .sock_tcp_finish_bind },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.start-connect", .op = .sock_tcp_start_connect },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.finish-connect", .op = .sock_tcp_finish_connect },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.subscribe", .op = .sock_tcp_subscribe },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.shutdown", .op = .sock_tcp_shutdown },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.is-listening", .op = .sock_tcp_is_listening },
    .{ .iface = "wasi:sockets/tcp", .func = "[resource-drop]tcp-socket", .op = .sock_tcp_drop },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.accept", .op = .sock_tcp_accept },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.start-listen", .op = .sock_tcp_start_listen },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.finish-listen", .op = .sock_tcp_finish_listen },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.hop-limit", .op = .sock_stub_val1 },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.keep-alive-enabled", .op = .sock_stub_val1 },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.keep-alive-count", .op = .sock_stub_val4 },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.keep-alive-idle-time", .op = .sock_stub_val8 },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.keep-alive-interval", .op = .sock_stub_val8 },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.receive-buffer-size", .op = .sock_stub_val8 },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.send-buffer-size", .op = .sock_stub_val8 },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.local-address", .op = .sock_tcp_local_address },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.remote-address", .op = .sock_tcp_remote_address },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-hop-limit", .op = .sock_stub_unit3i },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-keep-alive-enabled", .op = .sock_stub_unit3i },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-keep-alive-count", .op = .sock_stub_unit3i },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-keep-alive-idle-time", .op = .sock_stub_unit3l },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-keep-alive-interval", .op = .sock_stub_unit3l },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-listen-backlog-size", .op = .sock_tcp_set_backlog, .gens = p2_only },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-receive-buffer-size", .op = .sock_stub_unit3l },
    .{ .iface = "wasi:sockets/tcp", .func = "[method]tcp-socket.set-send-buffer-size", .op = .sock_stub_unit3l },
    .{ .iface = "wasi:sockets/udp-create-socket", .func = "create-udp-socket", .op = .sock_stub_val4 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.start-bind", .op = .sock_stub_unit15 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.finish-bind", .op = .sock_stub_unit2 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.stream", .op = .sock_stub_val15_4 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.local-address", .op = .sock_stub_val4 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.remote-address", .op = .sock_stub_val4 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.receive-buffer-size", .op = .sock_stub_val8 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.send-buffer-size", .op = .sock_stub_val8 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.set-receive-buffer-size", .op = .sock_stub_unit3l },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.set-send-buffer-size", .op = .sock_stub_unit3l },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.unicast-hop-limit", .op = .sock_stub_val1 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.set-unicast-hop-limit", .op = .sock_stub_unit3i },
    .{ .iface = "wasi:sockets/udp", .func = "[method]udp-socket.subscribe", .op = .sock_stub_subscribe },
    .{ .iface = "wasi:sockets/udp", .func = "[resource-drop]udp-socket", .op = .sock_tcp_drop },
    .{ .iface = "wasi:sockets/udp", .func = "[method]incoming-datagram-stream.receive", .op = .sock_stub_recv },
    .{ .iface = "wasi:sockets/udp", .func = "[method]incoming-datagram-stream.subscribe", .op = .sock_stub_subscribe },
    .{ .iface = "wasi:sockets/udp", .func = "[resource-drop]incoming-datagram-stream", .op = .sock_tcp_drop },
    .{ .iface = "wasi:sockets/udp", .func = "[method]outgoing-datagram-stream.check-send", .op = .sock_stub_val8 },
    .{ .iface = "wasi:sockets/udp", .func = "[method]outgoing-datagram-stream.send", .op = .sock_stub_send },
    .{ .iface = "wasi:sockets/udp", .func = "[method]outgoing-datagram-stream.subscribe", .op = .sock_stub_subscribe },
    .{ .iface = "wasi:sockets/udp", .func = "[resource-drop]outgoing-datagram-stream", .op = .sock_tcp_drop },
    .{ .iface = "wasi:sockets/ip-name-lookup", .func = "resolve-addresses", .op = .sock_stub_resolve, .gens = p2_only },
    .{ .iface = "wasi:sockets/ip-name-lookup", .func = "[method]resolve-address-stream.resolve-next-address", .op = .sock_stub_val4 },
    .{ .iface = "wasi:sockets/ip-name-lookup", .func = "[method]resolve-address-stream.subscribe", .op = .sock_stub_subscribe },
    .{ .iface = "wasi:sockets/ip-name-lookup", .func = "[resource-drop]resolve-address-stream", .op = .sock_tcp_drop },

    // wasi:filesystem/types@0.3.0 rows (ADR-0205 phase B) — the 0.3 shapes.
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.stat", .op = .fs3_stat, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.stat-at", .op = .fs3_stat_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.get-type", .op = .fs3_get_type, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.get-flags", .op = .fs3_get_flags, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.set-times", .op = .fs3_set_times, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.set-times-at", .op = .fs3_set_times_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.set-size", .op = .fs3_set_size, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.advise", .op = .fs3_advise, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.sync", .op = .fs3_sync, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.sync-data", .op = .fs3_sync_data, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.open-at", .op = .fs3_open_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.create-directory-at", .op = .fs3_create_directory_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.remove-directory-at", .op = .fs3_remove_directory_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.unlink-file-at", .op = .fs3_unlink_file_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.readlink-at", .op = .fs3_readlink_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.rename-at", .op = .fs3_rename_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.symlink-at", .op = .fs3_symlink_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.link-at", .op = .fs3_link_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.is-same-object", .op = .fs3_is_same_object, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.metadata-hash", .op = .fs3_metadata_hash, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.metadata-hash-at", .op = .fs3_metadata_hash_at, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.read-via-stream", .op = .fs3_read_via_stream, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.write-via-stream", .op = .fs3_write_via_stream, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.append-via-stream", .op = .fs3_append_via_stream, .gens = p3_only },
    .{ .iface = "wasi:filesystem/types", .func = "[method]descriptor.read-directory", .op = .fs3_read_directory, .gens = p3_only },
    // wasi:sockets/types@0.3.0 rows (ADR-0205 phase C). The 0.3 sockets WIT
    // moved everything into ONE `types` interface (0.2's tcp/udp/ip-name-lookup
    // splits collapsed), so most names cannot collide with 0.2 rows.
    .{ .iface = "wasi:sockets/types", .func = "[static]tcp-socket.create", .op = .sock3_tcp_create, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.bind", .op = .sock3_tcp_bind, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.connect", .op = .sock3_tcp_connect, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.listen", .op = .sock3_tcp_listen, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.send", .op = .sock3_tcp_send, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.receive", .op = .sock3_tcp_receive, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-local-address", .op = .sock3_tcp_local_addr, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-remote-address", .op = .sock3_tcp_remote_addr, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-is-listening", .op = .sock3_tcp_is_listening, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-address-family", .op = .sock3_tcp_family, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-listen-backlog-size", .op = .sock3_tcp_set_backlog, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-keep-alive-enabled", .op = .sock3_tcp_ka_enabled_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-keep-alive-enabled", .op = .sock3_tcp_ka_enabled_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-keep-alive-idle-time", .op = .sock3_tcp_ka_idle_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-keep-alive-idle-time", .op = .sock3_tcp_ka_idle_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-keep-alive-interval", .op = .sock3_tcp_ka_interval_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-keep-alive-interval", .op = .sock3_tcp_ka_interval_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-keep-alive-count", .op = .sock3_tcp_ka_count_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-keep-alive-count", .op = .sock3_tcp_ka_count_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-hop-limit", .op = .sock3_tcp_hop_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-hop-limit", .op = .sock3_tcp_hop_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-receive-buffer-size", .op = .sock3_tcp_rcvbuf_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-receive-buffer-size", .op = .sock3_tcp_rcvbuf_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.get-send-buffer-size", .op = .sock3_tcp_sndbuf_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]tcp-socket.set-send-buffer-size", .op = .sock3_tcp_sndbuf_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[resource-drop]tcp-socket", .op = .sock_tcp_drop, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[static]udp-socket.create", .op = .sock3_udp_create, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.bind", .op = .sock3_udp_bind, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.connect", .op = .sock3_udp_connect, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.disconnect", .op = .sock3_udp_disconnect, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.send", .op = .sock3_udp_send, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.receive", .op = .sock3_udp_receive, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.get-local-address", .op = .sock3_udp_local_addr, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.get-remote-address", .op = .sock3_udp_remote_addr, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.get-address-family", .op = .sock3_udp_family, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.get-unicast-hop-limit", .op = .sock3_udp_hop_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.set-unicast-hop-limit", .op = .sock3_udp_hop_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.get-receive-buffer-size", .op = .sock3_udp_rcvbuf_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.set-receive-buffer-size", .op = .sock3_udp_rcvbuf_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.get-send-buffer-size", .op = .sock3_udp_sndbuf_get, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[method]udp-socket.set-send-buffer-size", .op = .sock3_udp_sndbuf_set, .gens = p3_only },
    .{ .iface = "wasi:sockets/types", .func = "[resource-drop]udp-socket", .op = .io_resource_drop, .gens = p3_only },
    .{ .iface = "wasi:sockets/ip-name-lookup", .func = "resolve-addresses", .op = .sock3_resolve_addresses, .gens = p3_only },
    // wasi:http/types@0.3.0 rows (ADR-0205 phase D) — the `fields` resource.
    .{ .iface = "wasi:http/types", .func = "[constructor]fields", .op = .http3_fields_new, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[static]fields.from-list", .op = .http3_fields_from_list, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.get", .op = .http3_fields_get, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.has", .op = .http3_fields_has, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.set", .op = .http3_fields_set, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.delete", .op = .http3_fields_delete, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.get-and-delete", .op = .http3_fields_get_and_delete, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.append", .op = .http3_fields_append, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.copy-all", .op = .http3_fields_copy_all, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]fields.clone", .op = .http3_fields_clone, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[resource-drop]fields", .op = .io_resource_drop, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[static]request.new", .op = .http3_request_new, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.get-method", .op = .http3_request_get_method, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.set-method", .op = .http3_request_set_method, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.get-path-with-query", .op = .http3_request_get_pwq, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.set-path-with-query", .op = .http3_request_set_pwq, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.get-scheme", .op = .http3_request_get_scheme, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.set-scheme", .op = .http3_request_set_scheme, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.get-authority", .op = .http3_request_get_authority, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.set-authority", .op = .http3_request_set_authority, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.get-options", .op = .http3_request_get_options, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request.get-headers", .op = .http3_request_get_headers, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[static]request.consume-body", .op = .http3_request_consume_body, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[resource-drop]request", .op = .io_resource_drop, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[static]response.new", .op = .http3_response_new, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]response.get-status-code", .op = .http3_response_get_status, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]response.set-status-code", .op = .http3_response_set_status, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]response.get-headers", .op = .http3_response_get_headers, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[resource-drop]response", .op = .io_resource_drop, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[constructor]request-options", .op = .http3_reqopts_new, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request-options.get-connect-timeout", .op = .http3_reqopts_connect_get, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request-options.set-connect-timeout", .op = .http3_reqopts_connect_set, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request-options.get-first-byte-timeout", .op = .http3_reqopts_first_byte_get, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request-options.set-first-byte-timeout", .op = .http3_reqopts_first_byte_set, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request-options.get-between-bytes-timeout", .op = .http3_reqopts_between_bytes_get, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request-options.set-between-bytes-timeout", .op = .http3_reqopts_between_bytes_set, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[method]request-options.clone", .op = .http3_reqopts_clone, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[resource-drop]request-options", .op = .io_resource_drop, .gens = p3_only },
    .{ .iface = "wasi:http/types", .func = "[static]response.consume-body", .op = .http3_response_consume_body, .gens = p3_only },
    .{ .iface = "wasi:http/client", .func = "send", .op = .http3_client_send, .gens = p3_only },
};

/// Classify a WASI import `(interface, func, generation)` → the `P2Op` it maps
/// to, or null if the adapter does not (yet) handle it. `gen` (from the
/// import's `@version`, ADR-0205 D1) filters generation-specific rows;
/// `.any` matches every row (unversioned imports, legacy callers).
pub fn classifyImport(interface: []const u8, func: []const u8, gen: Gen) ?P2Op {
    for (table) |e| {
        if (!std.mem.eql(u8, e.iface, interface) or !std.mem.eql(u8, e.func, func)) continue;
        const ok = switch (gen) {
            .any => true,
            .p2 => e.gens.p2,
            .p3 => e.gens.p3,
        };
        if (ok) return e.op;
    }
    return null;
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "classify: the stdout print path" {
    try testing.expectEqual(P2Op.cli_get_stdout, classifyImport("wasi:cli/stdout", "get-stdout", .any).?);
    try testing.expectEqual(
        P2Op.out_stream_blocking_write_and_flush,
        classifyImport("wasi:io/streams", "[method]output-stream.blocking-write-and-flush", .any).?,
    );
    try testing.expectEqual(P2Op.out_stream_drop, classifyImport("wasi:io/streams", "[resource-drop]output-stream", .any).?);
}

test "p1Target: print path maps to fd_write(1) + std stream" {
    try testing.expectEqual(@as(u32, 1), p1Target(.cli_get_stdout).std_stream);
    try testing.expectEqual(@as(u32, 2), p1Target(.cli_get_stderr).std_stream);
    try testing.expectEqual(@as(u32, 1), p1Target(.out_stream_blocking_write_and_flush).fd_write);
    try testing.expectEqual(P1Target.noop, p1Target(.out_stream_drop));
    try testing.expectEqual(P1Target.proc_exit, p1Target(.cli_exit));
}

test "p1Target: clocks + random" {
    try testing.expectEqual(@as(u32, 0), p1Target(.clocks_wall_now).clock_time_get);
    try testing.expectEqual(@as(u32, 1), p1Target(.clocks_monotonic_now).clock_time_get);
    try testing.expectEqual(P1Target.random_get, p1Target(.random_get_bytes));
    // Official WASI 0.3.0 clock surface (system-clock = realtime id 0).
    try testing.expectEqual(@as(u32, 0), p1Target(.clocks_system_now).clock_time_get);
    try testing.expectEqual(@as(u32, 0), p1Target(.clocks_system_get_resolution).clock_res_get);
    try testing.expectEqual(@as(u32, 1), p1Target(.clocks_monotonic_get_resolution).clock_res_get);
}

test "classify: official 0.3.0 system-clock + get-resolution (version-stripped iface names)" {
    try testing.expectEqual(P2Op.clocks_system_now, classifyImport("wasi:clocks/system-clock", "now", .any).?);
    try testing.expectEqual(P2Op.clocks_system_get_resolution, classifyImport("wasi:clocks/system-clock", "get-resolution", .any).?);
    try testing.expectEqual(P2Op.clocks_monotonic_get_resolution, classifyImport("wasi:clocks/monotonic-clock", "get-resolution", .any).?);
}

test "classify: wasi:io/poll + subscribe methods" {
    try testing.expectEqual(P2Op.poll_poll, classifyImport("wasi:io/poll", "poll", .any).?);
    try testing.expectEqual(P2Op.poll_pollable_ready, classifyImport("wasi:io/poll", "[method]pollable.ready", .any).?);
    try testing.expectEqual(P2Op.poll_pollable_block, classifyImport("wasi:io/poll", "[method]pollable.block", .any).?);
    try testing.expectEqual(P2Op.in_stream_subscribe, classifyImport("wasi:io/streams", "[method]input-stream.subscribe", .any).?);
    try testing.expectEqual(P2Op.clocks_subscribe_duration, classifyImport("wasi:clocks/monotonic-clock", "subscribe-duration", .any).?);
    try testing.expectEqual(P1Target.noop, p1Target(.poll_poll));
}

test "classify: 0.2 metadata-hash + metadata-hash-at are real P2 ops, distinct from the 0.3 rows" {
    try testing.expectEqual(P2Op.fs_descriptor_metadata_hash, classifyImport("wasi:filesystem/types", "[method]descriptor.metadata-hash", .p2).?);
    try testing.expectEqual(P2Op.fs_descriptor_metadata_hash_at, classifyImport("wasi:filesystem/types", "[method]descriptor.metadata-hash-at", .p2).?);
    try testing.expectEqual(P2Op.fs3_metadata_hash_at, classifyImport("wasi:filesystem/types", "[method]descriptor.metadata-hash-at", .p3).?);
    try testing.expectEqual(P1Target.fd_filestat_get, p1Target(.fs_descriptor_metadata_hash));
    try testing.expectEqual(P1Target.path_filestat_get, p1Target(.fs_descriptor_metadata_hash_at));
}

test "classify: cli/environment + terminal + check-write (E2)" {
    try testing.expectEqual(P2Op.cli_get_environment, classifyImport("wasi:cli/environment", "get-environment", .any).?);
    try testing.expectEqual(P2Op.cli_initial_cwd, classifyImport("wasi:cli/environment", "initial-cwd", .any).?);
    try testing.expectEqual(P2Op.cli_get_terminal_stdout, classifyImport("wasi:cli/terminal-stdout", "get-terminal-stdout", .any).?);
    try testing.expectEqual(P2Op.out_stream_check_write, classifyImport("wasi:io/streams", "[method]output-stream.check-write", .any).?);
    try testing.expectEqual(P1Target.noop, p1Target(.cli_get_environment));
}

test "D-307: errno → P2 filesystem error-code ordinals" {
    // Spec-pinned ordinals (wasi:filesystem/types error-code declaration order).
    try testing.expectEqual(P2ErrorCode.no_entry, errnoToP2ErrorCode(.noent));
    try testing.expectEqual(@as(u8, 20), @intFromEnum(errnoToP2ErrorCode(.noent)));
    try testing.expectEqual(P2ErrorCode.access, errnoToP2ErrorCode(.acces));
    try testing.expectEqual(P2ErrorCode.bad_descriptor, errnoToP2ErrorCode(.badf));
    try testing.expectEqual(P2ErrorCode.exist, errnoToP2ErrorCode(.exist));
    try testing.expectEqual(P2ErrorCode.is_directory, errnoToP2ErrorCode(.isdir));
    try testing.expectEqual(P2ErrorCode.not_directory, errnoToP2ErrorCode(.notdir));
    // Ordinals from `wasm-tools component wit` on a rustc 1.97 wasm32-wasip2
    // guest (wasi:filesystem/types@0.2.0), spot-checked at the ends and
    // around `no-lock` / `no-tty`, which the P1 map never names.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(P2ErrorCode.access));
    try testing.expectEqual(@as(u8, 21), @intFromEnum(P2ErrorCode.no_lock));
    try testing.expectEqual(@as(u8, 27), @intFromEnum(P2ErrorCode.unsupported));
    try testing.expectEqual(@as(u8, 28), @intFromEnum(P2ErrorCode.no_tty));
    try testing.expectEqual(@as(u8, 36), @intFromEnum(P2ErrorCode.cross_device));
    try testing.expectEqual(37, @typeInfo(P2ErrorCode).@"enum".fields.len);
    // Errnos with no P2 counterpart fall back to `io`.
    try testing.expectEqual(P2ErrorCode.io, errnoToP2ErrorCode(.connreset));
}

test "classify: filesystem descriptor resource ops (wasi:filesystem/types)" {
    try testing.expectEqual(P2Op.fs_descriptor_read, classifyImport("wasi:filesystem/types", "[method]descriptor.read", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_write, classifyImport("wasi:filesystem/types", "[method]descriptor.write", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_open_at, classifyImport("wasi:filesystem/types", "[method]descriptor.open-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_sync, classifyImport("wasi:filesystem/types", "[method]descriptor.sync", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_stat, classifyImport("wasi:filesystem/types", "[method]descriptor.stat", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_get_type, classifyImport("wasi:filesystem/types", "[method]descriptor.get-type", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_drop, classifyImport("wasi:filesystem/types", "[resource-drop]descriptor", .any).?);
    try testing.expectEqual(P2Op.fs_get_directories, classifyImport("wasi:filesystem/preopens", "get-directories", .any).?);
}

test "p1Target: descriptor ops map to fd syscalls (fd from the handle rep at call time)" {
    try testing.expectEqual(P1Target.fd_pread, p1Target(.fs_descriptor_read));
    try testing.expectEqual(P1Target.fd_pwrite, p1Target(.fs_descriptor_write));
    try testing.expectEqual(P1Target.path_open, p1Target(.fs_descriptor_open_at));
    try testing.expectEqual(P1Target.fd_sync, p1Target(.fs_descriptor_sync));
    try testing.expectEqual(P1Target.fd_filestat_get, p1Target(.fs_descriptor_stat));
    try testing.expectEqual(P1Target.fd_fdstat_get, p1Target(.fs_descriptor_get_type));
    try testing.expectEqual(P1Target.fd_close, p1Target(.fs_descriptor_drop));
    try testing.expectEqual(P1Target.preopens_get_directories, p1Target(.fs_get_directories));
}

test "classify: wasi:random/insecure resolves to the insecure ops (secure-fill backed)" {
    try testing.expectEqual(P2Op.random_insecure_get_bytes, classifyImport("wasi:random/insecure", "get-insecure-random-bytes", .any).?);
    try testing.expectEqual(P2Op.random_insecure_get_u64, classifyImport("wasi:random/insecure", "get-insecure-random-u64", .any).?);
    try testing.expectEqual(P2Op.random_insecure_seed, classifyImport("wasi:random/insecure-seed", "insecure-seed", .any).?);
    try testing.expectEqual(P1Target.random_get, p1Target(.random_insecure_get_bytes));
}

test "classify: path-addressed descriptor methods + random u64 (E2 Go world)" {
    try testing.expectEqual(P2Op.random_get_u64, classifyImport("wasi:random/random", "get-random-u64", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_stat_at, classifyImport("wasi:filesystem/types", "[method]descriptor.stat-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_create_directory_at, classifyImport("wasi:filesystem/types", "[method]descriptor.create-directory-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_link_at, classifyImport("wasi:filesystem/types", "[method]descriptor.link-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_readlink_at, classifyImport("wasi:filesystem/types", "[method]descriptor.readlink-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_remove_directory_at, classifyImport("wasi:filesystem/types", "[method]descriptor.remove-directory-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_rename_at, classifyImport("wasi:filesystem/types", "[method]descriptor.rename-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_symlink_at, classifyImport("wasi:filesystem/types", "[method]descriptor.symlink-at", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_sync_data, classifyImport("wasi:filesystem/types", "[method]descriptor.sync-data", .any).?);
    try testing.expectEqual(P2Op.fs_descriptor_unlink_file_at, classifyImport("wasi:filesystem/types", "[method]descriptor.unlink-file-at", .any).?);
    try testing.expectEqual(P1Target.path_filestat_get, p1Target(.fs_descriptor_stat_at));
    try testing.expectEqual(P1Target.path_create_directory, p1Target(.fs_descriptor_create_directory_at));
    try testing.expectEqual(P1Target.path_rename, p1Target(.fs_descriptor_rename_at));
    try testing.expectEqual(P1Target.fd_datasync, p1Target(.fs_descriptor_sync_data));
    try testing.expectEqual(P1Target.random_get, p1Target(.random_get_u64));
}

test "classify: unknown interface/func → null; isWasiP2Interface" {
    try testing.expectEqual(@as(?P2Op, null), classifyImport("wasi:sockets/tcp", "connect", .any));
    try testing.expectEqual(@as(?P2Op, null), classifyImport("env", "foo", .any));
    try testing.expect(isWasiP2Interface("wasi:cli/run"));
    try testing.expect(!isWasiP2Interface("env"));
}

test "classify: official 0.3.0 additions (ADR-0205 phase A)" {
    try testing.expectEqual(P2Op.clocks_wait_until, classifyImport("wasi:clocks/monotonic-clock", "wait-until", .any).?);
    try testing.expectEqual(P2Op.clocks_wait_for, classifyImport("wasi:clocks/monotonic-clock", "wait-for", .any).?);
    try testing.expectEqual(P2Op.cli_exit_with_code, classifyImport("wasi:cli/exit", "exit-with-code", .any).?);
    // 0.3.0 renames of shape-identical funcs share the 0.2 handlers.
    try testing.expectEqual(P2Op.cli_initial_cwd, classifyImport("wasi:cli/environment", "get-initial-cwd", .any).?);
    try testing.expectEqual(P2Op.random_insecure_seed, classifyImport("wasi:random/insecure-seed", "get-insecure-seed", .any).?);
}
