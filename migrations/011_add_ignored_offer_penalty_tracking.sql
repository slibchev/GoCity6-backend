CREATE TABLE ignored_offer_penalty_tracking (
    offer_id TEXT PRIMARY KEY
        REFERENCES ride_offers(id),

    driver_id TEXT NOT NULL
        REFERENCES drivers(id),

    dispatch_round INTEGER NOT NULL
        CHECK (dispatch_round IN (1, 2)),

    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ignored_offer_penalty_tracking_driver_idx
    ON ignored_offer_penalty_tracking (driver_id);