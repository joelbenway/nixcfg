# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  modulesPath,
  ...
}: let
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (lib.custom.relativeToRoot "hardware/quadrom2000.nix")
    (lib.custom.relativeToRoot "hardware/ivybridge.nix")
    ./storage.nix
  ]; # imports

  age = {
    identityPaths = ["/persist${hostKeyPath}"];
    secrets = {
      wifi-environment-variables = {
        file = lib.custom.relativeToRoot "secrets/wifi.env.age";
        mode = "600";
        owner = "root";
        group = "users";
      };
      wifi-guest-environment-variables = {
        file = lib.custom.relativeToRoot "secrets/wifi-guest.env.age";
        mode = "600";
        owner = "root";
        group = "users";
      };
      tailscale-oauth-env = {
        file = lib.custom.relativeToRoot "secrets/tailscale-oauth.env.age";
        name = "tailscale.env";
        mode = "400";
        owner = "root";
        group = "root";
      };
      storage-luks-passphrase = {
        file = lib.custom.relativeToRoot "secrets/storage-luks-passphrase.age";
      };
      hermes-env = {
        file = lib.custom.relativeToRoot "secrets/hermes.env.age";
        name = "hermes.env";
        mode = "440";
        owner = "root";
        group = "root";
      }; # hermes-env
      nix-builder-ssh = {
        file = lib.custom.relativeToRoot "secrets/nix-builder-ssh.age";
        path = "/root/.ssh/nix-builder";
        mode = "600";
        owner = "root";
        group = "root";
      };
    }; # secrets
  }; # age

  impermanence = {
    enable = true;
    device = "cryptroot";
    directories = [
      "/var/lib/samba"
      "/var/lib/containers"
      "/var/lib/hermes"
      "/var/lib/private/actual"
      "/var/lib/caddy"
    ];
  }; # impermanence

  systemd.tmpfiles.rules = [
    "d /var/lib/private 0700 root root -"
  ];

  openssh = {
    enable = true;
    inherit hostKeyPath;
  };

  distributed-builds = {
    enable = true;
    keyFile = config.age.secrets.nix-builder-ssh.path;
  };

  binary-cache.server = {
    enable = true;
  };

  joel = {
    enable = true;
    desktop = false;
  }; # joel

  katy = {
    enable = true;
    desktop = false;
  }; # katy

  networkstack = {
    hostName = hostname;
    wifiHome = false;
    wifiLab = true;
    envFiles = [
      config.age.secrets.wifi-environment-variables.path
      config.age.secrets.wifi-guest-environment-variables.path
    ];
  }; # networkstack

  tailscale = {
    enable = true;
    envFile = config.age.secrets.tailscale-oauth-env.path;
  }; # tailscale

  services.tailscale.extraSetFlags = ["--operator=caddy"];

  hermes = {
    enable = false;
    environmentFiles = [
      config.age.secrets.hermes-env.path
    ];
  }; # hermes

  # Samba Configuration
  samba = {
    enable = true;
    shares = {
      # Shared folders
      Public = {
        path = "/storage/public";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        comment = "Public Guest Share";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nobody";
        "force group" = "users";
      }; # Public
      Media = {
        path = "/storage/media";
        browseable = "yes";
        "read only" = "yes";
        "write list" = "joel katy";
        "guest ok" = "yes";
        comment = "Shared Media Collection";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force group" = "users";
      }; # Media

      # Private user folders
      Joel = {
        path = "/storage/users/joel";
        "valid users" = "joel";
        "read only" = "no";
        browseable = "yes";
        "force user" = "joel";
        "force group" = "users";
      }; # Joel
      Katy = {
        path = "/storage/users/katy";
        "valid users" = "katy";
        "read only" = "no";
        browseable = "yes";
        "force user" = "katy";
        "force group" = "users";
      }; # Katy
    }; # shares
  }; # samba

  copyparty = {
    enable = true;
    port = 3920;
  }; # copyparty

  actual = {
    enable = true;
    hostname = "127.0.0.1";
    port = 5005;
  }; # actual

  networking.firewall.allowedTCPPorts = [
    80
    443
    3923
    5006
  ];

  services.caddy = {
    enable = true;
    extraConfig = ''
      (tailscale_auth) {
        map {remote_host} {ts_user} {
          100.82.75.113 joel
          100.117.132.66 joel
          100.67.148.7 joel
          100.77.161.1 joel
          100.75.211.110 joel
          100.74.22.119 katy
          default ""
        }
        map {ts_user} {actual_pw} {
          joel "snark"
          katy "snark"
          default ""
        }
      }

      files.benway.me {
        tls internal
        import tailscale_auth
        reverse_proxy 127.0.0.1:3920 {
          header_up X-Tailscale-User {ts_user}
        }
      }

      budget.benway.me {
        tls internal
        import tailscale_auth
        reverse_proxy 127.0.0.1:5005 {
          header_up x-actual-password {actual_pw}
        }
      }

      zita.gentoo-humboldt.ts.net {
        redir https://zita.gentoo-humboldt.ts.net:3923
      }

      zita.gentoo-humboldt.ts.net:3923 {
        import tailscale_auth
        reverse_proxy 127.0.0.1:3920 {
          header_up X-Tailscale-User {ts_user}
        }
      }

      zita.gentoo-humboldt.ts.net:5006 {
        import tailscale_auth
        reverse_proxy 127.0.0.1:5005 {
          header_up x-actual-password {actual_pw}
        }
      }
    '';
  };

  systemd.services.caddy = {
    after = ["tailscaled-set.service"];
    wants = ["tailscaled-set.service"];
  };

  boot = {
    enableContainers = true;
    extraModulePackages = [];
    initrd = {
      systemd.enable = true;
      availableKernelModules = [
        "xhci_pci"
        "ahci"
        "nvme"
        "usb_storage"
        "uas"
        "usbhid"
        "sd_mod"
        "rtsx_pci_sdmmc"
        "isci" # Intel C600 SAS/SATA SCU controller for internal drive bays on HP Z620
        "mpt3sas"
        "mpt2sas"
        "e1000e" # Intel 82579LM & 82574L Gigabit Ethernet for HP Z620
      ];
      kernelModules = ["e1000e"];
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          authorizedKeys = [
            (import (lib.custom.relativeToRoot "data/keys.nix")).hosts.michael
            (import (lib.custom.relativeToRoot "data/keys.nix")).users.joel
          ];
          hostKeys = ["/persist/etc/ssh/initrd_host_ed25519_key"];
          ignoreEmptyHostKeys = true;
        };
      };
      systemd.network = {
        enable = true;
        networks."10-lan" = {
          matchConfig.Name = "en* eth*";
          networkConfig = {
            Address = "192.168.77.20/24";
            Gateway = "192.168.77.1";
            DNS = ["192.168.77.1"];
            DHCP = "yes";
          };
        };
      };
    }; # initrd
    kernelModules = [];
    kernelParams = [
      "intel_iommu=on"
    ];
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    }; # loader
  }; # boot

  disko.devices = (import ./disks.nix {}).disko.devices;

  fileSystems."/var/log".neededForBoot = true;
}
