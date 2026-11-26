# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.llm;
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  modelsCatalog = import (lib.custom.relativeToRoot "data/models.nix");

  formatIniValue = v:
    if builtins.isBool v
    then
      (
        if v
        then "true"
        else "false"
      )
    else toString v;

  renderIniSection = name: attrs: let
    lines = lib.mapAttrsToList (k: v: "${k} = ${formatIniValue v}") attrs;
  in ''
    [${name}]
    ${lib.concatStringsSep "\n" lines}
  '';

  globalPresetAttrs =
    modelsCatalog.defaults
    // {
      threads = cfg.threads;
    }
    // lib.optionalAttrs (cfg.numa != null) {
      numa = cfg.numa;
    };

  modelPresetSections = lib.mapAttrsToList (id: m:
    renderIniSection id (
      {
        hf-repo = m.hfRepo;
        ctx-size = m.context;
      }
      // (m.llama or {})
    ))
  modelsCatalog.models;

  modelsPresetFile = pkgs.writeText "llama-models.ini" ''
    version = 1

    ${renderIniSection "*" globalPresetAttrs}
    ${lib.concatStringsSep "\n" modelPresetSections}
  '';

  # Declarative metadata consumed by llm-cache-gc to identify declared vs orphan blobs
  declaredModelsJson = pkgs.writeText "llama-declared-models.json" (
    builtins.toJSON (
      lib.mapAttrsToList (id: m: let
        parts = lib.splitString ":" m.hfRepo;
        repo = builtins.elemAt parts 0;
        tag =
          if builtins.length parts > 1
          then builtins.elemAt parts 1
          else "latest";
        repoPrefix = lib.replaceStrings ["/"] ["_"] repo;
      in {
        inherit id repoPrefix tag;
        hfRepo = m.hfRepo;
        pin = m.pin or false;
      })
      modelsCatalog.models
    )
  );

  cacheGcScript =
    pkgs.writers.writePython3Bin "llm-cache-gc" {
      flakeIgnore = ["E501"];
    } ''
      import argparse
      import json
      import os
      from pathlib import Path
      import sys
      import time

      DEFAULT_CACHE_DIR = "${cfg.cacheDir}"
      DEFAULT_MANIFEST = "${declaredModelsJson}"
      DEFAULT_MAX_AGE_DAYS = ${toString cfg.cacheGc.maxAgeDays}
      DEFAULT_MAX_SIZE_GB = ${toString cfg.cacheGc.maxSizeGB}


      def fmt_bytes(num_bytes: int) -> str:
          size = float(num_bytes)
          for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
              if size < 1024.0 or unit == "TiB":
                  return f"{size:.2f} {unit}"
              size /= 1024.0
          return f"{num_bytes} B"


      def open_files_under(root: Path) -> set[Path]:
          """Return resolved paths under root currently open by any process."""
          open_paths: set[Path] = set()
          root_str = str(root.resolve())
          proc = Path("/proc")
          if not proc.is_dir():
              return open_paths
          for entry in proc.iterdir():
              if not entry.name.isdigit():
                  continue
              fd_dir = entry / "fd"
              try:
                  for fd in fd_dir.iterdir():
                      try:
                          target = os.readlink(fd)
                      except OSError:
                          continue
                      if target.startswith(root_str):
                          open_paths.add(Path(target))
              except OSError:
                  continue
          return open_paths


      def load_declared(manifest_path: Path) -> list[dict]:
          with manifest_path.open("r", encoding="utf-8") as fh:
              return json.load(fh)


      def match_declared_for_gguf(
          gguf_name: str,
          declared: list[dict],
          manifest_file_map: dict[str, dict],
      ) -> dict | None:
          # Exact manifest lookup first (handles multi-tag repos accurately)
          if gguf_name in manifest_file_map:
              return manifest_file_map[gguf_name]
          lower_name = gguf_name.lower()
          for entry in declared:
              prefix = f"{entry['repoPrefix']}_".lower()
              if lower_name.startswith(prefix):
                  return entry
          return None


      def build_manifest_index(
          cache_dir: Path, declared: list[dict]
      ) -> tuple[dict[str, dict], dict[str, list[Path]]]:
          """Map cached GGUF filenames to declared model entries and track manifests."""
          by_manifest_name: dict[str, dict] = {}
          for entry in declared:
              key = f"manifest={entry['repoPrefix']}={entry['tag']}.json".lower()
              by_manifest_name[key] = entry

          gguf_to_declared: dict[str, dict] = {}
          gguf_to_manifests: dict[str, list[Path]] = {}

          for mf in cache_dir.glob("manifest=*.json"):
              decl = by_manifest_name.get(mf.name.lower())
              try:
                  data = json.loads(mf.read_text(encoding="utf-8"))
              except (OSError, json.JSONDecodeError):
                  continue
              if decl is None:
                  continue
              prefix = f"{decl['repoPrefix']}_"
              for field in ("ggufFile", "mmprojFile"):
                  obj = data.get(field)
                  if isinstance(obj, dict) and isinstance(obj.get("rfilename"), str):
                      rname = obj["rfilename"].replace("/", "_")
                      fname = f"{prefix}{rname}"
                      gguf_to_declared[fname] = decl
                      gguf_to_manifests.setdefault(fname, []).append(mf)

          return gguf_to_declared, gguf_to_manifests


      def remove_path(
          path: Path, dry_run: bool, reason: str, removed: set[Path]
      ) -> int:
          if path in removed:
              return 0
          try:
              size = path.stat().st_size
          except OSError:
              return 0
          prefix = "[DRY-RUN] would remove" if dry_run else "Removing"
          print(f"{prefix} ({reason}): {path.name} ({fmt_bytes(size)})")
          removed.add(path)
          if not dry_run:
              try:
                  path.unlink()
              except OSError as exc:
                  print(f"WARNING: failed to remove {path}: {exc}", file=sys.stderr)
                  return 0
          return size


      def delete_gguf_bundle(
          gguf: Path,
          manifests: list[Path],
          dry_run: bool,
          reason: str,
          removed: set[Path],
      ) -> int:
          freed = remove_path(gguf, dry_run, reason, removed)
          etag = gguf.with_name(gguf.name + ".etag")
          if etag.exists():
              freed += remove_path(etag, dry_run, f"{reason}/etag", removed)
          for mf in manifests:
              if mf.exists():
                  freed += remove_path(mf, dry_run, f"{reason}/manifest", removed)
          return freed


      def main() -> int:
          parser = argparse.ArgumentParser(
              description="Prune stale, removed, or over-budget GGUF files from LLAMA_CACHE."
          )
          parser.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
          parser.add_argument("--manifest", default=DEFAULT_MANIFEST)
          parser.add_argument("--max-age-days", type=int, default=DEFAULT_MAX_AGE_DAYS)
          parser.add_argument("--max-size-gb", type=float, default=DEFAULT_MAX_SIZE_GB)
          parser.add_argument("--dry-run", action="store_true")
          parser.add_argument("--status", action="store_true")
          args = parser.parse_args()

          cache_dir = Path(args.cache_dir)
          if not cache_dir.exists():
              print(f"Cache directory {cache_dir} does not exist; nothing to do.")
              return 0

          declared = load_declared(Path(args.manifest))
          open_paths = open_files_under(cache_dir)
          gguf_to_declared, gguf_to_manifests = build_manifest_index(cache_dir, declared)

          now = time.time()
          max_age_sec = args.max_age_days * 86400
          max_size_bytes = int(args.max_size_gb * (1024**3))

          declared_manifest_names = {
              f"manifest={d['repoPrefix']}={d['tag']}.json".lower() for d in declared
          }

          items: list[dict] = []
          for path in sorted(cache_dir.glob("*.gguf")):
              try:
                  st = path.stat()
              except OSError:
                  continue
              decl = match_declared_for_gguf(path.name, declared, gguf_to_declared)
              last_used = max(st.st_atime, st.st_mtime)
              age_days = max(0.0, (now - last_used) / 86400.0)
              items.append(
                  {
                      "path": path,
                      "size": st.st_size,
                      "last_used": last_used,
                      "age_days": age_days,
                      "declared": decl,
                      "pin": bool(decl and decl.get("pin")),
                      "in_use": path.resolve() in open_paths,
                      "manifests": gguf_to_manifests.get(path.name, []),
                  }
              )

          total_bytes = sum(it["size"] for it in items)

          if args.status:
              print(f"Cache dir: {cache_dir}")
              print(
                  f"Total GGUF usage: {fmt_bytes(total_bytes)} / "
                  f"{args.max_size_gb:.1f} GiB (TTL: {args.max_age_days}d)"
              )
              if not items:
                  print("No cached GGUF models.")
                  return 0
              for it in sorted(items, key=lambda x: x["last_used"], reverse=True):
                  model_id = it["declared"]["id"] if it["declared"] else "ORPHAN"
                  flags = []
                  if it["pin"]:
                      flags.append("pinned")
                  if it["in_use"]:
                      flags.append("in-use")
                  flag_str = f" [{', '.join(flags)}]" if flags else ""
                  print(
                      f"  - {model_id:22s} {fmt_bytes(it['size']):>10s}  "
                      f"age={it['age_days']:5.1f}d  {it['path'].name}{flag_str}"
                  )
              return 0

          freed_total = 0
          removed: set[Path] = set()
          kept: list[dict] = []

          # Phase 1 & 2: Remove orphans (removed from data/models.nix) and stale unpinned models
          for it in items:
              if it["in_use"]:
                  kept.append(it)
                  continue
              if it["declared"] is None:
                  freed_total += delete_gguf_bundle(
                      it["path"], it["manifests"], args.dry_run, "orphan", removed
                  )
                  continue
              if not it["pin"] and (now - it["last_used"]) > max_age_sec:
                  freed_total += delete_gguf_bundle(
                      it["path"],
                      it["manifests"],
                      args.dry_run,
                      f"stale>{args.max_age_days}d",
                      removed,
                  )
                  continue
              kept.append(it)

          # Clean up any dangling manifest or .etag files
          remaining_ggufs = {it["path"].name for it in kept}
          for mf in sorted(cache_dir.glob("manifest=*.json")):
              if mf.name.lower() not in declared_manifest_names:
                  freed_total += remove_path(mf, args.dry_run, "orphan-manifest", removed)
          for etag in sorted(cache_dir.glob("*.gguf.etag")):
              gguf_name = etag.name[: -len(".etag")]
              if gguf_name not in remaining_ggufs:
                  freed_total += remove_path(etag, args.dry_run, "orphan-etag", removed)

          # Phase 3: Enforce size cap via LRU eviction of oldest unpinned, idle models
          remaining_bytes = sum(it["size"] for it in kept)
          evictable = sorted(
              [it for it in kept if not it["pin"] and not it["in_use"]],
              key=lambda x: x["last_used"],
          )
          for it in evictable:
              if remaining_bytes <= max_size_bytes:
                  break
              freed = delete_gguf_bundle(
                  it["path"],
                  it["manifests"],
                  args.dry_run,
                  f"size-cap>{args.max_size_gb:g}GiB",
                  removed,
              )
              freed_total += freed
              remaining_bytes -= it["size"]

          if remaining_bytes > max_size_bytes:
              print(
                  f"WARNING: remaining pinned/in-use models ({fmt_bytes(remaining_bytes)}) "
                  f"exceed budget ({args.max_size_gb:g} GiB).",
                  file=sys.stderr,
              )

          action = "Would free" if args.dry_run else "Freed"
          print(
              f"{action} {fmt_bytes(freed_total)}; "
              f"remaining GGUF cache: {fmt_bytes(max(0, remaining_bytes))} / {args.max_size_gb:g} GiB."
          )
          return 0


      if __name__ == "__main__":
          sys.exit(main())
    '';
