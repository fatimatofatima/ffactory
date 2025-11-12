CREATE TABLE IF NOT EXISTS media_assets(
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  case_id TEXT,
  bucket TEXT NOT NULL,
  object_key TEXT NOT NULL,
  media_type TEXT,        -- audio | video
  duration_seconds INT,
  size_bytes BIGINT,
  sha256 TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS transcripts(
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  media_id UUID REFERENCES media_assets(id) ON DELETE CASCADE,
  lang TEXT,
  text TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS nlp_entities(
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  case_id TEXT,
  entity_type TEXT,       -- PERSON | ORG | LOC | EVENT | ...
  value TEXT,
  source TEXT,            -- neural-core
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS entity_mentions(
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  transcript_id UUID REFERENCES transcripts(id) ON DELETE CASCADE,
  entity_id UUID REFERENCES nlp_entities(id) ON DELETE CASCADE,
  start_char INT, end_char INT
);
