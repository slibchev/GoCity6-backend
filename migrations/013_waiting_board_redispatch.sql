-- Keep a durable distinction between regular pending-ride offers and
-- automatic offers that temporarily reserve a waiting-board ride.
ALTER TABLE ride_offers
    ADD COLUMN source TEXT NOT NULL DEFAULT 'automatic';

ALTER TABLE ride_offers
    ADD CONSTRAINT ride_offers_source_check
    CHECK (source IN ('automatic', 'waiting_board'));

-- The redispatch worker reads a bounded oldest-first page of live board rides.
CREATE INDEX rides_waiting_redispatch_requested_at_idx
    ON rides (requested_at ASC, id ASC)
    WHERE status = 'waitingForVehicle'
      AND assigned_driver_id IS NULL
      AND assigned_vehicle_id IS NULL;