in {
  options.llm = {
    enable = lib.mkEnableOption "Local LLM inference server (llama.cpp Router Mode)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.llama-cpp-vulkan;
      defaultText = lib.literalExpression "pkgs.llama-cpp-vulkan";
      description = "llama-cpp package to run (e.g., pkgs.llama-cpp-vulkan or pkgs.llama-cpp).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Listen address for llama-server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = ports.llm.internal;
      description = "Listen port for llama-server.";
    };

    threads = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Physical CPU core count for llama-server (avoid hyperthreads on dual-socket Xeon).";
    };

    numa = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["distribute" "isolate" "numactl"]);
      default = null;
      description = "NUMA strategy for multi-socket systems (e.g., 'distribute' on dual-socket Xeon).";
    };

    modelsMax = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Maximum models loaded concurrently in Router Mode before LRU eviction.";
    };

    sleepIdleSeconds = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Unload idle models from RAM/VRAM after this many seconds of inactivity.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/llama-cpp";
      description = "Persistent directory for LLAMA_CACHE (downloaded GGUF weights and manifests).";
    };

    gpuAccess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Grant the llama-cpp service access to GPU device nodes (Vulkan/DRM/NVIDIA).";
    };

    cacheGc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable periodic garbage collection of stale, removed, or over-budget GGUF cache files.";
      };

      maxAgeDays = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Evict unpinned models untouched (atime/mtime) for longer than this many days.";
      };

      maxSizeGB = lib.mkOption {
        type = lib.types.int;
        default = 45;
        description = "Soft size budget in GiB for LLAMA_CACHE; oldest-used unpinned models are evicted LRU above this.";
      };

      dates = lib.mkOption {
        type = lib.types.str;
        default = "Sun *-*-* 04:30:00";
        description = "Systemd OnCalendar schedule for llm-cache-gc.timer.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      cacheGcScript
    ];

    users.users.llama-cpp = {
      isSystemUser = true;
      group = "llama-cpp";
      extraGroups = lib.optionals cfg.gpuAccess [
        "video"
        "render"
      ];
      description = "llama.cpp Router Mode service user";
    };

    users.groups.llama-cpp = {};

    services.llama-cpp = {
      enable = true;
      package = cfg.package;
      openFirewall = false;
      settings = {
        host = cfg.host;
        port = cfg.port;
        models-max = cfg.modelsMax;
        sleep-idle-seconds = cfg.sleepIdleSeconds;
        models-preset = modelsPresetFile;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0750 llama-cpp llama-cpp -"
    ];

    systemd.services.llama-cpp = {
      unitConfig.RequiresMountsFor = [cfg.cacheDir];
      serviceConfig =
        {
          DynamicUser = lib.mkForce false;
          User = "llama-cpp";
          Group = "llama-cpp";
          SupplementaryGroups = lib.optionals cfg.gpuAccess [
            "video"
            "render"
          ];
          Environment = lib.mkForce [
            "LLAMA_CACHE=${cfg.cacheDir}"
          ];
          ReadWritePaths = [cfg.cacheDir];
          PrivateUsers = lib.mkForce (!cfg.gpuAccess);
          # Vulkan/NVIDIA shader compilation requires JIT executable mappings
          MemoryDenyWriteExecute = lib.mkForce (!cfg.gpuAccess);
        }
        // lib.optionalAttrs cfg.gpuAccess {
          DeviceAllow = [
            "/dev/dri rw"
            "char-drm rw"
            "/dev/nvidiactl rw"
            "/dev/nvidia-modeset rw"
            "/dev/nvidia-uvm rw"
            "/dev/nvidia-uvm-tools rw"
            "char-nvidia-frontend rw"
            "char-nvidia-uvm rw"
            "/dev/nvidia0 rw"
          ];
        };
    };

    systemd.services.llm-cache-gc = lib.mkIf cfg.cacheGc.enable {
      description = "Prune stale, removed, and over-budget models from LLAMA_CACHE";
      unitConfig.RequiresMountsFor = [cfg.cacheDir];
      serviceConfig = {
        Type = "oneshot";
        User = "llama-cpp";
        Group = "llama-cpp";
        ExecStart = "${cacheGcScript}/bin/llm-cache-gc";
        ReadWritePaths = [cfg.cacheDir];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.llm-cache-gc = lib.mkIf cfg.cacheGc.enable {
      description = "Periodic pruning of local LLM GGUF cache";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.cacheGc.dates;
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };
  };
}
