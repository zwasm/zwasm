struct Point { x : Int; y : Int }
struct Node { val : Point; next : Node? }

fn chain(n : Int, v : Int) -> Node? {
  if n == 0 { None } else { Some({ val: { x: v, y: v * 10 }, next: chain(n - 1, v + 1) }) }
}

fn walk(node : Node?) -> Int {
  match node { None => 0; Some(n) => n.val.x + n.val.y + walk(n.next) }
}

fn head(node : Node?) -> Point? {
  match node { None => None; Some(n) => Some(n.val) }
}

fn first_span(node : Node?) -> Int {
  match head(node) { None => 0; Some(p) => p.y - p.x }
}

pub fn compute() -> Int {
  let c = chain(6, 1)
  walk(c) + first_span(c)
}

fn main { ignore(compute()) }
