package com.example.demo.api;

import java.time.Instant;
import java.util.UUID;

public record ReservationResponse(
		UUID id,
		UUID psychologistId,
		UUID employeeId,
		Instant startsAt,
		Instant endsAt) {
}
