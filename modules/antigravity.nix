{
  config,
  lib,
  pkgs,
  inputs,
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
  options.antigravity = {
    enable = lib.mkEnableOption "Enables antigravity";
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "User configuration";
    }; # users
  }; # options.antigravity

  config = lib.mkIf config.antigravity.enable {
    home-manager.users =
      lib.mapAttrs (_: userConfig: {
        disabledModules = ["programs/antigravity.nix"];
        imports = [
          (import "${inputs.home-manager}/modules/programs/vscode/mkVscodeModule.nix" {
            modulePath = ["programs" "antigravity"];
            name = "Antigravity IDE";
            packageName = "antigravity-ide";
            nameShort = "Antigravity IDE";
            dataFolderName = ".antigravity-ide";
            skipVersionCheck = true;
          })
        ];

        home = {
          packages = with pkgs;
            lib.optionals userConfig.cpp [
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
          antigravity = {
            enable = true;
            package = pkgs.antigravity-ide;
            mutableExtensionsDir = false;
            profiles = {
              default = {
                enableMcpIntegration = userConfig.ai;
                extensions = with pkgs.vscode-extensions;
                  [
                    mkhl.direnv
                  ]
                  ++ lib.optionals userConfig.cpp [
                    llvm-vs-code-extensions.vscode-clangd
                    ms-vscode.cmake-tools
                    vadimcn.vscode-lldb
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
                  ]; # extensions
                userSettings = {
                  "files.watcherExclude" = {
                    "**/.git/objects/**" = true;
                    "**/.git/subtree-cache/**" = true;
                    "**/.direnv/**" = true;
                    "**/result" = true;
                    "**/result/**" = true;
                  };
                  diffEditor = {
                    ignoreTrimWhitespace = false;
                  };
                  editor = {
                    tabSize = 2;
                    tabCompletion = "on";
                  };
                  clangd = lib.mkIf userConfig.cpp {
                    checkUpdates = false;
                  }; # clangd
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
                }; # userSettings
                userTasks = {
                }; # userTasks
              }; # default
            }; # profiles
          }; # antigravity
        }; # programs
      })
      config.antigravity.users;
  }; # config
}
