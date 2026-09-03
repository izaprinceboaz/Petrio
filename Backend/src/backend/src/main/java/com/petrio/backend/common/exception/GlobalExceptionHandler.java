package com.petrio.backend.common.exception;

import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class GlobalExceptionHandler {
    

    // @ExceptionHandler(AccessDeniedException.class)
    // public Accds handleAccessDeniedException(AccessDeniedException ex) {
    //     return new ApiError(403, "Forbidden", ex.getMessage(), "/api/ping");
    // }
}
