- **On the arm64 JIT, a call's stack arguments, the frame reserved for them and
  the return buffer of a callee with three or more results follow one rule**
  (#425). On Apple targets the buffer was placed by an eight-bytes-per-scalar
  count while the frame reserved the four-byte-packed size; it now starts where
  the reserved argument region ends, on every arm64 target.
