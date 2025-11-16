# Redis Migration Plan (Phase 2)

## Overview

This document outlines the Phase 2 migration strategy: adding Azure Cache for Redis as a caching layer on top of the existing PostgreSQL implementation from Phase 1.

**Goal**: Improve performance and reduce PostgreSQL load by caching active conversations in Redis, with write-back to PostgreSQL on session end.

---

## Architecture Design

### Three-Tier Architecture

```
┌─────────────┐
│  Streamlit  │  (Session State - In-Memory)
│     App     │
└──────┬──────┘
       │
       │ Read/Write operations
       ▼
┌─────────────┐
│    Redis    │  (Hot Cache - Active Conversations)
│   L1 Cache  │  - Current session conversations
└──────┬──────┘  - Recently accessed conversations
       │          - TTL: 30 minutes
       │
       │ Cache miss / Write-back
       ▼
┌─────────────┐
│ PostgreSQL  │  (Cold Storage - All Conversations)
│  Database   │  - Persistent storage
└─────────────┘  - Historical conversations
```

### Data Flow

**Read Path**:
1. Check Streamlit `session_state` (in-memory)
2. If miss, check Redis cache
3. If miss, query PostgreSQL
4. Backfill Redis with fetched data

**Write Path**:
1. Write immediately to Redis (mark as dirty)
2. Update Streamlit `session_state`
3. Write to PostgreSQL on:
   - Session end / logout
   - Manual flush trigger
   - Periodic background job (optional)

---

## Redis Key Design

### Key Structure

```python
# Active conversation (full messages)
KEY: "conv:{user_id}:{conversation_id}"
TYPE: Hash
TTL: 1800 seconds (30 minutes)
FIELDS:
  - title: string
  - model: string
  - created_at: ISO timestamp
  - last_modified: ISO timestamp
  - dirty: "0" | "1"  # Flag for pending write-back
VALUE (messages): JSON array

# User's conversation list (metadata only)
KEY: "user:{user_id}:convlist"
TYPE: Sorted Set (score = last_modified timestamp)
TTL: 300 seconds (5 minutes)
MEMBERS: conversation_id
SCORES: Unix timestamp of last_modified

# Dirty conversations queue (for write-back tracking)
KEY: "dirty:convs"
TYPE: Set
MEMBERS: "{user_id}:{conversation_id}"
TTL: None (persist until written back)
```

### Example Keys

```
conv:00000000-0000-0000-0000-000000000001:a1b2c3d4 → Hash (full conversation)
user:00000000-0000-0000-0000-000000000001:convlist → Sorted Set (conversation IDs)
dirty:convs → Set (pending write-backs)
```

---

## Implementation Details

### 1. Redis Backend Class

Create `RedisBackend` class in `chat_history_manager.py`:

```python
class RedisBackend:
    """Redis caching layer for chat conversations."""

    def __init__(self, redis_connection_string: str):
        """Initialize Redis client and connection pool."""
        self.client = redis.from_url(redis_connection_string, decode_responses=True)

    def get_conversation(self, user_id: str, conversation_id: str) -> Optional[Dict]:
        """Fetch conversation from Redis cache."""
        key = f"conv:{user_id}:{conversation_id}"
        data = self.client.hgetall(key)
        if not data:
            return None

        # Parse messages from JSON
        messages = json.loads(data.get("messages", "[]"))
        return {
            "title": data["title"],
            "model": data["model"],
            "messages": messages,
            "created_at": data["created_at"],
            "last_modified": data["last_modified"]
        }

    def set_conversation(self, user_id: str, conversation_id: str, conversation: Dict, dirty: bool = True):
        """Store conversation in Redis and mark as dirty if modified."""
        key = f"conv:{user_id}:{conversation_id}"

        # Serialize messages to JSON
        data = {
            "title": conversation["title"],
            "model": conversation["model"],
            "messages": json.dumps(conversation["messages"]),
            "created_at": conversation["created_at"],
            "last_modified": conversation["last_modified"],
            "dirty": "1" if dirty else "0"
        }

        # Store with TTL (30 minutes)
        self.client.hset(key, mapping=data)
        self.client.expire(key, 1800)

        # Add to dirty set if modified
        if dirty:
            self.client.sadd("dirty:convs", f"{user_id}:{conversation_id}")

    def get_dirty_conversations(self) -> List[Tuple[str, str]]:
        """Retrieve all conversations pending write-back."""
        dirty_keys = self.client.smembers("dirty:convs")
        return [tuple(key.split(":", 1)) for key in dirty_keys]

    def clear_dirty_flag(self, user_id: str, conversation_id: str):
        """Remove dirty flag after successful write-back."""
        key = f"conv:{user_id}:{conversation_id}"
        self.client.hset(key, "dirty", "0")
        self.client.srem("dirty:convs", f"{user_id}:{conversation_id}")
```

