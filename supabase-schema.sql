-- ============================================================
-- ContractScan AI — Enterprise Supabase Schema
-- Version: 2.0 (Enterprise Edition)
--
-- Run this in Supabase SQL Editor (Project → SQL Editor → +)
-- Order matters: run top to bottom.
-- ============================================================

-- ============================================================
-- EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- For gen_random_uuid() & server-side encryption
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- For fuzzy text search on contract types

-- ============================================================
-- ENUM TYPES
-- ============================================================
CREATE TYPE risk_level AS ENUM ('critical', 'warning', 'safe');
CREATE TYPE subscription_status_type AS ENUM (
  'active', 'inactive', 'trialing', 'past_due', 'canceled', 'unpaid'
);
CREATE TYPE complexity_tier AS ENUM ('simple', 'medium', 'complex');

-- ============================================================
-- PROFILES TABLE
-- Extends auth.users. One row per user.
-- ============================================================
CREATE TABLE public.profiles (
  id                    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email                 TEXT NOT NULL,

  -- Stripe billing
  stripe_customer_id    TEXT UNIQUE,
  subscription_status   subscription_status_type DEFAULT 'inactive',
  subscription_id       TEXT,                    -- Stripe subscription ID
  current_period_end    TIMESTAMPTZ,             -- When current billing period ends

  -- Usage tracking
  free_analyses_used    INTEGER NOT NULL DEFAULT 0,
  total_analyses        INTEGER NOT NULL DEFAULT 0,
  total_cost_usd        NUMERIC(10,6) NOT NULL DEFAULT 0, -- Lifetime AI cost

  -- Rate limiting (sliding window, 1 hour)
  rate_limit_count      INTEGER NOT NULL DEFAULT 0,
  rate_limit_reset_at   TIMESTAMPTZ,

  -- Metadata
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for Stripe webhook lookups
CREATE INDEX idx_profiles_stripe ON public.profiles (stripe_customer_id)
  WHERE stripe_customer_id IS NOT NULL;

-- ============================================================
-- ANALYSES TABLE (PARTITIONED BY MONTH)
--
-- At 100M users we'll have billions of analyses.
-- Partition by created_at month so old data can be
-- cheaply archived/detached without full-table locks.
-- ============================================================
CREATE TABLE public.analyses (
  id                    UUID NOT NULL DEFAULT gen_random_uuid(),
  user_id               UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  file_name             TEXT NOT NULL,

  -- Cache deduplication
  contract_hash         TEXT NOT NULL,           -- SHA-256 of normalized text

  -- Analysis results (stored as JSONB for queryability)
  contract_type         TEXT,
  overall_risk_score    INTEGER CHECK (overall_risk_score BETWEEN 0 AND 100),
  overall_risk_level    risk_level,
  summary               TEXT,
  clauses               JSONB,                   -- Array of clause objects
  red_flags             JSONB,                   -- Array of strings
  positive_points       JSONB,                   -- Array of strings

  -- AES-256-GCM encrypted copies (application-layer encryption)
  -- Format: "iv:tag:ciphertext" (all hex)
  clauses_encrypted     TEXT,
  summary_encrypted     TEXT,

  -- Routing metadata
  model_used            TEXT,                    -- 'groq-llama-3.1-8b' | 'groq-deepseek-r1' | 'claude-3-5-sonnet'
  complexity_score      INTEGER CHECK (complexity_score BETWEEN 0 AND 100),
  complexity_tier       complexity_tier,
  token_reduction_pct   INTEGER DEFAULT 0,
  from_cache            BOOLEAN NOT NULL DEFAULT FALSE,

  -- Performance + cost
  processing_ms         INTEGER,
  estimated_cost_usd    NUMERIC(10,6) DEFAULT 0,

  -- Timestamps (partition key)
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (id, created_at)                   -- Include partition key in PK
) PARTITION BY RANGE (created_at);

-- Create monthly partitions for current + next 12 months
-- Run this block to create initial partitions:
DO $$
DECLARE
  start_date DATE := DATE_TRUNC('month', NOW());
  end_date   DATE;
  partition_name TEXT;
BEGIN
  FOR i IN 0..12 LOOP
    start_date := DATE_TRUNC('month', NOW()) + (i || ' months')::INTERVAL;
    end_date   := start_date + '1 month'::INTERVAL;
    partition_name := 'analyses_' || TO_CHAR(start_date, 'YYYY_MM');

    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS public.%I
       PARTITION OF public.analyses
       FOR VALUES FROM (%L) TO (%L)',
      partition_name,
      start_date,
      end_date
    );
    RAISE NOTICE 'Created partition: %', partition_name;
  END LOOP;
