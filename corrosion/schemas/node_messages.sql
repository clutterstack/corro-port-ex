-- Updated schema with originating_endpoint field (IP:PORT)
CREATE TABLE node_messages (
  pk TEXT PRIMARY KEY NOT NULL DEFAULT '',
  node_id TEXT NOT NULL DEFAULT 'no_id',
  message TEXT NOT NULL DEFAULT '',
  sequence INTEGER NOT NULL DEFAULT 0,
  timestamp TEXT NOT NULL DEFAULT 0,
  originating_endpoint TEXT NOT NULL DEFAULT '127.0.0.1:5001'  -- IP:PORT for direct API communication
);