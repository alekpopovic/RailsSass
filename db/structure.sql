SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: enforce_organization_active_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_organization_active_owner() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  affected_organization_id bigint;
  affected_organization_ids bigint[];
BEGIN
  IF TG_TABLE_NAME = 'organizations' THEN
    affected_organization_ids := ARRAY[NEW.id];
  ELSIF TG_OP = 'INSERT' THEN
    affected_organization_ids := ARRAY[NEW.organization_id];
  ELSIF TG_OP = 'DELETE' THEN
    affected_organization_ids := ARRAY[OLD.organization_id];
  ELSE
    SELECT array_agg(candidate_id ORDER BY candidate_id)
    INTO affected_organization_ids
    FROM (
      SELECT DISTINCT unnest(
        ARRAY[OLD.organization_id, NEW.organization_id]
      ) AS candidate_id
    ) AS candidates;
  END IF;

  FOREACH affected_organization_id IN ARRAY affected_organization_ids
  LOOP
    PERFORM 1
    FROM public.organizations
    WHERE id = affected_organization_id
    FOR UPDATE;

    IF FOUND AND NOT EXISTS (
      SELECT 1
      FROM public.organization_memberships
      WHERE organization_id = affected_organization_id
        AND role = 'owner'
        AND status = 'active'
    ) THEN
      RAISE EXCEPTION
        'organization % must have at least one active owner',
        affected_organization_id
        USING ERRCODE = '23514',
          CONSTRAINT = 'organization_must_have_active_owner',
          TABLE = 'organizations';
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;


--
-- Name: enforce_product_membership_role_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_product_membership_role_scope() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  role_organization_id bigint;
  role_active boolean;
BEGIN
  SELECT organization_id, active
  INTO role_organization_id, role_active
  FROM public.product_roles
  WHERE id = NEW.product_role_id
    AND product_id = NEW.product_id
  FOR SHARE;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF role_active = FALSE THEN
    RAISE EXCEPTION 'inactive product role cannot be assigned'
      USING ERRCODE = '23514',
        CONSTRAINT = 'product_membership_roles_role_active',
        TABLE = 'product_membership_roles';
  END IF;

  IF role_organization_id IS NOT NULL
    AND role_organization_id IS DISTINCT FROM NEW.organization_id THEN
    RAISE EXCEPTION 'organization product role belongs to another organization'
      USING ERRCODE = '23514',
        CONSTRAINT = 'product_membership_roles_role_organization_matches',
        TABLE = 'product_membership_roles';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: prevent_audit_event_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_audit_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  RAISE EXCEPTION 'audit events are append-only'
    USING ERRCODE = '55000',
      TABLE = 'audit_events';
END;
$$;


--
-- Name: protect_billing_subscription_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_billing_subscription_history() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'billing subscription history must be archived, not deleted'
      USING ERRCODE = '55000',
        TABLE = 'billing_subscriptions';
  END IF;

  IF OLD.current = FALSE AND (
    NEW.current <> FALSE
    OR NEW.archived_at IS DISTINCT FROM OLD.archived_at
  ) THEN
    RAISE EXCEPTION 'archived billing subscription state is immutable'
      USING ERRCODE = '23514',
        CONSTRAINT = 'billing_subscriptions_archive_is_one_way',
        TABLE = 'billing_subscriptions';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: protect_plan_price_plan_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_plan_price_plan_identity() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  IF NEW.plan_id IS DISTINCT FROM OLD.plan_id THEN
    RAISE EXCEPTION 'plan price plan identity is immutable'
      USING ERRCODE = '23514',
        CONSTRAINT = 'plan_prices_plan_identity_immutable',
        TABLE = 'plan_prices';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: protect_product_role_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_product_role_identity() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  IF NEW.product_id IS DISTINCT FROM OLD.product_id
    OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
    OR NEW.key IS DISTINCT FROM OLD.key
    OR NEW.system IS DISTINCT FROM OLD.system THEN
    RAISE EXCEPTION 'product role identity is immutable'
      USING ERRCODE = '23514',
        CONSTRAINT = 'product_roles_identity_immutable',
        TABLE = 'product_roles';
  END IF;

  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    actor_user_id bigint,
    action character varying(100) NOT NULL,
    subject_type character varying(100) NOT NULL,
    subject_id bigint NOT NULL,
    request_id character varying(255),
    job_id character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT audit_events_action_format CHECK (((action)::text ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text)),
    CONSTRAINT audit_events_job_id_valid CHECK (((job_id IS NULL) OR (((job_id)::text = btrim((job_id)::text)) AND ((char_length((job_id)::text) >= 1) AND (char_length((job_id)::text) <= 255))))),
    CONSTRAINT audit_events_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT audit_events_request_id_valid CHECK (((request_id IS NULL) OR (((request_id)::text = btrim((request_id)::text)) AND ((char_length((request_id)::text) >= 1) AND (char_length((request_id)::text) <= 255))))),
    CONSTRAINT audit_events_subject_id_positive CHECK ((subject_id > 0)),
    CONSTRAINT audit_events_subject_type_present CHECK ((((subject_type)::text = btrim((subject_type)::text)) AND ((char_length((subject_type)::text) >= 1) AND (char_length((subject_type)::text) <= 100))))
);


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_events_id_seq OWNED BY public.audit_events.id;


