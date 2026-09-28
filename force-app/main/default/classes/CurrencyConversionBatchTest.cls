@isTest
private class CurrencyConversionBatchTest {

    private static final Datetime OLD_TIMESTAMP = Datetime.newInstance(2026, 1, 1, 0, 0, 0);

    @TestSetup
    static void setup() {
        CurrencyTestDataFactory.disableAutoProcessing();
        insert new List<Opportunity>{
            CurrencyTestDataFactory.buildConverted('B-FAILED', 1000000, 'USD', null, null, null, 'Failed'),
            CurrencyTestDataFactory.buildConverted('B-PENDING', 800000, 'EUR', null, null, null, 'Pending'),
            CurrencyTestDataFactory.buildConverted('B-DONE', 1000000, 'USD', 'USD', 8200, 0.0082, 'Success'),
            CurrencyTestDataFactory.build('B-NOTYPE', 100000, null)
        };
        Opportunity failed = CurrencyTestDataFactory.getByName('B-FAILED');
        failed.Currency_Error_Message__c = 'HTTP 500: ExchangeRate-API server error (server-error).';
        update failed;
    }

    @isTest
    static void retryMode_reprocessesFailedAndPending_butNotSuccessful() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(new Map<String, Decimal>{ 'USD' => 0.0090, 'EUR' => 0.0075 }));

        Test.startTest();
        CurrencyConversionBatch.run('RETRY');
        Test.stopTest();

        Opportunity failed = CurrencyTestDataFactory.getByName('B-FAILED');
        Assert.areEqual('Success', failed.Currency_Update_Status__c, 'Failed record is reprocessed once the root cause is fixed');
        Assert.areEqual(9000.00, failed.Expected_Currency_Amount__c);
        Assert.isNull(failed.Currency_Error_Message__c, 'Old error is cleared on success');

        Opportunity pending = CurrencyTestDataFactory.getByName('B-PENDING');
        Assert.areEqual('Success', pending.Currency_Update_Status__c);
        Assert.areEqual(6000.00, pending.Expected_Currency_Amount__c, '800,000 x 0.0075');

        Opportunity done = CurrencyTestDataFactory.getByName('B-DONE');
        Assert.areEqual(8200.00, done.Expected_Currency_Amount__c, 'Already-successful record untouched in RETRY mode');
        Assert.areEqual(0.0082, done.Exchange_Rate__c);
        Assert.areEqual(OLD_TIMESTAMP, done.Currency_Last_Updated__c);

        Opportunity noType = CurrencyTestDataFactory.getByName('B-NOTYPE');
        Assert.isNull(noType.Currency_Update_Status__c, 'Blank currency type is never picked up');

        Assert.areEqual(2, ExchangeRateApiMock.callCount, 'USD (shared by 2 records) + EUR = 2 calls');
        Assert.areEqual(2, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
    }

    @isTest
    static void refreshMode_reappliesLatestRate_toSuccessfulRecords() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(new Map<String, Decimal>{ 'USD' => 0.0090, 'EUR' => 0.0075 }));

        Test.startTest();
        CurrencyConversionBatch.run('REFRESH');
        Test.stopTest();

        Opportunity done = CurrencyTestDataFactory.getByName('B-DONE');
        Assert.areEqual(9000.00, done.Expected_Currency_Amount__c, 'Refreshed with the latest USD rate');
        Assert.areEqual(0.0090, done.Exchange_Rate__c);
        Assert.isTrue(done.Currency_Last_Updated__c > OLD_TIMESTAMP);
        Opportunity_Currency_Update__c t = [
            SELECT Previous_Expected_Amount__c, New_Expected_Amount__c, Exchange_Rate_Used__c
            FROM Opportunity_Currency_Update__c WHERE Opportunity__c = :done.Id
        ];
        Assert.areEqual(8200, t.Previous_Expected_Amount__c, 'Tracking shows how the value changed');
        Assert.areEqual(9000, t.New_Expected_Amount__c);
        Assert.areEqual(0.0090, t.Exchange_Rate_Used__c);
        Assert.areEqual(3, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
        Assert.areEqual(2, ExchangeRateApiMock.callCount);
    }

    @isTest
    static void retryMode_apiStillDown_keepsRecordsFailed_andNeverOverwritesValues() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withResponse(500, 'down'));

        Test.startTest();
        CurrencyConversionBatch.run('RETRY');
        Test.stopTest();

        Opportunity failed = CurrencyTestDataFactory.getByName('B-FAILED');
        Assert.areEqual('Failed', failed.Currency_Update_Status__c);
        Assert.isNull(failed.Expected_Currency_Amount__c);
        Assert.isTrue(failed.Currency_Error_Message__c.contains('HTTP 500'));
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity_Currency_Update__c]);
        Assert.areEqual(2, [SELECT COUNT() FROM Exchange_Rate_History__c WHERE API_Status__c = 'Failed']);
    }

    @isTest
    static void idsMode_processesOnlyTheGivenRecords() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));
        Opportunity pending = CurrencyTestDataFactory.getByName('B-PENDING');

        Test.startTest();
        Database.executeBatch(new CurrencyConversionBatch(new Set<Id>{ pending.Id }), 200);
        Test.stopTest();

        Assert.areEqual('Success', CurrencyTestDataFactory.getByName('B-PENDING').Currency_Update_Status__c);
        Assert.areEqual('Failed', CurrencyTestDataFactory.getByName('B-FAILED').Currency_Update_Status__c);
        Assert.areEqual(1, ExchangeRateApiMock.callCount);
    }

    @isTest
    static void bulk_200Records_sixCurrencies_sixApiCalls() {
        CurrencyTestDataFactory.disableAutoProcessing();
        Map<String, Decimal> rates = ExchangeRateApiMock.defaultRates();
        List<String> codes = new List<String>(rates.keySet());
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(CurrencyTestDataFactory.build('BULK-' + i, 100000 + (i * 1000), codes[Math.mod(i, codes.size())]));
        }
        insert opps;
        Set<Id> ids = new Map<Id, Opportunity>(opps).keySet();
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(rates));

        Test.startTest();
        Database.executeBatch(new CurrencyConversionBatch(ids), 200);
        Test.stopTest();

        Assert.areEqual(6, ExchangeRateApiMock.callCount, '200 Opportunities, 6 currencies -> 6 callouts');
        Assert.areEqual(200, [SELECT COUNT() FROM Opportunity WHERE Id IN :ids AND Currency_Update_Status__c = 'Success']);
        Assert.areEqual(200, [SELECT COUNT() FROM Opportunity_Currency_Update__c WHERE Opportunity__c IN :ids]);
        Assert.areEqual(6, [SELECT COUNT() FROM Exchange_Rate_History__c WHERE API_Status__c = 'Success']);
        for (Opportunity o : [SELECT Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c FROM Opportunity WHERE Id IN :ids]) {
            Decimal expected = (o.Amount * rates.get(o.Expected_Currency_Type__c)).setScale(2, RoundingMode.HALF_UP);
            Assert.areEqual(expected, o.Expected_Currency_Amount__c, 'Wrong amount for ' + o.Expected_Currency_Type__c);
        }
    }

    @isTest
    static void statefulRateCache_acrossExecuteChunks() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));
        Opportunity failed = CurrencyTestDataFactory.getByName('B-FAILED');   // USD
        Opportunity done = CurrencyTestDataFactory.getByName('B-DONE');       // USD

        CurrencyConversionBatch batch = new CurrencyConversionBatch('RETRY');
        batch.execute(null, new List<Opportunity>{ failed });   // chunk 1
        batch.execute(null, new List<Opportunity>{ done });     // chunk 2

        Assert.areEqual(1, ExchangeRateApiMock.callCount, 'USD fetched once for the whole run');
        Assert.areEqual(2, batch.getSummary().success);
        Assert.areEqual(1, batch.getSummary().apiCalls);
    }

    @isTest
    static void finish_and_start_run_for_every_mode() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));
        Test.startTest();
        Id jobId = CurrencyConversionBatch.run('RETRY');
        Test.stopTest();
        Assert.isNotNull(jobId);
        Assert.areEqual('Completed', [SELECT Status FROM AsyncApexJob WHERE Id = :jobId].Status);
    }

    @isTest
    static void invalidMode_isRejected() {
        try {
            new CurrencyConversionBatch('NOPE');
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('NOPE'));
        }
    }
}
