# Joel's Flake ❄

## Hosts
You may notice all the hosts in this flake are named after Catholic Saints. You may also notice most of them are relics. I get a kick out of saving corporate e-waste from the trash, and everything is fast once you put nixos on it.

### agnes
Agnes is a Dell E7270 laptop. Per Dell's naming scheme the E indicates that this is model has an E-port for old fashioned docking stations. The 7 indicates that this is more premium than a 5 or heaven forbid a 3. The 2 indicates this is the 12" model, and the 70 means that the 60 came out the year before and the 80 will come out next year. I am a big fan of this vintage of Latitude. This uses a magnesium and aluminum chassis Dell dubbed it’s “Tri-metal chassis” which passed MIL-STD 810G while being nice and thin. This era was the first to have features like 14nm silicon, a NVME drive, and TPM 2.0 but the last to have the underrated E-port. Agnes has the i7-6600U offering from Dell, but has been upgraded beyond what was available from the factory. It has a much nicer FHD IPS panel, 32GB of ram despite only officially supporting 16GB, and a 1TB Hynix P30 Gold. St. Agnes was martyred at age 12 or 13.

### francis
Francis is an HP ProDesk 600 G4 desktop with an i5-8500T, 32GB of ram, and a 1TB NVMe drive. Another corporate relic saved from the trash, this one serves as a workstation. St. Francis of Assisi is famous for his radical solidarity with the poor. He begged for stones and used them to restore ruined chapels.

### jerome
Jerome is a Dell E7470 laptop, pretty much the 14" version of agnes with similar upgrades to ram, nvme, lcd panel, and has been [me cleaned](https://github.com/corna/me_cleaner). One uncommon option jerome has is the i7-6650U processor featuring Intel's Iris iGPU rather than the vanilla Intel HD graphics. Jerome has been my daily driver these past few years and still feels as modern as the machines I use at work thanks to nixos. St. Jerome is a doctor of the Church and is most famous for translating the early bible into Latin.

### therese
Therese is a customized nixos iso for installing this config. The [build_iso](./scripts/build_iso) script creates the therese iso injected with the necessary secrets to easily bootstrap another host. This build is done in a container so as to prevent the secrets in the iso's /nix/store from being accessible to any user on the host /nix/store. St. Therese is a very famous saint, doctor of the church, and patron saint of missionaries. Her "little way" was a sharp contrast between the heroic perfectrionism and spiritual effortmaxxing.

### michael
Michael is a HP Slim desktop with an i3-12100 and a dual 2.5GBE nic. It serves as a home firewall.  St. Michael the Archangel is the prince of the heavenly host and patron saint of soldiers, police, and the sick. Who better to guard the gate?

### zita
Zita is an HP z620 workstation. It has dual 8-core Xeon E5-2667v2 CPUs and 128 GB of ram. It was quite the prize when it was new in 2012 or so. It's secureboot is all old and quirky and it's TPM is 1.2, but otherwise it's aged well. This one was used as a controller for a video wall in Chicago. After selling it's expensive capture cards the machine was better than free. Now it heats my basement while serving files over Samba and [copyparty](https://github.com/9001/copyparty). St. Zita is the patron saint of domestic servants and is often depicted holding keys.

## Features
* Multi-Host
* Multi-User
* [home-manager](https://github.com/nix-community/home-manager) and [plasma-manager](https://github.com/nix-community/plasma-manager)
* secret management using [agenix](https://github.com/ryantm/agenix)
* impermanence on root
* secureboot using [lanzaboote](https://github.com/nix-community/lanzaboote)
* declarative disk layout using [disko](https://github.com/nix-community/disko)
* declarative firewall with VLAN routing and NAT
* Custom install iso

## Areas of Note
* My [firefox](./modules/firefox.nix) is quite nice with a hardened profile and all my extensions included.
* [Brave](./modules/brave.nix) is similar to my firefox module, but maybe not as optimized.
* [Tailscale](./modules/tailscale.nix) My tailscale module uses an oauth token that doesn't have to be rotated as often as an API key.
* [AI](./modules/llm.nix) I have a local ai module with llama-cpp and llama-swap others might find interesting.
* [Loadkeys](./modules/loadkeys.nix) A systemd user service that imports API keys into the session environment for tools like [opencode](./modules/opencode.nix) and [gemini](./modules/gemini.nix) as well as a shared [mcp](./modules/mcp.nix) server setup.

## Get Started

## Chicken-Egg
To install one of the profiles that utilizes secrets, you'll first need a secret. The [therese](#therese) install iso solves this bootstrap problem. The [build_iso](./scripts/build_iso) script builds the iso inside a podman container to prevent the secrets injected from entering the host nix store. The iso also includes a copy of the flake, an install script, and all the tools needed to recover or fully provision a machine from scratch.

## Lanzaboote
The [secureboot module](./modules/secureboot.nix) automates most of this process. When `secureboot.enable = true`, lanzaboote is configured with auto key generation and auto enrollment (including reboot). You just need to enable secureboot in your UEFI first — the module handles the rest on first boot.

For reference, the manual steps are: generate keys using the ```sbctl``` package with ```sudo sbctl create-keys``` or ```sudo nix run nixpkgs#sbctl create-keys```. This will generate keys in /var/lib/sbctl. After this the platform keys can be deleted or reset from the system UEFI interface, secureboot enabled, and the bios password locked. The final step is to enroll the new keys with the command ```sudo sbctl enroll-keys --microsoft``` or ```sudo nix run nixpkgs#sbctl enroll-keys -- --microsoft```. The command ```bootctl status``` should confirm secure boot is enabled.

## TPM Unlock
The [tpm module](./modules/tpm.nix) automates TPM enrollment. When `tpm.enable = true`, a oneshot systemd service checks each configured LUKS device and enrolls it with TPM2 if not already enrolled, using the passphrase from your agenix secrets. No manual steps required.

For reference, the manual command is: ```sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+2+7+12 --wipe-slot=tpm2 /dev/nvme0n1p2``` for each encrypted partition. You'll be prompted for the password.