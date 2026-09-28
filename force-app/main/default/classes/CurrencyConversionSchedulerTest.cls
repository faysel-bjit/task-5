@isTest
private class CurrencyConversionSchedulerTest {

    @TestSetup
    static void setup() {
        CurrencyTestDataFactory.disableAutoProcessing();
        insert CurrencyTestDataFactory.buildConverted('S-FAILED', 1000000, 'USD', null, null, null, 'Failed');
    }

    @isTest
    static void scheduledRun_startsRetryBatch_andReprocessesFailedRecords() {
        Test.setMock(HttpCalloutMock.class, ExchangeRateApiMock.withRates(ExchangeRateApiMock.defaultRates()));

        Test.startTest();
        new CurrencyConversionScheduler().execute(null);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex' AND ApexClass.Name = 'CurrencyConversionBatch']);
        Opportunity r = CurrencyTestDataFactory.getByName('S-FAILED');
        Assert.areEqual('Success', r.Currency_Update_Status__c);
        Assert.areEqual(8200.00, r.Expected_Currency_Amount__c);
    }

    @isTest
    static void canBeScheduled() {
        Test.startTest();
        Id jobId = System.schedule('Currency refresh test', '0 0 2 * * ?', new CurrencyConversionScheduler('REFRESH'));
        Test.stopTest();
        Assert.areEqual('WAITING', [SELECT State FROM CronTrigger WHERE Id = :jobId].State);
    }
}
