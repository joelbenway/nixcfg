# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: let
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
                  "llama.cpp" = lib.mkIf config.llm.enable {
                    npm = "@ai-sdk/openai-compatible";
                    name = "llama-server (local)";
                    options = {
                      apiKey = "none";
                      baseURL = "http://localhost:${config.llm.llamaPort}/v1";
                    }; # options
                    models = lib.listToAttrs (map (m: {
                        name = m.id;
                        value = {name = "${m.id} (local)";};
                      })
                      config.llm.models);
                  }; # "llama.cpp"
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
                }; # provider
              }; # settings;
              tui = {
                theme = "system";
              }; # tui
            }; # opencode
          }; # programs
        }
      )
      config.opencode.users;
  }; # config
}
