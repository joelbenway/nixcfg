# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{pkgs ? import <nixpkgs> {}}:
pkgs.mkShell {
  buildInputs = [
    pkgs.actionlint
    pkgs.alejandra
    pkgs.gh
    pkgs.git-filter-repo
    pkgs.nixos-anywhere
    pkgs.shellcheck
    pkgs.shfmt
    pkgs.statix
    pkgs.trufflehog
  ];

  shellHook = ''
    HOOK_DIR="$(git rev-parse --git-path hooks 2>/dev/null || true)"
    if [ -n "$HOOK_DIR" ] && [ -d "$HOOK_DIR" ]; then
      PRE_COMMIT="$HOOK_DIR/pre-commit"
      cat > "$PRE_COMMIT" << 'HOOK'
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Processing... (skip with git commit --no-verify)"
    echo ""

    export PATH="${pkgs.alejandra}/bin:${pkgs.trufflehog}/bin:$PATH"

    mapfile -t nix_files < <(git diff --cached --name-only --diff-filter=ACMR -- '*.nix')
    if [ "''${#nix_files[@]}" -gt 0 ]; then
      alejandra --quiet "''${nix_files[@]}"
      git add -- "''${nix_files[@]}"
    fi

    echo "Scanning for secrets with trufflehog..."
    mapfile -t staged_files < <(git diff --cached --name-only --diff-filter=ACMR)
    if [ "''${#staged_files[@]}" -gt 0 ]; then
      if ! trufflehog filesystem "''${staged_files[@]}" --log-level=-1 --fail; then
        echo "Secrets detected! Commit blocked."
        exit 1
      fi
    fi
    HOOK
      chmod +x "$PRE_COMMIT"
      echo "Git pre-commit hook installed"
    fi

    if [ -d ".git" ]; then
      git config submodule.recurse true
      repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      if [ -e "$repo_root/secrets/.git" ]; then
        git config --unset-all url."$repo_root/secrets".insteadOf 2>/dev/null || true
        git config url."$repo_root/secrets".insteadOf "git@github.com:joelbenway/nixos-secrets.git"
        git config --add url."$repo_root/secrets".insteadOf "ssh://git@github.com/joelbenway/nixos-secrets.git"
      fi
    fi
  '';
}
