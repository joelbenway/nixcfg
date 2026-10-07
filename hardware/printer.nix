# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
_: {
  services = {
    printing.enable = true;
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    }; # avahi
  }; # services
}
