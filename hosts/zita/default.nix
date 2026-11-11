# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
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
      cloudflare-api-env = {
        file = lib.custom.relativeToRoot "secrets/cloudflare-api.env.age";
        name = "cloudflare.env";
        mode = "440";
        owner = "caddy";
        group = "caddy";
      };
      nix-builder-ssh = {
        file = lib.custom.relativeToRoot "secrets/nix-builder-ssh.age";
        path = "/root/.ssh/nix-builder";
        mode = "600";
        owner = "root";
        group = "root";
      };
      plaid-env = {
        file = lib.custom.relativeToRoot "secrets/plaid.env.age";
        name = "plaid.env";
        mode = "440";
        owner = "plaid-sync";
        group = "plaid-sync";
      };
      zita-cache-priv-key = {
        file = lib.custom.relativeToRoot "secrets/zita-cache-priv-key.age";
        mode = "400";
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
      "/var/lib/signal-cli"
      "/var/lib/private/actual"
      "/var/lib/caddy"
    ];
  }; # impermanence

  systemd.tmpfiles.rules = [
    "d /var/lib/private 0700 root root -"
    "z /var/lib/private 0700 root root -"
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
    signKeyPath = config.age.secrets.zita-cache-priv-key.path;
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
  systemd.services.tailscaled.environment.TS_PERMIT_CERT_UID = "caddy";

  hermes = {
    enable = true;
    environmentFiles = [
      config.age.secrets.hermes-env.path
    ];
  }; # hermes

  # Samba Configuration (shares auto-derived from data/shares.nix)
  samba.enable = true;

  copyparty.enable = true;

  actual = {
    enable = true;
    hostname = "127.0.0.1";
    plaid = {
      enable = true;
      environmentFile = config.age.secrets.plaid-env.path;
    };
  }; # actual

  jellyfin = {
    enable = true;
    mediaDir = "/storage/media";
    hardwareAcceleration = {
      enable = true;
      type = "nvenc";
      device = "/dev/dri/renderD128";
    };
  }; # jellyfin

  networking = {
    nameservers = ["192.168.77.1"];
    firewall.allowedTCPPorts = [
      80
      443
      ports.copyparty.tailscale
      ports.actual.tailscale
      ports.plaid.tailscale
      ports.jellyfin.tailscale
    ];
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.4"];
      hash = "sha256-5a5cpFl90pEWt0lUC4ZJQ7g+1//ZvsRhee64Dt9vh5o=";
    };
    environmentFile = config.age.secrets.cloudflare-api-env.path;
    extraConfig = ''
      files.benway.me {
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
        reverse_proxy 127.0.0.1:${toString ports.copyparty.internal}
      }

      budget.benway.me {
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
        header Cross-Origin-Resource-Policy cross-origin
        reverse_proxy 127.0.0.1:${toString ports.actual.internal}
      }

      plaid.benway.me {
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
        reverse_proxy 127.0.0.1:${toString ports.plaid.internal}
      }

      jellyfin.benway.me {
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        }
        reverse_proxy 127.0.0.1:${toString ports.jellyfin.internal}
      }

      ${hostname}.${config.tailscale.tailnet} {
        redir https://${hostname}.${config.tailscale.tailnet}:${toString ports.copyparty.tailscale}
      }

      ${hostname}.${config.tailscale.tailnet}:${toString ports.copyparty.tailscale} {
        reverse_proxy 127.0.0.1:${toString ports.copyparty.internal}
      }

      ${hostname}.${config.tailscale.tailnet}:${toString ports.actual.tailscale} {
        header Cross-Origin-Resource-Policy cross-origin
        reverse_proxy 127.0.0.1:${toString ports.actual.internal}
      }

      ${hostname}.${config.tailscale.tailnet}:${toString ports.plaid.tailscale} {
        reverse_proxy 127.0.0.1:${toString ports.plaid.internal}
      }

      ${hostname}.${config.tailscale.tailnet}:${toString ports.jellyfin.tailscale} {
        reverse_proxy 127.0.0.1:${toString ports.jellyfin.internal}
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
          port = ports.initrdSsh.ssh;
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

  disko.devices = (import ./disks.nix {inherit lib;}).disko.devices;

  fileSystems."/var/log".neededForBoot = true;

  auto-update = {
    enable = true;
    dates = "*-*-* 05:00:00";
    randomizedDelaySec = "5m";
    gitMirror.enable = true;
    cacheWarmer = {
      enable = true;
      hosts = ["michael" "francis" "agnes" "jerome"];
    };
    canary.services = [
      "harmonia.socket"
      "caddy"
      "samba-smbd"
      "container@copyparty"
      "hermes-agent"
    ];
    # Zita uses initrd SSH unlock from Michael (no TPM 2.0); let Michael unlock Zita on scheduled reboots
    reboot = {
      enable = true;
      window = "03:00";
    };
  };
}
