{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel];

  boot.kernelParams = [
    "i915.enable_guc=2"
    "i915.enable_fbc=1"
    "i915.enable_psr=0"
    # "i915.enable_dc=0"
  ];

  hardware.intelgpu = {
    computeRuntime = "legacy";
    vaapiDriver = "intel-media-driver";
  };
}
