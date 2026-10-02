{
  config,
  lib,
  pkgs,
  ...
}: {
  options.devenvshell = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = "Enable devenv shell";
    }; # enable
  }; # options.devenvshell

  config = lib.mkIf config.devenvshell.enable {
    environment.systemPackages = with pkgs; [
      devenv
    ];

    nix.settings = {
      extra-substituters = ["https://devenv.cachix.org"];
      extra-trusted-public-keys = ["devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="];
    };

    programs = {
      direnv.enable = true;
    };
  }; # config
}
