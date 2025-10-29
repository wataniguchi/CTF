import os
from pathlib import Path
from typing import Optional
from openai import OpenAI
from markdown_it import MarkdownIt
from rich.console import Console
from rich.markdown import Markdown
from rich.table import Table as RichTable
from rich.syntax import Syntax
import argparse

client = OpenAI(
    base_url="http://192.168.192.11:1234/v1",  # note the trailing /v1
    api_key="lmstudio"                    # dummy key – required by the SDK but ignored
)


def parse_blocks(md_text: str):
    """Return a list of dicts preserving original order."""
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
                    "info": t.info,          # language hint (e.g. json)
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
                            # next inline token holds cell text
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
            # skip the closing token
            while i < len(tokens) and tokens[i].type != "table_close":
                i += 1
            i += 1
            continue

        # Anything else – just move on ------------------------------------
        i += 1

    return blocks


def render_with_rich(md_text: str, structured_blocks=None):
    """
    Print the whole response using Rich's Markdown renderer.
    If ``structured_blocks`` is supplied we also show a second rendering that
    uses Rich.Table objects (demonstrates you can go both ways).
    """
    console = Console()
    console.print("[bold cyan]=== Full OpenAI/LM‑Studio reply (Markdown) ===[/]\n")
    # Rich will automatically turn pipe tables into pretty grids.
    console.print(Markdown(md_text, code_theme="monokai", inline_code_lexer="python"))

    if structured_blocks:
        console.print("\n[bold cyan]=== Re‑rendered using the parsed structures ===[/]")
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


def _read_file_contents(filepath: str, max_bytes: int = 200_000) -> str:
    """
    Read the file at ``filepath`` and return its text content.

    * Only regular files are allowed (no directories, symlinks that point
      outside the allowed root, etc.).
    * The size is capped to ``max_bytes`` – anything larger is truncated
      because LM Studio models have a limited context window.
    * UTF‑8 decoding is tried first; if it fails we fall back to latin‑1,
      which never raises a UnicodeDecodeError (it maps bytes 0‑255 directly).

    Raises:
        FileNotFoundError, PermissionError – for obvious OS problems.
        ValueError – when the file is too big or not a regular file.
    """
    p = Path(filepath).expanduser().resolve(strict=True)

    if not p.is_file():
        raise ValueError(f"'{filepath}' is not a regular file.")

    size = p.stat().st_size
    if size > max_bytes:
        # We will read only the first ``max_bytes`` bytes – enough for most
        # source‑code files while keeping us inside the model’s context.
        truncate = True
    else:
        truncate = False

    # Open in binary mode so we can control truncation before decoding.
    with p.open("rb") as f:
        raw = f.read(max_bytes) if truncate else f.read()

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        # Fallback – this will never raise an exception.
        return raw.decode("latin-1")


def inquire_lmstudio(filepath: str) -> Optional[str]:
    """
    Send the **contents** of ``filepath`` to the LM Studio server (via
    OpenAI‑compatible API) and return the model’s answer.

    Returns:
        The assistant message text on success, or ``None`` if something went
        wrong.  Errors are printed to stdout/stderr – you can replace the
        ``print`` calls with a proper logger in production.
    """
    try:
        file_content = _read_file_contents(filepath)
    except Exception as exc:               # includes FileNotFoundError, PermissionError …
        print(f"[-] Could not read '{filepath}': {exc}")
        return None

    system_prompt = ""                     # keep empty or customise as you like

    user_prompt = (
        f"Please analyse the following source code and list any security "
        f"vulnerabilities, unsafe patterns, or best‑practice violations it may contain.\n\n"
        f"--- BEGIN FILE CONTENT ({os.path.basename(filepath)}) ---\n"
        f"{file_content}\n"
        f"--- END FILE CONTENT ---"
    )

    """Sends the filepath to the LMstudio server (via OpenAI API) and returns the response."""
    try:
        completion = client.chat.completions.create(
            model="default",  # Or your preferred model in LM Studio
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            max_tokens=4096,  # Adjust as needed for response length
            temperature=0.8 # Adjust for creativity vs. accuracy
        )
        return completion.choices[0].message.content
    except Exception as e:
        print(f"Error inquiring LMstudio for {filepath}: {e}")
        return None


def should_process(file_path: str, allowed_exts: set[str]) -> bool:
    """
    Return True if the file's suffix (case‑insensitive) is in ``allowed_exts``.
    """
    _, ext = os.path.splitext(file_path)
    return ext.lower() in allowed_exts


def traverse_and_inquire(root_dir: str, allowed_exts: set[str]) -> None:
    """Walk ``root_dir`` recursively and query LM‑Studio only for whitelisted files."""
    for dirpath, _dirnames, filenames in os.walk(root_dir):
        for name in filenames:
            full_path = os.path.join(dirpath, name)

            if not should_process(full_path, allowed_exts):
                # Skip files we are not interested in – saves time and API calls.
                continue

            print(f"\n[+] Querying LM‑Studio for: {full_path}")
            response = inquire_lmstudio(full_path)
            if response:
                #print("LM‑Studio response:")
                render_with_rich(response)
                #blocks = parse_blocks(response)
                #render_with_rich(response, structured_blocks=blocks)
                print("-" * 60)


def parse_cli() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Selective file scanner – only .js/.ejs (or custom) files are sent to LM‑Studio."
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
    return parser.parse_args()


def main() -> None:
    args = parse_cli()

    # Normalise extensions – ensure they all start with a dot and are lower‑cased.
    allowed_exts = {ext if ext.startswith(".") else f".{ext}" for ext in args.ext}
    allowed_exts = {e.lower() for e in allowed_exts}

    print(f"Scanning '{args.directory}' for extensions: {', '.join(sorted(allowed_exts))}")
    traverse_and_inquire(args.directory, allowed_exts)


if __name__ == "__main__":
    main()
