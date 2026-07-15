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
-- Name: organization_access_locators id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators ALTER COLUMN id SET DEFAULT nextval('public.organization_access_locators_id_seq'::regclass);


--
-- Name: organization_memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships ALTER COLUMN id SET DEFAULT nextval('public.organization_memberships_id_seq'::regclass);


--
-- Name: organizations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations ALTER COLUMN id SET DEFAULT nextval('public.organizations_id_seq'::regclass);


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
-- Name: organization_access_locators organization_access_locators_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT organization_access_locators_pkey PRIMARY KEY (id);


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
-- Name: index_org_access_locators_on_user_and_organization; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_org_access_locators_on_user_and_organization ON public.organization_access_locators USING btree (user_id, organization_id);


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
-- Name: organization_memberships organization_must_have_active_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER organization_must_have_active_owner AFTER INSERT OR DELETE OR UPDATE ON public.organization_memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_organization_active_owner();


--
-- Name: organizations organization_must_have_active_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER organization_must_have_active_owner AFTER INSERT ON public.organizations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_organization_active_owner();


--
-- Name: organization_access_locators fk_org_access_locators_membership_identity; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT fk_org_access_locators_membership_identity FOREIGN KEY (organization_membership_id, user_id, organization_id) REFERENCES public.organization_memberships(id, user_id, organization_id) ON DELETE RESTRICT;


--
-- Name: organization_access_locators fk_rails_1fbdd512c3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT fk_rails_1fbdd512c3 FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_memberships fk_rails_57cf70d280; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT fk_rails_57cf70d280 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


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
-- Name: organization_access_locators fk_rails_903c442217; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_access_locators
    ADD CONSTRAINT fk_rails_903c442217 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260715170300'),
('20260715170200'),
('20260715170100'),
('20260715170000'),
('0');

