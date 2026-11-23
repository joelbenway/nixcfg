# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{pkgs}:
pkgs.writeShellApplication {
  name = "beszel-query";
  runtimeInputs = [pkgs.python3];
  text = ''
    exec python3 ${./beszel_query.py} "$@"
  '';
}
