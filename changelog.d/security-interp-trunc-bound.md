- **On the interpreter, a trapping float-to-int truncation of exactly 2^31,
  2^32, 2^63 or 2^64 traps** (#656). It traps `integer overflow`, as the JIT
  does; before, the host process stopped.
