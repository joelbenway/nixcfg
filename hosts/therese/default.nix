# nix build .#nixosConfigurations.therese.config.system.build.isoImage
{
  lib,
  pkgs,
  modulesPath,
  self,
  hostname,
  platform,
  ...
}: let
  wifiEnv = "${lib.custom.relativeToRoot "wifi.env"}";
  sshKey = lib.custom.relativeToRoot "id_ed25519";

  filteredSource =
    builtins.filterSource (
      srcpath: type:
        baseNameOf srcpath
        != ".git"
        && baseNameOf srcpath != ".gitignore"
        && type != "symlink"
    )
    self;

  installScript = pkgs.writeShellScriptBin "install" ''
    echo "Installing..."
    exec /iso/nixcfg/hosts/therese/install_flake --key /etc/id_ed25519
  '';
in {
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    (lib.custom.relativeToRoot "modules/networkstack.nix")
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nixpkgs.hostPlatform = platform;

  users.users.nixos = {
    openssh.authorizedKeys.keys = let keys = import (lib.custom.relativeToRoot "data/keys.nix"); in [keys.joel];
  }; # users.users.nixos

  networkstack = {
    hostName = hostname;
    wifiHome = true;
    envFile = wifiEnv;
  }; #networkstack

  environment.etc."id_ed25519" = {
    source = sshKey;
    mode = "0444";
  };

  isoImage.contents = [
    {
      source = filteredSource;
      target = "/nixcfg";
    }
  ];

  environment.systemPackages = with pkgs; [
    age
    btrfs-progs
    disko
    git
    installScript
    sbctl
    util-linux
  ];
}
