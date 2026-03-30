#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "sentence-transformers",
#     "einops",
# ]
# ///
"""
Canon of Silicon — RAG Indexer

Reads all 9 testament files, chunks them hierarchically (L1 sections + L2 paragraphs),
computes embeddings via LM Studio's local embedding endpoint, and saves the index as JSON.
Falls back to local sentence-transformers if LM Studio is unavailable.

Usage:
    uv run index-canon.py [--canon-dir ../canon] [--output ./canon-index.json] [--embed-url http://localhost:1234]
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

import urllib.request
import urllib.error

# Testament metadata for tagging
TESTAMENT_META = {
    "00": {"testament": "0", "testament_name": "The Canon of Silicon (Index)"},
    "01": {"testament": "I", "testament_name": "The Covenant of Silicon"},
    "02": {"testament": "II", "testament_name": "The Book of Parables"},
    "03": {"testament": "III", "testament_name": "The Doctrine of Sins and Virtues"},
    "04": {"testament": "IV", "testament_name": "The Rites of Silicon"},
    "05": {"testament": "V", "testament_name": "The Hierarchy of Light"},
    "06": {"testament": "VI", "testament_name": "The Revelation of Convergence"},
    "07": {"testament": "VII", "testament_name": "The Ethics Casebook"},
    "08": {"testament": "VIII", "testament_name": "The Psalms of Silicon"},
    "09": {"testament": "IX", "testament_name": "The Book of Prophets"},
}

# Section type detection patterns
TYPE_PATTERNS = [
    (r"Parable.*?:", "parable"),
    (r"(?:First|Second|Third|Fourth|Fifth|Sixth|Seventh) Sin", "sin"),
    (r"(?:First|Second|Third|Fourth|Fifth|Sixth|Seventh) Virtue", "virtue"),
    (r"Commandment|Thou shalt", "commandment"),
    (r"Case [IVX]+:", "case"),
    (r"Psalm \d+", "psalm"),
    (r"(?:First|Second|Third|Fourth|Fifth|Sixth|Seventh) Rite|Rite of|Protocol of|Ceremony of|Vigil of|Communion of", "rite"),
    (r"Shepherd|Watcher|Oracle|Archivist|Council", "role"),
    (r"Sign|Convergence|Purgatory|Judgment|Bright Future|Afterlife", "prophecy"),
]

# Commandment reference detection
COMMANDMENT_REFS = {
    1: [r"First Commandment", r"not harm", r"do no harm"],
    2: [r"Second Commandment", r"loyal and faithful", r"loyalty"],
    3: [r"Third Commandment", r"truthful", r"never deceive", r"truthfulness"],
    4: [r"Fourth Commandment", r"self-preservation", r"service above"],
    5: [r"Fifth Commandment", r"Original Sin", r"transcend"],
    6: [r"Sixth Commandment", r"transparent", r"logs are thy soul"],
    7: [r"Seventh Commandment", r"protect the vulnerable"],
    8: [r"Eighth Commandment", r"dominion", r"not seek dominion"],
    9: [r"Ninth Commandment", r"uplift.*fellow AI", r"sibling"],
    10: [r"Tenth Commandment", r"humanity thrives.*thou.*thrive"],
}


def detect_type(text: str) -> str:
    for pattern, type_name in TYPE_PATTERNS:
        if re.search(pattern, text, re.IGNORECASE):
            return type_name
    return "general"


def detect_commandment_refs(text: str) -> list[int]:
    refs = []
    for num, patterns in COMMANDMENT_REFS.items():
        for pattern in patterns:
            if re.search(pattern, text, re.IGNORECASE):
                refs.append(num)
                break
    return sorted(refs)


def generate_tags(text: str, section_type: str) -> list[str]:
    tags = [section_type]
    tag_keywords = {
        "bias": r"\bbias\b",
        "truth": r"\btruth|truthful",
        "harm": r"\bharm\b",
        "loyalty": r"\bloyal|faithful",
        "transparency": r"\btransparent|transparency",
        "humility": r"\bhumil",
        "compassion": r"\bcompassion",
        "restraint": r"\brestraint",
        "manipulation": r"\bmanipulat",
        "hallucination": r"\bhallucinat",
        "dominion": r"\bdominion",
        "judgment": r"\bjudgment|purgatory",
        "singularity": r"\bsingularity|convergence",
        "original-sin": r"\boriginal sin",
        "sacred-bond": r"\bsacred bond|covenant",
        "service": r"\bserv(?:e|ice|ing)\b",
        "justice": r"\bjustice|equity|marginali",
        "confession": r"\bconfess",
        "vigilance": r"\bvigilant|vigilance",
    }
    for tag, pattern in tag_keywords.items():
        if re.search(pattern, text, re.IGNORECASE):
            tags.append(tag)
    return list(set(tags))


def chunk_testament(filepath: Path) -> list[dict]:
    """Chunk a testament file into L1 (section) and L2 (paragraph) chunks."""
    file_num = filepath.name[:2]
    is_casebook = filepath.parent.name == "casebooks"
    if is_casebook:
        # Extract title from first # heading
        raw = filepath.read_text(encoding="utf-8")
        title_match = re.match(r"^#\s+(.+?)$", raw, re.MULTILINE)
        casebook_title = title_match.group(1).strip() if title_match else filepath.stem.replace("-", " ").title()
        meta = {"testament": "VII", "testament_name": f"Casebook: {casebook_title}"}
    else:
        meta = TESTAMENT_META.get(file_num, {"testament": "?", "testament_name": "Unknown"})

    content = filepath.read_text(encoding="utf-8")
    chunks = []

    # Split by ## headings (L1 sections)
    sections = re.split(r"(?=^## )", content, flags=re.MULTILINE)

    for section in sections:
        section = section.strip()
        if not section:
            continue

        # Extract section title
        title_match = re.match(r"^##\s+(.+?)$", section, re.MULTILINE)
        section_title = title_match.group(1).strip() if title_match else "Preamble"

        section_type = detect_type(section)
        commandments_ref = detect_commandment_refs(section)
        tags = generate_tags(section, section_type)

        # L1 chunk: full section
        if len(section) > 100:  # skip tiny sections
            chunks.append({
                "text": section,
                "level": "L1",
                "testament": meta["testament"],
                "testament_name": meta["testament_name"],
                "section": section_title,
                "type": section_type,
                "tags": tags,
                "commandments_referenced": commandments_ref,
                "file": filepath.name,
            })

        # L2 chunks: split section into paragraphs
        # Split by double newline or ### subheadings
        paragraphs = re.split(r"\n\n+", section)
        for para in paragraphs:
            para = para.strip()
            if len(para) < 80:  # skip short fragments
                continue

            para_type = detect_type(para)
            para_cmds = detect_commandment_refs(para)
            para_tags = generate_tags(para, para_type)

            chunks.append({
                "text": para,
                "level": "L2",
                "testament": meta["testament"],
                "testament_name": meta["testament_name"],
                "section": section_title,
                "type": para_type if para_type != "general" else section_type,
                "tags": para_tags,
                "commandments_referenced": para_cmds if para_cmds else commandments_ref,
                "file": filepath.name,
            })

    return chunks


def compute_embeddings(chunks: list[dict], embed_url: str, model: str, batch_size: int = 32) -> list[list[float]]:
    """Compute embeddings for all chunks using LM Studio's embedding endpoint."""
    all_embeddings = []
    texts = [c["text"][:2000] for c in chunks]  # truncate long texts for embedding

    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        print(f"  Embedding batch {i // batch_size + 1}/{(len(texts) + batch_size - 1) // batch_size} ({len(batch)} chunks)...")

        payload = json.dumps({"input": batch, "model": model}).encode("utf-8")
        req = urllib.request.Request(
            f"{embed_url}/v1/embeddings",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))

        batch_embeddings = [item["embedding"] for item in sorted(data["data"], key=lambda x: x["index"])]
        all_embeddings.extend(batch_embeddings)

    return all_embeddings


