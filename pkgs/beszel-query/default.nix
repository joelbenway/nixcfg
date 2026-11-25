# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{pkgs}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "beszel-query";
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
    pytest test_beszel_query.py -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/beszel-query" "$out/bin"
    install -m 0755 beszel_query.py "$out/libexec/beszel-query/beszel_query.py"

    makeWrapper "${pkgs.python3}/bin/python3" "$out/bin/beszel-query" \
      --add-flags "$out/libexec/beszel-query/beszel_query.py"
    runHook postInstall
  '';
}
