# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{pkgs}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "fleet-notify";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [
    pkgs.makeWrapper
  ];

  nativeCheckInputs = [
    pkgs.python3
    pkgs.python3Packages.pytest
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    pytest test_fleet_notify.py -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/fleet-notify" "$out/bin"
    install -m 0755 fleet_notify.py "$out/libexec/fleet-notify/fleet_notify.py"
    install -m 0755 fleet_notify_desktop.py "$out/libexec/fleet-notify/fleet_notify_desktop.py"

    makeWrapper "${pkgs.python3}/bin/python3" "$out/bin/fleet-notify" \
      --add-flags "$out/libexec/fleet-notify/fleet_notify.py" \
      --prefix PYTHONPATH : "$out/libexec/fleet-notify" \
      --prefix PATH : "${pkgs.lib.makeBinPath [pkgs.systemd]}"

    makeWrapper "${pkgs.python3}/bin/python3" "$out/bin/fleet-notify-desktop" \
      --add-flags "$out/libexec/fleet-notify/fleet_notify_desktop.py" \
      --prefix PYTHONPATH : "$out/libexec/fleet-notify" \
      --prefix PATH : "${pkgs.lib.makeBinPath [pkgs.libnotify]}"
    runHook postInstall
  '';
}
