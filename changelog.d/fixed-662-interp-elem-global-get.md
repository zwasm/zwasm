- **On the interpreter, an element segment can read an imported global** (#662,
  #282). A `global.get` item of an imported funcref global, or an active
  offset that reads an imported global, made instantiation fail.
