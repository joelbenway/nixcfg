{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel];

  boot.kernelParams = [
    "i915.enable_guc=3"
    "i915.enable_fbc=1"
    "i915.enable_psr=1"
    "i915.enable_dc=0"
  ];

  hardware = {
    intelgpu = {
      driver = "i915";
      vaapiDriver = "intel-media-driver";
    }; # intelgpu
  }; # hardware
}
