"""
app.py
Streamlit chat UI refactored for clarity and functional structure.
"""
import os
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Tuple

import streamlit as st
from dotenv import load_dotenv

from chat_history_manager import ChatHistoryManager

# Load environment variables from .env file
load_dotenv()

# ----------------------------------------------------------------------------
# Configuration and constants
# ----------------------------------------------------------------------------
st.set_page_config(page_title="ChatGPT-like UI", page_icon="💬", layout="wide")

DEFAULT_MODEL = "gpt-4o-mini"
WELCOME_TITLE = "DAPE OpsAgent Manager"
WELCOME_SUBTITLE = "What can I do for you?"


# ----------------------------------------------------------------------------
# State and data helpers
# ----------------------------------------------------------------------------
# Initialize chat history manager based on environment configuration
CHAT_HISTORY_MODE = os.getenv("CHAT_HISTORY_MODE", "local")
CONVERSATION_HISTORY_DAYS = int(os.getenv("CONVERSATION_HISTORY_DAYS", "7"))

if CHAT_HISTORY_MODE in ["redis", "local_redis"]:
    # Build PostgreSQL connection string from environment variables
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    user = os.getenv("POSTGRES_ADMIN_LOGIN", "pgadmin")
    password = os.getenv("POSTGRES_ADMIN_PASSWORD", "")
    database = os.getenv("POSTGRES_DATABASE", "chat_history")
    sslmode = os.getenv("POSTGRES_SSLMODE", "require")
    connection_string = f"postgresql://{user}:{password}@{host}:{port}/{database}?sslmode={sslmode}"

    # Build Redis connection parameters
    redis_host = os.getenv("REDIS_HOST", "localhost")
    redis_password = os.getenv("REDIS_PASSWORD", "")
    redis_port = int(os.getenv("REDIS_PORT", "6380"))
    redis_ssl = os.getenv("REDIS_SSL", "true").lower() == "true"
    redis_ttl = int(os.getenv("REDIS_TTL_SECONDS", "1800"))

    HISTORY = ChatHistoryManager(
        mode="redis",
        connection_string=connection_string,
        redis_host=redis_host,
        redis_password=redis_password,
        redis_port=redis_port,
        redis_ssl=redis_ssl,
        redis_ttl=redis_ttl,
        history_days=CONVERSATION_HISTORY_DAYS
    )
elif CHAT_HISTORY_MODE == "postgres" or CHAT_HISTORY_MODE == "local_psql":
    # Build PostgreSQL connection string from environment variables
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", "5432")
    user = os.getenv("POSTGRES_ADMIN_LOGIN", "pgadmin")
    password = os.getenv("POSTGRES_ADMIN_PASSWORD", "")
    database = os.getenv("POSTGRES_DATABASE", "chat_history")
    sslmode = os.getenv("POSTGRES_SSLMODE", "require")
    connection_string = f"postgresql://{user}:{password}@{host}:{port}/{database}?sslmode={sslmode}"

    HISTORY = ChatHistoryManager(
        mode="postgres",
        connection_string=connection_string,
        history_days=CONVERSATION_HISTORY_DAYS
    )
else:
    HISTORY = ChatHistoryManager(mode="local")

def get_user_info() -> Dict[str, str]:
    """Extract user information from SSO headers or environment config.

    Supports five modes:
    1. local_psql: Use hardcoded test credentials from environment (PostgreSQL only)
    2. local_redis: Use hardcoded test credentials from environment (Redis + PostgreSQL)
    3. postgres: Use real SSO headers from Azure Easy Auth (PostgreSQL only)
    4. redis: Use real SSO headers from Azure Easy Auth (Redis + PostgreSQL)
    5. local: Fallback for local JSON mode
    """
    # Check if we're in local testing mode (PostgreSQL or Redis)
    if CHAT_HISTORY_MODE in ["local_psql", "local_redis"]:
        return {
            'user_id': os.getenv('LOCAL_TEST_CLIENT_ID', '00000000-0000-0000-0000-000000000001'),
            'user_name': os.getenv('LOCAL_TEST_USERNAME', 'local_user'),
            'is_authenticated': True,
            'mode': CHAT_HISTORY_MODE
        }

    # Try to extract from SSO headers (postgres or redis mode)
    if CHAT_HISTORY_MODE in ["postgres", "redis"]:
        try:
            headers = st.context.headers
            user_name = headers.get('X-MS-CLIENT-PRINCIPAL-NAME')
            user_id = headers.get('X-MS-CLIENT-PRINCIPAL-ID')

            if user_id and user_name:
                return {
                    'user_id': user_id,
                    'user_name': user_name,
                    'is_authenticated': True,
                    'mode': CHAT_HISTORY_MODE
                }
        except Exception:
            pass

    # Fallback for local mode or when SSO headers are unavailable
    return {
        'user_id': 'local_user',
        'user_name': 'Local User',
        'is_authenticated': False,
        'mode': 'local'
    }


