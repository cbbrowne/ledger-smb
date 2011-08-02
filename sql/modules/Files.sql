CREATE OR REPLACE FUNCTION file__get_mime_type
 (in_mime_type_id int, in_mime_type_text text)
RETURNS mime_type AS
$$
select * from mime_type 
 where ($1 IS NULL OR id = $1) AND ($2 IS NULL OR mime_type = $2);
$$ language sql;

COMMENT ON FUNCTION file__get_mime_type(in_mime_type_id int, in_mime_type text) IS
$$Retrieves mime type information associated with a file object.$$;

CREATE OR REPLACE FUNCTION file__attach_to_tx
(in_content bytea, in_mime_type_id int, in_file_name text,
in_description text, in_id int, in_ref_key int, in_file_class int)
RETURNS file_base
AS
$$
DECLARE retval file_base;
BEGIN
   IF in_id IS NOT NULL THEN
       IF in_content THEN
          RAISE EXCEPTION $e$Can't specify id and content in attachment$e$;--'
       END IF;
       INSERT INTO file_order_to_tx        
              (file_id, source_class, ref_key, dest_class, attached_by,
              attached_at)
       VALUES (in_id, 2, in_ref_key, 1, person__get_my_entity_id(), now());

       SELECT * INTO retval FROM file_base where id = in_id;
       RETURN retval;
   ELSE
       INSERT INTO file_transaction 
                   (content, mime_type_id, file_name, description, ref_key,
                   file_class, uploaded_by, uploaded_at)
            VALUES (in_content, in_mime_type_id, in_file_name, in_description,
                   in_ref_key, in_file_class, person__get_my_entity_id(), 
                   now());
        SELECT * INTO retval FROM file_base 
         where id = currval('file_base_id_seq');

        RETURN retval;
    END IF;
END;
$$ LANGUAGE PLPGSQL;

COMMENT ON FUNCTION file__attach_to_tx
(in_content bytea, in_mime_type_id int, in_file_name text,
in_description text, in_id int, in_ref_key int, in_file_class int) IS
$$ Attaches or links a file to a transaction.  in_content OR id can be set.
Setting both raises an exception.$$;


CREATE OR REPLACE FUNCTION file__attach_to_order
(in_content bytea, in_mime_type_id int, in_file_name text,
in_description text, in_id int, in_ref_key int, in_file_class int)
RETURNS file_base
AS
$$
DECLARE retval file_base;
BEGIN
   IF in_id IS NOT NULL THEN
       IF in_content THEN
          RAISE EXCEPTION $e$Conflicting options file_id and content$e$;
       END IF;
       IF in_file_class = 1 THEN
           INSERT INTO file_tx_to_order        
                  (file_id, source_class, ref_key, dest_class, attached_by,
                  attached_at)
           VALUES (in_id, 1, in_ref_key, 2, person__get_my_entity_id(), now());
       ELSIF in_file_class = 2 THEN
           INSERT INTO file_order_to_order
                  (file_id, source_class, ref_key, dest_class, attached_by,
                  attached_at)
           VALUES (in_id, 2, in_ref_key, 2, person__get_my_entity_id(), now());
       ELSE 
           RAISE EXCEPTION $E$Invalid file class$E$;
       END IF;
       SELECT * INTO retval FROM file_base where id = in_id;
       RETURN retval;
   ELSE
       INSERT INTO file_transaction 
                   (content, mime_type_id, file_name, description, ref_key,
                   file_class, uploaded_by, uploaded_at)
            VALUES (in_content, in_mime_type_id, in_file_name, in_description,
                   in_ref_key, in_file_class, person__get_my_entity_id(), 
                   now());
        SELECT * INTO retval FROM file_base 
         where id = currval('file_base_id_seq');

        RETURN retval;
    END IF;
END;
$$ LANGUAGE PLPGSQL;

COMMENT ON FUNCTION file__attach_to_order
(in_content bytea, in_mime_type_id int, in_file_name text,
in_description text, in_id int, in_ref_key int, in_file_class int) IS
$$ Attaches or links a file to an order.  in_content OR id can be set.
Setting both raises an exception.$$;


