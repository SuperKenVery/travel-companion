{
  description = "Travel Companion Rust-first iOS development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.fenix.url = "github:nix-community/fenix";
  inputs.fenix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, fenix, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" ];
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          rustToolchain = fenix.packages.${system}.combine [
            fenix.packages.${system}.stable.cargo
            fenix.packages.${system}.stable.clippy
            fenix.packages.${system}.stable.rust-src
            fenix.packages.${system}.stable.rustc
            fenix.packages.${system}.stable.rustfmt
            fenix.packages.${system}.stable.rust-analyzer
            fenix.packages.${system}.targets.aarch64-apple-ios.stable.rust-std
          ];
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              rustToolchain
              libimobiledevice
              openssl
              pkg-config
              sqlite
              xcodegen
            ];

            RUST_BACKTRACE = "1";
            TC_NIX_DEVSHELL = "1";
            # nixpkgs provides the reproducible userland toolchain, while the
            # licensed iPhoneOS SDK remains supplied by the host Xcode.
            TC_HOST_XCRUN = "/usr/bin/xcrun";
            TC_HOST_XCODEBUILD = "/usr/bin/xcodebuild";
            TC_HOST_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer";

            # nixpkgs exports LD=ld for native builds. Xcode treats inherited
            # environment variables as build settings, but its `Ld` phases
            # require the clang driver because they pass driver-only options
            # such as -Xlinker. Keep the Nix compiler wrappers on PATH while
            # preventing Xcode (including an app launched from this shell)
            # from invoking ld directly.
            shellHook = ''
              unset LD
            '';
          };
        });
    };
}
