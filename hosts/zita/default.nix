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
  fleetNetwork = import (lib.custom.relativeToRoot "data/network.nix");
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  servicesCatalog = import (lib.custom.relativeToRoot "data/services.nix");
  serviceList = builtins.attrValues servicesCatalog;
  defaultRedirectSvc = lib.findFirst (s: s.defaultTailscaleRedirect or false) servicesCatalog.copyparty serviceList;
  beszelHubKeySecret = lib.custom.relativeToRoot "secrets/beszel-hub-key.age";
  beszelHubEnvSecret = lib.custom.relativeToRoot "secrets/beszel-hub.env.age";
  beszelHermesEnvSecret = lib.custom.relativeToRoot "secrets/beszel-hermes.env.age";
  ntfyServerEnvSecret = lib.custom.relativeToRoot "secrets/ntfy-server.env.age";
  hasBeszelHubKey = builtins.pathExists beszelHubKeySecret;
  hasBeszelHubEnv = builtins.pathExists beszelHubEnvSecret;
  hasBeszelHermesEnv = builtins.pathExists beszelHermesEnvSecret;
  hasNtfyServerEnv = builtins.pathExists ntfyServerEnvSecret;
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (lib.custom.relativeToRoot "hardware/quadrom2000.nix")
    (lib.custom.relativeToRoot "hardware/ivybridge.nix")
    ./storage.nix
  ]; # imports

  age.secrets =
    {
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
      zita-cache-priv-key = {
        file = lib.custom.relativeToRoot "secrets/zita-cache-priv-key.age";
        mode = "400";
        owner = "root";
        group = "root";
      };
      vaultwarden-env = {
        file = lib.custom.relativeToRoot "secrets/vaultwarden.env.age";
        name = "vaultwarden.env";
        mode = "400";
        owner = "vaultwarden";
        group = "vaultwarden";
      };
    }
    // lib.optionalAttrs hasBeszelHubKey {
      beszel-hub-key = {
        file = beszelHubKeySecret;
        name = "beszel-hub-key";
        mode = "400";
        owner = "root";
        group = "root";
      };
    }
    // lib.optionalAttrs hasBeszelHubEnv {
      beszel-hub-env = {
        file = beszelHubEnvSecret;
        name = "beszel-hub.env";
        mode = "400";
        owner = "beszel-hub";
        group = "beszel-hub";
      };
    }
    // lib.optionalAttrs hasBeszelHermesEnv {
      beszel-hermes-env = {
        file = beszelHermesEnvSecret;
        name = "beszel-hermes.env";
        mode = "400";
        owner = "hermes";
        group = "hermes";
      };
    }
    // lib.optionalAttrs hasNtfyServerEnv {
      ntfy-server-env = {
        file = ntfyServerEnvSecret;
        name = "ntfy-server.env";
        mode = "400";
        owner = "ntfy-sh";
        group = "ntfy-sh";
      };
    }; # age.secrets

  impermanence.directories = [
    "/var/lib/samba"
    "/var/lib/containers"
    "/var/lib/hermes"
    "/var/lib/signal-cli"
    "/var/lib/private/actual"
    "/var/lib/caddy"
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/private 0700 root root -"
    "z /var/lib/private 0700 root root -"
  ];

  # Impermanence creates parent dirs like /var/lib/private with 0755 when mounting
  # /var/lib/private/actual; systemd requires /var/lib/private to be 0700 for DynamicUser services.
  system.activationScripts.fixVarLibPrivate = lib.stringAfter ["persist-files"] ''
    if [ -d /var/lib/private ]; then
      chmod 0700 /var/lib/private
    fi
  '';

  distributed-builds.enable = true;

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

  forgejo = {
    enable = true;
    admin.passwordFile = config.age.secrets.joel-passphrase.path;
  };

  vaultwarden = {
    enable = true;
    environmentFile = config.age.secrets.vaultwarden-env.path;
  };

  notify = {
    server = lib.mkIf hasNtfyServerEnv {
      enable = true;
      domain = servicesCatalog.ntfy.domain;
      environmentFile = config.age.secrets.ntfy-server-env.path;
      admin.passwordFile = config.age.secrets.joel-passphrase.path;
    };
    client = {
      urls = [
        "http://127.0.0.1:${toString ports.ntfy.internal}"
        "https://${servicesCatalog.ntfy.domain}"
        "https://zita.${config.tailscale.tailnet}:${toString ports.ntfy.tailscale}"
      ];
      onFailureUnits = [
        "caddy"
        "beszel-hub"
        "vaultwarden"
        "forgejo"
      ];
    };
  };

  beszel = {
    agent = {
      gpuCollectors = ["nvidia-smi"];
      extraFilesystems = [
        "/mnt/cache__Cache"
        "/mnt/disk1__Bulk"
      ];
      diskUsageCache = "1h";
    };
    hub = {
      enable = true;
      domain = servicesCatalog.beszel.domain;
      keyFile =
        if hasBeszelHubKey
        then config.age.secrets.beszel-hub-key.path
        else null;
      environmentFile =
        if hasBeszelHubEnv
        then config.age.secrets.beszel-hub-env.path
        else null;
      hermesEnvFile =
        if hasBeszelHermesEnv
        then config.age.secrets.beszel-hermes-env.path
        else null;
      systems = [
        {
          name = "zita";
          host = "127.0.0.1";
          port = ports.beszel.agent;
        }
        {
          name = "michael";
          host = fleetNetwork.hosts.michael.ip;
          port = ports.beszel.agent;
        }
        {
          name = "francis";
          host = "francis.${config.tailscale.tailnet}";
          port = ports.beszel.agent;
        }
        {
          name = "agnes";
          host = "agnes.${config.tailscale.tailnet}";
          port = ports.beszel.agent;
        }
        {
          name = "jerome";
          host = "jerome.${config.tailscale.tailnet}";
          port = ports.beszel.agent;
        }
      ];
    };
  };

  networking = {
    nameservers = [fleetNetwork.hosts.michael.ip];
    firewall.allowedTCPPorts =
      [
        80
        443
      ]
      ++ (map (svc: svc.tailscalePort) serviceList);
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  systemd.services.avahi-daemon.serviceConfig.ExecStartPre = [
    "+${pkgs.coreutils}/bin/rm -f /run/avahi-daemon/pid"
  ];

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.4"];
      hash = "sha256-QSiwKqKvSxhksWBF4/MlBOpyXba5xOQ2sRwA0R7399E=";
    };
    environmentFile = config.age.secrets.cloudflare-api-env.path;
    extraConfig = ''
      # Skip local port-53 DNS-01 self-checks: michael enforces Pi-hole/Unbound (cache-min-ttl=300s),
      # which caches NXDOMAIN past Caddy's default propagation timeout. Wait 15s for Cloudflare and
      # let Let's Encrypt's authoritative validators verify the TXT record directly.
      (cf_tls) {
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          propagation_delay 15s
          propagation_timeout -1
        }
      }

      ${lib.concatMapStringsSep "\n" (svc: ''
          ${svc.domain} {
            import cf_tls
            ${svc.extraCaddyConfig or ""}reverse_proxy 127.0.0.1:${toString svc.internalPort}
          }
        '')
        serviceList}

      ${hostname}.${config.tailscale.tailnet} {
        redir https://${hostname}.${config.tailscale.tailnet}:${toString defaultRedirectSvc.tailscalePort}
      }

      ${lib.concatMapStringsSep "\n" (svc: ''
          ${hostname}.${config.tailscale.tailnet}:${toString svc.tailscalePort} {
            ${svc.extraCaddyConfig or ""}reverse_proxy 127.0.0.1:${toString svc.internalPort}
          }
        '')
        serviceList}
    '';
  };

  systemd.services.caddy = {
    after = ["tailscaled-set.service"];
    wants = ["tailscaled-set.service"];
  };

  boot = {
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
            Address = "${fleetNetwork.hosts.zita.ip}/24";
            Gateway = fleetNetwork.hosts.michael.ip;
            DNS = [fleetNetwork.hosts.michael.ip];
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

  auto-update = {
    enable = true;
    dates = "*-*-* 05:00:00";
    randomizedDelaySec = "5m";
    gitMirror.enable = true;
    cacheWarmer = {
      enable = true;
      hosts = ["michael" "francis" "agnes" "jerome"];
    };
    canary.services =
      [
        "harmonia.socket"
        "caddy"
        "samba-smbd"
        "container@copyparty"
        "hermes-agent"
        "smartd"
        "forgejo"
        "vaultwarden"
        "beszel-hub"
      ]
      ++ lib.optional hasNtfyServerEnv "ntfy-sh";
    # Zita uses initrd SSH unlock from Michael (no TPM 2.0); let Michael unlock Zita on scheduled reboots
    reboot = {
      enable = true;
      window = "03:00";
    };
  };
}
