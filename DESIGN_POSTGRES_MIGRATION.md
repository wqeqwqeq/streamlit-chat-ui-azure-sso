# Design Document: Azure PostgreSQL Chat History Migration

**Version:** 1.1
**Date:** 2025-11-11
**Author:** Design Document for DAPE OpsAgent Manager
**Last Updated:** 2025-11-11 - Added explicit Entra ID SSO integration details

---

## 1. Executive Summary

This document outlines the design for migrating the DAPE OpsAgent Manager's chat history persistence layer from local JSON file storage to Azure PostgreSQL Flexible Server. The migration will enable multi-user support, improved scalability, and better data management capabilities.

### Key Objectives
- Store all chat conversations in Azure PostgreSQL instead of local JSON files
- **Associate each conversation with user's Entra ID identity** (via `X-MS-CLIENT-PRINCIPAL-ID` header)
- **Implement user isolation**: Each user sees only their own conversations
- Fetch and display only the last 14 days of chat history per user
- Maintain all existing chat metadata (title, model, messages, timestamps)
- Store user display names (email/UPN) for audit and display purposes
- Support seamless migration path from existing JSON storage

### Key Features of Entra ID Integration
- **Automatic SSO**: Azure App Service Easy Auth handles Entra ID authentication
- **Header-based identity**: User identity extracted from `X-MS-CLIENT-PRINCIPAL-ID` (GUID) and `X-MS-CLIENT-PRINCIPAL-NAME` (email/UPN)
- **Database-level isolation**: All queries filtered by user's Entra ID GUID
- **No authentication code required**: Easy Auth middleware handles token validation

---

## 2. Authentication & User Identity (Entra ID SSO)

### 2.1 SSO Integration Overview
The application is integrated with **Azure Entra ID (formerly Azure Active Directory)** through Azure App Service's built-in **Easy Auth** feature. When users access the application, they are automatically authenticated via Entra ID SSO before reaching the Streamlit app.

### 2.2 User Identity Extraction
After successful Entra ID authentication, Azure App Service injects authentication headers into every HTTP request to the Streamlit application. The app extracts user identity from these headers:

```python
def get_user_info() -> Dict[str, str]:
    """Extract user information from SSO headers."""
    headers = st.context.headers

    # Azure Easy Auth injects these headers after Entra ID authentication
    user_name = headers.get('X-MS-CLIENT-PRINCIPAL-NAME')  # User's email/UPN
    user_id = headers.get('X-MS-CLIENT-PRINCIPAL-ID')      # Unique user identifier (GUID)

    return {
        'user_id': user_id,          # e.g., "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        'user_name': user_name,      # e.g., "john.doe@contoso.com"
        'is_authenticated': bool(user_id and user_name)
    }
```

**Key Headers:**
- **`X-MS-CLIENT-PRINCIPAL-NAME`**: User's email or User Principal Name (UPN) from Entra ID
- **`X-MS-CLIENT-PRINCIPAL-ID`**: Unique identifier (GUID) for the user in Entra ID tenant
  - This is the primary key for user identity
  - Stable across sessions and remains constant even if email changes
  - Format: UUID (e.g., `a1b2c3d4-e5f6-7890-abcd-ef1234567890`)

### 2.3 Authentication Flow

```
User Browser
    │
    ├─► Azure App Service (Easy Auth)
    │       │
    │       ├─► Redirect to Entra ID login
    │       │
    │       ├─► User authenticates with Entra ID credentials
    │       │
    │       ├─► Entra ID returns authentication token
    │       │
    │       └─► Easy Auth validates token & injects headers
    │
    └─► Streamlit App
            │
            ├─► Extract X-MS-CLIENT-PRINCIPAL-ID (user_client_id)
            ├─► Extract X-MS-CLIENT-PRINCIPAL-NAME (user_name)
            │
            └─► Load user-specific chat history from PostgreSQL
                    WHERE user_client_id = <X-MS-CLIENT-PRINCIPAL-ID>
```

