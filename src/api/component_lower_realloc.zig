//! Which realloc a `canon lower` names (see `WasiP2Ctx.lower_realloc_instance`).

const std = @import("std");
const ctypes = @import("../feature/component/types.zig");

/// A component whose lowers name more than one realloc, or whose lower
/// realloc does not resolve to a guest instance's export. The trampolines
/// allocate every lowered result through one realloc, so a second one would
/// place some results in the wrong buffer.
pub const Error = error{UnsupportedLowerRealloc};

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

/// The one `(instance, name)` every lower's realloc must agree on.
pub const Binding = struct {
    ref: ?ctypes.TypeInfo.CoreExportRef = null,

    /// Record `ex`'s lower realloc. A lower naming a different
    /// `(instance, name)` than the first is refused.
    pub fn record(self: *Binding, info: *const ctypes.TypeInfo, ex: ctypes.CoreInlineExport) Error!void {
        const ref = lowerReallocRef(info, ex) orelse return;
        if (self.ref) |have| {
            if (have.instance != ref.instance or !std.mem.eql(u8, have.name, ref.name))
                return Error.UnsupportedLowerRealloc;
            return;
        }
        self.ref = ref;
    }
};
