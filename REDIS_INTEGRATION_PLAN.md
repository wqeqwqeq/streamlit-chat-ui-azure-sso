# Azure Redis Cache Integration Plan

## Overview
Implement write-through cache layer using Azure Redis Cache with PostgreSQL as the source of truth. Redis schema mirrors PostgreSQL tables exactly. All configuration via `.env` file (no Bicep app settings).

---

## 1. Redis Key Design (2 Keys Only)

### Key 1: `chat:{user_id}:conversations` → Sorted Set
**Purpose**: Mirrors PostgreSQL `conversations` table
**Structure**:
- **Members**: JSON-serialized conversation metadata
- **Score**: `last_modified` timestamp (for automatic sorting)
- **JSON payload per member**:
```json
{
  "conversation_id": "abc123",
  "title": "Chat title",
  "model": "gpt-4o-mini",
  "created_at": "2025-01-15T10:30:00Z",
  "last_modified": "2025-01-15T12:45:00Z"
}
```

**Operations**:
- List conversations: `ZREVRANGE chat:{user_id}:conversations 0 -1` → Returns newest first
- Add/update: Remove old entry by conversation_id, then `ZADD` with new metadata
- Delete: `ZREM` by matching conversation_id

### Key 2: `chat:{conversation_id}:messages` → List
**Purpose**: Mirrors PostgreSQL `messages` table
**Structure**:
- **List elements**: JSON-serialized message objects (in sequence order)
- **JSON payload per element**:
```json
{
  "sequence_number": 0,
  "role": "user",
  "content": "Hello!",
  "time": "2025-01-15T10:30:15Z"
}
```

**Note**: `sequence_number` is included for:
- Consistency with PostgreSQL schema
- Validation that Redis list order matches sequence
- Easier debugging and cache verification
- The Redis list position implicitly maintains order, but the explicit sequence_number provides a safety check

**Operations**:
- Load all messages: `LRANGE chat:{conversation_id}:messages 0 -1`
- Append new message: `RPUSH chat:{conversation_id}:messages {json_message}`
- Delete all messages: `DEL chat:{conversation_id}:messages`

**TTL**: Both keys have 30-minute TTL (configurable via `REDIS_TTL_SECONDS`)

---

## 2. Chat History Modes

### Supported Modes

| Mode | Storage | User Auth | Use Case |
|------|---------|-----------|----------|
| `local` | JSON files | N/A | Local dev, no DB |
| `local_psql` | PostgreSQL only | Test user from .env | Local dev with Azure DB |
| `postgres` | PostgreSQL only | SSO headers | Production without cache |
| `local_redis` | **Azure Redis + PostgreSQL** | Test user from .env | Local dev testing Redis |
| `redis` | **Azure Redis + PostgreSQL** | SSO headers | Production with cache |

**Key Point**: `local_redis` connects to **Azure Redis** (not Docker), but uses test user credentials for development.

---

## 3. Infrastructure Changes (`deployment/simplified.bicep`)

### Add Redis Cache Resource
```bicep
@description('Redis Cache SKU name')
@allowed(['Basic', 'Standard', 'Premium'])
param redisSkuName string = 'Basic'

@description('Redis Cache capacity (0=250MB, 1=1GB, 2=2.5GB)')
param redisSkuCapacity int = 0

resource redisCache 'Microsoft.Cache/redis@2023-08-01' = {
  name: '${resourcePrefix}-redis'
  location: location
  properties: {
    sku: {
      name: redisSkuName
      family: 'C'
      capacity: redisSkuCapacity
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    redisConfiguration: {
      'maxmemory-policy': 'allkeys-lru'  // Evict least recently used
    }
  }
}
```

### Add Outputs (for easy .env configuration)
**IMPORTANT**: No Key Vault secrets needed. All configuration is managed via `.env` file.
```bicep
output redisHostName string = redisCache.properties.hostName
output redisSslPort int = redisCache.properties.sslPort
```

**Deployment workflow**:
1. Deploy Bicep template to provision Redis
2. Copy output values to `.env` file:
   ```bash
   az deployment group show -g <rg-name> -n <deployment-name> --query properties.outputs
   ```
3. Get Redis password from Azure Portal:
   - Redis Cache → Access keys → Copy Primary key
   - Add to `.env` as `REDIS_PASSWORD=<key>`

**NO Key Vault secrets, NO App Service app settings** - `.env` is the single source of truth, bundled in deployment ZIP.

---

## 4. Environment Configuration (`.env`)

