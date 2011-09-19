CREATE OR REPLACE FUNCTION reconciliation__submit_set(
	in_report_id int, in_line_ids int[]) RETURNS bool AS
$$
BEGIN
	UPDATE cr_report set submitted = true where id = in_report_id;
	PERFORM reconciliation__save_set(in_report_id, in_line_ids);

	RETURN FOUND;
END;
$$ LANGUAGE PLPGSQL;

COMMENT ON FUNCTION reconciliation__submit_set(
        in_report_id int, in_line_ids int[]) IS
$$Submits a reconciliation report for approval. 
in_line_ids is used to specify which report lines are cleared, finalizing the
report.$$;

CREATE OR REPLACE FUNCTION reconciliation__save_set(
	in_report_id int, in_line_ids int[]) RETURNS bool AS
$$
BEGIN
	UPDATE cr_report_line SET cleared = false
	WHERE report_id = in_report_id;

	UPDATE cr_report_line SET cleared = true
	WHERE report_id = in_report_id AND id = ANY(in_line_ids);
	RETURN found;
END;
$$ LANGUAGE PLPGSQL;

COMMENT ON FUNCTION reconciliation__save_set(
        in_report_id int, in_line_ids int[]) IS
$$Sets which lines of the report are cleared.$$;

CREATE OR REPLACE FUNCTION reconciliation__delete_report(in_report_id int)
RETURNS bool AS 
$$
    DECLARE
    BEGIN
        PERFORM id FROM cr_report WHERE id = in_report_id AND approved = TRUE;
        
        IF FOUND THEN --changing the verbose message to a notice and adding a
                      --program-helpful exception --CT
            RAISE NOTICE 'reconcilation__delete_report(): report % is approved; cannot delete.', in_report_id;
            RAISE EXCEPTION 'Cannot delete approved';
        END IF;

        DELETE FROM cr_report_line WHERE report_id = in_report_id;
        DELETE FROM cr_report WHERE id = in_report_id;
         
        return FOUND;
    END;
$$ language plpgsql;

COMMENT ON FUNCTION reconciliation__delete_report(in_report_id int) IS
$$Deletes the report if the report exists and is unapproved.$$;

CREATE OR REPLACE FUNCTION reconciliation__get_cleared_balance(in_chart_id int)
RETURNS numeric AS
$$
	select CASE WHEN c.category in('A', 'E') THEN sum(ac.amount) * -1 ELSE
		sum(ac.amount) END
	FROM account c
	JOIN acc_trans ac ON (ac.chart_id = c.id)
	JOIN (select id from ar where approved
		union
		select id from ap where approved
		union
		select id from gl where approved) g on (g.id = ac.trans_id)
	WHERE c.id = $1 AND ac.cleared is true and ac.approved is true
		GROUP BY c.id, c.category;
$$ LANGUAGE sql;

