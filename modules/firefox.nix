# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: {
  options.firefox = {
    enable = lib.mkEnableOption "Enables firefox browser";
    extensions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = with lib.types; either path str;
            description = "Path to the .xpi file or URL to the extension";
          };
          installation_mode = lib.mkOption {
            type = lib.types.str;
            default = "force_installed";
          };
          default_area = lib.mkOption {
            type = lib.types.str;
            default = "navbar";
          };
        };
      });
      default = {};
      description = "Attribute set of extension IDs to their settings";
    };
  }; # options

  config = lib.mkIf config.firefox.enable {
    services.psd.enable = true;

    programs.firefox = {
      enable = true;
      policies = {
        DisableFirefoxAccounts = true;
        # DisableTelemetry = true;
        # DisableFirefoxStudies = true;
        # DontCheckDefaultBrowser = true;
        DisablePocket = true;
        # NewTabPage = false;
        SearchBar = "unified";

        Preferences = {
        }; # Preferences

        ExtensionSettings =
          {
            "uBlock0@raymondhill.net" = {
              install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
              installation_mode = "force_installed";
              default_area = "navbar";
            };
            "{446900e4-71c2-419f-a6a7-df9c091e268b}" = {
              install_url = "https://addons.mozilla.org/firefox/downloads/latest/bitwarden-password-manager/latest.xpi";
              installation_mode = "force_installed";
              default_area = "navbar";
            };
          }
          // (lib.mapAttrs (_: value: {
              install_url =
                if builtins.isPath value.source
                then "file://${value.source}"
                else value.source;
              inherit (value) installation_mode default_area;
            })
            config.firefox.extensions);
      }; # policies
    }; # programs.firefox

    home-manager.sharedModules = [
      ({config, ...}: {
        home.activation = {
          createFirefoxDir = ''
            mkdir -p "${config.xdg.configHome}/mozilla/firefox"
          '';
          cleanupFirefoxSymlinks = ''
            if [ -L "${config.xdg.configHome}/mozilla/firefox/hardened" ]; then
              rm "${config.xdg.configHome}/mozilla/firefox/hardened"
            fi
          '';
        };

        programs.firefox = {
          enable = true;
          configPath = "${config.xdg.configHome}/mozilla/firefox";
          profiles = {
            hardened = {
              id = 0;
              name = "default";
              isDefault = true;
              settings = {
                # Startup
                "browser.aboutConfig.showWarning" = false;
                "browser.startup.page" = 1;
                "browser.startup.homepage" = "about:home";
                "browser.newtabpage.enabled" = false;
                "browser.newtabpage.activity-stream.feeds.telemetry" = false;
                "browser.newtabpage.activity-stream.telemetry" = false;
                "browser.newtabpage.activity-stream.showSponsored" = false;
                "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
                "browser.newtabpage.activity-stream.default.sites" = "";
                "browser.newtabpage.activity-stream.feeds.section.topstories" = false;
                # Geolocation
                "geo.provider.network.url" = "https://location.services.mozilla.com/v1/geolocate?key=%MOZILLA_API_KEY%";
                "geo.provider.use_gpsd" = false;
                "geo.provider.use_geoclue" = false;
                # Language / Locale
                "intl.accept_languages" = "en-US, en";
                "javascript.use_us_english_locale" = true;
                # Recommendations
                "extensions.getAddons.showPane" = false;
                "extensions.htmlaboutaddons.recommendations.enabled" = false;
                "browser.discovery.enabled" = false;
                "browser.urlbar.suggest.quicksuggest.nonsponsored" = false;
                "browser.urlbar.suggest.quicksuggest.sponsored" = false;
                "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons" = false;
                "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features" = false;
                # Telemetry
                "datareporting.policy.dataSubmissionEnabled" = false;
                "datareporting.healthreport.uploadEnabled" = false;
                "toolkit.telemetry.enabled" = false;
                "toolkit.telemetry.unified" = false;
                "toolkit.telemetry.server" = "data:,";
                "toolkit.telemetry.archive.enabled" = false;
                "toolkit.telemetry.newProfilePing.enabled" = false;
                "toolkit.telemetry.shutdownPingSender.enabled" = false;
                "toolkit.telemetry.updatePing.enabled" = false;
                "toolkit.telemetry.bhrPing.enabled" = false;
                "toolkit.telemetry.firstShutdownPing.enabled" = false;
                "toolkit.telemetry.coverage.opt-out" = true;
                "toolkit.coverage.opt-out" = true;
                "toolkit.coverage.endpoint.base" = "";
                "browser.ping-centre.telemetry" = false;
                # Studies
                "app.shield.optoutstudies.enabled" = false;
                "app.normandy.enabled" = false;
                "app.normandy.api_url" = "";
                "breakpad.reportURL" = "";
                "browser.tabs.crashReporting.sendReport" = false;
                # Captive portal detection / network checks
                "captivedetect.canonicalURL" = "";
                "network.captive-portal-service.enabled" = false;
                "network.connectivity-service.enabled" = false;
                # Safe browsing
                "browser.safebrowsing.malware.enabled" = false;
                "browser.safebrowsing.phishing.enabled" = false;
                "browser.safebrowsing.blockedURIs.enabled" = false;
                "browser.safebrowsing.provider.google4.gethashURL" = "";
                "browser.safebrowsing.provider.google4.updateURL" = "";
                "browser.safebrowsing.provider.google.gethashURL" = "";
                "browser.safebrowsing.provider.google.updateURL" = "";
                "browser.safebrowsing.provider.google4.dataSharingURL" = "";
                "browser.safebrowsing.downloads.enabled" = false;
                "browser.safebrowsing.downloads.remote.enabled" = false;
                "browser.safebrowsing.downloads.remote.url" = "";
                "browser.safebrowsing.downloads.remote.block_potentially_unwanted" = false;
                "browser.safebrowsing.downloads.remote.block_uncommon" = false;
                "browser.safebrowsing.allowOverride" = false;
                # Network: dns, proxies, IPv6
                "network.prefetch-next" = false;
                "network.dns.disablePrefetch" = true;
                "network.predictor.enabled" = false;
                "network.http.speculative-parallel-limit" = 0;
                "browser.places.speculativeConnect.enabled" = false;
                "network.dns.disableIPv6" = true;
                "network.gio.supported-protocols" = "";
                "network.file.disable_unc_paths" = true;
                "permissions.manager.defaultsUrl" = "";
                "network.IDN_show_punycode" = true;
                "doh-rollout.disable-heuristics" = true;
                "network.trr.mode" = 2;
                "network.trr.uri" = "https://dns.quad9.net/dns-query";
                # Search bar: suggestions, autofill
                "browser.search.defaultenginename" = "DuckDuckGo";
                "browser.search.order.1" = "DuckDuckGo";
                "browser.search.suggest.enabled" = false;
                "browser.urlbar.suggest.searches" = false;
                "browser.urlbar.trending.featureGate" = false;
                "browser.urlbar.addons.featureGate" = false;
                "browser.urlbar.mdn.featureGate" = false;
                "browser.urlbar.speculativeConnect.enabled" = false;
                "browser.formfill.enable" = false;
                "extensions.formautofill.addresses.enabled" = false;
                "extensions.formautofill.creditCards.enabled" = false;
                # Passwords
                "signon.rememberSignons" = false;
                "signon.autofillForms" = false;
                "signon.formlessCapture.enabled" = false;
                "network.auth.subresource-http-auth-allow" = 1;
                "signon.management.page.break-alerts.enabled" = false;
                # Disk cache and memory
                "browser.cache.disk.enable" = false;
                "browser.privatebrowsing.forceMediaMemoryCache" = true;
                "media.memory_cache_max_size" = 65536;
                "browser.sessionstore.privacy_level" = 2;
                "browser.sessionstore.resume_from_crash" = false;
                "browser.pagethumbnails.capturing_disabled" = true;
                "browser.download.start_downloads_in_tmp_dir" = true;
                "browser.helperApps.deleteTempFileOnExit" = true;
                # Https
                "dom.security.https_only_mode" = true;
                "dom.security.https_only_mode_send_http_background_request" = false;
                "browser.xul.error_pages.expert_bad_cert" = true;
                "security.tls.enable_0rtt_data" = false;
                "security.OCSP.require" = true;
                "security.cert_pinning.enforcement_level" = 2;
                "security.remote_settings.crlite_filters.enabled" = true;
                "security.pki.crlite_mode" = "2";
                # Headers / referers
                "network.http.referer.XOriginPolicy" = 2;
                "network.http.referer.XOriginTrimmingPolicy" = 2;
                # Audio / Video: WebRTC, WebGL, DRM
                "media.autoplay.default" = 5;
                "media.peerconnection.ice.proxy_only_if_behind_proxy" = true;
                "media.peerconnection.ice.default_address_only" = true;
                "media.peerconnection.ice.no_host" = true;
                "webgl.disabled" = false;
                "media.eme.enabled" = false;
                # Downloads
                "browser.download.useDownloadDir" = false;
                "browser.download.manager.addToRecentDocs" = false;
                # Cookies
                "browser.contentblocking.category" = "strict";
                # UI Features
                "dom.popup_allowed_events" = "click dblclick mousedown pointerdown";
                "extensions.pocket.enabled" = false;
                "pdfjs.enableScripting" = false;
                "privacy.userContext.enabled" = true;
                "privacy.userContext.ui.enabled" = true;
                # Extensions
                "extensions.enabledScopes" = 5;
                "extensions.postDownloadThirdPartyPrompt" = false;
                # Shutdown Settings
                "privacy.sanitize.sanitizeOnShutdown" = true;
                "privacy.clearOnShutdown.cookies" = true;
                "privacy.clearOnShutdown.offlineApps" = true;
                "privacy.sanitize.timeSpan" = 0;
                # Fingerprinting (RFP)
                "privacy.resistFingerprinting" = false;
                "privacy.resistFingerprinting.pbmode" = false;
                "privacy.fingerprintingProtection" = true;
                "privacy.fingerprintingProtection.pbmode" = true;
                "privacy.fingerprintingProtection.overrides" = "+AllTargets,-CSSPrefersColorScheme";
                "privacy.window.maxInnerWidth" = 3840;
                "privacy.window.maxInnerHeight" = 2160;
                "privacy.resistFingerprinting.letterboxing" = false;
                "privacy.resistFingerprinting.block_mozAddonManager" = true;
                "browser.display.use_system_colors" = false;
                "browser.link.open_newwindow.restriction" = 0;
              }; # settings

              search = {
                force = true;
                default = "ddg";
                order = ["ddg" "google"];
              }; # search

              bookmarks = {
                force = true;
                settings = [
                  # {
                  #   name = "wikipedia";
                  #   tags = ["wiki"];
                  #   keyword = "wiki";
                  #   url = "https://en.wikipedia.org/wiki/Special:Search?search=%s&go=Go";
                  # }
                  {
                    name = "Nix sites";
                    toolbar = true;
                    bookmarks = [
                      {
                        name = "manual";
                        url = "https://nixos.org/manual/nixos/unstable/";
                      }
                      {
                        name = "wiki";
                        tags = ["wiki" "nix"];
                        url = "https://wiki.nixos.org/";
                      }
                      {
                        name = "package search";
                        tags = ["package" "search" "nix"];
                        url = "https://search.nixos.org/packages";
                      }
                      {
                        name = "home-manager search";
                        tags = ["home-manager" "search" "nix"];
                        url = "https://home-manager-options.extranix.com/?query=&release=master";
                      }
                      {
                        name = "noogle";
                        tags = ["api" "search" "nix"];
                        url = "https://noogle.dev/";
                      }
                    ];
                  }
                ]; # settings
              }; # bookmarks
            }; # hardened
          }; # profiles
        }; # programs.firefox
      })
    ]; # home-manager.sharedModules
  }; # config
}
