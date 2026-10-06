package com.example.demo.repository;

import java.util.Optional;
import java.util.UUID;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import com.example.demo.domain.Psychologist;

import jakarta.persistence.LockModeType;

public interface PsychologistRepository extends JpaRepository<Psychologist, UUID> {

	@Lock(LockModeType.PESSIMISTIC_WRITE)
	@Query("select p from Psychologist p where p.id = :id")
	Optional<Psychologist> findByIdForUpdate(@Param("id") UUID id);
}
