import os
import shutil
from docling.document_converter import DocumentConverter

DIR_READ = "./pdf.out"
DIR_WRITE = "./md.out"

if __name__ == "__main__":
    print("Starting PDF to Markdown conversion...")
    # Remove existing output directory if it exists
    if os.path.exists(DIR_WRITE):
        shutil.rmtree(DIR_WRITE)
    # Create output directory
    os.makedirs(DIR_WRITE, exist_ok=True)

    # Initialize DocumentConverter
    converter = DocumentConverter()

    # Process all PDF files in the input directory
    for filename in os.listdir(DIR_READ):
        if filename.endswith(".pdf"):
            input_path = os.path.join(DIR_READ, filename)
            output_path = os.path.join(DIR_WRITE, f"{os.path.splitext(filename)[0]}.md")
            print(f"Converting {input_path} to {output_path}")
            pdf = converter.convert(input_path)
            makedown = pdf.document.export_to_markdown()
            with open(output_path, "w", encoding="utf-8") as f:
                f.write(makedown)