END $$;

-- ── Indexes on analyses ──────────────────────
-- User's analysis history (most common query)
CREATE INDEX idx_analyses_user_created
  ON public.analyses (user_id, created_at DESC);

-- Cache lookup by hash (critical performance path)
CREATE INDEX idx_analyses_hash
  ON public.analyses (contract_hash);

-- Risk level filtering
CREATE INDEX idx_analyses_risk
  ON public.analyses (overall_risk_level, created_at DESC)
  WHERE overall_risk_level IS NOT NULL;

-- Model usage analytics
CREATE INDEX idx_analyses_model
  ON public.analyses (model_used, created_at DESC)
  WHERE model_used IS NOT NULL;

-- ============================================================
-- CONTRACT CACHE TABLE
--
-- Maps SHA-256(normalized text) → analysis result.
-- When the same contract is uploaded again (by any user),
-- the AI call is skipped entirely.
-- ============================================================
CREATE TABLE public.contract_cache (
  contract_hash         TEXT PRIMARY KEY,         -- SHA-256 of normalized contract
  analysis_id           UUID NOT NULL,            -- Points to canonical analysis
  result_encrypted      TEXT NOT NULL,            -- AES-256 encrypted AnalysisResult JSON
  model_used            TEXT NOT NULL,
  hit_count             INTEGER NOT NULL DEFAULT 0,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_hit_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for hit count analytics
CREATE INDEX idx_cache_hits ON public.contract_cache (hit_count DESC);
CREATE INDEX idx_cache_created ON public.contract_cache (created_at DESC);

-- ============================================================
-- USAGE LEDGER TABLE
-- Immutable append-only cost tracking per analysis.
-- Powers admin cost dashboards and abuse detection.
-- ============================================================
CREATE TABLE public.usage_ledger (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  analysis_id     UUID,
  model_used      TEXT NOT NULL,
  cost_usd        NUMERIC(10,6) NOT NULL,
  from_cache      BOOLEAN NOT NULL DEFAULT FALSE,
  is_pro          BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ledger_user ON public.usage_ledger (user_id, created_at DESC);
CREATE INDEX idx_ledger_date ON public.usage_ledger (created_at DESC);

-- ============================================================
-- RPC FUNCTIONS
-- ============================================================

-- Atomic increment for usage tracking (called from worker)
CREATE OR REPLACE FUNCTION public.increment_usage(
  p_user_id UUID,
  p_cost    NUMERIC,
  p_is_pro  BOOLEAN
) RETURNS void AS $$
BEGIN
  UPDATE public.profiles SET
    total_analyses = total_analyses + 1,
    total_cost_usd = total_cost_usd + p_cost,
    free_analyses_used = CASE
      WHEN NOT p_is_pro THEN free_analyses_used + 1
      ELSE free_analyses_used
    END,
    updated_at = NOW()
  WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get user's cost summary for a given month
CREATE OR REPLACE FUNCTION public.get_monthly_cost(
  p_user_id UUID,
  p_year    INTEGER DEFAULT EXTRACT(YEAR FROM NOW())::INTEGER,
  p_month   INTEGER DEFAULT EXTRACT(MONTH FROM NOW())::INTEGER
) RETURNS TABLE (
  total_analyses   BIGINT,
  total_cost_usd   NUMERIC,
  cache_hits       BIGINT,
  avg_risk_score   NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(*)::BIGINT                          AS total_analyses,
    COALESCE(SUM(a.estimated_cost_usd), 0)   AS total_cost_usd,
    COUNT(*) FILTER (WHERE a.from_cache)      AS cache_hits,
    AVG(a.overall_risk_score)                 AS avg_risk_score
  FROM public.analyses a
  WHERE a.user_id = p_user_id
    AND EXTRACT(YEAR  FROM a.created_at) = p_year
    AND EXTRACT(MONTH FROM a.created_at) = p_month;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Archive partition: detach old partitions to cold storage
CREATE OR REPLACE FUNCTION public.archive_old_partition(p_year INTEGER, p_month INTEGER)
RETURNS void AS $$
DECLARE
  partition_name TEXT := 'analyses_' || LPAD(p_year::TEXT, 4, '0') || '_' || LPAD(p_month::TEXT, 2, '0');
BEGIN
  EXECUTE format('ALTER TABLE public.analyses DETACH PARTITION public.%I', partition_name);
  RAISE NOTICE 'Detached partition: %', partition_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- AUTO-CREATE MONTHLY PARTITIONS
-- Trigger fires on the 1st of each month (via pg_cron or manual)
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_next_month_partition()
RETURNS void AS $$
DECLARE
  next_month_start DATE := DATE_TRUNC('month', NOW() + '1 month'::INTERVAL);
  next_month_end   DATE := next_month_start + '1 month'::INTERVAL;
  partition_name   TEXT := 'analyses_' || TO_CHAR(next_month_start, 'YYYY_MM');
BEGIN
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS public.%I
     PARTITION OF public.analyses
     FOR VALUES FROM (%L) TO (%L)',
    partition_name, next_month_start, next_month_end
  );
  RAISE NOTICE 'Auto-created partition: %', partition_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Updated_at trigger on profiles
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Auto-create profile row when user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email)
  VALUES (NEW.id, NEW.email)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================
ALTER TABLE public.profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analyses         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_cache   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_ledger     ENABLE ROW LEVEL SECURITY;

-- Profiles: users see only their own row
CREATE POLICY "profiles_select_own" ON public.profiles
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE USING (auth.uid() = id);

-- Analyses: users see only their own rows
CREATE POLICY "analyses_select_own" ON public.analyses
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "analyses_insert_own" ON public.analyses
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Contract cache: readable by all authenticated users (it's anonymized)
-- Writable only by service role (workers use service key)
CREATE POLICY "cache_select_authenticated" ON public.contract_cache
  FOR SELECT TO authenticated USING (true);

-- Usage ledger: users see only their own records
CREATE POLICY "ledger_select_own" ON public.usage_ledger
  FOR SELECT USING (auth.uid() = user_id);

-- ============================================================
-- GRANTS (service role used by worker bypasses RLS)
-- ============================================================
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated;
GRANT SELECT, INSERT ON public.analyses TO authenticated;
GRANT SELECT ON public.contract_cache TO authenticated;
GRANT SELECT ON public.usage_ledger TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_monthly_cost TO authenticated;

-- ============================================================
-- USEFUL ADMIN QUERIES
-- ============================================================

-- Cache effectiveness
-- SELECT
--   COUNT(*) AS total_cached,
--   SUM(hit_count) AS total_hits,
--   ROUND(SUM(hit_count) * 0.012, 2) AS estimated_savings_usd
-- FROM public.contract_cache;

-- Model usage distribution
-- SELECT model_used, COUNT(*), ROUND(AVG(processing_ms)) AS avg_ms
-- FROM public.analyses
-- WHERE created_at > NOW() - INTERVAL '30 days'
-- GROUP BY model_used ORDER BY COUNT(*) DESC;

-- High-risk contracts (for product insights)
-- SELECT contract_type, COUNT(*), ROUND(AVG(overall_risk_score), 1) AS avg_risk
-- FROM public.analyses
-- WHERE overall_risk_level = 'critical'
-- GROUP BY contract_type ORDER BY COUNT(*) DESC LIMIT 10;

-- Daily active users
-- SELECT DATE(created_at), COUNT(DISTINCT user_id) AS dau
-- FROM public.analyses
-- WHERE created_at > NOW() - INTERVAL '30 days'
-- GROUP BY DATE(created_at) ORDER BY 1;
