{
  config,
  lib,
  ...
}: {
  options.brave = {
    enable = lib.mkEnableOption "Enables brave browser";
    extensions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = with lib.types; nullOr (either path str);
            default = null;
            description = "Path to the .crx file or update URL";
          };
          version = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Version of the extension (required for local crx)";
          };
        };
      });
      default = {};
      description = "Attribute set of extension IDs to their settings";
    };
  }; # options

  config = lib.mkIf config.brave.enable {
    programs.chromium = {
      enable = true;
      # There is a conflict when mixing the system module and home-manager for
      # managing extensions. It builds but home-manager fails activation.
      # extensions = [
      #   "ddkjiahejlhfcafbddmgiahcphecmpfh" # ublock origin lite
      #   "nngceckbapebfimnlniiiahkandclblb" # bitwarden
      # ];
      extraOpts = {
        "AutofillAddressEnabled" = false;
        "AutofillCreditCardEnabled" = false;
        "BackgroundModeEnabled" = false;
        "BraveAIChatEnabled" = false;
        "BraveRewardsDisabled" = true;
        "BraveVPNDisabled" = true;
        "BraveWalletDisabled" = true;
        "BrowserSignin" = 0;
        "MetricsReportingEnabled" = false;
        "PasswordManagerEnabled" = false;
        "SearchSuggestEnabled" = false;
        "SpellcheckEnabled" = true;
        "SpellcheckLanguage" = [
          "en-US"
        ];
        "SyncDisabled" = true;
      }; # extraOpts
    }; # programs.chromium

    home-manager.sharedModules = [
      ({
        pkgs,
        lib,
        ...
      }: {
        programs = {
          brave = {
            enable = true;
            package = pkgs.brave;
            extensions =
              [
                {
                  id = "ddkjiahejlhfcafbddmgiahcphecmpfh"; # ublock origin lite
                }
                {
                  id = "nngceckbapebfimnlniiiahkandclblb"; # bitwarden
                }
              ]
              ++ (lib.mapAttrsToList (id: value: (
                  {inherit id;}
                  // (lib.optionalAttrs (value.source != null && builtins.isPath value.source) {crxPath = value.source;})
                  // (lib.optionalAttrs (value.source != null && builtins.isString value.source) {updateUrl = value.source;})
                  // (lib.optionalAttrs (value.version != null) {inherit (value) version;})
                ))
                config.brave.extensions);
            commandLineArgs = [
              "-no-default-browser-check"
              "--no-first-run"
            ]; # commandLineArgs
          }; # brave
          chromium.package = null;
          google-chrome.package = null;
          google-chrome-beta.package = null;
          google-chrome-dev.package = null;
          vivaldi.package = null;
          microsoft-edge.package = null;
        }; # programs
      })
    ]; # home-manager.sharedModules
  }; # config
}
