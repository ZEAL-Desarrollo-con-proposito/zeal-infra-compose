package com.example.demo.repository;

import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import com.example.demo.domain.Reservation;
import com.example.demo.domain.ReservationStatus;

import jakarta.persistence.LockModeType;

public interface ReservationRepository extends JpaRepository<Reservation, UUID> {

	boolean existsByPsychologistIdAndStartsAtAndStatus(
			UUID psychologistId, Instant startsAt, ReservationStatus status);

	List<Reservation> findAllByPsychologistIdInAndStartsAtGreaterThanEqualAndStartsAtLessThanAndStatus(
			Collection<UUID> psychologistIds, Instant from, Instant to, ReservationStatus status);

	@Lock(LockModeType.PESSIMISTIC_WRITE)
	@Query("select r from Reservation r where r.id = :id")
	Optional<Reservation> findByIdForUpdate(@Param("id") UUID id);
}
