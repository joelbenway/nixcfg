# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
#
# Single source of truth for local LLM models served by Zita's llama-server
# (Router Mode) and consumed by Hermes, OpenCode, and fleet clients.
#
# Model weights are never placed in /nix/store. llama-server downloads GGUF
# blobs lazily into LLAMA_CACHE on first request, preserves active models
# across reboots, and llm-cache-gc prunes removed, stale, or over-budget blobs.
{
  serverHost = "zita";

  # Shared llama-server preset defaults applied to every model ([*] section)
  defaults = {
    flash-attn = "on";
    cache-type-k = "q8_0";
    cache-type-v = "q8_0";
    jinja = true;
  };

  models = {
    "gemma-4-e4b-it" = {
      name = "Gemma 4 E4B (Zita)";
      hfRepo = "unsloth/gemma-4-e4b-it-gguf:Q4_K_M";
      context = 32768;
      maxOutput = 8192;
      # Keep pinned on disk so Hermes's offline fallback is ready if WAN drops
      pin = true;
      hermesFallback = true;
      opencode = true;
      llama = {
        n-gpu-layers = 99;
        temp = 1.0;
        top-k = 64;
        top-p = 0.95;
      };
    };

    "inkling-2-mini" = {
      name = "Inkling 2 Mini MoE (Zita)";
      hfRepo = "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M";
      context = 32768;
      maxOutput = 8192;
      pin = false;
      opencode = true;
      llama = {
        n-gpu-layers = 99;
        cpu-moe = true;
        temp = 0.7;
      };
    };

    "gemma-4-26b-a4b-it" = {
      name = "Gemma 4 26B-A4B MoE (Zita)";
      hfRepo = "unsloth/gemma-4-26b-a4b-it-gguf:Q4_K_M";
      context = 65536;
      maxOutput = 16384;
      pin = false;
      opencode = true;
      llama = {
        n-gpu-layers = 99;
        cpu-moe = true;
        temp = 1.0;
        top-k = 64;
        top-p = 0.95;
      };
    };
  };
}
