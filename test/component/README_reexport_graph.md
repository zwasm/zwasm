# Component Model fixture: reexport_graph (children reached through their exports)

`adder_graph` with every child instance exported at the outer level, and every
reference to a child made through the export's index rather than the
`instantiate`'s:

```
(instance $b (instantiate $B))                                  ;; instance 0: definition 0
(export $bx "b" (instance $b))                                  ;; instance 1: re-exports 0
(instance $a (instantiate $A (with "adder" (func $bx "adder"))));; instance 2: definition 1
(export $ax "a" (instance $a))                                  ;; instance 3: re-exports 2
(export "add-five" (func $ax "add-five"))
```

The `with` arg's func alias names instance 1 and the outer export's func alias
names instance 3, both re-exports. The graph resolves a child from an
instance index in two places (the provider of a child's import, and the child
behind an outer func export); both must follow the re-export to the
`instantiate` it names. `wasm-tools compose` output reaches the same shape.

## Reproduce

```sh
wasm-tools parse reexport_graph.wat -o reexport_graph.wasm
wasm-tools validate --features component-model reexport_graph.wasm
```

(Assembled with wasm-tools 1.240.0.)

## Behaviour

`add-five(10)` → A calls B's `adder(10, 5)` → `15`.
