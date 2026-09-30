{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-gpu-nvidia-nonprime];

  hardware = {
    nvidia = {
      # The open source driver does not support Maxwell GPUs.
      open = false;
    }; # nvidia
  }; # hardware
}
