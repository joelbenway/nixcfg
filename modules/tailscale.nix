{
  config,
  lib,
  pkgs,
  ...
}: {
  options.tailscale = {
    enable = lib.mkEnableOption "Enable tailscale.";
    envFile = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      example = "/home/user/.secrets/ts.env";
      description = ''
        Path to an EnvironmentFile containing TS_API_CLIENT_ID,
        TS_API_CLIENT_SECRET and potentially other Tailscale-related
        variables in the future. The file must be in systemd EnvironmentFile
        format (one NAME=value per line, no spaces around =).
      '';
    }; # envFile

    tailnet = lib.mkOption {
      type = lib.types.str;
      default = "gentoo-humboldt.ts.net";
      description = "Tailscale tailnet domain name";
    };
  }; # options.tailscale

  config = lib.mkIf config.tailscale.enable {
    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraUpFlags = ["--reset" "--accept-routes" "--accept-dns=false" "--ssh" "--advertise-tags=tag:nixos"];
      extraSetFlags = [];
      extraDaemonFlags = [];
    }; # services.tailscale

    systemd.services = {
      tailscaled-authenticate = lib.mkIf (config.tailscale.envFile != null) (let
        cfg = config.services.tailscale;
      in {
        description = "Automatic authentication for Tailscale";
        after = ["tailscaled.service" "network-online.target"];
        wants = ["tailscaled.service" "network-online.target"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "notify";
        };
        path = [
          cfg.package
          pkgs.jq

          pkgs.curl
        ];
        enableStrictShellChecks = true;
        script =
          # bash
          ''
            getState() {
              tailscale status --json --peers=false | jq -r '.BackendState'
            }

            lastState=""
            while state="$(getState)"; do
              if [[ "$state" != "$lastState" ]]; then
                # https://github.com/tailscale/tailscale/blob/v1.72.1/ipn/backend.go#L24-L32
                case "$state" in
                  Stopped)
                    tailscale up ${lib.concatStringsSep " " cfg.extraUpFlags}
                    ;;
                  NeedsLogin)
                    echo "Server needs authentication, creating auth key..."
                    set -a
                    # shellcheck source=/dev/null
                    source ${config.tailscale.envFile}
                    set +a

                    access_token=$(curl -s -u "$TS_API_CLIENT_ID:$TS_API_CLIENT_SECRET" \
                      -d "grant_type=client_credentials" \
                      "https://api.tailscale.com/api/v2/oauth/token" | jq -r '.access_token')

                    if [[ "$access_token" == "null" || -z "$access_token" ]]; then
                      echo "Failed to get access token"
                      exit 1
                    fi

                    auth_key=$(curl -s -H "Authorization: Bearer $access_token" \
                      -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
                      -d '{
                        "capabilities": {
                          "devices": {
                            "create": {
                              "reusable": false,
                              "ephemeral": false,
                              "preauthorized": true,
                              "tags": ["tag:nixos"]
                            }
                          }
                        },
                        "expirySeconds": 60
                      }' | jq -r '.key')

                    if [[ "$auth_key" == "null" || -z "$auth_key" ]]; then
                      echo "Failed to create auth key"
                      exit 1
                    fi

                    tailscale up --authkey="$auth_key" ${lib.concatStringsSep " " cfg.extraUpFlags}
                    ;;
                  Running)
                    echo "Tailscale is running"
                    systemd-notify --ready
                    exit 0
                    ;;
                  *)
                    echo "Waiting for Tailscale State (Current: $state)"
                    ;;
                esac
              fi
              lastState="$state"
              sleep .5
            done
          '';
      }); # tailscaled-authenticate
    }; # systemd.services
  }; # config
}
