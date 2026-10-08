package com.example.demo.api;

import java.net.URI;
import java.util.UUID;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.support.ServletUriComponentsBuilder;

import com.example.demo.service.ReservationService;

import jakarta.validation.Valid;

@RestController
@RequestMapping("/api/reservations")
public class ReservationController {

	private final ReservationService reservationService;

	public ReservationController(ReservationService reservationService) {
		this.reservationService = reservationService;
	}

	@PostMapping
	public ResponseEntity<ReservationResponse> reserve(@Valid @RequestBody ReserveAppointmentRequest request) {
		ReservationResponse response = reservationService.reserve(request);
		URI location = ServletUriComponentsBuilder.fromCurrentRequest().path("/{id}")
				.buildAndExpand(response.id()).toUri();
		return ResponseEntity.created(location).body(response);
	}

	@DeleteMapping("/{reservationId}")
	public ResponseEntity<Void> cancel(@PathVariable UUID reservationId,
			@Valid @RequestBody CancelReservationRequest request) {
		reservationService.cancel(reservationId, request);
		return ResponseEntity.noContent().build();
	}
}
