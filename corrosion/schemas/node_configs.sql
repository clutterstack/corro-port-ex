-- Bootstrap configuration for each node in the cluster
-- Each node subscribes to changes for its own node_id and updates its config accordingly
CREATE TABLE node_configs (
  node_id TEXT PRIMARY KEY NOT NULL,                    -- e.g., "dev-node1", "iad-machine123"
  corrosion_actor_id TEXT,                              -- Corrosion's UUID for this node (self-reported)
  bootstrap_hosts TEXT NOT NULL DEFAULT '[]',           -- JSON array: ["host1:8787", "host2:8787"]
  updated_at TEXT NOT NULL DEFAULT '',                  -- ISO8601 timestamp
  updated_by TEXT NOT NULL DEFAULT ''                   -- Which node made this change (for audit trail)
);
