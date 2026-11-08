# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  lib,
  username,
  description,
  uid ? null,
  shell ? null,
  isWheel ? true,
  authorizedKeys ? [],
  extraGroups ? [],
  desktop ? true,
  packages ? [],
  homePackages ? [],
  homeImports ? [],
  stateVersion ? "24.05",
  git ? null,
  extraConfig ? {},
  extraHomeConfig ? {},
}: let
  relativeToRoot = lib.path.append ../../.;

  keys = import (relativeToRoot "data/keys.nix");
  userKey = keys.${username} or null;

  capitalizedUser =
    (lib.toUpper (lib.substring 0 1 username))
    + (lib.substring 1 (-1) username);

  storageConfig = import (relativeToRoot "data/shares.nix");
  storageServer = storageConfig.serverHost;

  passphraseFile = relativeToRoot "secrets/${username}-passphrase.age";
  hasPassphrase = builtins.pathExists passphraseFile;

  sshKeyFile = relativeToRoot "secrets/${username}-ssh.age";
  hasSshKey = builtins.pathExists sshKeyFile;

  pfpPng = relativeToRoot "secrets/${username}s-pfp.png.age";
  pfpJpg = relativeToRoot "secrets/${username}s-pfp.jpg.age";
  hasPfp = builtins.pathExists pfpPng || builtins.pathExists pfpJpg;
  pfpFile =
    if builtins.pathExists pfpPng
    then pfpPng
    else pfpJpg;
