- **A GC collection frees its temporary buffers when it returns.** Before, the
  list of object starts each collection built could stay in the arena behind
  the GC heap, so a GC guest held more host memory than its live heap needed:
  657 MB against 319 MB at peak for 8 million live objects on the JIT (x86_64
  Linux).
