#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Unified source‑code analyser for LM Studio / OpenAI‑compatible servers.

All files that match the supplied extensions are read, concatenated and sent to the model
in a *single* (or few) request(s).  This gives the LLM visibility of the whole code base,
allowing it to spot cross‑file vulnerabilities such as insecure template inclusion,
improper module exports, etc.

Usage stays identical to the original script, with one extra optional argument:

    python analyse_all.py /path/to/project -e .js .ejs \
        -i "Also check for any usage of eval() and report possible XSS."

"""

import os
import time
from datetime import datetime
import argparse
from pathlib import Path
from typing import Optional, List, Set, Tuple

# ------------------------------------------------------------
# 3rd‑party imports (unchanged)
# ------------------------------------------------------------
from openai import OpenAI
from markdown_it import MarkdownIt
from rich.console import Console
from rich.markdown import Markdown
from rich.table import Table as RichTable
from rich.syntax import Syntax

# ------------------------------------------------------------
# Configuration – adjust to your environment / model limits
# ------------------------------------------------------------
client = OpenAI(
    base_url="http://192.168.192.11:1234/v1",  # LM Studio endpoint
    api_key="lmstudio"                         # dummy key required by SDK
)

SYSTEM_PROMPT = ""                     # you can add a high‑level instruction here

# Fixed user‑side prologue that is always sent to the model.
BASE_PROLOGUE = (
    "Please analyse the following source code and list any security "
    "vulnerabilities, unsafe patterns, or best‑practice violations it may contain."
)

# Approximate model context limit (tokens → bytes).  1 token ≈ 4 characters.
MAX_TOTAL_BYTES = 950_000               # leave room for the model’s response
MAX_FILE_BYTES = 200_000                # per‑file cap – same as original script
CHUNK_OVERLAP_BYTES = 2_000             # small overlap to keep context continuity

# ------------------------------------------------------------
# Helper: read a file safely, honouring size limits and encoding fallbacks
# ------------------------------------------------------------
def _read_file_contents(filepath: str, max_bytes: int = MAX_FILE_BYTES) -> str:
    """
    Return the (possibly truncated) text of *filepath*.

    - Only regular files are accepted.
    - Size is capped to ``max_bytes``; larger files are truncated.
    - UTF‑8 is tried first, then latin‑1 as a safe fallback.
    """
    p = Path(filepath).expanduser().resolve(strict=True)

    if not p.is_file():
        raise ValueError(f"'{filepath}' is not a regular file.")

    size = p.stat().st_size
    truncate = size > max_bytes

    with p.open("rb") as f:
        raw = f.read(max_bytes) if truncate else f.read()

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


# ------------------------------------------------------------
# Markdown rendering helpers (unchanged, only doc‑string tweaked)
# ------------------------------------------------------------
def parse_blocks(md_text: str):
    """Parse a markdown string into an ordered list of paragraph / code / table blocks."""
    md = MarkdownIt().enable("table")
    tokens = md.parse(md_text)

    blocks = []
    i = 0
    while i < len(tokens):
        t = tokens[i]

        # Paragraph -------------------------------------------------------
        if t.type == "paragraph_open":
            content = ""
            j = i + 1
            while j < len(tokens) and tokens[j].type != "paragraph_close":
                if tokens[j].type == "inline":
                    content += tokens[j].content
                j += 1
            blocks.append({"type": "paragraph", "text": content.strip()})
            i = j + 1
            continue

        # Fenced code ------------------------------------------------------
        if t.type == "fence":
            blocks.append(
                {
                    "type": "code",
                    "info": t.info,
                    "text": t.content,
                }
            )
            i += 1
            continue

        # Table ------------------------------------------------------------
        if t.type == "table_open":
            rows = []
            i += 1
            while i < len(tokens) and tokens[i].type != "table_close":
                if tokens[i].type == "tr_open":
                    cells = []
                    i += 1
                    while i < len(tokens) and tokens[i].type != "tr_close":
                        if tokens[i].type in ("th_open", "td_open"):
                            j = i + 1
                            txt = ""
                            while j < len(tokens) and tokens[j].type != "inline":
                                j += 1
                            if j < len(tokens):
                                txt = tokens[j].content.strip()
                            cells.append(txt)
                        i += 1
                    rows.append(cells)
                else:
                    i += 1
            blocks.append({"type": "table", "rows": rows})
            while i < len(tokens) and tokens[i].type != "table_close":
                i += 1
            i += 1
            continue

        # Anything else – just move on ------------------------------------
        i += 1

    return blocks


def render_with_rich(md_text: str, structured_blocks=None):
    """
    Pretty‑print the model’s markdown reply using Rich.
    If ``structured_blocks`` is supplied a second rendering based on parsed
    structures (tables, code fences) is shown as also.
    """
    console = Console()
    console.print("[bold cyan]=== LM‑Studio reply (Markdown) ===[/]\n")
    console.print(Markdown(md_text, code_theme="monokai", inline_code_lexer="python"))

    if structured_blocks:
        console.print("\n[bold cyan]=== Re‑rendered using parsed structures ===[/]")
        for blk in structured_blocks:
            if blk["type"] == "paragraph":
                console.print(blk["text"])
            elif blk["type"] == "code":
                syntax = Syntax(
                    blk["text"],
                    lexer=blk["info"] or "text",
                    theme="monokai",
                    line_numbers=False,
                )
                console.print(syntax)
            elif blk["type"] == "table":
                rows = blk["rows"]
                header, *data = rows
                rt = RichTable(show_header=True, header_style="bold magenta")
                for col in header:
                    rt.add_column(col)
                for row in data:
                    rt.add_row(*row)
                console.print(rt)


# ------------------------------------------------------------
# Core logic – gather files and build the (chunked) prompt(s)
# ------------------------------------------------------------
def should_process(file_path: str, allowed_exts: Set[str]) -> bool:
    """Return True if the file’s suffix (case‑insensitive) is in ``allowed_exts``."""
    _, ext = os.path.splitext(file_path)
    return ext.lower() in allowed_exts


def collect_file_entries(root_dir: str, allowed_exts: Set[str]) -> List[Tuple[str, str]]:
    """
    Walk ``root_dir`` and return a list of tuples ``(relative_path, file_content)`` for
    every file whose extension is whitelisted.

    The relative path is calculated with respect to *root_dir* – this keeps the prompt
    readable even when the script is run from an arbitrary working directory.
    """
    entries: List[Tuple[str, str]] = []
    root_path = Path(root_dir).expanduser().resolve(strict=True)

    for dirpath, _dirnames, filenames in os.walk(root_path):
        for name in filenames:
            full_path = os.path.join(dirpath, name)
            if not should_process(full_path, allowed_exts):
                continue

            try:
                print(f"[+] reading '{full_path}'")
                content = _read_file_contents(full_path)
            except Exception as exc:
                print(f"[-] Could not read '{full_path}': {exc}")
                continue

            rel_path = os.path.relpath(full_path, start=root_path)
            entries.append((rel_path, content))

    return entries


def build_prompt_chunks(
    file_entries: List[Tuple[str, str]],
    max_total_bytes: int = MAX_TOTAL_BYTES,
    overlap_bytes: int = CHUNK_OVERLAP_BYTES,
) -> List[str]:
    """
    Turn the list of ``(path, content)`` into one or more prompt strings that each
    respect ``max_total_bytes``.

    The algorithm is simple:

    * Keep appending files (with a small header/footer wrapper) until adding the next
      file would exceed the limit.
    * When the limit is reached, start a new chunk.  The first ``overlap_bytes`` of the
      previous chunk are copied to the front of the new one – this helps the model keep
      context across chunk boundaries.

    Returns a list of ready‑to‑send prompt strings **without** the fixed prologue.
    """
    chunks: List[str] = []
    current_parts: List[str] = []
    current_size = 0

    def flush_current():
        nonlocal current_parts, current_size
        if current_parts:
            chunks.append("\n".join(current_parts))
            # keep overlap for next chunk
            overlap_text = "\n".join(current_parts)[-overlap_bytes:]
            current_parts = [overlap_text] if overlap_text else []
            current_size = len(overlap_text.encode("utf-8"))
        else:
            current_parts = []
            current_size = 0

    for rel_path, content in file_entries:
        # Build a small wrapper that makes the prompt self‑documenting
        wrapped = (
            f"\n--- BEGIN FILE: {rel_path} ---\n"
            f"{content}\n"
            f"--- END FILE: {rel_path} ---\n"
        )
        wrapped_bytes = len(wrapped.encode("utf-8"))

        # If a single file alone exceeds the per‑chunk limit, we truncate it
        if wrapped_bytes > max_total_bytes:
            truncated = wrapped[:max_total_bytes]
            print(f"[!] File '{rel_path}' is larger than the chunk size – truncating.")
            wrapped = truncated
            wrapped_bytes = len(wrapped.encode("utf-8"))

        # Does adding this file overflow the current chunk?
        if current_size + wrapped_bytes > max_total_bytes:
            flush_current()

        current_parts.append(wrapped)
        current_size += wrapped_bytes

    # finalise last chunk
    flush_current()
    return chunks


def _assemble_full_prompt(
    chunk_body: str,
    extra_instruction: Optional[str] = None,
) -> str:
    """
    Insert the fixed prologue and (optionally) a user‑supplied instruction **before**
    the actual code chunk.

    The final string is what will be sent to the model.
    """
    parts = [BASE_PROLOGUE]

    if extra_instruction:
        print(f"[+] Extra instruction: '{extra_instruction}'")
        # Strip leading/trailing whitespace so we don't get accidental blank lines
        parts.append(extra_instruction.strip())

    # Separate the instruction block from the file list with a blank line for readability
    parts.append("")          # forces a newline between instruction and code
    parts.append(chunk_body)

    return "\n".join(parts)


def inquire_lmstudio(prompt: str) -> Optional[str]:
    """
    Send a *single* prompt (which may contain many files) to the LM‑Studio server.
    Returns the assistant’s reply text or ``None`` on error.
    """
    try:
        completion = client.chat.completions.create(
            model="default",                     # change if you have a named model
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user",   "content": prompt},
            ],
            max_tokens=131072,                     # adjust according to your model
            temperature=0.2,                    # low temp for more deterministic analysis
        )
        return completion.choices[0].message.content
    except Exception as e:
        print(f"[!] OpenAI request failed: {e}")
        return None


def process_project(
    root_dir: str,
    allowed_exts: Set[str],
    extra_instruction: Optional[str] = None,
) -> None:
    """
    Orchestrates the whole workflow:

    1. Collect all matching files.
    2. Split them into size‑limited chunks.
    3. Prepend the fixed prologue (and optional instruction) to each chunk.
    4. Send each chunk to the model and render the answer.
    """
    print(f"🔎 Scanning '{root_dir}' for extensions: {', '.join(sorted(allowed_exts))}")

    file_entries = collect_file_entries(root_dir, allowed_exts)
    if not file_entries:
        print("[-] No files matched – exiting.")
        return

    raw_chunks = build_prompt_chunks(file_entries)

    # Add the prologue / optional instruction **once per chunk**
    chunks = [_assemble_full_prompt(c, extra_instruction) for c in raw_chunks]

    total = len(chunks)
    for idx, chunk in enumerate(chunks, start=1):
        banner = f"\n[bold cyan]=== Chunk {idx}/{total} ({len(chunk.encode('utf-8'))//1024} KB) ===[/]\n"
        print(banner)

        response = inquire_lmstudio(chunk)
        if response:
            render_with_rich(response)
            # Uncomment the following two lines if you also want the parsed view
            # blocks = parse_blocks(response)
            # render_with_rich(response, structured_blocks=blocks)
        else:
            print("[-] No response received for this chunk.")
        print("-" * 80)


# ------------------------------------------------------------
# CLI handling (now includes optional instruction argument)
# ------------------------------------------------------------
def parse_cli() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyse a whole JavaScript/EJS code‑base with LM Studio in one go."
    )
    parser.add_argument(
        "directory",
        help="Root directory to walk recursively.",
    )
    parser.add_argument(
        "-e",
        "--ext",
        nargs="+",
        default=[".js", ".ejs"],
        metavar=".ext",
        help=(
            "File extensions to include (case‑insensitive). "
            "Provide them with the leading dot, e.g. -e .js .ts .html"
        ),
    )
    parser.add_argument(
        "-i",
        "--instruction",
        type=str,
        default=None,
        help=(
            "Additional instruction that will be placed after the fixed prologue "
            "and before the source files. Example: \"-i 'Also check for usage of eval().'\""
        ),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_cli()

    # Normalise extensions – ensure they all start with a dot and are lower‑cased.
    allowed_exts = {ext if ext.startswith(".") else f".{ext}" for ext in args.ext}
    allowed_exts = {e.lower() for e in allowed_exts}

    print(f"Scanning '{args.directory}' for extensions: {', '.join(sorted(allowed_exts))}")

    # ---- TIMING START -------------------------------------------------
    start_dt   = datetime.now()
    start_perf = time.perf_counter()

    print(f"\n🚀 Scan started at  {start_dt.strftime('%Y-%m-%d %H:%M:%S')}\n")

    process_project(args.directory, allowed_exts, extra_instruction=args.instruction)

    # ---- TIMING END ---------------------------------------------------
    end_dt   = datetime.now()
    end_perf = time.perf_counter()

    elapsed_seconds = end_perf - start_perf
    elapsed_hms     = time.strftime("%H:%M:%S", time.gmtime(elapsed_seconds))

    print(f"\n✅ Scan finished at {end_dt.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"⏱️  Total elapsed wall‑clock time: {elapsed_hms} ({elapsed_seconds:.2f}s)")


if __name__ == "__main__":
    main()
