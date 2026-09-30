# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
{
  pkgs,
  inputs,
  platform,
  ...
}: {
  imports = [
    inputs.agenix.nixosModules.default
    {
      environment.systemPackages = [inputs.agenix.packages.${platform}.default];
    }
  ];

  nixpkgs.hostPlatform = platform;

  system.stateVersion = "23.11";
  nixpkgs.config.allowUnfree = true;
  users.mutableUsers = false;

  nix = {
    settings = {
      auto-optimise-store = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      http-connections = 128;
      max-substitution-jobs = 128;
      extra-substituters = [
        "https://microvm.cachix.org"
        "https://cache.numtide.com"
        "https://nix-community.cachix.org"
        "https://numtide.cachix.org"
        "https://cuda-maintainers.cachix.org"
        "https://wezterm.cachix.org"
      ];
      extra-trusted-public-keys = [
        "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqyn="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
        "wezterm.cachix.org-1:kAbhjYUC9qvblTE+s7S+kl5XM1zVa4skO+E/1IDWdH0="
      ];
    }; # settings

    nixPath = ["nixpkgs=${inputs.nixpkgs}"];

    gc = {
      automatic = true;
      randomizedDelaySec = "14m";
      options = "--delete-older-than 60d";
      persistent = true;
    }; # gc
  }; # nix

  boot.loader.systemd-boot.configurationLimit = 20;

  # Set your time zone.
  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";

  security.polkit.enable = true;

  environment.systemPackages = with pkgs; [
    age
    btop
    curl
    htop
    nh
    p7zip
    ripgrep
    sbctl
    tmux
    # tpm2-tss
    tree
    vim
    wget
  ];

  services = {
    libinput.enable = true;
    pcscd.enable = true;
  }; # services
}
