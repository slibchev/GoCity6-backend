ALTER TABLE rides
    ADD COLUMN client_request_id TEXT;

CREATE UNIQUE INDEX rides_client_request_id_unique_idx
    ON rides (client_request_id)
    WHERE client_request_id IS NOT NULL;