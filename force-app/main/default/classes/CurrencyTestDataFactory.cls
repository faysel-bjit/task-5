@isTest
public class CurrencyTestDataFactory {

    /** Stops the trigger from starting async jobs (used when a test calls the service/batch itself). */
    public static void disableAutoProcessing() {
        OpportunityCurrencyTriggerHandler.autoProcessDisabledForTest = true;
    }

    public static Opportunity build(String name, Decimal amount, String currencyCode) {
        return new Opportunity(
            Name = name, StageName = 'Prospecting', CloseDate = Date.today().addDays(30),
            Amount = amount, Expected_Currency_Type__c = currencyCode
        );
    }

    /** An Opportunity that already carries an earlier conversion result. */
    public static Opportunity buildConverted(String name, Decimal amount, String currencyCode,
                                             String lastConvertedCurrency, Decimal previousAmount,
                                             Decimal previousRate, String status) {
        Opportunity o = build(name, amount, currencyCode);
        o.Expected_Currency_Amount__c = previousAmount;
        o.Exchange_Rate__c = previousRate;
        o.Last_Converted_Currency__c = lastConvertedCurrency;
        o.Currency_Last_Updated__c = Datetime.newInstance(2026, 1, 1, 0, 0, 0);
        o.Currency_Update_Status__c = status;
        return o;
    }

    public static Opportunity getByName(String name) {
        return [
            SELECT Id, Name, Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c, Exchange_Rate__c,
                   Currency_Last_Updated__c, Currency_Update_Status__c, Currency_Error_Message__c,
                   Last_Converted_Currency__c
            FROM Opportunity WHERE Name = :name LIMIT 1
        ];
    }

    public static List<Opportunity> getByNames(Set<String> names) {
        return [
            SELECT Id, Name, Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c, Exchange_Rate__c,
                   Currency_Last_Updated__c, Currency_Update_Status__c, Currency_Error_Message__c,
                   Last_Converted_Currency__c
            FROM Opportunity WHERE Name IN :names
        ];
    }
}
