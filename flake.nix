{
  description = "jotdown — a Jupyter notebook frontend for Neovim, built on fibrous";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The UI framework. A pinned flake input like any other: changes in the
    # sibling checkout are invisible until commit + push + `nix flake update
    # fibrous`. For day-to-day development every entry point below honors
    # FIBROUS_PATH (the Makefile defaults it to ../fibrous.nvim), so `make
    # test` always sees the working tree.
    fibrous.url = "github:mbrea-c/fibrous.nvim";
  };

  outputs =
    {
      self,
      nixpkgs,
      fibrous,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      # The plugin, packaged the standard nixpkgs way, with two twists:
      #   - fibrous is a `dependencies` entry, so dep-flattening plugin
      #     managers (home-manager, nixvim, ...) put it on the runtimepath
      #     automatically;
      #   - the wire transport's external tools (curl, websocat) are PINNED:
      #     postPatch substitutes their store paths into lua/jotdown/tools.lua,
      #     closing the plugin over the exact binaries it was tested with. No
      #     PATH lookups at runtime, fully reproducible. (A source checkout
      #     keeps the placeholders and falls back to PATH — see tools.lua.)
      packages = forAllSystems (pkgs: rec {
        default = jotdown;
        jotdown = pkgs.vimUtils.buildVimPlugin {
          pname = "jotdown";
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self;
          dependencies = [ fibrous.packages.${pkgs.stdenv.hostPlatform.system}.default ];
          postPatch = ''
            substituteInPlace lua/jotdown/tools.lua \
              --replace-fail "@curl@" "${pkgs.curl}" \
              --replace-fail "@websocat@" "${pkgs.websocat}"
          '';
          # the real gate is the test suite (`nix flake check`); the generic
          # require-check chokes on modules that need a running UI
          doCheck = false;
        };
      });

      # `nix run .#test [-- tests/foo_spec.lua]` — the suite (or one spec)
      # against the flake's own snapshot of the source. Use `make test`
      # against the working tree during development.
      apps = forAllSystems (
        pkgs:
        let
          app = name: text: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name text;
                runtimeInputs = [ pkgs.neovim ];
              }
            );
          };
        in
        rec {
          default = test;
          test = app "jotdown-test" ''
            export FIBROUS_PATH="''${FIBROUS_PATH:-${fibrous}}"
            cd ${self}
            exec nvim --headless -u NONE -i NONE -l tests/run.lua "$@"
          '';
        }
      );

      # `nix develop`: the test host plus the transport tools, so integration
      # work against a live `jupyter server` has everything on hand.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.gnumake
            pkgs.lua-language-server
            pkgs.stylua
            pkgs.curl
            pkgs.websocat
          ];
        };
      });

      # `nix flake check` runs the suite in the build sandbox, in a fully
      # isolated headless Neovim, against the PINNED fibrous. curl/websocat
      # are present for (future) transport integration specs.
      checks = forAllSystems (pkgs: {
        tests =
          pkgs.runCommandLocal "jotdown-tests"
            {
              nativeBuildInputs = [
                pkgs.neovim
                pkgs.gnumake
                pkgs.curl
                pkgs.websocat
              ];
            }
            ''
              cp -r ${self}/. work && chmod -R +w work && cd work
              export HOME="$TMPDIR"
              export FIBROUS_PATH=${fibrous}
              make test
              touch "$out"
            '';
      });
    };
}
