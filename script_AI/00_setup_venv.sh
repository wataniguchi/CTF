#!/bin/sh
rm -rf venv_CTF
python -m venv venv_CTF
. venv_CTF/bin/activate # POSIX equivalent of source venv_CTF/bin/activate
python -m pip install --upgrade pip
pip install openai rich markdown-it-py
deactivate
