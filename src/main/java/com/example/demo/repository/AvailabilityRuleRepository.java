package com.example.demo.repository;

import java.time.DayOfWeek;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

import org.springframework.data.jpa.repository.JpaRepository;

import com.example.demo.domain.AvailabilityRule;

public interface AvailabilityRuleRepository extends JpaRepository<AvailabilityRule, UUID> {

	List<AvailabilityRule> findAllByPsychologistIdIn(Collection<UUID> psychologistIds);

	List<AvailabilityRule> findAllByPsychologistIdAndDayOfWeek(UUID psychologistId, DayOfWeek dayOfWeek);

	List<AvailabilityRule> findAllByPsychologistId(UUID psychologistId);
}
