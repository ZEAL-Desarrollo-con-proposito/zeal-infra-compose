package com.example.demo.service;

import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.example.demo.api.AvailabilityDirectoryResponse;
import com.example.demo.api.AvailabilityDirectoryResponse.FreeSlotResponse;
import com.example.demo.domain.AvailabilityRule;
import com.example.demo.domain.Psychologist;
import com.example.demo.domain.Reservation;
import com.example.demo.domain.ReservationStatus;
import com.example.demo.repository.AvailabilityRuleRepository;
import com.example.demo.repository.PsychologistRepository;
import com.example.demo.repository.ReservationRepository;

@Service
public class AvailabilityService {

	private final PsychologistRepository psychologistRepository;
	private final AvailabilityRuleRepository availabilityRuleRepository;
	private final ReservationRepository reservationRepository;
	private final Clock clock;

	public AvailabilityService(PsychologistRepository psychologistRepository,
			AvailabilityRuleRepository availabilityRuleRepository,
			ReservationRepository reservationRepository, Clock clock) {
		this.psychologistRepository = psychologistRepository;
		this.availabilityRuleRepository = availabilityRuleRepository;
		this.reservationRepository = reservationRepository;
		this.clock = clock;
	}

	@Transactional(readOnly = true)
	public List<AvailabilityDirectoryResponse> directory(LocalDate from, LocalDate to) {
		if (to.isBefore(from)) {
			throw new IllegalArgumentException("End date must not be before start date");
		}

		List<Psychologist> psychologists = psychologistRepository.findAll();
		if (psychologists.isEmpty()) {
			return List.of();
		}
		List<UUID> psychologistIds = psychologists.stream().map(Psychologist::getId).toList();
		List<AvailabilityRule> rules = availabilityRuleRepository.findAllByPsychologistIdIn(psychologistIds);
		Map<UUID, List<AvailabilityRule>> rulesByPsychologist = rules.stream()
				.collect(Collectors.groupingBy(rule -> rule.getPsychologist().getId()));
		List<Reservation> reservations = reservationRepository
				.findAllByPsychologistIdInAndStartsAtGreaterThanEqualAndStartsAtLessThanAndStatus(
						psychologistIds, from.minusDays(1).atStartOfDay(ZoneId.of("UTC")).toInstant(),
						to.plusDays(2).atStartOfDay(ZoneId.of("UTC")).toInstant(), ReservationStatus.ACTIVE);
		Set<String> reservedOccurrences = reservations.stream()
				.map(reservation -> key(reservation.getPsychologist().getId(), reservation.getStartsAt()))
				.collect(Collectors.toCollection(HashSet::new));
		Instant now = clock.instant();

		return psychologists.stream().map(psychologist -> {
			List<FreeSlotResponse> freeSlots = generateSlots(
					rulesByPsychologist.getOrDefault(psychologist.getId(), List.of()), from, to).stream()
					.filter(slot -> slot.startsAt().isAfter(now))
					.filter(slot -> !reservedOccurrences.contains(key(psychologist.getId(), slot.startsAt())))
					.distinct()
					.toList();
			return new AvailabilityDirectoryResponse(psychologist.getId(), psychologist.getName(), freeSlots);
		}).filter(response -> !response.freeSlots().isEmpty()).toList();
	}

	public FreeSlotResponse findSlot(Collection<AvailabilityRule> rules, Instant startsAt) {
		for (AvailabilityRule rule : rules) {
			ZoneId zoneId = ZoneId.of(rule.getZoneId());
			LocalDate date = startsAt.atZone(zoneId).toLocalDate();
			if (date.getDayOfWeek() != rule.getDayOfWeek()) {
				continue;
			}
			for (FreeSlotResponse slot : generateSlots(List.of(rule), date, date)) {
				if (slot.startsAt().equals(startsAt)) {
					return slot;
				}
			}
		}
		return null;
	}

	private List<FreeSlotResponse> generateSlots(List<AvailabilityRule> rules, LocalDate from, LocalDate to) {
		List<FreeSlotResponse> slots = new ArrayList<>();
		for (LocalDate date = from; !date.isAfter(to); date = date.plusDays(1)) {
			for (AvailabilityRule rule : rules) {
				if (date.getDayOfWeek() != rule.getDayOfWeek()) {
					continue;
				}
				ZoneId zoneId = ZoneId.of(rule.getZoneId());
				LocalDateTime start = LocalDateTime.of(date, rule.getStartTime());
				LocalDateTime end = LocalDateTime.of(date, rule.getEndTime());
				for (LocalDateTime slotStart = start;
						!slotStart.plusMinutes(rule.getSlotDurationMinutes()).isAfter(end);
						slotStart = slotStart.plusMinutes(rule.getSlotDurationMinutes())) {
					List<ZoneOffset> validOffsets = zoneId.getRules().getValidOffsets(slotStart);
					if (!validOffsets.isEmpty()) {
						Instant startsAt = slotStart.toInstant(validOffsets.get(0));
						Instant endsAt = startsAt.plusSeconds(rule.getSlotDurationMinutes() * 60L);
						slots.add(new FreeSlotResponse(startsAt, endsAt));
					}
				}
			}
		}
		return slots;
	}

	static String key(UUID psychologistId, Instant startsAt) {
		return psychologistId + ":" + startsAt;
	}
}
