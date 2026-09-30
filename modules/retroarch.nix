{
  config,
  lib,
  pkgs,
  ...
}: {
  options.retroarch = {
    enable = lib.mkEnableOption "Enable RetroArch";
  }; # options.retroarch

  config = lib.mkIf config.retroarch.enable {
    hardware.xone.enable = true;

    environment.systemPackages = with pkgs; [
      (retroarch.withCores (
        cores:
          with libretro; [
            fbalpha2012 # arcade for low-end devices
            mame2003-plus # arcade general purpose
            mame2010 # arcade compatibility
            mame2016 # arcade compatibility
            puae # Commodore Amiga
            dosbox-pure # dos
            beetle-pce # pc engine
            gambatte # Nintendo GB/GBC
            mgba # Nintendo GBA
            beetle-vb # Nintendo Virtual Boy
            melonds # Nintendo DS
            nestopia # Nintendo NES
            snes9x # Nintendo SNES
            parallel-n64 # Nintendo 64 with high accuracy
            mupen64plus # Nintendo 64 with high performance
            dolphin # Nintendo GameCube/Wii
            scummvm # point-and-click PC games
            genesis-plus-gx # Sega Master System/Genesis/CD
            picodrive # Sega 32x
            yabause # Sega Saturn
            flycast # Sega Dreamcast
            fbneo # SNK Neo Geo
            swanstation # Sony Playstation
            pcsx2 # Sony Playstation 2
            ppsspp # Sony Playstation portable
          ]
      ))
    ]; # environment.systemPackages
  }; # config
}
