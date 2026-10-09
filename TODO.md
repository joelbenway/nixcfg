# nixcfg TODO

## Upstream & Packaging Fixes

- [ ] **Remove `pihole-ftl` GCC 15 overlay on `michael`**:
  - **Context**: In `hosts/michael/default.nix`, an overlay passes `-Wno-error=unused-but-set-variable` to `pihole-ftl` because upstream Pi-hole FTL 6.7.1 contains an unused variable `i` in `src/config/validator.c:824` that fails under GCC 15 with `-Werror`.
  - **Action**: Once upstream nixpkgs or Pi-hole patches this warning/error and a binary substitute is available on `cache.nixos.org`, remove `nixpkgs.overlays` from `hosts/michael/default.nix` to return to the mainline package with strict compile warnings as errors.

## Installer & Bootstrapping (`therese`)

- [ ] **Stage `wifi-guest.env` into `/etc` for automatic Wi-Fi on `therese`**:
  - **Context**: `NetworkManager-ensure-profiles` failed to find `/nix/store/...-source/wifi-guest.env` on boot because the flake source tree was excluded from the ISO runtime closure.
  - **Action**: Stage `wifi-guest.env` into `/etc/wifi-guest.env` via `environment.etc."wifi-guest.env".source` and update `networkstack.envFiles = ["/etc/wifi-guest.env"]` in `hosts/therese/default.nix` before the next ISO build so Wi-Fi connects automatically.