--
-- Name: billing_checkout_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_checkout_attempts (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    initiated_by_membership_id bigint NOT NULL,
    plan_price_id bigint NOT NULL,
    provider character varying(32) DEFAULT 'lemon_squeezy'::character varying NOT NULL,
    environment character varying(8) NOT NULL,
    test_mode boolean NOT NULL,
    token_digest character varying(64) NOT NULL,
    status character varying(32) DEFAULT 'creating'::character varying NOT NULL,
    provider_checkout_id character varying(128),
    expires_at timestamp(6) without time zone NOT NULL,
    token_consumed_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    failure_code character varying(64),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT billing_checkout_attempts_completed_after_creation CHECK (((completed_at IS NULL) OR (completed_at >= created_at))),
    CONSTRAINT billing_checkout_attempts_environment_allowed CHECK (((environment)::text = ANY ((ARRAY['test'::character varying, 'live'::character varying])::text[]))),
    CONSTRAINT billing_checkout_attempts_environment_test_mode_consistent CHECK (((((environment)::text = 'test'::text) AND (test_mode = true)) OR (((environment)::text = 'live'::text) AND (test_mode = false)))),
    CONSTRAINT billing_checkout_attempts_expiry_after_creation CHECK ((expires_at > created_at)),
    CONSTRAINT billing_checkout_attempts_failure_code_normalized CHECK (((failure_code IS NULL) OR (((failure_code)::text = btrim((failure_code)::text)) AND ((failure_code)::text ~ '^[a-z][a-z0-9_]*$'::text) AND ((char_length((failure_code)::text) >= 1) AND (char_length((failure_code)::text) <= 64))))),
    CONSTRAINT billing_checkout_attempts_lifecycle CHECK (((((status)::text = ANY ((ARRAY['creating'::character varying, 'creation_unknown'::character varying])::text[])) AND (completed_at IS NULL) AND (token_consumed_at IS NULL) AND (failure_code IS NULL)) OR (((status)::text = 'ready'::text) AND (provider_checkout_id IS NOT NULL) AND (completed_at IS NULL) AND (token_consumed_at IS NULL) AND (failure_code IS NULL)) OR (((status)::text = 'completed'::text) AND (provider_checkout_id IS NOT NULL) AND (completed_at IS NOT NULL) AND (token_consumed_at IS NOT NULL) AND (failure_code IS NULL)) OR (((status)::text = ANY ((ARRAY['expired'::character varying, 'superseded'::character varying])::text[])) AND (completed_at IS NOT NULL) AND (token_consumed_at IS NULL) AND (failure_code IS NULL)) OR (((status)::text = 'failed'::text) AND (completed_at IS NOT NULL) AND (token_consumed_at IS NULL) AND (failure_code IS NOT NULL)))),
    CONSTRAINT billing_checkout_attempts_provider_allowed CHECK (((provider)::text = 'lemon_squeezy'::text)),
    CONSTRAINT billing_checkout_attempts_provider_id_normalized CHECK (((provider_checkout_id IS NULL) OR (((provider_checkout_id)::text = btrim((provider_checkout_id)::text)) AND ((provider_checkout_id)::text !~ '[[:space:]]'::text) AND ((char_length((provider_checkout_id)::text) >= 1) AND (char_length((provider_checkout_id)::text) <= 128))))),
    CONSTRAINT billing_checkout_attempts_status_allowed CHECK (((status)::text = ANY ((ARRAY['creating'::character varying, 'ready'::character varying, 'creation_unknown'::character varying, 'completed'::character varying, 'expired'::character varying, 'superseded'::character varying, 'failed'::character varying])::text[]))),
    CONSTRAINT billing_checkout_attempts_token_consumed_at_valid CHECK (((token_consumed_at IS NULL) OR ((token_consumed_at >= created_at) AND (token_consumed_at <= completed_at)))),
    CONSTRAINT billing_checkout_attempts_token_digest_format CHECK (((token_digest)::text ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: billing_checkout_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_checkout_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_checkout_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_checkout_attempts_id_seq OWNED BY public.billing_checkout_attempts.id;


--
-- Name: billing_customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_customers (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    provider character varying(32) DEFAULT 'lemon_squeezy'::character varying NOT NULL,
    environment character varying(8) NOT NULL,
    provider_customer_id character varying(128) NOT NULL,
    test_mode boolean NOT NULL,
    provider_updated_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT billing_customers_environment_allowed CHECK (((environment)::text = ANY ((ARRAY['test'::character varying, 'live'::character varying])::text[]))),
    CONSTRAINT billing_customers_environment_test_mode_consistent CHECK (((((environment)::text = 'test'::text) AND (test_mode = true)) OR (((environment)::text = 'live'::text) AND (test_mode = false)))),
    CONSTRAINT billing_customers_provider_allowed CHECK (((provider)::text = 'lemon_squeezy'::text)),
    CONSTRAINT billing_customers_provider_customer_id_normalized CHECK ((((provider_customer_id)::text = btrim((provider_customer_id)::text)) AND ((provider_customer_id)::text !~ '[[:space:]]'::text) AND ((char_length((provider_customer_id)::text) >= 1) AND (char_length((provider_customer_id)::text) <= 128))))
);


--
-- Name: billing_customers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_customers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_customers_id_seq OWNED BY public.billing_customers.id;


--
-- Name: billing_plan_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_plan_changes (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    billing_subscription_id bigint NOT NULL,
    requested_by_membership_id bigint NOT NULL,
    from_plan_price_id bigint NOT NULL,
    to_plan_price_id bigint NOT NULL,
    provider character varying(32) DEFAULT 'lemon_squeezy'::character varying NOT NULL,
    environment character varying(8) NOT NULL,
    test_mode boolean NOT NULL,
    status character varying(32) DEFAULT 'pending'::character varying NOT NULL,
    requested_at timestamp(6) without time zone NOT NULL,
    provider_updated_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    failure_code character varying(64),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT billing_plan_changes_completed_after_requested CHECK (((completed_at IS NULL) OR (completed_at >= requested_at))),
    CONSTRAINT billing_plan_changes_environment_allowed CHECK (((environment)::text = ANY ((ARRAY['test'::character varying, 'live'::character varying])::text[]))),
    CONSTRAINT billing_plan_changes_environment_test_mode_consistent CHECK (((((environment)::text = 'test'::text) AND (test_mode = true)) OR (((environment)::text = 'live'::text) AND (test_mode = false)))),
    CONSTRAINT billing_plan_changes_failure_code_normalized CHECK (((failure_code IS NULL) OR (((failure_code)::text = btrim((failure_code)::text)) AND ((failure_code)::text ~ '^[a-z][a-z0-9_]*$'::text) AND ((char_length((failure_code)::text) >= 1) AND (char_length((failure_code)::text) <= 64))))),
    CONSTRAINT billing_plan_changes_lifecycle CHECK (((((status)::text = ANY ((ARRAY['pending'::character varying, 'submitted'::character varying, 'creation_unknown'::character varying])::text[])) AND (completed_at IS NULL) AND (failure_code IS NULL)) OR (((status)::text = ANY ((ARRAY['applied'::character varying, 'superseded'::character varying])::text[])) AND (completed_at IS NOT NULL) AND (failure_code IS NULL)) OR (((status)::text = 'failed'::text) AND (completed_at IS NOT NULL) AND (failure_code IS NOT NULL)))),
    CONSTRAINT billing_plan_changes_prices_differ CHECK ((from_plan_price_id <> to_plan_price_id)),
    CONSTRAINT billing_plan_changes_provider_allowed CHECK (((provider)::text = 'lemon_squeezy'::text)),
    CONSTRAINT billing_plan_changes_status_allowed CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'submitted'::character varying, 'creation_unknown'::character varying, 'applied'::character varying, 'failed'::character varying, 'superseded'::character varying])::text[])))
);


--
-- Name: billing_plan_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_plan_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_plan_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_plan_changes_id_seq OWNED BY public.billing_plan_changes.id;


--
-- Name: billing_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_subscriptions (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    billing_customer_id bigint NOT NULL,
    plan_price_id bigint NOT NULL,
    provider character varying(32) DEFAULT 'lemon_squeezy'::character varying NOT NULL,
    environment character varying(8) NOT NULL,
    provider_subscription_id character varying(128) NOT NULL,
    provider_customer_id character varying(128) NOT NULL,
    status character varying(32) NOT NULL,
    current boolean DEFAULT true NOT NULL,
    trial_ends_at timestamp(6) without time zone,
    renews_at timestamp(6) without time zone,
    ends_at timestamp(6) without time zone,
    provider_updated_at timestamp(6) without time zone NOT NULL,
    pause jsonb DEFAULT '{}'::jsonb NOT NULL,
    card_brand character varying(32),
    card_last_four character varying(4),
    test_mode boolean NOT NULL,
    raw_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp(6) without time zone,
    lock_version bigint DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    past_due_started_at timestamp(6) without time zone,
    CONSTRAINT billing_subscriptions_archive_after_creation CHECK (((archived_at IS NULL) OR (archived_at >= created_at))),
    CONSTRAINT billing_subscriptions_cancelled_end_required CHECK ((((status)::text <> 'cancelled'::text) OR (ends_at IS NOT NULL))),
    CONSTRAINT billing_subscriptions_card_display_consistent CHECK ((((card_brand IS NULL) AND (card_last_four IS NULL)) OR ((card_brand IS NOT NULL) AND ((card_brand)::text = btrim((card_brand)::text)) AND ((char_length((card_brand)::text) >= 1) AND (char_length((card_brand)::text) <= 32)) AND (card_last_four IS NOT NULL) AND ((card_last_four)::text ~ '^[0-9]{4}$'::text)))),
    CONSTRAINT billing_subscriptions_current_archive_consistent CHECK (((current AND (archived_at IS NULL)) OR ((NOT current) AND (archived_at IS NOT NULL)))),
    CONSTRAINT billing_subscriptions_environment_allowed CHECK (((environment)::text = ANY ((ARRAY['test'::character varying, 'live'::character varying])::text[]))),
    CONSTRAINT billing_subscriptions_environment_test_mode_consistent CHECK (((((environment)::text = 'test'::text) AND (test_mode = true)) OR (((environment)::text = 'live'::text) AND (test_mode = false)))),
    CONSTRAINT billing_subscriptions_lock_version_non_negative CHECK ((lock_version >= 0)),
    CONSTRAINT billing_subscriptions_pause_object_bounded CHECK (((jsonb_typeof(pause) = 'object'::text) AND (pg_column_size(pause) <= 65536))),
    CONSTRAINT billing_subscriptions_provider_allowed CHECK (((provider)::text = 'lemon_squeezy'::text)),
    CONSTRAINT billing_subscriptions_provider_customer_id_normalized CHECK ((((provider_customer_id)::text = btrim((provider_customer_id)::text)) AND ((provider_customer_id)::text !~ '[[:space:]]'::text) AND ((char_length((provider_customer_id)::text) >= 1) AND (char_length((provider_customer_id)::text) <= 128)))),
    CONSTRAINT billing_subscriptions_provider_subscription_id_normalized CHECK ((((provider_subscription_id)::text = btrim((provider_subscription_id)::text)) AND ((provider_subscription_id)::text !~ '[[:space:]]'::text) AND ((char_length((provider_subscription_id)::text) >= 1) AND (char_length((provider_subscription_id)::text) <= 128)))),
    CONSTRAINT billing_subscriptions_raw_payload_object_bounded CHECK (((jsonb_typeof(raw_payload) = 'object'::text) AND (pg_column_size(raw_payload) <= 65536))),
    CONSTRAINT billing_subscriptions_status_allowed CHECK (((status)::text = ANY ((ARRAY['on_trial'::character varying, 'active'::character varying, 'paused'::character varying, 'past_due'::character varying, 'unpaid'::character varying, 'cancelled'::character varying, 'expired'::character varying, 'unknown'::character varying])::text[]))),
    CONSTRAINT billing_subscriptions_trial_end_required CHECK ((((status)::text <> 'on_trial'::text) OR (trial_ends_at IS NOT NULL)))
);


