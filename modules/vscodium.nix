# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  vscodeLib = import (lib.custom.relativeToRoot "lib/vscode.nix") {inherit lib;};

  userConfigType = lib.types.submodule {
    options = vscodeLib.mkLanguageOptions;
  }; # userConfigType
in {
  options.vscodium = {
    enable = lib.mkEnableOption "Enables vscodium";
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "User configuration";
    }; # users
  }; # options.vscodium

  config = lib.mkIf config.vscodium.enable {
    home-manager.users =
      lib.mapAttrs (_: userConfig: {
        home.packages = vscodeLib.mkHomePackages {inherit pkgs userConfig;};

        programs = {
          vscodium = {
            enable = true;
            package = pkgs.vscodium;
            mutableExtensionsDir = false;
            profiles = {
              default = {
                enableMcpIntegration = userConfig.ai;
                extensions =
                  (vscodeLib.mkCommonExtensions {inherit pkgs userConfig;})
                  ++ lib.optionals userConfig.cpp [
                    pkgs.vscode-extensions.ms-vscode.cpptools
                  ]
                  ++ [
                    (pkgs.vscode-utils.buildVscodeMarketplaceExtension {
                      mktplcRef = {
                        publisher = "jeanp413";
                        name = "open-remote-ssh";
                        version = "0.6.2";
                      };
                      vsix = pkgs.fetchurl {
                        url = "https://open-vsx.org/api/jeanp413/open-remote-ssh/0.6.2/file/jeanp413.open-remote-ssh-0.6.2.vsix";
                        hash = "sha256-DvlV63bVU2Y74W4noYFPpOyl+XYMvHyVh05IXH8zYkg=";
                      };
                    })
                  ]
                  ++ lib.optionals userConfig.ai (pkgs.vscode-utils.extensionsFromVscodeMarketplace [
                    {
                      publisher = "sst-dev";
                      name = "opencode";
                      version = "0.0.13";
                      sha256 = "1m301j2qbym3j2qnck76jyxakca3h1qiybc2r7wy7z11m98mg9z9";
                    }
                  ]); # extensions
                userSettings =
                  (vscodeLib.mkCommonUserSettings {inherit config userConfig;})
                  // {
                    C_Cpp = lib.mkIf userConfig.cpp {
                      intelliSenseEngine = "disabled";
                    }; # C_Cpp
                    continue = lib.mkIf userConfig.ai {
                      telemetryEnabled = false;
                    }; # continue
                  }; # userSettings
                userTasks = {
                }; # userTasks
              }; # default
            }; # profiles
          }; # vscodium
        }; # programs
      })
      config.vscodium.users;
  }; # config
}