CREATE TYPE file_list_item AS (
       mime_type text,
       file_name text,
       description text,
       uploaded_by_id int,
       uploaded_by_name text,
       uploaded_at timestamp,
       id int,
       ref_key int,
       file_class int
);

CREATE OR REPLACE FUNCTION file__list_by(in_ref_key int, in_file_class int)
RETURNS SETOF file_list_item AS
$$

SELECT m.mime_type, f.file_name, f.description, f.uploaded_by, e.name, 
       f.uploaded_at, f.id, f.ref_key, f.file_class
  FROM mime_type m
  JOIN file_base f ON f.mime_type_id = m.id
  JOIN entity e ON f.uploaded_by = e.id
 WHERE f.ref_key = $1 and f.file_class = $2;

$$ language sql;

COMMENT ON FUNCTION file__list_by(in_ref_key int, in_file_class int) IS
$$ Returns a list of files attached to a database object.  No content is 
retrieved.$$;

CREATE OR REPLACE FUNCTION file__get(in_id int, in_file_class int)
RETURNS file_base AS
$$
SELECT * FROM file_base where id = $1 and file_class = $2;
$$ language sql;

COMMENT ON FUNCTION file__get(in_id int, in_file_class int) IS
$$ Retrieves the file information specified including content.$$;

DROP VIEW IF EXISTS file_links;
DROP VIEW IF EXISTS file_tx_links;
DROP VIEW IF EXISTS file_order_links;
DELETE FROM file_view_catalog WHERE file_class in (1, 2);

CREATE OR REPLACE view file_tx_links AS
SELECT file_id, ref_key, gl.reference, gl.type, dest_class, source_class,
       sl.ref_key as dest_ref
  FROM file_secondary_attachment sl
  JOIN (select id, reference, 'gl' as type
          FROM gl
         UNION
        SELECT id, invnumber, case when invoice then 'is' else 'ar' end as type
          FROM ar
         UNION
        SELECT id, invnumber, case when invoice then 'ir' else 'ap' end as type
          FROM ap) gl ON sl.ref_key = gl.id and sl.source_class = 1;
-- view of links FROM transactions

INSERT INTO file_view_catalog (file_class, view_name) 
     VALUES (1, 'file_tx_links');

CREATE OR REPLACE view file_order_links AS
SELECT file_id, ref_key, oe.ordnumber as reference, oc.oe_class, dest_class, 
       source_class, sl.ref_key as dest_ref
  FROM file_secondary_attachment sl   
  JOIN oe ON sl.ref_key = oe.id
  JOIN oe_class oc ON oe.oe_class_id = oc.id
 WHERE sl.source_class = 2;
       

-- view of links FROM orders

INSERT INTO file_view_catalog (file_class, view_name) 
     VALUES (2, 'file_order_links');


CREATE OR REPLACE FUNCTION file_links_vrebuild()
RETURNS bool AS
$$
DECLARE 
   viewline file_view_catalog%rowtype;
   stmt text;
BEGIN
   stmt := '';
   FOR viewline IN
       select * from file_view_catalog
   LOOP
       IF stmt = '' THEN
           stmt := 'SELECT * FROM ' || quote_ident(viewline.view_name) || '
';
       ELSE
           stmt := stmt || ' UNION
SELECT * FROM '|| quote_ident(viewline.view_name) || '
';
       END IF; 
   END LOOP;
   EXECUTE 'CREATE OR REPLACE VIEW file_links AS
' || stmt;
   RETURN TRUE;
END;
$$ LANGUAGE PLPGSQL;

select * from file_links_vrebuild();


CREATE OR REPLACE FUNCTION file__list_links(in_ref_key int, in_file_class int)
RETURNS setof file_links AS
$$ select * from file_links where ref_key = $1 and dest_class = $2;
$$ language sql;

COMMENT ON FUNCTION file__list_links(in_ref_key int, in_file_class int) IS
$$ This function retrieves a list of file attachments on a specified object.$$;
