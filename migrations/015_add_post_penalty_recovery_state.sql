ALTER TABLE driver_dispatch_states
    ADD COLUMN requires_completed_ride_after_penalty BOOLEAN NOT NULL DEFAULT FALSE;
