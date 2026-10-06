package com.example.demo.api;

import java.time.Instant;

import org.springframework.dao.ConcurrencyFailureException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

import com.example.demo.service.ResourceNotFoundException;
import com.example.demo.service.SlotConflictException;

import jakarta.validation.ConstraintViolationException;

@RestControllerAdvice
public class ApiExceptionHandler {

	@ExceptionHandler(ResourceNotFoundException.class)
	public ResponseEntity<ApiError> notFound(ResourceNotFoundException exception) {
		return error(HttpStatus.NOT_FOUND, exception.getMessage());
	}

	@ExceptionHandler({ SlotConflictException.class, DataIntegrityViolationException.class,
			ConcurrencyFailureException.class })
	public ResponseEntity<ApiError> conflict(Exception exception) {
		String message = exception instanceof SlotConflictException
				? exception.getMessage() : "The requested availability slot was reserved concurrently";
		return error(HttpStatus.CONFLICT, message);
	}

	@ExceptionHandler({ IllegalArgumentException.class, ConstraintViolationException.class,
			MethodArgumentNotValidException.class, HttpMessageNotReadableException.class,
			MethodArgumentTypeMismatchException.class })
	public ResponseEntity<ApiError> badRequest(Exception exception) {
		String message = exception instanceof MethodArgumentNotValidException validationException
				? validationException.getBindingResult().getFieldErrors().stream()
						.map(fieldError -> fieldError.getField() + ": " + fieldError.getDefaultMessage())
						.findFirst().orElse("Request validation failed")
				: exception.getMessage();
		return error(HttpStatus.BAD_REQUEST, message);
	}

	private ResponseEntity<ApiError> error(HttpStatus status, String message) {
		ApiError body = new ApiError(Instant.now(), status.value(), status.getReasonPhrase(), message);
		return ResponseEntity.status(status).body(body);
	}
}
