import os
import logging
from sentence_transformers import SentenceTransformer
import faiss

DIR_INDEX = "./vecstore.out"
INDEX_FILE = "faiss_index.bin"
DIR_CHUNKED = "./chunked.out"

EMBED_MODEL_NAME = "google/embeddinggemma-300m"
LOCAL_MODEL_NAME = EMBED_MODEL_NAME.replace("/", "--")
MODELS_DIR = "./models.work"
MODEL_DIR = os.path.join(MODELS_DIR, LOCAL_MODEL_NAME)

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger(__name__)

    # List to hold all chunks
    chunks = []

    # Read all chunks from chunked files
    for filename in os.listdir(DIR_CHUNKED):
        if filename.endswith(".txt"):
            chunked_path = os.path.join(DIR_CHUNKED, filename)
            with open(chunked_path, "r", encoding="utf-8") as f:
                text = f.read()
                chunks.append(text)
    logger.info(f"Total chunks loaded: {len(chunks)}")

    # Load embedding model
    embed_model = SentenceTransformer(MODEL_DIR)
    logger.info(f"Embedding model loaded from {MODEL_DIR}")

    # Read FAISS index
    faiss_index_path = os.path.join(DIR_INDEX, INDEX_FILE)
    index = faiss.read_index(faiss_index_path)
    logger.info(f"FAISS index loaded from {faiss_index_path}")

    # Example: Encode a query and search in the index
    query = "What are requirements for good strqtegic communication?"
    query_embedding = embed_model.encode([query]).astype("float32")
    k = 30  # number of nearest neighbors
    distances, indices = index.search(query_embedding, k)
    logger.info(f"Top {k} nearest neighbors for the query '{query}':")
    for i, (idx, dist) in enumerate(zip(indices[0], distances[0])):
        logger.info(f"{i+1}: Chunk Index: {idx}, Distance: {dist}")
        logger.info(f"Content: {chunks[idx]}")