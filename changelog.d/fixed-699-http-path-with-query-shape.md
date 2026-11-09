- **`wasi:http` `set-path-with-query` refuses a path that is not
  origin-form** (#699). A value must be empty or start with `/` or `?`;
  before, `a/b/c` or `http://other.example/x` was accepted and then spliced
  onto the request's authority.
