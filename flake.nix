{
  description = "perijove — a Jupyter notebook frontend for Neovim, built on fibrous";

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
      # a real jupyter for the integration spec and the demo-real app
      jupyterEnv = pkgs: pkgs.python3.withPackages (ps: [
        ps.jupyter-server
        ps.ipykernel
      ]);
    in
    {
      # The plugin, packaged the standard nixpkgs way, with two twists:
      #   - fibrous is a `dependencies` entry, so dep-flattening plugin
      #     managers (home-manager, nixvim, ...) put it on the runtimepath
      #     automatically;
      #   - the external tools (curl, websocat, and jupyter-server for the
      #     builtin local connection) are PINNED: postPatch substitutes their
      #     store paths into lua/perijove/tools.lua, closing the plugin over
      #     the exact binaries it was tested with. No PATH lookups at runtime,
      #     fully reproducible. (A source checkout keeps the placeholders and
      #     falls back to PATH — see tools.lua.)
      packages = forAllSystems (pkgs: rec {
        default = perijove;
        perijove = pkgs.vimUtils.buildVimPlugin {
          pname = "perijove";
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self;
          dependencies = [ fibrous.packages.${pkgs.stdenv.hostPlatform.system}.default ];
          postPatch = ''
            substituteInPlace lua/perijove/tools.lua \
              --replace-fail "@curl@" "${pkgs.curl}" \
              --replace-fail "@websocat@" "${pkgs.websocat}" \
              --replace-fail "@jupyter@" "${jupyterEnv pkgs}"
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
          app = name: extraInputs: text: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name text;
                runtimeInputs = [ pkgs.neovim ] ++ extraInputs;
              }
            );
          };
          # the apps run from the source snapshot (tools.lua placeholders
          # unsubstituted), so the transport tools must be on PATH
          wireTools = pkgs: [ pkgs.curl pkgs.websocat ];
        in
        rec {
          default = demo;
          test = app "perijove-test" (wireTools pkgs ++ [ (jupyterEnv pkgs) pkgs.basedpyright ]) ''
            export FIBROUS_PATH="''${FIBROUS_PATH:-${fibrous}}"
            cd ${self}
            exec nvim --headless -u NONE -i NONE -l tests/run.lua "$@"
          '';
          demo = app "perijove-demo" [ ] ''
            export FIBROUS_PATH="''${FIBROUS_PATH:-${fibrous}}"
            exec nvim --clean -u ${self}/demo/init.lua
          '';
          # the same notebook over a REAL local jupyter kernel
          demo-real = app "perijove-demo-real" (wireTools pkgs ++ [ (jupyterEnv pkgs) ]) ''
            export FIBROUS_PATH="''${FIBROUS_PATH:-${fibrous}}"
            exec nvim --clean -u ${self}/demo/real.lua
          '';
        }
      );

      # `nix develop`: the test host, the transport tools, and a real jupyter
      # server + ipykernel so the integration spec runs (it skips itself when
      # jupyter-server is missing).
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.gnumake
            pkgs.lua-language-server
            pkgs.stylua
            pkgs.curl
            pkgs.websocat
            (jupyterEnv pkgs)
            # notebook LSP integration spec (skips itself when missing)
            pkgs.basedpyright
          ];
        };
      });

      # `nix flake check` runs the suite in the build sandbox, in a fully
      # isolated headless Neovim, against the PINNED fibrous. The sandbox has
      # loopback, so the real-kernel integration spec runs here too, against
      # the pinned jupyter-server + ipykernel.
      checks = forAllSystems (pkgs: {
        tests =
          pkgs.runCommandLocal "perijove-tests"
            {
              nativeBuildInputs = [
                pkgs.neovim
                pkgs.gnumake
                pkgs.curl
                pkgs.websocat
                (jupyterEnv pkgs)
                pkgs.basedpyright
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
