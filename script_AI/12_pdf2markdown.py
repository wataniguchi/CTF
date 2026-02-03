import os
import shutil
import logging
import time
from docling_core.types.doc import ImageRefMode, PictureItem, TableItem
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions
from docling.document_converter import DocumentConverter, PdfFormatOption
from hierarchical.postprocessor import ResultPostprocessor

DIR_READ = "./pdf.out"
DIR_WRITE = "./md.out"

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger(__name__)
    logger.info("Starting PDF to Markdown conversion...")

    # Remove existing output directory if it exists
    if os.path.exists(DIR_WRITE):
        logger.info(f"Removing existing output directory: {DIR_WRITE}")
        shutil.rmtree(DIR_WRITE)
    # Create output directory
    os.makedirs(DIR_WRITE, exist_ok=True)

    # Set image resolution
    IMAGE_RESOLUTION_SCALE = 2.0  # Scale factor for image resolution

    # Configure pipeline options
    pipeline_options = PdfPipelineOptions()
    pipeline_options.images_scale = IMAGE_RESOLUTION_SCALE
    pipeline_options.generate_page_images = True
    pipeline_options.generate_picture_images = True
    pipeline_options.generate_table_images = False
    pdf_format_option = PdfFormatOption(pipeline_options=pipeline_options)

    # Initialize DocumentConverter
    converter = DocumentConverter(
        format_options={InputFormat.PDF: pdf_format_option}
    )

    # Process all PDF files in the input directory
    for filename in os.listdir(DIR_READ):
        if filename.endswith(".pdf"):
            input_path = os.path.join(DIR_READ, filename)
            output_path = os.path.join(DIR_WRITE, f"{os.path.splitext(filename)[0]}.md")
            logger.info(f"Converting {input_path} to {output_path}")
            start_time = time.time()

            pdf = converter.convert(input_path)
            # Save images
            picture_counter = 0
            for item, _level in pdf.document.iterate_items():
                if isinstance(item, PictureItem):
                    picture_counter += 1
                    image_path = os.path.join(DIR_WRITE,
                                              f"{os.path.splitext(filename)[0]}-picture-{picture_counter}.png")
                    with open(image_path, "wb") as fp:
                        item.get_image(pdf.document).save(fp, format="PNG")

            # The postprocessor modiefies the document in place
            ResultPostprocessor(pdf).process()
            markdown = pdf.document.export_to_markdown(
                image_mode=ImageRefMode.REFERENCED
            )
            with open(output_path, "w", encoding="utf-8") as f:
                f.write(markdown)
            
            elapsed_time = time.time() - start_time
            logger.info(f"Finished converting {filename} in {elapsed_time:.2f} seconds")