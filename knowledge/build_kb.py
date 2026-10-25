#!/usr/bin/env python3
"""Build the Neyam Vaani knowledge base from curated source JSON files.

Reads every ``*.json`` file in ``knowledge/sources/`` and produces:

* ``kb.json``   - ALWAYS written. The interchange format consumed by
                  ``build_embeddings.py`` / ``package_kb.py`` and (for the
                  bundled sample) by the Flutter app.
* ``kb.sqlite`` - written when the local Python's ``sqlite3`` module has
                  FTS5 support (true for the CPython builds on our CI and
                  on steward laptops). Contains one FTS5 virtual table
                  ``documents(id, title, lang, text, tags)`` using the
                  ``unicode61`` tokenizer, which handles Devanagari/Tamil
                  scripts for full-text search.

If FTS5 is unavailable, the script still succeeds with ``kb.json`` only and
prints a notice - the JSON path is the guaranteed fallback. Both artifacts
are documented in ``knowledge/README.md``.

Usage:
    python build_kb.py                        # all languages, ./sources -> ./build
    python build_kb.py --language ta --language hi
    python build_kb.py --sources-dir DIR --out-dir DIR

Standard library only. Python 3.8+.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

KB_JSON_FORMAT = "neyam-kb/1"
REQUIRED_FIELDS = ("id", "title", "lang", "text")


def load_documents(sources_dir: Path, languages: Optional[List[str]] = None) -> List[Dict[str, Any]]:
    """Load and validate every source document in *sources_dir*.

    Each source file must be either a JSON list of documents or an object
    with a ``documents`` list (metadata keys like ``source``/``license``
    are allowed alongside). Documents must carry ``id``, ``title``,
    ``lang``, ``text``; ``tags`` defaults to ``[]``.
    """
    if not sources_dir.is_dir():
        raise SystemExit(f"error: sources directory not found: {sources_dir}")

    documents: List[Dict[str, Any]] = []
    seen_ids = set()
    errors: List[str] = []

    for path in sorted(sources_dir.glob("*.json")):
        try:
            with path.open(encoding="utf-8") as handle:
                data = json.load(handle)
        except json.JSONDecodeError as exc:
            errors.append(f"{path.name}: invalid JSON ({exc})")
            continue

        raw_docs = data.get("documents") if isinstance(data, dict) else data
        if not isinstance(raw_docs, list):
            errors.append(f"{path.name}: expected a list or {{'documents': [...]}}")
            continue

        for index, doc in enumerate(raw_docs):
            label = f"{path.name}[{index}]"
            if not isinstance(doc, dict):
                errors.append(f"{label}: not an object")
                continue
            for field in REQUIRED_FIELDS:
                value = doc.get(field)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{label}: missing or empty field '{field}'")
            if errors and errors[-1].startswith(f"{label}: missing"):
                continue
            tags = doc.get("tags", [])
            if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
                errors.append(f"{label}: 'tags' must be a list of strings")
                continue
            doc_id = doc["id"]
            if doc_id in seen_ids:
                errors.append(f"{label}: duplicate id '{doc_id}'")
                continue
            seen_ids.add(doc_id)
            if languages and doc["lang"] not in languages:
                continue
            documents.append(
                {
                    "id": doc_id,
                    "title": doc["title"].strip(),
                    "lang": doc["lang"].strip(),
                    "text": doc["text"].strip(),
                    "tags": list(tags),
                }
            )

    if errors:
        for line in errors:
            print(f"  ! {line}", file=sys.stderr)
        raise SystemExit(f"error: {len(errors)} validation problem(s) in {sources_dir}")

    if not documents:
        print(f"notice: no documents found in {sources_dir} (nothing to build)")
    return documents


def write_json_kb(documents: List[Dict[str, Any]], out_dir: Path) -> Path:
    """Write the always-guaranteed ``kb.json`` interchange artifact."""
    payload = {
        "format": KB_JSON_FORMAT,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "document_count": len(documents),
        "documents": documents,
    }
    out_path = out_dir / "kb.json"
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out_path


def fts5_available() -> bool:
    """Probe whether this interpreter's sqlite3 supports FTS5 virtual tables."""
    try:
        connection = sqlite3.connect(":memory:")
    except sqlite3.Error:
        return False
    try:
        connection.execute(
            "CREATE VIRTUAL TABLE probe USING fts5(id UNINDEXED, text, tokenize='unicode61')"
        )
    except sqlite3.Error:
        return False
    finally:
        connection.close()
    return True


def write_sqlite_kb(documents: List[Dict[str, Any]], out_path: Path) -> None:
    """Write the FTS5 ``kb.sqlite`` query artifact (never raises)."""
    connection = sqlite3.connect(str(out_path))
    try:
        connection.execute(
            """
            CREATE VIRTUAL TABLE documents USING fts5(
                id UNINDEXED,
                title,
                lang UNINDEXED,
                text,
                tags UNINDEXED,
                tokenize='unicode61'
            )
            """
        )
        connection.executemany(
            "INSERT INTO documents(id, title, lang, text, tags) VALUES (?, ?, ?, ?, ?)",
            [
                (doc["id"], doc["title"], doc["lang"], doc["text"], " ".join(doc["tags"]))
                for doc in documents
            ],
        )
        connection.commit()
    finally:
        connection.close()


def build(sources_dir: Path, out_dir: Path, languages: Optional[List[str]]) -> int:
    documents = load_documents(sources_dir, languages)
    out_dir.mkdir(parents=True, exist_ok=True)

    json_path = write_json_kb(documents, out_dir)
    langs = sorted({doc["lang"] for doc in documents})
    print(f"kb.json   : {json_path} ({len(documents)} documents, langs: {', '.join(langs) or '-'})")

    if not documents:
        return 0

    sqlite_path = out_dir / "kb.sqlite"
    if fts5_available():
        if sqlite_path.exists():
            sqlite_path.unlink()
        # A stale -wal/-shm from a previous run would corrupt the new file.
        for suffix in ("-wal", "-shm"):
            stale = out_dir / f"kb.sqlite{suffix}"
            if stale.exists():
                stale.unlink()
        write_sqlite_kb(documents, sqlite_path)
        print(f"kb.sqlite : {sqlite_path} (FTS5, unicode61 tokenizer)")
    else:
        print(
            "kb.sqlite : skipped - this Python's sqlite3 has no FTS5 support. "
            "The JSON artifact above is the documented fallback and is fully "
            "supported by the pack pipeline and the app."
        )
    return 0


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sources-dir", type=Path, default=here / "sources",
                        help="directory of source JSON files (default: <script>/sources)")
    parser.add_argument("--out-dir", type=Path, default=here / "build",
                        help="output directory (default: <script>/build)")
    parser.add_argument("--language", action="append", default=None,
                        help="only include this language (repeatable, e.g. --language ta)")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    return build(args.sources_dir, args.out_dir, args.language)


if __name__ == "__main__":
    sys.exit(main())
