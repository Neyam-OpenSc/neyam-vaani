#!/usr/bin/env python3
"""Deterministic hashing-trick embeddings for the Neyam Vaani knowledge base.

ALGORITHM CONTRACT - "nv-hash-v1"
=================================

The exact same algorithm is implemented, bit for bit, in pure Dart at
``app/lib/data/services/knowledge/hybrid_search.dart`` so that embeddings
shipped in language packs match what the app computes on-device. If you
change *anything* in this file's tokenization or hashing, you MUST change
the Dart side (and the tests) in the same commit and bump the contract
name to ``nv-hash-v2``.

Steps, given an input string:

1. TOKENIZE (unicode-script aware, identical ranges in both languages):
   a. Split into code points. A code point is a *word character* iff it
      falls inside one of these inclusive ranges (and is not an exception):
        0x0030-0x0039  ASCII digits
        0x0041-0x005A  A-Z
        0x0061-0x007A  a-z
        0x00C0-0x02FF  Latin-1 letters, Latin Extended, IPA
        0x0370-0x1BFF  Greek, Cyrillic, Hebrew, Arabic and ALL Brahmic
                       scripts (Devanagari 0x0900, Bengali 0x0980, Tamil
                       0x0B80, Telugu 0x0C00, Kannada 0x0C80, Malayalam
                       0x0D00, ...)
        0x1C00-0x1CFF, 0x1D00-0x1DFF, 0x1E00-0x1FFF  extensions
      EXCEPTIONS (word-separators despite living inside those blocks):
        0x0964, 0x0965  Devanagari danda / double danda - they are sentence
                        punctuation in Hindi/Marathi and must not glue to
                        the preceding word.
      Everything else (spaces, ASCII punctuation, danda, currency signs
      such as 0x20B9, the 0x2000-0x206F general-punctuation block incl.
      zero-width spaces) splits tokens.
   b. While scanning, lowercase ONLY ASCII A-Z (add 0x20). Indic scripts
      have no case, so no locale-sensitive lowercasing is used - it must
      stay reproducible in every language.
   c. Tokens are the maximal runs of word characters. Runs may freely mix
      scripts ("Call112" is one token); digits are word characters.

2. EMBED (signed hashing trick, 384 dimensions):
   For each token occurrence, compute two FNV-1a 32-bit hashes over the
   token's code points (NOT bytes, NOT UTF-16 units):
        h1 = fnv1a(token, seed=0x811C9DC5)
        h2 = fnv1a(token, seed=0x1B873599)
        fnv1a: h = seed; for cp in code_points: h = ((h XOR cp) * 0x01000193) mod 2**32
   Then:
        index = h1 mod 384
        sign  = +1.0 if (h2 AND 1) == 1 else -1.0
        vec[index] += sign
   Finally L2-normalize the vector (a zero vector stays zero).

3. DOCUMENT INPUT: a document is embedded over ``title + " " + text``
   (tags are NOT part of the embedding; they are indexed for lexical
   search only). Queries are embedded over the raw query string.

Outputs (in --out-dir):
    embeddings.json - {"format": "neyam-embeddings/1", "algorithm": "nv-hash-v1",
                       "dim": 384, "vectors": [{"id", "lang", "vector"}]},
                      vectors rounded to 6 decimals.
    embeddings.bin  - binary twin: magic b"NVEM", version byte 0x01,
                      uint32-LE dim, uint32-LE count, then per document:
                      uint32-LE id-byte-length, id UTF-8 bytes, dim
                      float32-LE values.

Standard library only. Python 3.8+.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

DIM = 384
ALGORITHM = "nv-hash-v1"
EMBEDDINGS_JSON_FORMAT = "neyam-embeddings/1"
BIN_MAGIC = b"NVEM"
BIN_VERSION = 1

# Must stay identical to hybrid_search.dart (_kWordCharRanges / _kWordCharExceptions).
WORD_CHAR_RANGES: Tuple[Tuple[int, int], ...] = (
    (0x0030, 0x0039),
    (0x0041, 0x005A),
    (0x0061, 0x007A),
    (0x00C0, 0x02FF),
    (0x0370, 0x1BFF),
    (0x1C00, 0x1CFF),
    (0x1D00, 0x1DFF),
    (0x1E00, 0x1FFF),
)
WORD_CHAR_EXCEPTIONS = frozenset({0x0964, 0x0965})  # danda, double danda


def is_word_char(code_point: int) -> bool:
    """True iff *code_point* belongs to a token (see contract above)."""
    if code_point in WORD_CHAR_EXCEPTIONS:
        return False
    for start, end in WORD_CHAR_RANGES:
        if start <= code_point <= end:
            return True
    return False


def ascii_lower(code_point: int) -> int:
    """Lowercase ASCII letters only - locale-free by contract."""
    return code_point + 0x20 if 0x41 <= code_point <= 0x5A else code_point


def tokenize(text: str) -> List[str]:
    """Split *text* into tokens (contract step 1)."""
    tokens: List[str] = []
    current: List[int] = []
    for char in text:
        code_point = ord(char)
        if is_word_char(code_point):
            current.append(ascii_lower(code_point))
        elif current:
            tokens.append("".join(chr(cp) for cp in current))
            current = []
    if current:
        tokens.append("".join(chr(cp) for cp in current))
    return tokens


def fnv1a(token: str, seed: int) -> int:
    """FNV-1a 32-bit over the token's code points (contract step 2)."""
    hashed = seed
    for char in token:
        hashed = ((hashed ^ ord(char)) * 0x01000193) & 0xFFFFFFFF
    return hashed