### 2.4 Complete Data Flow: Entra ID to Database

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. User Login                                                        │
│    User accesses: https://app.azurewebsites.net                     │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. Azure App Service Easy Auth                                       │
│    - Redirects to Entra ID login page                               │
│    - User authenticates with Entra ID credentials                   │
│    - Entra ID returns token with user claims                        │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. Easy Auth Injects Headers                                         │
│    X-MS-CLIENT-PRINCIPAL-ID: "550e8400-e29b-41d4-a716-446655440000" │
│    X-MS-CLIENT-PRINCIPAL-NAME: "john.doe@contoso.com"               │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. Streamlit App Extracts Headers                                    │
│    user_id = headers.get('X-MS-CLIENT-PRINCIPAL-ID')                │
│    user_name = headers.get('X-MS-CLIENT-PRINCIPAL-NAME')            │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. Load User's Chat History                                          │
│    HISTORY.list_conversations(user_id)                              │
│                                                                       │
│    SQL Query:                                                         │
│    SELECT * FROM conversations                                        │
│    WHERE user_client_id = '550e8400-e29b-41d4-a716-446655440000'    │
│      AND last_modified >= NOW() - INTERVAL '14 days'                │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. User Sees Only Their Conversations                                │
│    - Isolated by Entra ID GUID                                       │
│    - Last 14 days only                                               │
│    - No access to other users' data                                  │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.5 Local Development Fallback
When running locally without Entra ID SSO (headers not present), the app uses a fallback:
```python
# If headers are missing (local development)
user_client_id = user_info.get('user_id') or 'local_user'
```

This allows developers to test the application without requiring Entra ID authentication.

**Production Behavior**: In production with Easy Auth enabled, the headers are **always present** because Easy Auth middleware runs before the Streamlit app receives any requests. Unauthenticated users are automatically redirected to Entra ID login and never reach the application.

---

## 3. Current Architecture

### 3.1 Existing Storage Model
Currently, `ChatHistoryManager` stores conversations as JSON files in `.chat_history/`:
```
.chat_history/
  ├── a1b2c3d4.json
  ├── e5f6g7h8.json
  └── ...
```

Each JSON file contains:
```json
{
  "title": "string",
  "model": "string",
  "messages": [
    {
      "role": "user|assistant",
      "content": "string",
      "time": "ISO8601 timestamp"
    }
  ],
  "created_at": "ISO8601 timestamp",
  "last_modified": "ISO8601 timestamp"
}
```

**Critical Limitation:** JSON files are **not associated with any user identity**. In a multi-user environment with Entra ID SSO, all users would see the same conversations, which is a major security and privacy issue.

### 3.2 Current Limitations
- **No user isolation**: All conversations shared across all users (security vulnerability)
- **No integration with Entra ID identity**: User's client ID not stored with conversations
- No filtering by date range
- Limited scalability for concurrent users
- No backup/restore capabilities beyond file system
- No query optimization for large conversation sets

---

## 4. Target Architecture

### 4.1 Database Schema

#### 4.1.1 Tables

**Table: `conversations`**
```sql
CREATE TABLE conversations (
    conversation_id VARCHAR(36) PRIMARY KEY,  -- UUID generated by Streamlit app (e.g., "a1b2c3d4")
    user_client_id VARCHAR(255) NOT NULL,     -- Entra ID user GUID from X-MS-CLIENT-PRINCIPAL-ID header
    user_display_name VARCHAR(500),           -- User's email/name from X-MS-CLIENT-PRINCIPAL-NAME (optional, for display)
    title VARCHAR(500) NOT NULL,
    model VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    last_modified TIMESTAMPTZ NOT NULL,

    -- Indexes for common queries
    INDEX idx_user_last_modified (user_client_id, last_modified DESC),
    INDEX idx_created_at (created_at)
);

-- Example data:
-- conversation_id: "a1b2c3d4"
-- user_client_id: "550e8400-e29b-41d4-a716-446655440000" (from Entra ID)
-- user_display_name: "john.doe@contoso.com"
-- title: "Database migration discussion"
-- model: "gpt-4o-mini"
```

**Column Details:**
- **`conversation_id`**: Unique identifier for each conversation
  - Generated by Streamlit app: `str(uuid.uuid4())[:8]`
  - Current implementation uses 8 characters, but schema supports up to 36 for full UUID
- **`user_client_id`**: **Primary user identifier from Entra ID**
  - **Source**: `X-MS-CLIENT-PRINCIPAL-ID` header injected by Azure Easy Auth
  - **Format**: GUID/UUID (e.g., `550e8400-e29b-41d4-a716-446655440000`)
  - **Purpose**: Isolates conversations per user, ensures data privacy
  - **Stability**: Remains constant even if user's email/name changes in Entra ID
- **`user_display_name`**: User-friendly display name (optional)
  - **Source**: `X-MS-CLIENT-PRINCIPAL-NAME` header (email or UPN)
  - **Purpose**: Display purposes only, not used for authorization
  - **Example**: `john.doe@contoso.com` or `John Doe`

**Table: `messages`**
```sql
CREATE TABLE messages (
    message_id SERIAL PRIMARY KEY,
    conversation_id VARCHAR(36) NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL,
    time TIMESTAMPTZ NOT NULL,
    sequence_number INT NOT NULL,  -- Order within conversation

    -- Indexes
    INDEX idx_conversation_sequence (conversation_id, sequence_number),
    UNIQUE (conversation_id, sequence_number)
);
```

