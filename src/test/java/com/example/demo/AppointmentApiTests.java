package com.example.demo;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.demo.api.ReserveAppointmentRequest;
import com.example.demo.domain.AvailabilityRule;
import com.example.demo.domain.Psychologist;
import com.example.demo.domain.Reservation;
import com.example.demo.domain.ReservationStatus;
import com.example.demo.repository.AvailabilityRuleRepository;
import com.example.demo.repository.PsychologistRepository;
import com.example.demo.repository.ReservationRepository;
import com.example.demo.service.ReservationService;
import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneOffset;
import java.time.temporal.TemporalAdjusters;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@SpringBootTest
@AutoConfigureMockMvc
class AppointmentApiTests {

	@Autowired
	private MockMvc mockMvc;

	@Autowired
	private ReservationService reservationService;

	@Autowired
	private PsychologistRepository psychologistRepository;

	@Autowired
	private AvailabilityRuleRepository availabilityRuleRepository;

	@Autowired
	private ReservationRepository reservationRepository;

	@Autowired
	private PlatformTransactionManager transactionManager;

	@Autowired
	private JdbcTemplate jdbcTemplate;

	@BeforeEach
	void clearDatabase() {
		jdbcTemplate.execute("""
				ALTER TABLE reservations ADD COLUMN IF NOT EXISTS active_key BOOLEAN
				GENERATED ALWAYS AS (CASE WHEN status = 'ACTIVE' THEN TRUE ELSE NULL END)
				""");
		jdbcTemplate.execute("""
				CREATE UNIQUE INDEX IF NOT EXISTS uk_test_reservation_active_slot
				ON reservations (psychologist_id, starts_at, active_key)
				""");
		reservationRepository.deleteAll();
		availabilityRuleRepository.deleteAll();
		psychologistRepository.deleteAll();
	}

	@Test
	void directoryOmitsReservedOccurrencesAndReservationEndpointReturnsConflict() throws Exception {
		Psychologist psychologist = createMondayPsychologist();
		Instant firstSlot = nextMondayAt(9);
		UUID employeeId = UUID.randomUUID();
		String request = """
				{"psychologistId":"%s","employeeId":"%s","startsAt":"%s"}
				""".formatted(psychologist.getId(), employeeId, firstSlot);

		mockMvc.perform(post("/api/reservations").contentType("application/json").content(request))
				.andExpect(status().isCreated());
		mockMvc.perform(post("/api/reservations").contentType("application/json").content(request))
				.andExpect(status().isConflict());

		LocalDate nextMonday = firstSlot.atZone(ZoneOffset.UTC).toLocalDate();
		mockMvc.perform(get("/api/psychologists/availability")
						.param("from", nextMonday.toString()).param("to", nextMonday.plusWeeks(1).toString()))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$[0].psychologistId").value(psychologist.getId().toString()))
				.andExpect(jsonPath("$[0].freeSlots.length()").value(3))
				.andExpect(jsonPath("$[0].freeSlots[0].startsAt")
						.value(nextMondayAt(9).plusSeconds(1800).toString()))
				.andExpect(jsonPath("$[0].freeSlots[1].startsAt")
						.value(nextMonday.plusWeeks(1).atTime(9, 0).toInstant(ZoneOffset.UTC).toString()));
	}

	@Test
	void simultaneousReservationsAllowOnlyOneWinner() throws Exception {
		Psychologist psychologist = createMondayPsychologist();
		Instant startsAt = nextMondayAt(9);
		CountDownLatch ready = new CountDownLatch(2);
		CountDownLatch start = new CountDownLatch(1);

		try (var executor = Executors.newFixedThreadPool(2)) {
			List<Future<Boolean>> results = List.of(
					executor.submit(() -> tryReserve(psychologist.getId(), startsAt, ready, start)),
					executor.submit(() -> tryReserve(psychologist.getId(), startsAt, ready, start)));

			ready.await();
			start.countDown();
			long winners = results.stream().filter(this::successful).count();

			assertEquals(1, winners);
			assertEquals(1, reservationRepository.count());
		}
	}

