/**
 * End-to-end tests: DML on Opportunity -> trigger -> Queueable/Batch -> service -> callout mock.
 * Async work runs when Test.stopTest() is called.
 */
@isTest
private class OpportunityCurrencyTriggerTest {

    private static void mockDefaultRates() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));
    }

    @isTest
    static void insert_withCurrency_setsPending_thenConvertsAsync() {
        mockDefaultRates();
        Opportunity opp = CurrencyTestDataFactory.build('TR-INSERT', 1000000, ' usd ');

        Test.startTest();
        insert opp;
        Assert.areEqual('Pending', CurrencyTestDataFactory.getByName('TR-INSERT').Currency_Update_Status__c,
            'Stamped Pending synchronously, converted asynchronously');
        Test.stopTest();

        Opportunity r = CurrencyTestDataFactory.getByName('TR-INSERT');
        Assert.areEqual('USD', r.Expected_Currency_Type__c, 'Currency code normalised');
        Assert.areEqual('Success', r.Currency_Update_Status__c);
        Assert.areEqual(8200.00, r.Expected_Currency_Amount__c);
        Assert.areEqual(0.0082, r.Exchange_Rate__c);
        Assert.areEqual(1000000, r.Amount);
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
        Assert.areEqual(1, [SELECT COUNT() FROM Exchange_Rate_History__c]);
    }

    @isTest
    static void insert_eur_convertsWithEurRate() {
        mockDefaultRates();
        Test.startTest();
        insert CurrencyTestDataFactory.build('TR-EUR', 800000, 'EUR');
        Test.stopTest();
        Opportunity r = CurrencyTestDataFactory.getByName('TR-EUR');
        Assert.areEqual(5600.00, r.Expected_Currency_Amount__c);
        Assert.areEqual('Success', r.Currency_Update_Status__c);
    }

    @isTest
    static void insert_blankCurrency_isIgnored() {
        mockDefaultRates();
        Test.startTest();
        insert CurrencyTestDataFactory.build('TR-BLANK', 500000, null);
        Test.stopTest();

        Opportunity r = CurrencyTestDataFactory.getByName('TR-BLANK');
        Assert.isNull(r.Currency_Update_Status__c);
        Assert.isNull(r.Expected_Currency_Amount__c);
        Assert.areEqual(0, ExchangeRateApiMock.callCount, 'No conversion, no API call');
    }

    @isTest
    static void insert_invalidCurrency_endsFailedWithMessage() {
        mockDefaultRates();
        Test.startTest();
        insert CurrencyTestDataFactory.build('TR-XYZ', 500000, 'XYZ');
        Test.stopTest();

        Opportunity r = CurrencyTestDataFactory.getByName('TR-XYZ');
        Assert.areEqual('Failed', r.Currency_Update_Status__c);
        Assert.isTrue(r.Currency_Error_Message__c.contains('unsupported-code'));
        Assert.isNull(r.Expected_Currency_Amount__c);
    }

    @isTest
    static void insert_apiDown_endsFailed_amountUntouched() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(500, 'oops'));
        Test.startTest();
        insert CurrencyTestDataFactory.build('TR-DOWN', 1000000, 'USD');
        Test.stopTest();

        Opportunity r = CurrencyTestDataFactory.getByName('TR-DOWN');
        Assert.areEqual('Failed', r.Currency_Update_Status__c);
        Assert.isTrue(r.Currency_Error_Message__c.contains('HTTP 500'));
        Assert.isNull(r.Expected_Currency_Amount__c);
        Assert.areEqual(1000000, r.Amount);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
    }

    @isTest
    static void currencyTypeChange_usdToEur_recalculatesAndKeepsHistory() {
        Opportunity seed = CurrencyTestDataFactory.buildConverted('TR-CHANGE', 1000000, 'USD', 'USD', 8200, 0.0082, 'Success');
        insert seed;                       // status supplied -> no conversion is triggered
        mockDefaultRates();

        Test.startTest();
        seed.Expected_Currency_Type__c = 'EUR';
        update seed;
        Assert.areEqual('Pending', CurrencyTestDataFactory.getByName('TR-CHANGE').Currency_Update_Status__c);
        Test.stopTest();

        Opportunity r = CurrencyTestDataFactory.getByName('TR-CHANGE');
        Assert.areEqual('EUR', r.Expected_Currency_Type__c);
        Assert.areEqual(7000.00, r.Expected_Currency_Amount__c, '1,000,000 x 0.0070');
        Assert.areEqual(0.0070, r.Exchange_Rate__c);
        Assert.areEqual('Success', r.Currency_Update_Status__c);
        Assert.areEqual(1000000, r.Amount, 'Amount stays in BDT');

        Opportunity_Currency_Update__c t = [
            SELECT Expected_Currency_Type__c, Previous_Currency_Type__c, Previous_Expected_Amount__c, New_Expected_Amount__c
            FROM Opportunity_Currency_Update__c WHERE Opportunity__c = :r.Id
        ];
        Assert.areEqual('EUR', t.Expected_Currency_Type__c);
        Assert.areEqual('USD', t.Previous_Currency_Type__c);
        Assert.areEqual(8200, t.Previous_Expected_Amount__c);
        Assert.areEqual(7000, t.New_Expected_Amount__c);
    }

    @isTest
    static void amountChange_recalculatesExpectedAmount() {
        Opportunity seed = CurrencyTestDataFactory.buildConverted('TR-AMT', 1000000, 'USD', 'USD', 8200, 0.0082, 'Success');
        insert seed;
        mockDefaultRates();

        Test.startTest();
        seed.Amount = 2000000;
        update seed;
        Test.stopTest();

        Opportunity r = CurrencyTestDataFactory.getByName('TR-AMT');
        Assert.areEqual(16400.00, r.Expected_Currency_Amount__c);
        Assert.areEqual(2000000, r.Amount);
        Assert.areEqual('Success', r.Currency_Update_Status__c);
    }

    @isTest
    static void unrelatedFieldChange_doesNotTriggerConversion() {
        Opportunity seed = CurrencyTestDataFactory.buildConverted('TR-NAME', 1000000, 'USD', 'USD', 8200, 0.0082, 'Success');
        insert seed;
        mockDefaultRates();

        Test.startTest();
        seed.Name = 'TR-NAME renamed';
        update seed;
        Test.stopTest();

        Assert.areEqual(0, ExchangeRateApiMock.callCount);
        Opportunity r = [SELECT Currency_Update_Status__c, Expected_Currency_Amount__c FROM Opportunity WHERE Id = :seed.Id];
        Assert.areEqual('Success', r.Currency_Update_Status__c);
        Assert.areEqual(8200, r.Expected_Currency_Amount__c);
    }

    @isTest
    static void clearingCurrency_doesNotTriggerConversion() {
        Opportunity seed = CurrencyTestDataFactory.buildConverted('TR-CLEAR', 1000000, 'USD', 'USD', 8200, 0.0082, 'Success');
        insert seed;
        mockDefaultRates();

        Test.startTest();
        seed.Expected_Currency_Type__c = null;
        update seed;
        Test.stopTest();

        Assert.areEqual(0, ExchangeRateApiMock.callCount);
        Assert.areEqual('Success', [SELECT Currency_Update_Status__c FROM Opportunity WHERE Id = :seed.Id].Currency_Update_Status__c);
    }

    @isTest
    static void userSetsFailedBackToPending_reprocessesAutomatically() {
        Opportunity seed = CurrencyTestDataFactory.buildConverted('TR-REPROCESS', 1000000, 'USD', null, null, null, 'Failed');
        seed.Currency_Error_Message__c = 'HTTP 500: ExchangeRate-API server error (server-error).';
        insert seed;
        mockDefaultRates();

        Test.startTest();
        seed.Currency_Update_Status__c = 'Pending';
        update seed;
        Test.stopTest();

        Opportunity r = CurrencyTestDataFactory.getByName('TR-REPROCESS');
        Assert.areEqual('Success', r.Currency_Update_Status__c);
        Assert.areEqual(8200.00, r.Expected_Currency_Amount__c);
        Assert.isNull(r.Currency_Error_Message__c);
    }

    @isTest
    static void autoProcessingDisabled_leavesRecordsPending() {
        CurrencyTestDataFactory.disableAutoProcessing();
        mockDefaultRates();

        Test.startTest();
        insert CurrencyTestDataFactory.build('TR-OFF', 1000000, 'USD');
        Test.stopTest();

        Assert.areEqual('Pending', CurrencyTestDataFactory.getByName('TR-OFF').Currency_Update_Status__c);
        Assert.areEqual(0, ExchangeRateApiMock.callCount);
    }

    @isTest
    static void bulkInsert_200Records_mixedCurrencies_oneCallPerCurrency() {
        Map<String, Decimal> rates = ExchangeRateApiMock.defaultRates();
        List<String> codes = new List<String>(rates.keySet());
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(CurrencyTestDataFactory.build('TR-BULK-' + i, 250000 + (i * 500), codes[Math.mod(i, codes.size())]));
        }
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(rates));

        Test.startTest();
        insert opps;
        Test.stopTest();

        Assert.areEqual(6, ExchangeRateApiMock.callCount, '200 Opportunities across 6 currencies -> 6 callouts');
        Assert.areEqual(200, [SELECT COUNT() FROM Opportunity WHERE Name LIKE 'TR-BULK-%' AND Currency_Update_Status__c = 'Success']);
        Assert.areEqual(200, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
        Assert.areEqual(6, [SELECT COUNT() FROM Exchange_Rate_History__c]);
        for (Opportunity o : [SELECT Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c FROM Opportunity WHERE Name LIKE 'TR-BULK-%']) {
            Decimal expected = (o.Amount * rates.get(o.Expected_Currency_Type__c)).setScale(2, RoundingMode.HALF_UP);
            Assert.areEqual(expected, o.Expected_Currency_Amount__c);
        }
    }

    @isTest
    static void bulkInsert_moreThan200_startsBatchInsteadOfQueueable() {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 201; i++) {
            opps.add(CurrencyTestDataFactory.build('TR-BIG-' + i, 100000, 'USD'));
        }
        mockDefaultRates();

        Test.startTest();
        insert opps;
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex' AND ApexClass.Name = 'CurrencyConversionBatch']);
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND ApexClass.Name = 'CurrencyConversionQueueable']);
        // a test-context batch runs a single chunk (max 200 records)
        Assert.areEqual(200, [SELECT COUNT() FROM Opportunity WHERE Name LIKE 'TR-BIG-%' AND Currency_Update_Status__c = 'Success']);
    }

    @isTest
    static void queueable_withDeletedRecord_endsCleanly() {
        CurrencyTestDataFactory.disableAutoProcessing();
        Opportunity opp = CurrencyTestDataFactory.build('TR-QFAIL', 1000000, 'USD');
        insert opp;
        mockDefaultRates();

        Test.startTest();
        // Edge case: the Opportunity is deleted between enqueue and execution -> nothing to
        // process, so the job must end cleanly and leave no half-written data behind.
        Id oppId = opp.Id;
        delete opp;
        System.enqueueJob(new CurrencyConversionQueueable(new List<Id>{ oppId }));
        Test.stopTest();

        Assert.areEqual(0, ExchangeRateApiMock.callCount);
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
    }
}
