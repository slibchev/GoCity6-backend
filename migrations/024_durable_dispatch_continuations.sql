-- Extend the existing offer-action outbox so the same lease/retry/recovery
-- mechanism can also resume an initial dispatch and a timed-out offer.
-- Existing accept/reject history is preserved and backfilled to ride_id.

ALTER TABLE driver_offer_action_outbox
    ADD COLUMN ride_id TEXT REFERENCES rides(id);

UPDATE driver_offer_action_outbox AS action
SET ride_id = offer.ride_id
FROM ride_offers AS offer
WHERE action.offer_id = offer.id
  AND action.ride_id IS NULL;

ALTER TABLE driver_offer_action_outbox
    ALTER COLUMN ride_id SET NOT NULL,
    ALTER COLUMN offer_id DROP NOT NULL,
    ALTER COLUMN driver_id DROP NOT NULL;

ALTER TABLE driver_offer_action_outbox
    DROP CONSTRAINT driver_offer_action_outbox_offer_id_key,
    DROP CONSTRAINT driver_offer_action_outbox_action_check,
    DROP CONSTRAINT driver_offer_action_outbox_policy_outcome_check,
    DROP CONSTRAINT driver_offer_action_outbox_action_redispatch_check;

ALTER TABLE driver_offer_action_outbox
    ADD CONSTRAINT driver_offer_action_outbox_action_check
        CHECK (action IN ('accept', 'reject', 'timeout', 'initial_dispatch')),
    ADD CONSTRAINT driver_offer_action_outbox_target_check
        CHECK (
            (action = 'initial_dispatch'
                AND offer_id IS NULL
                AND driver_id IS NULL
                AND idempotency_key IS NULL)
            OR
            (action <> 'initial_dispatch'
                AND offer_id IS NOT NULL
                AND driver_id IS NOT NULL)
        ),
    ADD CONSTRAINT driver_offer_action_outbox_policy_outcome_check
        CHECK (
            (action = 'accept' AND policy_outcome IS NULL)
            OR
            (action = 'initial_dispatch' AND policy_outcome IS NULL)
            OR
            (action = 'timeout' AND policy_outcome = 'timeout')
            OR
            (
                action = 'reject'
                AND policy_outcome IS NOT NULL
                AND length(policy_outcome) BETWEEN 1 AND 100
                AND policy_outcome = btrim(policy_outcome)
            )
        ),
    ADD CONSTRAINT driver_offer_action_outbox_action_redispatch_check
        CHECK (
            (action = 'accept' AND redispatch_status = 'not_required')
            OR
            (action IN ('reject', 'timeout', 'initial_dispatch')
                AND redispatch_status <> 'not_required')
        );

CREATE UNIQUE INDEX driver_offer_action_outbox_offer_id_unique_idx
    ON driver_offer_action_outbox (offer_id)
    WHERE offer_id IS NOT NULL;

CREATE UNIQUE INDEX driver_offer_action_outbox_initial_ride_unique_idx
    ON driver_offer_action_outbox (ride_id)
    WHERE action = 'initial_dispatch';

DROP INDEX driver_offer_action_outbox_ready_idx;

CREATE INDEX driver_offer_action_outbox_ready_idx
    ON driver_offer_action_outbox (available_at, created_at, action_id)
    WHERE action IN ('reject', 'timeout', 'initial_dispatch')
      AND redispatch_status IN ('queued', 'retryable');
