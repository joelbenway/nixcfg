{
  config,
  lib,
  pkgs,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      theme = lib.mkOption {
        type = lib.types.str;
        default = "org.kde.breezedark.desktop";
        description = "The Plasma look and feel theme";
      }; # theme
      wallpaper = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = "The Plasma wallpaper";
      }; # wallpaper
      discover = lib.mkEnableOption "Enable discover";
    };
  };
in {
  options.plasma = {
    enable = lib.mkEnableOption "Enables plasma desktop";
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "Users for whom to enable Plasma";
    }; # users
  }; # options.plasma

  config = lib.mkIf config.plasma.enable {
    services = {
      xserver.enable = true;
      desktopManager.plasma6.enable = true;
      displayManager = {
        plasma-login-manager = {
          enable = true;
        }; # plasma-login-manager
        defaultSession = "plasma";
      }; # displayManager
      flatpak.enable = lib.any (user: user.discover) (lib.attrValues config.plasma.users);
      fwupd.enable = lib.any (user: user.discover) (lib.attrValues config.plasma.users);
    }; # services

    environment.systemPackages = with pkgs;
      [
        kdePackages.kcalc
        kdePackages.kleopatra
        kdePackages.kmail
        kdePackages.kmail-account-wizard
        kdePackages.kontact
        kdePackages.ktexteditor
        kdePackages.merkuro
      ]
      ++ lib.optionals config.hardware.sane.enable [
        kdePackages.skanpage
      ];

    programs = {
      firefox = {
        policies = {
          Preferences = {
            "widget.use-xdg-desktop-portal.file-picker" = {
              Value = "1";
              Status = "user";
            };
          }; # Preferences
          ExtensionSettings = {
            "plasma-browser-integration@kde.org" = {
              install_url = "https://addons.mozilla.org/firefox/downloads/latest/plasma-integration/latest.xpi";
              installation_mode = "force_installed";
            }; # "plasma-browser-integration@kde.org"
          }; # ExtensionSettings
        }; # policies
      }; # firefox

      kdeconnect.enable = true;
    }; # programs

    home-manager = {
      sharedModules = [
        {
          programs.brave = {
            extensions = [
              {
                id = "cimiefiiaegbelhefglklhhakcgmhkai"; # plasma integration
              }
            ];
          };
        }
      ]; # sharedModules

      users =
        lib.mapAttrs (user: userConfig: {
          # necessary to enable plasma-browser-integration on home-manager installed firefox
          home.file.".mozilla/native-messaging-hosts/org.kde.plasma.browser_integration.json".source = "${pkgs.kdePackages.plasma-browser-integration}/lib/mozilla/native-messaging-hosts/org.kde.plasma.browser_integration.json";

          programs.plasma = {
            enable = true;
            workspace = {
              lookAndFeel = userConfig.theme;
              wallpaper = userConfig.wallpaper;
            }; # programs.plasma

            kscreenlocker = {
              appearance.wallpaper = userConfig.wallpaper;
            }; # kscreenlocker
          }; # programs.plasma

          programs.kate = {
            enable = true;
            lsp.customServers = {
              nix = {
                command = ["nixd"];
                url = "https://github.com/nix-community/nixd";
                highlightingModeRegex = "^Nix$";
              }; # nix
            }; # lsp.customServers
            editor = {
              indent = {
                replaceWithSpaces = true;
                width = 2;
              }; # indent
              tabWidth = 2;
            }; # editor
          }; # programs.kate
        }) # users
        
        config.plasma.users;
    }; # home-manager
  }; # config
}
