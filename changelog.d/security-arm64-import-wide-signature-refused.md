- **On arm64, importing another module's function with 518 or more `i32`
  parameters is refused at instantiation.** Before, instantiating the importing
  module aborted the process, whether or not it called the function. Measured
  through the C API on aarch64 Linux; x86_64 instantiated the same modules.
