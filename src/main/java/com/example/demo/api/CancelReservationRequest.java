package com.example.demo.api;

import java.util.UUID;

import jakarta.validation.constraints.NotNull;

public record CancelReservationRequest(@NotNull UUID employeeId) {
}
