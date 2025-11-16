# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Streamlit-based chat UI (ChatGPT-like interface) called "DAPE OpsAgent Manager" that supports persistent chat history, multiple models, and Azure Easy Auth integration for SSO.

## Development Commands

### Running the Application

```bash
streamlit run app.py
```

The app runs on `http://localhost:8501` by default.

### Environment Setup

This project uses `pyproject.toml` for dependency management. The `requirements.txt` file is auto-generated during deployment.

Using uv (recommended):
```bash
uv sync
```

Or using pip:
```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
uv pip compile pyproject.toml -o requirements.txt
pip install -r requirements.txt
```

### Deployment to Azure

Deploy to Azure Web App (Linux with Python 3.12):

```bash
cd deployment
./deploy_script.sh <app-name> <resource-group>
# Default app-name: stanley-dev-ui-app
```

The deployment script automatically generates `requirements.txt` from `pyproject.toml` using `uv pip compile`, then creates a ZIP bundle with app.py, chat_history_manager.py, and requirements.txt.

### Infrastructure Deployment

Deploy Azure infrastructure using Bicep:

```bash
# Deploy resource group first
az deployment sub create --location <location> --template-file deployment/rg.bicep

# Deploy main infrastructure
az deployment group create --resource-group <rg-name> --template-file deployment/simplified.bicep
```

## Architecture

### Application Structure

The application follows a functional Streamlit architecture with clear separation of concerns:

- **app.py**: Main application entry point with UI orchestration
  - State management via `st.session_state`
  - Functional UI components (sidebar, chat transcript, input handling)
  - Model selection and chat management
  - SSO integration via Azure Easy Auth headers

- **chat_history_manager.py**: Persistence layer for chat conversations
  - Currently implements local JSON file storage (`.chat_history/` directory)
  - Each conversation stored as `{conversation_id}.json`
  - Designed for future SQL backend support (mode parameter)

### Key Concepts

#### Session State Management

The app maintains these key session state variables:
- `conversations`: Dict of all loaded conversations (in-memory cache)
- `current_id`: Active conversation ID
- `selected_model`: Currently selected model
- `user_info`: SSO user information from Azure Easy Auth headers
- `show_menu`: Chat menu visibility state
- `renaming_chat`: Chat being renamed

#### Chat History Persistence

- Conversations auto-save on every message exchange
- Atomic writes via temp file + rename pattern for safety
- Each conversation includes: title, model, messages list, created_at, last_modified timestamps
- Empty chats are reused to avoid clutter (welcome screen shows when no messages)

#### SSO Authentication

The app extracts user info from Azure Easy Auth headers:
- `X-MS-CLIENT-PRINCIPAL-NAME`: User's email/display name
- `X-MS-CLIENT-PRINCIPAL-ID`: Unique user identifier

In local mode (no SSO headers), displays "Local Mode" instead of username.

#### Model Integration

Currently uses a stub LLM (`call_llm_stub` in app.py:116) that echoes user input. This should be replaced with actual model API calls (e.g., Azure OpenAI, OpenAI API, local LLM endpoint).

Available models configured in `models_list()` (app.py:105):
- gpt-4o-mini (default)
- gpt-4o
- gpt-4.1
- gpt-3.5-turbo
- local-llm

### Azure Infrastructure

The Bicep template (`deployment/simplified.bicep`) provisions:
- App Service Plan (Linux, configurable SKU, default B1)
- App Service (Python 3.12 runtime)
- User-assigned Managed Identity
- Application Insights + Log Analytics Workspace
- Key Vault
- Azure AD authentication (Easy Auth) - disabled in sandbox/test environments (when resource prefix contains 'sbx')

Authentication is controlled by the `isSbx` variable which checks if the resource prefix contains 'sbx'.

## Important Implementation Notes

### Modifying the LLM Backend

Replace `call_llm_stub()` in app.py with actual API calls. The function receives:
- `model`: Selected model name
- `messages`: List of message dicts with "role" and "content" fields (OpenAI-compatible format)

Return the assistant's response as a string.

### Adding New Models

Edit `models_list()` in app.py:105 to add/remove model options in the dropdown.

### Chat History Storage Mode

`ChatHistoryManager` is initialized with `mode="local"`. To implement SQL storage:
1. Extend `ChatHistoryManager.__init__()` to handle `mode="sql"`
2. Implement SQL versions of `list_conversations()`, `get_conversation()`, `save_conversation()`, `delete_conversation()`

### Deployment Configuration

The deploy script sets these critical Azure Web App settings:
- `SCM_DO_BUILD_DURING_DEPLOYMENT=true`: Enables build during deployment
- Startup command: `python -m streamlit run app.py --server.port 8000 --server.address 0.0.0.0`
- Note: Port 8000 is used instead of Streamlit's default 8501 to match Azure Web App expectations

### Bicep Parameters

Key parameters in `simplified.bicep`:
- `resourcePrefix`: Prefix for all resource names (default: 'stanley-dev-ui')
- `skuName`: App Service Plan SKU (default: 'b1')
- `tokenProviderAppId`: Azure AD App Registration client ID for Easy Auth
- `location`: Defaults to resource group location