--
-- Name: billing_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_subscriptions_id_seq OWNED BY public.billing_subscriptions.id;


--
-- Name: billing_webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_webhook_events (
    id bigint NOT NULL,
    organization_id bigint,
    provider character varying(32) DEFAULT 'lemon_squeezy'::character varying NOT NULL,
    environment character varying(8) NOT NULL,
    fingerprint character varying(64) NOT NULL,
    provider_event_id character varying(128),
    event_name character varying(100),
    provider_resource_id character varying(128),
    status character varying(32) DEFAULT 'received'::character varying NOT NULL,
    test_mode boolean,
    received_at timestamp(6) without time zone NOT NULL,
    verified_at timestamp(6) without time zone NOT NULL,
    processed_at timestamp(6) without time zone,
    provider_updated_at timestamp(6) without time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    error_code character varying(64),
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT billing_webhook_events_attempt_count_non_negative CHECK ((attempt_count >= 0)),
    CONSTRAINT billing_webhook_events_environment_allowed CHECK (((environment)::text = ANY ((ARRAY['test'::character varying, 'live'::character varying])::text[]))),
    CONSTRAINT billing_webhook_events_environment_test_mode_consistent CHECK (((test_mode IS NULL) OR (((environment)::text = 'test'::text) AND (test_mode = true)) OR (((environment)::text = 'live'::text) AND (test_mode = false)))),
    CONSTRAINT billing_webhook_events_error_code_normalized CHECK (((error_code IS NULL) OR (((error_code)::text = btrim((error_code)::text)) AND ((error_code)::text ~ '^[a-z][a-z0-9_]*$'::text) AND ((char_length((error_code)::text) >= 1) AND (char_length((error_code)::text) <= 64))))),
    CONSTRAINT billing_webhook_events_event_name_normalized CHECK (((event_name IS NULL) OR (((event_name)::text = btrim((event_name)::text)) AND ((char_length((event_name)::text) >= 1) AND (char_length((event_name)::text) <= 100))))),
    CONSTRAINT billing_webhook_events_fingerprint_format CHECK (((fingerprint)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT billing_webhook_events_lifecycle CHECK (((((status)::text = ANY ((ARRAY['received'::character varying, 'processing'::character varying])::text[])) AND (processed_at IS NULL) AND (error_code IS NULL)) OR (((status)::text = ANY ((ARRAY['processed'::character varying, 'ignored'::character varying])::text[])) AND (processed_at IS NOT NULL) AND (error_code IS NULL)) OR (((status)::text = ANY ((ARRAY['quarantined'::character varying, 'failed'::character varying])::text[])) AND (processed_at IS NOT NULL) AND (error_code IS NOT NULL)))),
    CONSTRAINT billing_webhook_events_processed_after_verified CHECK (((processed_at IS NULL) OR (processed_at >= verified_at))),
    CONSTRAINT billing_webhook_events_provider_allowed CHECK (((provider)::text = 'lemon_squeezy'::text)),
    CONSTRAINT billing_webhook_events_provider_event_id_normalized CHECK (((provider_event_id IS NULL) OR (((provider_event_id)::text = btrim((provider_event_id)::text)) AND ((provider_event_id)::text !~ '[[:space:]]'::text) AND ((char_length((provider_event_id)::text) >= 1) AND (char_length((provider_event_id)::text) <= 128))))),
    CONSTRAINT billing_webhook_events_resource_id_normalized CHECK (((provider_resource_id IS NULL) OR (((provider_resource_id)::text = btrim((provider_resource_id)::text)) AND ((provider_resource_id)::text !~ '[[:space:]]'::text) AND ((char_length((provider_resource_id)::text) >= 1) AND (char_length((provider_resource_id)::text) <= 128))))),
    CONSTRAINT billing_webhook_events_snapshot_object_bounded CHECK (((jsonb_typeof(snapshot) = 'object'::text) AND (pg_column_size(snapshot) <= 65536))),
    CONSTRAINT billing_webhook_events_status_allowed CHECK (((status)::text = ANY ((ARRAY['received'::character varying, 'processing'::character varying, 'processed'::character varying, 'ignored'::character varying, 'quarantined'::character varying, 'failed'::character varying])::text[]))),
    CONSTRAINT billing_webhook_events_verified_after_received CHECK ((verified_at >= received_at))
);


--
-- Name: billing_webhook_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.billing_webhook_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: billing_webhook_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.billing_webhook_events_id_seq OWNED BY public.billing_webhook_events.id;


--
-- Name: organization_access_locators; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_access_locators (
    id bigint NOT NULL,
    organization_membership_id bigint NOT NULL,
    user_id bigint NOT NULL,
    organization_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: organization_access_locators_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organization_access_locators_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organization_access_locators_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organization_access_locators_id_seq OWNED BY public.organization_access_locators.id;


--
-- Name: organization_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_invitations (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    inviter_id bigint NOT NULL,
    email_address character varying(254) NOT NULL,
    organization_role character varying(16) NOT NULL,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    token_digest character varying(64) NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    accepted_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT organization_invitations_accepted_at_valid CHECK (((accepted_at IS NULL) OR ((accepted_at >= created_at) AND (accepted_at < expires_at)))),
    CONSTRAINT organization_invitations_email_normalized CHECK ((((email_address)::text = lower(btrim((email_address)::text))) AND ((char_length((email_address)::text) >= 3) AND (char_length((email_address)::text) <= 254)))),
    CONSTRAINT organization_invitations_expiry_after_creation CHECK ((expires_at > created_at)),
    CONSTRAINT organization_invitations_revoked_at_valid CHECK (((revoked_at IS NULL) OR (revoked_at >= created_at))),
    CONSTRAINT organization_invitations_role_allowed CHECK (((organization_role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'billing'::character varying, 'member'::character varying])::text[]))),
    CONSTRAINT organization_invitations_status_allowed CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'revoked'::character varying, 'expired'::character varying])::text[]))),
    CONSTRAINT organization_invitations_status_timestamps CHECK (((((status)::text = ANY ((ARRAY['pending'::character varying, 'expired'::character varying])::text[])) AND (accepted_at IS NULL) AND (revoked_at IS NULL)) OR (((status)::text = 'accepted'::text) AND (accepted_at IS NOT NULL) AND (revoked_at IS NULL)) OR (((status)::text = 'revoked'::text) AND (accepted_at IS NULL) AND (revoked_at IS NOT NULL)))),
    CONSTRAINT organization_invitations_token_digest_format CHECK (((token_digest)::text ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: organization_invitations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organization_invitations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organization_invitations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organization_invitations_id_seq OWNED BY public.organization_invitations.id;


--
-- Name: organization_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_memberships (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    user_id bigint NOT NULL,
    role character varying(16) NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    joined_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT organization_memberships_role_allowed CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'billing'::character varying, 'member'::character varying])::text[]))),
    CONSTRAINT organization_memberships_status_allowed CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying])::text[])))
);


--
-- Name: organization_memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organization_memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organization_memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organization_memberships_id_seq OWNED BY public.organization_memberships.id;


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(63) NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT organizations_name_normalized CHECK ((((name)::text = btrim((name)::text)) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100)))),
    CONSTRAINT organizations_slug_format CHECK ((((slug)::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text) AND ((char_length((slug)::text) >= 1) AND (char_length((slug)::text) <= 63)))),
    CONSTRAINT organizations_status_allowed CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying])::text[])))
);


--
-- Name: organizations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organizations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organizations_id_seq OWNED BY public.organizations.id;