### Update `.env.example`
Add Redis section:

```bash
# ======================================================================
# Redis Cache Configuration (local_redis/redis modes only)
# ======================================================================

# Redis server hostname
# Azure: {RESOURCE_PREFIX}-redis.redis.cache.windows.net (from Bicep output)
# Get from: az deployment group show --query properties.outputs.redisHostName
REDIS_HOST=your-redis-server.redis.cache.windows.net

# Redis port (Azure always uses SSL port 6380)
REDIS_PORT=6380

# Redis password/access key
# Get from Azure Portal → Redis Cache → Access keys → Primary
# Or from Key Vault secret: redis-password
REDIS_PASSWORD=your_redis_primary_key_here

# Enable SSL/TLS connection (always true for Azure)
REDIS_SSL=true

# TTL for Redis keys in seconds (default: 1800 = 30 minutes)
REDIS_TTL_SECONDS=1800
```

### Update Mode Description
```bash
# Storage mode for chat history
# Options:
#   - local:       JSON files in .chat_history/ directory (no database required)
#   - local_psql:  Azure PostgreSQL with hardcoded test user (for local development/testing)
#   - postgres:    Azure PostgreSQL with real SSO user from Azure Easy Auth headers
#   - local_redis: Azure Redis + Azure PostgreSQL with test user (for Redis cache testing)
#   - redis:       Azure Redis + Azure PostgreSQL with SSO user (production with cache)
CHAT_HISTORY_MODE=local
```

---

## 5. Code Changes (`chat_history_manager.py`)

### Add Redis Dependency
Update `pyproject.toml`:
```toml
dependencies = [
    "streamlit>=1.43.0",
    "python-dotenv>=1.0.0",
    "psycopg2-binary>=2.9.10",
    "redis>=5.0.0",  # NEW
]
```

### Architecture: Decoupled Backends

**Design principle**: Keep PostgreSQL and Redis backends completely separate. ChatHistoryManager orchestrates write-through caching logic when `mode="redis"`.

**Benefits**:
- ✅ PostgresBackend remains unchanged (no refactoring needed)
- ✅ RedisBackend is independent and testable
- ✅ ChatHistoryManager controls caching strategy
- ✅ Easy to swap caching logic without touching backends

### Keep PostgresBackend Unchanged
```python
class PostgresBackend:
    # NO CHANGES - keep existing implementation as-is
    # Lines 61-275 remain untouched

    def list_conversations(self, user_id=None, days=7):
        # Existing implementation (lines 61-108)
        ...

    def get_conversation(self, conversation_id, user_id=None):
        # Existing implementation (lines 110-170)
        ...

    def save_conversation(self, conversation_id, conversation, user_id=None):
        # Existing implementation (lines 172-251)
        ...

    def delete_conversation(self, conversation_id, user_id=None):
        # Existing implementation (lines 253-275)
        ...
```

### Create Independent RedisBackend Class
A standalone Redis client for caching operations only:

```python
import redis
import json
from datetime import datetime, timezone, timedelta
import logging

logger = logging.getLogger(__name__)

class RedisBackend:
    """Independent Redis cache backend (no PostgreSQL coupling)."""

    def __init__(self, redis_host, redis_password, redis_port=6380, redis_ssl=True, redis_ttl=1800):
        """Initialize Redis connection only."""
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

    def is_available(self):
        """Check if Redis is available."""
        return self.redis_client is not None

    def get_conversations_list(self, user_id, days=7):
        """Get cached conversations list. Returns None if cache miss."""
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

    def set_conversations_list(self, user_id, conversations):
        """Cache conversations list in Redis."""
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

    def get_conversation_messages(self, conversation_id, user_id=None):
        """Get cached conversation messages. Returns None if cache miss."""
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

    def set_conversation_messages(self, conversation_id, messages):
        """Cache conversation messages in Redis."""
        if not self.redis_client:
            return False

        msg_key = f"chat:{conversation_id}:messages"

        try:
            pipeline = self.redis_client.pipeline()
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

    def update_conversation_metadata(self, user_id, conversation_id, conversation):
        """Update conversation metadata in sorted set."""
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

    def append_messages(self, conversation_id, new_messages, start_sequence=0):
        """Append new messages to existing cached conversation."""
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

    def delete_conversation_cache(self, user_id, conversation_id):
        """Delete conversation from Redis cache."""
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

    def close(self):
        """Close Redis connection."""
        if self.redis_client:
            self.redis_client.close()
            logger.info("Redis connection closed")
```

