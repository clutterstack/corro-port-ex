-- Updated schema with region field
CREATE TABLE node_messages (
  pk TEXT PRIMARY KEY NOT NULL DEFAULT '',
  node_id TEXT NOT NULL DEFAULT 'no_id',
  message TEXT NOT NULL DEFAULT '',
  sequence INTEGER NOT NULL DEFAULT 0,
  timestamp TEXT NOT NULL DEFAULT 0,
  originating_endpoint TEXT NOT NULL DEFAULT '127.0.0.1:5001',  -- IP:PORT for direct API communication
  region TEXT NOT NULL DEFAULT 'unknown'  -- Fly.io region code (e.g., 'ams', 'iad', 'fra')
);

-- Performance index for subscription queries and message listing
-- Using DESC order to optimize "ORDER BY sequence DESC LIMIT N" queries
CREATE INDEX IF NOT EXISTS idx_node_messages_sequence_desc
ON node_messages(sequence DESC);