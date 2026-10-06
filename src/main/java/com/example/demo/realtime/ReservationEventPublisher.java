package com.example.demo.realtime;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

@Component
@ConditionalOnProperty(name = "app.redis.enabled", havingValue = "true", matchIfMissing = true)
public class ReservationEventPublisher {

	static final String CHANNEL = "wellbeing:availability:occupied";

	private static final Logger logger = LoggerFactory.getLogger(ReservationEventPublisher.class);

	private final StringRedisTemplate redisTemplate;
	private final ObjectMapper objectMapper;

	public ReservationEventPublisher(StringRedisTemplate redisTemplate, ObjectMapper objectMapper) {
		this.redisTemplate = redisTemplate;
		this.objectMapper = objectMapper;
	}

	@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
	public void publish(SlotOccupiedEvent event) {
		try {
			redisTemplate.convertAndSend(CHANNEL, objectMapper.writeValueAsString(event));
		}
		catch (JacksonException exception) {
			logger.error("Could not serialize occupied-slot event for reservation {}", event.reservationId(), exception);
		}
		catch (RuntimeException exception) {
			logger.error("Could not publish occupied-slot event for reservation {}", event.reservationId(), exception);
		}
	}
}
