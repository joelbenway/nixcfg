{
  config,
  hostname,
  inputs,
  lib,
  modulesPath,
  ...
}: let
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    inputs.nixos-hardware.nixosModules.common-cpu-intel-cpu-only
    (lib.custom.relativeToRoot "hardware/quadrom2000.nix")
    (lib.custom.relativeToRoot "hardware/ivybridge.nix")
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
        owner = "hermes";
        group = "hermes";
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
      "/var/lib/actual"
    ];
  }; # impermanence

  services = {
    btrfs = {
      autoScrub = {
        enable = true;
        interval = "monthly";
        fileSystems = ["/" "/storage"];
      }; # autoScrub
    }; # btrfs
  }; # services

  openssh = {
    enable = true;
    hostKeyPath = hostKeyPath;
  };

  distributed-builds = {
    enable = true;
    keyFile = config.age.secrets.nix-builder-ssh.path;
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
    envFile = config.age.secrets.wifi-environment-variables.path;
  }; # networkstack

  tailscale = {
    enable = true;
    envFile = config.age.secrets.tailscale-oauth-env.path;
  }; # tailscale

  hermes = {
    enable = true;
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
  }; # copyparty

  actual = {
    enable = true;
  }; # actual

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
      ];
      kernelModules = [];
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

  # Merge disko configurations
  disko.devices = lib.mkMerge [
    (import ./disks.nix {}).disko.devices
    (import ./storage.nix {
      passwordFile = config.age.secrets.storage-luks-passphrase.path;
    }).disko.devices
  ]; # disko.devices

  fileSystems."/var/log".neededForBoot = true;
}
