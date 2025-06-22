# Sources of Truth in CorroPort Application

## External Sources of Truth (Authoritative)

### 1. **Corrosion Database Cluster**
- **Source**: Corrosion SQLite-based distributed database nodes
- **API Access**: HTTP REST API (ports 8081, 8082, 8083+)
- **Client Module**: `CorroPort.CorrosionClient` (low-level HTTP client)
- **High-level Interface**: `CorroPort.ClusterAPI`
- **Data Types**: 
  - Cluster member information (`__corro_members` table)
  - Message data (`node_messages` table)
  - Database schema and table definitions
- **Location**: Each node runs its own Corrosion instance with local SQLite files (`dev-node1.db`, `dev-node2.db`, etc.)

### 2. **DNS System (Fly.io)**
- **Source**: DNS TXT records for node discovery
- **Query**: `vms.{app_name}.internal` TXT records
- **Access Module**: `CorroPort.NodeDiscovery` GenServer
- **Data Types**: Expected cluster nodes list with regions
- **Cache**: 1-minute cache with automatic refresh
- **Format**: `"machine_id region,machine_id region,..."`

### 3. **Corrosion CLI Commands**
- **Source**: Corrosion binary CLI interface
- **Access Module**: `CorroPort.CorroCLI`
- **Commands**: `cluster members`, `cluster info`, `cluster status`
- **Cache Module**: `CorroPort.CLIMemberStore` (5-minute cache)
- **Data Types**: Active cluster membership information
- **Binary Locations**: `corrosion/corrosion-mac` (dev), `/app/corrosion` (prod)

### 4. **System Environment**
- **Environment Variables**:
  - `NODE_ID`: Node identifier for multi-node setups
  - `FLY_APP_NAME`: Fly.io application name
  - `FLY_PRIVATE_IP`: Private IP address
  - `FLY_MACHINE_ID`: Machine identifier
  - `FLY_REGION`: Region code (ams, fra, iad, etc.)
  - `SECRET_KEY_BASE`: Phoenix secret
  - `PHX_HOST`, `PORT`, `API_PORT`: Web server configuration

### 5. **Corrosion Subscription Stream**
- **Source**: Real-time streaming from Corrosion's subscription API
- **Access Module**: `CorroPort.CorroSubscriber` GenServer
- **Data Types**: Real-time changes to `node_messages` table
- **Connection**: Long-running HTTP streaming connection

## Internal Sources of Truth (State Management)

### 1. **Application Configuration**
- **Modules**: `CorroPort.NodeConfig`
- **Config Files**: 
  - `config/runtime.exs` (production)
  - `config/dev.exs` (development)
  - `config/prod.exs`, `config/test.exs`
- **Data**: Node-specific configuration, ports, paths, environment settings

### 2. **In-Memory GenServer State**

#### **Node Discovery State**
- **Module**: `CorroPort.NodeDiscovery`
- **State**: Expected nodes list, regions, DNS cache status
- **Updates**: DNS queries, PubSub broadcasts

#### **Active Membership State**
- **Module**: `CorroPort.CLIMemberStore` 
- **State**: Current active cluster members from CLI
- **Updates**: Periodic CLI execution (5-minute intervals)

#### **Message Propagation State**
- **Module**: `CorroPort.MessagePropagation`
- **State**: Message acknowledgment tracking, experiment IDs
- **Dependencies**: Wraps `CorroPort.AckTracker`

#### **Acknowledgment Tracking State**
- **Module**: `CorroPort.AckTracker`
- **State**: Latest message being tracked, received acknowledgments
- **Storage**: ETS table (`:ack_tracker`)

#### **System Metrics State**
- **Module**: `CorroPort.SystemMetrics`
- **State**: Current experiment ID, collection status
- **Data**: CPU, memory, process counts, message queue lengths

### 3. **PubSub Event Streams**
- **System**: `Phoenix.PubSub` (CorroPort.PubSub)
- **Topics**:
  - `"node_discovery"`: Expected nodes updates
  - `"cluster_members"`: Active member updates  
  - `"cluster_membership"`: Membership changes
  - `"message_propagation"`: Acknowledgment updates
  - `"ack_events"`: Low-level acknowledgment events

## Persistent Data Sources

### 1. **Analytics SQLite Database**
- **Repository**: `CorroPort.Analytics.Repo` (Ecto)
- **Access**: `CorroPort.AnalyticsStorage` GenServer wrapper
- **Location**: Node-specific files (`analytics/analytics_node1.db`, etc.)
- **Tables**:
  - `topology_snapshots`: Experiment topology data
  - `message_events`: Message timing events
  - `system_metrics`: Performance metrics
- **Purpose**: Experiment data collection, separate from Corrosion cluster

### 2. **Corrosion Configuration Files**
- **Location**: `corrosion/` directory
- **Files**: `config-node1.toml`, `config-node2.toml`, etc.
- **Content**: Database paths, API ports, gossip configuration, bootstrap peers
- **Generated**: By startup scripts, not dynamic

### 3. **Corrosion Subscription Storage**
- **Location**: `corrosion/subscriptions/` directory
- **Files**: SQLite files for subscription state
- **Purpose**: Corrosion's internal subscription management

## Data Flow and Dependencies

### **Hierarchy of Truth**
1. **Corrosion Database** (ultimate source of distributed state)
2. **DNS System** (authoritative node list)
3. **CLI Commands** (current active membership)
4. **Application State** (cached and computed data)
5. **Analytics Database** (experiment tracking)

### **Update Patterns**
- **Real-time**: Corrosion subscription stream → PubSub → LiveViews
- **Periodic**: DNS queries (1min), CLI commands (5min), system metrics (5sec during experiments)
- **Event-driven**: Message sends → acknowledgment tracking → analytics recording

### **Configuration Flow**
- Environment variables → Application config → Node-specific configuration → Corrosion config files

## Notes
- The Corrosion database cluster is the ultimate source of truth for distributed state
- DNS and CLI provide discovery and membership information
- Application state provides caching and real-time propagation
- Analytics database tracks experiments separately from main cluster data