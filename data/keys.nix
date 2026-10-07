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
in
  users // hosts // {inherit users hosts;}
