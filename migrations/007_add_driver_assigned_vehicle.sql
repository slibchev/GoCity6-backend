ALTER TABLE drivers
ADD COLUMN assigned_vehicle_id TEXT
    REFERENCES vehicles(id);

CREATE INDEX drivers_assigned_vehicle_id_idx
    ON drivers (assigned_vehicle_id);