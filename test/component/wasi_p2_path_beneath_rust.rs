// A WASI 0.2 guest that plants "up" -> "." in its preopen and reads
// "up/../outside.txt", which resolves one level above the preopen. The read
// is refused: exit 20, and nothing on stdout. See
// README_wasi_p2_path_beneath_rust.md.
#[allow(deprecated)]
fn main() {
    if let Err(e) = std::fs::soft_link(".", "up") {
        eprintln!("symlink: {e}");
        std::process::exit(10);
    }
    match std::fs::read_to_string("up/../outside.txt") {
        Ok(s) => print!("{s}"),
        Err(e) => {
            eprintln!("open: {e}");
            std::process::exit(20);
        }
    }
}