def ensure_state() -> None:
    """Initialize required session_state keys and ensure a current chat exists."""
    # Initialize user information first (needed for PostgreSQL mode)
    if "user_info" not in st.session_state:
        st.session_state.user_info = get_user_info()

    if "conversations" not in st.session_state:
        st.session_state.conversations = {}
        # Load from persistent storage
        user_id = st.session_state.user_info.get('user_id')
        for cid, convo in HISTORY.list_conversations(user_id=user_id):
            st.session_state.conversations[cid] = convo

    if "current_id" not in st.session_state or st.session_state.current_id not in st.session_state.conversations:
        # Prefer reusing an existing clean chat (no messages) to avoid duplicates
        empty_chats = [
            (cid, convo)
            for cid, convo in st.session_state.conversations.items()
            if not convo.get("messages")
        ]
        if empty_chats:
            # Pick the newest empty chat by created_at
            empty_chats.sort(key=lambda kv: kv[1].get("created_at", ""), reverse=True)
            st.session_state.current_id = empty_chats[0][0]
        else:
            # No clean chat available; create a fresh one to show welcome page
            new_chat()

    if "show_menu" not in st.session_state:
        st.session_state.show_menu = None
    if "renaming_chat" not in st.session_state:
        st.session_state.renaming_chat = None
    if "selected_model" not in st.session_state:
        st.session_state.selected_model = DEFAULT_MODEL


def new_chat() -> None:
    """Create a new conversation, set it as current, and timestamp it."""
    cid = str(uuid.uuid4())[:8]
    st.session_state.conversations[cid] = {
        "title": "New chat",
        "model": st.session_state.get("selected_model", DEFAULT_MODEL),
        "messages": [],
        "created_at": datetime.now(timezone.utc).isoformat(),
        "last_modified": datetime.now(timezone.utc).isoformat(),
    }
    st.session_state.current_id = cid
    user_id = st.session_state.user_info.get('user_id')
    HISTORY.save_conversation(cid, st.session_state.conversations[cid], user_id=user_id)


def title_from_first_user_message(msg: str) -> str:
    """Derive a short, single-line chat title from the user's first message."""
    trimmed = (msg or "New chat").strip().replace("\n", " ")
    return (trimmed[:28] + "…") if len(trimmed) > 29 else (trimmed if trimmed else "New chat")


def models_list() -> List[str]:
    """Return available model identifiers for the dropdown."""
    return [
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-4.1",
        "gpt-3.5-turbo",
        "local-llm",
    ]


def call_llm_stub(model: str, messages: List[Dict]) -> str:
    """Placeholder LLM: echo the user's last message for the chosen model."""
    user_last = next((m["content"] for m in reversed(messages) if m["role"] == "user"), "Hello!")
    return f"(Stubbed {model}) You said: {user_last}"


def get_conversations_sorted() -> List[Tuple[str, Dict]]:
    """Return (id, conversation) tuples sorted by last_modified, fallback created_at (desc)."""
    items = [
        (cid, convo)
        for cid, convo in st.session_state.conversations.items()
    ]
    return sorted(
        items,
        key=lambda x: x[1].get("last_modified", x[1].get("created_at", "")),
        reverse=True,
    )


def sync_selected_model_to_current() -> None:
    """Copy the selected model into the active conversation record without updating last_modified."""
    convo = st.session_state.conversations[st.session_state.current_id]
    if convo.get("model") != st.session_state.selected_model:
        convo["model"] = st.session_state.selected_model
        user_id = st.session_state.user_info.get('user_id')
        HISTORY.save_conversation(st.session_state.current_id, convo, user_id=user_id)