#### 4.1.2 Schema Rationale

**Why separate messages table?**
- Normalized design allows efficient querying of individual messages
- Better performance for large conversations (thousands of messages)
- Enables future features: message search, edit history, reactions
- Reduces data duplication

**Why store `user_display_name` in conversations table?**
- **Display purposes**: Show conversation owner in admin/audit interfaces
- **Audit trail**: Historical record even if user is deleted from Entra ID
- **Performance**: Avoids lookups to Entra ID API for display name
- **Not for authorization**: Always use `user_client_id` for access control
- **Optional field**: Can be NULL if header not available

**Why `user_client_id` (Entra ID GUID) instead of email?**
- **Stability**: User's email can change, but GUID remains constant
- **Uniqueness**: Guaranteed unique across Entra ID tenant
- **Security**: Email addresses can be reassigned to different users
- **Standards compliance**: Aligns with Azure/Microsoft identity best practices

**Why `sequence_number`?**
- Guarantees message ordering independent of timestamps
- Allows for message insertion between existing messages (future feature)
- Simplifies pagination and offset queries

**Why `TIMESTAMPTZ`?**
- Timezone-aware timestamps ensure consistency across deployments
- UTC storage with automatic timezone conversion

**Why VARCHAR(36) for conversation_id?**
- Current implementation uses 8-char UUIDs: `str(uuid.uuid4())[:8]`
- Design allows expansion to full UUID (36 chars) for better uniqueness
- Prevents ID collision issues at scale

---

## 5. API Design

### 5.1 Updated ChatHistoryManager

```python
class ChatHistoryManager:
    """Persist and retrieve chat histories.

    Modes:
      - "local": Store each conversation as a JSON file under .chat_history/
      - "postgres": Store conversations in Azure PostgreSQL
    """

    def __init__(
        self,
        mode: str = "local",
        base_dir: Optional[Path | str] = None,
        connection_string: Optional[str] = None,
        days_to_fetch: int = 14
    ) -> None:
        """
        Args:
            mode: Storage backend ("local" or "postgres")
            base_dir: Base directory for local mode
            connection_string: PostgreSQL connection string for postgres mode
            days_to_fetch: Number of days of history to fetch (default: 14)
        """
```

### 5.2 Modified Public API

```python
# Updated method signatures
def list_conversations(self, user_client_id: str) -> List[Tuple[str, Dict]]:
    """Return list of (conversation_id, conversation) for a specific user.

    In postgres mode, only returns conversations from the last N days
    (configured via days_to_fetch parameter).

    Args:
        user_client_id: User's Entra ID GUID from X-MS-CLIENT-PRINCIPAL-ID header
            Example: "550e8400-e29b-41d4-a716-446655440000"

    Returns:
        List of (conversation_id, conversation_dict) tuples
        Only returns conversations belonging to the specified user
    """

def get_conversation(self, conversation_id: str, user_client_id: str) -> Optional[Dict]:
    """Load a single conversation.

    Args:
        conversation_id: Unique conversation identifier
        user_client_id: User's Entra ID GUID (for authorization check)
            Must match the user who created the conversation

    Returns:
        Conversation dict or None if not found/unauthorized
        Returns None if conversation belongs to different user
    """

def save_conversation(
    self,
    conversation_id: str,
    user_client_id: str,
    conversation: Dict,
    user_display_name: Optional[str] = None
) -> None:
    """Persist a conversation to storage.

    Args:
        conversation_id: Unique conversation identifier
        user_client_id: User's Entra ID GUID from X-MS-CLIENT-PRINCIPAL-ID
        conversation: Conversation data dict (title, model, messages, timestamps)
        user_display_name: User's email/name from X-MS-CLIENT-PRINCIPAL-NAME (optional)
            Example: "john.doe@contoso.com"
    """

def delete_conversation(self, conversation_id: str, user_client_id: str) -> None:
    """Remove a conversation from storage.

    Args:
        conversation_id: Unique conversation identifier
        user_client_id: User's Entra ID GUID (for authorization check)
            Prevents users from deleting other users' conversations
    """
```

### 5.3 PostgreSQL Implementation Details

#### 5.3.1 Connection Management
```python
import psycopg2
from psycopg2.pool import SimpleConnectionPool

class PostgreSQLBackend:
    def __init__(self, connection_string: str, days_to_fetch: int = 14):
        self.pool = SimpleConnectionPool(
            minconn=1,
            maxconn=10,
            dsn=connection_string
        )
        self.days_to_fetch = days_to_fetch

    def get_connection(self):
        return self.pool.getconn()

    def release_connection(self, conn):
        self.pool.putconn(conn)
```

