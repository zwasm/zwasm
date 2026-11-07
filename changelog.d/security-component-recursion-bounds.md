- **A component that nests types, declarations or components past zwasm's
  caps, or chains func re-exports, is refused or resolved** (#682). Before, the
  host process stopped. A type nests at most 100 levels, and a binary holds at
  most 1000 nested components.
