-- Replace or add to existing schema
CREATE TABLE node_messages (
  pk TEXT PRIMARY KEY NOT NULL DEFAULT '',   -- Keep pk for consistency with existing pattern
  node_id TEXT NOT NULL DEFAULT 'no_id',        -- Same as pk but clearer
  message TEXT NOT NULL DEFAULT '',        -- Timestamp as message
  sequence INTEGER NOT NULL DEFAULT 0,    -- Message counter
  timestamp TEXT NOT NULL DEFAULT 0      -- ISO8601 timestamp
);