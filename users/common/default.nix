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
                file = relativeToRoot "secrets/bypass-paywalls-chrome-clean-3.8.5.0.crx.age";
                name = "bypass-paywalls-chrome-clean-3.8.5.0.crx";
                mode = "644";
                owner = "root";
                group = "users";
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
              version = "3.8.5.0";
            };
          };

          copyparty.users = lib.mkIf hasPassphrase (lib.mkMerge [
            [
              {
                name = username;
                passwordFile = config.age.secrets."${username}-passphrase".path;
                canWriteMedia = isWheel;
              }
            ]
          ]);

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
              hashedPasswordFile = lib.mkIf hasPassphrase config.age.secrets."${username}-passphrase".path;
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
                file = lib.optionalAttrs (userKey != null) {
                  ".ssh/id_ed25519.pub".text = userKey;
                  ".ssh/allowed_signers".text = "${git.email} ${userKey}";
                };
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
                      name = git.name;
                      email = git.email;
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
            resolvedExtraHomeConfig
          ];
        }
        resolvedExtraConfig
      ]))
  ];
}