	@Test
	void cancellationReleasesSlotAndAllowsReservationAgain() throws Exception {
		Psychologist psychologist = createMondayPsychologist();
		Instant startsAt = nextMondayAt(9);
		UUID employeeId = UUID.randomUUID();
		String reserveRequest = """
				{"psychologistId":"%s","employeeId":"%s","startsAt":"%s"}
				""".formatted(psychologist.getId(), employeeId, startsAt);
		mockMvc.perform(post("/api/reservations").contentType("application/json").content(reserveRequest))
				.andExpect(status().isCreated());

		Reservation reservation = reservationRepository.findAll().get(0);
		String cancelRequest = """
				{"employeeId":"%s"}
				""".formatted(employeeId);
		mockMvc.perform(delete("/api/reservations/{reservationId}", reservation.getId())
						.contentType("application/json").content(cancelRequest))
				.andExpect(status().isNoContent());

		assertEquals(ReservationStatus.CANCELLED, reservationRepository.findById(reservation.getId()).orElseThrow()
				.getStatus());
		LocalDate monday = startsAt.atZone(ZoneOffset.UTC).toLocalDate();
		mockMvc.perform(get("/api/psychologists/availability")
						.param("from", monday.toString()).param("to", monday.plusWeeks(1).toString()))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$[0].freeSlots.length()").value(4));

		mockMvc.perform(post("/api/reservations").contentType("application/json").content(reserveRequest))
				.andExpect(status().isCreated());
		assertEquals(2, reservationRepository.count());
	}

	@Test
	void cancellationRejectsAnotherEmployeesReservationAndUnknownReservation() throws Exception {
		Psychologist psychologist = createMondayPsychologist();
		UUID employeeId = UUID.randomUUID();
		mockMvc.perform(post("/api/reservations").contentType("application/json").content("""
				{"psychologistId":"%s","employeeId":"%s","startsAt":"%s"}
				""".formatted(psychologist.getId(), employeeId, nextMondayAt(9))))
				.andExpect(status().isCreated());
		Reservation reservation = reservationRepository.findAll().get(0);

		mockMvc.perform(delete("/api/reservations/{reservationId}", reservation.getId())
						.contentType("application/json")
						.content("{\"employeeId\":\"" + UUID.randomUUID() + "\"}"))
				.andExpect(status().isNotFound());
		mockMvc.perform(delete("/api/reservations/{reservationId}", UUID.randomUUID())
						.contentType("application/json")
						.content("{\"employeeId\":\"" + employeeId + "\"}"))
				.andExpect(status().isNotFound());

		assertEquals(ReservationStatus.ACTIVE, reservationRepository.findById(reservation.getId()).orElseThrow()
				.getStatus());
	}

	@Test
	void cancellationCannotBeRepeated() throws Exception {
		Psychologist psychologist = createMondayPsychologist();
		UUID employeeId = UUID.randomUUID();
		mockMvc.perform(post("/api/reservations").contentType("application/json").content("""
				{"psychologistId":"%s","employeeId":"%s","startsAt":"%s"}
				""".formatted(psychologist.getId(), employeeId, nextMondayAt(9))))
				.andExpect(status().isCreated());
		Reservation reservation = reservationRepository.findAll().get(0);
		String request = "{\"employeeId\":\"" + employeeId + "\"}";

		mockMvc.perform(delete("/api/reservations/{reservationId}", reservation.getId())
						.contentType("application/json").content(request))
				.andExpect(status().isNoContent());
		mockMvc.perform(delete("/api/reservations/{reservationId}", reservation.getId())
						.contentType("application/json").content(request))
				.andExpect(status().isConflict());

		assertEquals(1, reservationRepository.count());
	}

	private Psychologist createMondayPsychologist() {
		return new TransactionTemplate(transactionManager).execute(status -> {
			Psychologist psychologist = psychologistRepository.saveAndFlush(new Psychologist("Dr. Test"));
			availabilityRuleRepository.save(new AvailabilityRule(
					psychologist, DayOfWeek.MONDAY, LocalTime.of(9, 0),
					LocalTime.of(10, 0), 30, "UTC"));
			return psychologist;
		});
	}

	private Instant nextMondayAt(int hour) {
		return LocalDate.now(ZoneOffset.UTC).with(TemporalAdjusters.next(DayOfWeek.MONDAY))
				.atTime(hour, 0).toInstant(ZoneOffset.UTC);
	}

	private boolean tryReserve(UUID psychologistId, Instant startsAt, CountDownLatch ready, CountDownLatch start) {
		ready.countDown();
		try {
			start.await();
			reservationService.reserve(new ReserveAppointmentRequest(
					psychologistId, UUID.randomUUID(), startsAt));
			return true;
		}
		catch (RuntimeException exception) {
			return false;
		}
		catch (InterruptedException exception) {
			Thread.currentThread().interrupt();
			return false;
		}
	}

	private boolean successful(Future<Boolean> result) {
		try {
			return result.get();
		}
		catch (Exception exception) {
			return false;
		}
	}
}