COMMENT ON FUNCTION reconciliation__get_cleared_balance(in_chart_id int) IS
$$ Gets the cleared balance of the account specified by chart_id.
This is specified in normal format (i.e. positive numbers for debits for asset
and espense accounts, and positive numbers for credits in other accounts 

Note that currently contra accounts will show negative balances.$$;

CREATE OR REPLACE FUNCTION reconciliation__report_approve (in_report_id INT) returns INT as $$
    
    -- Does some basic checks before allowing the approval to go through; 
    -- moves the approval to "cr_report_line", I guess, or some other "final" table.
    --
    -- Pending may just be a single flag in the database to mark that it is
    -- not finalized. Will need to discuss with Chris.
    
    DECLARE
        current_row RECORD;
        completed cr_report_line;
        total_errors INT;
        in_user TEXT;
	ac_entries int[];
    BEGIN
        in_user := current_user;
        
        -- so far, so good. Different user, and no errors remain. Therefore, 
        -- we can move it to completed reports.
        --
        -- User may not be necessary - I would think it better to use the 
        -- in_user, to note who approved the report, than the user who
        -- filed it. This may require clunkier syntax..
        
        -- 
	ac_entries := '{}';
        update cr_report set approved = 't',
		approved_by = person__get_my_entity_id(),
		approved_username = SESSION_USER
	where id = in_report_id;

	FOR current_row IN 
		SELECT compound_array(entries) AS entries FROM (
			select as_array(ac.entry_id) as entries
		FROM acc_trans ac
		JOIN transactions t on (ac.trans_id = t.id)
		JOIN (select id, entity_credit_account::text as ref, 'ar' as table FROM ar
			UNION
		      select id, entity_credit_account::text, 'ap' as table FROM ap
			UNION
		      select id, reference, 'gl' as table FROM gl) gl
			ON (gl.table = t.table_name AND gl.id = t.id)
		LEFT JOIN cr_report_line rl ON (rl.report_id = in_report_id
			AND ((rl.ledger_id = ac.entry_id 
				AND ac.voucher_id IS NULL) 
				OR (rl.voucher_id = ac.voucher_id)) and rl.cleared is true)
		WHERE ac.cleared IS FALSE
			AND ac.chart_id = (select chart_id from cr_report where id = in_report_id)
		GROUP BY gl.ref, ac.source, ac.transdate,
			ac.memo, ac.voucher_id, gl.table
		HAVING count(rl.report_id) > 0) a
	LOOP
		ac_entries := ac_entries || current_row.entries;
	END LOOP;

	UPDATE acc_trans SET cleared = TRUE 
	where entry_id = any(ac_entries);
        
        return 1;        
    END;

$$ language 'plpgsql' security definer;

COMMENT ON  FUNCTION reconciliation__report_approve (in_report_id INT) IS
$$Marks the report approved and marks all cleared transactions in it cleared.$$;


-- XXX Badly named, rename for 1.4.  --CT
CREATE OR REPLACE FUNCTION reconciliation__new_report_id 
(in_chart_id int, in_total numeric, in_end_date date) returns INT as $$

    INSERT INTO cr_report(chart_id, their_total, end_date) values ($1, $2, $3);
    SELECT currval('cr_report_id_seq')::int;

$$ language 'sql';

COMMENT ON FUNCTION reconciliation__new_report_id 
(in_chart_id int, in_total numeric, in_end_date date)  IS
$$ Inserts creates a new report and returns the id.$$;

create or replace function reconciliation__add_entry(
    in_report_id INT, 
    in_scn TEXT, 
    in_type TEXT, 
    in_date TIMESTAMP,
    in_amount numeric
) RETURNS INT AS $$
    
    DECLARE
	in_account int;
        la RECORD;
        t_errorcode INT;
        our_value NUMERIC;
        lid INT;
	in_count int;
	t_scn TEXT;
	t_uid int;
	t_prefix text;
    BEGIN

	SELECT value into t_prefix FROM defaults WHERE setting_key = 'check_prefix';

	t_uid := person__get_my_entity_id();
	IF in_scn = '' THEN 
		t_scn := NULL;
	ELSE 
		t_scn := t_prefix || in_scn;
	END IF;
	IF t_scn IS NOT NULL THEN
		SELECT count(*) INTO in_count FROM cr_report_line
		WHERE scn ilike t_scn AND report_id = in_report_id 
			AND their_balance = 0;

		IF in_count = 0 THEN
			INSERT INTO cr_report_line
			(report_id, scn, their_balance, our_balance, clear_time,
				"user", trans_type)
			VALUES 
			(in_report_id, t_scn, in_amount, 0, in_date, t_uid,
				in_type);
		ELSIF in_count = 1 THEN
			UPDATE cr_report_line
			SET their_balance = in_amount, clear_time = in_date,
				cleared = true
			WHERE t_scn = scn AND report_id = in_report_id
				AND their_balance = 0;
		ELSE 
			SELECT count(*) INTO in_count FROM cr_report_line
			WHERE t_scn ilike scn AND report_id = in_report_id
				AND our_value = in_amount and their_balance = 0;

			IF in_count = 0 THEN -- no match among many of values
				SELECT id INTO lid FROM cr_report_line
                        	WHERE t_scn ilike scn AND report_id = in_report_id
				ORDER BY our_balance ASC limit 1;

				UPDATE cr_report_line
                                SET their_balance = in_amount, 
					clear_time = in_date,
					trans_type = in_type,
					cleared = true
                                WHERE id = lid;

			ELSIF in_count = 1 THEN -- EXECT MATCH
				UPDATE cr_report_line
				SET their_balance = in_amount, 
					trans_type = in_type,
					clear_time = in_date,
					cleared = true
				WHERE t_scn = scn AND report_id = in_report_id
                                	AND our_value = in_amount 
					AND their_balance = 0;
			ELSE -- More than one match
				SELECT id INTO lid FROM cr_report_line
                        	WHERE t_scn ilike scn AND report_id = in_report_id
                                	AND our_value = in_amount
				ORDER BY id ASC limit 1;

				UPDATE cr_report_line
                                SET their_balance = in_amount,
					trans_type = in_type,
					cleared = true,
					clear_time = in_date
                                WHERE id = lid;
				
			END IF;
		END IF;
	ELSE -- scn IS NULL, check on amount instead
		SELECT count(*) INTO in_count FROM cr_report_line
		WHERE report_id = in_report_id AND our_balance = in_amount
			AND their_balance = 0 and post_date = in_date
			and scn NOT LIKE t_prefix || '%';

		IF in_count = 0 THEN -- no match
			INSERT INTO cr_report_line
			(report_id, scn, their_balance, our_balance, clear_time,
			"user", trans_type)
			VALUES 
			(in_report_id, t_scn, in_amount, 0, in_date, t_uid,
			in_type);
		ELSIF in_count = 1 THEN -- perfect match
			UPDATE cr_report_line SET their_balance = in_amount,
					trans_type = in_type,
					clear_time = in_date,
					cleared = true
			WHERE report_id = in_report_id AND our_balance = in_amount
                        	AND their_balance = 0 and
				in_scn NOT LIKE t_prefix || '%';
		ELSE -- more than one match
			SELECT min(id) INTO lid FROM cr_report_line
			WHERE report_id = in_report_id AND our_balance = in_amount
                        	AND their_balance = 0 and post_date = in_date
				AND scn NOT LIKE t_prefix || '%'
			LIMIT 1;

			UPDATE cr_report_line SET their_balance = in_amount,
					trans_type = in_type,
					clear_time = in_date,
					cleared = true
			WHERE id = lid;
			
		END IF;
	END IF;
        return 1; 
        
    END;    
$$ language 'plpgsql';

comment on function reconciliation__add_entry(
    in_report_id INT,
    in_scn TEXT,
    in_type TEXT,
    in_date TIMESTAMP,
    in_amount numeric
)  IS
$$ 
This function is used for automatically matching entries from an external source
like a bank-produced csv file.

This function is very sensitive to ordering of inputs.  NULL or empty in_scn values MUST be submitted after meaningful scns.  It is also highly recommended 
that within each category, one submits in order of amount.  We should therefore
wrap it in another function which can operate on a set, perhaps in 1.4....$$;

create or replace function reconciliation__pending_transactions 
(in_end_date DATE, in_chart_id int, in_report_id int, in_their_total numeric) 
RETURNS int as $$
    
    DECLARE
        gl_row RECORD;
    BEGIN
		INSERT INTO cr_report_line (report_id, scn, their_balance, 
			our_balance, "user", voucher_id, ledger_id, post_date)
		SELECT in_report_id, 
		       COALESCE(ac.source, gl.ref),
		       0, 
		       sum(amount) AS amount,
				(select entity_id from users 
				where username = CURRENT_USER),
			ac.voucher_id, min(ac.entry_id), ac.transdate
		FROM acc_trans ac
		JOIN transactions t on (ac.trans_id = t.id)
		JOIN (select id, entity_credit_account::text as ref, 'ar' as table FROM ar where approved
			UNION
		      select id, entity_credit_account::text, 'ap' as table FROM ap WHERE approved
			UNION
		      select id, reference, 'gl' as table FROM gl WHERE approved) gl 
			ON (gl.table = t.table_name AND gl.id = t.id)
		LEFT JOIN cr_report_line rl ON (rl.report_id = in_report_id
			AND ((rl.ledger_id = ac.entry_id 
				AND ac.voucher_id IS NULL) 
				OR (rl.voucher_id = ac.voucher_id)))
		WHERE ac.cleared IS FALSE
			AND ac.approved IS TRUE
			AND ac.chart_id = in_chart_id
			AND ac.transdate <= in_end_date
		GROUP BY gl.ref, ac.source, ac.transdate,
			ac.memo, ac.voucher_id, gl.table
		HAVING count(rl.id) = 0;

		UPDATE cr_report set updated = now(),
			their_total = coalesce(in_their_total, their_total)
		where id = in_report_id;
    RETURN in_report_id;
    END;
$$ LANGUAGE plpgsql;

COMMENT ON function reconciliation__pending_transactions
(in_end_date DATE, in_chart_id int, in_report_id int, in_their_total numeric) IS
$$Ensures that the list of pending transactions in the report is up to date. $$;

CREATE OR REPLACE FUNCTION reconciliation__report_details (in_report_id INT) RETURNS setof cr_report_line as $$

    DECLARE
        row cr_report_line;
    BEGIN    
        FOR row IN 
		select * from cr_report_line where report_id = in_report_id 
		order by scn, post_date
	LOOP
        
            RETURN NEXT row;
        
        END LOOP;    
    END;

$$ language 'plpgsql';

COMMENT ON FUNCTION reconciliation__report_details (in_report_id INT) IS
$$ Returns the details of the report. $$;

CREATE OR REPLACE FUNCTION reconciliation__report_summary (in_report_id INT) RETURNS cr_report as $$

    DECLARE
        row cr_report;
    BEGIN    
        select * into row from cr_report where id = in_report_id;
        
        RETURN row;
        
    END;

$$ language 'plpgsql';

-- why is this not called reconciliation__get_report or something? --CT
CREATE OR REPLACE FUNCTION reconciliation__get_total (in_report_id INT) returns setof cr_report AS $$

    DECLARE
        row cr_report;
    BEGIN
    
        SELECT * INTO row FROM cr_report 
        where id = in_report_id 
        AND scn = -1;
        
        IF NOT FOUND THEN -- I think this is a fairly major error condition
            RAISE EXCEPTION 'Bad report id.';
        ELSE
            return next row;
        END IF;
    END;

$$ language 'plpgsql';

COMMENT ON FUNCTION reconciliation__get_total (in_report_id INT) IS
$$ Retrieves all header info from the reconciliation report.$$;

CREATE OR REPLACE FUNCTION reconciliation__search
(in_date_from date, in_date_to date, 
	in_balance_from numeric, in_balance_to numeric, 
	in_chart_id int, in_submitted bool, in_approved bool) 
returns setof cr_report AS
$$
DECLARE report cr_report;
BEGIN
	FOR report IN
		SELECT r.* FROM cr_report r
		JOIN account c ON (r.chart_id = c.id)
		WHERE 
			(in_date_from IS NULL OR in_date_from <= end_date) and
			(in_date_to IS NULL OR in_date_to >= end_date) AND
			(in_balance_from IS NULL 
				or in_balance_from <= their_total ) AND
			(in_balance_to IS NULL 
				OR in_balance_to >= their_total) AND
			(in_chart_id IS NULL OR in_chart_id = chart_id) AND
			(in_submitted IS NULL or in_submitted = submitted) AND
			(in_approved IS NULL OR in_approved = approved) AND
			(r.deleted IS FALSE)
		ORDER BY c.accno, end_date, their_total
	LOOP
		RETURN NEXT report;
	END LOOP; 
END;
$$ language plpgsql;

COMMENT ON FUNCTION reconciliation__search
(in_date_from date, in_date_to date,
        in_balance_from numeric, in_balance_to numeric,
        in_chart_id int, in_submitted bool, in_approved bool) IS
$$ Searches for reconciliation reports.
NULLs match all values.
in_date_to and in_date_from give a range of reports.  All other inputs are
exact matches.
$$;

create type recon_accounts as (
    name text,
    accno text,
    id int
);

create or replace function reconciliation__account_list () returns setof recon_accounts as $$
    SELECT
        coa.accno || ' ' || coa.description as name,
        coa.accno, coa.id as id
    FROM account coa
         JOIN cr_coa_to_account cta ON cta.chart_id = coa.id
    ORDER BY coa.accno;
$$ language sql;

COMMENT ON function reconciliation__account_list () IS
$$ returns set of accounts set up for reconciliation.  Currently we pull the 
account number and description from the account table.$$;

CREATE OR REPLACE FUNCTION reconciliation__get_current_balance
(in_account_id int, in_date date) returns numeric as
$$
DECLARE outval NUMERIC;
BEGIN
	SELECT CASE WHEN (select category FROM account WHERE id = in_account_id)
			IN ('A', 'E') THEN sum(a.amount) * -1
		ELSE sum(a.amount) END
	FROM acc_trans a
	JOIN (
		SELECT id FROM ar
		WHERE approved is true
		UNION
		SELECT id FROM ap
		WHERE approved is true
		UNION
		SELECT id FROM gl
		WHERE approved is true
	) gl ON a.trans_id = gl.id
	WHERE a.approved IS TRUE 
		AND a.chart_id = in_account_id
		AND a.transdate <= in_date;

	RETURN outval;
END;
$$ language plpgsql;

COMMENT ON FUNCTION reconciliation__get_current_balance
(in_account_id int, in_date date) IS
$$ Gets the current balance of all approved transactions against a specific 
account.  For asset and expense accounts this is the debit balance, for others
this is the credit balance.$$;

CREATE OR REPLACE VIEW recon_payee AS
 SELECT n.name AS payee, rr.id, rr.report_id, rr.scn, rr.their_balance, rr.our_balance, rr.errorcode, rr."user", rr.clear_time, rr.insert_time, rr.trans_type, rr.post_date, rr.ledger_id, rr.voucher_id, rr.overlook, rr.cleared
   FROM cr_report_line rr
   LEFT JOIN acc_trans ac ON rr.ledger_id = ac.entry_id
   LEFT JOIN gl ON ac.trans_id = gl.id
   LEFT JOIN (( SELECT ap.id, e.name
   FROM ap
   JOIN entity_credit_account eca ON ap.entity_credit_account = eca.id
   JOIN entity e ON eca.entity_id = e.id
UNION 
 SELECT ar.id, e.name
   FROM ar
   JOIN entity_credit_account eca ON ar.entity_credit_account = eca.id
   JOIN entity e ON eca.entity_id = e.id)
UNION 
 SELECT gl.id, gl.description
   FROM gl) n ON n.id = ac.trans_id;


CREATE OR REPLACE FUNCTION reconciliation__report_details_payee (in_report_id INT) RETURNS setof recon_payee as $$
   DECLARE
        row recon_payee;
    BEGIN    
        FOR row IN 
        	select * from recon_payee where report_id = in_report_id 
        	order by scn, post_date
        LOOP
          RETURN NEXT row;
        END LOOP;    
    END;
$$ language 'plpgsql';

COMMENT ON FUNCTION reconciliation__report_details_payee (in_report_id INT) IS
$$ Pulls the payee information for the reconciliation report.$$;
