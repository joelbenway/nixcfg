# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  domain = "benway.me";
  localDomain = "skylab.home";
  lanSubnet = "192.168.77.0/24";
  hosts = {
    michael = {
      ip = "192.168.77.1";
      fqdn = "michael.skylab.home";
    };
    zita = {
      ip = "192.168.77.20";
      fqdn = "zita.skylab.home";
    };
  };
}
