# nixcfg TODO

## Upstream & Packaging Fixes

- [ ] **Remove `pihole-ftl` GCC 15 overlay on `michael`**:
  - **Context**: In `hosts/michael/dns.nix`, an overlay passes `-Wno-error=unused-but-set-variable` to `pihole-ftl` because upstream Pi-hole FTL 6.7.1 contains an unused variable `i` in `src/config/validator.c:824` that fails under GCC 15 with `-Werror`.
  - **Action**: Once upstream nixpkgs or Pi-hole patches this warning/error and a binary substitute is available on `cache.nixos.org`, remove `nixpkgs.overlays` from `hosts/michael/dns.nix` to return to the mainline package with strict compile warnings as errors.
