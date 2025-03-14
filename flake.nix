{
  description = ''
    A garnix module for projects using Haskell.

    Add dependencies, pick the GHC version, and optionally deploy a web server.

    [Documentation](https://garnix.io/docs/modules/haskell) - [Source](https://github.com/garnix-io/haskell-module).
  '';
  outputs =
    { self }:
    {
      garnixModules.default =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let
          webServerSubmodule.options = {
            command =
              lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "The command to run to start the server in production.";
                example = "server --port \"$PORT\"";
              }
              // {
                name = "server command";
              };

            port = lib.mkOption {
              type = lib.types.port;
              description = "Port to forward incoming HTTP requests to. This port has to be opened by the server command. This also sets the PORT environment variable for the server command.";
              example = 7000;
              default = 7000;
            };

            path =
              lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "URL path your Haskell server will be hosted on.";
                default = "/";
              }
              // {
                name = "API path";
              };
          };

          haskellSubmodule.options = {
            src =
              lib.mkOption {
                type = lib.types.path;
                description = "A path to the directory containing your cabal or hpack (`package.yaml`) file.";
                example = "./.";
              }
              // {
                name = "source directory";
              };

            ghcVersion =
              lib.mkOption {
                type = lib.types.enum [
                  "9.10"
                  "9.8"
                  "9.6"
                  "9.4"
                  "9.2"
                  "9.0"
                ];
                description = "The major GHC version to use.";
                default = "9.8";
              }
              // {
                name = "GHC version";
              };

            webServer = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule webServerSubmodule);
              description = "Whether to build a server configuration based on this project and deploy it to the garnix cloud.";
              default = null;
            };

            devTools =
              lib.mkOption {
                type = lib.types.listOf lib.types.package;
                description = "A list of packages make available in the devshell for this project (and `default` devshell). This is useful for things like LSPs, formatters, etc.";
                default = [ ];
              }
              // {
                name = "development tools";
              };

            buildDependencies = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              description = ''
              A list of additional dependencies required to build this package. They are made available in the devshell, and at build time.

              (It's not necessary to include library dependencies manually, these will be included automatically.)
              '';
              default = [ ];
            };

            runtimeDependencies = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              description = "A list of dependencies required at runtime. They are made available in the devshell, at build time, and are available on the server at runtime.";
              default = [ ];
            };
          };

          ghcStr = ghc: "ghc${builtins.replaceStrings [ "." ] [ "" ] ghc}";
        in
        {
          options = {
            haskell = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule haskellSubmodule);
              description = "An attrset of Haskell projects to generate.";
            };
          };

          config = {
            packages = builtins.mapAttrs (
              name: projectConfig:
              pkgs.haskell.packages."${ghcStr projectConfig.ghcVersion}".callCabal2nix "haskell-${name}"
                projectConfig.src
                { }
            ) config.haskell;

            devShells = builtins.mapAttrs (
              name: projectConfig:
              let
                haskellPackages = pkgs.haskell.packages."${ghcStr projectConfig.ghcVersion}";
              in
              pkgs.mkShell {
                inputsFrom = [
                  (haskellPackages.callCabal2nix "haskell-${name}" projectConfig.src { }).env
                ];
                buildInputs = [
                  haskellPackages.cabal-install
                  haskellPackages.hpack
                ];
              }
            ) config.haskell;

            nixosConfigurations =
              let
                hasAnyWebServer = builtins.any (projectConfig: projectConfig.webServer != null) (
                  builtins.attrValues config.haskell
                );
              in
              lib.mkIf hasAnyWebServer {
                default =
                  # Global NixOS configuration
                  [
                    {
                      services.nginx = {
                        enable = true;
                        recommendedProxySettings = true;
                        recommendedOptimisation = true;
                        virtualHosts.default = {
                          default = true;
                        };
                      };

                      networking.firewall.allowedTCPPorts = [ 80 ];
                    }
                  ]
                  ++
                  # Per project NixOS configuration
                  (builtins.attrValues (
                    builtins.mapAttrs (
                      name: projectConfig:
                      lib.mkIf (projectConfig.webServer != null) {
                        environment.systemPackages = projectConfig.runtimeDependencies;

                        systemd.services.${name} = {
                          description = "${name} Haskell garnix module";
                          wantedBy = [ "multi-user.target" ];
                          after = [ "network-online.target" ];
                          wants = [ "network-online.target" ];
                          environment.PORT = toString projectConfig.webServer.port;
                          serviceConfig = {
                            Type = "simple";
                            DynamicUser = true;
                            ExecStart = lib.getExe (
                              pkgs.writeShellApplication {
                                name = "start-${name}";
                                runtimeInputs = [ config.packages.${name} ] ++ projectConfig.runtimeDependencies;
                                text = projectConfig.webServer.command;
                              }
                            );
                          };
                        };

                        services.nginx.virtualHosts.default.locations.${projectConfig.webServer.path}.proxyPass =
                          "http://localhost:${toString projectConfig.webServer.port}";
                      }
                    ) config.haskell
                  ));
              };
          };
        };
    };
}