#### 5.3.2 List Conversations Query
```sql
-- Fetch conversations from last 14 days for specific Entra ID user, ordered by last_modified DESC
SELECT
    c.conversation_id,
    c.user_client_id,
    c.user_display_name,
    c.title,
    c.model,
    c.created_at,
    c.last_modified,
    json_agg(
        json_build_object(
            'role', m.role,
            'content', m.content,
            'time', m.time
        ) ORDER BY m.sequence_number
    ) as messages
FROM conversations c
LEFT JOIN messages m ON c.conversation_id = m.conversation_id
WHERE c.user_client_id = %s  -- Entra ID GUID from X-MS-CLIENT-PRINCIPAL-ID
  AND c.last_modified >= NOW() - INTERVAL '14 days'
GROUP BY c.conversation_id
ORDER BY c.last_modified DESC;
```

**Query Explanation:**
- **WHERE clause filters by `user_client_id`**: Ensures user only sees their own conversations (Entra ID isolation)
- **14-day window**: `c.last_modified >= NOW() - INTERVAL '14 days'`
- **JOIN with messages**: Fetches all messages in a single query for performance
- **json_agg**: Aggregates messages into JSON array, preserving order via `sequence_number`

#### 5.3.3 Save Conversation Logic
```python
def save_conversation(
    self,
    conversation_id: str,
    user_client_id: str,
    conversation: Dict,
    user_display_name: Optional[str] = None
) -> None:
    """
    Save conversation with Entra ID user association.

    Args:
        user_client_id: Entra ID GUID from X-MS-CLIENT-PRINCIPAL-ID
        user_display_name: Email/name from X-MS-CLIENT-PRINCIPAL-NAME
    """
    conn = self.get_connection()
    try:
        with conn.cursor() as cur:
            # Upsert conversation metadata with Entra ID user info
            cur.execute("""
                INSERT INTO conversations
                    (conversation_id, user_client_id, user_display_name, title, model, created_at, last_modified)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (conversation_id)
                DO UPDATE SET
                    user_display_name = EXCLUDED.user_display_name,
                    title = EXCLUDED.title,
                    model = EXCLUDED.model,
                    last_modified = EXCLUDED.last_modified;
            """, (
                conversation_id,
                user_client_id,
                user_display_name,  # Store user's display name for audit/display
                conversation['title'],
                conversation['model'],
                conversation['created_at'],
                conversation['last_modified']
            ))

            # Delete existing messages and re-insert (simpler than diff logic)
            cur.execute(
                "DELETE FROM messages WHERE conversation_id = %s",
                (conversation_id,)
            )

            # Insert messages with sequence numbers
            for idx, msg in enumerate(conversation['messages']):
                cur.execute("""
                    INSERT INTO messages
                        (conversation_id, role, content, time, sequence_number)
                    VALUES (%s, %s, %s, %s, %s);
                """, (
                    conversation_id,
                    msg['role'],
                    msg['content'],
                    msg['time'],
                    idx
                ))

            conn.commit()
    except Exception as e:
        conn.rollback()
        raise
    finally:
        self.release_connection(conn)
```

---

## 6. Application Changes

### 6.1 app.py Modifications

#### 6.1.1 Initialization
```python
# Current
HISTORY = ChatHistoryManager(mode="local")

# Updated
HISTORY = ChatHistoryManager(
    mode=os.getenv("CHAT_HISTORY_MODE", "local"),
    connection_string=os.getenv("POSTGRES_CONNECTION_STRING"),
    days_to_fetch=14
)
```

#### 6.1.2 User Context Integration
All HISTORY method calls must now pass **both** `user_client_id` and `user_display_name` from Entra ID headers:

```python
def ensure_state() -> None:
    # Get user info first - extracts from X-MS-CLIENT-PRINCIPAL-* headers
    if "user_info" not in st.session_state:
        st.session_state.user_info = get_user_info()

    # Extract Entra ID user identifiers
    user_id = st.session_state.user_info.get('user_id', 'local_user')  # X-MS-CLIENT-PRINCIPAL-ID
    user_name = st.session_state.user_info.get('user_name')            # X-MS-CLIENT-PRINCIPAL-NAME

    if "conversations" not in st.session_state:
        st.session_state.conversations = {}
        # Load from persistent storage - now user-specific based on Entra ID GUID
        for cid, convo in HISTORY.list_conversations(user_id):
            st.session_state.conversations[cid] = convo
    # ... rest of function
```

