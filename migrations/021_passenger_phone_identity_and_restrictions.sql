ALTER TABLE passengers
    ADD COLUMN phone_e164 TEXT,
    ADD COLUMN phone_verified_at TIMESTAMPTZ,
    ADD CONSTRAINT passengers_phone_e164_format_check
        CHECK (
            phone_e164 IS NULL
            OR phone_e164 ~ '^\+[1-9][0-9]{1,14}$'
        ),
    ADD CONSTRAINT passengers_phone_verification_requires_number_check
        CHECK (phone_verified_at IS NULL OR phone_e164 IS NOT NULL);

CREATE UNIQUE INDEX passengers_phone_e164_unique_idx
    ON passengers (phone_e164)
    WHERE phone_e164 IS NOT NULL;

CREATE TABLE passenger_phone_restrictions (
    restriction_id UUID PRIMARY KEY,
    phone_e164 TEXT NOT NULL
        CHECK (phone_e164 ~ '^\+[1-9][0-9]{1,14}$'),
    imposed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    expires_at TIMESTAMPTZ,
    reason TEXT NOT NULL CHECK (length(btrim(reason)) > 0),
    admin_actor TEXT NOT NULL CHECK (length(btrim(admin_actor)) > 0),
    lifted_at TIMESTAMPTZ,
    lifted_by TEXT,
    lift_reason TEXT,
    CONSTRAINT passenger_phone_restrictions_expiry_check
        CHECK (expires_at IS NULL OR expires_at > imposed_at),
    CONSTRAINT passenger_phone_restrictions_lift_audit_check
        CHECK (
            (lifted_at IS NULL AND lifted_by IS NULL AND lift_reason IS NULL)
            OR
            (lifted_at IS NOT NULL
                AND lifted_by IS NOT NULL
                AND lift_reason IS NOT NULL
                AND length(btrim(lifted_by)) > 0
                AND length(btrim(lift_reason)) > 0)
        )
);

CREATE INDEX passenger_phone_restrictions_phone_time_idx
    ON passenger_phone_restrictions (phone_e164, imposed_at DESC);

CREATE TABLE passenger_phone_restriction_audit (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restriction_id UUID REFERENCES passenger_phone_restrictions(restriction_id)
        ON DELETE RESTRICT,
    phone_e164 TEXT NOT NULL
        CHECK (phone_e164 ~ '^\+[1-9][0-9]{1,14}$'),
    action TEXT NOT NULL
        CHECK (action IN ('imposed', 'lifted', 'lift_no_active')),
    admin_actor TEXT NOT NULL CHECK (length(btrim(admin_actor)) > 0),
    reason TEXT NOT NULL CHECK (length(btrim(reason)) > 0),
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT passenger_phone_restriction_audit_link_check
        CHECK (
            (action = 'lift_no_active' AND restriction_id IS NULL)
            OR
            (action IN ('imposed', 'lifted') AND restriction_id IS NOT NULL)
        )
);

CREATE INDEX passenger_phone_restriction_audit_phone_time_idx
    ON passenger_phone_restriction_audit (phone_e164, occurred_at DESC);

CREATE TABLE passenger_phone_identity_audit (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    passenger_id TEXT NOT NULL REFERENCES passengers(id) ON DELETE RESTRICT,
    phone_e164 TEXT NOT NULL
        CHECK (phone_e164 ~ '^\+[1-9][0-9]{1,14}$'),
    action TEXT NOT NULL CHECK (action IN ('assigned', 'changed', 'unlinked')),
    admin_actor TEXT NOT NULL CHECK (length(btrim(admin_actor)) > 0),
    reason TEXT NOT NULL CHECK (length(btrim(reason)) > 0),
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX passenger_phone_identity_audit_passenger_time_idx
    ON passenger_phone_identity_audit (passenger_id, occurred_at DESC);

CREATE INDEX passenger_phone_identity_audit_phone_time_idx
    ON passenger_phone_identity_audit (phone_e164, occurred_at DESC);
