package com.example.demo.repository;

import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

import org.springframework.data.jpa.repository.JpaRepository;

import com.example.demo.domain.Reservation;

public interface ReservationRepository extends JpaRepository<Reservation, UUID> {

	boolean existsByPsychologistIdAndStartsAt(UUID psychologistId, Instant startsAt);

	List<Reservation> findAllByPsychologistIdInAndStartsAtGreaterThanEqualAndStartsAtLessThan(
			Collection<UUID> psychologistIds, Instant from, Instant to);
}
