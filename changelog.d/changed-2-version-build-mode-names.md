- **`zwasm --version` spells the build mode as Zig 0.17 does** (#624):
  `mode: safe` / `fast` / `small` / `debug` where 2.8 printed `ReleaseSafe` /
  `ReleaseFast` / `ReleaseSmall` / `Debug`. The bench's `engine_build_mode`
  and `runner_build_mode` fields change the same way.
