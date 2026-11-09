# Secure Boot and Lanzaboote Integrity Rules

## CRITICAL: Never Sign `/boot/EFI/nixos/kernel-*.efi` with `sbctl`
All Secure Boot machines in the fleet (Michael, Francis, Agnes, Jerome) use **Lanzaboote** with a thin stub architecture:

1. **How It Works:**
   - The UEFI firmware loads and authenticates the signed UKI/generation stub at `/boot/EFI/Linux/nixos-generation-*.efi`.
   - The generation thin stub loads `/boot/EFI/nixos/kernel-*.efi` and `/boot/EFI/nixos/initrd-*.efi`.
   - The stub verifies the kernel by comparing its **exact SHA-256 hash** against the build-time checksum embedded into the generation stub binary.
   - The raw kernel files in `/boot/EFI/nixos/` are **intentionally NOT Authenticode-signed**.

2. **Why Modifying Them Is Catastrophic:**
   - Running `sbctl sign` on `/boot/EFI/nixos/kernel-*.efi` modifies the PE binary on disk by appending an Authenticode certificate table to the end of the file.
   - This invalidates its SHA-256 checksum.
   - On the next reboot, the thin stub detects the checksum mismatch and halts boot with:
     ```text
     [ERROR] : stub/src/thin.rs: Kernel hash does not match!
     [PANIC] : panicked at stub/src/main.rs: Failed to extract configuration from binary... Error { status: SECURITY_VIOLATION }
     ```
   - The machine is completely unbootable until recovered via a live USB/ISO.

3. **Expected `sbctl verify` Behavior:**
   - `sbctl verify` scans the entire ESP for `.efi` files and will ALWAYS mark `/boot/EFI/nixos/kernel-*.efi` with `✗ Not Signed`.
   - **This is expected and correct.** NEVER run `sbctl sign` or `sbctl sign-all` to clear these entries.
   - Genuine bootloader binaries that MUST be signed are `/boot/EFI/BOOT/*.EFI`, `/boot/EFI/systemd/*.efi`, and `/boot/EFI/Linux/*.efi`.
