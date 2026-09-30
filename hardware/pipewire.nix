{...}: {
  services = {
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    }; # pipewire
  }; # services

  security.rtkit.enable = true;
}
