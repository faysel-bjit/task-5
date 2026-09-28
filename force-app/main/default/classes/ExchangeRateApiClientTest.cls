@isTest
private class ExchangeRateApiClientTest {

    @isTest
    static void fetchRate_success_returnsRateAndUsesNamedCredential() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));

        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');

        Assert.isTrue(r.success, 'Expected a successful result');
        Assert.areEqual(0.0082, r.rate);
        Assert.areEqual('BDT', r.baseCurrency);
        Assert.areEqual('USD', r.targetCurrency);
        Assert.areEqual(1, ExchangeRateApiMock.callCount);
        Assert.areEqual('callout:ExchangeRate_API/pair/BDT/USD', ExchangeRateApiMock.endpoints[0],
            'Callout must go through the Named Credential, with no host or API key in code');
    }

    @isTest
    static void fetchRate_eurRate() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'EUR');
        Assert.isTrue(r.success);
        Assert.areEqual(0.0070, r.rate);
    }

    @isTest
    static void unsupportedCode_isReportedAsFailure() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'XYZ');
        Assert.isFalse(r.success);
        Assert.areEqual('unsupported-code', r.errorType);
        Assert.isTrue(r.errorMessage.contains('XYZ'));
        Assert.isFalse(r.isHaltingError(), 'A bad currency must not stop other currencies from being fetched');
    }

    @isTest
    static void invalidKey_apiErrorBody_isHaltingAuthFailure() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withApiError('invalid-key'));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.isFalse(r.success);
        Assert.areEqual('invalid-key', r.errorType);
        Assert.isTrue(r.errorMessage.contains('invalid-key'));
        Assert.isTrue(r.isHaltingError());
        Assert.isNull(r.rate);
    }

    @isTest
    static void http401_emptyBody_isAuthenticationFailure() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(401, ''));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.isFalse(r.success);
        Assert.areEqual('authentication-failed', r.errorType);
        Assert.areEqual(401, r.statusCode);
        Assert.isTrue(r.isHaltingError());
    }

    @isTest
    static void quotaReached_isHaltingFailure() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withApiError('quota-reached'));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.isFalse(r.success);
        Assert.areEqual('quota-reached', r.errorType);
        Assert.isTrue(r.isHaltingError());
    }

    @isTest
    static void inactiveAccountAndMalformedRequest_haveMeaningfulMessages() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withApiError('inactive-account'));
        Assert.isTrue(ExchangeRateApiClient.fetchRate('BDT', 'USD').errorMessage.contains('inactive-account'));
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withApiError('malformed-request'));
        Assert.isTrue(ExchangeRateApiClient.fetchRate('BDT', 'USD').errorMessage.contains('malformed-request'));
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withApiError('something-new'));
        Assert.isTrue(ExchangeRateApiClient.fetchRate('BDT', 'USD').errorMessage.contains('something-new'));
    }

    @isTest
    static void http429_isRateLimited() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(429, 'Too Many Requests'));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.areEqual('rate-limited', r.errorType);
        Assert.isTrue(r.isHaltingError());
    }

    @isTest
    static void http500_htmlBody_isServerError() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(500, '<html>Internal Server Error</html>'));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.isFalse(r.success);
        Assert.areEqual('server-error', r.errorType);
        Assert.isTrue(r.errorMessage.contains('HTTP 500'));
        Assert.isFalse(r.isHaltingError(), 'A 5xx is per-request; other currencies may still work');
    }

    @isTest
    static void http404_isGenericHttpError() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(404, ''));
        Assert.areEqual('http-error', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType);
    }

    @isTest
    static void emptyBody_withHttp200_isEmptyResponse() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, ''));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.isFalse(r.success);
        Assert.areEqual('empty-response', r.errorType);
    }

    @isTest
    static void invalidJson_isReported() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, '{"result": "success", conversion_rate'));
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.isFalse(r.success);
        Assert.areEqual('invalid-json', r.errorType);
    }

    @isTest
    static void jsonArray_isUnexpectedStructure() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, '[1,2,3]'));
        Assert.areEqual('invalid-response', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType);
    }

    @isTest
    static void successBody_withBadRate_isRejected() {
        String prefix = '{"result":"success","target_code":"USD","conversion_rate":';
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, prefix + '0}'));
        Assert.areEqual('invalid-response', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType, 'zero rate');
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, prefix + '-1.5}'));
        Assert.areEqual('invalid-response', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType, 'negative rate');
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, prefix + '"abc"}'));
        Assert.areEqual('invalid-response', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType, 'non numeric rate');
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, '{"result":"success","target_code":"USD"}'));
        Assert.areEqual('invalid-response', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType, 'missing rate');
    }

    @isTest
    static void successBody_forDifferentCurrency_isRejected() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200,
            '{"result":"success","target_code":"EUR","conversion_rate":0.007}'));
        Assert.areEqual('invalid-response', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType);
    }

    @isTest
    static void missingResultMarker_isInvalidResponse() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, '{"conversion_rate":0.0082}'));
        Assert.areEqual('invalid-response', ExchangeRateApiClient.fetchRate('BDT', 'USD').errorType);
    }

    @isTest
    static void networkFailure_isCaughtNotThrown() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withNetworkFailure());
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.fetchRate('BDT', 'USD');
        Assert.isFalse(r.success);
        Assert.areEqual('callout-exception', r.errorType);
        Assert.isTrue(r.errorMessage.contains('Simulated network failure'));
    }

    @isTest
    static void rateIsRoundedToEightDecimals() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200,
            '{"result":"success","target_code":"USD","conversion_rate":0.008212345678}'));
        Assert.areEqual(0.00821235, ExchangeRateApiClient.fetchRate('BDT', 'USD').rate);
    }

    @isTest
    static void notAttempted_marksNoRequestMade() {
        ExchangeRateApiClient.RateResult r = ExchangeRateApiClient.notAttempted('BDT', 'USD', 'callout-limit', 'x');
        Assert.isFalse(r.success);
        Assert.isFalse(r.attempted);
        Assert.areEqual(0, ExchangeRateApiMock.callCount);
    }
}
