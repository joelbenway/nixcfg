# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  serverHost = "zita";
  basePath = "/storage";

  # Shared fleet folders
  shares = {
    Public = {
      name = "Public";
      path = "/storage/public";
      comment = "Public Guest Share";
      readOnly = false;
      guestOk = true;
      forceUser = "nobody";
      forceGroup = "users";
      desktop = {
        name = "Zita Public";
        icon = "folder-remote";
      };
    };
    Media = {
      name = "Media";
      path = "/storage/media";
      comment = "Shared Media Collection";
      readOnly = true;
      writeList = ["joel" "katy"];
      guestOk = true;
      forceGroup = "users";
      desktop = {
        name = "Zita Media";
        icon = "folder-remote";
      };
    };
  };

  # User personal folders
  userShares = {
    enable = true;
    basePath = "/storage/users";
    desktop = {
      icon = "folder-remote";
    };
  };
}
