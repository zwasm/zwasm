;; WASI 0.3 sockets reached from a sync export, so a default (-Dwasi=p2) build
;; serves them too. `connect(port)` creates a TCP socket and connects it to
;; 127.0.0.1:port; `resolve()` resolves "127.0.0.1". Each returns the first
;; failing result<_, error-code> as (disc << 8) | error-code: 0 = ok, 0x100 =
;; err access-denied. Built from a core module and a world importing
;; wasi:sockets/types and ip-name-lookup @0.3.0 (`wasm-tools component embed` +
;; `new`); regenerate the .wasm with `wasm-tools parse`.
(component
  (type $ty-wasi:sockets/types@0.3.0 (;0;)
    (instance
      (export (;0;) "tcp-socket" (type (sub resource)))
      (type (;1;) (enum "ipv4" "ipv6"))
      (export (;2;) "ip-address-family" (type (eq 1)))
      (type (;3;) (option string))
      (type (;4;) (variant (case "access-denied") (case "not-supported") (case "invalid-argument") (case "out-of-memory") (case "timeout") (case "invalid-state") (case "address-not-bindable") (case "address-in-use") (case "remote-unreachable") (case "connection-refused") (case "connection-broken") (case "connection-reset") (case "connection-aborted") (case "datagram-too-large") (case "other" 3)))
      (export (;5;) "error-code" (type (eq 4)))
      (type (;6;) (tuple u8 u8 u8 u8))
      (export (;7;) "ipv4-address" (type (eq 6)))
      (type (;8;) (record (field "port" u16) (field "address" 7)))
      (export (;9;) "ipv4-socket-address" (type (eq 8)))
      (type (;10;) (tuple u16 u16 u16 u16 u16 u16 u16 u16))
      (export (;11;) "ipv6-address" (type (eq 10)))
      (type (;12;) (record (field "port" u16) (field "flow-info" u32) (field "address" 11) (field "scope-id" u32)))
      (export (;13;) "ipv6-socket-address" (type (eq 12)))
      (type (;14;) (variant (case "ipv4" 9) (case "ipv6" 13)))
      (export (;15;) "ip-socket-address" (type (eq 14)))
      (type (;16;) (variant (case "ipv4" 7) (case "ipv6" 11)))
      (export (;17;) "ip-address" (type (eq 16)))
      (type (;18;) (own 0))
      (type (;19;) (result 18 (error 5)))
      (type (;20;) (func (param "address-family" 2) (result 19)))
      (export (;0;) "[static]tcp-socket.create" (func (type 20)))
      (type (;21;) (borrow 0))
      (type (;22;) (result (error 5)))
      (type (;23;) (func async (param "self" 21) (param "remote-address" 15) (result 22)))
      (export (;1;) "[method]tcp-socket.connect" (func (type 23)))
    )
  )
  (import "wasi:sockets/types@0.3.0" (instance $wasi:sockets/types@0.3.0 (;0;) (type $ty-wasi:sockets/types@0.3.0)))
  (alias export $wasi:sockets/types@0.3.0 "ip-address" (type $ip-address (;1;)))
  (type $ty-wasi:sockets/ip-name-lookup@0.3.0 (;2;)
    (instance
      (alias outer 1 $ip-address (type (;0;)))
      (export (;1;) "ip-address" (type (eq 0)))
      (type (;2;) (option string))
      (type (;3;) (variant (case "access-denied") (case "invalid-argument") (case "name-unresolvable") (case "temporary-resolver-failure") (case "permanent-resolver-failure") (case "other" 2)))
      (export (;4;) "error-code" (type (eq 3)))
      (type (;5;) (list 1))
      (type (;6;) (result 5 (error 4)))
      (type (;7;) (func async (param "name" string) (result 6)))
      (export (;0;) "resolve-addresses" (func (type 7)))
    )
  )
  (import "wasi:sockets/ip-name-lookup@0.3.0" (instance $wasi:sockets/ip-name-lookup@0.3.0 (;1;) (type $ty-wasi:sockets/ip-name-lookup@0.3.0)))
  (core module $main (;0;)
    (type (;0;) (func (param i32 i32)))
    (type (;1;) (func (param i32 i32) (result i32)))
    (type (;2;) (func (param i32 i32 i32) (result i32)))
    (type (;3;) (func (param i32 i32 i32 i32) (result i32)))
    (type (;4;) (func (param i32) (result i32)))
    (type (;5;) (func (result i32)))
    (import "wasi:sockets/types@0.3.0" "[static]tcp-socket.create" (func $create (;0;) (type 0) (param i32 i32)))
    (import "wasi:sockets/types@0.3.0" "[async-lower][method]tcp-socket.connect" (func $connect (;1;) (type 1) (param i32 i32) (result i32)))
    (import "wasi:sockets/ip-name-lookup@0.3.0" "[async-lower]resolve-addresses" (func $resolve (;2;) (type 2) (param i32 i32 i32) (result i32)))
    (memory (;0;) 1)
    (global $bump (;0;) (mut i32) i32.const 4096)
    (export "memory" (memory 0))
    (export "cabi_realloc" (func 3))
    (export "connect" (func 5))
    (export "resolve" (func 6))
    (func (;3;) (type 3) (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      global.get $bump
      i32.const 7
      i32.add
      i32.const -8
      i32.and
      local.set $p
      local.get $p
      local.get 3
      i32.add
      global.set $bump
      local.get $p
    )
    (func $outcome (;4;) (type 4) (param $at i32) (result i32)
      local.get $at
      i32.load8_u
      i32.const 8
      i32.shl
      local.get $at
      i32.const 4
      i32.add
      i32.load8_u
      i32.or
    )
    (func (;5;) (type 4) (param $port i32) (result i32)
      i32.const 0
      i32.const 256
      call $create
      i32.const 256
      i32.load8_u
      if ;; label = @1
        i32.const 256
        call $outcome
        return
      end
      i32.const 512
      i32.const 260
      i32.load
      i32.store
      i32.const 516
      i32.const 0
      i32.store8
      i32.const 520
      local.get $port
      i32.store16
      i32.const 522
      i32.const 16777343
      i32.store
      i32.const 512
      i32.const 768
      call $connect
      drop
      i32.const 768
      call $outcome
    )
    (func (;6;) (type 5) (result i32)
      i32.const 16
      i32.const 9
      i32.const 1024
      call $resolve
      drop
      i32.const 1024
      call $outcome
    )
    (data (;0;) (i32.const 16) "127.0.0.1")
    (@producers
      (processed-by "wit-component" "0.262.0")
    )
  )
  (core module $wit-component-shim-module (;1;)
    (type (;0;) (func (param i32 i32)))
    (type (;1;) (func (param i32 i32) (result i32)))
    (type (;2;) (func (param i32 i32 i32) (result i32)))
    (table (;0;) 3 3 funcref)
    (export "0" (func $"indirect-wasi:sockets/types@0.3.0-[static]tcp-socket.create"))
    (export "1" (func $"indirect-wasi:sockets/types@0.3.0-[async-lower][method]tcp-socket.connect"))
    (export "2" (func $"indirect-wasi:sockets/ip-name-lookup@0.3.0-[async-lower]resolve-addresses"))
    (export "$imports" (table 0))
    (func $"indirect-wasi:sockets/types@0.3.0-[static]tcp-socket.create" (;0;) (type 0) (param i32 i32)
      local.get 0
      local.get 1
      i32.const 0
      call_indirect (type 0)
    )
    (func $"indirect-wasi:sockets/types@0.3.0-[async-lower][method]tcp-socket.connect" (;1;) (type 1) (param i32 i32) (result i32)
      local.get 0
      local.get 1
      i32.const 1
      call_indirect (type 1)
    )
    (func $"indirect-wasi:sockets/ip-name-lookup@0.3.0-[async-lower]resolve-addresses" (;2;) (type 2) (param i32 i32 i32) (result i32)
      local.get 0
      local.get 1
      local.get 2
      i32.const 2
      call_indirect (type 2)
    )
    (@producers
      (processed-by "wit-component" "0.262.0")
    )
  )
  (core instance $wit-component-shim-instance (;0;) (instantiate $wit-component-shim-module))
  (alias core export $wit-component-shim-instance "0" (core func $"indirect-wasi:sockets/types@0.3.0-[static]tcp-socket.create" (;0;)))
  (alias core export $wit-component-shim-instance "1" (core func $"indirect-wasi:sockets/types@0.3.0-[async-lower][method]tcp-socket.connect" (;1;)))
  (core instance $wasi:sockets/types@0.3.0 (;1;)
    (export "[static]tcp-socket.create" (func $"indirect-wasi:sockets/types@0.3.0-[static]tcp-socket.create"))
    (export "[async-lower][method]tcp-socket.connect" (func $"indirect-wasi:sockets/types@0.3.0-[async-lower][method]tcp-socket.connect"))
  )
  (alias core export $wit-component-shim-instance "2" (core func $"indirect-wasi:sockets/ip-name-lookup@0.3.0-[async-lower]resolve-addresses" (;2;)))
  (core instance $wasi:sockets/ip-name-lookup@0.3.0 (;2;)
    (export "[async-lower]resolve-addresses" (func $"indirect-wasi:sockets/ip-name-lookup@0.3.0-[async-lower]resolve-addresses"))
  )
  (core instance $main (;3;) (instantiate $main
      (with "wasi:sockets/types@0.3.0" (instance $wasi:sockets/types@0.3.0))
      (with "wasi:sockets/ip-name-lookup@0.3.0" (instance $wasi:sockets/ip-name-lookup@0.3.0))
    )
  )
  (alias core export $main "memory" (core memory $memory (;0;)))
  (core module $wit-component-fixup (;2;)
    (type (;0;) (func (param i32 i32)))
    (type (;1;) (func (param i32 i32) (result i32)))
    (type (;2;) (func (param i32 i32 i32) (result i32)))
    (import "actual" "0" (func $0 (;0;) (type 0) (param i32 i32)))
    (import "actual" "1" (func $1 (;1;) (type 1) (param i32 i32) (result i32)))
    (import "actual" "2" (func $2 (;2;) (type 2) (param i32 i32 i32) (result i32)))
    (import "shim" "$imports" (table (;0;) 3 3 funcref))
    (elem (;0;) (i32.const 0) func $0 $1 $2)
    (@producers
      (processed-by "wit-component" "0.262.0")
    )
  )
  (alias export $wasi:sockets/types@0.3.0 "[static]tcp-socket.create" (func $"[static]tcp-socket.create" (;0;)))
  (alias core export $main "cabi_realloc" (core func $cabi_realloc (;3;)))
  (core func $"#core-func4 indirect-wasi:sockets/types@0.3.0-[static]tcp-socket.create" (@name "indirect-wasi:sockets/types@0.3.0-[static]tcp-socket.create") (;4;) (canon lower (func $"[static]tcp-socket.create") (memory $memory) (realloc $cabi_realloc) string-encoding=utf8))
  (alias export $wasi:sockets/types@0.3.0 "[method]tcp-socket.connect" (func $"[method]tcp-socket.connect" (;1;)))
  (core func $"#core-func5 indirect-wasi:sockets/types@0.3.0-[async-lower][method]tcp-socket.connect" (@name "indirect-wasi:sockets/types@0.3.0-[async-lower][method]tcp-socket.connect") (;5;) (canon lower (func $"[method]tcp-socket.connect") (memory $memory) (realloc $cabi_realloc) string-encoding=utf8 async))
  (alias export $wasi:sockets/ip-name-lookup@0.3.0 "resolve-addresses" (func $resolve-addresses (;2;)))
  (core func $"#core-func6 indirect-wasi:sockets/ip-name-lookup@0.3.0-[async-lower]resolve-addresses" (@name "indirect-wasi:sockets/ip-name-lookup@0.3.0-[async-lower]resolve-addresses") (;6;) (canon lower (func $resolve-addresses) (memory $memory) (realloc $cabi_realloc) string-encoding=utf8 async))
  (core instance $actual (;4;)
    (export "0" (func $"#core-func4 indirect-wasi:sockets/types@0.3.0-[static]tcp-socket.create"))
    (export "1" (func $"#core-func5 indirect-wasi:sockets/types@0.3.0-[async-lower][method]tcp-socket.connect"))
    (export "2" (func $"#core-func6 indirect-wasi:sockets/ip-name-lookup@0.3.0-[async-lower]resolve-addresses"))
  )
  (core instance $fixup (;5;) (instantiate $wit-component-fixup
      (with "actual" (instance $actual))
      (with "shim" (instance $wit-component-shim-instance))
    )
  )
  (type (;3;) (func (param "port" u16) (result u32)))
  (alias core export $main "connect" (core func $connect (;7;)))
  (func $connect (;3;) (type 3) (canon lift (core func $connect)))
  (export $"#func4 connect" (@name "connect") (;4;) "connect" (func $connect))
  (type (;4;) (func (result u32)))
  (alias core export $main "resolve" (core func $resolve (;8;)))
  (func $resolve (;5;) (type 4) (canon lift (core func $resolve)))
  (export $"#func6 resolve" (@name "resolve") (;6;) "resolve" (func $resolve))
  (@producers
    (processed-by "wit-component" "0.262.0")
  )
)
