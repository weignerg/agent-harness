"""Atomic Manifest and Rollback Engine for Multi-Runtime Agent Harness."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Union


def compute_sha256(filepath: Union[str, Path]) -> str:
    """Compute the SHA-256 hex digest of a file."""
    path = Path(filepath)
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()


class ManifestEntry:
    """Represents a single file entry in the installation manifest."""

    def __init__(self, path: str, sha256: str, timestamp: str):
        self.path = str(Path(path).resolve())
        self.sha256 = sha256
        self.timestamp = timestamp

    def to_dict(self) -> Dict[str, str]:
        return {
            "path": self.path,
            "sha256": self.sha256,
            "timestamp": self.timestamp,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, str]) -> ManifestEntry:
        return cls(
            path=data["path"],
            sha256=data["sha256"],
            timestamp=data["timestamp"],
        )


class InstallManifest:
    """In-memory representation of install_manifest.json."""

    def __init__(
        self,
        version: str = "1.0.0",
        target: str = "all",
        mode: str = "global",
        installed_at: Optional[str] = None,
        files: Optional[List[Dict[str, Any]]] = None,
        symlinks: Optional[List[Dict[str, str]]] = None,
        directories: Optional[List[str]] = None,
    ):
        self.version = version
        self.target = target
        self.mode = mode
        self.installed_at = (
            installed_at
            or datetime.datetime.now(datetime.timezone.utc).isoformat()
        )
        self.files: List[Dict[str, Any]] = files or []
        self.symlinks: List[Dict[str, str]] = symlinks or []
        self.directories: List[str] = directories or []

    def to_dict(self) -> Dict[str, Any]:
        return {
            "version": self.version,
            "target": self.target,
            "mode": self.mode,
            "installed_at": self.installed_at,
            "files": self.files,
            "symlinks": self.symlinks,
            "directories": self.directories,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> InstallManifest:
        return cls(
            version=data.get("version", "1.0.0"),
            target=data.get("target", "all"),
            mode=data.get("mode", "global"),
            installed_at=data.get("installed_at"),
            files=data.get("files", []),
            symlinks=data.get("symlinks", []),
            directories=data.get("directories", []),
        )

    def save(self, path: Union[str, Path]) -> None:
        """Atomically persist manifest to disk via temporary file."""
        target_path = Path(path).resolve()
        target_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = target_path.with_name(f"{target_path.name}.tmp.{os.getpid()}")
        try:
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(self.to_dict(), f, indent=2)
                f.write("\n")
            os.replace(tmp_path, target_path)
        finally:
            if tmp_path.exists():
                try:
                    tmp_path.unlink()
                except OSError:
                    pass

    @classmethod
    def load(cls, path: Union[str, Path]) -> InstallManifest:
        target_path = Path(path).resolve()
        if not target_path.is_file():
            raise FileNotFoundError(f"Manifest not found: {target_path}")
        with open(target_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return cls.from_dict(data)


class ManifestEngine:
    """Engine responsible for recording, verifying, and rolling back harness installations."""

    def __init__(self, manifest_path: Union[str, Path]):
        self.manifest_path = Path(manifest_path).resolve()
        if self.manifest_path.is_file():
            try:
                self.manifest = InstallManifest.load(self.manifest_path)
            except Exception:
                self.manifest = InstallManifest()
        else:
            self.manifest = InstallManifest()

        self._file_paths = {f["path"] for f in self.manifest.files}
        self._symlink_paths = {s["path"] for s in self.manifest.symlinks}
        self._dir_paths = set(self.manifest.directories)

    def record_file(self, file_path: Union[str, Path]) -> ManifestEntry:
        """Compute sha256 and record an installed file."""
        p = Path(file_path).resolve()
        if not p.is_file():
            raise FileNotFoundError(f"Cannot record non-existent file: {p}")
        sha = compute_sha256(p)
        ts = datetime.datetime.fromtimestamp(p.stat().st_mtime, datetime.timezone.utc).isoformat()
        entry = ManifestEntry(path=str(p), sha256=sha, timestamp=ts)
        resolved_str = str(p)
        if resolved_str in self._file_paths:
            self.manifest.files = [f for f in self.manifest.files if f["path"] != resolved_str]
        self.manifest.files.append(entry.to_dict())
        self._file_paths.add(resolved_str)
        return entry

    def record_symlink(self, link_path: Union[str, Path], target_path: Union[str, Path]) -> None:
        """Record a created symlink."""
        lp = Path(link_path).resolve()
        resolved_str = str(lp)
        tp_str = str(target_path)
        if resolved_str in self._symlink_paths:
            self.manifest.symlinks = [s for s in self.manifest.symlinks if s["path"] != resolved_str]
        self.manifest.symlinks.append({"path": resolved_str, "target": tp_str})
        self._symlink_paths.add(resolved_str)

    def record_directory(self, dir_path: Union[str, Path]) -> None:
        """Record an created directory."""
        dp = Path(dir_path).resolve()
        resolved_str = str(dp)
        if resolved_str not in self._dir_paths:
            self.manifest.directories.append(resolved_str)
            self._dir_paths.add(resolved_str)

    def record_tree(self, root_dir: Union[str, Path], exclude_manifest: bool = True) -> None:
        """Recursively scan and record all directories, symlinks, and files under root_dir."""
        root = Path(root_dir).resolve()
        if not root.exists():
            return
        if root.is_dir() and not root.is_symlink():
            self.record_directory(root)

        for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
            dirnames[:] = [d for d in dirnames if not d.endswith(".pre-harness.bak")]
            dp = Path(dirpath).resolve()
            self.record_directory(dp)
            for fn in filenames:
                if fn.endswith(".pre-harness.bak"):
                    continue
                fp = dp / fn
                if exclude_manifest and fp.resolve() == self.manifest_path.resolve():
                    continue
                if fp.is_symlink():
                    self.record_symlink(fp, os.readlink(fp))
                elif fp.is_file():
                    self.record_file(fp)
            for dn in dirnames:
                sub_p = dp / dn
                if sub_p.is_symlink():
                    self.record_symlink(sub_p, os.readlink(sub_p))

    def save(self, target: str = "all", mode: str = "global") -> Path:
        """Save the manifest to disk."""
        self.manifest.target = target
        self.manifest.mode = mode
        self.manifest.installed_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.manifest.save(self.manifest_path)
        return self.manifest_path

    def verify(self) -> Dict[str, Any]:
        """Verify recorded files against current filesystem state."""
        intact: List[str] = []
        tampered: List[str] = []
        missing: List[str] = []

        for f_entry in self.manifest.files:
            p = Path(f_entry["path"])
            if not p.is_file():
                missing.append(f_entry["path"])
                continue
            current_hash = compute_sha256(p)
            if current_hash == f_entry["sha256"]:
                intact.append(f_entry["path"])
            else:
                tampered.append(f_entry["path"])

        is_valid = (len(tampered) == 0 and len(missing) == 0 and len(self.manifest.files) > 0)
        return {
            "intact": intact,
            "tampered": tampered,
            "missing": missing,
            "total": len(self.manifest.files),
            "is_valid": is_valid,
        }

    def uninstall(self, dry_run: bool = False, force: bool = False) -> Dict[str, Any]:
        """Roll back installed files in reverse order."""
        removed_files: List[str] = []
        preserved_files: List[str] = []
        restored_files: List[str] = []
        already_missing: List[str] = []
        removed_symlinks: List[str] = []
        removed_directories: List[str] = []

        # 1. Process files in reverse
        for f_entry in reversed(self.manifest.files):
            p = Path(f_entry["path"])
            if not p.exists() and not p.is_symlink():
                already_missing.append(f_entry["path"])
                continue
            if not p.is_file():
                already_missing.append(f_entry["path"])
                continue

            bak_p = p.with_name(f"{p.name}.pre-harness.bak")
            if bak_p.is_file():
                if not dry_run:
                    try:
                        shutil.copy2(bak_p, p)
                        bak_p.unlink()
                    except OSError:
                        pass
                restored_files.append(f_entry["path"])
                continue

            current_hash = compute_sha256(p)
            if current_hash == f_entry["sha256"] or force:
                if not dry_run:
                    try:
                        p.unlink()
                    except OSError:
                        pass
                removed_files.append(f_entry["path"])
            else:
                preserved_files.append(f_entry["path"])

        # 2. Process symlinks in reverse
        for s_entry in reversed(self.manifest.symlinks):
            p = Path(s_entry["path"])
            if p.is_symlink() or p.exists():
                if not dry_run:
                    try:
                        p.unlink()
                    except OSError:
                        pass
                removed_symlinks.append(s_entry["path"])

        # 3. Process directories in reverse (only if empty)
        for d_path in reversed(self.manifest.directories):
            p = Path(d_path)
            if p.is_dir() and not p.is_symlink():
                if not dry_run:
                    try:
                        os.rmdir(p)
                        removed_directories.append(d_path)
                    except OSError:
                        pass
                else:
                    removed_directories.append(d_path)

        # 4. Remove manifest file if clean
        if not dry_run and len(preserved_files) == 0:
            if self.manifest_path.is_file():
                try:
                    self.manifest_path.unlink()
                except OSError:
                    pass
            try:
                os.rmdir(self.manifest_path.parent)
            except OSError:
                pass

        return {
            "removed_files": removed_files,
            "preserved_files": preserved_files,
            "restored_files": restored_files,
            "already_missing": already_missing,
            "removed_symlinks": removed_symlinks,
            "removed_directories": removed_directories,
            "dry_run": dry_run,
        }


def _run_cli() -> None:
    parser = argparse.ArgumentParser(description="Harness Installation Manifest Engine")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # verify
    verify_p = subparsers.add_parser("verify", help="Verify integrity of installed files")
    verify_p.add_argument("--manifest-path", required=True, help="Path to install_manifest.json")

    # uninstall
    uninstall_p = subparsers.add_parser("uninstall", help="Safely roll back installed files")
    uninstall_p.add_argument("--manifest-path", required=True, help="Path to install_manifest.json")
    uninstall_p.add_argument("--dry-run", action="store_true", help="Simulate rollback without deleting")
    uninstall_p.add_argument("--force", action="store_true", help="Force deletion even if modified")

    # record
    record_p = subparsers.add_parser("record", help="Record installed directories into manifest")
    record_p.add_argument("--manifest-path", required=True, help="Path to install_manifest.json")
    record_p.add_argument("--target", default="all", help="Target name")
    record_p.add_argument("--mode", default="global", help="Mode: global or local")
    record_p.add_argument("--roots", nargs="*", default=[], help="Root directories to scan and record")
    record_p.add_argument("--symlinks", nargs="*", default=[], help="Symlinks in format <link_path>:<target_path>")

    args = parser.parse_args()

    if args.subcommand == "verify":
        m_path = Path(args.manifest_path).resolve()
        if not m_path.is_file():
            sys.stderr.write(f"❌ Error: Install manifest not found: {m_path}\n")
            sys.exit(1)
        engine = ManifestEngine(m_path)
        res = engine.verify()
        print("=" * 80)
        print(f"🔍 VERIFYING HARNESS MANIFEST: {m_path}")
        print("=" * 80)
        print(f"  Total Files Recorded : {res['total']}")
        print(f"  ✅ Intact Files      : {len(res['intact'])}")
        print(f"  ❌ Tampered Files    : {len(res['tampered'])}")
        print(f"  ⚠️ Missing Files     : {len(res['missing'])}")
        if res["tampered"]:
            print("\n  ❌ Tampered Files Detected:")
            for t in res["tampered"]:
                print(f"    - {t}")
        if res["missing"]:
            print("\n  ⚠️ Missing Files Detected:")
            for m in res["missing"]:
                print(f"    - {m}")
        print("=" * 80)
        if res["is_valid"]:
            print("🎉 Verification SUCCESS: All installed files are intact and untampered.")
            sys.exit(0)
        else:
            print("❌ Verification FAILED: Detected integrity mismatches.")
            sys.exit(1)

    elif args.subcommand == "uninstall":
        m_path = Path(args.manifest_path).resolve()
        if not m_path.is_file():
            sys.stderr.write(f"⚠️ Notice: Manifest not found: {m_path}. Nothing to roll back.\n")
            sys.exit(0)
        engine = ManifestEngine(m_path)
        res = engine.uninstall(dry_run=args.dry_run, force=args.force)
        prefix = "[DRY-RUN] " if args.dry_run else ""
        print("=" * 80)
        print(f"🗑️ {prefix}ROLLING BACK HARNESS MANIFEST: {m_path}")
        print("=" * 80)
        print(f"  Files Removed        : {len(res['removed_files'])}")
        print(f"  Files Preserved      : {len(res['preserved_files'])}")
        print(f"  Files Restored       : {len(res['restored_files'])}")
        print(f"  Symlinks Removed     : {len(res['removed_symlinks'])}")
        print(f"  Directories Removed  : {len(res['removed_directories'])}")
        if res.get("restored_files"):
            print("\n  🔄 Restored pre-existing user configurations:")
            for r in res["restored_files"]:
                print(f"    - {r}")
        if res["preserved_files"]:
            print("\n  ⚠️ Preserved user-modified files:")
            for p in res["preserved_files"]:
                print(f"    - {p}")
        print("=" * 80)
        if args.dry_run:
            print("[DRY-RUN] Rollback simulation complete. Zero disk modifications made.")
        else:
            print("✅ Rollback complete.")
        sys.exit(0)

    elif args.subcommand == "record":
        m_path = Path(args.manifest_path).resolve()
        engine = ManifestEngine(m_path)
        for root in args.roots:
            engine.record_tree(root)
        for s in args.symlinks:
            if ":" in s:
                link_p, target_p = s.split(":", 1)
                engine.record_symlink(link_p, target_p)
        engine.save(target=args.target, mode=args.mode)
        print(f"  ✅ Manifest saved to {m_path} ({len(engine.manifest.files)} files recorded)")
        sys.exit(0)


if __name__ == "__main__":
    _run_cli()