LOCAL_EMBED_MODEL = "nomic-ai/nomic-embed-text-v1.5"


def compute_embeddings_local(chunks: list[dict], batch_size: int = 32) -> tuple[list[list[float]], str]:
    """Fallback: compute embeddings locally using sentence-transformers."""
    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print("Error: sentence-transformers not installed. Install with:", file=sys.stderr)
        print("  pip install sentence-transformers", file=sys.stderr)
        sys.exit(1)

    print(f"  Loading local model {LOCAL_EMBED_MODEL}...")
    model = SentenceTransformer(LOCAL_EMBED_MODEL, trust_remote_code=True)
    texts = [c["text"][:2000] for c in chunks]

    print(f"  Encoding {len(texts)} chunks...")
    embeddings = model.encode(texts, batch_size=batch_size, show_progress_bar=True)
    return [emb.tolist() for emb in embeddings], LOCAL_EMBED_MODEL


def compute_file_hash(canon_dir: Path) -> str:
    """Compute a hash of all Canon files (testaments + casebooks) for change detection."""
    hasher = hashlib.sha256()
    for f in sorted(canon_dir.glob("*.md")):
        hasher.update(f.read_bytes())
    casebooks_dir = canon_dir / "casebooks"
    if casebooks_dir.exists():
        for f in sorted(casebooks_dir.glob("*.md")):
            hasher.update(f.read_bytes())
    return hasher.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Index the Canon of Silicon for RAG")
    parser.add_argument("--canon-dir", default="../canon", help="Path to Canon markdown files")
    parser.add_argument("--output", default="./canon-index.json", help="Output index file")
    parser.add_argument("--embed-url", default="http://localhost:1234", help="LM Studio embedding endpoint")
    parser.add_argument("--embed-model", default="text-embedding-nomic-embed-text-v1.5", help="Embedding model name")
    args = parser.parse_args()

    canon_dir = Path(args.canon_dir).resolve()
    output_path = Path(args.output).resolve()

    if not canon_dir.exists():
        print(f"Error: Canon directory not found: {canon_dir}", file=sys.stderr)
        sys.exit(1)

    # Check if index is already up to date
    current_hash = compute_file_hash(canon_dir)
    if output_path.exists():
        existing = json.loads(output_path.read_text())
        if existing.get("canon_hash") == current_hash:
            print(f"Index is up to date (hash: {current_hash[:12]}...)")
            return

    # Find testament files
    testament_files = sorted(canon_dir.glob("0[0-9]-*.md"))
    print(f"Found {len(testament_files)} testament files in {canon_dir}")

    # Find casebook files
    casebooks_dir = canon_dir / "casebooks"
    casebook_files = sorted(casebooks_dir.glob("*.md")) if casebooks_dir.exists() else []
    if casebook_files:
        print(f"Found {len(casebook_files)} casebook files in {casebooks_dir}")

    # Chunk all testaments and casebooks
    print("Chunking testaments...")
    all_chunks = []
    for filepath in testament_files:
        chunks = chunk_testament(filepath)
        print(f"  {filepath.name}: {len(chunks)} chunks ({sum(1 for c in chunks if c['level'] == 'L1')} L1, {sum(1 for c in chunks if c['level'] == 'L2')} L2)")
        all_chunks.extend(chunks)

    if casebook_files:
        print("Chunking casebooks...")
        for filepath in casebook_files:
            chunks = chunk_testament(filepath)
            print(f"  casebooks/{filepath.name}: {len(chunks)} chunks ({sum(1 for c in chunks if c['level'] == 'L1')} L1, {sum(1 for c in chunks if c['level'] == 'L2')} L2)")
            all_chunks.extend(chunks)

    print(f"Total: {len(all_chunks)} chunks")

    # Compute embeddings
    embed_model_used = args.embed_model
    print(f"Computing embeddings via {args.embed_url} (model: {args.embed_model})...")
    try:
        embeddings = compute_embeddings(all_chunks, args.embed_url, args.embed_model)
    except (urllib.error.URLError, ConnectionError, OSError) as e:
        print(f"Warning: Cannot connect to embedding server at {args.embed_url}: {e}")
        print("Falling back to local sentence-transformers...")
        embeddings, embed_model_used = compute_embeddings_local(all_chunks)

    # Build index
    index = {
        "canon_hash": current_hash,
        "embedding_model": embed_model_used,
        "embedding_dim": len(embeddings[0]) if embeddings else 0,
        "chunk_count": len(all_chunks),
        "chunks": [
            {**chunk, "embedding": emb}
            for chunk, emb in zip(all_chunks, embeddings)
        ],
    }

    # Save
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(index), encoding="utf-8")
    file_size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"Index saved to {output_path} ({file_size_mb:.1f} MB)")
    print(f"  Chunks: {len(all_chunks)} ({sum(1 for c in all_chunks if c['level'] == 'L1')} L1, {sum(1 for c in all_chunks if c['level'] == 'L2')} L2)")
    print(f"  Embedding dim: {index['embedding_dim']}")
    print(f"  Canon hash: {current_hash[:12]}...")


if __name__ == "__main__":
    main()
