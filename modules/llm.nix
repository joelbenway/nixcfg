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

  # Declarative metadata consumed by llm-cache-gc to identify declared vs orphan repos/tags
  declaredModelsJson = pkgs.writeText "llama-declared-models.json" (
    builtins.toJSON (
      lib.mapAttrsToList (id: m: let
        parts = lib.splitString ":" m.hfRepo;
        repo = builtins.elemAt parts 0;
        tag =
          if builtins.length parts > 1
          then builtins.elemAt parts 1
          else "";
      in {
        inherit id repo tag;
        folderName = "models--${lib.replaceStrings ["/"] ["--"] repo}";
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
      from contextlib import contextmanager
      import errno
      import fcntl
      import json
      import os
      from pathlib import Path
      import sys
      import time

      DEFAULT_CACHE_DIR = "${cfg.cacheDir}"
      DEFAULT_MANIFEST = "${declaredModelsJson}"
      DEFAULT_MAX_AGE_DAYS = ${toString cfg.cacheGc.maxAgeDays}
      DEFAULT_MAX_SIZE_GB = ${toString cfg.cacheGc.maxSizeGB}
      PARTIAL_SUFFIX = ".downloadInProgress"


      def fmt_bytes(num_bytes: int) -> str:
          size = float(num_bytes)
          for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
              if size < 1024.0 or unit == "TiB":
                  return f"{size:.2f} {unit}"
              size /= 1024.0
          return f"{num_bytes} B"


      def is_valid_oid(name: str) -> bool:
          return len(name) in (40, 64) and all(c in "0123456789abcdefABCDEF" for c in name)


      def path_in_root(target: str, root_str: str, root_prefix: str) -> bool:
          return target == root_str or target.startswith(root_prefix)


      def open_files_under(root: Path) -> set[Path]:
          """Return resolved paths under root open via fds or mmap'd by any process."""
          open_paths: set[Path] = set()
          root_resolved = root.resolve()
          root_str = str(root_resolved)
          root_prefix = root_str + os.sep
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
                      if path_in_root(target, root_str, root_prefix):
                          open_paths.add(Path(target))
              except OSError:
                  pass

              # llama.cpp may mmap model weights and close the fd after load;
              # scan /proc/<pid>/maps so mapped blobs are still treated as in use.
              maps_file = entry / "maps"
              try:
                  with maps_file.open("r", encoding="utf-8", errors="replace") as fh:
                      for line in fh:
                          parts = line.split(None, 5)
                          if len(parts) < 6:
                              continue
                          mapped = parts[5].strip()
                          if mapped.endswith(" (deleted)"):
                              mapped = mapped[: -len(" (deleted)")]
                          if path_in_root(mapped, root_str, root_prefix):
                              open_paths.add(Path(mapped))
              except OSError:
                  pass
          return open_paths


      def load_declared(manifest_path: Path) -> list[dict]:
          with manifest_path.open("r", encoding="utf-8") as fh:
              return json.load(fh)


      def folder_name_to_repo(folder_name: str) -> str | None:
          if not folder_name.startswith("models--"):
              return None
          rest = folder_name[len("models--"):]
          if "--" not in rest:
              return None
          return rest.replace("--", "/")


      def match_declared_for_snapshot(
          rel_path: str, repo_decls: list[dict]
      ) -> dict | None:
          if not repo_decls:
              return None
          lower_path = rel_path.lower()
          name = Path(rel_path).name.lower()

          # Non-GGUF metadata and mmproj sidecars belong to the declared repo as a whole;
          # prefer a pinned declaration if any exist so pinned models keep their sidecars.
          is_sidecar = (not name.endswith(".gguf")) or ("mmproj" in name)
          if is_sidecar:
              pinned = [d for d in repo_decls if d.get("pin")]
              return pinned[0] if pinned else repo_decls[0]

          # Match quant tag against GGUF filename (prefer longer/more specific tags first)
          tagged = sorted(
              repo_decls, key=lambda d: len(d.get("tag") or ""), reverse=True
          )
          for decl in tagged:
              tag = (decl.get("tag") or "").lower()
              if not tag or tag == "latest" or tag in lower_path:
                  return decl
          return None


      def is_within(child: Path, parent: Path) -> bool:
          try:
              child.relative_to(parent)
              return True
          except ValueError:
              return False


      @contextmanager
      def acquire_blob_lock(
          cache_dir: Path, repo_dir: Path, blob_path: Path, dry_run: bool
      ):
          """Acquire llama.cpp's shared flock (.locks/<repo>/<oid>.lock) non-blocking.

          Yields True if the lock is acquired (or not applicable / dry-run), False if busy/failed.
          Lock files are never deleted (matching llama.cpp common/file-lock.cpp).
          """
          if dry_run:
              yield True
              return

          blobs_root = (repo_dir / "blobs").resolve()
          if blob_path.parent != blobs_root or not is_valid_oid(blob_path.name):
              yield True
              return

          lock_dir = cache_dir / ".locks" / repo_dir.name
          lock_path = lock_dir / f"{blob_path.name}.lock"
          fd = -1
          locked = False
          try:
              lock_dir.mkdir(parents=True, exist_ok=True)
              flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
              if hasattr(os, "O_NOFOLLOW"):
                  flags |= os.O_NOFOLLOW
              fd = os.open(lock_path, flags, 0o664)
              try:
                  os.fchmod(fd, 0o664)
              except OSError:
                  pass
              fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
              locked = True
          except OSError as exc:
              if exc.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                  print(f"WARNING: cannot lock {lock_path}: {exc}", file=sys.stderr)
              if fd >= 0:
                  os.close(fd)
              yield False
              return

          try:
              yield True
          finally:
              if locked:
                  try:
                      fcntl.flock(fd, fcntl.LOCK_UN)
                  except OSError:
                      pass
              if fd >= 0:
                  os.close(fd)


      def has_live_snapshot_links(
          repo_dir: Path, blob_path: Path, removed: set[Path]
      ) -> bool:
          """Re-scan repo_dir/snapshots for any remaining symlink resolving to blob_path."""
          snapshots_root = repo_dir / "snapshots"
          if not snapshots_root.is_dir():
              return False
          repo_resolved = repo_dir.resolve()
          target_resolved = blob_path.resolve()
          for entry in snapshots_root.rglob("*"):
              if entry in removed or not entry.is_symlink():
                  continue
              try:
                  raw = os.readlink(entry)
                  resolved = (entry.parent / raw).resolve()
              except OSError:
                  continue
              if is_within(resolved, repo_resolved) and resolved == target_resolved:
                  return True
          return False


      def unlink_path(
          path: Path, dry_run: bool, reason: str, removed: set[Path]
      ) -> tuple[bool, int]:
          """Attempt to unlink path. Returns (removed_ok, bytes_freed)."""
          if path in removed:
              return True, 0
          try:
              st = path.lstat()
          except FileNotFoundError:
              removed.add(path)
              return True, 0
          except OSError as exc:
              print(f"WARNING: cannot stat {path}: {exc}", file=sys.stderr)
              return False, 0

          size = 0 if path.is_symlink() else st.st_size
          prefix = "[DRY-RUN] would remove" if dry_run else "Removing"
          print(f"{prefix} ({reason}): {path} ({fmt_bytes(size)})")
          if dry_run:
              removed.add(path)
              return True, size
          try:
              path.unlink()
              removed.add(path)
              return True, size
          except FileNotFoundError:
              removed.add(path)
              return True, 0
          except OSError as exc:
              print(f"WARNING: failed to remove {path}: {exc}", file=sys.stderr)
              return False, 0


      def scan_hf_cache(
          cache_dir: Path, declared: list[dict], open_paths: set[Path]
      ) -> tuple[list[dict], list[dict], list[dict]]:
          """Inventory llama.cpp v1.0.0 hf_cache (models--<owner>--<repo>/blobs & snapshots).

          Returns (blob_items, orphan_blobs, partial_files) with each backing blob counted once.
          """
          decls_by_repo: dict[str, list[dict]] = {}
          for d in declared:
              decls_by_repo.setdefault(d["repo"].lower(), []).append(d)

          blobs_by_path: dict[Path, dict] = {}
          orphan_blobs: list[dict] = []
          partial_files: list[dict] = []

          for repo_dir in sorted(cache_dir.glob("models--*")):
              if not repo_dir.is_dir():
                  continue
              repo_id = folder_name_to_repo(repo_dir.name)
              if repo_id is None:
                  continue
              repo_resolved = repo_dir.resolve()
              repo_decls = decls_by_repo.get(repo_id.lower(), [])
              snapshots_root = repo_dir / "snapshots"
              blobs_root = repo_dir / "blobs"

              referenced_blobs: set[Path] = set()

              if snapshots_root.is_dir():
                  for commit_dir in sorted(snapshots_root.iterdir()):
                      if not commit_dir.is_dir():
                          continue
                      for entry in sorted(commit_dir.rglob("*")):
                          if entry.is_dir() and not entry.is_symlink():
                              continue
                          if entry.name.endswith(PARTIAL_SUFFIX):
                              try:
                                  p_st = entry.stat()
                                  partial_files.append(
                                      {
                                          "path": entry.resolve(),
                                          "repo_id": repo_id,
                                          "size": p_st.st_size,
                                      }
                                  )
                              except OSError:
                                  pass
                              continue
                          rel_path = entry.relative_to(commit_dir).as_posix()
                          decl = match_declared_for_snapshot(rel_path, repo_decls)

                          # Read symlink metadata before readlink(); use only symlink mtime
                          # (not symlink atime, which readlink() refreshes under relatime).
                          try:
                              s_st = entry.lstat()
                              s_mtime = s_st.st_mtime
                          except OSError:
                              s_mtime = 0.0

                          if entry.is_symlink():
                              try:
                                  raw_target = os.readlink(entry)
                                  backing = (entry.parent / raw_target).resolve()
                              except OSError:
                                  backing = None
                              if backing is None or not is_within(backing, repo_resolved):
                                  backing = entry
                          else:
                              backing = entry.resolve()

                          referenced_blobs.add(backing)

                          try:
                              b_st = backing.stat()
                              b_size = b_st.st_size
                              b_last = max(b_st.st_atime, b_st.st_mtime)
                          except OSError:
                              b_size = 0
                              b_last = 0.0

                          rec = blobs_by_path.get(backing)
                          if rec is None:
                              rec = {
                                  "blob_path": backing,
                                  "repo_dir": repo_dir,
                                  "repo_id": repo_id,
                                  "size": b_size,
                                  "last_used": max(b_last, s_mtime),
                                  "refs": [],
                              }
                              blobs_by_path[backing] = rec
                          else:
                              rec["last_used"] = max(rec["last_used"], b_last, s_mtime)

                          rec["refs"].append(
                              {
                                  "snap_path": entry,
                                  "rel_path": rel_path,
                                  "declared": decl,
                                  "pin": bool(decl and decl.get("pin")),
                                  "is_symlink": entry.is_symlink(),
                              }
                          )

              # Discover unreferenced blobs and retained partial downloads under blobs/
              if blobs_root.is_dir():
                  for blob in sorted(blobs_root.iterdir()):
                      if not blob.is_file() or blob.is_symlink():
                          continue
                      resolved_blob = blob.resolve()
                      try:
                          st = resolved_blob.stat()
                      except OSError:
                          continue
                      if blob.name.endswith(PARTIAL_SUFFIX):
                          partial_files.append(
                              {
                                  "path": resolved_blob,
                                  "repo_id": repo_id,
                                  "size": st.st_size,
                              }
                          )
                          continue
                      if resolved_blob in referenced_blobs:
                          continue
                      orphan_blobs.append(
                          {
                              "blob_path": resolved_blob,
                              "repo_dir": repo_dir,
                              "repo_id": repo_id,
                              "size": st.st_size,
                              "last_used": max(st.st_atime, st.st_mtime),
                              "in_use": resolved_blob in open_paths,
                          }
                      )

          now = time.time()
          blob_items: list[dict] = []
          for rec in blobs_by_path.values():
              rec["pin"] = any(r["pin"] for r in rec["refs"])
              rec["declared_ids"] = sorted(
                  {r["declared"]["id"] for r in rec["refs"] if r["declared"] is not None}
              )
              rec["in_use"] = (rec["blob_path"] in open_paths) or any(
                  r["snap_path"].resolve() in open_paths
                  for r in rec["refs"]
                  if not r["is_symlink"]
              )
              rec["age_days"] = max(0.0, (now - rec["last_used"]) / 86400.0)
              blob_items.append(rec)

          return blob_items, orphan_blobs, partial_files


      def rmdir_if_empty(path: Path, dry_run: bool) -> None:
          if not path.is_dir() or path.is_symlink():
              return
          try:
              if any(path.iterdir()):
                  return
          except OSError:
              return
          if not dry_run:
              try:
                  path.rmdir()
              except OSError:
                  # Non-empty due to concurrent write or permission issue: leave in place
                  pass


      def prune_empty_repo_dirs(cache_dir: Path, dry_run: bool) -> None:
          """Remove empty directories bottom-up via atomic rmdir(); never touch .locks/."""
          for repo_dir in sorted(cache_dir.glob("models--*")):
              if not repo_dir.is_dir() or repo_dir.is_symlink():
                  continue
              for sub in sorted(
                  repo_dir.rglob("*"), key=lambda p: len(p.parts), reverse=True
              ):
                  rmdir_if_empty(sub, dry_run)
              rmdir_if_empty(repo_dir, dry_run)


      def is_blob_open(rec: dict, open_paths: set[Path]) -> bool:
          if rec["blob_path"] in open_paths:
              return True
          for ref in rec["refs"]:
              if ref["snap_path"] in open_paths:
                  return True
          return False


      def evict_blob_record(
          cache_dir: Path,
          rec: dict,
          dry_run: bool,
          reason: str,
          removed: set[Path],
      ) -> tuple[bool, int]:
          """Remove recorded snapshot links, then remove backing blob under shared flock
          only if no snapshot links remain. Returns (blob_removed_ok, bytes_freed).
          """
          freed = 0
          all_refs_removed = True
          for ref in rec["refs"]:
              snap = ref["snap_path"]
              if snap == rec["blob_path"]:
                  # Degraded mode (regular file directly in snapshots/): handled below
                  continue
              ok, b = unlink_path(snap, dry_run, f"{reason}/snapshot", removed)
              freed += b
              if not ok:
                  all_refs_removed = False

          if not all_refs_removed:
              return False, freed

          with acquire_blob_lock(
              cache_dir, rec["repo_dir"], rec["blob_path"], dry_run
          ) as locked:
              if not locked:
                  return False, freed
              if has_live_snapshot_links(rec["repo_dir"], rec["blob_path"], removed):
                  return False, freed
              blob_ok, blob_freed = unlink_path(rec["blob_path"], dry_run, reason, removed)
              freed += blob_freed
              return blob_ok, freed


      def main() -> int:
          parser = argparse.ArgumentParser(
              description="Prune stale, removed, or over-budget models from llama.cpp hf_cache."
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
          blob_items, orphan_blobs, partial_files = scan_hf_cache(
              cache_dir, declared, open_paths
          )

          now = time.time()
          max_age_sec = args.max_age_days * 86400
          max_size_bytes = int(args.max_size_gb * (1024**3))

          partial_bytes = sum(pf["size"] for pf in partial_files)
          total_bytes = sum(it["size"] for it in blob_items) + sum(ob["size"] for ob in orphan_blobs) + partial_bytes

          if args.status:
              print(f"Cache dir: {cache_dir}")
              partial_note = (
                  f" (incl. {fmt_bytes(partial_bytes)} resumable partials)"
                  if partial_bytes > 0
                  else ""
              )
              print(
                  f"Total cache usage: {fmt_bytes(total_bytes)} / "
                  f"{args.max_size_gb:.1f} GiB{partial_note} (TTL: {args.max_age_days}d)"
              )
              if not blob_items and not orphan_blobs and not partial_files:
                  print("No cached model blobs.")
                  return 0
              for it in sorted(blob_items, key=lambda x: x["last_used"], reverse=True):
                  model_label = ",".join(it["declared_ids"]) if it["declared_ids"] else "ORPHAN"
                  ref_names = ",".join(r["rel_path"] for r in it["refs"])
                  flags = []
                  if it["pin"]:
                      flags.append("pinned")
                  if it["in_use"]:
                      flags.append("in-use")
                  flag_str = f" [{', '.join(flags)}]" if flags else ""
                  print(
                      f"  - {model_label:22s} {fmt_bytes(it['size']):>10s}  "
                      f"age={it['age_days']:5.1f}d  {it['repo_id']}/{ref_names}{flag_str}"
                  )
              for ob in orphan_blobs:
                  flag_str = " [in-use]" if ob["in_use"] else ""
                  print(
                      f"  - {'UNREF-BLOB':22s} {fmt_bytes(ob['size']):>10s}  "
                      f"{ob['repo_id']}/blobs/{ob['blob_path'].name}{flag_str}"
                  )
              for pf in partial_files:
                  print(
                      f"  - {'PARTIAL':22s} {fmt_bytes(pf['size']):>10s}  "
                      f"{pf['repo_id']}/{pf['path'].name} [resumable]"
                  )
              return 0

          freed_total = 0
          removed: set[Path] = set()
          kept: list[dict] = []
          retained_orphan_bytes = 0

          # Phase 1a: Remove unreferenced blobs under models--*/blobs/
          # Re-check snapshot reachability under the shared blob lock before unlinking.
          for ob in orphan_blobs:
              if ob["in_use"]:
                  retained_orphan_bytes += ob["size"]
                  continue
              with acquire_blob_lock(
                  cache_dir, ob["repo_dir"], ob["blob_path"], args.dry_run
              ) as locked:
                  if not locked or has_live_snapshot_links(
                      ob["repo_dir"], ob["blob_path"], removed
                  ):
                      retained_orphan_bytes += ob["size"]
                      continue
                  ok, freed = unlink_path(
                      ob["blob_path"], args.dry_run, "unreferenced-blob", removed
                  )
                  freed_total += freed
                  if not ok:
                      retained_orphan_bytes += ob["size"]

          # Phase 1b & 2: Remove orphan snapshots/blobs and stale unpinned blobs
          for it in blob_items:
              if it["in_use"]:
                  kept.append(it)
                  continue

              # If a blob is referenced by BOTH declared and orphan snapshots, unlink only
              # the orphan snapshot symlinks and keep the backing blob intact.
              declared_refs = [r for r in it["refs"] if r["declared"] is not None]
              orphan_refs = [r for r in it["refs"] if r["declared"] is None]

              if declared_refs and orphan_refs:
                  remaining_refs = list(declared_refs)
                  for ref in orphan_refs:
                      if ref["snap_path"] != it["blob_path"]:
                          ok, freed = unlink_path(
                              ref["snap_path"], args.dry_run, "orphan-snapshot", removed
                          )
                          freed_total += freed
                          if not ok:
                              remaining_refs.append(ref)
                  it["refs"] = remaining_refs

              if not declared_refs:
                  blob_ok, freed = evict_blob_record(
                      cache_dir, it, args.dry_run, "orphan", removed
                  )
                  freed_total += freed
                  if not blob_ok:
                      kept.append(it)
                  continue

              if not it["pin"] and (now - it["last_used"]) > max_age_sec:
                  blob_ok, freed = evict_blob_record(
                      cache_dir, it, args.dry_run, f"stale>{args.max_age_days}d", removed
                  )
                  freed_total += freed
                  if not blob_ok:
                      kept.append(it)
                  continue

              kept.append(it)

          # Phase 3: Enforce size cap via LRU eviction of oldest unpinned, idle blobs.
          # Partial downloads count toward cache usage but are kept out of eviction candidates.
          remaining_bytes = (
              partial_bytes + retained_orphan_bytes + sum(it["size"] for it in kept)
          )
          evictable = sorted(
              [it for it in kept if not it["pin"] and not it["in_use"]],
              key=lambda x: x["last_used"],
          )
          # Refresh open/mmap'd file snapshot immediately before LRU eviction
          open_now = open_files_under(cache_dir)
          for it in evictable:
              if remaining_bytes <= max_size_bytes:
                  break
              if is_blob_open(it, open_now):
                  continue
              blob_ok, freed = evict_blob_record(
                  cache_dir, it, args.dry_run, f"size-cap>{args.max_size_gb:g}GiB", removed
              )
              freed_total += freed
              if blob_ok:
                  remaining_bytes -= it["size"]

          # Phase 4: Remove empty directories bottom-up via rmdir(); never touch .locks/
          prune_empty_repo_dirs(cache_dir, args.dry_run)

          if remaining_bytes > max_size_bytes:
              print(
                  f"WARNING: remaining pinned/in-use/partial/locked cache ({fmt_bytes(remaining_bytes)}) "
                  f"exceeds budget ({args.max_size_gb:g} GiB).",
                  file=sys.stderr,
              )

          action = "Would free" if args.dry_run else "Freed"
          print(
              f"{action} {fmt_bytes(freed_total)}; "
              f"remaining cache: {fmt_bytes(max(0, remaining_bytes))} / {args.max_size_gb:g} GiB."
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

    # Create cacheDir strictly after its backing mount (e.g., nofail /mnt/cache SSD)
    # is ready, avoiding systemd-tmpfiles-setup creating it on rootfs underneath the mount.
    systemd.services.llama-cpp-cache-init = {
      description = "Ensure persistent llama.cpp cache directory exists on mounted storage";
      unitConfig.RequiresMountsFor = [cfg.cacheDir];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/install -d -m 0750 -o llama-cpp -g llama-cpp ${lib.escapeShellArg cfg.cacheDir}";
      };
    };

    systemd.services.llama-cpp = {
      after = ["llama-cpp-cache-init.service"];
      requires = ["llama-cpp-cache-init.service"];
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
      after = ["llama-cpp-cache-init.service"];
      requires = ["llama-cpp-cache-init.service"];
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