def embed(text: str) -> List[float]:
    """Return the L2-normalized 384-dim nv-hash-v1 vector for *text*."""
    vector = [0.0] * DIM
    for token in tokenize(text):
        index = fnv1a(token, 0x811C9DC5) % DIM
        sign = 1.0 if (fnv1a(token, 0x1B873599) & 1) == 1 else -1.0
        vector[index] += sign
    norm = math.sqrt(sum(value * value for value in vector))
    if norm > 0.0:
        vector = [value / norm for value in vector]
    return vector


def document_input(title: str, text: str) -> str:
    """The string a document is embedded over (title + space + text)."""
    return f"{title} {text}"


def load_documents(kb_json: Path) -> List[Dict[str, str]]:
    """Read documents from a kb.json produced by build_kb.py."""
    data = json.loads(kb_json.read_text(encoding="utf-8"))
    documents = data["documents"] if isinstance(data, dict) else data
    if not isinstance(documents, list):
        raise SystemExit(f"error: {kb_json} does not contain a documents list")
    return documents


def build(vectors: Sequence[Tuple[str, str, List[float]]], out_dir: Path) -> Tuple[Path, Path]:
    """Write embeddings.json and embeddings.bin for *(id, lang, vector)* rows."""
    out_dir.mkdir(parents=True, exist_ok=True)

    json_path = out_dir / "embeddings.json"
    json_payload = {
        "format": EMBEDDINGS_JSON_FORMAT,
        "algorithm": ALGORITHM,
        "dim": DIM,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "vectors": [
            {"id": doc_id, "lang": lang, "vector": [round(v, 6) for v in vector]}
            for doc_id, lang, vector in vectors
        ],
    }
    json_path.write_text(
        json.dumps(json_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    bin_path = out_dir / "embeddings.bin"
    with bin_path.open("wb") as handle:
        handle.write(BIN_MAGIC)
        handle.write(struct.pack("<B", BIN_VERSION))
        handle.write(struct.pack("<I", DIM))
        handle.write(struct.pack("<I", len(vectors)))
        for doc_id, _lang, vector in vectors:
            id_bytes = doc_id.encode("utf-8")
            handle.write(struct.pack("<I", len(id_bytes)))
            handle.write(id_bytes)
            handle.write(struct.pack(f"<{DIM}f", *vector))
    return json_path, bin_path


def main(argv: Optional[List[str]] = None) -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--kb", type=Path, default=here / "build" / "kb.json",
                        help="kb.json from build_kb.py (default: <script>/build/kb.json)")
    parser.add_argument("--out-dir", type=Path, default=here / "build",
                        help="output directory (default: <script>/build)")
    args = parser.parse_args(argv)

    if not args.kb.is_file():
        raise SystemExit(
            f"error: {args.kb} not found - run build_kb.py first "
            f"(or pass --kb /path/to/kb.json)"
        )

    documents = load_documents(args.kb)
    vectors = [
        (doc["id"], doc["lang"], embed(document_input(doc["title"], doc["text"])))
        for doc in documents
    ]
    json_path, bin_path = build(vectors, args.out_dir)
    print(f"embeddings.json : {json_path} ({len(vectors)} vectors, dim={DIM}, {ALGORITHM})")
    print(f"embeddings.bin  : {bin_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
