#!/bin/sh
rm -rf venv_CTF
python3 -m venv venv_CTF
. venv_CTF/bin/activate # POSIX equivalent of source venv_CTF/bin/activate
python3 -m pip install --upgrade pip
pip install openai rich markdown-it-py
pip install docling docling-hierarchical-pdf fugashi ipadic
pip install faiss-cpu sentence-transformers
deactivate
