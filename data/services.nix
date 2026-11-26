# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
let
  ports = import ./ports.nix;
  network = import ./network.nix;
in {
  copyparty = {
    domain = "files.${network.domain}";
    internalPort = ports.copyparty.internal;
    tailscalePort = ports.copyparty.tailscale;
    defaultTailscaleRedirect = true;
  };
  actual = {
    domain = "budget.${network.domain}";
    internalPort = ports.actual.internal;
    tailscalePort = ports.actual.tailscale;
    extraCaddyConfig = ''
      header Cross-Origin-Resource-Policy cross-origin
    '';
  };
  jellyfin = {
    domain = "jellyfin.${network.domain}";
    internalPort = ports.jellyfin.internal;
    tailscalePort = ports.jellyfin.tailscale;
  };
  forgejo = {
    domain = "git.${network.domain}";
    internalPort = ports.forgejo.internal;
    tailscalePort = ports.forgejo.tailscale;
  };
  vaultwarden = {
    domain = "vault.${network.domain}";
    internalPort = ports.vaultwarden.internal;
    tailscalePort = ports.vaultwarden.tailscale;
  };
  beszel = {
    domain = "metrics.${network.domain}";
    internalPort = ports.beszel.internal;
    tailscalePort = ports.beszel.tailscale;
  };
  ntfy = {
    domain = "notify.${network.domain}";
    internalPort = ports.ntfy.internal;
    tailscalePort = ports.ntfy.tailscale;
  };
  llm = {
    domain = "ai.${network.domain}";
    internalPort = ports.llm.internal;
    tailscalePort = ports.llm.tailscale;
  };
}