# ----------------------------------------------------------------------------
# UI helpers
# ----------------------------------------------------------------------------
def inject_css() -> None:
    """Inject small CSS tweaks for layout, spacing, and subtle styling."""
    st.markdown(
        """
<style>
section[data-testid="stSidebar"] .block-container { padding-top: 1rem; }
.main .block-container { max-width: 900px; }
[data-testid="stChatMessage"] > div { border-radius: 12px !important; }
.sticky-header { position: sticky; top: 0; z-index: 999; padding: .5rem .8rem; margin: -1rem -1rem 0 -1rem; background: rgba(250,250,250,.85); backdrop-filter: blur(6px); border-bottom: 1px solid #eee; }
.chat-item { position: relative; padding: 0.5rem; border-radius: 8px; margin-bottom: 0.25rem; transition: background-color 0.2s; }
.chat-item:hover { background-color: rgba(0,0,0,0.05); }
.chat-item-content { display: flex; align-items: center; justify-content: space-between; }
.chat-menu-btn { opacity: 0; transition: opacity 0.2s; cursor: pointer; padding: 4px 8px; border-radius: 4px; font-size: 16px; }
.chat-item:hover .chat-menu-btn { opacity: 1; }
.chat-menu-btn:hover { background-color: rgba(0,0,0,0.1); }
.chat-row { position: relative; }
</style>
""",
        unsafe_allow_html=True,
    )


def render_model_picker() -> None:
    """Render the model selector and sync selection to session state."""
    st.markdown("### 🤖 Model")
    st.session_state.selected_model = st.selectbox(
        "Choose a model",
        models_list(),
        index=models_list().index(st.session_state.get("selected_model", DEFAULT_MODEL)) if st.session_state.get("selected_model") in models_list() else 0,
        label_visibility="collapsed",
    )


def render_chat_items() -> None:
    """Render chat list with select, rename, and delete controls."""
    current = st.session_state.current_id
    items = get_conversations_sorted()
    if not items:
        st.info("No chats yet. Start one!")
        return

    for cid, convo in items:
        title = convo["title"]
        if st.session_state.renaming_chat == cid:
            st.markdown("**Rename chat**")
            new_title = st.text_input(
                "New name",
                value=st.session_state.conversations[cid]["title"],
                key=f"rename_input_{cid}",
                label_visibility="collapsed",
            )
            col_save, col_cancel = st.columns([1, 1])
            with col_save:
                if st.button("💾 Save", key=f"save_{cid}", use_container_width=True):
                    if new_title.strip():
                        st.session_state.conversations[cid]["title"] = new_title.strip()
                        user_id = st.session_state.user_info.get('user_id')
                        HISTORY.save_conversation(cid, st.session_state.conversations[cid], user_id=user_id)
                    st.session_state.renaming_chat = None
                    st.rerun()
            with col_cancel:
                if st.button("✗ Cancel", key=f"cancel_{cid}", use_container_width=True):
                    st.session_state.renaming_chat = None
                    st.rerun()
            st.markdown("---")
            continue

        col1, col2 = st.columns([9, 1])
        with col1:
            is_selected = (cid == current)
            if st.button(
                title,
                key=f"chat_{cid}",
                use_container_width=True,
                type="primary" if is_selected else "secondary",
            ):
                # If using PostgreSQL/Redis and messages aren't loaded, fetch them now
                if CHAT_HISTORY_MODE in ["postgres", "local_psql", "redis", "local_redis"] and not convo.get("messages"):
                    user_id = st.session_state.user_info.get('user_id')
                    full_convo = HISTORY.get_conversation(cid, user_id=user_id)
                    if full_convo:
                        st.session_state.conversations[cid] = full_convo

                st.session_state.current_id = cid
                st.session_state.show_menu = None
                st.rerun()
        with col2:
            if st.button("⋮", key=f"menu_{cid}", help="Chat options"):
                st.session_state.show_menu = None if st.session_state.show_menu == cid else cid
                st.rerun()

        if st.session_state.show_menu == cid:
            col_left, col_menu, col_right = st.columns([1, 2, 1])
            with col_menu:
                if st.button("✏️ Rename", key=f"rename_btn_{cid}", use_container_width=True):
                    st.session_state.renaming_chat = cid
                    st.session_state.show_menu = None
                    st.rerun()
                if st.button("🗑️ Delete", key=f"delete_btn_{cid}", use_container_width=True):
                    was_current = (cid == st.session_state.current_id)
                    st.session_state.conversations.pop(cid, None)
                    user_id = st.session_state.user_info.get('user_id')
                    HISTORY.delete_conversation(cid, user_id=user_id)
                    st.session_state.show_menu = None
                    st.session_state.renaming_chat = None
                    if was_current:
                        # Always create a brand-new chat when the active one is deleted
                        new_chat()
                    # If not current, keep current_id unchanged
                    st.rerun()
            st.markdown("---")


