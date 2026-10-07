# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: {
  options.networkstack = {
    hostName = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Networking Host name";
    }; # hostName
    enable = lib.mkEnableOption "Enable Network Stack";
    wifiHome = lib.mkEnableOption "Enable Home Wifi";
    wifiLab = lib.mkEnableOption "Enable Lab Wifi";
    wifiIot = lib.mkEnableOption "Enable Iot Wifi";
    wifi = lib.mkEnableOption "Enable Wifi";
    envFiles = lib.mkOption {
      type = with lib.types; listOf (either path str);
      default = [];
      description = "List of Environment Files with wifi profile info.";
    }; #envFiles
  }; # options.networkstack

  config = lib.mkMerge [
    {
      # if hostName is set, enable networkstack
      networkstack.enable = lib.mkDefault (config.networkstack.hostName != null);
      # if any specific wifi is enable, enable wifi
      networkstack.wifi = lib.mkMerge [
        (lib.mkDefault (
          config.networkstack.wifiHome
          || config.networkstack.wifiLab
          || config.networkstack.wifiIot
        ))
        # if there are no envFiles, force wifi disabled
        (lib.mkIf (config.networkstack.envFiles == []) (lib.mkForce false))
      ];
    }
    (lib.mkIf config.networkstack.enable {
      networking = {
        hostName = config.networkstack.hostName;
        networkmanager = {
          enable = true;
          wifi = {
            powersave = config.networkstack.wifi;
          }; # wifi

          ensureProfiles = lib.mkIf config.networkstack.wifi {
            environmentFiles = config.networkstack.envFiles;
            profiles = {
              home-wifi = lib.mkIf config.networkstack.wifiHome {
                connection = {
                  id = "home-wifi";
                  permissions = "";
                  type = "wifi";
                }; # connection
                ipv4 = {
                  dns-search = "";
                  method = "auto";
                }; # ipv4
                wifi = {
                  mac-address-blacklist = "";
                  mode = "infrastructure";
                  ssid = "$HOME_WIFI_SSID";
                }; # wifi
                wifi-security = {
                  auth-alg = "open";
                  key-mgmt = "wpa-psk";
                  psk = "$HOME_WIFI_PSK";
                }; # wifi-security
              }; # home-wifi
              lab-wifi = lib.mkIf config.networkstack.wifiLab {
                connection = {
                  id = "lab-wifi";
                  permissions = "";
                  type = "wifi";
                }; # connection
                ipv4 = {
                  dns-search = "";
                  method = "auto";
                }; # ipv4
                wifi = {
                  mac-address-blacklist = "";
                  mode = "infrastructure";
                  ssid = "$LAB_WIFI_SSID";
                }; # wifi
                wifi-security = {
                  auth-alg = "open";
                  key-mgmt = "wpa-psk";
                  psk = "$LAB_WIFI_PSK";
                }; # wifi-security
              }; # lab-wifi
              iot-wifi = lib.mkIf config.networkstack.wifiIot {
                connection = {
                  id = "iot-wifi";
                  permissions = "";
                  type = "wifi";
                }; # connection
                ipv4 = {
                  dns-search = "";
                  method = "auto";
                }; # ipv4
                wifi = {
                  mac-address-blacklist = "";
                  mode = "infrastructure";
                  ssid = "$IOT_WIFI_SSID";
                }; # wifi
                wifi-security = {
                  auth-alg = "open";
                  key-mgmt = "wpa-psk";
                  psk = "$IOT_WIFI_PSK";
                }; # wifi-security
              }; # iot-wifi
            }; # profiles
          }; # ensureProfiles
        }; # networkmanager

        firewall.enable = true;

        # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
        # (the default) this is the recommended approach. When using systemd-networkd it's
        # still possible to use this option, but it's recommended to use it in conjunction
        # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
        useDHCP = lib.mkDefault true;
        # interfaces.enp0s31f6.useDHCP = lib.mkDefault true;
        # interfaces.wlp1s0.useDHCP = lib.mkDefault true;
      }; # networking
    })
  ]; # config
}
