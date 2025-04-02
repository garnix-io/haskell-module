{
  # The inputs should go in the top-level flake.

  outputs = inputs: inputs.garnix-lib.lib.mkModules {
    modules = [
      inputs.self.garnixModules.default
    ];

    config = { pkgs, ... }: {
      haskell = {
        haskell-project = {
          src = "${inputs.cradle}";
        };
      };
    };
  };
}
