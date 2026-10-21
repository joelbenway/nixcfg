# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: let
  categories = {
    Suspicious = {
      description = "Firebog Suspicious Lists";
      lists = [
        {
          url = "https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt";
          description = "Firebog Green (Suspicious Lists) - PolishFiltersTeam KADhosts";
        }
        {
          url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts";
          description = "Firebog Green (Suspicious Lists) - Fademind's Spammers";
        }
        {
          url = "https://v.firebog.net/hosts/static/w3kbl.txt";
          description = "Firebog Green (Suspicious Lists) - WaLLy3K's Blacklist";
        }
        {
          url = "https://raw.githubusercontent.com/matomo-org/referrer-spam-blacklist/master/spammers.txt";
          description = "Firebog Blue (Suspicious Lists) - Matomo Referrer Spam";
        }
        {
          url = "https://someonewhocares.org/hosts/zero/hosts";
          description = "Firebog Blue (Suspicious Lists) - Someone Who Cares";
        }
        {
          url = "https://raw.githubusercontent.com/RooneyMcNibNug/pihole-stuff/master/SNAFU.txt";
          description = "Firebog Blue (Suspicious Lists) - RooneyMcNibNug's SNAFU list";
        }
      ];
    };

    Advertising = {
      description = "Firebog Advertising Lists";
      lists = [
        {
          url = "https://adaway.org/hosts.txt";
          description = "Firebog Green (Advertising Lists) - AdAway";
        }
        {
          url = "https://v.firebog.net/hosts/AdguardDNS.txt";
          description = "Firebog Green (Advertising Lists) - Adguard DNS";
        }
        {
          url = "https://v.firebog.net/hosts/Admiral.txt";
          description = "Firebog Green (Advertising Lists) - LanikSJ's Admiral Anti-Adblock";
        }
        {
          url = "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt";
          description = "Firebog Green (Advertising Lists) - Anudeep ND's Blacklist";
        }
        {
          url = "https://v.firebog.net/hosts/Easylist.txt";
          description = "Firebog Green (Advertising Lists) - Easylist";
        }
        {
          url = "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext";
          description = "Firebog Green (Advertising Lists) - Peter Lowe's Adservers";
        }
        {
          url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts";
          description = "Firebog Green (Advertising Lists) - Fademind's Unchecky Ads";
        }
        {
          url = "https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts";
          description = "Firebog Green (Advertising Lists) - hostsVN";
        }
      ];
    };

    Tracking = {
      description = "Firebog Tracking & Telemetry Lists";
      lists = [
        {
          url = "https://v.firebog.net/hosts/Easyprivacy.txt";
          description = "Firebog Green (Tracking & Telemetry Lists) - Easyprivacy";
        }
        {
          url = "https://v.firebog.net/hosts/Prigent-Ads.txt";
          description = "Firebog Green (Tracking & Telemetry Lists) - Fabrice Prigent's Ads";
        }
        {
          url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts";
          description = "Firebog Green (Tracking & Telemetry Lists) - Fademind's 2o7 Network Trackers";
        }
        {
          url = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt";
          description = "Firebog Green (Tracking & Telemetry Lists) - Crazy Max's Microsoft Telemetry";
        }
        {
          url = "https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt";
          description = "Firebog Green (Tracking & Telemetry Lists) - Geoffrey Frogeye's First-Party Trackers";
        }
      ];
    };

    Malicious = {
      description = "Firebog Malicious Lists";
      lists = [
        {
          url = "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt";
          description = "Firebog Green (Malicious Lists) - DandelionSprout's Anti Malware Filter";
        }
        {
          url = "https://v.firebog.net/hosts/Prigent-Crypto.txt";
          description = "Firebog Green (Malicious Lists) - Fabrice Prigent's Cryptojacking";
        }
        {
          url = "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts";
          description = "Firebog Green (Malicious Lists) - Fademind's Risky Hosts";
        }
        {
          url = "https://phishing.army/download/phishing_army_blocklist_extended.txt";
          description = "Firebog Green (Malicious Lists) - Phishing Army's Extended Blocklist";
        }
        {
          url = "https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt";
          description = "Firebog Green (Malicious Lists) - Quidsup Malicious";
        }
        {
          url = "https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt";
          description = "Firebog Green (Malicious Lists) - Spam404";
        }
        {
          url = "https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/hosts";
          description = "Firebog Green (Malicious Lists) - Echap's Stalkerware Indicators";
        }
        {
          url = "https://urlhaus.abuse.ch/downloads/hostfile/";
          description = "Firebog Green (Malicious Lists) - URLhaus Malicious URL blocklist";
        }
        {
          url = "https://lists.cyberhost.uk/malware.txt";
          description = "Firebog Green (Malicious Lists) - CyberHost.uk Malware Domains";
        }
        {
          url = "https://malware-filter.gitlab.io/malware-filter/phishing-filter-hosts.txt";
          description = "Firebog Blue (Malicious Lists) - Curbengh's Phishing filter";
        }
        {
          url = "https://v.firebog.net/hosts/Prigent-Malware.txt";
          description = "Firebog Blue (Malicious Lists) - Fabrice Prigent's Malware";
        }
        {
          url = "https://raw.githubusercontent.com/jarelllama/Scam-Blocklist/main/lists/wildcard_domains/scams.txt";
          description = "Firebog Blue (Malicious Lists) - Jarelllama's Scam Blocklist";
        }
        {
          url = "https://v.firebog.net/hosts/RPiList-Malware.txt";
          description = "Firebog Blue (Malicious Lists) - RPiList Malware";
        }
        {
          url = "https://v.firebog.net/hosts/RPiList-Phishing.txt";
          description = "Firebog Blue (Malicious Lists) - RPiList Phishing";
        }
      ];
    };

    Other = {
      description = "Firebog Other Lists (Adult & Social Media)";
      lists = [
        {
          url = "https://raw.githubusercontent.com/chadmayfield/my-pihole-blocklists/master/lists/pi_blocklist_porn_top1m.list";
          description = "Firebog Blue (Other Lists) - Chad Mayfield (Top 1M)";
        }
        {
          url = "https://v.firebog.net/hosts/Prigent-Adult.txt";
          description = "Firebog Blue (Other Lists) - Fabrice Prigent's Adult (LARGE: 90MB, 3M+ entries)";
        }
        {
          url = "https://raw.githubusercontent.com/anudeepND/blacklist/master/facebook.txt";
          description = "Firebog Blue (Other Lists) - Anudeep ND's Facebook Blacklist";
        }
      ];
    };
  };

  defaultLists = [
    {
      url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
      description = "Steven Black unified hosts file";
    }
    {
      url = "https://raw.githubusercontent.com/AnonymouseGlobal/blocklist/master/blocklist.txt";
      description = "Anonymouse ad blocklist";
    }
  ];

  allLists = map (it: {
    inherit (it) url description;
    type = "block";
    enabled = true;
  }) (defaultLists ++ lib.concatMap (c: c.lists) (lib.attrValues categories));
in {
  inherit categories defaultLists allLists;
}
