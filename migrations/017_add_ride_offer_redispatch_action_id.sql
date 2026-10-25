-- Persist the outbox action that caused an automatic redispatch offer.
-- Existing offers remain unlinked (NULL); no historical backfill is intended.
ALTER TABLE ride_offers
    ADD COLUMN redispatch_action_id TEXT
        REFERENCES driver_offer_action_outbox(action_id);

-- A single reject action may create at most one automatic offer, including
-- after that offer is accepted, rejected, or expired.
CREATE UNIQUE INDEX ride_offers_redispatch_action_id_unique_idx
    ON ride_offers (redispatch_action_id)
    WHERE redispatch_action_id IS NOT NULL;

ALTER TABLE ride_offers
    ADD CONSTRAINT ride_offers_redispatch_action_automatic_check
    CHECK (
        redispatch_action_id IS NULL
        OR source = 'automatic'
    );
