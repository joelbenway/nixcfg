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
          github-cli
          github-mcp-server
          mcp-nixos
          nodejs
          pciutils
          tcpdump
          usbutils
          wireshark-cli
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
      pkgs,
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

      opencode.users.${username} = {
        enable = true;
      };

      mcp.users.${username} = {
        enable = true;
        servers = {
          nixos = {
            type = "stdio";
            command = "mcp-nixos";
            env = {
              FASTMCP_SHOW_SERVER_BANNER = "false";
              PYTHONPATH = "${pkgs.writeTextDir "sitecustomize.py" ''
                import signal, sys
                signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))
              ''}";
            };
          }; # nixos
          github = {
            type = "stdio";
            command = "github-mcp-server";
            args = [
              "stdio"
              "--toolsets=all"
            ];
          }; # github
          context7 = {
            type = "stdio";
            command = "${pkgs.writeShellScript "context7-mcp" ''
              export CONTEXT7_API_KEY="''${CONTEXT7_API_KEY:-$CONTEXTSEVEN_API_KEY}"
              exec ${pkgs.nodejs}/bin/npx -y @upstash/context7-mcp "$@"
            ''}";
          }; # context7
          tavily = {
            type = "stdio";
            command = "npx";
            args = [
              "-y"
              "tavily-mcp"
            ];
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
        ide.enable = config.${username}.desktop;
        agy.enable = true;
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
