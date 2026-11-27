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
          fastfetch
          github-cli
          pciutils
          tcpdump
          usbutils
          wireshark-cli
        ]
        ++ lib.optionals config.joel.dev [
          ddgr
          github-mcp-server
          mcp-nixos
          nodejs
        ]
        ++ lib.optionals config.joel.desktop [
          # bitwarden-desktop
          gimp
          media-downloader
          signal-desktop
          tor-browser
          transmission_4-qt
          vlc
        ];

    extraConfig = {
      username,
      config,
      pkgs,
      ...
    }: let
      kmailSecretFile = lib.custom.relativeToRoot "secrets/${username}-kmail.json.age";
      hasKmailSecret = builtins.pathExists kmailSecretFile;
      usePlasma = config.${username}.desktop && config.plasma.enable;
    in {
      age = {
        secrets = lib.mkMerge [
          {
            "${username}-gpg-keys-asc" = {
              file = lib.custom.relativeToRoot "secrets/${username}-gpg-keys.asc.age";
              name = "${username}-gpg-keys.asc";
              mode = "600";
              owner = username;
              group = "users";
            };
          }
          (lib.mkIf usePlasma {
            "${username}s-wallpaper" = {
              file = lib.custom.relativeToRoot "secrets/${username}s-wallpaper.jpg.age";
              name = "${username}s-wallpaper.jpg";
              mode = "770";
              owner = username;
              group = "users";
            };
          })
          (lib.mkIf config.${username}.dev {
            "${username}-api-env" = {
              file = lib.custom.relativeToRoot "secrets/${username}-api.env.age";
              name = "${username}-api.env";
              mode = "400";
              owner = username;
              group = "users";
            };
          })
          (lib.mkIf (hasKmailSecret && usePlasma) {
            "${username}-kmail-json" = {
              file = kmailSecretFile;
              name = "${username}-kmail.json";
              mode = "400";
              owner = username;
              group = "users";
            };
          })
        ];
      };

      plasma.users = lib.mkIf usePlasma {
        ${username}.wallpaper = config.age.secrets."${username}s-wallpaper".path;
      };

      kmail.users = lib.mkIf (hasKmailSecret && usePlasma) {
        ${username} = {
          enable = true;
          configFile = config.age.secrets."${username}-kmail-json".path;
        };
      };

      podman.enable = lib.mkIf config.${username}.dev true;

      loadkeys.users = lib.mkIf config.${username}.dev {
        ${username} = {
          enable = true;
          envFile = config.age.secrets."${username}-api-env".path;
        };
      };

      opencode.users = lib.mkIf config.${username}.dev {
        ${username} = {
          enable = true;
        };
      };

      mcp.users = lib.mkIf config.${username}.dev {
        ${username} = {
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
        };
      }; # mcp

      gpg.users.${username} = {
        gpgFile = config.age.secrets."${username}-gpg-keys-asc".path;
      }; # gpg

      vscodium = lib.mkIf (config.${username}.desktop && config.${username}.dev) {
        enable = true;
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
        hub.enable = lib.mkIf (config.${username}.desktop && config.${username}.dev) true;
        agy.enable = lib.mkIf config.${username}.dev true;
        users = lib.mkIf config.${username}.dev {
          ${username} = {
            cpp = true;
            flutter = true;
            nix = true;
            python = true;
            shell = true;
            ai = true;
          };
        };
      };

      hex = lib.mkIf config.${username}.desktop {
        enable = true;
        users.${username} = {
          enable = true;
          autostart = true;
          installModel = true;
          # Plasma keeps Alt+Space for KRunner; Hex's KDE default is Ctrl+Alt+Space.
          shortcut = "control+alt+space";
        };
      };

      devenvshell.enable = lib.mkIf config.${username}.dev true;

      programs.appimage = lib.mkIf config.${username}.desktop {
        enable = true;
        binfmt = true;
      }; # programs.appimage
    }; # extraConfig
  }
