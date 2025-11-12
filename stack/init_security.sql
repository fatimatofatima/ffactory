CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS login_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  login_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address INET,
  success BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_login_time ON login_attempts(login_time);
CREATE INDEX IF NOT EXISTS idx_login_user ON login_attempts(user_id);

CREATE TABLE IF NOT EXISTS network_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  event_type TEXT NOT NULL,            -- connection_attempt, flow, dns, ...
  source_ip INET,
  destination_ip INET,
  destination_port INT,
  protocol TEXT,
  bytes_sent BIGINT DEFAULT 0,
  bytes_received BIGINT DEFAULT 0,
  meta JSONB
);
CREATE INDEX IF NOT EXISTS idx_net_time     ON network_events(event_time);
CREATE INDEX IF NOT EXISTS idx_net_type     ON network_events(event_type);
CREATE INDEX IF NOT EXISTS idx_net_dst_port ON network_events(destination_port);
