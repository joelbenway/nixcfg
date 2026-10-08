# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  #sudo nixos-rebuild switch --flake /path/to/flake#hostname
  description = "Nixos config flake";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # stable.url = "github:nixos/nixpkgs/nixos-24.05";

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    copyparty = {
      url = "github:9001/copyparty";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    supportedSystems = ["x86_64-linux" "aarch64-linux"];
    forEachSupportedSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f {pkgs = import nixpkgs {inherit system;};});
    lib = nixpkgs.lib.extend (_: super: {
      custom = import ./lib {lib = super;};
    });

    mkHost = {
      name,
      platform ? "x86_64-linux",
      extraModules ? [],
      hmModules ? [],
      overlays ? [],
    }:
      nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs self lib;
          hostname = name;
          inherit platform;
        };
        modules =
          [
            ./hosts/configuration.nix
            ./hosts/${name}
            ./modules
            ./users
            inputs.disko.nixosModules.disko
            inputs.home-manager.nixosModules.default
            {nixpkgs.overlays = overlays;}
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = hmModules;
            }
          ]
          ++ extraModules;
      };
  in {
    devShells = forEachSupportedSystem ({pkgs}: {
      default = import ./shell.nix {inherit pkgs;};
    });

    nixosConfigurations = {
      agnes = mkHost {
        name = "agnes";
        hmModules = [inputs.plasma-manager.homeModules.plasma-manager];
      }; # agnes

      francis = mkHost {
        name = "francis";
        hmModules = [inputs.plasma-manager.homeModules.plasma-manager];
      }; # francis

      jerome = mkHost {
        name = "jerome";
        hmModules = [inputs.plasma-manager.homeModules.plasma-manager];
      }; # jerome

      michael = mkHost {
        name = "michael";
        hmModules = [inputs.agenix.homeManagerModules.default];
      }; # michael

      therese = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs self lib;
          hostname = "therese";
          platform = "x86_64-linux";
        };
        modules = [./hosts/therese];
      }; # therese

      zita = mkHost {
        name = "zita";
        hmModules = [inputs.agenix.homeManagerModules.default];
        overlays = [inputs.copyparty.overlays.default];
      }; # zita
    }; # nixosConfigurations
  };
}
