//! Which realloc a `canon lower` names.
//!
//! A lowered host import that returns a list or string must place the
//! result in guest memory through the realloc named by that lower's own
//! `(realloc ...)` canonopt. That is not always the realloc the component's
//! lifts use. A component built with the wasi_snapshot_preview1 adapter is
//! the common case: the adapter's lowers name `cabi_import_realloc`, which
//! hands back the buffer the preview1 caller passed in (for `random_get`,
//! its `buf`), while the main module exports `cabi_realloc`. Allocating
//! through the main module's realloc puts the bytes somewhere else and the
//! adapter asserts (`assert_eq!(result.as_ptr(), buf)`).

const ctypes = @import("../feature/component/types.zig");

/// The core export a synthetic inline export's lower names as its realloc,
/// or null when the export is not a func, not a `canon lower`, or the lower
/// carries no realloc option (or it does not resolve to a core export).
pub fn lowerReallocRef(info: *const ctypes.TypeInfo, ex: ctypes.CoreInlineExport) ?ctypes.TypeInfo.CoreExportRef {
    if (ex.sort != .func) return null;
    const def = info.coreFunc(ex.index) orelse return null;
    const l = switch (def) {
        .lower => |l| l,
        else => return null,
    };
    const ri = l.opts.realloc orelse return null;
    return info.resolveCoreFuncExport(ri);
}
