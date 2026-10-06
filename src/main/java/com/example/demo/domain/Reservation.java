package com.example.demo.domain;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;

@Entity
@Table(name = "reservations", uniqueConstraints = @UniqueConstraint(
		name = "uk_reservation_psychologist_start",
		columnNames = { "psychologist_id", "starts_at" }))
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
}
