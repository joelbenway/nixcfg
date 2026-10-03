{pkgs ? import <nixpkgs> {}}:
pkgs.mkShell {
  buildInputs = [
    pkgs.actionlint
    pkgs.alejandra
    pkgs.gh
    pkgs.git-filter-repo
    pkgs.shellcheck
    pkgs.shfmt
    pkgs.statix
    pkgs.trufflehog
  ];

  shellHook = ''
        HOOK_DIR=".git/hooks"
        PRE_COMMIT="$HOOK_DIR/pre-commit"

        if [ -d "$HOOK_DIR" ]; then
          cat > "$PRE_COMMIT" << 'HOOK'
    #!/usr/bin/env bash

    echo "Processing... (skip with git commit --no-verify)"
    echo ""

    export PATH="${pkgs.alejandra}/bin:${pkgs.trufflehog}/bin:${pkgs.git-filter-repo}/bin:$PATH"

    nix_files=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.nix$' | tr '\n' ' ')
    if [ -n "$nix_files" ]; then
      alejandra --quiet $nix_files
      git add $nix_files
    fi

    echo "Scanning for secrets with trufflehog..."
    staged_files=$(git diff --cached --name-only --diff-filter=ACMR | tr '\n' ' ')
    if [ -n "$staged_files" ]; then
      trufflehog filesystem $staged_files --log-level=-1 --fail
      exit_code=$?
      if [ $exit_code -ne 0 ]; then
        echo "Secrets detected! Commit blocked."
        exit 1
      fi
    fi
    HOOK
          chmod +x "$PRE_COMMIT"
          echo "Git pre-commit hook installed"
        fi
  '';
}