### 2. Enhanced ChatHistoryManager

Modify `ChatHistoryManager` to use Redis as an intermediate layer:

```python
class ChatHistoryManager:
    def __init__(self, mode: str, redis_enabled: bool = False, **kwargs):
        self.mode = mode
        self.redis_enabled = redis_enabled

        if redis_enabled:
            redis_conn_str = os.getenv("REDIS_CONNECTION_STRING")
            self.redis_backend = RedisBackend(redis_conn_str)
        else:
            self.redis_backend = None

        # Initialize PostgreSQL backend (existing code)
        if mode == "postgres":
            self.postgres_backend = PostgreSQLBackend(kwargs["connection_string"])

    def get_conversation(self, conversation_id: str, user_id: str) -> Optional[Dict]:
        """Get conversation with Redis cache-aside pattern."""
        if self.redis_enabled:
            # Try Redis first
            cached = self.redis_backend.get_conversation(user_id, conversation_id)
            if cached:
                return cached

        # Cache miss: query PostgreSQL
        convo = self.postgres_backend.get_conversation(conversation_id, user_id)

        # Backfill Redis
        if convo and self.redis_enabled:
            self.redis_backend.set_conversation(user_id, conversation_id, convo, dirty=False)

        return convo

    def save_conversation(self, conversation_id: str, conversation: Dict, user_id: str) -> None:
        """Save conversation to Redis (immediate) and mark for write-back."""
        if self.redis_enabled:
            # Write to Redis immediately
            self.redis_backend.set_conversation(user_id, conversation_id, conversation, dirty=True)
        else:
            # Direct PostgreSQL write
            self.postgres_backend.save_conversation(conversation_id, user_id, conversation)

    def flush_dirty_conversations(self) -> int:
        """Write all dirty conversations from Redis to PostgreSQL."""
        if not self.redis_enabled:
            return 0

        dirty_list = self.redis_backend.get_dirty_conversations()
        count = 0

        for user_id, conversation_id in dirty_list:
            convo = self.redis_backend.get_conversation(user_id, conversation_id)
            if convo:
                try:
                    self.postgres_backend.save_conversation(conversation_id, user_id, convo)
                    self.redis_backend.clear_dirty_flag(user_id, conversation_id)
                    count += 1
                except Exception as e:
                    print(f"Failed to write back {conversation_id}: {e}")

        return count
```

### 3. Session End Detection

Implement session end detection in `app.py`:

**Option A**: Streamlit `st.on_script_run` callback (if available)
**Option B**: Manual flush button (user-initiated)
**Option C**: Background process monitoring Redis dirty set

```python
# Add to app.py
import atexit

def flush_on_exit():
    """Flush dirty conversations on session end."""
    try:
        count = HISTORY.flush_dirty_conversations()
        print(f"Flushed {count} conversations to PostgreSQL")
    except Exception as e:
        print(f"Flush error: {e}")

# Register cleanup handler
atexit.register(flush_on_exit)

# Optional: Manual flush button in sidebar
if REDIS_ENABLED:
    if st.sidebar.button("💾 Save All to Database"):
        count = HISTORY.flush_dirty_conversations()
        st.sidebar.success(f"Saved {count} conversations!")
```

