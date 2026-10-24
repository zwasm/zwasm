- **An interpreter call chain deeper than 256 no longer traps
  `CallStackExhausted` while the host stack has room** (#638). Frames past
  256 go into heap chunks; the cap is `Runtime.max_frame_depth` (16384),
  and the native-stack check still traps runaway recursion first.
