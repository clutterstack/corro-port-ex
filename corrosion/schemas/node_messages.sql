-- Replace or add to existing schema

CREATE TABLE node_messages (
  pk TEXT PRIMARY KEY NOT NULL DEFAULT '',
  node_id TEXT NOT NULL DEFAULT 'no_id',
  message TEXT NOT NULL DEFAULT '',
  sequence INTEGER NOT NULL DEFAULT 0,
  timestamp TEXT NOT NULL DEFAULT 0,
  originating_ip TEXT NOT NULL DEFAULT ''
);