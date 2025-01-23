{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }:
  let
    lib = nixpkgs.lib;

    webServerSubmodule.options = {
      command = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "The command to run to start the server in production";
        example = "server --port 7000";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "Port to forward incoming http requests to";
        example = 7000;
      };

      path = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "URL path to host your haskell server on";
        default = "/";
      };
    };

    haskellSubmodule.options = {
      src = lib.mkOption {
        type = lib.types.path;
        description = "A path to the directory containing your cabal or hpack file";
        example = "./.";
      };

      ghcVersion = lib.mkOption {
        type = lib.types.enum ["9.10" "9.8" "9.6" "9.4" "9.2" "9.0"];
        description = "The major GHC version to use";
        default = "9.8";
      };

      webServer = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule webServerSubmodule);
        description = "Whether to create an HTTP server based on this Haskell project";
        default = null;
      };

      devTools = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        description = "A list of packages make available in the devshell for this project (and `default` devshell). This is useful for things like LSPs, formatters, etc.";
        default = [];
      };

      buildDependencies = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        description = "A list of dependencies required to build this package. They are made available in the devshell, and at build time";
        default = [];
      };

      runtimeDependencies = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        description = "A list of dependencies required at runtime. They are made available in the devshell, at build time, and are available on the server at runtime";
        default = [];
      };
    };
  in {
    garnixModules.default = { pkgs, config, ... }:
    let ghcStr = ghc: "ghc${builtins.replaceStrings ["."] [""] ghc}";
    in {
      options = {
        haskell = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule haskellSubmodule);
          description = "An attrset of Haskell projects to generate";
        };
      };

      config =
      rec {
        packages = builtins.mapAttrs (name: projectConfig:
          pkgs.haskell.packages."${ghcStr projectConfig.ghcVersion}".callCabal2nix
            "haskell-${name}"
            projectConfig.src { }
        ) config.haskell;

        devShells = builtins.mapAttrs (name: projectConfig:
          pkgs.mkShell {
             inputsFrom = [ (packages.${name}.callCabal2nix "haskell-${name}" ./. { }).env ];
          }
        ) config.haskell;

        nixosConfigurations = let
          hasAnyWebServer =
            builtins.any (projectConfig: projectConfig.webServer != null)
            (builtins.attrValues config.haskell);
        in lib.mkIf hasAnyWebServer {
          default =
          # Global nixos configuration
          [{
            services.nginx = {
              enable = true;
              recommendedProxySettings = true;
              recommendedOptimisation = true;
              virtualHosts.default = {
                default = true;
              };
            };

            networking.firewall.allowedTCPPorts = [ 80 ];
          }]
          ++
          # Per project nixos configuration
          (builtins.attrValues (builtins.mapAttrs (name: projectConfig: lib.mkIf (projectConfig.webServer != null) {
            environment.systemPackages = projectConfig.runtimeDependencies;

            systemd.services.${name} = {
              description = "${name} haskell garnix module";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              serviceConfig = {
                Type = "simple";
                DynamicUser = true;
                ExecStart = lib.getExe (pkgs.writeShellApplication {
                  name = "start-${name}";
                  runtimeInputs = [ config.packages.${name} ] ++ projectConfig.runtimeDependencies;
                  text = projectConfig.webServer.command;
                });
              };
            };

            services.nginx.virtualHosts.default.locations.${projectConfig.webServer.path}.proxyPass = "http://localhost:${toString projectConfig.webServer.port}";
          }) config.haskell));
      };};
    };
  };
}
