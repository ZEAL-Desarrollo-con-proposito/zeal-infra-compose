ALTER TABLE reservations
	ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE';

ALTER TABLE reservations
	DROP CONSTRAINT IF EXISTS uk_reservation_psychologist_start;

CREATE UNIQUE INDEX IF NOT EXISTS uk_reservation_active_psychologist_start
	ON reservations (psychologist_id, starts_at)
	WHERE status = 'ACTIVE';
