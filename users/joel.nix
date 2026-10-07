# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
in
  import (lib.custom.relativeToRoot "users/common") {
    inherit lib;
    username = "joel";
    description = "Joel Benway";
    uid = 1000;
    authorizedKeys = [keys.joel];
    git = {
      name = "Joel Benway";
      email = "157863269+joelbenway@users.noreply.github.com";
    };

    extraGroups = ["hermes"];

    packages = {
      config,
      pkgs,
      ...
    }:
      with pkgs;
        [
          ddgr
          fastfetch
          git-filter-repo
          mcp-nixos
          pciutils
          usbutils
        ]
        ++ (
          if config.joel.desktop
          then [
            # bitwarden-desktop
            gimp
            media-downloader
            signal-desktop
            tor-browser
            transmission_4-qt
            vlc
          ]
          else []
        );

    extraConfig = {
      username,
      config,
      ...
    }: {
      age = {
        secrets = {
          "${username}s-wallpaper" = {
            file = lib.custom.relativeToRoot "secrets/${username}s-wallpaper.jpg.age";
            name = "${username}s-wallpaper.jpg";
            mode = "770";
            owner = username;
            group = "users";
          };
          "${username}-api-env" = {
            file = lib.custom.relativeToRoot "secrets/${username}-api.env.age";
            name = "${username}-api.env";
            mode = "400";
            owner = username;
            group = "users";
          };
          "${username}-gpg-keys-asc" = {
            file = lib.custom.relativeToRoot "secrets/${username}-gpg-keys.asc.age";
            name = "${username}-gpg-keys.asc";
            mode = "600";
            owner = username;
            group = "users";
          };
        };
      };

      plasma.users.${username}.wallpaper = config.age.secrets."${username}s-wallpaper".path;

      podman.enable = true;

      loadkeys.users.${username} = {
        enable = true;
        envFile = config.age.secrets."${username}-api-env".path;
      };

      gemini.users.${username} = {
        enable = false;
      };

      opencode.users.${username} = {
        enable = true;
      };

      mcp.users.${username} = {
        enable = true;
        servers = {
          nixos = {
            type = "stdio";
            command = "mcp-nixos";
          }; # nixos
          context7 = {
            url = "https://mcp.context7.com/mcp";
            headers = {
              CONTEXT7_API_KEY = "{env:CONTEXTSEVEN_API_KEY}";
            }; # headers
          }; # context7
          tavily = {
            url = "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}";
          };
        }; # servers
      }; # mcp

      gpg.users.${username} = {
        gpgFile = config.age.secrets."${username}-gpg-keys-asc".path;
      }; # gpg

      vscodium = {
        enable = config.${username}.desktop;
        users.${username} = {
          cpp = true;
          flutter = true;
          nix = true;
          python = true;
          shell = true;
          ai = true;
        };
      };

      antigravity = {
        enable = config.${username}.desktop;
        users.${username} = {
          cpp = true;
          flutter = true;
          nix = true;
          python = true;
          shell = true;
          ai = true;
        };
      };

      devenvshell.enable = true;

      programs.appimage = {
        enable = config.${username}.desktop;
        binfmt = config.${username}.desktop;
      }; # programs.appimage

      services = {
        udev.packages = [
        ]; # udev.packages
      }; # services
    }; # extraConfig
  }
