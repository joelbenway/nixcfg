{lib, ...}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
in
  import (lib.custom.relativeToRoot "users/common") {
    inherit lib;
    username = "katy";
    description = "Katy Benway";
    authorizedKeys = [keys.joel keys.katy];
  }
