CREATE TABLE driver_dispatch_states (
    driver_id TEXT PRIMARY KEY
        REFERENCES drivers(id),

    -- Поредни отказани/игнорирани доставени оферти.
    consecutive_rejects INTEGER NOT NULL DEFAULT 0
        CHECK (consecutive_rejects >= 0),

    -- Ниво на натрупаните санкции в текущия работен период.
    -- 0 -> следващата санкция е 30 min
    -- 1 -> следващата е 60 min
    -- 2 -> следващата е 90 min
    -- и т.н.
    penalty_level INTEGER NOT NULL DEFAULT 0
        CHECK (penalty_level >= 0),

    -- До кога водачът е изключен от automatic dispatch.
    dispatch_blocked_until TIMESTAMPTZ,

    -- След край на смяна наказателната история може да се
    -- занули едва след 8 непрекъснати часа извън смяна.
    penalty_reset_eligible_at TIMESTAMPTZ,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX driver_dispatch_states_blocked_until_idx
    ON driver_dispatch_states (dispatch_blocked_until)
    WHERE dispatch_blocked_until IS NOT NULL;