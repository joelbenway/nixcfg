# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib}: {
  mkLanguageOptions = {
    cpp = lib.mkEnableOption "Enables cpp tooling";
    flutter = lib.mkEnableOption "Enables Dart/Flutter tooling";
    nix = lib.mkEnableOption "Enables nix tooling";
    python = lib.mkEnableOption "Enables python tooling";
    shell = lib.mkEnableOption "Enables Shell tooling";
    ai = lib.mkEnableOption "Enables AI tooling";
  };

  mkHomePackages = {
    pkgs,
    userConfig,
  }:
    with pkgs;
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
      ];

  mkCommonExtensions = {
    pkgs,
    userConfig,
  }:
    with pkgs.vscode-extensions;
      [
        mkhl.direnv
      ]
      ++ lib.optionals userConfig.cpp [
        llvm-vs-code-extensions.vscode-clangd
        ms-vscode.cmake-tools
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
      ];

  mkCommonUserSettings = {
    config,
    userConfig,
  }: {
    diffEditor = {
      ignoreTrimWhitespace = false;
    };
    editor = {
      tabSize = 2;
      tabCompletion = "on";
    };
    nix = lib.mkIf userConfig.nix {
      enableLanguageServer = true;
      serverPath = "nixd";
      serverSettings = {
        nixd = {
          formatting = {
            command = ["alejandra"];
          };
          options = {
            nixos = lib.mkIf (config.networking.hostName != null) {
              "expr" = let
                workspaceFolder = "\${workspaceFolder}";
              in "(builtins.getFlake \"${workspaceFolder}\").nixosConfigurations.${config.networking.hostName}.options";
            };
          };
        };
      };
      formatterPath = "alejandra";
    };
  };
}
