package com.example.demo.domain;

import java.time.DayOfWeek;
import java.time.LocalTime;
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
@Table(name = "availability_rules")
public class AvailabilityRule {

	@Id
	@GeneratedValue(strategy = GenerationType.UUID)
	private UUID id;

	@ManyToOne(fetch = FetchType.LAZY, optional = false)
	@JoinColumn(name = "psychologist_id", nullable = false)
	private Psychologist psychologist;

	@Enumerated(EnumType.STRING)
	@Column(nullable = false)
	private DayOfWeek dayOfWeek;

	@Column(nullable = false)
	private LocalTime startTime;

	@Column(nullable = false)
	private LocalTime endTime;

	@Column(nullable = false)
	private int slotDurationMinutes;

	@Column(nullable = false)
	private String zoneId;

	protected AvailabilityRule() {
	}

	public AvailabilityRule(Psychologist psychologist, DayOfWeek dayOfWeek, LocalTime startTime,
			LocalTime endTime, int slotDurationMinutes, String zoneId) {
		this.psychologist = psychologist;
		this.dayOfWeek = dayOfWeek;
		this.startTime = startTime;
		this.endTime = endTime;
		this.slotDurationMinutes = slotDurationMinutes;
		this.zoneId = zoneId;
	}

	public UUID getId() {
		return id;
	}

	public Psychologist getPsychologist() {
		return psychologist;
	}

	public DayOfWeek getDayOfWeek() {
		return dayOfWeek;
	}

	public LocalTime getStartTime() {
		return startTime;
	}

	public LocalTime getEndTime() {
		return endTime;
	}

	public int getSlotDurationMinutes() {
		return slotDurationMinutes;
	}

	public String getZoneId() {
		return zoneId;
	}
}
