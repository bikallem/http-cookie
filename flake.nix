{
  description = "http-date — RFC 9110 HTTP datetime encoder/decoder";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Build a scope against a given ocaml compiler, applying the mdx/logs
          # fix and adding alcobar (not in nixpkgs).
          mkScope =
            ocaml:
            (pkgs.ocaml-ng.mkOcamlPackages ocaml).overrideScope (
              oself: osuper: {
                # nixpkgs builds mdx against a stripped-down `logs` (no lwt/jsoo) to
                # break a dep cycle. utop pulls in the full `logs`, so the two
                # propagated copies collide in the dev shell. Force mdx onto the
                # default `logs` to keep findlib happy.
                mdx = osuper.mdx.override { inherit (oself) logs; };

                alcobar = oself.buildDunePackage rec {
                  pname = "alcobar";
                  version = "0.3";

                  src = pkgs.fetchurl {
                    url = "https://github.com/samoht/alcobar/releases/download/v${version}/${pname}-${version}.tbz";
                    sha256 = "de27258a56db63f690a3bb8edbc8215ce85acfdac8ab1be44f172d2314f0177c";
                  };

                  minimalOCamlVersion = "4.10";

                  propagatedBuildInputs = [
                    oself.alcotest
                    oself.cmdliner
                    oself.afl-persistent
                  ];

                  doCheck = false;

                  meta = {
                    description = "Crowbar with an Alcotest-compatible API";
                    homepage = "https://github.com/samoht/alcobar";
                    license = pkgs.lib.licenses.mit;
                  };
                };
              }
            );

          # dev ocaml with framePointerSupport
          ocamlDev =
            (pkgs.ocaml-ng.ocamlPackages_5_4.ocaml.override {
              framePointerSupport = true;
              flambdaSupport = true;
            }).overrideAttrs
              (_: {
                doCheck = false;
              });

          # Stock 5.4.1 scope - hits the binary cache.
          ocamlPackages = mkScope ocamlDev;

          # 5.4.1 + flambda + AFL instrumentation. Different store path than the
          # stock compiler, so the whole scope is rebuild locally on first use.
          ocamlFuzz =
            (pkgs.ocaml-ng.ocamlPackages_5_4.ocaml.override {
              flambdaSupport = true;
              aflSupport = true;
            }).overrideAttrs
              (_: {
                doCheck = false; # skip make tests phase
              });
          ocamlPackagesFuzz = mkScope ocamlFuzz;

          # nixpkgs ships dune 3.21.1; build the 3.22.1 binary standalone so
          # the rest of ocamlPackages (ocaml-lsp, etc.) keeps its matching
          # dune monorepo libraries.
          mkDune =
            scope:
            scope.dune_3.overrideAttrs (_: rec {
              version = "3.23.0";
              src = pkgs.fetchurl {
                url = "https://github.com/ocaml/dune/releases/download/${version}/dune-${version}.tbz";
                hash = "sha256-6SmH/+S8eVaxiyJRsPmETVXfo4cDXOYKPw/VrE4mF9Q=";
              };
            });

          dune = mkDune ocamlPackages;
          duneFuzz = mkDune ocamlPackagesFuzz;

          commonPackages = scope: duneBin: [
            duneBin
            scope.ocaml
            scope.findlib
            scope.mdx
            scope.ocaml-lsp
            scope.ocamlformat
            scope.utop
            scope.alcobar
            scope.angstrom
            scope.ppx_expect
          ];

        in
        {
          # To use this env:
          # unset NIX_DEVSHELL && direnv reload
          default = pkgs.mkShell {
            packages = commonPackages ocamlPackages dune;
          };

          # `nix develop .#fuzz` - OCaml 5.4.1 with flambda + AFL instrumentation,
          # plus alcobar and the AFL++ fuzzer itself. `aflSupport = true` only
          # instruments the *compiler*; the `afl-fuzz` driver is a separate
          # package and must be added explicitly.
          # First entry rebuilds the entire OCaml scope locally (no binary cache hit);
          # subsequent entries are instant.
          #
          # To use this env:
          # export NIX_DEVSHELL=fuzz && direnv reload
          fuzz = pkgs.mkShell {
            packages = commonPackages ocamlPackagesFuzz duneFuzz ++ [
              pkgs.aflplusplus
            ];
          };
        }
      );
    };
}
