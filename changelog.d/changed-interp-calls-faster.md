- **Interpreter calls are faster** (#624). Against 0.16.0 on one host, the
  shootout `fib2` fixture takes 67% less time on the interpreter, `ctype` 48%
  and `ratelimit` 19%. Each call clears its frame's 2.5 KB label stack through
  compiler_rt's memset, which Zig 0.17 vectorizes.