#### 6.1.3 Save/Delete Operations
```python
# Save example - passes both user_client_id and user_display_name
user_info = st.session_state.user_info
HISTORY.save_conversation(
    conversation_id=st.session_state.current_id,
    user_client_id=user_info.get('user_id', 'local_user'),      # Entra ID GUID
    conversation=st.session_state.conversations[cid],
    user_display_name=user_info.get('user_name')                # Email/UPN (optional)
)

# Delete example - authorization via user_client_id
HISTORY.delete_conversation(
    conversation_id=cid,
    user_client_id=user_info.get('user_id', 'local_user')
)

# Get conversation example - authorization check
conversation = HISTORY.get_conversation(
    conversation_id=cid,
    user_client_id=user_info.get('user_id', 'local_user')
)
```

#### 6.1.4 Helper Function for User Context
```python
def get_user_context() -> Tuple[str, Optional[str]]:
    """
    Extract user context from Entra ID SSO headers with fallback for local mode.

    Returns:
        Tuple of (user_client_id, user_display_name)
        - user_client_id: Entra ID GUID or 'local_user' for development
        - user_display_name: Email/UPN or None
    """
    user_info = st.session_state.get('user_info', {})
    user_client_id = user_info.get('user_id') or 'local_user'
    user_display_name = user_info.get('user_name')
    return user_client_id, user_display_name

# Usage example
user_id, user_name = get_user_context()
HISTORY.save_conversation(cid, user_id, conversation, user_name)
```

### 6.2 Fallback for Local Mode
When running without SSO (local development), the app gracefully falls back to a default user:

```python
# In get_user_info() - already implemented in app.py
def get_user_info() -> Dict[str, str]:
    """Extract user information from SSO headers."""
    try:
        headers = st.context.headers
        user_name = headers.get('X-MS-CLIENT-PRINCIPAL-NAME')
        user_id = headers.get('X-MS-CLIENT-PRINCIPAL-ID')

        return {
            'user_id': user_id,           # Will be None in local mode
            'user_name': user_name,       # Will be None in local mode
            'is_authenticated': bool(user_id and user_name)
        }
    except Exception as e:
        # Fallback for local development
        return {
            'user_id': None,
            'user_name': None,
            'is_authenticated': False
        }

# All database operations use: user_info.get('user_id') or 'local_user'
# This ensures local dev works without requiring Entra ID authentication
```

**Important**: In production with Entra ID enabled, `user_id` will **always** be present due to Easy Auth middleware. The fallback is only for local development.

---

## 7. Azure Infrastructure

### 7.1 Required Azure Resources

#### 7.1.1 Azure PostgreSQL Flexible Server
```bicep
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-03-01' = {
  name: '${resourcePrefix}-postgres'
  location: location
  sku: {
    name: 'Standard_B2s'  // Burstable tier for dev/test
    tier: 'Burstable'
  }
  properties: {
    version: '15'
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'  // Enable for production
    }
  }
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-03-01' = {
  name: 'chat_history'
  parent: postgresServer
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}
```

#### 7.1.2 Firewall Rules
```bicep
// Allow Azure services
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-03-01' = {
  name: 'AllowAzureServices'
  parent: postgresServer
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// VNet integration (recommended for production)
resource postgresVnetRule 'Microsoft.DBforPostgreSQL/flexibleServers/virtualNetworkRules@2023-03-01' = {
  name: 'appServiceVnetRule'
  parent: postgresServer
  properties: {
    virtualNetworkSubnetId: appSubnet.id
  }
}
```

### 7.2 Connection String Management

Store connection string in Key Vault:
```bicep
resource postgresConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  name: 'postgres-connection-string'
  parent: keyVault
  properties: {
    value: 'postgresql://${postgresAdminLogin}:${postgresAdminPassword}@${postgresServer.properties.fullyQualifiedDomainName}:5432/chat_history?sslmode=require'
  }
}
```

App Service configuration:
```bicep
resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  // ... existing properties
  properties: {
    siteConfig: {
      appSettings: [
        {
          name: 'CHAT_HISTORY_MODE'
          value: 'postgres'
        }
        {
          name: 'POSTGRES_CONNECTION_STRING'
          value: '@Microsoft.KeyVault(SecretUri=${postgresConnectionStringSecret.properties.secretUri})'
        }
      ]
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
}
```

### 7.3 Database Initialization

