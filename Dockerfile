FROM python:3.12-slim

WORKDIR /app

# Install uv package manager
RUN pip install --no-cache-dir uv

# Copy dependency configuration
COPY pyproject.toml .

# Install dependencies using uv
RUN uv sync

# Copy application files
COPY app.py chat_history_manager.py ./
COPY .env .

# Expose port (documentation only - actual port set via WEBSITES_PORT)
EXPOSE 8000

# Start Streamlit application using uv run
CMD ["uv", "run", "streamlit", "run", "app.py", "--server.port=8000", "--server.address=0.0.0.0"]
