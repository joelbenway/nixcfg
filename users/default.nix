{lib, ...}: {
  imports = lib.custom.scanFiles ./.;

  home-manager.backupFileExtension = "hmbak";
}