Create a deployment script (`deployment/init_postgres.sql`):
```sql
-- Create tables
CREATE TABLE IF NOT EXISTS conversations (
    conversation_id VARCHAR(36) PRIMARY KEY,
    user_client_id VARCHAR(255) NOT NULL,     -- Entra ID GUID from X-MS-CLIENT-PRINCIPAL-ID
    user_display_name VARCHAR(500),           -- User's email/name from X-MS-CLIENT-PRINCIPAL-NAME
    title VARCHAR(500) NOT NULL,
    model VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    last_modified TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    message_id SERIAL PRIMARY KEY,
    conversation_id VARCHAR(36) NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL,
    time TIMESTAMPTZ NOT NULL,
    sequence_number INT NOT NULL,
    UNIQUE (conversation_id, sequence_number)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_user_last_modified
    ON conversations(user_client_id, last_modified DESC);

CREATE INDEX IF NOT EXISTS idx_created_at
    ON conversations(created_at);

CREATE INDEX IF NOT EXISTS idx_conversation_sequence
    ON messages(conversation_id, sequence_number);

-- Grant permissions (if using separate app user)
GRANT SELECT, INSERT, UPDATE, DELETE ON conversations TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON messages TO app_user;
GRANT USAGE, SELECT ON SEQUENCE messages_message_id_seq TO app_user;
```

Deployment step:
```bash
# Run during Azure deployment
psql "$POSTGRES_CONNECTION_STRING" -f deployment/init_postgres.sql
```

---

## 8. Migration Strategy

### 8.1 Migration Phases

#### Phase 1: Database Setup (Pre-deployment)
1. Provision Azure PostgreSQL Flexible Server
2. Create database and tables using `init_postgres.sql`
3. Configure firewall rules and VNet integration
4. Store connection string in Key Vault
5. Test connectivity from App Service

#### 8.1.2 Phase 2: Code Implementation
1. Implement PostgreSQL backend in `ChatHistoryManager`
2. Update all method signatures to accept `user_client_id`
3. Modify `app.py` to pass user context to all HISTORY calls
4. Add environment variable configuration
5. Implement fallback logic for local development

#### 8.1.3 Phase 3: Data Migration
1. Create migration script (`scripts/migrate_to_postgres.py`):
```python
#!/usr/bin/env python3
"""
Migrate existing JSON chat history to PostgreSQL.
"""
import json
import os
from pathlib import Path
from chat_history_manager import ChatHistoryManager

def migrate_json_to_postgres():
    # Initialize both managers
    local_mgr = ChatHistoryManager(mode="local")
    postgres_mgr = ChatHistoryManager(
        mode="postgres",
        connection_string=os.getenv("POSTGRES_CONNECTION_STRING")
    )

    # Default user for migrated conversations
    # In production, may need to assign to actual users
    default_user = os.getenv("MIGRATION_DEFAULT_USER", "migrated_user")

    # Load all local conversations
    conversations = local_mgr.list_conversations()

    print(f"Found {len(conversations)} conversations to migrate")

    for cid, convo in conversations:
        try:
            postgres_mgr.save_conversation(cid, default_user, convo)
            print(f"✓ Migrated conversation {cid}: {convo['title']}")
        except Exception as e:
            print(f"✗ Failed to migrate {cid}: {e}")

    print("Migration complete")

if __name__ == "__main__":
    migrate_json_to_postgres()
```

2. Run migration script in staging environment
3. Verify data integrity
4. Backup JSON files before deployment

#### 8.1.4 Phase 4: Deployment
1. Deploy updated application to Azure App Service
2. Set environment variables:
   - `CHAT_HISTORY_MODE=postgres`
   - `POSTGRES_CONNECTION_STRING` (from Key Vault)
3. Monitor logs for errors
4. Verify user-specific chat history loading

#### 8.1.5 Phase 5: Validation & Cleanup
1. Test multi-user isolation
2. Verify 14-day filtering
3. Performance testing with concurrent users
4. Archive/delete old JSON files after validation period

### 8.2 Rollback Plan
If issues arise:
1. Set `CHAT_HISTORY_MODE=local` in App Service config
2. Restart application (falls back to JSON files)
3. Diagnose PostgreSQL issues
4. Re-attempt deployment after fixes

---

## 9. Security Considerations

### 9.1 User Isolation
- All queries filter by `user_client_id` to prevent cross-user data access
- Authorization checks in `get_conversation` and `delete_conversation`
- No API endpoints expose conversation listing across users

### 9.2 Connection Security
- Use SSL/TLS for all PostgreSQL connections (`sslmode=require`)
- Store credentials in Azure Key Vault (not in code/config files)
- Use Managed Identity for Key Vault access
- Rotate database passwords quarterly