--
-- Name: plan_feature_entitlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plan_feature_entitlements (
    id bigint NOT NULL,
    plan_product_id bigint NOT NULL,
    product_feature_id bigint NOT NULL,
    product_id bigint NOT NULL,
    feature_kind character varying(16) NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    limit_value bigint,
    unlimited boolean DEFAULT false NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT plan_feature_entitlements_kind_allowed CHECK (((feature_kind)::text = ANY ((ARRAY['flag'::character varying, 'limit'::character varying])::text[]))),
    CONSTRAINT plan_feature_entitlements_settings_object CHECK ((jsonb_typeof(settings) = 'object'::text)),
    CONSTRAINT plan_feature_entitlements_typed_value CHECK (((((feature_kind)::text = 'flag'::text) AND (limit_value IS NULL) AND (unlimited = false)) OR (((feature_kind)::text = 'limit'::text) AND (((unlimited = true) AND (limit_value IS NULL)) OR ((unlimited = false) AND (limit_value IS NOT NULL) AND (limit_value >= 0))))))
);


--
-- Name: plan_feature_entitlements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.plan_feature_entitlements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: plan_feature_entitlements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.plan_feature_entitlements_id_seq OWNED BY public.plan_feature_entitlements.id;


--
-- Name: plan_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plan_prices (
    id bigint NOT NULL,
    plan_id bigint NOT NULL,
    billing_interval character varying(16) NOT NULL,
    currency character varying(3) NOT NULL,
    amount_cents bigint NOT NULL,
    lemon_store_id character varying(64),
    lemon_product_id character varying(64),
    lemon_variant_id character varying(64),
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT plan_prices_amount_non_negative CHECK ((amount_cents >= 0)),
    CONSTRAINT plan_prices_billing_interval_allowed CHECK (((billing_interval)::text = ANY ((ARRAY['monthly'::character varying, 'yearly'::character varying])::text[]))),
    CONSTRAINT plan_prices_currency_format CHECK (((currency)::text ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT plan_prices_lemon_mapping_complete CHECK ((((lemon_store_id IS NULL) AND (lemon_product_id IS NULL) AND (lemon_variant_id IS NULL)) OR ((lemon_store_id IS NOT NULL) AND ((lemon_store_id)::text = btrim((lemon_store_id)::text)) AND ((lemon_store_id)::text !~ '[[:space:]]'::text) AND ((char_length((lemon_store_id)::text) >= 1) AND (char_length((lemon_store_id)::text) <= 64)) AND (lemon_product_id IS NOT NULL) AND ((lemon_product_id)::text = btrim((lemon_product_id)::text)) AND ((lemon_product_id)::text !~ '[[:space:]]'::text) AND ((char_length((lemon_product_id)::text) >= 1) AND (char_length((lemon_product_id)::text) <= 64)) AND (lemon_variant_id IS NOT NULL) AND ((lemon_variant_id)::text = btrim((lemon_variant_id)::text)) AND ((lemon_variant_id)::text !~ '[[:space:]]'::text) AND ((char_length((lemon_variant_id)::text) >= 1) AND (char_length((lemon_variant_id)::text) <= 64)))))
);


--
-- Name: plan_prices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.plan_prices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: plan_prices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.plan_prices_id_seq OWNED BY public.plan_prices.id;


--
-- Name: plan_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plan_products (
    id bigint NOT NULL,
    plan_id bigint NOT NULL,
    product_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: plan_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.plan_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: plan_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.plan_products_id_seq OWNED BY public.plan_products.id;


--
-- Name: plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plans (
    id bigint NOT NULL,
    key character varying(63) NOT NULL,
    name character varying(100) NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    free boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT plans_description_normalized CHECK (((description = btrim(description)) AND (char_length(description) <= 2000))),
    CONSTRAINT plans_key_format CHECK ((((key)::text ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*$'::text) AND ((char_length((key)::text) >= 1) AND (char_length((key)::text) <= 63)))),
    CONSTRAINT plans_name_normalized CHECK ((((name)::text = btrim((name)::text)) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100)))),
    CONSTRAINT plans_position_non_negative CHECK (("position" >= 0))
);


--
-- Name: plans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.plans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: plans_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.plans_id_seq OWNED BY public.plans.id;


--
-- Name: product_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_features (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    key character varying(63) NOT NULL,
    name character varying(100) NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    kind character varying(16) NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT product_features_description_normalized CHECK (((description = btrim(description)) AND (char_length(description) <= 2000))),
    CONSTRAINT product_features_key_format CHECK ((((key)::text ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*$'::text) AND ((char_length((key)::text) >= 1) AND (char_length((key)::text) <= 63)))),
    CONSTRAINT product_features_kind_allowed CHECK (((kind)::text = ANY ((ARRAY['flag'::character varying, 'limit'::character varying])::text[]))),
    CONSTRAINT product_features_name_normalized CHECK ((((name)::text = btrim((name)::text)) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100))))
);


--
-- Name: product_features_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_features_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_features_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_features_id_seq OWNED BY public.product_features.id;


--
-- Name: product_membership_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_membership_roles (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    product_id bigint NOT NULL,
    product_membership_id bigint NOT NULL,
    product_role_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: product_membership_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_membership_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_membership_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_membership_roles_id_seq OWNED BY public.product_membership_roles.id;


--
-- Name: product_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_memberships (
    id bigint NOT NULL,
    organization_id bigint NOT NULL,
    organization_membership_id bigint NOT NULL,
    organization_membership_status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    product_id bigint NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT product_memberships_parent_membership_active CHECK (((organization_membership_status)::text = 'active'::text)),
    CONSTRAINT product_memberships_status_allowed CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying])::text[])))
);


--
-- Name: product_memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_memberships_id_seq OWNED BY public.product_memberships.id;


--
-- Name: product_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_permissions (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    key character varying(100) NOT NULL,
    name character varying(100) NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT product_permissions_description_normalized CHECK (((description = btrim(description)) AND (char_length(description) <= 2000))),
    CONSTRAINT product_permissions_key_format CHECK ((((key)::text ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*([.][a-z][a-z0-9]*(_[a-z0-9]+)*)+$'::text) AND ((char_length((key)::text) >= 3) AND (char_length((key)::text) <= 100)))),
    CONSTRAINT product_permissions_name_normalized CHECK ((((name)::text = btrim((name)::text)) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100))))
);


--
-- Name: product_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_permissions_id_seq OWNED BY public.product_permissions.id;


--
-- Name: product_role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_role_permissions (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    product_role_id bigint NOT NULL,
    product_permission_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: product_role_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_role_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_role_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_role_permissions_id_seq OWNED BY public.product_role_permissions.id;


--
-- Name: product_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_roles (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    organization_id bigint,
    key character varying(63) NOT NULL,
    name character varying(100) NOT NULL,
    system boolean DEFAULT true NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT product_roles_key_format CHECK ((((key)::text ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*$'::text) AND ((char_length((key)::text) >= 1) AND (char_length((key)::text) <= 63)))),
    CONSTRAINT product_roles_name_normalized CHECK ((((name)::text = btrim((name)::text)) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100)))),
    CONSTRAINT product_roles_system_scope_consistent CHECK ((((system = true) AND (organization_id IS NULL)) OR ((system = false) AND (organization_id IS NOT NULL))))
);


--
-- Name: product_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_roles_id_seq OWNED BY public.product_roles.id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    key character varying(63) NOT NULL,
    name character varying(100) NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT products_description_normalized CHECK (((description = btrim(description)) AND (char_length(description) <= 2000))),
    CONSTRAINT products_key_format CHECK ((((key)::text ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*$'::text) AND ((char_length((key)::text) >= 1) AND (char_length((key)::text) <= 63)))),
    CONSTRAINT products_name_normalized CHECK ((((name)::text = btrim((name)::text)) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100))))
);


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token_digest character varying(64) NOT NULL,
    ip_address inet,
    user_agent character varying(512),
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT sessions_expiry_after_creation CHECK ((expires_at > created_at)),
    CONSTRAINT sessions_token_digest_format CHECK (((token_digest)::text ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT sessions_user_agent_length CHECK (((user_agent IS NULL) OR (char_length((user_agent)::text) <= 512)))
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    name character varying(100) NOT NULL,
    email_address character varying(254) NOT NULL,
    password_digest character varying(255) NOT NULL,
    email_verified_at timestamp(6) without time zone,
    system_role character varying(32) DEFAULT 'user'::character varying NOT NULL,
    disabled_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT users_email_address_normalized CHECK ((((email_address)::text = lower(btrim((email_address)::text))) AND ((char_length((email_address)::text) >= 3) AND (char_length((email_address)::text) <= 254)))),
    CONSTRAINT users_name_normalized CHECK ((((name)::text = btrim((name)::text)) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100)))),
    CONSTRAINT users_password_digest_present CHECK (((char_length((password_digest)::text) >= 1) AND (char_length((password_digest)::text) <= 255))),
    CONSTRAINT users_system_role_allowed CHECK (((system_role)::text = ANY ((ARRAY['user'::character varying, 'platform_admin'::character varying])::text[])))
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: audit_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events ALTER COLUMN id SET DEFAULT nextval('public.audit_events_id_seq'::regclass);


--
-- Name: billing_checkout_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_checkout_attempts ALTER COLUMN id SET DEFAULT nextval('public.billing_checkout_attempts_id_seq'::regclass);


--
-- Name: billing_customers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_customers ALTER COLUMN id SET DEFAULT nextval('public.billing_customers_id_seq'::regclass);


--
-- Name: billing_plan_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plan_changes ALTER COLUMN id SET DEFAULT nextval('public.billing_plan_changes_id_seq'::regclass);


--
-- Name: billing_subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.billing_subscriptions_id_seq'::regclass);


--
-- Name: billing_webhook_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_webhook_events ALTER COLUMN id SET DEFAULT nextval('public.billing_webhook_events_id_seq'::regclass);


--
-- Name: organization_access_locators id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators ALTER COLUMN id SET DEFAULT nextval('public.organization_access_locators_id_seq'::regclass);


--
-- Name: organization_invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations ALTER COLUMN id SET DEFAULT nextval('public.organization_invitations_id_seq'::regclass);


--
-- Name: organization_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships ALTER COLUMN id SET DEFAULT nextval('public.organization_memberships_id_seq'::regclass);


--
-- Name: organizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations ALTER COLUMN id SET DEFAULT nextval('public.organizations_id_seq'::regclass);


--
-- Name: plan_feature_entitlements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements ALTER COLUMN id SET DEFAULT nextval('public.plan_feature_entitlements_id_seq'::regclass);


--
-- Name: plan_prices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_prices ALTER COLUMN id SET DEFAULT nextval('public.plan_prices_id_seq'::regclass);


--
-- Name: plan_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_products ALTER COLUMN id SET DEFAULT nextval('public.plan_products_id_seq'::regclass);


--
-- Name: plans id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans ALTER COLUMN id SET DEFAULT nextval('public.plans_id_seq'::regclass);


--
-- Name: product_features id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_features ALTER COLUMN id SET DEFAULT nextval('public.product_features_id_seq'::regclass);


--
-- Name: product_membership_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_membership_roles ALTER COLUMN id SET DEFAULT nextval('public.product_membership_roles_id_seq'::regclass);


--
-- Name: product_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_memberships ALTER COLUMN id SET DEFAULT nextval('public.product_memberships_id_seq'::regclass);


--
-- Name: product_permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_permissions ALTER COLUMN id SET DEFAULT nextval('public.product_permissions_id_seq'::regclass);


--
-- Name: product_role_permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_role_permissions ALTER COLUMN id SET DEFAULT nextval('public.product_role_permissions_id_seq'::regclass);


--
-- Name: product_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_roles ALTER COLUMN id SET DEFAULT nextval('public.product_roles_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: billing_checkout_attempts billing_checkout_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_checkout_attempts
    ADD CONSTRAINT billing_checkout_attempts_pkey PRIMARY KEY (id);


--
-- Name: billing_customers billing_customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_customers
    ADD CONSTRAINT billing_customers_pkey PRIMARY KEY (id);


--
-- Name: billing_plan_changes billing_plan_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plan_changes
    ADD CONSTRAINT billing_plan_changes_pkey PRIMARY KEY (id);


--
-- Name: billing_subscriptions billing_subscriptions_past_due_cycle_consistent; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_subscriptions
    ADD CONSTRAINT billing_subscriptions_past_due_cycle_consistent CHECK (((((status)::text = 'past_due'::text) AND (past_due_started_at IS NOT NULL) AND (past_due_started_at <= provider_updated_at)) OR (((status)::text <> 'past_due'::text) AND (past_due_started_at IS NULL)))) NOT VALID;


--
-- Name: billing_subscriptions billing_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_subscriptions
    ADD CONSTRAINT billing_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: billing_webhook_events billing_webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_webhook_events
    ADD CONSTRAINT billing_webhook_events_pkey PRIMARY KEY (id);


--
-- Name: organization_access_locators organization_access_locators_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT organization_access_locators_pkey PRIMARY KEY (id);


--
-- Name: organization_invitations organization_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_pkey PRIMARY KEY (id);


--
-- Name: organization_memberships organization_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: plan_feature_entitlements plan_feature_entitlements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements
    ADD CONSTRAINT plan_feature_entitlements_pkey PRIMARY KEY (id);


--
-- Name: plan_prices plan_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_prices
    ADD CONSTRAINT plan_prices_pkey PRIMARY KEY (id);


--
-- Name: plan_products plan_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_products
    ADD CONSTRAINT plan_products_pkey PRIMARY KEY (id);


--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT plans_pkey PRIMARY KEY (id);


--
-- Name: product_features product_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_features
    ADD CONSTRAINT product_features_pkey PRIMARY KEY (id);


--
-- Name: product_membership_roles product_membership_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_membership_roles
    ADD CONSTRAINT product_membership_roles_pkey PRIMARY KEY (id);


--
-- Name: product_memberships product_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_memberships
    ADD CONSTRAINT product_memberships_pkey PRIMARY KEY (id);


--
-- Name: product_permissions product_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_permissions
    ADD CONSTRAINT product_permissions_pkey PRIMARY KEY (id);


--
-- Name: product_role_permissions product_role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_role_permissions
    ADD CONSTRAINT product_role_permissions_pkey PRIMARY KEY (id);


--
-- Name: product_roles product_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_roles
    ADD CONSTRAINT product_roles_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_on_organization_id_status_role_ce3565acf4; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_organization_id_status_role_ce3565acf4 ON public.organization_memberships USING btree (organization_id, status, role);


--
-- Name: idx_on_organization_membership_id_c0ffad9c57; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_organization_membership_id_c0ffad9c57 ON public.organization_access_locators USING btree (organization_membership_id);


--
-- Name: index_audit_events_on_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_action ON public.audit_events USING btree (action);


--
-- Name: index_audit_events_on_actor_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_actor_user_id ON public.audit_events USING btree (actor_user_id);


--
-- Name: index_audit_events_on_org_and_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_org_and_actor ON public.audit_events USING btree (organization_id, actor_user_id);


--
-- Name: index_audit_events_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_organization_id ON public.audit_events USING btree (organization_id);


--
-- Name: index_audit_events_on_organization_id_and_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_organization_id_and_occurred_at ON public.audit_events USING btree (organization_id, occurred_at);


--
-- Name: index_billing_checkout_attempts_on_locator_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_checkout_attempts_on_locator_identity ON public.billing_checkout_attempts USING btree (id, organization_id, provider, environment, token_digest);


--
-- Name: index_billing_checkout_attempts_on_membership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_checkout_attempts_on_membership ON public.billing_checkout_attempts USING btree (initiated_by_membership_id);


--
-- Name: index_billing_checkout_attempts_on_one_pending_per_org; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_checkout_attempts_on_one_pending_per_org ON public.billing_checkout_attempts USING btree (organization_id) WHERE ((status)::text = ANY ((ARRAY['creating'::character varying, 'ready'::character varying, 'creation_unknown'::character varying])::text[]));


--
-- Name: index_billing_checkout_attempts_on_org_status_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_checkout_attempts_on_org_status_expiry ON public.billing_checkout_attempts USING btree (organization_id, status, expires_at);


--
-- Name: index_billing_checkout_attempts_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_checkout_attempts_on_organization_id ON public.billing_checkout_attempts USING btree (organization_id);


--
-- Name: index_billing_checkout_attempts_on_origin_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_checkout_attempts_on_origin_identity ON public.billing_checkout_attempts USING btree (id, organization_id, plan_price_id, provider, environment);


--
-- Name: index_billing_checkout_attempts_on_plan_price_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_checkout_attempts_on_plan_price_id ON public.billing_checkout_attempts USING btree (plan_price_id);


--
-- Name: index_billing_checkout_attempts_on_provider_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_checkout_attempts_on_provider_identity ON public.billing_checkout_attempts USING btree (provider, environment, provider_checkout_id) WHERE (provider_checkout_id IS NOT NULL);


--
-- Name: index_billing_checkout_attempts_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_checkout_attempts_on_token_digest ON public.billing_checkout_attempts USING btree (token_digest);


--
-- Name: index_billing_customers_on_org_provider_environment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_customers_on_org_provider_environment ON public.billing_customers USING btree (organization_id, provider, environment);


--
-- Name: index_billing_customers_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_customers_on_organization_id ON public.billing_customers USING btree (organization_id);


--
-- Name: index_billing_customers_on_provider_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_customers_on_provider_identity ON public.billing_customers USING btree (provider, environment, provider_customer_id);


--
-- Name: index_billing_customers_on_subscription_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_customers_on_subscription_identity ON public.billing_customers USING btree (id, organization_id, provider, environment, test_mode, provider_customer_id);


--
-- Name: index_billing_plan_changes_on_from_plan_price_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plan_changes_on_from_plan_price_id ON public.billing_plan_changes USING btree (from_plan_price_id);


--
-- Name: index_billing_plan_changes_on_membership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plan_changes_on_membership ON public.billing_plan_changes USING btree (requested_by_membership_id);


--
-- Name: index_billing_plan_changes_on_one_pending_per_subscription; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_plan_changes_on_one_pending_per_subscription ON public.billing_plan_changes USING btree (billing_subscription_id) WHERE ((status)::text = ANY ((ARRAY['pending'::character varying, 'submitted'::character varying, 'creation_unknown'::character varying])::text[]));


--
-- Name: index_billing_plan_changes_on_org_status_requested; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plan_changes_on_org_status_requested ON public.billing_plan_changes USING btree (organization_id, status, requested_at);


--
-- Name: index_billing_plan_changes_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plan_changes_on_organization_id ON public.billing_plan_changes USING btree (organization_id);


--
-- Name: index_billing_plan_changes_on_subscription_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plan_changes_on_subscription_history ON public.billing_plan_changes USING btree (billing_subscription_id, requested_at);


--
-- Name: index_billing_plan_changes_on_to_plan_price_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_plan_changes_on_to_plan_price_id ON public.billing_plan_changes USING btree (to_plan_price_id);


--
-- Name: index_billing_subscriptions_on_billing_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_subscriptions_on_billing_customer_id ON public.billing_subscriptions USING btree (billing_customer_id);


--
-- Name: index_billing_subscriptions_on_locator_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_subscriptions_on_locator_identity ON public.billing_subscriptions USING btree (id, organization_id, provider, environment, provider_subscription_id);


--
-- Name: index_billing_subscriptions_on_one_current_per_org; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_subscriptions_on_one_current_per_org ON public.billing_subscriptions USING btree (organization_id) WHERE current;


--
-- Name: index_billing_subscriptions_on_org_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_subscriptions_on_org_and_status ON public.billing_subscriptions USING btree (organization_id, status);


--
-- Name: index_billing_subscriptions_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_subscriptions_on_organization_id ON public.billing_subscriptions USING btree (organization_id);


--
-- Name: index_billing_subscriptions_on_plan_change_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_subscriptions_on_plan_change_identity ON public.billing_subscriptions USING btree (id, organization_id, provider, environment, test_mode);


--
-- Name: index_billing_subscriptions_on_plan_price_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_subscriptions_on_plan_price_id ON public.billing_subscriptions USING btree (plan_price_id);


--
-- Name: index_billing_subscriptions_on_provider_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_subscriptions_on_provider_customer ON public.billing_subscriptions USING btree (provider, environment, provider_customer_id);


--
-- Name: index_billing_subscriptions_on_provider_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_subscriptions_on_provider_identity ON public.billing_subscriptions USING btree (provider, environment, provider_subscription_id);


--
-- Name: index_billing_subscriptions_on_provider_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_subscriptions_on_provider_updated_at ON public.billing_subscriptions USING btree (provider, environment, provider_updated_at);


--
-- Name: index_billing_subscriptions_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_subscriptions_on_status ON public.billing_subscriptions USING btree (status);


--
-- Name: index_billing_webhook_events_on_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_webhook_events_on_fingerprint ON public.billing_webhook_events USING btree (fingerprint);


--
-- Name: index_billing_webhook_events_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_webhook_events_on_organization_id ON public.billing_webhook_events USING btree (organization_id);


--
-- Name: index_billing_webhook_events_on_provider_event_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_billing_webhook_events_on_provider_event_identity ON public.billing_webhook_events USING btree (provider, environment, provider_event_id) WHERE (provider_event_id IS NOT NULL);


--
-- Name: index_billing_webhook_events_on_provider_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_webhook_events_on_provider_resource ON public.billing_webhook_events USING btree (provider, environment, provider_resource_id);


--
-- Name: index_billing_webhook_events_on_status_and_received; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_billing_webhook_events_on_status_and_received ON public.billing_webhook_events USING btree (status, received_at);


--
-- Name: index_org_access_locators_on_user_and_organization; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_org_access_locators_on_user_and_organization ON public.organization_access_locators USING btree (user_id, organization_id);


--
-- Name: index_org_invitations_on_org_and_inviter; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_org_invitations_on_org_and_inviter ON public.organization_invitations USING btree (organization_id, inviter_id);


--
-- Name: index_org_invitations_on_org_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_org_invitations_on_org_status_created ON public.organization_invitations USING btree (organization_id, status, created_at);


--
-- Name: index_org_invitations_on_org_status_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_org_invitations_on_org_status_expiry ON public.organization_invitations USING btree (organization_id, status, expires_at);


--
-- Name: index_org_invitations_on_pending_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_org_invitations_on_pending_email ON public.organization_invitations USING btree (organization_id, lower((email_address)::text)) WHERE ((status)::text = 'pending'::text);


--
-- Name: index_org_memberships_on_id_and_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_org_memberships_on_id_and_organization_id ON public.organization_memberships USING btree (id, organization_id);


--
-- Name: index_org_memberships_on_id_org_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_org_memberships_on_id_org_and_status ON public.organization_memberships USING btree (id, organization_id, status);


--
-- Name: index_org_memberships_on_id_user_id_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_org_memberships_on_id_user_id_organization_id ON public.organization_memberships USING btree (id, user_id, organization_id);


--
-- Name: index_organization_access_locators_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organization_access_locators_on_organization_id ON public.organization_access_locators USING btree (organization_id);


--
-- Name: index_organization_access_locators_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organization_access_locators_on_user_id ON public.organization_access_locators USING btree (user_id);


--
-- Name: index_organization_invitations_on_inviter_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organization_invitations_on_inviter_id ON public.organization_invitations USING btree (inviter_id);


--
-- Name: index_organization_invitations_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organization_invitations_on_organization_id ON public.organization_invitations USING btree (organization_id);


--
-- Name: index_organization_invitations_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organization_invitations_on_token_digest ON public.organization_invitations USING btree (token_digest);


--
-- Name: index_organization_memberships_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organization_memberships_on_organization_id ON public.organization_memberships USING btree (organization_id);


--
-- Name: index_organization_memberships_on_organization_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organization_memberships_on_organization_id_and_user_id ON public.organization_memberships USING btree (organization_id, user_id);


--
-- Name: index_organization_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organization_memberships_on_user_id ON public.organization_memberships USING btree (user_id);


--
-- Name: index_organizations_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organizations_on_public_id ON public.organizations USING btree (public_id);


--
-- Name: index_organizations_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_organizations_on_slug ON public.organizations USING btree (slug);


--
-- Name: index_organizations_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_organizations_on_status ON public.organizations USING btree (status);


--
-- Name: index_plan_feature_entitlements_on_plan_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plan_feature_entitlements_on_plan_product_id ON public.plan_feature_entitlements USING btree (plan_product_id);


--
-- Name: index_plan_feature_entitlements_on_product_and_feature; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_plan_feature_entitlements_on_product_and_feature ON public.plan_feature_entitlements USING btree (plan_product_id, product_feature_id);


--
-- Name: index_plan_feature_entitlements_on_product_feature_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plan_feature_entitlements_on_product_feature_id ON public.plan_feature_entitlements USING btree (product_feature_id);


--
-- Name: index_plan_feature_entitlements_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plan_feature_entitlements_on_product_id ON public.plan_feature_entitlements USING btree (product_id);


--
-- Name: index_plan_prices_on_lemon_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_plan_prices_on_lemon_variant_id ON public.plan_prices USING btree (lemon_variant_id) WHERE (lemon_variant_id IS NOT NULL);


--
-- Name: index_plan_prices_on_plan_and_selection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plan_prices_on_plan_and_selection ON public.plan_prices USING btree (plan_id, active, billing_interval, currency);


--
-- Name: index_plan_prices_on_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plan_prices_on_plan_id ON public.plan_prices USING btree (plan_id);


--
-- Name: index_plan_products_on_id_and_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_plan_products_on_id_and_product_id ON public.plan_products USING btree (id, product_id);


--
-- Name: index_plan_products_on_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plan_products_on_plan_id ON public.plan_products USING btree (plan_id);


--
-- Name: index_plan_products_on_plan_id_and_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_plan_products_on_plan_id_and_product_id ON public.plan_products USING btree (plan_id, product_id);


--
-- Name: index_plan_products_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plan_products_on_product_id ON public.plan_products USING btree (product_id);


--
-- Name: index_plans_on_active_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_plans_on_active_and_position ON public.plans USING btree (active, "position");


--
-- Name: index_plans_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_plans_on_key ON public.plans USING btree (key);


--
-- Name: index_plans_on_single_active_free; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_plans_on_single_active_free ON public.plans USING btree (free) WHERE (active AND free);


--
-- Name: index_product_features_on_id_product_and_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_features_on_id_product_and_kind ON public.product_features USING btree (id, product_id, kind);


--
-- Name: index_product_features_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_features_on_product_id ON public.product_features USING btree (product_id);


--
-- Name: index_product_features_on_product_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_features_on_product_id_and_active ON public.product_features USING btree (product_id, active);


--
-- Name: index_product_features_on_product_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_features_on_product_id_and_key ON public.product_features USING btree (product_id, key);


--
-- Name: index_product_membership_roles_on_membership_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_membership_roles_on_membership_and_role ON public.product_membership_roles USING btree (product_membership_id, product_role_id);


--
-- Name: index_product_membership_roles_on_membership_org_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_membership_roles_on_membership_org_product ON public.product_membership_roles USING btree (product_membership_id, organization_id, product_id);


--
-- Name: index_product_membership_roles_on_org_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_membership_roles_on_org_and_product ON public.product_membership_roles USING btree (organization_id, product_id);


--
-- Name: index_product_membership_roles_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_membership_roles_on_organization_id ON public.product_membership_roles USING btree (organization_id);


--
-- Name: index_product_membership_roles_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_membership_roles_on_product_id ON public.product_membership_roles USING btree (product_id);


--
-- Name: index_product_membership_roles_on_role_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_membership_roles_on_role_and_product ON public.product_membership_roles USING btree (product_role_id, product_id);


--
-- Name: index_product_memberships_on_active_org_membership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_memberships_on_active_org_membership ON public.product_memberships USING btree (organization_membership_id, organization_id, organization_membership_status);


--
-- Name: index_product_memberships_on_id_org_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_memberships_on_id_org_and_product ON public.product_memberships USING btree (id, organization_id, product_id);


--
-- Name: index_product_memberships_on_membership_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_memberships_on_membership_and_product ON public.product_memberships USING btree (organization_membership_id, product_id);


--
-- Name: index_product_memberships_on_org_product_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_memberships_on_org_product_and_status ON public.product_memberships USING btree (organization_id, product_id, status);


--
-- Name: index_product_memberships_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_memberships_on_organization_id ON public.product_memberships USING btree (organization_id);


--
-- Name: index_product_memberships_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_memberships_on_product_id ON public.product_memberships USING btree (product_id);


--
-- Name: index_product_permissions_on_id_and_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_permissions_on_id_and_product_id ON public.product_permissions USING btree (id, product_id);


--
-- Name: index_product_permissions_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_permissions_on_product_id ON public.product_permissions USING btree (product_id);


--
-- Name: index_product_permissions_on_product_id_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_permissions_on_product_id_and_key ON public.product_permissions USING btree (product_id, key);


--
-- Name: index_product_role_permissions_on_permission_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_role_permissions_on_permission_and_product ON public.product_role_permissions USING btree (product_permission_id, product_id);


--
-- Name: index_product_role_permissions_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_role_permissions_on_product_id ON public.product_role_permissions USING btree (product_id);


--
-- Name: index_product_role_permissions_on_role_and_permission; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_role_permissions_on_role_and_permission ON public.product_role_permissions USING btree (product_role_id, product_permission_id);


--
-- Name: index_product_role_permissions_on_role_and_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_role_permissions_on_role_and_product ON public.product_role_permissions USING btree (product_role_id, product_id);


--
-- Name: index_product_roles_on_id_and_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_roles_on_id_and_product_id ON public.product_roles USING btree (id, product_id);


--
-- Name: index_product_roles_on_org_product_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_roles_on_org_product_and_active ON public.product_roles USING btree (organization_id, product_id, active);


--
-- Name: index_product_roles_on_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_roles_on_organization_id ON public.product_roles USING btree (organization_id);


--
-- Name: index_product_roles_on_organization_product_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_roles_on_organization_product_and_key ON public.product_roles USING btree (organization_id, product_id, key) WHERE (organization_id IS NOT NULL);


--
-- Name: index_product_roles_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_roles_on_product_id ON public.product_roles USING btree (product_id);


--
-- Name: index_product_roles_on_product_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_roles_on_product_id_and_active ON public.product_roles USING btree (product_id, active);


--
-- Name: index_product_roles_on_system_product_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_roles_on_system_product_and_key ON public.product_roles USING btree (product_id, key) WHERE (organization_id IS NULL);


--
-- Name: index_products_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_products_on_active ON public.products USING btree (active);


--
-- Name: index_products_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_key ON public.products USING btree (key);


--
-- Name: index_sessions_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_expires_at ON public.sessions USING btree (expires_at);


--
-- Name: index_sessions_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sessions_on_token_digest ON public.sessions USING btree (token_digest);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_users_on_lower_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_lower_email_address ON public.users USING btree (lower((email_address)::text));


--
-- Name: index_users_on_system_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_system_role ON public.users USING btree (system_role);


--
-- Name: audit_events audit_events_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_are_append_only BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_event_mutation();


--
-- Name: billing_subscriptions billing_subscription_history_is_preserved; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER billing_subscription_history_is_preserved BEFORE DELETE OR UPDATE ON public.billing_subscriptions FOR EACH ROW EXECUTE FUNCTION public.protect_billing_subscription_history();


--
-- Name: organization_memberships organization_must_have_active_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER organization_must_have_active_owner AFTER INSERT OR DELETE OR UPDATE ON public.organization_memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_organization_active_owner();


--
-- Name: organizations organization_must_have_active_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER organization_must_have_active_owner AFTER INSERT ON public.organizations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_organization_active_owner();


--
-- Name: plan_prices plan_prices_plan_identity_is_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER plan_prices_plan_identity_is_immutable BEFORE UPDATE OF plan_id ON public.plan_prices FOR EACH ROW EXECUTE FUNCTION public.protect_plan_price_plan_identity();


--
-- Name: product_membership_roles product_membership_roles_scope_is_valid; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_membership_roles_scope_is_valid BEFORE INSERT OR UPDATE OF organization_id, product_id, product_role_id ON public.product_membership_roles FOR EACH ROW EXECUTE FUNCTION public.enforce_product_membership_role_scope();


--
-- Name: product_roles product_roles_identity_is_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_roles_identity_is_immutable BEFORE UPDATE OF product_id, organization_id, key, system ON public.product_roles FOR EACH ROW EXECUTE FUNCTION public.protect_product_role_identity();


--
-- Name: audit_events fk_audit_events_actor_membership; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_audit_events_actor_membership FOREIGN KEY (organization_id, actor_user_id) REFERENCES public.organization_memberships(organization_id, user_id) ON DELETE RESTRICT;


--
-- Name: billing_checkout_attempts fk_billing_checkout_attempts_membership_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_checkout_attempts
    ADD CONSTRAINT fk_billing_checkout_attempts_membership_tenant FOREIGN KEY (initiated_by_membership_id, organization_id) REFERENCES public.organization_memberships(id, organization_id) ON DELETE RESTRICT;


--
-- Name: billing_plan_changes fk_billing_plan_changes_from_plan_price; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plan_changes
    ADD CONSTRAINT fk_billing_plan_changes_from_plan_price FOREIGN KEY (from_plan_price_id) REFERENCES public.plan_prices(id) ON DELETE RESTRICT;


--
-- Name: billing_plan_changes fk_billing_plan_changes_membership_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plan_changes
    ADD CONSTRAINT fk_billing_plan_changes_membership_tenant FOREIGN KEY (requested_by_membership_id, organization_id) REFERENCES public.organization_memberships(id, organization_id) ON DELETE RESTRICT;


--
-- Name: billing_plan_changes fk_billing_plan_changes_subscription_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plan_changes
    ADD CONSTRAINT fk_billing_plan_changes_subscription_tenant FOREIGN KEY (billing_subscription_id, organization_id, provider, environment, test_mode) REFERENCES public.billing_subscriptions(id, organization_id, provider, environment, test_mode) ON DELETE RESTRICT;


--
-- Name: billing_plan_changes fk_billing_plan_changes_to_plan_price; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plan_changes
    ADD CONSTRAINT fk_billing_plan_changes_to_plan_price FOREIGN KEY (to_plan_price_id) REFERENCES public.plan_prices(id) ON DELETE RESTRICT;


--
-- Name: billing_subscriptions fk_billing_subscriptions_customer_identity; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_subscriptions
    ADD CONSTRAINT fk_billing_subscriptions_customer_identity FOREIGN KEY (billing_customer_id, organization_id, provider, environment, test_mode, provider_customer_id) REFERENCES public.billing_customers(id, organization_id, provider, environment, test_mode, provider_customer_id) ON DELETE RESTRICT;


--
-- Name: organization_access_locators fk_org_access_locators_membership_identity; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT fk_org_access_locators_membership_identity FOREIGN KEY (organization_membership_id, user_id, organization_id) REFERENCES public.organization_memberships(id, user_id, organization_id) ON DELETE RESTRICT;


--
-- Name: organization_invitations fk_org_invitations_inviter_membership; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT fk_org_invitations_inviter_membership FOREIGN KEY (organization_id, inviter_id) REFERENCES public.organization_memberships(organization_id, user_id) ON DELETE RESTRICT;


--
-- Name: plan_feature_entitlements fk_plan_feature_entitlements_plan_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements
    ADD CONSTRAINT fk_plan_feature_entitlements_plan_product FOREIGN KEY (plan_product_id, product_id) REFERENCES public.plan_products(id, product_id) ON DELETE RESTRICT;


--
-- Name: plan_feature_entitlements fk_plan_feature_entitlements_product_feature; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements
    ADD CONSTRAINT fk_plan_feature_entitlements_product_feature FOREIGN KEY (product_feature_id, product_id, feature_kind) REFERENCES public.product_features(id, product_id, kind) ON DELETE RESTRICT;


--
-- Name: product_membership_roles fk_product_membership_roles_membership_scope; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_membership_roles
    ADD CONSTRAINT fk_product_membership_roles_membership_scope FOREIGN KEY (product_membership_id, organization_id, product_id) REFERENCES public.product_memberships(id, organization_id, product_id) ON DELETE CASCADE;


--
-- Name: product_membership_roles fk_product_membership_roles_role_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_membership_roles
    ADD CONSTRAINT fk_product_membership_roles_role_product FOREIGN KEY (product_role_id, product_id) REFERENCES public.product_roles(id, product_id) ON DELETE RESTRICT;


--
-- Name: product_memberships fk_product_memberships_active_organization_membership; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_memberships
    ADD CONSTRAINT fk_product_memberships_active_organization_membership FOREIGN KEY (organization_membership_id, organization_id, organization_membership_status) REFERENCES public.organization_memberships(id, organization_id, status) ON DELETE RESTRICT;


--
-- Name: product_role_permissions fk_product_role_permissions_permission_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_role_permissions
    ADD CONSTRAINT fk_product_role_permissions_permission_product FOREIGN KEY (product_permission_id, product_id) REFERENCES public.product_permissions(id, product_id) ON DELETE RESTRICT;


--
-- Name: product_role_permissions fk_product_role_permissions_role_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_role_permissions
    ADD CONSTRAINT fk_product_role_permissions_role_product FOREIGN KEY (product_role_id, product_id) REFERENCES public.product_roles(id, product_id) ON DELETE RESTRICT;


--
-- Name: product_role_permissions fk_rails_0557fef164; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_role_permissions
    ADD CONSTRAINT fk_rails_0557fef164 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: plan_products fk_rails_19f4567acb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_products
    ADD CONSTRAINT fk_rails_19f4567acb FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE RESTRICT;


--
-- Name: organization_access_locators fk_rails_1fbdd512c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT fk_rails_1fbdd512c3 FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_invitations fk_rails_25f1cad884; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT fk_rails_25f1cad884 FOREIGN KEY (inviter_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: audit_events fk_rails_2e3720791c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_2e3720791c FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: organization_invitations fk_rails_3046f3efef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT fk_rails_3046f3efef FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: product_memberships fk_rails_3409fb7b87; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_memberships
    ADD CONSTRAINT fk_rails_3409fb7b87 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: billing_plan_changes fk_rails_39ea69e58b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_plan_changes
    ADD CONSTRAINT fk_rails_39ea69e58b FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: plan_prices fk_rails_3e32e08315; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_prices
    ADD CONSTRAINT fk_rails_3e32e08315 FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE RESTRICT;


--
-- Name: plan_feature_entitlements fk_rails_4245058809; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements
    ADD CONSTRAINT fk_rails_4245058809 FOREIGN KEY (plan_product_id) REFERENCES public.plan_products(id) ON DELETE RESTRICT;


--
-- Name: billing_checkout_attempts fk_rails_52f07620e4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_checkout_attempts
    ADD CONSTRAINT fk_rails_52f07620e4 FOREIGN KEY (plan_price_id) REFERENCES public.plan_prices(id) ON DELETE RESTRICT;


--
-- Name: organization_memberships fk_rails_57cf70d280; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT fk_rails_57cf70d280 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: plan_products fk_rails_6cc811864d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_products
    ADD CONSTRAINT fk_rails_6cc811864d FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: billing_customers fk_rails_6d4927c1b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_customers
    ADD CONSTRAINT fk_rails_6d4927c1b8 FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_memberships fk_rails_715ab7f4fe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT fk_rails_715ab7f4fe FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: billing_webhook_events fk_rails_79fcf94956; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_webhook_events
    ADD CONSTRAINT fk_rails_79fcf94956 FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: product_roles fk_rails_82bd80c9b1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_roles
    ADD CONSTRAINT fk_rails_82bd80c9b1 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: product_features fk_rails_9019f50ede; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_features
    ADD CONSTRAINT fk_rails_9019f50ede FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: organization_access_locators fk_rails_903c442217; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT fk_rails_903c442217 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: product_membership_roles fk_rails_ae303566d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_membership_roles
    ADD CONSTRAINT fk_rails_ae303566d8 FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: plan_feature_entitlements fk_rails_b7d4a4f088; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements
    ADD CONSTRAINT fk_rails_b7d4a4f088 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: audit_events fk_rails_be0ed9e37f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_be0ed9e37f FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: billing_subscriptions fk_rails_c4450e56ec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_subscriptions
    ADD CONSTRAINT fk_rails_c4450e56ec FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: product_roles fk_rails_cce658936e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_roles
    ADD CONSTRAINT fk_rails_cce658936e FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: billing_checkout_attempts fk_rails_ce0ba24f13; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_checkout_attempts
    ADD CONSTRAINT fk_rails_ce0ba24f13 FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: product_permissions fk_rails_d7e4cf7e2f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_permissions
    ADD CONSTRAINT fk_rails_d7e4cf7e2f FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: plan_feature_entitlements fk_rails_dcabbaef40; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements
    ADD CONSTRAINT fk_rails_dcabbaef40 FOREIGN KEY (product_feature_id) REFERENCES public.product_features(id) ON DELETE RESTRICT;


--
-- Name: billing_subscriptions fk_rails_e25cba9faa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_subscriptions
    ADD CONSTRAINT fk_rails_e25cba9faa FOREIGN KEY (plan_price_id) REFERENCES public.plan_prices(id) ON DELETE RESTRICT;


--
-- Name: billing_subscriptions fk_rails_e3ce32be2a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_subscriptions
    ADD CONSTRAINT fk_rails_e3ce32be2a FOREIGN KEY (billing_customer_id) REFERENCES public.billing_customers(id) ON DELETE RESTRICT;


--
-- Name: product_memberships fk_rails_f0c84e845b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_memberships
    ADD CONSTRAINT fk_rails_f0c84e845b FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: product_membership_roles fk_rails_f682672ff7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_membership_roles
    ADD CONSTRAINT fk_rails_f682672ff7 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260716040000'),
('20260716030100'),
('20260716030000'),
('20260716020000'),
('20260716010600'),
('20260716001730'),
('20260715170300'),
('20260715170200'),
('20260715170100'),
('20260715170000');

