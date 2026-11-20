- **The `wasi:http` host holds every request and response body whole in host
  memory** (#761). `--max-memory` and the memory-pages limit cap a guest's
  linear memory, not this: a guest that makes or serves an HTTP exchange, or
  the peer of its request, chooses the size of a host allocation. Bound the
  process's memory from outside when such a guest is not trusted.