### 9.3 SQL Injection Prevention
- Use parameterized queries exclusively (via psycopg2 `%s` placeholders)
- Never concatenate user input into SQL strings
- Validate conversation_id format (UUID pattern)

### 9.4 Data Privacy
- Consider encryption at rest (Azure PostgreSQL supports it)
- Implement data retention policy (auto-delete conversations > 90 days)
- Add audit logging for sensitive operations (delete, export)

---

## 10. Performance Considerations

### 10.1 Indexing Strategy
- Index on `(user_client_id, last_modified DESC)`: Optimizes list_conversations query
- Index on `(conversation_id, sequence_number)`: Fast message retrieval in order
- Index on `created_at`: Supports retention policy cleanup queries

### 9.2 Connection Pooling
- Use `psycopg2.pool.SimpleConnectionPool` (min=1, max=10 connections)
- Prevents connection exhaustion under load
- Reuses connections across requests

### 10.3 Query Optimization
- Single query to fetch conversation + messages (JOIN with json_agg)
- 14-day filter reduces data transfer and processing
- LIMIT clauses for pagination (future enhancement)

### 10.4 Caching Strategy (Future)
- Cache recent conversations in Redis
- Invalidate cache on save/delete operations
- Reduces database load for active users

### 10.5 Monitoring
- Enable Azure Monitor for PostgreSQL
- Track query performance (slow query log)
- Monitor connection pool utilization
- Alert on error rates

---

## 11. Testing Strategy

### 15.1 Unit Tests
```python
# tests/test_chat_history_manager_postgres.py
import pytest
from chat_history_manager import ChatHistoryManager

@pytest.fixture
def postgres_manager():
    return ChatHistoryManager(
        mode="postgres",
        connection_string=os.getenv("TEST_POSTGRES_CONNECTION_STRING")
    )

def test_save_and_retrieve_conversation(postgres_manager):
    user_id = "test_user_123"
    conversation = {
        "title": "Test Chat",
        "model": "gpt-4o-mini",
        "messages": [
            {"role": "user", "content": "Hello", "time": "2025-01-01T00:00:00Z"}
        ],
        "created_at": "2025-01-01T00:00:00Z",
        "last_modified": "2025-01-01T00:00:00Z"
    }

    cid = "test-conv-1"
    postgres_manager.save_conversation(cid, user_id, conversation)

    retrieved = postgres_manager.get_conversation(cid, user_id)
    assert retrieved is not None
    assert retrieved["title"] == "Test Chat"
    assert len(retrieved["messages"]) == 1

def test_user_isolation(postgres_manager):
    cid = "test-conv-2"
    user1 = "user_1"
    user2 = "user_2"

    conversation = {
        "title": "User 1 Chat",
        "model": "gpt-4o-mini",
        "messages": [],
        "created_at": "2025-01-01T00:00:00Z",
        "last_modified": "2025-01-01T00:00:00Z"
    }

    postgres_manager.save_conversation(cid, user1, conversation)

    # User 2 should not be able to access User 1's conversation
    retrieved = postgres_manager.get_conversation(cid, user2)
    assert retrieved is None

def test_14_day_filtering(postgres_manager):
    # Create conversations with different timestamps
    # Verify only last 14 days returned
    # ...
```

### 15.2 Integration Tests
- Test full app.py flow with PostgreSQL backend
- Multi-user scenarios
- Concurrent access
- Error handling (connection failures, timeouts)

### 12.3 Load Testing
```bash
# Use locust or similar tool
locust -f tests/load_test.py --host=https://your-app.azurewebsites.net
```

---

## 12. Future Enhancements

### 15.1 Short-term (Next 3 months)
- Add conversation search by title/content
- Export conversation to JSON/PDF
- Conversation sharing between users
- Message edit/delete functionality

### 15.2 Medium-term (3-6 months)
- Redis caching layer
- Full-text search with PostgreSQL `tsvector`
- Conversation tags/categories
- Analytics dashboard (usage metrics)

### 12.3 Long-term (6+ months)
- Multi-region replication
- Conversation branching (ChatGPT-style)
- Conversation templates
- AI-powered conversation summarization

---

## 13. Dependencies

### 15.1 Python Packages
Add to `requirements.txt`:
```
psycopg2-binary>=2.9.9
python-dotenv>=1.0.0  # For local development env vars
```

Add to `pyproject.toml`:
```toml
[project]
dependencies = [
    "streamlit>=1.28.0",
    "psycopg2-binary>=2.9.9",
    "python-dotenv>=1.0.0",
]
```

### 15.2 Azure Resources
- Azure PostgreSQL Flexible Server (Standard_B2s or higher)
- Azure Key Vault (existing)
- App Service with Managed Identity (existing)
- Application Insights (existing)