### Update ChatHistoryManager - Orchestration Layer

ChatHistoryManager now orchestrates both PostgreSQL and Redis backends for write-through caching:

```python
class ChatHistoryManager:
    """Manager for chat history with multiple backend support."""

    def __init__(self, mode="local", **kwargs):
        self.mode = mode

        if mode == "local":
            self.backend = LocalBackend()
            self.cache = None
        elif mode == "postgres":
            self.backend = PostgresBackend(
                connection_string=kwargs["connection_string"],
                history_days=kwargs.get("history_days", 7)
            )
            self.cache = None
        elif mode == "redis":
            # Initialize BOTH backends (decoupled)
            self.backend = PostgresBackend(
                connection_string=kwargs["connection_string"],
                history_days=kwargs.get("history_days", 7)
            )
            self.cache = RedisBackend(
                redis_host=kwargs["redis_host"],
                redis_password=kwargs["redis_password"],
                redis_port=kwargs.get("redis_port", 6380),
                redis_ssl=kwargs.get("redis_ssl", True),
                redis_ttl=kwargs.get("redis_ttl", 1800)
            )
        else:
            raise ValueError(f"Unknown mode: {mode}")

    def list_conversations(self, user_id=None):
        """List conversations with optional Redis caching."""
        if self.cache and self.cache.is_available():
            # Try cache first
            cached = self.cache.get_conversations_list(user_id, self.backend.history_days)
            if cached is not None:
                return cached

            # Cache miss - load from PostgreSQL
            logger.info(f"Cache miss for user {user_id}, loading from PostgreSQL")

        # Load from PostgreSQL
        conversations = self.backend.list_conversations(user_id)

        # Populate cache
        if self.cache and self.cache.is_available():
            self.cache.set_conversations_list(user_id, conversations)

        return conversations

    def get_conversation(self, conversation_id, user_id=None):
        """Get conversation with optional Redis caching."""
        if self.cache and self.cache.is_available():
            # Try cache first
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

    def save_conversation(self, conversation_id, conversation, user_id=None):
        """Save conversation with write-through caching."""
        # 1. Write to PostgreSQL first (source of truth)
        self.backend.save_conversation(conversation_id, conversation, user_id)

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
                else:
                    # No messages cached yet, cache all
                    self.cache.set_conversation_messages(conversation_id, conversation['messages'])
            except Exception as e:
                logger.warning(f"Failed to append messages to cache: {e}")

    def delete_conversation(self, conversation_id, user_id=None):
        """Delete conversation with cache invalidation."""
        # 1. Delete from PostgreSQL first
        self.backend.delete_conversation(conversation_id, user_id)

        # 2. Invalidate cache
        if self.cache and self.cache.is_available():
            self.cache.delete_conversation_cache(user_id, conversation_id)

    def close(self):
        """Close all connections."""
        if hasattr(self.backend, 'close'):
            self.backend.close()
        if self.cache:
            self.cache.close()
```

**Key Benefits of Decoupled Design**:
1. PostgresBackend code remains untouched
2. RedisBackend is independent and reusable
3. ChatHistoryManager orchestrates caching logic
4. Easy to test each component in isolation
5. Can switch caching strategies without touching backends

---

## 6. App.py Changes (Minimal)

### Update Initialization (Lines 32-51)
```python
CHAT_HISTORY_MODE = os.getenv("CHAT_HISTORY_MODE", "local")
CONVERSATION_HISTORY_DAYS = int(os.getenv("CONVERSATION_HISTORY_DAYS", "7"))

if CHAT_HISTORY_MODE in ["redis", "local_redis"]:
    # Build PostgreSQL connection string
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
    # Existing code (unchanged)
    ...
else:
    HISTORY = ChatHistoryManager(mode="local")
```

### Update `get_user_info()` (Line 62)
```python
if CHAT_HISTORY_MODE in ["local_psql", "local_redis"]:
    return {
        'user_id': os.getenv('LOCAL_TEST_CLIENT_ID', '00000000-0000-0000-0000-000000000001'),
        'user_name': os.getenv('LOCAL_TEST_USERNAME', 'local_user'),
        'is_authenticated': True,
        'mode': CHAT_HISTORY_MODE
    }
```

### Update `render_user_info()` (Lines 315-323)
```python
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
else:
    st.markdown("**🏠 Local Mode**")
```

