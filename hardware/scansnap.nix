{...}: {
  imports = [./scanner.nix];
  hardware.sane.drivers.scanSnap.enable = true;
}
