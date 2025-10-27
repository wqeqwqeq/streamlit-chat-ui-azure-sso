# Streamlit Chat UI (ChatGPT-like)

A minimal Streamlit chat interface with a top model selector, chat history, and a bottom input box. Includes basic styling to resemble ChatGPT.

## Features
- Top model selector (dropdown)
- Persistent chat history with avatars
- Streaming-style assistant responses
- Minimal CSS for centered, constrained layout

## Requirements
- Python 3.9+

## Setup
```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

## Run
```bash
streamlit run app.py
```
Then open the URL shown in the terminal (usually `http://localhost:8501`).

## Customize
- Edit the available models in `app.py` inside `render_top_bar()`.
- Replace `generate_response_stream()` with your real model call.
