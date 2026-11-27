# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  modelsCatalog = import (lib.custom.relativeToRoot "data/models.nix");
  opencodeModels = lib.filterAttrs (_: m: m.opencode or false) modelsCatalog.models;

  # numtide/llm-agents.nix ships OpenCode v2 as `opencode2` (bin/opencode2) to coexist with v1.
  # Wrap it with a local symlinkJoin so `opencode` is on PATH and Home Manager sees the 2.x version
  # while still fetching the underlying opencode2 binary straight from cache.numtide.com.
  opencode2 = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode2;
  opencodePkg = pkgs.symlinkJoin {
    name = "opencode-${opencode2.version}";
    paths = [opencode2];
    preferLocalBuild = true;
    postBuild = ''
      ln -s "$out/bin/opencode2" "$out/bin/opencode"
    '';
    meta = opencode2.meta // {mainProgram = "opencode";};
  };

  userConfigType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Enable opencode for this user";
    }; # options
  }; # userConfigType
in {
  options.opencode = {
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "Per user configuration";
    }; # users
  }; # options.opencode

  config = {
    home-manager.users =
      lib.mapAttrs (
        _: cfg: {
          programs = {
            opencode = {
              inherit (cfg) enable;
              package = opencodePkg;
              enableMcpIntegration = true;
              settings = {
                lsp = true;
                plugin = [
                  # https://github.com/obra/superpowers
                  "superpowers@git+https://github.com/obra/superpowers.git"
                  # https://github.com/DietrichGebert/ponytail
                  "@dietrichgebert/ponytail"
                ]; # plugin
                provider = {
                  anthropic = {
                    options = {
                      apiKey = "{env:ANTHROPIC_API_KEY}";
                    }; # options
                  }; # anthropic
                  cerebras = {
                    options = {
                      apiKey = "{env:CEREBRAS_API_KEY}";
                    }; # options
                  }; # cerebras
                  deepseek = {
                    options = {
                      apiKey = "{env:DEEPSEEK_API_KEY}";
                    }; # options
                  }; # deepseek
                  google = {
                    options = {
                      apiKey = "{env:GEMINI_API_KEY}";
                    }; # options
                  }; # google
                  groq = {
                    options = {
                      apiKey = "{env:GROQ_API_KEY}";
                    }; # options
                  }; # groq
                  huggingface = {
                    options = {
                      apiKey = "{env:HUGGING_FACE_API_KEY}";
                    }; # options
                  }; # huggingface
                  kilo = {
                    options = {
                      apiKey = "{env:KILO_GATEWAY_API_KEY}";
                    }; # options
                  }; # kilo
                  meta = {
                    options = {
                      apiKey = "{env:META_API_KEY}";
                    }; # options
                  }; # meta
                  mistral = {
                    options = {
                      apiKey = "{env:MISTRAL_API_KEY}";
                    }; # options
                  }; # mistral
                  nvidia = {
                    options = {
                      apiKey = "{env:NVIDIA_API_KEY}";
                    }; # options
                  }; # nvidia
                  ollama-cloud = {
                    options = {
                      apiKey = "{env:OLLAMA_CLOUD_API_KEY}";
                    }; # options
                  }; # ollama-cloud
                  openai = {
                    options = {
                      apiKey = "{env:OPENAI_API_KEY}";
                    }; # options
                  }; # openai
                  openrouter = {
                    options = {
                      apiKey = "{env:OPENROUTER_API_KEY}";
                    }; # options
                  }; # openrouter
                  xai = {
                    options = {
                      apiKey = "{env:XAI_API_KEY}";
                    }; # options
                  }; # xai
                  zita = {
                    npm = "@ai-sdk/openai-compatible";
                    name = "Zita (Local)";
                    options = {
                      baseURL = "https://${modelsCatalog.serverHost}.${config.tailscale.tailnet}:${toString ports.llm.tailscale}/v1";
                      apiKey = "none";
                    }; # options
                    models =
                      lib.mapAttrs (_: m: {
                        inherit (m) name;
                        limit = {
                          inherit (m) context;
                          output = m.maxOutput;
                        };
                      })
                      opencodeModels;
                  }; # zita
                }; # provider
              }; # settings;
              cli = {
                theme = "system";
              }; # cli
            }; # opencode
          }; # programs
        }
      )
      config.opencode.users;
  }; # config
}
