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
-- Name: organization_memberships organization_must_have_active_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER organization_must_have_active_owner AFTER INSERT OR DELETE OR UPDATE ON public.organization_memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_organization_active_owner();


--
-- Name: organizations organization_must_have_active_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER organization_must_have_active_owner AFTER INSERT ON public.organizations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_organization_active_owner();


--
-- Name: audit_events fk_audit_events_actor_membership; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_audit_events_actor_membership FOREIGN KEY (organization_id, actor_user_id) REFERENCES public.organization_memberships(organization_id, user_id) ON DELETE RESTRICT;


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
-- Name: plan_feature_entitlements fk_rails_dcabbaef40; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_feature_entitlements
    ADD CONSTRAINT fk_rails_dcabbaef40 FOREIGN KEY (product_feature_id) REFERENCES public.product_features(id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260716010600'),
('20260716001730'),
('20260715170300'),
('20260715170200'),
('20260715170100'),
('20260715170000'),
('0');

