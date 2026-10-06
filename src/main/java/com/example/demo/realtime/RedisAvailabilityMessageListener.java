package com.example.demo.realtime;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.data.redis.connection.Message;
import org.springframework.data.redis.connection.MessageListener;
import org.springframework.messaging.simp.SimpMessagingTemplate;
import org.springframework.stereotype.Component;

import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

@Component
@ConditionalOnProperty(name = "app.redis.enabled", havingValue = "true", matchIfMissing = true)
public class RedisAvailabilityMessageListener implements MessageListener {

	private static final Logger logger = LoggerFactory.getLogger(RedisAvailabilityMessageListener.class);

	private final ObjectMapper objectMapper;
	private final SimpMessagingTemplate messagingTemplate;

	public RedisAvailabilityMessageListener(ObjectMapper objectMapper, SimpMessagingTemplate messagingTemplate) {
		this.objectMapper = objectMapper;
		this.messagingTemplate = messagingTemplate;
	}

	@Override
	public void onMessage(Message message, byte[] pattern) {
		try {
			SlotOccupiedEvent event = objectMapper.readValue(message.getBody(), SlotOccupiedEvent.class);
			messagingTemplate.convertAndSend("/topic/availability", event);
		}
		catch (JacksonException exception) {
			logger.error("Could not process Redis occupied-slot event", exception);
		}
	}
}
