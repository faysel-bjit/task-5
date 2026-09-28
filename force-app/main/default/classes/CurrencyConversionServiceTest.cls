/**
 * Service-level tests. Data is created in @TestSetup (committed) so the callouts made by the
 * service are not blocked by "uncommitted work pending".
 */
@isTest
private class CurrencyConversionServiceTest {

    @TestSetup
    static void setup() {
        CurrencyTestDataFactory.disableAutoProcessing();
        insert new List<Opportunity>{
            CurrencyTestDataFactory.build('T-USD-1', 1000000, 'USD'),
            CurrencyTestDataFactory.build('T-USD-2', 2500000, 'USD'),
            CurrencyTestDataFactory.build('T-EUR-1', 800000, 'EUR'),
            CurrencyTestDataFactory.build('T-JPY-1', 5000000, 'JPY'),
            CurrencyTestDataFactory.build('T-GBP-1', 3200000, 'GBP'),
            CurrencyTestDataFactory.build('T-BLANK', 500000, null),
            CurrencyTestDataFactory.build('T-INVALID', 500000, 'XYZ'),
            CurrencyTestDataFactory.build('T-BADFMT', 500000, 'US'),
            CurrencyTestDataFactory.build('T-NOAMT', null, 'USD'),
            // earlier successful USD conversion worth 8,100 (old rate 0.0081)
            CurrencyTestDataFactory.buildConverted('T-PREV', 1000000, 'USD', 'USD', 8100, 0.0081, 'Success'),
            // user switched USD -> EUR; old USD amount still on the record
            CurrencyTestDataFactory.buildConverted('T-CHANGE', 1000000, 'EUR', 'USD', 8200, 0.0082, 'Pending')
        };
    }

    private static CurrencyConversionService.ProcessingSummary process(Set<String> names,
                                                                       CurrencyConversionService.ProcessingContext ctx) {
        return CurrencyConversionService.processOpportunities(CurrencyTestDataFactory.getByNames(names), ctx);
    }