---

## Azure Infrastructure (Bicep)

### Redis Resource

Add to `deployment/simplified.bicep`:

```bicep
// ======================== Azure Cache for Redis ========================
resource redisCache 'Microsoft.Cache/Redis@2023-08-01' = {
  name: '${resourcePrefix}-redis'
  location: location
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 0  // C0 - 250 MB
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    redisConfiguration: {
      'maxmemory-policy': 'allkeys-lru'  // Evict least recently used keys
    }
  }
}

// Store Redis connection string in Key Vault
resource redisConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  name: 'redis-connection-string'
  parent: keyVault
  properties: {
    value: 'rediss://:${redisCache.listKeys().primaryKey}@${redisCache.properties.hostName}:6380/0?ssl=true'
  }
  dependsOn: [
    keyVaultAccessPolicy
  ]
}
```

### App Settings

Update `appService` app settings:

```bicep
{
  name: 'REDIS_ENABLED'
  value: 'true'
}
{
  name: 'REDIS_CONNECTION_STRING'
  value: '@Microsoft.KeyVault(SecretUri=${redisConnectionStringSecret.properties.secretUri})'
}
```

---

## Environment Configuration

Update `.env.example`:

```bash
# ======================================================================
# Redis Configuration (Phase 2 - Optional)
# ======================================================================

# Enable Redis caching layer (true/false)
REDIS_ENABLED=false

# Redis connection string
# Format: rediss://:<password>@<hostname>:6380/0?ssl=true
REDIS_CONNECTION_STRING=rediss://:password@your-redis.redis.cache.windows.net:6380/0?ssl=true

# Redis cache TTL (seconds) - default: 1800 (30 minutes)
REDIS_CACHE_TTL=1800
```

---

## Deployment Updates

### requirements.txt

Add Redis client:

```
redis==5.0.1
```

### Deployment Script

No changes needed - Redis resources deployed via Bicep, connection string auto-configured.

---

## Performance Optimization

### 1. Batch Operations

Use Redis pipelines for multiple operations:

```python
def set_multiple_conversations(self, convs: List[Tuple[str, str, Dict]]):
    """Batch write multiple conversations."""
    pipe = self.client.pipeline()
    for user_id, conv_id, conv in convs:
        key = f"conv:{user_id}:{conv_id}"
        pipe.hset(key, mapping=self._serialize(conv))
        pipe.expire(key, 1800)
    pipe.execute()
```

### 2. Connection Pooling

Redis client uses connection pooling by default (max_connections=50).

### 3. Compression (Optional)

For large conversations, compress message content:

```python
import zlib
import base64

def _compress_messages(self, messages: List[Dict]) -> str:
    json_str = json.dumps(messages)
    compressed = zlib.compress(json_str.encode())
    return base64.b64encode(compressed).decode()

def _decompress_messages(self, compressed_str: str) -> List[Dict]:
    compressed = base64.b64decode(compressed_str.encode())
    json_str = zlib.decompress(compressed).decode()
    return json.loads(json_str)
```

---

## Monitoring and Metrics

### Key Metrics

1. **Cache Hit Rate**
   - Target: >80%
   - Query: `(redis_hits / (redis_hits + redis_misses)) * 100`

2. **Write-Back Lag**
   - Track size of `dirty:convs` set
   - Alert if > 100 dirty conversations

3. **Redis Memory Usage**
   - Monitor used_memory
   - Alert if > 80% of maxmemory

### Azure Monitor Queries

```kql
// Redis cache hit rate
AzureMetrics
| where ResourceProvider == "MICROSOFT.CACHE"
| where MetricName in ("cachehits", "cachemisses")
| summarize hits = sum(cachehits), misses = sum(cachemisses)
| extend hit_rate = (hits / (hits + misses)) * 100
```

