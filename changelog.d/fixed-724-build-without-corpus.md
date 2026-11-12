- **`zig build` configures on a tree without `test/`, so zwasm builds as a
  package again** (#724). 2.11.0's `build.zig` walked a test corpus on every
  build and panicked when it was missing, which is the tree a Zig dependency
  or a vendored copy holds. 2.10.0 was not affected.
