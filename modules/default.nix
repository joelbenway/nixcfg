{lib, ...}: {
  imports = lib.custom.scanFiles ./.;
}
