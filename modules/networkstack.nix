# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: let
  mkWifiProfile = {
    id,
    ssid,
    psk,
    keyMgmt ? "sae",
  }: {
    connection = {
      inherit id;
      permissions = "";
      type = "wifi";
    };
    ipv4 = {
      dns-search = "";
      method = "auto";
    };
    wifi = {
      mac-address-blacklist = "";
      mode = "infrastructure";
      inherit ssid;
    };
    wifi-security = {
      auth-alg = "open";
      key-mgmt = keyMgmt;
      inherit psk;
    };
  };
in {
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
    }; # envFiles
  }; # options.networkstack

  config = lib.mkMerge [
    {
      # if hostName is set, enable networkstack
      networkstack.enable = lib.mkDefault (config.networkstack.hostName != null);
      # if any specific wifi is enabled, enable wifi
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
              home-wifi = lib.mkIf config.networkstack.wifiHome (mkWifiProfile {
                id = "home-wifi";
                ssid = "$HOME_WIFI_SSID";
                psk = "$HOME_WIFI_PSK";
              });
              lab-wifi = lib.mkIf config.networkstack.wifiLab (mkWifiProfile {
                id = "lab-wifi";
                ssid = "$LAB_WIFI_SSID";
                psk = "$LAB_WIFI_PSK";
              });
              iot-wifi = lib.mkIf config.networkstack.wifiIot (mkWifiProfile {
                id = "iot-wifi";
                ssid = "$IOT_WIFI_SSID";
                psk = "$IOT_WIFI_PSK";
                keyMgmt = "wpa-psk";
              });
            }; # profiles
          }; # ensureProfiles
        }; # networkmanager

        firewall.enable = true;

        # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
        # (the default) this is the recommended approach. When using systemd-networkd it's
        # still possible to use this option, but it's recommended to use it in conjunction
        # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
        useDHCP = lib.mkDefault true;
      }; # networking
    })
  ]; # config
}
