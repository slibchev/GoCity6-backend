CREATE TABLE passengers (
    id TEXT PRIMARY KEY,

    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,

    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'disabled')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE UNIQUE INDEX passengers_username_lower_idx
    ON passengers (LOWER(username));

ALTER TABLE rides
    ADD COLUMN passenger_id TEXT
        REFERENCES passengers(id)
        ON DELETE RESTRICT;

CREATE INDEX rides_passenger_requested_at_idx
    ON rides (passenger_id, requested_at DESC)
    WHERE passenger_id IS NOT NULL;
