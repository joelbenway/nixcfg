# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{pkgs}:
pkgs.stdenv.mkDerivation {
  pname = "kmail-provision";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.pkg-config
    pkgs.qt6.wrapQtAppsHook
  ];

  buildInputs = [
    pkgs.qt6.qtbase
    pkgs.qt6Packages.qtkeychain
  ];

  nativeCheckInputs = [
    pkgs.python3
    pkgs.python3Packages.pytest
  ];

  buildPhase = ''
    runHook preBuild
    $CXX -std=c++17 -O2 -Wall -Wextra -fPIC \
      kmail-keychain-set.cpp \
      $(pkg-config --cflags --libs Qt6Core) \
      -I${pkgs.qt6Packages.qtkeychain}/include \
      -L${pkgs.qt6Packages.qtkeychain}/lib \
      -lqt6keychain \
      -o kmail-keychain-set
    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck
    pytest -v test_kmail_provision.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec/kmail-provision"
    install -m 0755 kmail-keychain-set "$out/bin/kmail-keychain-set"
    install -m 0755 kmail_provision.py "$out/libexec/kmail-provision/kmail_provision.py"

    makeWrapper ${pkgs.python3}/bin/python3 "$out/bin/kmail-provision" \
      --add-flags "$out/libexec/kmail-provision/kmail_provision.py" \
      --prefix PATH : "$out/bin:${pkgs.lib.makeBinPath [
      pkgs.qt6.qttools
      pkgs.kdePackages.akonadi
      pkgs.gnupg
    ]}"
    runHook postInstall
  '';
}