def render_user_info() -> None:
    """Render user information at the bottom of the sidebar."""
    user_info = st.session_state.user_info
    mode = user_info.get('mode', 'local')

    st.markdown("---")

    if mode == 'local_psql':
        display_name = user_info['user_name'] or 'Unknown User'
        st.markdown(f"**🧪 Local PostgreSQL Mode**")
        st.markdown(f"*Test User: {display_name}*")
    elif mode == 'local_redis':
        display_name = user_info['user_name'] or 'Unknown User'
        st.markdown(f"**🧪 Local Redis Mode**")
        st.markdown(f"*Test User: {display_name}*")
    elif mode == 'postgres' and user_info['is_authenticated']:
        display_name = user_info['user_name'] or 'Unknown User'
        st.markdown(f"**👤 {display_name}**")
    elif mode == 'redis' and user_info['is_authenticated']:
        display_name = user_info['user_name'] or 'Unknown User'
        st.markdown(f"**👤 {display_name}**")
    else:
        st.markdown("**🏠 Local Mode**")



def render_sidebar() -> None:
    """Render sidebar: model picker, new chat button, chat list, and user info."""
    with st.sidebar:
        render_model_picker()
        if st.button("➕ New chat", use_container_width=True):
            new_chat()
            st.rerun()
        st.markdown("---")
        st.markdown("#### 💬 Chats")
        
        # Create scrollable container with fixed height for chat items
        with st.container(height=450):
            render_chat_items()
        
        # User info stays outside the scrollable container - always visible
        render_user_info()


def render_transcript(convo: Dict) -> None:
    """Render welcome screen or the chat transcript for the given conversation."""
    if not convo["messages"]:
        st.markdown(
            f"""
                <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 60vh;">
                    <h1 style="text-align: center; margin-bottom: 1rem;">{WELCOME_TITLE}</h1>
                    <p style="text-align: center; font-size: 1.2rem; color: #666;">{WELCOME_SUBTITLE}</p>
                </div>
            """,
            unsafe_allow_html=True,
        )
        return
    for m in convo["messages"]:
        with st.chat_message(m["role"]):
            st.markdown(m["content"])


def build_llm_messages(messages: List[Dict]) -> List[Dict]:
    """Convert internal message dicts to an OpenAI-style message list."""
    return [{"role": m["role"], "content": m["content"]} for m in messages]


def handle_chat_input(convo: Dict) -> None:
    """Handle user input, append messages, call the LLM stub, and rerun."""
    prompt = st.chat_input("Message…")
    if not prompt:
        return

    convo["messages"].append({"role": "user", "content": prompt, "time": datetime.now(timezone.utc).isoformat()})
    if convo["title"] == "New chat":
        convo["title"] = title_from_first_user_message(prompt)

    with st.chat_message("user"):
        st.markdown(prompt)

    reply = call_llm_stub(convo["model"], build_llm_messages(convo["messages"]))
    convo["messages"].append({"role": "assistant", "content": reply, "time": datetime.now(timezone.utc).isoformat()})
    convo["last_modified"] = datetime.now(timezone.utc).isoformat()
    with st.chat_message("assistant"):
        st.markdown(reply)
    # Persist conversation after message exchange
    user_id = st.session_state.user_info.get('user_id')
    HISTORY.save_conversation(st.session_state.current_id, convo, user_id=user_id)
    st.rerun()


# ----------------------------------------------------------------------------
# Main page orchestration
# ----------------------------------------------------------------------------
def main() -> None:
    """Coordinate the full page lifecycle: state, UI, transcript, and input."""
    ensure_state()
    inject_css()
    render_sidebar()
    sync_selected_model_to_current()
    current_convo = st.session_state.conversations[st.session_state.current_id]
    render_transcript(current_convo)
    handle_chat_input(current_convo)


main()