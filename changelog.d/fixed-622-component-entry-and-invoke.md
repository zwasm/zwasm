- **`zwasm run` on a component runs its `wasi:cli/run` export by name, and
  `--invoke` reaches a component** (#622). It ran the first lifted export (on
  `-Dwasi=p2`, even an async-only one) and dropped `--invoke`. Without one,
  the component is refused with its exports listed. `--invoke NAME=args` takes
  WIT scalar, char and string args.
