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
  michael = mkBuilder {
    maxJobs = 8;
    speedFactor = 4;
    extraFeatures = ["gccarch-alderlake"];
  };

  zita = mkBuilder {
    maxJobs = 16;
    speedFactor = 3;
    extraFeatures = ["gccarch-ivybridge"];
  };
}