in {
  options.${username} = {
    enable = lib.mkEnableOption "Enables user ${username}";
    desktop = lib.mkOption {
      type = lib.types.bool;
      default = desktop;
      description = "Enable this users desktop environment.";
    }; # desktop
  }; # options.${username}

  imports = [
    ({
      config,
      inputs,
      lib,
      pkgs,
      ...
    }: let
      ifExists = groups: builtins.filter (group: builtins.hasAttr group config.users.groups) groups;

      resolve = arg:
        if builtins.isFunction arg
        then arg {inherit username config pkgs lib;}
        else arg;

      resolvedExtraConfig = resolve extraConfig;
      resolvedExtraHomeConfig = resolve extraHomeConfig;
      resolvedPackages = resolve packages;
      resolvedHomePackages = resolve homePackages;
    in
      lib.mkIf config.${username}.enable (lib.mkMerge [
        {
          age.secrets =
            (lib.optionalAttrs hasPassphrase {
              "${username}-passphrase".file = passphraseFile;
            })
            // (lib.optionalAttrs hasSshKey {
              "${username}-ssh" = {
                file = sshKeyFile;
                path = "/home/${username}/.ssh/id_ed25519";
                mode = "600";
                owner = username;
                group = "users";
              };
            })
            // (lib.optionalAttrs hasPfp {
              "${username}s-pfp" = {
                file = pfpFile;
                path = "/home/${username}/.face.icon";
                mode = "644";
                owner = username;
                group = "users";
              };
            })
            // {
              bypass-paywalls-firefox = {
                file = relativeToRoot "secrets/bypass_paywalls_clean-latest.xpi.age";
                name = "bypass_paywalls_clean-latest.xpi";
                mode = "644";
                owner = "root";
                group = "users";
              };
              bypass-paywalls-chrome = {
                file = relativeToRoot "secrets/bypass-paywalls-chrome-clean-latest.crx.age";
                name = "bypass-paywalls-chrome-clean-latest.crx";
                mode = "644";
                owner = "root";
                group = "users";
              };
            };

          system.activationScripts = lib.mkIf hasPassphrase {
            users.deps = ["${username}-password-hash"];
            "${username}-password-hash" = {
              deps = ["agenixInstall"];
              text = ''
                mkdir -m 0700 -p /run/user-password-hashes
                if [ -f "${config.age.secrets."${username}-passphrase".path}" ]; then
                  NEW_SUM="$(${pkgs.coreutils}/bin/sha256sum "${config.age.secrets."${username}-passphrase".path}" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
                  OLD_SUM="$(cat "/run/user-password-hashes/${username}.sha256" 2>/dev/null || true)"
                  if [ "$NEW_SUM" != "$OLD_SUM" ] || [ ! -f "/run/user-password-hashes/${username}.hash" ]; then
                    ${pkgs.coreutils}/bin/tr -d '\r\n' < "${config.age.secrets."${username}-passphrase".path}" | ${pkgs.mkpasswd}/bin/mkpasswd -m sha-512 -s > "/run/user-password-hashes/${username}.hash.tmp"
                    chmod 0600 "/run/user-password-hashes/${username}.hash.tmp"
                    mv "/run/user-password-hashes/${username}.hash.tmp" "/run/user-password-hashes/${username}.hash"
                    echo "$NEW_SUM" > "/run/user-password-hashes/${username}.sha256"
                  fi
                fi
              '';
            };
          };

          systemd.tmpfiles.rules =
            [
              "d /home/${username}/.ssh 0700 ${username} users -"
            ]
            ++ lib.optional (builtins.hasAttr "/storage" config.fileSystems) "d /storage/users/${username} 0700 ${username} users -";

          plasma = lib.mkIf config.${username}.desktop {
            enable = true;
            users.${username} = {
              theme = "org.kde.breezedark.desktop";
            };
          };

          firefox = lib.mkIf config.${username}.desktop {
            enable = true;
            extensions."magnolia@12.34" = {
              source = config.age.secrets.bypass-paywalls-firefox.path;
              default_area = "menupanel";
            };
          };

          brave = lib.mkIf config.${username}.desktop {
            enable = true;
            extensions."lkbebcjgcmobigpeffafkodonchffocl" = {
              source = config.age.secrets.bypass-paywalls-chrome.path;
              version = "4.4.7.7";
            };
          };

          copyparty.users = lib.mkIf hasPassphrase [
            {
              name = username;
              passwordFile = config.age.secrets."${username}-passphrase".path;
              canWriteMedia = isWheel;
            }
          ];

          samba.users = lib.mkIf hasPassphrase {
            ${username}.passwordFile = config.age.secrets."${username}-passphrase".path;
          };

          users.users.${username} =
            {
              isNormalUser = true;
              inherit description;
              inherit uid;
              homeMode = "0755";
              extraGroups =
                [
                  "audio"
                  "input"
                  "networkmanager"
                  "storage"
                  "video"
                ]
                ++ lib.optional isWheel "wheel"
                ++ extraGroups
                ++ ifExists [
                  "dialout"
                  "docker"
                  "lp"
                  "lxd"
                  "podman"
                  "scanner"
                ];
              hashedPasswordFile = lib.mkIf hasPassphrase "/run/user-password-hashes/${username}.hash";
              openssh.authorizedKeys.keys = lib.unique (authorizedKeys ++ (lib.optional (userKey != null) userKey));
            }
            // lib.optionalAttrs (shell != null) {inherit shell;}; # users.users.${username}

          environment.systemPackages = resolvedPackages;

          home-manager.users.${username} = lib.mkMerge [
            {
              imports = homeImports;
              home = {
                inherit username stateVersion;
                homeDirectory = "/home/${username}";
                packages = resolvedHomePackages;
                shellAliases = {
                  dotfiles = "${pkgs.git}/bin/git --git-dir=\"$HOME/.dotfiles/\" --work-tree=\"$HOME\"";
                };
                file = lib.optionalAttrs (userKey != null) (
                  {
                    ".ssh/id_ed25519.pub".text = userKey;
                  }
                  // lib.optionalAttrs (git != null && git ? email) {
                    ".ssh/allowed_signers".text = "${git.email} ${userKey}";
                  }
                );
                # https://wiki.archlinux.org/title/Dotfiles
                activation.initDotfiles = inputs.home-manager.lib.hm.dag.entryAfter ["writeBoundary"] ''
                  if [ ! -d "$HOME/.dotfiles" ]; then
                    ${pkgs.git}/bin/git init --bare "$HOME/.dotfiles"
                    ${pkgs.git}/bin/git --git-dir="$HOME/.dotfiles" config status.showUntrackedFiles no
                  fi
                '';
              };
              programs = {
                bash.enable = true;
                home-manager.enable = true;
                git = lib.mkIf (git != null) {
                  enable = true;
                  settings = {
                    user = {
                      inherit (git) name email;
                    }; # user
                    gpg = {
                      ssh = {
                        allowedSignersFile = "~/.ssh/allowed_signers";
                      }; # ssh
                    }; # gpg
                  }; # settings
                  signing = {
                    format = "ssh";
                    key = "~/.ssh/id_ed25519.pub";
                    signByDefault = true;
                  }; # signing
                }; # git
              }; # programs
            }
            (lib.mkIf config.${username}.desktop {
              xdg.dataFile =
                lib.mapAttrs' (_key: share: {
                  name = "remoteview/${storageServer}-${share.name}.desktop";
                  value.text = ''
                    [Desktop Entry]
                    Icon=${share.desktop.icon or "folder-remote"}
                    Name=${share.desktop.name or "${storageServer} ${share.name}"}
                    Type=Link
                    URL=smb://${username}@${storageServer}/${share.name}
                  '';
                })
                storageConfig.shares
                // lib.optionalAttrs (storageConfig.userShares.enable or false) {
                  "remoteview/${storageServer}-${capitalizedUser}.desktop".text = ''
                    [Desktop Entry]
                    Icon=${storageConfig.userShares.desktop.icon or "folder-remote"}
                    Name=${storageServer} ${capitalizedUser}
                    Type=Link
                    URL=smb://${username}@${storageServer}/${capitalizedUser}
                  '';
                };

              home.activation.sambaPlaces = let
                sharesList =
                  (lib.mapAttrsToList (_key: share: [
                      "smb://${username}@${storageServer}/${share.name}"
                      (share.desktop.name or "${storageServer} ${share.name}")
                      (share.desktop.icon or "folder-remote")
                    ])
                    storageConfig.shares)
                  ++ lib.optional (storageConfig.userShares.enable or false) [
                    "smb://${username}@${storageServer}/${capitalizedUser}"
                    "${storageServer} ${capitalizedUser}"
                    (storageConfig.userShares.desktop.icon or "folder-remote")
                  ];
                sharesJson = builtins.toJSON sharesList;
              in
                inputs.home-manager.lib.hm.dag.entryAfter ["writeBoundary"] ''
                                  ${pkgs.python3}/bin/python3 -c '
                  import os
                  import json
                  import xml.etree.ElementTree as ET

                  places_file = os.path.expanduser("~/.local/share/user-places.xbel")
                  if not os.path.exists(places_file):
                      exit(0)

                  try:
                      with open(places_file, "r", encoding="utf-8") as f:
                          xml_text = f.read()

                      for prefix, uri in [
                          ("bookmark", "http://www.freedesktop.org/standards/desktop-bookmarks"),
                          ("ns0", "http://www.freedesktop.org/standards/desktop-bookmarks"),
                          ("kdeprivate", "http://www.kde.org")
                      ]:
                          ET.register_namespace(prefix, uri)
                          if f"xmlns:{prefix}" not in xml_text:
                              xml_text = xml_text.replace("<xbel ", f"<xbel xmlns:{prefix}=\"{uri}\" ", 1)

                      root = ET.fromstring(xml_text)
                      tree = ET.ElementTree(root)

                      shares = json.loads(${lib.escapeShellArg sharesJson})
                      target_urls = {url for url, _, _ in shares}

                      # Clean up outdated hostname variants of managed SMB shares
                      changed = False
                      for bm in list(root.findall(".//bookmark")):
                          href = bm.get("href", "")
                          if href.startswith("smb://") and href not in target_urls:
                              for url, _, _ in shares:
                                  share_path = "/" + url.rsplit("/", 1)[-1]
                                  if href.endswith(share_path):
                                      root.remove(bm)
                                      changed = True
                                      break

                      existing_urls = {b.get("href") for b in root.findall(".//bookmark")}

                      for url, title, icon in shares:
                          if url not in existing_urls:
                              bm = ET.SubElement(root, "bookmark", href=url)
                              t = ET.SubElement(bm, "title")
                              t.text = title
                              info = ET.SubElement(bm, "info")
                              meta = ET.SubElement(info, "metadata", owner="http://freedesktop.org")
                              ET.SubElement(meta, "{http://www.freedesktop.org/standards/desktop-bookmarks}icon", name=icon)
                              changed = True

                      if changed:
                          ET.indent(tree, space=" ", level=0)
                          tree.write(places_file, encoding="UTF-8", xml_declaration=True)
                  except Exception as e:
                      print(f"Warning: Could not update user-places.xbel: {e}", flush=True)
                  '
                '';
            })
            resolvedExtraHomeConfig
          ];
        }
        resolvedExtraConfig
      ]))
  ];
}
