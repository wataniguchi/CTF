import os
import shutil
import logging
from docling.document_converter import DocumentConverter
from docling.chunking import HybridChunker
from transformers import AutoTokenizer
from huggingface_hub import login
from huggingface_hub import snapshot_download
from sentence_transformers import SentenceTransformer
import faiss

DIR_READ = "./md.out"
DIR_INDEX = "./vecstore.out"
INDEX_FILE = "faiss_index.bin"
DIR_CHUNKED = "./chunked.out"

EMBED_MODEL_NAME = "google/embeddinggemma-300m"
LOCAL_MODEL_NAME = EMBED_MODEL_NAME.replace("/", "--")
MAX_TOKENS = 4096
MODELS_DIR = "./models.work"
MODEL_DIR = os.path.join(MODELS_DIR, LOCAL_MODEL_NAME)

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger(__name__)

    # Check if local model directory exists
    if not os.path.exists(MODELS_DIR):
        os.makedirs(MODELS_DIR, exist_ok=True)

    if not os.path.exists(MODEL_DIR):
        logger.info(f"Local model not found at path: {MODEL_DIR}")
        # Explicitly download the model
        login()
        snapshot_download(
            repo_id=EMBED_MODEL_NAME,
            local_dir=MODEL_DIR,
            resume_download=True,
        )
        logger.info(f"Model downloaded and saved to local path: {MODEL_DIR}")
    else:
        logger.info(f"Local model found at path: {MODEL_DIR}")

    tokenizer = AutoTokenizer.from_pretrained(MODEL_DIR)
    embed_model = SentenceTransformer(MODEL_DIR)

    # Remove existing output directory if it exists
    if os.path.exists(DIR_INDEX):
        shutil.rmtree(DIR_INDEX)
    # Create output directory
    os.makedirs(DIR_INDEX, exist_ok=True)
    # Remove existing output directory if it exists
    if os.path.exists(DIR_CHUNKED):
        shutil.rmtree(DIR_CHUNKED)
    # Create output directory
    os.makedirs(DIR_CHUNKED, exist_ok=True)

    logger.info("Starting to chunk markdown files...")
    # Initialize DocumentConverter
    converter = DocumentConverter()
    chunker = HybridChunker(
        tokenizer=tokenizer,
        max_tokens=MAX_TOKENS,
        chunk_overlap_ratio=0.1,
        chunking_strategy="hybrid",
        merge_peers=True,
    )

    # List to hold all chunks
    chunks = []
    index = 0

    # Process all markdown files in the input directory
    for filename in os.listdir(DIR_READ):
        if filename.endswith(".md"):
            input_path = os.path.join(DIR_READ, filename)
            #output_path = os.path.join(DIR_INDEX, f"{os.path.splitext(filename)[0]}.md")
            logger.info(f"Chunking {input_path}")
            doc = converter.convert(input_path).document
            chunk_iterator = chunker.chunk(dl_doc=doc)
            for i, chunk in enumerate(chunk_iterator):
                logger.info(f"--- INDEX {index} : {filename} chunk {i+1} ---")
                text = chunker.contextualize(chunk=chunk)
                logger.info(text)
                chunks.append(text)

                # Save each chunk as a separate file
                chunked_path = os.path.join(DIR_CHUNKED, f"{index}.txt")
                with open(chunked_path, "w", encoding="utf-8") as f:
                    f.write(text)
                index += 1

    logger.info(f"Total chunks created: {len(chunks)}")

    # Create embeddings
    logger.info("Creating embeddings...")
    embeddings = embed_model.encode(chunks, convert_to_numpy=True)
    logger.info(f"Embeddings created, shape: {embeddings.shape}")
    # Create FAISS index
    dimension = embeddings.shape[1]
    index = faiss.IndexFlatL2(dimension)
    index.add(embeddings.astype("float32"))
    faiss_index_path = os.path.join(DIR_INDEX, INDEX_FILE)
    faiss.write_index(index, faiss_index_path)
    logger.info(f"FAISS index created and saved to {faiss_index_path}")