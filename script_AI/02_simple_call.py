#!/usr/bin/env python3

import time
from datetime import datetime
import argparse
from typing import Optional

# ------------------------------------------------------------
# 3rd-party imports
# ------------------------------------------------------------
from openai import OpenAI
from rich.console import Console
from rich.markdown import Markdown
from rich.table import Table as RichTable
from rich.syntax import Syntax

# ------------------------------------------------------------
# Configuration – adjust to your environment / model limits
# ------------------------------------------------------------
client = OpenAI(
    base_url="http://192.168.192.11:1234/v1",  # note the trailing /v1
    api_key="lmstudio"                    # dummy key – required by the SDK but ignored
)

SYSTEM_PROMPT = ""                     # you can add a high-level instruction here

# Fixed user-side prologue that is always sent to the model.
BASE_PROLOGUE = (
    "Please analyse the following instructions and try to answer in the structured "
    "way as a technology expertise."
)


def render_with_rich(md_text: str, structured_blocks=None):
    """
    Pretty-print the model's markdown reply using Rich.
    If ``structured_blocks`` is supplied a second rendering based on parsed
    structures (tables, code fences) is shown as also.
    """
    console = Console()
    console.print("[bold cyan]=== LM-Studio reply (Markdown) ===[/]\n")
    console.print(Markdown(md_text, code_theme="monokai", inline_code_lexer="python"))

    if structured_blocks:
        console.print("\n[bold cyan]=== Re-rendered using parsed structures ===[/]")
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


def inquire_lmstudio(prompt: str) -> Optional[str]:
    """
    Send a single prompt to the LM-Studio server.
    Returns the assistant's reply text or ``None`` on error.
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


# ------------------------------------------------------------
# CLI handling (now includes optional instruction argument)
# ------------------------------------------------------------
def parse_cli() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a simply inquiry to LM Studio."
    )
    parser.add_argument(
        "-i",
        "--instruction",
        type=str,
        default=None,
        help=(
            "Additional instruction that will be placed after the fixed prologue. "
            "Example: \"-i 'Also check for usage of eval().'\""
        ),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_cli()

    # ---- TIMING START -------------------------------------------------
    start_dt   = datetime.now()
    start_perf = time.perf_counter()

    print(f"\n[+] Inquiry started at  {start_dt.strftime('%Y-%m-%d %H:%M:%S')}\n")

    parts = [BASE_PROLOGUE]

    if args.instruction:
        print(f"[+] Extra instruction: '{args.instruction}'")
        # Strip leading/trailing whitespace so we don't get accidental blank lines
        parts.append(args.instruction.strip())

    prompt = "\n".join(parts)
        
    response = inquire_lmstudio(prompt=prompt)
    if response:
        render_with_rich(response)
        # Uncomment the following two lines if you also want the parsed view
        # blocks = parse_blocks(response)
        # render_with_rich(response, structured_blocks=blocks)
    else:
        print("[-] No response received for this chunk.")
    print("-" * 80)

    # ---- TIMING END ---------------------------------------------------
    end_dt   = datetime.now()
    end_perf = time.perf_counter()

    elapsed_seconds = end_perf - start_perf
    elapsed_hms     = time.strftime("%H:%M:%S", time.gmtime(elapsed_seconds))

    print(f"\n[+] Inquiry finished at {end_dt.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"[+] Total elapsed wall-clock time: {elapsed_hms} ({elapsed_seconds:.2f}s)")


if __name__ == "__main__":
    main()
