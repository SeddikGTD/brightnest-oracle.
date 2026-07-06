-- ==========================================
-- AI BINARY SIGNALS - POSTGRESQL DATABASE SCHEMA
-- Target Environment: Supabase / Hostinger Horizons Production PostgreSQL
-- Security Level: Military-Grade Row-Level Security (RLS) with Admin Monopoly Overrides
-- ==========================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Clean up existing resources (if running migration)
DROP TRIGGER IF EXISTS tr_on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS tr_on_profile_created ON public.users_profiles;
DROP FUNCTION IF EXISTS public.handle_new_auth_user();
DROP FUNCTION IF EXISTS public.handle_new_profile_creation();
DROP FUNCTION IF EXISTS public.is_admin();
DROP FUNCTION IF EXISTS public.validate_device_session();
DROP FUNCTION IF EXISTS public.increment_and_validate_signal_limit();

DROP TABLE IF EXISTS public.payments;
DROP TABLE IF EXISTS public.trading_signals;
DROP TABLE IF EXISTS public.subscriptions;
DROP TABLE IF EXISTS public.users_profiles;

-- ==========================================
-- 1. USERS PROFILES TABLE
-- ==========================================
CREATE TABLE public.users_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email VARCHAR(255) UNIQUE NOT NULL,
    username VARCHAR(50) UNIQUE,
    paper_balance NUMERIC(15, 2) DEFAULT 10000.00 CHECK (paper_balance >= 0),
    device_fingerprint VARCHAR(255),
    referral_code VARCHAR(50) UNIQUE NOT NULL,
    referred_by UUID REFERENCES public.users_profiles(id) ON DELETE SET NULL,
    is_banned BOOLEAN DEFAULT FALSE,
    is_admin BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexing for optimized lookups and anti-fraud checks
CREATE INDEX idx_users_device_fingerprint ON public.users_profiles(device_fingerprint);
CREATE INDEX idx_users_referral_code ON public.users_profiles(referral_code);

-- ==========================================
-- 2. SUBSCRIPTIONS TABLE
-- ==========================================
CREATE TABLE public.subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.users_profiles(id) ON DELETE CASCADE UNIQUE,
    tier VARCHAR(50) DEFAULT 'free_trial' CHECK (tier IN ('free_trial', 'vip_premium', 'expired')),
    starts_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    signals_today_count INTEGER DEFAULT 0 CHECK (signals_today_count >= 0),
    last_signal_consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_subscriptions_user ON public.subscriptions(user_id);
CREATE INDEX idx_subscriptions_expires ON public.subscriptions(expires_at);

-- ==========================================
-- 3. TRADING SIGNALS TABLE
-- ==========================================
CREATE TABLE public.trading_signals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_pair VARCHAR(20) NOT NULL,
    action VARCHAR(10) NOT NULL CHECK (action IN ('BUY', 'SELL')),
    signal_strength INTEGER NOT NULL CHECK (signal_strength BETWEEN 0 AND 100),
    entry_price NUMERIC(15, 5) NOT NULL,
    strike_time TIMESTAMPTZ NOT NULL,
    outcome VARCHAR(10) DEFAULT 'PENDING' CHECK (outcome IN ('WIN', 'LOSS', 'TIE', 'PENDING')),
    is_otc BOOLEAN DEFAULT FALSE,
    indicators_confluence JSONB, -- Stores technical indicators: RSI, MACD, Bollinger Bands, Price Action patterns
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_signals_created_at ON public.trading_signals(created_at DESC);
CREATE INDEX idx_signals_otc ON public.trading_signals(is_otc);

-- ==========================================
-- 4. PAYMENTS TABLE
-- ==========================================
CREATE TABLE public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.users_profiles(id) ON DELETE CASCADE,
    amount NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    currency VARCHAR(10) DEFAULT 'USD',
    status VARCHAR(50) DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED')),
    payment_gateway VARCHAR(50) NOT NULL, -- e.g. 'Stripe', 'Coinbase', 'BinancePay'
    transaction_id VARCHAR(255) UNIQUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_payments_user ON public.payments(user_id);
CREATE INDEX idx_payments_status ON public.payments(status);


