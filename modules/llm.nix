# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.llm = {
    enable = lib.mkEnableOption "Enables local LLM tools";
    hw = lib.mkOption {
      description = "Hardware info for llama-cpp optimization.";
      default = {};
      type = lib.types.submodule {
        options = {
          arch = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = let
              gccarch = lib.findFirst (f: lib.hasPrefix "gccarch-" f) null config.nix.settings.system-features;
            in
              if gccarch != null
              then lib.removePrefix "gccarch-" gccarch
              else null;
            example = "skylake";
            description = "CPU microarchitecture for -march=. Auto-detected from nix.settings.system-features gccarch-*. Set explicitly to override.";
          };
          extraFlags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["--threads" "2"];
            example = ["--threads" "1" "--split-mode" "layer" "--gpu-layers" "-1"];
            description = "Extra flags for llama-cpp server.";
          }; # extraFlags
        }; # options
      }; # type
    }; # hw
    models = lib.mkOption {
      description = "List of LLM model configurations";
      default = [];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          id = lib.mkOption {
            type = lib.types.str;
            example = "mistral-7b";
            description = "Model identifier for llama-swap";
          };
          package = lib.mkOption {
            type = lib.types.path;
            example = "/path/to/model.gguf";
            description = "Path to the model file";
          };
          args = lib.mkOption {
            type = with lib.types; listOf str;
            default = [];
            example = ["--ctx-size" "4096" "--temp" "0.7"];
            description = "Command-line arguments for llama-server";
          };
        };
      });
    };

    llamaPort = lib.mkOption {
      type = lib.types.str;
      default = "8080";
      example = "9292";
      description = "Port for llama-swap server to run";
    }; # llamaPort
  }; # options.llm

  config = lib.mkIf config.llm.enable (let
    llama-cpp-optimized = let
      base = pkgs.llama-cpp.override {
        blasSupport = false;
        cudaSupport = false;
        metalSupport = false;
        rocmSupport = false;
        vulkanSupport = false;
      };
      archFlags =
        if config.llm.hw.arch != null
        then [
          "-march=${config.llm.hw.arch}"
          "-mtune=${config.llm.hw.arch}"
        ]
        else [];
    in
      base.overrideAttrs (oldAttrs: {
        NIX_CFLAGS_COMPILE = (oldAttrs.NIX_CFLAGS_COMPILE or []) ++ archFlags;
        NIX_CXXFLAGS_COMPILE = (oldAttrs.NIX_CXXFLAGS_COMPILE or []) ++ archFlags;
      });
  in {
    environment.systemPackages = with pkgs; [
      llama-cpp-optimized
      llama-swap
      (llm.withPlugins {
        llm-cmd = true;
        llm-docs = true;
        llm-git = true;
      }) # llm
    ];

    environment.etc."llama-swap/config.yaml.template".text = ''
      healthCheckTimeout: 600
      ttl: 3600

      models:
        "gemma-4-e2b-it":
          cmd: >
            ${llama-cpp-optimized}/bin/llama-server
            -hf unsloth/gemma-4-e2b-it-gguf:Q4_K_M
            --port ''${PORT}
            --ctx-size 32768
            --temp 1.0
            --top-k 64
            --top-p 0.95
            ${lib.concatStringsSep " " config.llm.hw.extraFlags}

        "gemma-4-e4b-it":
          cmd: >
            ${llama-cpp-optimized}/bin/llama-server
            -hf unsloth/gemma-4-e4b-it-gguf:Q4_K_M
            --port ''${PORT}
            --ctx-size 131072
            --temp 1.0
            --top-k 64
            --top-p 0.95
            ${lib.concatStringsSep " " config.llm.hw.extraFlags}

        "gemma-4-26b-a4b-it":
          cmd: >
            ${llama-cpp-optimized}/bin/llama-server
            -hf unsloth/gemma-4-26b-a4b-it-gguf:Q4_K_M
            --port ''${PORT}
            --ctx-size 262144
            --temp 1.0
            --top-k 64
            --top-p 0.95
            ${lib.concatStringsSep " " config.llm.hw.extraFlags}

        "lfm2.5-instruct:1.2b":
          cmd: >
            ${llama-cpp-optimized}/bin/llama-server
            -hf LiquidAI/LFM2.5-1.2B-Instruct-GGUF:Q4_K_M
            --port ''${PORT}
            --ctx-size 8192
            --temp 0.1
            --top-k 50
            --top-p 0.1
            --repeat-penalty 1.05
            --jinja
            ${lib.concatStringsSep " " config.llm.hw.extraFlags}

        ${lib.concatStringsSep "\n        " (map (m: ''
          "${m.id}":
            cmd: >
              ${llama-cpp-optimized}/bin/llama-server
              --model "${m.package}"
              --port ''${PORT}
              ${lib.concatStringsSep " " config.llm.hw.extraFlags}
              ${lib.concatStringsSep " " m.args}
        '')
        config.llm.models)}

      peers:
        openrouter:
          proxy: https://openrouter.ai/api
          apiKey: "$OPENROUTER_API_KEY"
          models:
            - "openrouter/free"
    '';

    home-manager.sharedModules = [
      ({
        config,
        osConfig,
        ...
      }: {
        systemd.user.services.llama-swap = {
          Unit = {
            Description = "llama-swap - Reliable model swapping for any local AI server";
            After = ["network.target" "loadkeys-import-${config.home.username}.service"];
          };
          Install = {
            WantedBy = ["default.target"];
          };
          Service = {
            Type = "simple";
            RuntimeDirectory = "llama-swap";
            Environment = [
              # "LLAMA_CACHE=/var/cache/huggingface/llamacpp"
              "HF_HOME=/var/cache/huggingface"
            ];
            ExecStartPre = pkgs.writeShellScript "llama-swap-prep" ''
              export OPENROUTER_API_KEY="''${OPENROUTER_API_KEY:-none}"
              ${pkgs.gettext}/bin/envsubst '$OPENROUTER_API_KEY' < /etc/llama-swap/config.yaml.template > "$XDG_RUNTIME_DIR/llama-swap/config.yaml"
            '';
            ExecStart = "${pkgs.llama-swap}/bin/llama-swap --config %t/llama-swap/config.yaml --listen 0.0.0.0:${osConfig.llm.llamaPort} --watch-config";

            Restart = "always";
            RestartSec = 10;
            # Environment needs access to cache directories for model downloads
            # Simplified security settings to avoid namespace issues
            PrivateTmp = true;
            NoNewPrivileges = true;
          }; # Service
        }; # llama-swap

        xdg.configFile."io.datasette.llm/extra-openai-models.yaml".text = ''
          - model_id: "light"
            model_name: "lfm2.5-instruct:1.2b"
            api_base: "http://localhost:${osConfig.llm.llamaPort}/v1"
            api_key: "none"
            supports_tools: true

          - model_id: "fast"
            model_name: "gemma-4-e2b-it"
            api_base: "http://localhost:${osConfig.llm.llamaPort}/v1"
            api_key: "none"
            supports_tools: true

          - model_id: "daily"
            model_name: "gemma-4-e4b-it"
            api_base: "http://localhost:${osConfig.llm.llamaPort}/v1"
            api_key: "none"
            supports_tools: true

          - model_id: "heavy"
            model_name: "gemma-4-26b-a4b-it"
            api_base: "http://localhost:${osConfig.llm.llamaPort}/v1"
            api_key: "none"
            supports_tools: true

          - model_id: "cloud"
            model_name: "openrouter/free"
            api_base: "http://localhost:${osConfig.llm.llamaPort}/v1"
            api_key: "none"
            supports_tools: true
        '';

        xdg.configFile."io.datasette.llm/default_model.txt".text = ''
          cloud
        '';
      })
    ];
  }); # config
}
