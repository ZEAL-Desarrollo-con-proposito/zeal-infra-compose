package com.example.demo.domain;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;

@Entity
@Table(name = "reservations")
public class Reservation {

	@Id
	@GeneratedValue(strategy = GenerationType.UUID)
	private UUID id;

	@ManyToOne(fetch = FetchType.LAZY, optional = false)
	@JoinColumn(name = "psychologist_id", nullable = false)
	private Psychologist psychologist;

	@Column(nullable = false)
	private UUID employeeId;

	@Column(name = "starts_at", nullable = false)
	private Instant startsAt;

	@Column(name = "ends_at", nullable = false)
	private Instant endsAt;

	@Enumerated(EnumType.STRING)
	@Column(nullable = false, length = 20)
	private ReservationStatus status = ReservationStatus.ACTIVE;

	protected Reservation() {
	}

	public Reservation(Psychologist psychologist, UUID employeeId, Instant startsAt, Instant endsAt) {
		this.psychologist = psychologist;
		this.employeeId = employeeId;
		this.startsAt = startsAt;
		this.endsAt = endsAt;
	}

	public UUID getId() {
		return id;
	}

	public Psychologist getPsychologist() {
		return psychologist;
	}

	public UUID getEmployeeId() {
		return employeeId;
	}

	public Instant getStartsAt() {
		return startsAt;
	}

	public Instant getEndsAt() {
		return endsAt;
	}

	public ReservationStatus getStatus() {
		return status;
	}

	public void cancel() {
		if (status != ReservationStatus.ACTIVE) {
			throw new IllegalStateException("Only active reservations can be cancelled");
		}
		status = ReservationStatus.CANCELLED;
	}
}
