{
  config,
  lib,
  pkgs,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      cpp = lib.mkEnableOption "Enables cpp tooling";
      flutter = lib.mkEnableOption "Enables Dart/Flutter tooling";
      nix = lib.mkEnableOption "Enables nix tooling";
      python = lib.mkEnableOption "Enables python tooling";
      shell = lib.mkEnableOption "Enables Shell tooling";
      ai = lib.mkEnableOption "Enables AI tooling";
    }; # options
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
      lib.mapAttrs (user: userConfig: {
        home = {
          packages = with pkgs;
            [
            ]
            ++ lib.optionals userConfig.cpp [
              clang-tools
            ]
            ++ lib.optionals userConfig.nix [
              alejandra
              nixd
            ]
            ++ lib.optionals userConfig.shell [
              bash-language-server
              shellcheck
              shfmt
            ]
            ++ lib.optionals userConfig.ai [
              # mcp-language-server
            ]; # packages
        }; # home

        programs = {
          vscodium = {
            enable = true;
            package = pkgs.vscodium;
            mutableExtensionsDir = false;
            profiles = {
              default = {
                enableMcpIntegration = userConfig.ai;
                extensions = with pkgs.vscode-extensions;
                  [
                    # ms-vscode-remote.remote-ssh
                    # ms-vscode-remote.remote-ssh-edit
                    mkhl.direnv
                  ]
                  ++ lib.optionals userConfig.cpp [
                    llvm-vs-code-extensions.vscode-clangd
                    ms-vscode.cmake-tools
                    ms-vscode.cpptools
                  ]
                  ++ lib.optionals userConfig.flutter [
                    dart-code.dart-code
                    dart-code.flutter
                  ]
                  ++ lib.optionals userConfig.nix [
                    jnoortheen.nix-ide
                  ]
                  ++ lib.optionals userConfig.python [
                    ms-python.python
                  ]
                  ++ lib.optionals userConfig.shell [
                    mads-hartmann.bash-ide-vscode
                    # mkhl.shfmt
                  ]
                  ++ lib.optionals userConfig.ai [
                    # continue.continue
                    # Google.gemini-cli-vscode-ide-companion
                  ]
                  ++ lib.optionals userConfig.ai (pkgs.vscode-utils.extensionsFromVscodeMarketplace [
                    {
                      publisher = "sst-dev";
                      name = "opencode";
                      version = "0.0.13";
                      sha256 = "1m301j2qbym3j2qnck76jyxakca3h1qiybc2r7wy7z11m98mg9z9";
                    }
                  ]); # extensions
                userSettings = {
                  diffEditor = {
                    ignoreTrimWhitespace = false;
                  };
                  editor = {
                    tabSize = 2;
                    tabCompletion = "on";
                  };
                  C_Cpp = lib.mkIf userConfig.cpp {
                    intelliSenseEngine = "disabled";
                  }; # C_Cpp
                  nix = lib.mkIf userConfig.nix {
                    enableLanguageServer = true;
                    serverPath = "nixd";
                    serverSettings = {
                      nixd = {
                        formatting = {
                          command = ["alejandra"];
                        }; # formatting
                        options = {
                          nixos = lib.mkIf (config.networking.hostName != null) {
                            "expr" = let
                              workspaceFolder = "\${workspaceFolder}";
                            in "(builtins.getFlake \"${workspaceFolder}\").nixosConfigurations.${config.networking.hostName}.options";
                          }; # nixos
                        }; # options
                      }; # "nixd"
                    }; # serverSettings
                    formatterPath = "alejandra";
                  }; # nix
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