-- ==========================================
-- AUTOMATION & SECURITY FUNCTIONS (TRIGGERS / PROCEDURES)
-- ==========================================

-- A. Helper Function: Check Admin Privilege safely (Prevents RLS infinite recursion)
CREATE OR REPLACE FUNCTION public.is_admin() 
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.users_profiles 
    WHERE id = auth.uid() AND is_admin = true
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- B. Trigger Hook: Automatically handle public profile registration from Supabase Auth
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER AS $$
DECLARE
    v_referral_code VARCHAR(50);
    v_referred_by_id UUID;
    v_referrer_exists BOOLEAN;
BEGIN
    -- Generate a unique referral code
    v_referral_code := 'REF-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 8));

    -- Check if referrer was passed in metadata (e.g. from app onboarding link)
    IF NEW.raw_user_meta_data->>'referral_code' IS NOT NULL THEN
        SELECT id INTO v_referred_by_id 
        FROM public.users_profiles 
        WHERE referral_code = (NEW.raw_user_meta_data->>'referral_code');
    END IF;

    -- Create public user profile entry
    INSERT INTO public.users_profiles (
        id, 
        email, 
        username, 
        referral_code, 
        referred_by
    )
    VALUES (
        NEW.id, 
        NEW.email, 
        COALESCE(NEW.raw_user_meta_data->>'username', SPLIT_PART(NEW.email, '@', 1)), 
        v_referral_code, 
        v_referred_by_id
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER tr_on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();


-- C. Trigger Hook: Provision 3-Day Trial and process Viral Referral loops
CREATE OR REPLACE FUNCTION public.handle_new_profile_creation()
RETURNS TRIGGER AS $$
DECLARE
    v_trial_end_date TIMESTAMPTZ;
BEGIN
    -- Base trial: 3 days
    v_trial_end_date := NOW() + INTERVAL '3 days';

    -- VIRAL GROWTH SYSTEM: Referral extension logic
    IF NEW.referred_by IS NOT NULL THEN
        -- Give referee 2 extra days (increasing original 3-day welcome to 5 days)
        v_trial_end_date := v_trial_end_date + INTERVAL '2 days';

        -- Reward referrer with 3 bonus days immediately
        UPDATE public.subscriptions
        SET expires_at = expires_at + INTERVAL '3 days'
        WHERE user_id = NEW.referred_by;
    END IF;

    -- Initialize Subscription with precise trial expiry
    INSERT INTO public.subscriptions (
        user_id, 
        tier, 
        starts_at, 
        expires_at
    )
    VALUES (
        NEW.id, 
        'free_trial', 
        NOW(), 
        v_trial_end_date
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER tr_on_profile_created
AFTER INSERT ON public.users_profiles
FOR EACH ROW EXECUTE FUNCTION public.handle_new_profile_creation();


-- D. Security Function: Single-Session Device Fingerprinting Check
CREATE OR REPLACE FUNCTION public.validate_device_session(
    p_user_id UUID, 
    p_device_fingerprint VARCHAR
)
RETURNS BOOLEAN AS $$
DECLARE
    v_current_fingerprint VARCHAR(255);
    v_is_banned BOOLEAN;
BEGIN
    -- Fetch profile details
    SELECT device_fingerprint, is_banned INTO v_current_fingerprint, v_is_banned
    FROM public.users_profiles
    WHERE id = p_user_id;

    -- Block banned users instantly
    IF v_is_banned = TRUE THEN
        RAISE EXCEPTION 'This account has been banned due to policy violation.';
    END IF;

    -- If no device has logged in yet, register this device
    IF v_current_fingerprint IS NULL THEN
        UPDATE public.users_profiles
        SET device_fingerprint = p_device_fingerprint
        WHERE id = p_user_id;
        RETURN TRUE;
    END IF;

    -- Restrict account to a single concurrent session/device
    IF v_current_fingerprint <> p_device_fingerprint THEN
        RAISE EXCEPTION 'Concurrent session detected. Please log out from your previous device before connecting.';
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- E. Subscription Guard: Enforces 3-Day Free Trial lockdown and 2-signal/day max constraint
CREATE OR REPLACE FUNCTION public.increment_and_validate_signal_limit(p_user_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_tier VARCHAR(50);
    v_expires_at TIMESTAMPTZ;
    v_signals_today INTEGER;
    v_last_consumed TIMESTAMPTZ;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- E. Subscription Guard (Continuation): Enforces 3-Day Free Trial lockdown and 2-signal/day max constraint
CREATE OR REPLACE FUNCTION public.increment_and_validate_signal_limit(p_user_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_tier VARCHAR(50);
    v_expires_at TIMESTAMPTZ;
    v_signals_today INTEGER;
    v_last_consumed TIMESTAMPTZ;
BEGIN
    -- Fetch the user's current subscription
    SELECT tier, expires_at, signals_today_count, last_signal_consumed_at
    INTO v_tier, v_expires_at, v_signals_today, v_last_consumed
    FROM public.subscriptions
    WHERE user_id = p_user_id;

    -- No subscription check
    IF v_tier IS NULL THEN
        RAISE EXCEPTION 'No active subscription found. Access denied.';
    END IF;

    -- Trial / Subscription expiry check (3-Day Limit Lockdown)
    IF NOW() > v_expires_at THEN
        -- Auto expire tier in records
        UPDATE public.subscriptions SET tier = 'expired' WHERE user_id = p_user_id;
        RAISE EXCEPTION 'Your trial period has expired. Please subscribe to VIP Premium for continued access.';
    END IF;

    -- Check limits for free trial tier
    IF v_tier = 'free_trial' THEN
        -- Reset daily count if the last consumption was on a different calendar day
        IF v_last_consumed IS NULL OR DATE_TRUNC('day', v_last_consumed) < DATE_TRUNC('day', NOW()) THEN
            v_signals_today := 0;
            UPDATE public.subscriptions
            SET signals_today_count = 0, last_signal_consumed_at = NOW()
            WHERE user_id = p_user_id;
        END IF;

        -- Max 2 signals daily limit rule
        IF v_signals_today >= 2 THEN
            RAISE EXCEPTION 'Daily signal limit (2/2) reached for Free Welcome Tier. Upgrade to VIP Premium for unlimited signals!';
        END IF;
    END IF;

    -- Update usage statistics
    UPDATE public.subscriptions
    SET signals_today_count = signals_today_count + 1,
        last_signal_consumed_at = NOW()
    WHERE user_id = p_user_id;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ==========================================
-- ROW-LEVEL SECURITY (RLS) DESIGN
-- ==========================================

-- Enable RLS across all tables
ALTER TABLE public.users_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trading_signals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

-- 1. users_profiles Policies
CREATE POLICY "Users can view their own profile"
    ON public.users_profiles FOR SELECT
    USING (auth.uid() = id OR public.is_admin());

CREATE POLICY "Users can update their own profile details"
    ON public.users_profiles FOR UPDATE
    USING (auth.uid() = id OR public.is_admin())
    WITH CHECK (auth.uid() = id OR public.is_admin());

CREATE POLICY "Admin monopoly full access to profiles"
    ON public.users_profiles FOR ALL
    USING (public.is_admin());

-- 2. subscriptions Policies
CREATE POLICY "Users can view their own subscriptions"
    ON public.subscriptions FOR SELECT
    USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "Admin monopoly full access to subscriptions"
    ON public.subscriptions FOR ALL
    USING (public.is_admin());

-- 3. trading_signals Policies
CREATE POLICY "Registered active users can view signals"
    ON public.trading_signals FOR SELECT
    USING (
        -- Admin checks
        public.is_admin() OR
        -- Check if user is not banned and has an unexpired subscription
        EXISTS (
            SELECT 1 FROM public.users_profiles p
            JOIN public.subscriptions s ON s.user_id = p.id
            WHERE p.id = auth.uid() 
              AND p.is_banned = FALSE 
              AND NOW() <= s.expires_at
        )
    );

CREATE POLICY "Admin monopoly full access to trading signals"
    ON public.trading_signals FOR ALL
    USING (public.is_admin());

-- 4. payments Policies
CREATE POLICY "Users can view their own payment histories"
    ON public.payments FOR SELECT
    USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "Users can initiate pending payments"
    ON public.payments FOR INSERT
    WITH CHECK (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "Admin monopoly full access to payments"
    ON public.payments FOR ALL
    USING (public.is_admin());