/**
 * Thin HTTP client for ExchangeRate-API (v6 "pair" endpoint).
 *
 * SECURITY: no URL host and no API key exist in this class. The callout goes through the
 * Named Credential "ExchangeRate_API"; the key lives in the External Credential
 * "ExchangeRate_API_EC" and is injected by the platform as an "Authorization: Bearer" header.
 *
 * This class never throws for API problems - every outcome (success, API error, HTTP error,
 * empty body, invalid JSON, network failure) is returned as a RateResult so that callers can
 * record it and keep processing.
 */
public with sharing class ExchangeRateApiClient {

    public static final String NAMED_CREDENTIAL = 'ExchangeRate_API';
    public static final String BASE_CURRENCY = 'BDT';
    private static final Integer TIMEOUT_MS = 20000;

    // Errors that will hit every currency the same way -> stop calling the API for this run.
    private static final Set<String> HALTING_ERRORS = new Set<String>{
        'invalid-key', 'inactive-account', 'authentication-failed', 'quota-reached', 'rate-limited'
    };

    public class RateResult {
        public String baseCurrency;
        public String targetCurrency;
        public Decimal rate;
        public Boolean success = false;
        public Boolean attempted = true;   // false = no HTTP request was made
        public String errorType;
        public String errorMessage;
        public Integer statusCode;
        public Datetime retrievedAt;

        public RateResult() {}
        public RateResult(String baseCurrency, String targetCurrency) {
            this.baseCurrency = baseCurrency;
            this.targetCurrency = targetCurrency;
            this.retrievedAt = Datetime.now();
        }
        public Boolean isHaltingError() {
            return !success && errorType != null && HALTING_ERRORS.contains(errorType);
        }
    }

    /** Retrieves the BDT -> target rate. One HTTP callout. */
    public static RateResult fetchRate(String baseCurrency, String targetCurrency) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + '/pair/'
            + EncodingUtil.urlEncode(baseCurrency, 'UTF-8') + '/'
            + EncodingUtil.urlEncode(targetCurrency, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        try {
            HttpResponse res = new Http().send(req);
            return parseResponse(baseCurrency, targetCurrency, res.getStatusCode(), res.getBody());
        } catch (Exception e) {
            RateResult r = new RateResult(baseCurrency, targetCurrency);
            return fail(r, 'callout-exception',
                'Callout to ExchangeRate-API failed (callout-exception): ' + e.getMessage());
        }
    }

    /** Result for a currency we deliberately did not call the API for. */
    public static RateResult notAttempted(String baseCurrency, String targetCurrency,
                                          String errorType, String message) {
        RateResult r = new RateResult(baseCurrency, targetCurrency);
        r.attempted = false;
        return fail(r, errorType, message);
    }

    /** Turns an HTTP status + body into a RateResult. Public for unit testing. */
    @TestVisible
    private static RateResult parseResponse(String baseCurrency, String targetCurrency,
                                            Integer statusCode, String body) {
        RateResult r = new RateResult(baseCurrency, targetCurrency);
        r.statusCode = statusCode;
        Boolean httpOk = statusCode != null && statusCode >= 200 && statusCode < 300;

        if (String.isBlank(body)) {
            if (!httpOk) { return failHttp(r, statusCode); }
            return fail(r, 'empty-response', 'ExchangeRate-API returned an empty response body (empty-response).');
        }

        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (Exception e) {
            if (!httpOk) { return failHttp(r, statusCode); }
            return fail(r, 'invalid-json', 'ExchangeRate-API returned a response that is not valid JSON (invalid-json).');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            if (!httpOk) { return failHttp(r, statusCode); }
            return fail(r, 'invalid-response', 'ExchangeRate-API returned an unexpected JSON structure (invalid-response).');
        }

        Map<String, Object> payload = (Map<String, Object>) parsed;
        String result = payload.get('result') == null ? null : String.valueOf(payload.get('result'));

        if (result == 'error') {
            String errorType = payload.get('error-type') == null ? 'unknown-error' : String.valueOf(payload.get('error-type'));
            return fail(r, errorType, messageFor(errorType, targetCurrency));
        }
        if (!httpOk) { return failHttp(r, statusCode); }
        if (result != 'success') {
            return fail(r, 'invalid-response', 'ExchangeRate-API response has no "result":"success" marker (invalid-response).');
        }
        if (payload.get('target_code') != null && String.valueOf(payload.get('target_code')) != targetCurrency) {
            return fail(r, 'invalid-response', 'ExchangeRate-API returned a rate for a different currency than requested (invalid-response).');
        }

        Decimal rate;
        try {
            rate = payload.get('conversion_rate') == null ? null : Decimal.valueOf(String.valueOf(payload.get('conversion_rate')));
        } catch (Exception e) {
            rate = null;
        }
        if (rate != null) { rate = rate.setScale(8, RoundingMode.HALF_UP); }
        if (rate == null || rate <= 0) {
            return fail(r, 'invalid-response', 'ExchangeRate-API response has a missing or non-positive conversion_rate (invalid-response).');
        }

        r.rate = rate;
        r.success = true;
        return r;
    }

    private static RateResult fail(RateResult r, String errorType, String message) {
        r.success = false;
        r.errorType = errorType;
        r.errorMessage = message;
        return r;
    }

    private static RateResult failHttp(RateResult r, Integer statusCode) {
        if (statusCode == 401 || statusCode == 403) {
            return fail(r, 'authentication-failed', 'HTTP ' + statusCode
                + ': ExchangeRate-API rejected the credentials (authentication-failed). Check the API key in the External Credential.');
        }
        if (statusCode == 429) {
            return fail(r, 'rate-limited', 'HTTP 429: ExchangeRate-API rate limit reached (rate-limited).');
        }
        if (statusCode != null && statusCode >= 500) {
            return fail(r, 'server-error', 'HTTP ' + statusCode + ': ExchangeRate-API server error (server-error).');
        }
        return fail(r, 'http-error', 'HTTP ' + statusCode + ': unexpected response from ExchangeRate-API (http-error).');
    }

    private static String messageFor(String errorType, String targetCurrency) {
        switch on errorType {
            when 'invalid-key' {
                return 'ExchangeRate-API rejected the API key (invalid-key). Check the key stored in the ExchangeRate_API_EC External Credential.';
            }
            when 'inactive-account' {
                return 'ExchangeRate-API account is inactive - the account e-mail has not been confirmed (inactive-account).';
            }
            when 'quota-reached' {
                return 'ExchangeRate-API request quota has been reached (quota-reached).';
            }
            when 'unsupported-code' {
                return 'ExchangeRate-API does not support currency code "' + targetCurrency + '" (unsupported-code).';
            }
            when 'malformed-request' {
                return 'ExchangeRate-API could not understand the request (malformed-request).';
            }
            when else {
                return 'ExchangeRate-API returned an error (' + errorType + ').';
            }
        }
    }
}
