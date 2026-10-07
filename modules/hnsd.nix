# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hnsd;

  hnsdPkg = pkgs.stdenv.mkDerivation {
    pname = "hnsd";
    version = "2.0.0";
    src = pkgs.fetchFromGitHub {
      owner = "handshake-org";
      repo = "hnsd";
      rev = "v2.0.0";
      sha256 = "1pqpf9vz1d01873wvkdnmsj9y2qrk8fka4c636qipsjv6ar2ply0";
    };
    nativeBuildInputs = with pkgs; [autoconf automake libtool pkg-config which patchelf];
    buildInputs = with pkgs; [unbound];
    postPatch = "patchShebangs .";
    preConfigure = "./autogen.sh";
    postInstall = ''
      patchelf --shrink-rpath --allowed-rpath-prefixes "$NIX_STORE" "$out/bin/hnsd"
      patchelf --shrink-rpath --allowed-rpath-prefixes "$NIX_STORE" "$out/lib/libhsk.so"
    '';
    meta = with lib; {
      description = "Handshake SPV Name Resolver Daemon";
      homepage = "https://github.com/handshake-org/hnsd";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };
in {
  options.services.hnsd = {
    enable = lib.mkEnableOption "Handshake SPV Resolver Daemon (hnsd)";
    package = lib.mkOption {
      type = lib.types.package;
      default = hnsdPkg;
      description = "The hnsd package to use.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 5350;
      description = "Port for the hnsd recursive resolver";
    };
    rootPort = lib.mkOption {
      type = lib.types.port;
      default = 5354;
      description = "Port for the hnsd authoritative root nameserver";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hnsd = {
      description = "Handshake SPV Name Resolver";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/hnsd -r 127.0.0.1:${toString cfg.port} -n 127.0.0.1:${toString cfg.rootPort}";
        Restart = "on-failure";
        RestartSec = "5s";
        DynamicUser = true;
        AmbientCapabilities = "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
      };
    };
  };
}
