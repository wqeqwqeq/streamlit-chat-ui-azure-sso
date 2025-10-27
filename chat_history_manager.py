"""
chat_history_manager.py
Local JSON-based chat history manager. SQL mode is reserved for future use.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


class ChatHistoryManager:
    """Persist and retrieve chat histories.

    Modes:
      - "local": Store each conversation as a JSON file under .chat_history/
      - "sql": Reserved for future implementation
    """

    def __init__(self, mode: str = "local", base_dir: Optional[Path | str] = None) -> None:
        self.mode = mode
        self.base_dir = Path(base_dir) if base_dir is not None else Path(__file__).resolve().parent
        if self.mode == "local":
            self.store_dir = self.base_dir / ".chat_history"
            self._ensure_dir(self.store_dir)
        elif self.mode == "sql":
            raise NotImplementedError("sql mode not implemented yet")
        else:
            raise ValueError(f"Unsupported mode: {self.mode}")

    # ------------------------------
    # Public API
    # ------------------------------
    def list_conversations(self) -> List[Tuple[str, Dict]]:
        """Return list of (conversation_id, conversation) from storage."""
        if self.mode != "local":
            raise NotImplementedError("Only local mode is available")
        conversations: List[Tuple[str, Dict]] = []
        for path in sorted(self._iter_json_files(self.store_dir)):
            cid = path.stem
            data = self._safe_read_json(path)
            if data is not None:
                conversations.append((cid, data))
        return conversations

    def get_conversation(self, conversation_id: str) -> Optional[Dict]:
        """Load and return a single conversation, or None if missing/invalid."""
        if self.mode != "local":
            raise NotImplementedError("Only local mode is available")
        path = self.store_dir / f"{conversation_id}.json"
        return self._safe_read_json(path)

    def save_conversation(self, conversation_id: str, conversation: Dict) -> None:
        """Persist a conversation atomically to storage."""
        if self.mode != "local":
            raise NotImplementedError("Only local mode is available")
        path = self.store_dir / f"{conversation_id}.json"
        tmp_path = path.with_suffix(".json.tmp")
        tmp_path.write_text(json.dumps(conversation, ensure_ascii=False, indent=2))
        os.replace(tmp_path, path)

    def delete_conversation(self, conversation_id: str) -> None:
        """Remove a conversation from storage if it exists."""
        if self.mode != "local":
            raise NotImplementedError("Only local mode is available")
        path = self.store_dir / f"{conversation_id}.json"
        try:
            path.unlink(missing_ok=True)
        except TypeError:
            # Python <3.8 compatibility: ignore if file doesn't exist
            if path.exists():
                path.unlink()

    # ------------------------------
    # Internal helpers
    # ------------------------------
    @staticmethod
    def _ensure_dir(path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def _iter_json_files(directory: Path) -> Iterable[Path]:
        if not directory.exists():
            return []
        return (p for p in directory.glob("*.json") if p.is_file())

    @staticmethod
    def _safe_read_json(path: Path) -> Optional[Dict]:
        try:
            if not path.exists():
                return None
            return json.loads(path.read_text())
        except Exception:
            # Corrupt or unreadable file: ignore
            return None


