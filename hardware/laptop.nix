{lib, ...}: {
  powerManagement = {
    enable = true;
    cpuFreqGovernor = lib.mkDefault "ondemand";
    powertop.enable = lib.mkDefault true;
  }; # powerManagement

  services = {
    thermald.enable = lib.mkDefault true;
  }; # services
}
