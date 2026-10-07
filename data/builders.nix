# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
let
  defaultFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];

  mkBuilder = {
    maxJobs,
    speedFactor,
    extraFeatures ? [],
  }: {
    inherit maxJobs speedFactor;
    supportedFeatures = defaultFeatures ++ extraFeatures;
  };
in {
  agnes = mkBuilder {
    maxJobs = 2;
    speedFactor = 1;
    extraFeatures = ["gccarch-skylake"];
  };

  francis = mkBuilder {
    maxJobs = 6;
    speedFactor = 2;
    extraFeatures = ["gccarch-skylake"];
  };

  jerome = mkBuilder {
    maxJobs = 2;
    speedFactor = 1;
    extraFeatures = ["gccarch-skylake"];
  };

  michael = mkBuilder {
    maxJobs = 8;
    speedFactor = 3;
    extraFeatures = ["gccarch-alderlake"];
  };

  zita = mkBuilder {
    maxJobs = 16;
    speedFactor = 4;
    extraFeatures = ["gccarch-ivybridge"];
  };
}
