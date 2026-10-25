#!/usr/bin/env python3
"""Bundle per-language knowledge packs for Neyam Vaani.

Consumes the artifacts of the sibling scripts (``build_kb.py`` /
``build_embeddings.py`` - imported from this directory, standard library
only) and writes, for each requested language ``L``:

    build/packs/L/kb-L.json          language-filtered KB (always)
    build/packs/L/kb-L.sqlite        FTS5 twin, when sqlite3 has FTS5
    build/packs/L/embeddings-L.json  nv-hash-v1 vectors for L (always)
    build/packs/L/embeddings-L.bin   binary twin (always)
    build/packs/L/manifest.json      file list with byte sizes + sha256

The manifest is what the app verifies after a pack download (the transport
signature itself is added later by ``scripts/release_language_pack.sh`` -
see docs/language-pack-spec.md). Documents whose ``lang`` matches the pack
language are included; embedding vectors are matched by document id, so a
pack can never ship a KB row without its embedding or vice versa.

Usage:
    python package_kb.py                          # every language in kb.json
    python package_kb.py --langs ta,hi
    python package_kb.py --kb build/kb.json --embeddings build/embeddings.json

Standard library only. Python 3.8+.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

from build_embeddings import ALGORITHM, DIM, build as write_embeddings
from build_kb import KB_JSON_FORMAT, fts5_available, write_sqlite_kb

PACK_FORMAT = "neyam-pack/1"
PACK_VERSION = "1.0.0"


def sha256_of(path: Path) -> str:
    """Hex sha256 of *path* (streamed - pack files can be large)."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> Dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"error: {path} is not a JSON object")
    return data


def pack_language(lang: str, documents: List[Dict], vectors_by_id: Dict[str, List[float]],
                  out_root: Path) -> Path:
    """Write one language pack directory. Returns the pack directory."""
    pack_dir = out_root / lang
    pack_dir.mkdir(parents=True, exist_ok=True)

    docs = [doc for doc in documents if doc["lang"] == lang]
    vectors = [
        (doc["id"], lang, vectors_by_id[doc["id"]])
        for doc in docs
        if doc["id"] in vectors_by_id
    ]
    missing = [doc["id"] for doc in docs if doc["id"] not in vectors_by_id]
    if missing:
        raise SystemExit(
            f"error: pack '{lang}' is inconsistent - documents without embeddings: "
            f"{', '.join(missing)} (re-run build_embeddings.py against this kb.json)"
        )

    kb_json_path = pack_dir / f"kb-{lang}.json"
    kb_json_path.write_text(
        json.dumps(
            {
                "format": KB_JSON_FORMAT,
                "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "document_count": len(docs),
                "documents": docs,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    sqlite_path: Optional[Path] = None
    if docs and fts5_available():
        sqlite_path = pack_dir / f"kb-{lang}.sqlite"
        write_sqlite_kb(docs, sqlite_path)

    emb_json_path, emb_bin_path = write_embeddings(vectors, pack_dir)
    # write_embeddings uses fixed file names; rename to the per-language pack names.
    pack_emb_json = pack_dir / f"embeddings-{lang}.json"
    pack_emb_bin = pack_dir / f"embeddings-{lang}.bin"
    emb_json_path.replace(pack_emb_json)
    emb_bin_path.replace(pack_emb_bin)

    files: Dict[str, Dict[str, object]] = {}
    for path in (kb_json_path, pack_emb_json, pack_emb_bin):
        files[path.name] = {"bytes": path.stat().st_size, "sha256": sha256_of(path)}
    if sqlite_path is not None:
        files[sqlite_path.name] = {
            "bytes": sqlite_path.stat().st_size,
            "sha256": sha256_of(sqlite_path),
        }

    manifest = {
        "format": PACK_FORMAT,
        "language": lang,
        "version": PACK_VERSION,
        "kb_format": KB_JSON_FORMAT,
        "embedding_algorithm": ALGORITHM,
        "embedding_dim": DIM,
        "document_count": len(docs),
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "files": files,
    }
    manifest_path = pack_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return pack_dir


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--kb", type=Path, default=here / "build" / "kb.json",
                        help="kb.json from build_kb.py (default: <script>/build/kb.json)")
    parser.add_argument("--embeddings", type=Path, default=here / "build" / "embeddings.json",
                        help="embeddings.json from build_embeddings.py")
    parser.add_argument("--out-dir", type=Path, default=here / "build" / "packs",
                        help="pack output root (default: <script>/build/packs)")
    parser.add_argument("--langs", default="all",
                        help="comma-separated language codes, or 'all' (default: all)")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    for required in (args.kb, args.embeddings):
        if not required.is_file():
            raise SystemExit(
                f"error: {required} not found - run build_kb.py and "
                f"build_embeddings.py first (see knowledge/README.md)"
            )

    kb = load_json(args.kb)
    documents = kb.get("documents", [])
    if not isinstance(documents, list) or not documents:
        raise SystemExit(f"error: {args.kb} contains no documents")

    embeddings = load_json(args.embeddings)
    if embeddings.get("algorithm") != ALGORITHM or embeddings.get("dim") != DIM:
        raise SystemExit(
            f"error: {args.embeddings} was not built with {ALGORITHM}/dim={DIM} - "
            f"re-run build_embeddings.py"
        )
    vectors_by_id = {row["id"]: row["vector"] for row in embeddings.get("vectors", [])}

    available = sorted({doc["lang"] for doc in documents})
    if args.langs == "all":
        langs = available
    else:
        langs = [code.strip() for code in args.langs.split(",") if code.strip()]
        unknown = [code for code in langs if code not in available]
        if unknown:
            raise SystemExit(
                f"error: no documents for language(s): {', '.join(unknown)} "
                f"(kb.json has: {', '.join(available)})"
            )

    for lang in langs:
        pack_dir = pack_language(lang, documents, vectors_by_id, args.out_dir)
        print(f"pack {lang}: {pack_dir} ({len([p for p in pack_dir.iterdir()])} files)")

    print(f"done: {len(langs)} pack(s) in {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