---

## 14. Cost Estimation

### 15.1 Azure PostgreSQL Flexible Server
- **Compute**: Standard_B2s (2 vCores, 4 GB RAM)
  - Cost: ~$50-70/month (burstable tier)
  - Production: Standard_D2ds_v4 (~$150-200/month)

- **Storage**: 32 GB
  - Cost: ~$4/month
  - Scales automatically up to 16 TB

- **Backup**: 7-day retention
  - Included in base cost

- **Network**: Outbound data transfer
  - First 5 GB free, then ~$0.087/GB

### 15.2 Total Estimated Cost
- **Development/Test**: ~$55-75/month
- **Production**: ~$155-205/month

### 15.3 Cost Optimization
- Use burstable tier for dev/staging
- Enable auto-pause for non-production (future feature)
- Implement data retention policy (delete old conversations)
- Monitor storage growth and adjust

---

## 15. Success Metrics

### 15.1 Functional Metrics
- 100% of conversations stored in PostgreSQL
- Zero data loss during migration
- User isolation: 0 cross-user data access incidents
- 14-day filtering: Correct data returned

### 15.2 Performance Metrics
- List conversations: < 500ms (p95)
- Save conversation: < 200ms (p95)
- Get conversation: < 300ms (p95)
- Database CPU utilization: < 70% average

### 15.3 Reliability Metrics
- Uptime: 99.9%
- Failed queries: < 0.1%
- Connection pool exhaustion: 0 incidents

---

## 16. Timeline

| Phase | Duration | Key Milestones |
|-------|----------|----------------|
| Database Setup | 1 week | PostgreSQL provisioned, tables created |
| Code Implementation | 2 weeks | ChatHistoryManager updated, app.py modified |
| Testing | 1 week | Unit tests, integration tests, load tests |
| Data Migration | 3 days | JSON data migrated to PostgreSQL |
| Deployment | 2 days | Staging deployment, validation |
| Production Release | 1 day | Production deployment, monitoring |
| Validation & Cleanup | 1 week | Post-deployment validation, cleanup |

**Total Estimated Time**: 5-6 weeks

---

## 17. Risks & Mitigations

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Data loss during migration | High | Low | Backup JSON files, test migration in staging |
| PostgreSQL connection issues | High | Medium | Connection pooling, retry logic, fallback to local mode |
| User ID not available (SSO failure) | Medium | Low | Fallback to "local_user" for local dev |
| Performance degradation | Medium | Medium | Indexing, query optimization, load testing |
| Cost overrun | Low | Medium | Monitor usage, implement retention policy |

---

## 18. Appendix

### 18.1 Configuration Examples

**Local Development (.env file)**
```bash
CHAT_HISTORY_MODE=local
# Or for local PostgreSQL testing:
# CHAT_HISTORY_MODE=postgres
# POSTGRES_CONNECTION_STRING=postgresql://user:pass@localhost:5432/chat_history
```

**Azure App Service (Environment Variables)**
```bash
CHAT_HISTORY_MODE=postgres
POSTGRES_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=https://your-kv.vault.azure.net/secrets/postgres-connection-string)
```

### 18.2 Useful SQL Queries

**Count conversations per user**
```sql
SELECT user_client_id, COUNT(*) as conversation_count
FROM conversations
GROUP BY user_client_id
ORDER BY conversation_count DESC;
```

**Find large conversations (many messages)**
```sql
SELECT c.conversation_id, c.title, COUNT(m.message_id) as message_count
FROM conversations c
JOIN messages m ON c.conversation_id = m.conversation_id
GROUP BY c.conversation_id
ORDER BY message_count DESC
LIMIT 10;
```

**Delete conversations older than 90 days**
```sql
DELETE FROM conversations
WHERE last_modified < NOW() - INTERVAL '90 days';
```

### 18.3 References
- [Azure PostgreSQL Flexible Server Documentation](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/)
- [psycopg2 Documentation](https://www.psycopg.org/docs/)
- [Streamlit Session State](https://docs.streamlit.io/library/api-reference/session-state)
- [Azure Easy Auth Headers](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-customize-sign-in-out)

---

## Changelog

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Design Team | Initial design document |
| 1.1 | 2025-11-11 | Design Team | Added explicit Entra ID SSO integration details:<br>- New section 2: Authentication & User Identity<br>- Added `user_display_name` column to schema<br>- Updated all API signatures to include user display name<br>- Added complete data flow diagram<br>- Enhanced documentation of header extraction<br>- Clarified user isolation mechanisms |

---

**Document Status**: Draft for Review
**Next Review Date**: Upon implementation completion
