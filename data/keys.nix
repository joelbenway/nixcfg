# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
let
  users = {
    builder = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB2Rmp00+wVx421JLLbwipi6YxPL+BQkook6V11L+yQf";
    joel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5g3ew1GW6xx32IqKfk/Sq8DIKox+LXUooAkAzilNIn";
    katy = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIJd7UI9essT52TCyG5KJEevgpTiuUuR1UgjZrmVWAMv";
  };

  hosts = {
    agnes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlCIrhv6FyZLixbfzpTkn3Qf1WD2VNEcB9BfdRiQ+J+";
    francis = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMIskZGax3w8vnwxUtmDr2ufhcMWnrtfHyZG8jhsg+aM";
    jerome = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJryUfhvxUAWgszECQNYwFBFyOEcUbE6vLVXubbj6Zg8";
    michael = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHZwO9bTOrXssKPzLX8fymkzNi+JoKMBkZlS0/KnMWdy";
    zita = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEURzS57xEY66xkTP5GEJShmXrsd8PO06znqqsvoEex4";
  };

  hostsBase64 = {
    agnes = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUtsQ0lyaHY2RnlaTGl4YmZ6cFRrbjNRZjFXRDJWTkVjQjlCZmRSaVErSis=";
    francis = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSU1Jc2taR2F4M3c4dm53eFV0bURyMnVmaGNNV25ydGZIeVpHOGpoc2crYU0=";
    jerome = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpyeVVmaHZ4VUFXZ3N6RUNRTll3RkJGeU9FY1ViRTZ2TFZYdWJiajZaZzg=";
    michael = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUhad085YlRPclhzc0tQekxYOGZ5bWt6TmkrSm9LTUJrWmxTMC9Lbk1XZHk=";
    zita = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUVVUnpTNTd4RVk2NnhrVFA1R0VKU2htWHJzZDhQTzA2em5xcXN2b0VleDQ=";
  };
in
  users // hosts // {inherit users hosts hostsBase64;}
