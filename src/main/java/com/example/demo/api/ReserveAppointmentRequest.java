package com.example.demo.api;

import java.time.Instant;
import java.util.UUID;

import jakarta.validation.constraints.NotNull;

public record ReserveAppointmentRequest(
		@NotNull UUID psychologistId,
		@NotNull UUID employeeId,
		@NotNull Instant startsAt) {
}
