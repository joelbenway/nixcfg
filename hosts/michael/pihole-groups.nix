# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: let
  categories = {
    Advertising = {
      description = "HaGeZi Multi PRO++ (Ads, Trackers, Telemetry, Badware)";
      lists = [
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.plus.txt";
          description = "HaGeZi Multi PRO++ (ABP wildcard format)";
        }
      ];
    };

    Tracking = {
      description = "HaGeZi Native Device & OS Telemetry Trackers";
      lists = [
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.samsung.txt";
          description = "HaGeZi Native Tracker - Samsung";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.apple.txt";
          description = "HaGeZi Native Tracker - Apple";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.winoffice.txt";
          description = "HaGeZi Native Tracker - Windows & Office";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.xiaomi.txt";
          description = "HaGeZi Native Tracker - Xiaomi";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.huawei.txt";
          description = "HaGeZi Native Tracker - Huawei";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.oppo-realme.txt";
          description = "HaGeZi Native Tracker - Oppo & Realme";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.vivo.txt";
          description = "HaGeZi Native Tracker - Vivo";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.amazon.txt";
          description = "HaGeZi Native Tracker - Amazon";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.lgwebos.txt";
          description = "HaGeZi Native Tracker - LG webOS";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.roku.txt";
          description = "HaGeZi Native Tracker - Roku";
        }
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.tiktok.txt";
          description = "HaGeZi Native Tracker - TikTok";
        }
      ];
    };

    Malicious = {
      description = "HaGeZi Threat Intelligence Feeds (Malware, Phishing, Scam, Cryptojacking)";
      lists = [
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt";
          description = "HaGeZi Threat Intelligence Feeds (ABP wildcard format)";
        }
      ];
    };

    Bypass = {
      description = "HaGeZi Encrypted DNS / DoH Bypass Prevention";
      lists = [
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/doh.txt";
          description = "HaGeZi Encrypted DNS / DoH Servers (ABP wildcard format)";
        }
      ];
    };

    Other = {
      description = "Adult Content & Social Media Lists";
      lists = [
        {
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/nsfw.txt";
          description = "HaGeZi NSFW / Adult Content (ABP wildcard format)";
        }
        {
          url = "https://raw.githubusercontent.com/anudeepND/blacklist/master/facebook.txt";
          description = "Anudeep ND's Facebook Blacklist";
        }
      ];
    };
  };

  defaultLists = [];

  allLists = map (it: {
    inherit (it) url description;
    type = "block";
    enabled = true;
  }) (defaultLists ++ lib.concatMap (c: c.lists) (lib.attrValues categories));
in {
  inherit categories defaultLists allLists;
}