---

## Failure Handling

### Redis Unavailable

Gracefully degrade to direct PostgreSQL access:

```python
def get_conversation(self, conversation_id: str, user_id: str) -> Optional[Dict]:
    if self.redis_enabled:
        try:
            # Try Redis first
            cached = self.redis_backend.get_conversation(user_id, conversation_id)
            if cached:
                return cached
        except redis.ConnectionError:
            print("Redis unavailable, falling back to PostgreSQL")

    # Fallback to PostgreSQL
    return self.postgres_backend.get_conversation(conversation_id, user_id)
```

### Data Consistency

Ensure PostgreSQL is the source of truth:
- On startup, always load from PostgreSQL (not Redis)
- Periodic sync job to detect drift (optional)
- Redis TTL forces refresh from PostgreSQL

---

## Testing Strategy

### Unit Tests

```python
def test_redis_cache_hit():
    """Test that cached conversations are returned from Redis."""
    manager = ChatHistoryManager(mode="postgres", redis_enabled=True)

    # Prime cache
    manager.save_conversation("conv1", test_convo, user_id="user1")

    # Should hit cache
    result = manager.get_conversation("conv1", user_id="user1")
    assert result == test_convo

def test_redis_write_back():
    """Test that dirty conversations are flushed to PostgreSQL."""
    manager = ChatHistoryManager(mode="postgres", redis_enabled=True)

    manager.save_conversation("conv1", test_convo, user_id="user1")
    count = manager.flush_dirty_conversations()

    assert count == 1
    # Verify in PostgreSQL
    pg_result = manager.postgres_backend.get_conversation("conv1", "user1")
    assert pg_result == test_convo
```

### Integration Tests

1. Create conversation → verify in Redis
2. Flush → verify in PostgreSQL
3. Clear Redis → reload from PostgreSQL
4. Measure cache hit rate under load

---

## Cost Estimate

### Azure Cache for Redis

- **Basic C0**: $0.027/hour = ~$20/month
- **Basic C1**: $0.055/hour = ~$40/month (1 GB)
- **Standard C1**: $0.110/hour = ~$80/month (HA, replication)

**Recommendation**: Start with Basic C0, upgrade if memory exhausted.

---

## Migration Checklist

Phase 2 Implementation:

- [ ] Add Redis resource to Bicep template
- [ ] Create `RedisBackend` class
- [ ] Update `ChatHistoryManager` with Redis integration
- [ ] Add session end detection / flush mechanism
- [ ] Update requirements.txt with `redis`
- [ ] Add monitoring dashboards
- [ ] Load test with Redis enabled
- [ ] Document rollback procedure

---

## Rollback Plan

If Redis causes issues:

1. Set `REDIS_ENABLED=false` in App Settings
2. App falls back to direct PostgreSQL mode (Phase 1)
3. No data loss (PostgreSQL is source of truth)
4. Delete Redis resources to save costs

---

## Future Enhancements

1. **Async write-back**: Background thread/process
2. **Multi-level caching**: Redis + in-memory LRU cache
3. **Pub/sub for multi-instance**: Sync cache across App Service instances
4. **Redis Cluster**: For > 100K conversations
5. **Geo-replication**: Redis Enterprise for multi-region

---

## Summary

Phase 2 adds Redis as a performance optimization layer:

**Benefits**:
- ✅ Faster conversation loading (< 10ms vs 50-100ms PostgreSQL query)
- ✅ Reduced PostgreSQL load (80%+ cache hit rate)
- ✅ Better user experience (instant conversation switches)

**Trade-offs**:
- ❌ Additional cost (~$20/month)
- ❌ Increased complexity
- ❌ Potential data loss if write-back fails (mitigated by PostgreSQL source of truth)

**When to implement**: After Phase 1 is stable and user load increases.
