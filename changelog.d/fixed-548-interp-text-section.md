- **The interpreter's speed no longer moves with code laid out around it**
  (#548). The dispatch loop and every handler sit in one link section; a
  change elsewhere in the binary used to shift them by up to 12%.
