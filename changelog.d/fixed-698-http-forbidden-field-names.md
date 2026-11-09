- **`wasi:http` fields refuse the forbidden field names** (#698). `set`,
  `append`, `from-list`, `delete` and `get-and-delete` answer `forbidden` for
  `connection`, `host`, `transfer-encoding` and the six others wasmtime
  refuses, in any casing; before, any syntactically valid name went through.
