package com.example.demo.realtime;

import java.time.Instant;
import java.util.UUID;

public record SlotOccupiedEvent(UUID psychologistId, UUID reservationId, Instant startsAt, Instant endsAt) {
}
