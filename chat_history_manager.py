"""
chat_history_manager.py
Chat history manager with support for local JSON and PostgreSQL storage.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

try:
    import psycopg2
    from psycopg2 import pool, sql
    from psycopg2.extras import RealDictCursor
    PSYCOPG2_AVAILABLE = True
except ImportError:
    PSYCOPG2_AVAILABLE = False

try:
    import redis
    REDIS_AVAILABLE = True
except ImportError:
    REDIS_AVAILABLE = False

logger = logging.getLogger(__name__)


class PostgreSQLBackend:
    """PostgreSQL backend for chat history storage.

    Stores conversations in two tables:
    - conversations: metadata (title, model, timestamps)
    - messages: individual chat messages with sequence numbers
    """

    def __init__(self, connection_string: str) -> None:
        """Initialize PostgreSQL backend with connection pool.

        Args:
            connection_string: PostgreSQL connection string
                Format: postgresql://user:pass@host:port/dbname?sslmode=require
        """
        if not PSYCOPG2_AVAILABLE:
            raise RuntimeError(
                "psycopg2 is required for PostgreSQL mode. "
                "Install with: pip install psycopg2-binary"
            )

        self.connection_string = connection_string

        try:
            # Create connection pool (min 1, max 5 connections)
            self.pool = psycopg2.pool.SimpleConnectionPool(
                1, 5, connection_string
            )
        except Exception as e:
            raise RuntimeError(f"Failed to connect to PostgreSQL: {e}")

    def _get_conn(self):
        """Get a connection from the pool."""
        return self.pool.getconn()

    def _put_conn(self, conn):
        """Return a connection to the pool."""
        self.pool.putconn(conn)

    def list_conversations(
        self, user_id: str, days: int = 7
    ) -> List[Tuple[str, Dict]]:
        """Return list of (conversation_id, conversation_metadata) for a user.

        Only returns conversations created within the last `days` days.
        Messages are NOT included in the returned data.

        Args:
            user_id: User client ID (Azure Entra ID or local test ID)
            days: Number of days of history to load (default: 7)

        Returns:
            List of (conversation_id, conversation_dict) tuples, sorted by last_modified DESC
        """
        conn = self._get_conn()
        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cutoff_date = datetime.now(timezone.utc) - timedelta(days=days)

                cur.execute(
                    """
                    SELECT conversation_id, user_client_id, title, model,
                           created_at, last_modified
                    FROM conversations
                    WHERE user_client_id = %s
                      AND created_at >= %s
                    ORDER BY last_modified DESC
                    """,
                    (user_id, cutoff_date)
                )

                rows = cur.fetchall()

                conversations = []
                for row in rows:
                    convo = {
                        "title": row["title"],
                        "model": row["model"],
                        "messages": [],  # Empty - not loaded yet
                        "created_at": row["created_at"].isoformat(),
                        "last_modified": row["last_modified"].isoformat(),
                    }
                    conversations.append((row["conversation_id"], convo))

                return conversations
        finally:
            self._put_conn(conn)

    def get_conversation(
        self, conversation_id: str, user_id: str
    ) -> Optional[Dict]:
        """Load a single conversation with all messages.

        Args:
            conversation_id: Conversation ID
            user_id: User client ID (for security check)

        Returns:
            Conversation dict with messages, or None if not found
        """
        conn = self._get_conn()
        try:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # Get conversation metadata
                cur.execute(
                    """
                    SELECT conversation_id, user_client_id, title, model,
                           created_at, last_modified
                    FROM conversations
                    WHERE conversation_id = %s AND user_client_id = %s
                    """,
                    (conversation_id, user_id)
                )

                conv_row = cur.fetchone()
                if not conv_row:
                    return None

                # Get messages ordered by sequence number
                cur.execute(
                    """
                    SELECT role, content, timestamp, sequence_number
                    FROM messages
                    WHERE conversation_id = %s
                    ORDER BY sequence_number ASC
                    """,
                    (conversation_id,)
                )

                message_rows = cur.fetchall()

                messages = [
                    {
                        "role": msg["role"],
                        "content": msg["content"],
                        "time": msg["timestamp"].isoformat(),
                    }
                    for msg in message_rows
                ]

                return {
                    "title": conv_row["title"],
                    "model": conv_row["model"],
                    "messages": messages,
                    "created_at": conv_row["created_at"].isoformat(),
                    "last_modified": conv_row["last_modified"].isoformat(),
                }
        finally:
            self._put_conn(conn)

    def save_conversation(
        self, conversation_id: str, user_id: str, conversation: Dict
    ) -> None:
        """Save a conversation with all messages atomically.

        Uses a transaction to:
        1. UPSERT conversation metadata
        2. DELETE old messages
        3. INSERT new messages with sequence numbers

        Args:
            conversation_id: Conversation ID
            user_id: User client ID
            conversation: Conversation dict with messages
        """
        conn = self._get_conn()
        try:
            with conn:
                with conn.cursor() as cur:
                    # Parse timestamps
                    created_at = datetime.fromisoformat(
                        conversation.get("created_at", datetime.now(timezone.utc).isoformat())
                    )
                    last_modified = datetime.fromisoformat(
                        conversation.get("last_modified", datetime.now(timezone.utc).isoformat())
                    )

                    # UPSERT conversation metadata
                    cur.execute(
                        """
                        INSERT INTO conversations
                            (conversation_id, user_client_id, title, model, created_at, last_modified)
                        VALUES (%s, %s, %s, %s, %s, %s)
                        ON CONFLICT (conversation_id)
                        DO UPDATE SET
                            title = EXCLUDED.title,
                            model = EXCLUDED.model,
                            last_modified = EXCLUDED.last_modified
                        """,
                        (
                            conversation_id,
                            user_id,
                            conversation["title"],
                            conversation["model"],
                            created_at,
                            last_modified,
                        )
                    )

                    # Delete old messages
                    cur.execute(
                        "DELETE FROM messages WHERE conversation_id = %s",
                        (conversation_id,)
                    )

                    # Insert new messages with sequence numbers
                    messages = conversation.get("messages", [])
                    for seq_num, msg in enumerate(messages):
                        timestamp = datetime.fromisoformat(
                            msg.get("time", datetime.now(timezone.utc).isoformat())
                        )

                        cur.execute(
                            """
                            INSERT INTO messages
                                (conversation_id, sequence_number, role, content, timestamp)
                            VALUES (%s, %s, %s, %s, %s)
                            """,
                            (
                                conversation_id,
                                seq_num,
                                msg["role"],
                                msg["content"],
                                timestamp,
                            )
                        )

                # Transaction commits automatically if no exception
        finally:
            self._put_conn(conn)

    def delete_conversation(
        self, conversation_id: str, user_id: str
    ) -> None:
        """Delete a conversation and all its messages.

        Args:
            conversation_id: Conversation ID
            user_id: User client ID (for security check)
        """
        conn = self._get_conn()
        try:
            with conn:
                with conn.cursor() as cur:
                    # Messages are cascade-deleted by foreign key constraint
                    cur.execute(
                        """
                        DELETE FROM conversations
                        WHERE conversation_id = %s AND user_client_id = %s
                        """,
                        (conversation_id, user_id)
                    )
        finally:
            self._put_conn(conn)

    def close(self) -> None:
        """Close all connections in the pool."""
        if hasattr(self, 'pool'):
            self.pool.closeall()


class RedisBackend:
    """Independent Redis cache backend (no PostgreSQL coupling)."""

    def __init__(self, redis_host: str, redis_password: str, redis_port: int = 6380,
                 redis_ssl: bool = True, redis_ttl: int = 1800) -> None:
        """Initialize Redis connection only.

        Args:
            redis_host: Redis server hostname
            redis_password: Redis password/access key
            redis_port: Redis port (default: 6380 for Azure SSL)
            redis_ssl: Enable SSL/TLS connection (default: True for Azure)
            redis_ttl: TTL for Redis keys in seconds (default: 1800 = 30 minutes)
        """
        if not REDIS_AVAILABLE:
            raise RuntimeError(
                "redis is required for Redis mode. "
                "Install with: pip install redis>=5.0.0"
            )

        self.redis_ttl = redis_ttl
        self.redis_client = None

        try:
            self.redis_client = redis.Redis(
                host=redis_host,
                port=redis_port,
                password=redis_password,
                ssl=redis_ssl,
                ssl_cert_reqs='required' if redis_ssl else None,
                decode_responses=True,  # Auto-decode to UTF-8
                socket_timeout=5,
                socket_connect_timeout=5,
                max_connections=10
            )
            # Test connection
            self.redis_client.ping()
            logger.info(f"Redis connection successful: {redis_host}:{redis_port}")
        except redis.RedisError as e:
            logger.error(f"Redis connection failed: {e}")
            self.redis_client = None

    def is_available(self) -> bool:
        """Check if Redis is available."""
        return self.redis_client is not None

    def get_conversations_list(self, user_id: str, days: int = 7) -> Optional[List[Tuple[str, Dict]]]:
        """Get cached conversations list. Returns None if cache miss.

        Args:
            user_id: User client ID
            days: Number of days of history to filter

        Returns:
            List of (conversation_id, conversation_dict) tuples or None
        """
        if not self.redis_client:
            return None

        conv_key = f"chat:{user_id}:conversations"

        try:
            raw_data = self.redis_client.zrevrange(conv_key, 0, -1)
            if raw_data:
                # Parse JSON and filter by days
                cutoff = datetime.now(timezone.utc) - timedelta(days=days)
                conversations = []

                for json_str in raw_data:
                    meta = json.loads(json_str)
                    created_at = datetime.fromisoformat(meta['created_at'])
                    if created_at >= cutoff:
                        conversations.append((
                            meta['conversation_id'],
                            {
                                'title': meta['title'],
                                'model': meta['model'],
                                'messages': [],  # Lazy load
                                'created_at': meta['created_at'],
                                'last_modified': meta['last_modified']
                            }
                        ))

                # Refresh TTL
                self.redis_client.expire(conv_key, self.redis_ttl)
                logger.info(f"Redis cache hit for user {user_id}: {len(conversations)} conversations")
                return conversations
        except redis.RedisError as e:
            logger.warning(f"Redis error in get_conversations_list: {e}")

        return None  # Cache miss or error

    def set_conversations_list(self, user_id: str, conversations: List[Tuple[str, Dict]]) -> bool:
        """Cache conversations list in Redis.

        Args:
            user_id: User client ID
            conversations: List of (conversation_id, conversation_dict) tuples

        Returns:
            True if successful, False otherwise
        """
        if not self.redis_client:
            return False

        conv_key = f"chat:{user_id}:conversations"

        try:
            pipeline = self.redis_client.pipeline()
            for cid, convo in conversations:
                json_meta = json.dumps({
                    'conversation_id': cid,
                    'title': convo['title'],
                    'model': convo['model'],
                    'created_at': convo['created_at'],
                    'last_modified': convo['last_modified']
                })
                score = datetime.fromisoformat(convo['last_modified']).timestamp()
                pipeline.zadd(conv_key, {json_meta: score})
            pipeline.expire(conv_key, self.redis_ttl)
            pipeline.execute()
            logger.info(f"Cached {len(conversations)} conversations for user {user_id}")
            return True
        except redis.RedisError as e:
            logger.warning(f"Redis write error in set_conversations_list: {e}")
            return False

    def get_conversation_messages(self, conversation_id: str, user_id: str) -> Optional[Dict]:
        """Get cached conversation messages. Returns None if cache miss.

        Args:
            conversation_id: Conversation ID
            user_id: User client ID

        Returns:
            Conversation dict with messages or None
        """
        if not self.redis_client:
            return None

        msg_key = f"chat:{conversation_id}:messages"
        conv_key = f"chat:{user_id}:conversations"

        try:
            messages_json = self.redis_client.lrange(msg_key, 0, -1)

            if messages_json:
                # Verify ownership by checking metadata
                all_convos = self.redis_client.zrevrange(conv_key, 0, -1)
                meta = None
                for json_str in all_convos:
                    temp_meta = json.loads(json_str)
                    if temp_meta['conversation_id'] == conversation_id:
                        meta = temp_meta
                        break

                if meta:
                    # Refresh TTLs
                    pipeline = self.redis_client.pipeline()
                    pipeline.expire(msg_key, self.redis_ttl)
                    pipeline.expire(conv_key, self.redis_ttl)
                    pipeline.execute()

                    logger.info(f"Redis cache hit for conversation {conversation_id}")
                    return {
                        'title': meta['title'],
                        'model': meta['model'],
                        'messages': [json.loads(msg) for msg in messages_json],
                        'created_at': meta['created_at'],
                        'last_modified': meta['last_modified']
                    }
        except redis.RedisError as e:
            logger.warning(f"Redis error in get_conversation_messages: {e}")

        return None  # Cache miss or error

    def set_conversation_messages(self, conversation_id: str, messages: List[Dict]) -> bool:
        """Cache conversation messages in Redis.

        Args:
            conversation_id: Conversation ID
            messages: List of message dicts

        Returns:
            True if successful, False otherwise
        """
        if not self.redis_client:
            return False

        msg_key = f"chat:{conversation_id}:messages"

        try:
            pipeline = self.redis_client.pipeline()
            # Delete existing messages first
            pipeline.delete(msg_key)
            for idx, msg in enumerate(messages):
                # Ensure sequence_number is included
                msg_with_seq = {
                    'sequence_number': idx,
                    'role': msg['role'],
                    'content': msg['content'],
                    'time': msg.get('time', datetime.now(timezone.utc).isoformat())
                }
                pipeline.rpush(msg_key, json.dumps(msg_with_seq))
            pipeline.expire(msg_key, self.redis_ttl)
            pipeline.execute()
            logger.info(f"Cached {len(messages)} messages for conversation {conversation_id}")
            return True
        except redis.RedisError as e:
            logger.warning(f"Redis write error in set_conversation_messages: {e}")
            return False

    def update_conversation_metadata(self, user_id: str, conversation_id: str,
                                     conversation: Dict) -> bool:
        """Update conversation metadata in sorted set.

        Args:
            user_id: User client ID
            conversation_id: Conversation ID
            conversation: Conversation dict with metadata

        Returns:
            True if successful, False otherwise
        """
        if not self.redis_client:
            return False

        conv_key = f"chat:{user_id}:conversations"

        try:
            pipeline = self.redis_client.pipeline()

            # Remove old entry first (metadata might have changed)
            all_convos = self.redis_client.zrevrange(conv_key, 0, -1)
            for json_str in all_convos:
                meta = json.loads(json_str)
                if meta['conversation_id'] == conversation_id:
                    pipeline.zrem(conv_key, json_str)
                    break

            # Add new metadata
            json_meta = json.dumps({
                'conversation_id': conversation_id,
                'title': conversation['title'],
                'model': conversation['model'],
                'created_at': conversation['created_at'],
                'last_modified': conversation['last_modified']
            })
            score = datetime.fromisoformat(conversation['last_modified']).timestamp()
            pipeline.zadd(conv_key, {json_meta: score})
            pipeline.expire(conv_key, self.redis_ttl)

            pipeline.execute()
            logger.info(f"Updated metadata for conversation {conversation_id}")
            return True
        except redis.RedisError as e:
            logger.warning(f"Redis error in update_conversation_metadata: {e}")
            return False

    def append_messages(self, conversation_id: str, new_messages: List[Dict],
                       start_sequence: int = 0) -> bool:
        """Append new messages to existing cached conversation.

        Args:
            conversation_id: Conversation ID
            new_messages: List of new message dicts to append
            start_sequence: Starting sequence number for new messages

        Returns:
            True if successful, False otherwise
        """
        if not self.redis_client:
            return False

        msg_key = f"chat:{conversation_id}:messages"

        try:
            pipeline = self.redis_client.pipeline()
            for idx, msg in enumerate(new_messages):
                # Ensure sequence_number is included
                msg_with_seq = {
                    'sequence_number': start_sequence + idx,
                    'role': msg['role'],
                    'content': msg['content'],
                    'time': msg.get('time', datetime.now(timezone.utc).isoformat())
                }
                pipeline.rpush(msg_key, json.dumps(msg_with_seq))
            pipeline.expire(msg_key, self.redis_ttl)
            pipeline.execute()
            logger.info(f"Appended {len(new_messages)} messages to conversation {conversation_id}")
            return True
        except redis.RedisError as e:
            logger.warning(f"Redis error in append_messages: {e}")
            return False

    def delete_conversation_cache(self, user_id: str, conversation_id: str) -> bool:
        """Delete conversation from Redis cache.

        Args:
            user_id: User client ID
            conversation_id: Conversation ID

        Returns:
            True if successful, False otherwise
        """
        if not self.redis_client:
            return False

        conv_key = f"chat:{user_id}:conversations"
        msg_key = f"chat:{conversation_id}:messages"

        try:
            # Find and remove from sorted set
            all_convos = self.redis_client.zrevrange(conv_key, 0, -1)
            pipeline = self.redis_client.pipeline()

            for json_str in all_convos:
                meta = json.loads(json_str)
                if meta['conversation_id'] == conversation_id:
                    pipeline.zrem(conv_key, json_str)
                    break

            # Delete messages
            pipeline.delete(msg_key)
            pipeline.execute()
            logger.info(f"Deleted cache for conversation {conversation_id}")
            return True
        except redis.RedisError as e:
            logger.warning(f"Redis error in delete_conversation_cache: {e}")
            return False

    def close(self) -> None:
        """Close Redis connection."""
        if self.redis_client:
            self.redis_client.close()
            logger.info("Redis connection closed")


class ChatHistoryManager:
    """Persist and retrieve chat histories.

    Modes:
      - "local": Store each conversation as a JSON file under .chat_history/
      - "postgres": Store conversations in PostgreSQL database
      - "redis": Store conversations in PostgreSQL with Redis write-through caching
    """

    def __init__(
        self,
        mode: str = "local",
        base_dir: Optional[Path | str] = None,
        connection_string: Optional[str] = None,
        history_days: int = 7,
        redis_host: Optional[str] = None,
        redis_password: Optional[str] = None,
        redis_port: int = 6380,
        redis_ssl: bool = True,
        redis_ttl: int = 1800,
    ) -> None:
        """Initialize chat history manager.

        Args:
            mode: Storage mode ("local", "postgres", or "redis")
            base_dir: Base directory for local mode
            connection_string: PostgreSQL connection string for postgres/redis mode
            history_days: Number of days of history to load (postgres/redis mode only)
            redis_host: Redis server hostname (redis mode only)
            redis_password: Redis password/access key (redis mode only)
            redis_port: Redis port (default: 6380 for Azure SSL)
            redis_ssl: Enable SSL/TLS connection (default: True for Azure)
            redis_ttl: TTL for Redis keys in seconds (default: 1800 = 30 minutes)
        """
        self.mode = mode
        self.history_days = history_days
        self.base_dir = Path(base_dir) if base_dir is not None else Path(__file__).resolve().parent
        self.cache = None

        if self.mode == "local":
            self.store_dir = self.base_dir / ".chat_history"
            self._ensure_dir(self.store_dir)
            self.backend = None
        elif self.mode == "postgres":
            if not connection_string:
                raise ValueError("connection_string is required for postgres mode")
            self.backend = PostgreSQLBackend(connection_string)
        elif self.mode == "redis":
            # Initialize BOTH backends (decoupled)
            if not connection_string:
                raise ValueError("connection_string is required for redis mode")
            if not redis_host or not redis_password:
                raise ValueError("redis_host and redis_password are required for redis mode")

            self.backend = PostgreSQLBackend(connection_string)
            self.cache = RedisBackend(
                redis_host=redis_host,
                redis_password=redis_password,
                redis_port=redis_port,
                redis_ssl=redis_ssl,
                redis_ttl=redis_ttl
            )
        else:
            raise ValueError(f"Unsupported mode: {self.mode}")

    # ------------------------------
    # Public API
    # ------------------------------
    def list_conversations(self, user_id: Optional[str] = None) -> List[Tuple[str, Dict]]:
        """Return list of (conversation_id, conversation) from storage.

        Args:
            user_id: User client ID (required for postgres/redis mode)

        Returns:
            List of (conversation_id, conversation_dict) tuples
        """
        if self.mode == "local":
            conversations: List[Tuple[str, Dict]] = []
            for path in sorted(self._iter_json_files(self.store_dir)):
                cid = path.stem
                data = self._safe_read_json(path)
                if data is not None:
                    conversations.append((cid, data))
            return conversations

        elif self.mode == "postgres":
            if not user_id:
                raise ValueError("user_id is required for postgres mode")
            return self.backend.list_conversations(user_id, days=self.history_days)

        elif self.mode == "redis":
            if not user_id:
                raise ValueError("user_id is required for redis mode")

            # Try cache first
            if self.cache and self.cache.is_available():
                cached = self.cache.get_conversations_list(user_id, self.history_days)
                if cached is not None:
                    return cached

                # Cache miss - load from PostgreSQL
                logger.info(f"Cache miss for user {user_id}, loading from PostgreSQL")

            # Load from PostgreSQL
            conversations = self.backend.list_conversations(user_id, days=self.history_days)

            # Populate cache
            if self.cache and self.cache.is_available():
                self.cache.set_conversations_list(user_id, conversations)

            return conversations

        else:
            raise NotImplementedError(f"Mode {self.mode} not implemented")

    def get_conversation(
        self, conversation_id: str, user_id: Optional[str] = None
    ) -> Optional[Dict]:
        """Load and return a single conversation, or None if missing/invalid.

        Args:
            conversation_id: Conversation ID
            user_id: User client ID (required for postgres/redis mode)

        Returns:
            Conversation dict or None
        """
        if self.mode == "local":
            path = self.store_dir / f"{conversation_id}.json"
            return self._safe_read_json(path)

        elif self.mode == "postgres":
            if not user_id:
                raise ValueError("user_id is required for postgres mode")
            return self.backend.get_conversation(conversation_id, user_id)

        elif self.mode == "redis":
            if not user_id:
                raise ValueError("user_id is required for redis mode")

            # Try cache first
            if self.cache and self.cache.is_available():
                cached = self.cache.get_conversation_messages(conversation_id, user_id)
                if cached is not None:
                    return cached

                # Cache miss
                logger.info(f"Cache miss for conversation {conversation_id}")

            # Load from PostgreSQL
            conversation = self.backend.get_conversation(conversation_id, user_id)

            # Populate cache
            if conversation and self.cache and self.cache.is_available():
                self.cache.set_conversation_messages(conversation_id, conversation['messages'])

            return conversation

        else:
            raise NotImplementedError(f"Mode {self.mode} not implemented")

    def save_conversation(
        self, conversation_id: str, conversation: Dict, user_id: Optional[str] = None
    ) -> None:
        """Persist a conversation atomically to storage.

        Args:
            conversation_id: Conversation ID
            conversation: Conversation dict
            user_id: User client ID (required for postgres/redis mode)
        """
        if self.mode == "local":
            path = self.store_dir / f"{conversation_id}.json"
            tmp_path = path.with_suffix(".json.tmp")
            tmp_path.write_text(json.dumps(conversation, ensure_ascii=False, indent=2))
            os.replace(tmp_path, path)

        elif self.mode == "postgres":
            if not user_id:
                raise ValueError("user_id is required for postgres mode")
            self.backend.save_conversation(conversation_id, user_id, conversation)

        elif self.mode == "redis":
            if not user_id:
                raise ValueError("user_id is required for redis mode")

            # 1. Write to PostgreSQL first (source of truth)
            self.backend.save_conversation(conversation_id, user_id, conversation)

            # 2. Update Redis cache
            if self.cache and self.cache.is_available():
                # Update conversation metadata (for conversation list)
                self.cache.update_conversation_metadata(user_id, conversation_id, conversation)

                # Append new messages (efficient)
                # Check how many messages are already cached
                try:
                    redis_msg_count = self.cache.redis_client.llen(f"chat:{conversation_id}:messages") or 0
                    new_messages = conversation['messages'][redis_msg_count:]
                    if new_messages:
                        # Append with correct sequence numbering
                        self.cache.append_messages(conversation_id, new_messages, start_sequence=redis_msg_count)
                    elif redis_msg_count == 0:
                        # No messages cached yet, cache all
                        self.cache.set_conversation_messages(conversation_id, conversation['messages'])
                except Exception as e:
                    logger.warning(f"Failed to append messages to cache: {e}")

        else:
            raise NotImplementedError(f"Mode {self.mode} not implemented")

    def delete_conversation(
        self, conversation_id: str, user_id: Optional[str] = None
    ) -> None:
        """Remove a conversation from storage if it exists.

        Args:
            conversation_id: Conversation ID
            user_id: User client ID (required for postgres/redis mode)
        """
        if self.mode == "local":
            path = self.store_dir / f"{conversation_id}.json"
            try:
                path.unlink(missing_ok=True)
            except TypeError:
                # Python <3.8 compatibility: ignore if file doesn't exist
                if path.exists():
                    path.unlink()

        elif self.mode == "postgres":
            if not user_id:
                raise ValueError("user_id is required for postgres mode")
            self.backend.delete_conversation(conversation_id, user_id)

        elif self.mode == "redis":
            if not user_id:
                raise ValueError("user_id is required for redis mode")

            # 1. Delete from PostgreSQL first
            self.backend.delete_conversation(conversation_id, user_id)

            # 2. Invalidate cache
            if self.cache and self.cache.is_available():
                self.cache.delete_conversation_cache(user_id, conversation_id)

        else:
            raise NotImplementedError(f"Mode {self.mode} not implemented")

    def close(self) -> None:
        """Close any open connections (postgres/redis mode only)."""
        if self.backend and hasattr(self.backend, 'close'):
            self.backend.close()
        if self.cache and hasattr(self.cache, 'close'):
            self.cache.close()

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
