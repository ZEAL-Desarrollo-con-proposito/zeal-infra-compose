package com.example.demo.service;

import java.time.Clock;
import java.time.Instant;
import java.util.List;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import com.example.demo.api.ReservationResponse;
import com.example.demo.api.ReserveAppointmentRequest;
import com.example.demo.domain.AvailabilityRule;
import com.example.demo.domain.Psychologist;
import com.example.demo.domain.Reservation;
import com.example.demo.realtime.SlotOccupiedEvent;
import com.example.demo.repository.AvailabilityRuleRepository;
import com.example.demo.repository.PsychologistRepository;
import com.example.demo.repository.ReservationRepository;

@Service
public class ReservationService {

	private final PsychologistRepository psychologistRepository;
	private final AvailabilityRuleRepository availabilityRuleRepository;
	private final ReservationRepository reservationRepository;
	private final AvailabilityService availabilityService;
	private final ApplicationEventPublisher eventPublisher;
	private final Clock clock;

	public ReservationService(PsychologistRepository psychologistRepository,
			AvailabilityRuleRepository availabilityRuleRepository,
			ReservationRepository reservationRepository, AvailabilityService availabilityService,
			ApplicationEventPublisher eventPublisher, Clock clock) {
		this.psychologistRepository = psychologistRepository;
		this.availabilityRuleRepository = availabilityRuleRepository;
		this.reservationRepository = reservationRepository;
		this.availabilityService = availabilityService;
		this.eventPublisher = eventPublisher;
		this.clock = clock;
	}

	@Transactional(isolation = Isolation.SERIALIZABLE)
	public ReservationResponse reserve(ReserveAppointmentRequest request) {
		Psychologist psychologist = psychologistRepository.findByIdForUpdate(request.psychologistId())
				.orElseThrow(() -> new ResourceNotFoundException("Psychologist not found"));
		Instant startsAt = request.startsAt();
		if (!startsAt.isAfter(clock.instant())) {
			throw new SlotConflictException("The requested availability slot is no longer available");
		}
		if (reservationRepository.existsByPsychologistIdAndStartsAt(psychologist.getId(), startsAt)) {
			throw new SlotConflictException("The requested availability slot is already reserved");
		}

		List<AvailabilityRule> rules = availabilityRuleRepository.findAllByPsychologistId(psychologist.getId());
		var slot = availabilityService.findSlot(rules, startsAt);
		if (slot == null) {
			throw new SlotConflictException("The requested time is not part of the psychologist's availability");
		}

		Reservation reservation = reservationRepository.saveAndFlush(new Reservation(
				psychologist, request.employeeId(), slot.startsAt(), slot.endsAt()));
		eventPublisher.publishEvent(new SlotOccupiedEvent(
				psychologist.getId(), reservation.getId(), reservation.getStartsAt(), reservation.getEndsAt()));
		return new ReservationResponse(reservation.getId(), psychologist.getId(), reservation.getEmployeeId(),
				reservation.getStartsAt(), reservation.getEndsAt());
	}
}
