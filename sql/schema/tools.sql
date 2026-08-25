-- 2026-08-10  The tooling schema as production actually has it.
--
-- This is a GENERATED SNAPSHOT, not a migration. Nothing here is a change to apply to
-- production - production is where it was read from. It exists because the dated files in
-- sql/ no longer add up to what is running: five views (tools_v_part_tooling, tools_v_reorder,
-- tools_v_stock, tools_v_stock_by_designation, tools_v_where_used) exist on the server and are
-- written down in no migration at all, so a database rebuilt from sql/ alone comes out missing
-- them. Read this file to know what the shape IS; keep writing dated migrations for changes.
--
-- Captured 2026-08-10 from 192.168.0.5, and verified by replaying it into an empty database:
-- 9 tables, 5 views, 30 indexes, 26 policies, 3 triggers, 7 functions, zero errors, and those
-- six counts equal production's.
--
-- READ THIS BEFORE TREATING IT AS THE TARGET SHAPE. Production and the development copy have
-- drifted in BOTH directions, so neither one is simply ahead of the other:
--
--   Production has, and local does not:
--     * the five tools_v_* views above
--     * constraints and id sequences under their renamed form - tools_category_pkey,
--       tools_item_pkey, tools_master_id_seq. Local still carries the pre-rename names the
--       import left: out_tool_category_pkey, out_part_pkey, out_tool_id_seq.
--
--   Local has, and production does not:
--     * tools_master_code_seq and tools_item_code_seq, with the DEFAULTs that make a code
--       assign itself - 'FTL-'||lpad(...,4) on tools_master.tool_code, 'FTI-'||lpad(...,5) on
--       tools_item.item_code. That is sql/2026-08-06_tooling_codes_and_intake.sql, which has
--       never been run on production.
--     * the unique index from sql/2026-08-06_tooling_usage_unique.sql.
--
--   Both have v_tools_item_stock, so both did receive sql/2026-08-05_tooling_access.sql.
--
-- AND THE DATA IS ONLY IN ONE OF THEM. On 2026-08-10 every tools_* table on production has
-- zero rows. The 309 tool types, 345 stockable items, 138 assignments and 185 opening
-- movements that 2026-08-05_tooling_access.sql was written about are on the development copy
-- and nowhere else. So this file records production's SHAPE while production holds none of the
-- tooling DATA - do not read a dump of an empty schema as the state of the module.
--
-- TO REGENERATE, when the shape changes again:
--
--   pg_dump -h 192.168.0.5 -p 5432 -U postgres.your-tenant-id -d postgres \
--           --schema-only --no-owner -t 'public.tools_*'
--
--   That covers tables, constraints, indexes, triggers, views, RLS and grants. It does NOT
--   cover the two enum types or the seven functions - pg_dump's -t selects relations only, and
--   the triggers and policies below call functions that would then not exist. They are queried
--   separately (pg_get_functiondef over pg_proc, pg_enum for the labels) and placed above the
--   dump, which is why this file is assembled rather than dumped in one command.
--
-- ORDERING. check_function_bodies is off for the same reason pg_dump turns it off: three of the
-- functions are SQL-language, and tools_current_role() reads tools_profile - a table created
-- further down. Without it Postgres resolves the body at CREATE time and the file cannot be run
-- in any single order, because the triggers need the functions and the functions need the tables.
--
-- PREREQUISITES an empty database does not have. Replaying this file needs all four:
--   * the pg_trgm extension          - two GIN indexes use gin_trgm_ops
--   * schema auth, with auth.users   - tools_profile.id is a foreign key to it
--   * auth.uid()                     - tools_current_role() calls it
--   * roles anon, authenticated, service_role - the GRANTs at the foot name them
--
-- WHAT THE POLICIES ASSUME, which is worth knowing before trusting them. tools_current_role()
-- resolves through auth.uid(), and this application does not use Supabase Auth - it signs in
-- against AdminCredential and keeps the result in sessionStorage, so every request arrives on
-- the shared anon key and auth.uid() is null. The role therefore falls back to 'viewer' for
-- every caller. 2026-08-05_tooling_access.sql is the file that made these tables reachable
-- anyway, and NOTE 3 in it states what that costs; this snapshot only records the result.

