// Wasm 3.0 exception handling via emscripten's -fwasm-exceptions: the C++
// `throw` / `catch` pair lowers to `throw` + `try_table`, which is the only
// path in this corpus that reaches those instructions from a real toolchain.
//
// `test()` returns 42 by throwing across a function boundary and catching by
// type, so a miscompile of the unwind path shows up as a wrong value rather
// than only as a crash.
struct Marker {
  int value;
};

__attribute__((noinline)) static int raise_marker(int v) {
  if (v > 0) throw Marker{v};
  return 0;
}

extern "C" int test() {
  int acc = 0;
  try {
    acc += raise_marker(40);
  } catch (const Marker &m) {
    acc += m.value;
  }
  try {
    acc += raise_marker(-1);  // returns normally, no throw
  } catch (const Marker &) {
    acc += 1000;  // must not run
  }
  return acc + 2;
}
