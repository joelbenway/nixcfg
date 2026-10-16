# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
let
  tailnet = "gentoo-humboldt.ts.net";
in {
  inherit tailnet;

  devices = {
    agnes = {
      id = "O6R4J2L-LEMIKIM-FPZF2CB-UX647SR-G62IRHL-BUWHIKF-WROG3UQ-JUTSYAJ";
      addresses = ["tcp://agnes.${tailnet}:22000"];
    };
    francis = {
      id = "DDQ4SQY-JAPZ3J2-B5LNIDQ-K26JWJX-25CKGUQ-3OEDVKR-EJC7T4C-ACRQFA4";
      addresses = ["tcp://francis.${tailnet}:22000"];
    };
    jerome = {
      id = "3V6SMMC-RVFVRML-LCQGV3D-FD7XPJ4-YOW37AU-SKV5MNQ-5AZOX56-PTGTVAD";
      addresses = ["tcp://jerome.${tailnet}:22000"];
    };
  };

  folders = {
    "sync" = {
      id = "sync";
      label = "Sync";
      defaultPath = "/home/joel/Sync";
      devices = ["agnes" "francis" "jerome"];
      versioning = {
        type = "simple";
        params = {
          keep = "5";
        };
      };
    };
  };
}