### Update Lazy Loading Check (Line 272)
```python
if CHAT_HISTORY_MODE in ["postgres", "local_psql", "redis", "local_redis"] and not convo.get("messages"):
```

---

## 7. Testing Strategy

### Local Testing with local_redis Mode
1. **Deploy Azure Redis** (via Bicep)
2. **Get Redis credentials**:
   ```bash
   # From deployment output
   az deployment group show -g <rg> -n <deployment> --query properties.outputs

   # Or from Azure Portal
   # Redis Cache → Access keys → Copy Primary
   ```
3. **Configure .env**:
   ```bash
   CHAT_HISTORY_MODE=local_redis
   REDIS_HOST=stanley-dev-ui-redis.redis.cache.windows.net
   REDIS_PORT=6380
   REDIS_PASSWORD=<primary-key>
   REDIS_SSL=true
   REDIS_TTL_SECONDS=1800
   ```
4. **Run locally**: `streamlit run app.py`
5. **Monitor Redis** (Azure Portal → Metrics or Console)
6. **Test scenarios**:
   - Create new chat → Verify write to PostgreSQL + Redis
   - List conversations → Verify cache hit (check logs)
   - Click conversation → Verify lazy load from cache
   - Send message → Verify append to Redis list
   - Delete conversation → Verify cleanup
   - Wait 30 min → Verify TTL expiration and cache miss

### Production Testing with redis Mode
1. Set `CHAT_HISTORY_MODE=redis` in `.env`
2. Deploy to Azure
3. Test with SSO authentication
4. Monitor Application Insights for Redis errors
5. Verify cache performance metrics

---

## 8. Deployment Steps

### Phase 1: Infrastructure (Bicep)
1. Update `deployment/simplified.bicep` - add Redis resource
2. Deploy: `az deployment group create -g <rg> -f deployment/simplified.bicep`
3. Capture Redis hostname and password from outputs/portal

### Phase 2: Application Code
1. Update `pyproject.toml` - add `redis>=5.0.0`
2. Generate requirements: `uv pip compile pyproject.toml -o requirements.txt`
3. Update `chat_history_manager.py`:
   - **Keep PostgresBackend unchanged** (no refactoring needed!)
   - Create new `RedisBackend` class (independent)
   - Update `ChatHistoryManager.__init__()` to support `mode="redis"`
   - Update `ChatHistoryManager` public methods to orchestrate caching
4. Update `app.py`:
   - Add redis mode detection in initialization
   - Update `get_user_info()` to handle `local_redis` mode
   - Update `render_user_info()` to display Redis mode
   - Update lazy loading check to include redis modes
5. Update `.env.example` - add Redis configuration section

### Phase 3: Local Testing
1. Configure `.env` with Azure Redis credentials
2. Set `CHAT_HISTORY_MODE=local_redis`
3. Run: `streamlit run app.py`
4. Verify Redis cache operations (check logs)
5. Test all CRUD operations

### Phase 4: Azure Deployment
1. Deploy app: `./deployment/deploy_script.sh`
2. Ensure `.env` is bundled in ZIP (deployment script already does this)
3. Set `CHAT_HISTORY_MODE=redis` in production `.env`
4. Test SSO login and cache performance

---

## 9. Key Decisions Summary

### Architecture
✅ **Decoupled backends** - PostgresBackend and RedisBackend are independent
✅ **ChatHistoryManager orchestration** - Manages write-through caching logic at manager level
✅ **No PostgresBackend refactoring** - Existing code remains completely unchanged
✅ **Write-through cache** - PostgreSQL is source of truth, Redis is pure cache

### Data Design
✅ **2-key design** - Mirrors PostgreSQL schema exactly
✅ **Sorted Set for conversations** - Auto-sorts by `last_modified` timestamp
✅ **List for messages** - Append-only with RPUSH for efficiency
✅ **sequence_number in message JSON** - Ensures 1:1 match with PostgreSQL, enables validation
✅ **30-minute TTL** - Configurable via REDIS_TTL_SECONDS

### Configuration
✅ **`.env` as single source of truth** - No Key Vault secrets, no Bicep app settings
✅ **local_redis mode** - Connects to Azure Redis with test user for local development
✅ **No Docker Redis** - Always use Azure Redis Cache (consistent across environments)

### Reliability
✅ **Graceful degradation** - Falls back to PostgreSQL on Redis errors
✅ **Independent testability** - Each backend can be tested in isolation
✅ **Flexible caching** - Easy to modify caching strategy without touching backends

**Estimated effort**: 6-8 hours (implementation + testing)
