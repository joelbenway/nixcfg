{
  lib,
  pkgs,
  ...
}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
in
  import (lib.custom.relativeToRoot "users/common") {
    inherit lib;
    username = "eliza";
    description = "Eliza Benway";
    isWheel = false;
    authorizedKeys = [keys.joel];
    packages = with pkgs; [
      gcompris
    ];
    extraConfig = {
      plasma.users.eliza.discover = true;
      users.users.eliza.password = "eliza";
    }; # extraConfig
  }
