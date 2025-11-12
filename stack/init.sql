CREATE TABLE IF NOT EXISTS timeline_events(
  id bigserial PRIMARY KEY,
  case_id text,
  job_id text,
  timestamp timestamptz DEFAULT now(),
  description text,
  source text
);
CREATE TABLE IF NOT EXISTS scan_results(
  id bigserial PRIMARY KEY,
  case_id text,
  sha256 text,
  score int
);
CREATE TABLE IF NOT EXISTS decryption_failures(
  id bigserial PRIMARY KEY,
  case_id text,
  failure_type text,
  failure_timestamp timestamptz DEFAULT now()
);
