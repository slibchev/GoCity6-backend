-- Durable journal for driver accept/reject actions and redispatch work.
-- A row is inserted in the same transaction as the offer transition and
-- policy update, so a committed row is an authoritative settled action.
CREATE TABLE driver_offer_action_outbox (
    action_id TEXT PRIMARY KEY,

    offer_id TEXT NOT NULL UNIQUE
        REFERENCES ride_offers(id),

    driver_id TEXT NOT NULL
        REFERENCES drivers(id),

    action TEXT NOT NULL
        CHECK (action IN ('accept', 'reject')),

    -- NULL preserves compatibility with older clients. PostgreSQL permits
    -- multiple NULL values in this UNIQUE constraint, while offer_id above
    -- still permits only one journal/action row for a given offer.
    idempotency_key TEXT,

    -- Lowercase SHA-256 hex digest of the canonical action request.
    request_hash TEXT NOT NULL
        CHECK (request_hash ~ '^[0-9a-f]{64}$'),

    -- Accept actions have no rejection policy decision. Every reject records
    -- the policy decision, including a decision not to apply a penalty.
    policy_outcome TEXT,

    redispatch_status TEXT NOT NULL
        CHECK (
            redispatch_status IN (
                'queued',
                'leased',
                'retryable',
                'completed',
                'needs_review',
                'not_required'
            )
        ),

    attempt_count INTEGER NOT NULL DEFAULT 0
        CHECK (attempt_count >= 0),

    available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    lease_token TEXT,
    lease_until TIMESTAMPTZ,

    -- Store a short, sanitized code only; never persist raw exception text,
    -- addresses, credentials, or external provider responses here.
    last_error_code TEXT
        CHECK (
            last_error_code IS NULL
            OR (
                length(last_error_code) BETWEEN 1 AND 100
                AND last_error_code = btrim(last_error_code)
            )
        ),

    -- Sanitized outcome metadata only; do not store addresses or provider
    -- request/response payloads.
    redispatch_result JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    settled_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    redispatch_completed_at TIMESTAMPTZ,

    CONSTRAINT driver_offer_action_outbox_idempotency_key_check
        CHECK (
            idempotency_key IS NULL
            OR (
                length(idempotency_key) BETWEEN 1 AND 200
                AND idempotency_key = btrim(idempotency_key)
            )
        ),

    CONSTRAINT driver_offer_action_outbox_driver_idempotency_key_key
        UNIQUE (driver_id, idempotency_key),

    CONSTRAINT driver_offer_action_outbox_policy_outcome_check
        CHECK (
            (action = 'accept' AND policy_outcome IS NULL)
            OR
            (
                action = 'reject'
                AND policy_outcome IS NOT NULL
                AND length(policy_outcome) BETWEEN 1 AND 100
                AND policy_outcome = btrim(policy_outcome)
            )
        ),

    CONSTRAINT driver_offer_action_outbox_action_redispatch_check
        CHECK (
            (action = 'accept' AND redispatch_status = 'not_required')
            OR
            (action = 'reject' AND redispatch_status <> 'not_required')
        ),

    CONSTRAINT driver_offer_action_outbox_lease_check
        CHECK (
            (
                redispatch_status = 'leased'
                AND lease_token IS NOT NULL
                AND length(lease_token) BETWEEN 1 AND 200
                AND lease_token = btrim(lease_token)
                AND lease_until IS NOT NULL
            )
            OR
            (
                redispatch_status <> 'leased'
                AND lease_token IS NULL
                AND lease_until IS NULL
            )
        ),

    CONSTRAINT driver_offer_action_outbox_completed_at_check
        CHECK (
            (redispatch_status = 'completed'
                AND redispatch_completed_at IS NOT NULL)
            OR
            (redispatch_status <> 'completed'
                AND redispatch_completed_at IS NULL)
        ),

    CONSTRAINT driver_offer_action_outbox_settled_at_check
        CHECK (settled_at >= created_at)
);

-- Workers claim the oldest due reject jobs; accepted actions are excluded.
CREATE INDEX driver_offer_action_outbox_ready_idx
    ON driver_offer_action_outbox (available_at, created_at, action_id)
    WHERE action = 'reject'
      AND redispatch_status IN ('queued', 'retryable');

-- Allows recovery workers to reclaim jobs whose lease expired.
CREATE INDEX driver_offer_action_outbox_expired_lease_idx
    ON driver_offer_action_outbox (lease_until, action_id)
    WHERE redispatch_status = 'leased';

-- Supports authenticated action history and processing lookups by driver.
CREATE INDEX driver_offer_action_outbox_driver_history_idx
    ON driver_offer_action_outbox (driver_id, created_at DESC, action_id);
