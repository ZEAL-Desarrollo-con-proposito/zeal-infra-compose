package com.example.demo.api;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record AvailabilityDirectoryResponse(
		UUID psychologistId,
		String psychologistName,
		List<FreeSlotResponse> freeSlots) {

	public record FreeSlotResponse(Instant startsAt, Instant endsAt) {
	}
}
