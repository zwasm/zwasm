{
  description = "zwasm v2 — a from-scratch WebAssembly runtime in Zig 0.16.0";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Realworld-fixture generation only (devShells.gen). Pins the Rust
    # toolchain with wasm targets. Kept out of `devShells.default` so the
    # test hosts (ubuntu / windows via SSH) never pull it.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # `default` shell uses plain legacyPackages — unchanged, load-bearing
        # for every host. Do NOT add generation toolchains here.
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.17.0";

        # `gen` shell uses a rust-overlay-enabled package set. Separate
        # binding so the overlay never perturbs `default`.
        genPkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
        # `.minimal` = rustc + cargo + rust-std only (no docs/clippy/rustfmt,
        # which build from source and aren't needed to compile wasm fixtures).
        rustWasm = genPkgs.rust-bin.stable.latest.minimal.override {
          # wasip2 emits a real Component-Model component directly (no
          # cargo-component / adapter) — the Phase E2 real-component proof.
          targets = [ "wasm32-unknown-unknown" "wasm32-wasip1" "wasm32-wasip2" ];
        };
        # Native rustc (host target only, no wasm-std) for the §13.5
        # `rust_host` embedder example — a Rust program linking `libzwasm.a`
        # over the C ABI. Kept in its OWN lean shell (`devShells.rust-host`),
        # NOT in `default`, so the test hosts' `zig build test-all` shell stays
        # toolchain-free; only the `run-rust-host` step opts into native rust.
        rustNative = genPkgs.rust-bin.stable.latest.minimal;
        # Nightly + rust-src for the wasm32-wasip3 (WASI 0.3) Tier-3 target:
        # wasip3 ships NO prebuilt std (Tier 3), so components are built via
        # `-Z build-std` from source. Mac-gen-only (`.#gen-wasip3`); the emitted
        # `.wasm` is committed + run on the test hosts by the edge-runner (no
        # rust there). Front-① WASI 0.3 conformance path ② (2026-06-16).
        # Pinned nightly (not `.latest`) for reproducibility — this exact nightly
        # is verified to build wasip3 via the recipe in `devShells.gen-wasip3`.
        # KNOWN-BROKEN above this pin: nightlies 2026-07-08 / 2026-07-16 fail
        # `-Z build-std` for wasip3 (upstream `std/sys/env/wasi.rs` OsStringExt
        # regression, verified 2026-07-17; see D-523 before bumping).
        rustNightlyWasip3 = genPkgs.rust-bin.nightly."2026-06-24".minimal.override {
          extensions = [ "rust-src" ];
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.git           # real git — macOS /usr/bin/git is an xcrun shim that breaks under `nix develop` (run_bench.sh git rev-parse)
            pkgs.hyperfine
            pkgs.yq-go
            pkgs.python3
            # wabt DROPPED (D-290, 2026-06-13): every distiller now bakes with
            # `wasm-tools json-from-wast`; the spec RUNNERS consume pre-baked
            # committed corpora (no wast2json/wat2wasm at test time), and
            # build.zig's spectest uses `wasm-tools parse`. One modern wasm CLI.
            pkgs.wasmtime      # reference runtime — drives the §9.6 / 6.2 differential gate
            pkgs.wazero        # §11.3 SIMD gap comparator (run_bench.sh --compare=wazero); D-074
            pkgs.wasm-tools    # dump / validate / print / strip / smith / shrink — Phase 6+ debug + Phase 7 fuzz corpus (per ADR-0015 candidate)
            pkgs.lldb          # interactive debugger + watchpoints (per ADR-0015 candidate)
            pkgs.nasm          # `ndisasm -b 64 file.bin` for raw JIT byte stream disasm — paired with lldb / objdump for SEGV root-cause work (autonomous loop x86_64 JIT debug per `.claude/rules/debug_jit.md`)
          ]
          # §11.3 wasmer comparator — Mac-only. On x86_64-linux nixpkgs has no
          # binary-cache hit for wasmer, so it builds from source and the
          # Rust/LLVM link fails, breaking the dev shell on the ubuntu/windows
          # TEST hosts (which build this same shell for `zig build test-all`).
          # The SIMD gap analysis (§11.3) runs Mac-only, where wasmer resolves
          # from cache, so confine it there.
          ++ pkgs.lib.optionals (system == "aarch64-darwin") [ pkgs.wasmer ];

          shellHook = ''
            echo "zwasm v2 dev shell"
            zig version
            echo "wasm-tools: $(wasm-tools --version 2>/dev/null || echo 'NOT FOUND')"
            echo "lldb:       $(lldb --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
            echo "dsymutil:   $(which dsymutil 2>/dev/null || echo 'NOT FOUND')"
            # ADR-0064 + commit c89ec713 (2026-05-11): activate the
            # project's git hooks by pointing core.hooksPath at
            # `.githooks/`. The setting lives in `.git/config`
            # (per-clone, not committed); fresh clones — and any
            # local repo where the config drifted back to `.git/hooks`
            # — get the hooks re-activated on `nix develop` entry.
            # Idempotent: only re-sets if the current value differs.
            if git rev-parse --git-dir >/dev/null 2>&1; then
              current_hp=$(git config --local --get core.hooksPath 2>/dev/null || echo "")
              if [ "$current_hp" != ".githooks" ]; then
                git config core.hooksPath .githooks
                echo "git hooks: core.hooksPath set to .githooks (was: $current_hp)"
              fi
            fi
          '';
        };

        # `rust_host` embedder shell (§13.5; ADR-pending toolchain-on-test-host).
        # zig (builds `libzwasm.a`) + native rustc (builds `docs/examples/rust_host/
        # hello.rs` linking it). Used by the `run-rust-host` step on the Linux
        # test host via `nix develop .#rust-host`; kept separate from `default`
        # so `test-all` stays toolchain-free. Windows uses native winget rust
        # (no nix there). Enter with `nix develop .#rust-host`.
        devShells.rust-host = genPkgs.mkShell {
          packages = [
            zig
            rustNative          # native rustc + cargo (host target)
            pkgs.git
          ];
          shellHook = ''
            echo "zwasm v2 — rust_host embedder shell (native rustc; §13.5 3-OS rust run)"
            echo "  rustc: $(rustc --version 2>/dev/null || echo 'NOT FOUND')"
          '';
        };

        # Realworld-fixture GENERATION shell (Mac host only; see
        # `.dev/toolchain_provisioning.md`). Provides the real toolchains
        # that compile C / C++ / Rust / Go to wasm. The emitted `.wasm` is
        # committed as a binary artifact and run on the test hosts by the
        # Zig-built edge-runner — so these heavy toolchains stay OUT of
        # `devShells.default` (the test hosts never need them). Enter with
        # `nix develop .#gen`. Mirrors v1's flake-as-source-of-truth model
        # (v1 `flake.nix` lines 144-187 + `versions.lock`).
        devShells.gen = genPkgs.mkShell {
          packages = [
            zig
            rustWasm                 # rustc + cargo, targets wasm32-unknown-unknown / wasm32-wasip1
            genPkgs.emscripten       # emcc — C/C++ → wasm (incl. -sMEMORY64 memory64 corpus)
            genPkgs.tinygo           # Go subset → wasm / wasip1 (bundles binaryen)
            genPkgs.go               # `GOOS=wasip1 GOARCH=wasm go build`
            genPkgs.llvmPackages.clang # clang --target=wasm32/wasm64 (the clang_musttail / clang_wasm64 path)
            genPkgs.lld              # wasm-ld linker for the bare clang → wasm path
            genPkgs.wasm-tools       # parse / print / validate the emitted modules
            genPkgs.python3
            # node/npm host the AssemblyScript (Binaryen-backend) generator.
            # asc + wasi-shim versions are pinned by the committed
            # test/realworld/src/assemblyscript/package-lock.json (`npm ci`);
            # asc is pure JS, so the node version does not affect the emitted
            # bytes — nixpkgs' default node is the right pin granularity.
            genPkgs.nodejs
          ];

          # NOTE: keep the shellHook CHEAP — do NOT run `emcc` here. The
          # first `emcc` invocation builds the emscripten sysroot cache
          # (slow, minutes), so calling it on every shell entry would tax
          # rust/clang/go/tinygo generation that never touches emcc. emcc's
          # cache builds lazily on its first real use.
          shellHook = ''
            echo "zwasm v2 — realworld-fixture GENERATION shell (Mac host only)"
            # emscripten needs a writable cache (the nix store path is RO).
            export EM_CACHE="''${EM_CACHE:-$HOME/.cache/emscripten}"
            mkdir -p "$EM_CACHE"
            # nix-wrapped clang injects -fzero-call-used-regs (unsupported for
            # wasm); the realworld build scripts must run with this cleared.
            export NIX_HARDENING_ENABLE=""
            echo "  toolchains: zig rustc(wasm32) emcc tinygo go clang+lld node(asc) on PATH"
            echo "  EM_CACHE=$EM_CACHE  (emcc builds its cache lazily on first use)"
            echo "Generated .wasm is COMMITTED; test hosts run it via the edge-runner (no toolchain there)."
          '';
        };

        # WASI 0.3 (wasm32-wasip3) fixture generation — Mac host only. wasip3 is
        # a Tier-3 target (no prebuilt std), so this shell carries nightly +
        # rust-src and components are built with `cargo build -Z build-std`.
        # Kept separate from `.#gen` (stable) so the main generation shell is
        # never perturbed by nightly. Front-① conformance path ② (2026-06-16).
        devShells.gen-wasip3 = genPkgs.mkShell {
          packages = [
            rustNightlyWasip3
            genPkgs.wasm-tools
            genPkgs.lld           # wasm-ld — replaces the nix nightly rust-lld (broken on Darwin: libLLVM mismatch)
          ];
          # wasip3 is Tier-3 → ships NO prebuilt std and NO wasi-libc, and the nix
          # nightly `rust-lld` can't link on Darwin (libLLVM `llvm::lto::DTLTO`
          # symbol mismatch). The reproducible recipe (verified 2026-06-16, spike
          # `private/spikes/wasip3-build-std`, zwasm runs the output → exit 1):
          #   (1) `-Z build-std` builds std from source (rust-src extension);
          #   (2) `wasm-component-ld --wasm-ld-path <nixpkgs wasm-ld>` does the
          #       component wrap but links via nixpkgs lld, NOT the broken rust-lld;
          #   (3) `link-self-contained=no` + the STABLE toolchain's wasip2
          #       crt1-command.o + libc.a (wasip3's libc layer == wasip2's).
          # `$ZWASM_WASIP3_RUSTFLAGS` presets all of it; build with:
          #   RUSTFLAGS="$ZWASM_WASIP3_RUSTFLAGS" cargo build -Z build-std=std,panic_abort --target wasm32-wasip3 --release
          shellHook = ''
            echo "zwasm v2 — WASI 0.3 (wasm32-wasip3) gen shell (nightly + build-std; Mac only)"
            export ZWASM_WASIP3_WASMLD="${genPkgs.lld}/bin/wasm-ld"
            export ZWASM_WASIP3_WASILIBC="${rustWasm}/lib/rustlib/wasm32-wasip2/lib/self-contained"
            export ZWASM_WASIP3_RUSTFLAGS="-Clink-self-contained=no -Clink-arg=--wasm-ld-path=$ZWASM_WASIP3_WASMLD -Clink-arg=-L$ZWASM_WASIP3_WASILIBC -Clink-arg=$ZWASM_WASIP3_WASILIBC/crt1-command.o -Clink-arg=-lc"
            echo "  rustc: $(rustc --version 2>/dev/null || echo 'NOT FOUND')"
            echo "  wasip3 link recipe preset in \$ZWASM_WASIP3_RUSTFLAGS (build-std + nixpkgs wasm-ld + wasip2 wasi-libc)"
          '';
        };

        # Multi-runtime BENCHMARK shell (Mac host only; ADR-0163 workstream B).
        # Pins every comparator runtime in one hermetic shell so
        # `scripts/run_bench.sh --compare=all` reproduces against the full set
        # (wasmtime / wazero / wasmer / wasmedge). The `default` shell carries
        # only the §11.3 SIMD-gap trio (wasmtime / wazero / wasmer) — this shell
        # adds the wasmedge WASI-realworld comparator on top. Invoked
        # manually on the Mac bench host via `nix develop .#bench`; never built
        # by the ubuntu/windows TEST hosts (which build `default` for
        # `test-all`), so the heavier comparators here can't break their gate.
        #
        # wasm3 is deliberately EXCLUDED: nixpkgs marks wasm3-0.5.0 insecure
        # (8 CVEs incl. CVE-2022-39974; upstream unmaintained since 2021).
        # Pinning a CVE-laden runtime into a public release flake is wrong, and
        # v1's comparator set never included it — so no parity is lost.
        devShells.bench = pkgs.mkShell {
          packages = [
            zig                # builds ./zig-out/bin/zwasm for the comparison
            pkgs.git
            pkgs.hyperfine     # the timing harness run_bench.sh drives
            pkgs.yq-go         # results YAML post-processing
            pkgs.python3       # hyperfine-JSON → ms parsing (run_bench.sh)
            pkgs.wasmtime      # Cranelift JIT reference
            pkgs.wazero        # pure-Go interpreter/compiler comparator
            pkgs.wasmedge      # WASI _start comparator (interpreter by default; AOT via `wasmedge compile`)
          ]
          # wasmer is a binary-cache hit on aarch64-darwin but builds from
          # source (Rust/LLVM) elsewhere; the bench host is Mac, so confine it
          # there — same rationale as `default` (flake.nix §default wasmer note).
          ++ pkgs.lib.optionals (system == "aarch64-darwin") [ pkgs.wasmer ];

          shellHook = ''
            echo "zwasm v2 — multi-runtime BENCHMARK shell (Mac host only; ADR-0163)"
            for rt in wasmtime wazero wasmer wasmedge; do
              printf '  %-9s %s\n' "$rt:" "$(command -v "$rt" >/dev/null 2>&1 && "$rt" --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
            done
            echo "Run: nix develop .#bench --command bash scripts/run_bench.sh --compare=all"
          '';
        };
      });
}