SET check_function_bodies = false;

CREATE TYPE public.tools_txn_type AS ENUM ('OPENING', 'RECEIPT_PO', 'ISSUE_PRD', 'ISSUE_SPARE', 'RETURN_REUSE', 'RETURN_SCRAP', 'SELL', 'ADJUST');

CREATE TYPE public.tools_user_role AS ENUM ('viewer', 'operator', 'storeman', 'admin');

CREATE OR REPLACE FUNCTION public.tools_can_move_stock()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$ select tools_current_role() in ('operator','storeman','admin') $function$
;

CREATE OR REPLACE FUNCTION public.tools_current_role()
 RETURNS tools_user_role
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select coalesce((select role from tools_profile where id = auth.uid()), 'viewer');
$function$
;

CREATE OR REPLACE FUNCTION public.tools_is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$ select tools_current_role() = 'admin' $function$
;

CREATE OR REPLACE FUNCTION public.tools_record_movement(p_item_code text, p_txn_type tools_txn_type, p_qty integer, p_part_no text DEFAULT NULL::text, p_process text DEFAULT NULL::text, p_machine text DEFAULT NULL::text, p_po_no text DEFAULT NULL::text, p_remarks text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_item bigint; v_part bigint; v_proc smallint; v_id bigint; v_on_hand integer;
begin
    if not tools_can_move_stock() then
        raise exception 'not permitted to record stock movements';
    end if;

    select id, qty_on_hand into v_item, v_on_hand
      from tools_item where item_code = p_item_code and is_active;
    if v_item is null then
        raise exception 'unknown or inactive tool item %', p_item_code;
    end if;

    if p_part_no is not null then
        select id into v_part from tools_part where part_no = p_part_no;
        if v_part is null then raise exception 'unknown part %', p_part_no; end if;
    end if;
    if p_process is not null then
        select id into v_proc from tools_process where code = upper(p_process);
    end if;

    if p_qty < 0 and v_on_hand + p_qty < 0 then
        raise exception 'only % on hand for %, cannot issue %',
              v_on_hand, p_item_code, abs(p_qty);
    end if;

    insert into tools_txn (tool_item_id, txn_type, qty, part_id, process_id,
                              machine, po_no, performed_by, remarks)
    values (v_item, p_txn_type, p_qty, v_part, v_proc,
            p_machine, p_po_no, auth.uid(), p_remarks)
    returning id into v_id;

    return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.tools_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$ begin new.updated_at = now(); return new; end $function$
;

CREATE OR REPLACE FUNCTION public.tools_txn_apply()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    if tg_op = 'INSERT' then
        update tools_item set qty_on_hand = qty_on_hand + new.qty where id = new.tool_item_id;
    elsif tg_op = 'DELETE' then
        update tools_item set qty_on_hand = qty_on_hand - old.qty where id = old.tool_item_id;
    else
        update tools_item set qty_on_hand = qty_on_hand - old.qty where id = old.tool_item_id;
        update tools_item set qty_on_hand = qty_on_hand + new.qty where id = new.tool_item_id;
    end if;
    return null;
end $function$
;

CREATE OR REPLACE FUNCTION public.tools_txn_check_sign()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    if new.txn_type in ('RECEIPT_PO','RETURN_REUSE','OPENING') and new.qty < 0 then
        raise exception '% must be a positive quantity', new.txn_type;
    elsif new.txn_type in ('ISSUE_PRD','ISSUE_SPARE','SELL','RETURN_SCRAP') and new.qty > 0 then
        raise exception '% must be a negative quantity', new.txn_type;
    end if;
    return new;
end $function$
;

--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.8

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: tools_category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_category (
    id smallint NOT NULL,
    code text NOT NULL,
    name text NOT NULL
);


--
-- Name: tools_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_item (
    id bigint NOT NULL,
    tool_id bigint NOT NULL,
    item_code text NOT NULL,
    mfr_code text,
    brand text,
    supplier text,
    location text,
    reorder_point integer,
    qty_on_hand integer DEFAULT 0 NOT NULL,
    is_preferred boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    remarks text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: COLUMN tools_item.qty_on_hand; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tools_item.qty_on_hand IS 'INERT as of 2026-08-05. Backfilled once from tools_txn so it is not a lie, then left alone - nothing maintains it and nothing reads it. Stock comes from v_tools_item_stock. It is kept rather than dropped because dropping a column is the one change in this file that re-running it could not undo.';


--
-- Name: tools_item_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tools_item ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tools_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tools_master; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_master (
    id bigint NOT NULL,
    tool_code text NOT NULL,
    category_id smallint NOT NULL,
    tool_name text NOT NULL,
    nominal_size numeric(10,3),
    needs_review boolean DEFAULT false NOT NULL,
    remarks text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tools_master_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tools_master ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tools_master_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tools_part; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_part (
    id bigint NOT NULL,
    part_no text NOT NULL,
    description text,
    customer text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tools_part_demand; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_part_demand (
    id bigint NOT NULL,
    part_id bigint NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    qty_pcs integer NOT NULL
);


--
-- Name: tools_part_demand_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tools_part_demand ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tools_part_demand_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tools_part_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tools_part ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tools_part_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tools_process; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_process (
    id smallint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    family text NOT NULL,
    seq_no smallint,
    CONSTRAINT tools_process_family_check CHECK ((family = ANY (ARRAY['SWISS_AUTO'::text, 'TURNING'::text, 'MILLING'::text, 'HARD_TURNING'::text, 'STAMPING'::text, 'OTHER'::text])))
);


--
-- Name: tools_profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_profile (
    id uuid NOT NULL,
    full_name text NOT NULL,
    initials text,
    role public.tools_user_role DEFAULT 'viewer'::public.tools_user_role NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tools_txn; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_txn (
    id bigint NOT NULL,
    tool_item_id bigint NOT NULL,
    txn_type public.tools_txn_type NOT NULL,
    qty integer NOT NULL,
    txn_at timestamp with time zone DEFAULT now() NOT NULL,
    part_id bigint,
    process_id smallint,
    machine text,
    po_no text,
    performed_by uuid DEFAULT auth.uid(),
    remarks text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    txn_by text,
    txn_by_position text,
    CONSTRAINT tools_txn_direction_ck CHECK (
CASE txn_type
    WHEN 'OPENING'::public.tools_txn_type THEN (qty > 0)
    WHEN 'RECEIPT_PO'::public.tools_txn_type THEN (qty > 0)
    WHEN 'RETURN_REUSE'::public.tools_txn_type THEN (qty > 0)
    WHEN 'RETURN_SCRAP'::public.tools_txn_type THEN (qty > 0)
    WHEN 'ISSUE_PRD'::public.tools_txn_type THEN (qty < 0)
    WHEN 'ISSUE_SPARE'::public.tools_txn_type THEN (qty < 0)
    WHEN 'SELL'::public.tools_txn_type THEN (qty < 0)
    ELSE true
END),
    CONSTRAINT tools_txn_qty_check CHECK ((qty <> 0))
);


--
-- Name: COLUMN tools_txn.qty; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tools_txn.qty IS 'Signed. Negative leaves the shelf, positive arrives, never 0 (out_tool_txn_qty_check). The exception is RETURN_SCRAP, where a positive qty counts tools worn out in service and moves nothing onto the shelf. Use v_tools_item_stock rather than summing this column by hand.';


--
-- Name: COLUMN tools_txn.performed_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tools_txn.performed_by IS 'INERT. uuid default uid() referencing tools_profile -> auth.users, from the original import. This application has no Supabase Auth session, so uid() is always null and this column can never be filled by it. Kept, unread, because dropping it would break the FK to tools_profile for anything that later does use Auth. Read txn_by instead.';


--
-- Name: COLUMN tools_txn.txn_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tools_txn.txn_by IS 'Name from EmployeeTable of whoever recorded this movement. Identity was proven by EmployeeTable.pin - the PIN itself is never stored here. The same pattern as Data_IPQC.sa_by, and for the same reason: this application has no Supabase Auth session.';


--
-- Name: COLUMN tools_txn.txn_by_position; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tools_txn.txn_by_position IS 'That person''s position at the time, copied rather than joined, so a later change of role cannot rewrite who signed for a movement that has already happened.';


--
-- Name: CONSTRAINT tools_txn_direction_ck ON tools_txn; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON CONSTRAINT tools_txn_direction_ck ON public.tools_txn IS 'Direction lives in the sign of qty; txn_type says why. RETURN_SCRAP is positive and carries a count of tools worn out in service - it has no shelf effect, because the tools left the shelf when they were issued. ADJUST is exempt because a stock correction goes either way.';


--
-- Name: tools_txn_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tools_txn ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tools_txn_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tools_usage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tools_usage (
    id bigint NOT NULL,
    tool_id bigint NOT NULL,
    part_id bigint NOT NULL,
    process_id smallint,
    tool_life_pcs integer,
    setup_std_dia_mm numeric(10,3),
    is_active boolean DEFAULT true NOT NULL,
    remarks text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tools_usage_tool_life_pcs_check CHECK (((tool_life_pcs IS NULL) OR (tool_life_pcs > 0)))
);


--
-- Name: tools_usage_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tools_usage ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tools_usage_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tools_v_stock_by_designation; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.tools_v_stock_by_designation AS
 SELECT t.id AS tool_id,
    t.tool_code,
    t.tool_name,
    c.code AS category,
    count(i.id) AS sku_count,
    sum(i.qty_on_hand) AS qty_on_hand
   FROM ((public.tools_master t
     JOIN public.tools_category c ON ((c.id = t.category_id)))
     LEFT JOIN public.tools_item i ON (((i.tool_id = t.id) AND i.is_active)))
  GROUP BY t.id, t.tool_code, t.tool_name, c.code;


--
-- Name: tools_v_part_tooling; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.tools_v_part_tooling AS
 SELECT p.id AS part_id,
    p.part_no,
    COALESCE(pr.code, '?'::text) AS process,
    pr.name AS process_name,
    pr.family AS process_family,
    t.id AS tool_id,
    t.tool_code,
    t.tool_name,
    c.code AS category,
    u.tool_life_pcs,
    COALESCE(st.qty_on_hand, (0)::bigint) AS qty_on_hand
   FROM (((((public.tools_usage u
     JOIN public.tools_part p ON ((p.id = u.part_id)))
     JOIN public.tools_master t ON ((t.id = u.tool_id)))
     JOIN public.tools_category c ON ((c.id = t.category_id)))
     LEFT JOIN public.tools_process pr ON ((pr.id = u.process_id)))
     LEFT JOIN public.tools_v_stock_by_designation st ON ((st.tool_id = t.id)))
  WHERE u.is_active;


--
-- Name: tools_v_reorder; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.tools_v_reorder AS
 SELECT t.tool_code,
    t.tool_name,
    st.qty_on_hand,
    sum(d.qty_pcs) AS planned_pcs,
    sum(ceil(((d.qty_pcs)::numeric / (u.tool_life_pcs)::numeric))) AS tools_required,
    GREATEST((sum(ceil(((d.qty_pcs)::numeric / (u.tool_life_pcs)::numeric))) - (st.qty_on_hand)::numeric), (0)::numeric) AS qty_to_order
   FROM (((public.tools_usage u
     JOIN public.tools_master t ON ((t.id = u.tool_id)))
     JOIN public.tools_part_demand d ON ((d.part_id = u.part_id)))
     JOIN public.tools_v_stock_by_designation st ON ((st.tool_id = t.id)))
  WHERE (u.is_active AND (u.tool_life_pcs IS NOT NULL))
  GROUP BY t.tool_code, t.tool_name, st.qty_on_hand;


--
-- Name: tools_v_stock; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.tools_v_stock AS
 SELECT i.id AS tool_item_id,
    i.item_code,
    i.mfr_code,
    i.brand,
    i.location,
    i.qty_on_hand,
    i.reorder_point,
    ((i.reorder_point IS NOT NULL) AND (i.qty_on_hand <= i.reorder_point)) AS below_reorder,
    t.id AS tool_id,
    t.tool_code,
    t.tool_name,
    c.code AS category,
    ( SELECT max(x.txn_at) AS max
           FROM public.tools_txn x
          WHERE (x.tool_item_id = i.id)) AS last_movement
   FROM ((public.tools_item i
     JOIN public.tools_master t ON ((t.id = i.tool_id)))
     JOIN public.tools_category c ON ((c.id = t.category_id)))
  WHERE i.is_active;


--
-- Name: tools_v_where_used; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.tools_v_where_used AS
 SELECT t.id AS tool_id,
    t.tool_code,
    t.tool_name,
    p.part_no,
    COALESCE(pr.code, '?'::text) AS process,
    u.tool_life_pcs
   FROM (((public.tools_usage u
     JOIN public.tools_master t ON ((t.id = u.tool_id)))
     JOIN public.tools_part p ON ((p.id = u.part_id)))
     LEFT JOIN public.tools_process pr ON ((pr.id = u.process_id)))
  WHERE u.is_active;


--
-- Name: tools_category tools_category_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_category
    ADD CONSTRAINT tools_category_code_key UNIQUE (code);


--
-- Name: tools_category tools_category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_category
    ADD CONSTRAINT tools_category_pkey PRIMARY KEY (id);


--
-- Name: tools_item tools_item_item_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_item
    ADD CONSTRAINT tools_item_item_code_key UNIQUE (item_code);


--
-- Name: tools_item tools_item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_item
    ADD CONSTRAINT tools_item_pkey PRIMARY KEY (id);


--
-- Name: tools_master tools_master_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_master
    ADD CONSTRAINT tools_master_pkey PRIMARY KEY (id);


--
-- Name: tools_master tools_master_tool_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_master
    ADD CONSTRAINT tools_master_tool_code_key UNIQUE (tool_code);


--
-- Name: tools_part_demand tools_part_demand_part_id_period_start_period_end_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_part_demand
    ADD CONSTRAINT tools_part_demand_part_id_period_start_period_end_key UNIQUE (part_id, period_start, period_end);


--
-- Name: tools_part_demand tools_part_demand_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_part_demand
    ADD CONSTRAINT tools_part_demand_pkey PRIMARY KEY (id);


--
-- Name: tools_part tools_part_part_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_part
    ADD CONSTRAINT tools_part_part_no_key UNIQUE (part_no);


--
-- Name: tools_part tools_part_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_part
    ADD CONSTRAINT tools_part_pkey PRIMARY KEY (id);


--
-- Name: tools_process tools_process_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_process
    ADD CONSTRAINT tools_process_code_key UNIQUE (code);


--
-- Name: tools_process tools_process_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_process
    ADD CONSTRAINT tools_process_pkey PRIMARY KEY (id);


--
-- Name: tools_profile tools_profile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_profile
    ADD CONSTRAINT tools_profile_pkey PRIMARY KEY (id);


--
-- Name: tools_txn tools_txn_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_txn
    ADD CONSTRAINT tools_txn_pkey PRIMARY KEY (id);


--
-- Name: tools_usage tools_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_usage
    ADD CONSTRAINT tools_usage_pkey PRIMARY KEY (id);


--
-- Name: tools_usage tools_usage_tool_id_part_id_process_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_usage
    ADD CONSTRAINT tools_usage_tool_id_part_id_process_id_key UNIQUE (tool_id, part_id, process_id);


--
-- Name: tools_item_mfr_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_item_mfr_ix ON public.tools_item USING btree (upper(mfr_code));


--
-- Name: tools_item_pref_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tools_item_pref_uq ON public.tools_item USING btree (tool_id) WHERE is_preferred;


--
-- Name: tools_item_tool_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_item_tool_ix ON public.tools_item USING btree (tool_id);


--
-- Name: tools_master_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_master_name_trgm ON public.tools_master USING gin (tool_name public.gin_trgm_ops);


--
-- Name: tools_master_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tools_master_name_uq ON public.tools_master USING btree (category_id, upper(tool_name));


--
-- Name: tools_master_review_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_master_review_ix ON public.tools_master USING btree (needs_review) WHERE needs_review;


--
-- Name: tools_part_no_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_part_no_trgm ON public.tools_part USING gin (part_no public.gin_trgm_ops);


--
-- Name: tools_txn_date_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_txn_date_ix ON public.tools_txn USING btree (txn_at DESC);


--
-- Name: tools_txn_item_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_txn_item_at_idx ON public.tools_txn USING btree (tool_item_id, txn_at DESC);


--
-- Name: tools_txn_item_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_txn_item_ix ON public.tools_txn USING btree (tool_item_id, txn_at DESC);


--
-- Name: tools_txn_part_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_txn_part_ix ON public.tools_txn USING btree (part_id);


--
-- Name: tools_usage_part_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_usage_part_ix ON public.tools_usage USING btree (part_id);


--
-- Name: tools_usage_part_proc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_usage_part_proc_idx ON public.tools_usage USING btree (part_id, process_id);


--
-- Name: tools_usage_tool_ix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tools_usage_tool_ix ON public.tools_usage USING btree (tool_id);


--
-- Name: tools_master tools_master_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tools_master_touch BEFORE UPDATE ON public.tools_master FOR EACH ROW EXECUTE FUNCTION public.tools_touch_updated_at();


--
-- Name: tools_txn tools_txn_apply_t; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tools_txn_apply_t AFTER INSERT OR DELETE OR UPDATE ON public.tools_txn FOR EACH ROW EXECUTE FUNCTION public.tools_txn_apply();


--
-- Name: tools_txn tools_txn_sign; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER tools_txn_sign BEFORE INSERT OR UPDATE ON public.tools_txn FOR EACH ROW EXECUTE FUNCTION public.tools_txn_check_sign();


--
-- Name: tools_item tools_item_tool_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_item
    ADD CONSTRAINT tools_item_tool_id_fkey FOREIGN KEY (tool_id) REFERENCES public.tools_master(id) ON DELETE CASCADE;


--
-- Name: tools_master tools_master_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_master
    ADD CONSTRAINT tools_master_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.tools_category(id);


--
-- Name: tools_part_demand tools_part_demand_part_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_part_demand
    ADD CONSTRAINT tools_part_demand_part_id_fkey FOREIGN KEY (part_id) REFERENCES public.tools_part(id) ON DELETE CASCADE;


--
-- Name: tools_profile tools_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_profile
    ADD CONSTRAINT tools_profile_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: tools_txn tools_txn_part_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_txn
    ADD CONSTRAINT tools_txn_part_id_fkey FOREIGN KEY (part_id) REFERENCES public.tools_part(id);


--
-- Name: tools_txn tools_txn_performed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_txn
    ADD CONSTRAINT tools_txn_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.tools_profile(id);


--
-- Name: tools_txn tools_txn_process_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_txn
    ADD CONSTRAINT tools_txn_process_id_fkey FOREIGN KEY (process_id) REFERENCES public.tools_process(id);


--
-- Name: tools_txn tools_txn_tool_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_txn
    ADD CONSTRAINT tools_txn_tool_item_id_fkey FOREIGN KEY (tool_item_id) REFERENCES public.tools_item(id);


--
-- Name: tools_usage tools_usage_part_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_usage
    ADD CONSTRAINT tools_usage_part_id_fkey FOREIGN KEY (part_id) REFERENCES public.tools_part(id) ON DELETE CASCADE;


--
-- Name: tools_usage tools_usage_process_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_usage
    ADD CONSTRAINT tools_usage_process_id_fkey FOREIGN KEY (process_id) REFERENCES public.tools_process(id);


--
-- Name: tools_usage tools_usage_tool_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tools_usage
    ADD CONSTRAINT tools_usage_tool_id_fkey FOREIGN KEY (tool_id) REFERENCES public.tools_master(id) ON DELETE CASCADE;


--
-- Name: tools_category; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_category ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_category tools_category_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_category_admin ON public.tools_category TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_category tools_category_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_category_read ON public.tools_category FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_category tools_category_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_category_write ON public.tools_category TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: tools_item; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_item ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_item tools_item_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_item_admin ON public.tools_item TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_item tools_item_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_item_read ON public.tools_item FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_item tools_item_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_item_write ON public.tools_item TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: tools_master; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_master ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_master tools_master_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_master_admin ON public.tools_master TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_master tools_master_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_master_read ON public.tools_master FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_master tools_master_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_master_write ON public.tools_master TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: tools_part; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_part ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_part tools_part_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_part_admin ON public.tools_part TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_part_demand; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_part_demand ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_part_demand tools_part_demand_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_part_demand_admin ON public.tools_part_demand TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_part_demand tools_part_demand_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_part_demand_read ON public.tools_part_demand FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_part_demand tools_part_demand_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_part_demand_write ON public.tools_part_demand TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: tools_part tools_part_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_part_read ON public.tools_part FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_part tools_part_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_part_write ON public.tools_part TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: tools_process; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_process ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_process tools_process_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_process_admin ON public.tools_process TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_process tools_process_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_process_read ON public.tools_process FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_process tools_process_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_process_write ON public.tools_process TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: tools_profile; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_profile ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_profile tools_profile_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_profile_admin ON public.tools_profile TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_profile tools_profile_self; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_profile_self ON public.tools_profile FOR SELECT TO authenticated USING (((id = auth.uid()) OR public.tools_is_admin()));


--
-- Name: tools_txn; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_txn ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_txn tools_txn_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_txn_insert ON public.tools_txn FOR INSERT TO authenticated WITH CHECK (public.tools_can_move_stock());


--
-- Name: tools_txn tools_txn_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_txn_read ON public.tools_txn FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_txn tools_txn_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_txn_write ON public.tools_txn TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: tools_usage; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tools_usage ENABLE ROW LEVEL SECURITY;

--
-- Name: tools_usage tools_usage_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_usage_admin ON public.tools_usage TO authenticated USING (public.tools_is_admin()) WITH CHECK (public.tools_is_admin());


--
-- Name: tools_usage tools_usage_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_usage_read ON public.tools_usage FOR SELECT TO anon, authenticated USING (true);


--
-- Name: tools_usage tools_usage_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tools_usage_write ON public.tools_usage TO anon, authenticated USING (true) WITH CHECK (true);


--
-- Name: TABLE tools_category; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_category TO postgres;
GRANT ALL ON TABLE public.tools_category TO anon;
GRANT ALL ON TABLE public.tools_category TO authenticated;
GRANT ALL ON TABLE public.tools_category TO service_role;


--
-- Name: TABLE tools_item; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_item TO postgres;
GRANT ALL ON TABLE public.tools_item TO anon;
GRANT ALL ON TABLE public.tools_item TO authenticated;
GRANT ALL ON TABLE public.tools_item TO service_role;


--
-- Name: SEQUENCE tools_item_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tools_item_id_seq TO postgres;
GRANT ALL ON SEQUENCE public.tools_item_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tools_item_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tools_item_id_seq TO service_role;


--
-- Name: TABLE tools_master; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_master TO postgres;
GRANT ALL ON TABLE public.tools_master TO anon;
GRANT ALL ON TABLE public.tools_master TO authenticated;
GRANT ALL ON TABLE public.tools_master TO service_role;


--
-- Name: SEQUENCE tools_master_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tools_master_id_seq TO postgres;
GRANT ALL ON SEQUENCE public.tools_master_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tools_master_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tools_master_id_seq TO service_role;


--
-- Name: TABLE tools_part; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_part TO postgres;
GRANT ALL ON TABLE public.tools_part TO anon;
GRANT ALL ON TABLE public.tools_part TO authenticated;
GRANT ALL ON TABLE public.tools_part TO service_role;


--
-- Name: TABLE tools_part_demand; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_part_demand TO postgres;
GRANT ALL ON TABLE public.tools_part_demand TO anon;
GRANT ALL ON TABLE public.tools_part_demand TO authenticated;
GRANT ALL ON TABLE public.tools_part_demand TO service_role;


--
-- Name: SEQUENCE tools_part_demand_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tools_part_demand_id_seq TO postgres;
GRANT ALL ON SEQUENCE public.tools_part_demand_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tools_part_demand_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tools_part_demand_id_seq TO service_role;


--
-- Name: SEQUENCE tools_part_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tools_part_id_seq TO postgres;
GRANT ALL ON SEQUENCE public.tools_part_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tools_part_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tools_part_id_seq TO service_role;


--
-- Name: TABLE tools_process; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_process TO postgres;
GRANT ALL ON TABLE public.tools_process TO anon;
GRANT ALL ON TABLE public.tools_process TO authenticated;
GRANT ALL ON TABLE public.tools_process TO service_role;


--
-- Name: TABLE tools_profile; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_profile TO postgres;
GRANT ALL ON TABLE public.tools_profile TO anon;
GRANT ALL ON TABLE public.tools_profile TO authenticated;
GRANT ALL ON TABLE public.tools_profile TO service_role;


--
-- Name: TABLE tools_txn; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_txn TO postgres;
GRANT ALL ON TABLE public.tools_txn TO anon;
GRANT ALL ON TABLE public.tools_txn TO authenticated;
GRANT ALL ON TABLE public.tools_txn TO service_role;


--
-- Name: SEQUENCE tools_txn_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tools_txn_id_seq TO postgres;
GRANT ALL ON SEQUENCE public.tools_txn_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tools_txn_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tools_txn_id_seq TO service_role;


--
-- Name: TABLE tools_usage; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_usage TO postgres;
GRANT ALL ON TABLE public.tools_usage TO anon;
GRANT ALL ON TABLE public.tools_usage TO authenticated;
GRANT ALL ON TABLE public.tools_usage TO service_role;


--
-- Name: SEQUENCE tools_usage_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tools_usage_id_seq TO postgres;
GRANT ALL ON SEQUENCE public.tools_usage_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tools_usage_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tools_usage_id_seq TO service_role;


--
-- Name: TABLE tools_v_stock_by_designation; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_v_stock_by_designation TO postgres;
GRANT ALL ON TABLE public.tools_v_stock_by_designation TO anon;
GRANT ALL ON TABLE public.tools_v_stock_by_designation TO authenticated;
GRANT ALL ON TABLE public.tools_v_stock_by_designation TO service_role;


--
-- Name: TABLE tools_v_part_tooling; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_v_part_tooling TO postgres;
GRANT ALL ON TABLE public.tools_v_part_tooling TO anon;
GRANT ALL ON TABLE public.tools_v_part_tooling TO authenticated;
GRANT ALL ON TABLE public.tools_v_part_tooling TO service_role;


--
-- Name: TABLE tools_v_reorder; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_v_reorder TO postgres;
GRANT ALL ON TABLE public.tools_v_reorder TO anon;
GRANT ALL ON TABLE public.tools_v_reorder TO authenticated;
GRANT ALL ON TABLE public.tools_v_reorder TO service_role;


--
-- Name: TABLE tools_v_stock; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_v_stock TO postgres;
GRANT ALL ON TABLE public.tools_v_stock TO anon;
GRANT ALL ON TABLE public.tools_v_stock TO authenticated;
GRANT ALL ON TABLE public.tools_v_stock TO service_role;


--
-- Name: TABLE tools_v_where_used; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tools_v_where_used TO postgres;
GRANT ALL ON TABLE public.tools_v_where_used TO anon;
GRANT ALL ON TABLE public.tools_v_where_used TO authenticated;
GRANT ALL ON TABLE public.tools_v_where_used TO service_role;


--
-- PostgreSQL database dump complete
--