    private static void mockDefaultRates() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));
    }

    // ---------------------------------------------------------------- successful conversions
    @isTest
    static void bdtToUsd_calculatesAndUpdatesFields() {
        mockDefaultRates();
        CurrencyConversionService.ProcessingSummary s = process(new Set<String>{ 'T-USD-1' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-USD-1');
        Assert.areEqual(8200.00, o.Expected_Currency_Amount__c, '1,000,000 BDT x 0.0082');
        Assert.areEqual(0.0082, o.Exchange_Rate__c);
        Assert.areEqual('Success', o.Currency_Update_Status__c);
        Assert.areEqual(1000000, o.Amount, 'Amount must stay in BDT and unchanged');
        Assert.areEqual('USD', o.Expected_Currency_Type__c);
        Assert.areEqual('USD', o.Last_Converted_Currency__c);
        Assert.isNotNull(o.Currency_Last_Updated__c);
        Assert.isNull(o.Currency_Error_Message__c);
        Assert.areEqual(1, s.success);
        Assert.areEqual(0, s.failed);
    }

    @isTest
    static void bdtToEur_calculatesAndUpdatesFields() {
        mockDefaultRates();
        process(new Set<String>{ 'T-EUR-1' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-EUR-1');
        Assert.areEqual(5600.00, o.Expected_Currency_Amount__c, '800,000 BDT x 0.0070');
        Assert.areEqual(0.0070, o.Exchange_Rate__c);
        Assert.areEqual('Success', o.Currency_Update_Status__c);
        Assert.areEqual(800000, o.Amount);
    }

    @isTest
    static void sameCurrency_multipleOpportunities_singleApiCall() {
        mockDefaultRates();
        CurrencyConversionService.ProcessingSummary s = process(new Set<String>{ 'T-USD-1', 'T-USD-2', 'T-PREV' }, null);

        Assert.areEqual(1, ExchangeRateApiMock.callCount, 'Three USD Opportunities must share one API call');
        Assert.areEqual(1, s.apiCalls);
        Assert.areEqual(3, s.success);
        Assert.areEqual(8200.00, CurrencyTestDataFactory.getByName('T-USD-1').Expected_Currency_Amount__c);
        Assert.areEqual(20500.00, CurrencyTestDataFactory.getByName('T-USD-2').Expected_Currency_Amount__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Exchange_Rate_History__c], 'One history row per API call');
    }

    @isTest
    static void differentCurrencies_onePerCurrency_correctAmounts() {
        mockDefaultRates();
        CurrencyConversionService.ProcessingSummary s = process(
            new Set<String>{ 'T-USD-1', 'T-USD-2', 'T-EUR-1', 'T-JPY-1', 'T-GBP-1' }, null);

        Assert.areEqual(4, ExchangeRateApiMock.callCount, 'USD, EUR, JPY, GBP = 4 calls for 5 Opportunities');
        Assert.areEqual(5, s.success);
        Assert.areEqual(5600.00, CurrencyTestDataFactory.getByName('T-EUR-1').Expected_Currency_Amount__c);
        Assert.areEqual(6250000.00, CurrencyTestDataFactory.getByName('T-JPY-1').Expected_Currency_Amount__c, '5,000,000 x 1.25');
        Assert.areEqual(19520.00, CurrencyTestDataFactory.getByName('T-GBP-1').Expected_Currency_Amount__c, '3,200,000 x 0.0061');
        Assert.areEqual(1.25, CurrencyTestDataFactory.getByName('T-JPY-1').Exchange_Rate__c);
    }

    @isTest
    static void rateCache_isReusedAcrossChunksOfTheSameRun() {
        mockDefaultRates();
        CurrencyConversionService.ProcessingContext ctx = new CurrencyConversionService.ProcessingContext();

        process(new Set<String>{ 'T-USD-1' }, ctx);      // chunk 1 -> callout
        process(new Set<String>{ 'T-USD-2' }, ctx);      // chunk 2 -> cache hit, no callout

        Assert.areEqual(1, ExchangeRateApiMock.callCount, 'Second chunk must reuse the cached USD rate');
        Assert.areEqual(1, ctx.apiCalls);
        Assert.areEqual(20500.00, CurrencyTestDataFactory.getByName('T-USD-2').Expected_Currency_Amount__c);
        Assert.areEqual(2, [SELECT COUNT() FROM Opportunity_Currency_Update__c WHERE Expected_Currency_Type__c = 'USD'],
            'Both Opportunities get a tracking row');
        Assert.areEqual(1, [SELECT COUNT() FROM Exchange_Rate_History__c]);
        Id historyId = [SELECT Id FROM Exchange_Rate_History__c LIMIT 1].Id;
        Assert.areEqual(2, [SELECT COUNT() FROM Opportunity_Currency_Update__c WHERE Exchange_Rate_History__c = :historyId],
            'Tracking rows of both chunks point at the same rate record');
    }

    // ---------------------------------------------------------------- tracking
    @isTest
    static void exchangeRateHistory_isCreatedPerCurrency() {
        mockDefaultRates();
        process(new Set<String>{ 'T-USD-1', 'T-EUR-1' }, null);

        List<Exchange_Rate_History__c> rows = [
            SELECT Base_Currency__c, Target_Currency__c, Exchange_Rate__c, Retrieved_At__c, API_Status__c, Error_Details__c
            FROM Exchange_Rate_History__c ORDER BY Target_Currency__c
        ];
        Assert.areEqual(2, rows.size());
        Assert.areEqual('EUR', rows[0].Target_Currency__c);
        Assert.areEqual(0.0070, rows[0].Exchange_Rate__c);
        Assert.areEqual('USD', rows[1].Target_Currency__c);
        Assert.areEqual(0.0082, rows[1].Exchange_Rate__c);
        for (Exchange_Rate_History__c r : rows) {
            Assert.areEqual('BDT', r.Base_Currency__c);
            Assert.areEqual('Success', r.API_Status__c);
            Assert.isNotNull(r.Retrieved_At__c);
            Assert.isNull(r.Error_Details__c);
        }
    }

    @isTest
    static void opportunityUpdateTracking_capturesPreviousAndNewValues() {
        mockDefaultRates();
        process(new Set<String>{ 'T-PREV' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-PREV');
        Opportunity_Currency_Update__c t = [
            SELECT Opportunity__c, Opportunity_Amount_BDT__c, Expected_Currency_Type__c, Previous_Currency_Type__c,
                   Exchange_Rate_Used__c, Previous_Expected_Amount__c, New_Expected_Amount__c, Updated_At__c,
                   Exchange_Rate_History__r.Target_Currency__c
            FROM Opportunity_Currency_Update__c
        ];
        Assert.areEqual(o.Id, t.Opportunity__c);
        Assert.areEqual(1000000, t.Opportunity_Amount_BDT__c);
        Assert.areEqual('USD', t.Expected_Currency_Type__c);
        Assert.areEqual('USD', t.Previous_Currency_Type__c);
        Assert.areEqual(0.0082, t.Exchange_Rate_Used__c);
        Assert.areEqual(8100, t.Previous_Expected_Amount__c, 'Value before the update');
        Assert.areEqual(8200, t.New_Expected_Amount__c, 'Value after the update');
        Assert.isNotNull(t.Updated_At__c);
        Assert.areEqual('USD', t.Exchange_Rate_History__r.Target_Currency__c);
    }

    @isTest
    static void firstConversion_hasNoPreviousValue() {
        mockDefaultRates();
        process(new Set<String>{ 'T-USD-1' }, null);
        Opportunity_Currency_Update__c t = [SELECT Previous_Expected_Amount__c, Previous_Currency_Type__c FROM Opportunity_Currency_Update__c];
        Assert.isNull(t.Previous_Expected_Amount__c);
        Assert.isNull(t.Previous_Currency_Type__c);
    }

    // ---------------------------------------------------------------- currency type change (REQ 08)
    @isTest
    static void currencyTypeChange_recalculatesAndKeepsPreviousInTracking() {
        mockDefaultRates();
        process(new Set<String>{ 'T-CHANGE' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-CHANGE');
        Assert.areEqual(7000.00, o.Expected_Currency_Amount__c, 'Recalculated with BDT->EUR: 1,000,000 x 0.0070');
        Assert.areEqual(0.0070, o.Exchange_Rate__c);
        Assert.areEqual('EUR', o.Last_Converted_Currency__c);
        Assert.areEqual('Success', o.Currency_Update_Status__c);
        Assert.areEqual(1000000, o.Amount);

        Opportunity_Currency_Update__c t = [
            SELECT Expected_Currency_Type__c, Previous_Currency_Type__c, Previous_Expected_Amount__c, New_Expected_Amount__c
            FROM Opportunity_Currency_Update__c WHERE Opportunity__c = :o.Id
        ];
        Assert.areEqual('EUR', t.Expected_Currency_Type__c);
        Assert.areEqual('USD', t.Previous_Currency_Type__c, 'Tracking keeps the currency the old value was in');
        Assert.areEqual(8200, t.Previous_Expected_Amount__c);
        Assert.areEqual(7000, t.New_Expected_Amount__c);
    }

    // ---------------------------------------------------------------- validation failures / skips
    @isTest
    static void invalidCurrencyCode_apiRejects_marksFailed() {
        mockDefaultRates();     // XYZ is not in the mock -> unsupported-code
        CurrencyConversionService.ProcessingSummary s = process(new Set<String>{ 'T-INVALID' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-INVALID');
        Assert.areEqual('Failed', o.Currency_Update_Status__c);
        Assert.isTrue(o.Currency_Error_Message__c.contains('unsupported-code'), o.Currency_Error_Message__c);
        Assert.isTrue(o.Currency_Error_Message__c.contains('XYZ'));
        Assert.isNull(o.Expected_Currency_Amount__c);
        Assert.isNull(o.Exchange_Rate__c);
        Assert.areEqual(500000, o.Amount);
        Assert.areEqual(1, s.failed);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity_Currency_Update__c], 'No tracking row for a failure');
        Exchange_Rate_History__c h = [SELECT API_Status__c, Error_Details__c, Target_Currency__c, Exchange_Rate__c FROM Exchange_Rate_History__c];
        Assert.areEqual('Failed', h.API_Status__c, 'Failed API calls are also tracked');
        Assert.areEqual('XYZ', h.Target_Currency__c);
        Assert.isNotNull(h.Error_Details__c);
        Assert.isNull(h.Exchange_Rate__c);
    }

    @isTest
    static void malformedCurrencyCode_failsWithoutCallingApi() {
        mockDefaultRates();
        process(new Set<String>{ 'T-BADFMT' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-BADFMT');
        Assert.areEqual('Failed', o.Currency_Update_Status__c);
        Assert.isTrue(o.Currency_Error_Message__c.contains('Invalid currency code'));
        Assert.areEqual(0, ExchangeRateApiMock.callCount, 'Format errors are caught before any callout');
    }

    @isTest
    static void blankCurrencyType_isSkipped() {
        mockDefaultRates();
        CurrencyConversionService.ProcessingSummary s = process(new Set<String>{ 'T-BLANK' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-BLANK');
        Assert.isNull(o.Currency_Update_Status__c, 'Untouched');
        Assert.isNull(o.Expected_Currency_Amount__c);
        Assert.areEqual(1, s.skipped);
        Assert.areEqual(0, ExchangeRateApiMock.callCount);
        Assert.areEqual(0, [SELECT COUNT() FROM Exchange_Rate_History__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
    }

    @isTest
    static void blankAmount_isMarkedFailed_withoutCallout() {
        mockDefaultRates();
        process(new Set<String>{ 'T-NOAMT' }, null);

        Opportunity o = CurrencyTestDataFactory.getByName('T-NOAMT');
        Assert.areEqual('Failed', o.Currency_Update_Status__c);
        Assert.isTrue(o.Currency_Error_Message__c.contains('Amount is blank'));
        Assert.isNull(o.Expected_Currency_Amount__c);
        Assert.areEqual(0, ExchangeRateApiMock.callCount, 'Nothing to convert -> no API call wasted');
    }

    // ---------------------------------------------------------------- API failures (REQ 09)
    private static void assertPreviousValuesPreserved() {
        Opportunity o = CurrencyTestDataFactory.getByName('T-PREV');
        Assert.areEqual('Failed', o.Currency_Update_Status__c);
        Assert.areEqual(8100.00, o.Expected_Currency_Amount__c, 'Previously valid amount must survive a failed run');
        Assert.areEqual(0.0081, o.Exchange_Rate__c, 'Previously valid rate must survive a failed run');
        Assert.areEqual(Datetime.newInstance(2026, 1, 1, 0, 0, 0), o.Currency_Last_Updated__c);
        Assert.areEqual(1000000, o.Amount);
        Assert.isNotNull(o.Currency_Error_Message__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity_Currency_Update__c], 'No tracking row for a failure');
    }

    @isTest
    static void apiAuthenticationFailure_marksFailed_preservesValues_andStopsCalling() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withApiError('invalid-key'));
        CurrencyConversionService.ProcessingSummary s = process(
            new Set<String>{ 'T-PREV', 'T-EUR-1', 'T-JPY-1' }, null);

        assertPreviousValuesPreserved();
        Assert.isTrue(CurrencyTestDataFactory.getByName('T-PREV').Currency_Error_Message__c.contains('invalid-key'));
        Assert.areEqual(3, s.failed);
        Assert.areEqual(1, ExchangeRateApiMock.callCount, 'After an auth failure the remaining currencies are not attempted');
        Integer notAttempted = 0;
        for (Opportunity o : CurrencyTestDataFactory.getByNames(new Set<String>{ 'T-PREV', 'T-EUR-1', 'T-JPY-1' })) {
            Assert.areEqual('Failed', o.Currency_Update_Status__c);
            if (o.Currency_Error_Message__c.contains('Not attempted')) { notAttempted++; }
        }
        Assert.areEqual(2, notAttempted, 'Two of the three currencies were never sent to the API');
        Assert.areEqual(1, [SELECT COUNT() FROM Exchange_Rate_History__c], 'Only the real API call is tracked');
        Assert.areEqual('Failed', [SELECT API_Status__c FROM Exchange_Rate_History__c].API_Status__c);
    }

    @isTest
    static void apiQuotaExceeded_marksFailed_preservesValues() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withApiError('quota-reached'));
        process(new Set<String>{ 'T-PREV', 'T-EUR-1' }, null);

        assertPreviousValuesPreserved();
        Assert.isTrue(CurrencyTestDataFactory.getByName('T-PREV').Currency_Error_Message__c.contains('quota-reached'));
        Assert.areEqual(1, ExchangeRateApiMock.callCount, 'Quota is exhausted, so stop spending requests');
    }

    @isTest
    static void apiServerError_marksFailed_preservesValues() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(500, 'Internal Server Error'));
        process(new Set<String>{ 'T-PREV', 'T-EUR-1' }, null);

        assertPreviousValuesPreserved();
        Assert.isTrue(CurrencyTestDataFactory.getByName('T-PREV').Currency_Error_Message__c.contains('HTTP 500'));
        Assert.areEqual(2, ExchangeRateApiMock.callCount, 'A 5xx is per-request, so each currency is still tried');
    }

    @isTest
    static void emptyResponseBody_marksFailed_preservesValues() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, ''));
        process(new Set<String>{ 'T-PREV' }, null);

        assertPreviousValuesPreserved();
        Assert.isTrue(CurrencyTestDataFactory.getByName('T-PREV').Currency_Error_Message__c.contains('empty'));
    }

    @isTest
    static void invalidJsonResponse_marksFailed_preservesValues() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(200, 'not json at all'));
        process(new Set<String>{ 'T-PREV' }, null);

        assertPreviousValuesPreserved();
        Assert.isTrue(CurrencyTestDataFactory.getByName('T-PREV').Currency_Error_Message__c.contains('not valid JSON'));
    }

    @isTest
    static void networkFailure_marksFailed_preservesValues() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withNetworkFailure());
        process(new Set<String>{ 'T-PREV' }, null);

        assertPreviousValuesPreserved();
        Assert.isTrue(CurrencyTestDataFactory.getByName('T-PREV').Currency_Error_Message__c.contains('Simulated network failure'));
    }

    @isTest
    static void mixedBatch_validAndInvalid_processedIndependently() {
        mockDefaultRates();
        CurrencyConversionService.ProcessingSummary s = process(
            new Set<String>{ 'T-USD-1', 'T-INVALID', 'T-BLANK', 'T-BADFMT', 'T-NOAMT' }, null);

        Assert.areEqual(1, s.success);
        Assert.areEqual(3, s.failed);
        Assert.areEqual(1, s.skipped);
        Assert.areEqual('Success', CurrencyTestDataFactory.getByName('T-USD-1').Currency_Update_Status__c);
        Assert.areEqual('Failed', CurrencyTestDataFactory.getByName('T-INVALID').Currency_Update_Status__c);
    }

    // ---------------------------------------------------------------- misc
    @isTest
    static void emptyOrNullInput_isNoOp() {
        Assert.areEqual(0, CurrencyConversionService.processOpportunities(null, null).success);
        Assert.areEqual(0, CurrencyConversionService.processOpportunities(new List<Opportunity>(), null).success);
        Assert.areEqual(0, ExchangeRateApiMock.callCount);
    }

    @isTest
    static void processOpportunityIds_queriesAndConverts() {
        mockDefaultRates();
        Opportunity o = CurrencyTestDataFactory.getByName('T-USD-1');
        CurrencyConversionService.processOpportunityIds(new Set<Id>{ o.Id }, null);
        Assert.areEqual(8200.00, CurrencyTestDataFactory.getByName('T-USD-1').Expected_Currency_Amount__c);
    }

    @isTest
    static void lowerCaseAndPaddedCurrency_isNormalisedBeforeCalling() {
        mockDefaultRates();
        Opportunity o = CurrencyTestDataFactory.getByName('T-USD-1');
        o.Expected_Currency_Type__c = ' usd ';           // in-memory only, service must still cope
        CurrencyConversionService.processOpportunities(new List<Opportunity>{ o }, null);
        Assert.areEqual('callout:ExchangeRate_API/pair/BDT/USD', ExchangeRateApiMock.endpoints[0]);
        Assert.areEqual(8200.00, CurrencyTestDataFactory.getByName('T-USD-1').Expected_Currency_Amount__c);
    }

    @isTest
    static void markFailed_flagsOnlyNotYetSuccessfulRecords() {
        Opportunity pending = CurrencyTestDataFactory.getByName('T-USD-1');
        Opportunity done = CurrencyTestDataFactory.getByName('T-PREV');

        CurrencyConversionService.markFailed(new Set<Id>{ pending.Id, done.Id }, 'boom');

        Opportunity p = CurrencyTestDataFactory.getByName('T-USD-1');
        Assert.areEqual('Failed', p.Currency_Update_Status__c);
        Assert.areEqual('boom', p.Currency_Error_Message__c);
        Assert.areEqual('Success', CurrencyTestDataFactory.getByName('T-PREV').Currency_Update_Status__c,
            'A record that is already Success is not downgraded');
    }

    @isTest
    static void summaryAdd_accumulatesAndCapsErrors() {
        CurrencyConversionService.ProcessingSummary a = new CurrencyConversionService.ProcessingSummary();
        CurrencyConversionService.ProcessingSummary b = new CurrencyConversionService.ProcessingSummary();
        b.success = 2; b.failed = 1; b.skipped = 3; b.apiCalls = 4; b.dmlErrors = 5;
        for (Integer i = 0; i < 30; i++) { b.errors.add('e' + i); }
        a.add(b);
        a.add(b);
        Assert.areEqual(4, a.success);
        Assert.areEqual(2, a.failed);
        Assert.areEqual(6, a.skipped);
        Assert.areEqual(8, a.apiCalls);
        Assert.areEqual(10, a.dmlErrors);
        Assert.areEqual(20, a.errors.size());
    }
}
