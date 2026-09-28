/**
 * Bulk processing / reprocessing of Opportunity currency conversions.
 *
 * Modes
 *   RETRY   - Opportunities with a currency type whose status is Pending, Failed or blank (default)
 *   REFRESH - every Opportunity that has a currency type (re-applies the latest exchange rate)
 *   IDS     - an explicit set of Opportunity Ids (used by the trigger for > 200 records)
 *
 * The ProcessingContext is Stateful, so each currency is fetched from the API only ONCE for
 * the whole run, no matter how many chunks the run is split into.
 *
 * Run:  CurrencyConversionBatch.run('RETRY');
 */
public with sharing class CurrencyConversionBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {

    public static final String MODE_RETRY = 'RETRY';
    public static final String MODE_REFRESH = 'REFRESH';
    public static final String MODE_IDS = 'IDS';
    public static final Integer DEFAULT_SCOPE = 200;

    private String mode;
    private Set<Id> recordIds;
    private CurrencyConversionService.ProcessingContext ctx = new CurrencyConversionService.ProcessingContext();
    private CurrencyConversionService.ProcessingSummary summary = new CurrencyConversionService.ProcessingSummary();

    public CurrencyConversionBatch() {
        this(MODE_RETRY);
    }

    public CurrencyConversionBatch(String mode) {
        if (mode != MODE_RETRY && mode != MODE_REFRESH) {
            throw new IllegalArgumentException('Unknown mode "' + mode + '". Use RETRY or REFRESH.');
        }
        this.mode = mode;
    }

    public CurrencyConversionBatch(Set<Id> opportunityIds) {
        this.mode = MODE_IDS;
        this.recordIds = opportunityIds;
    }

    public static Id run(String mode) {
        return Database.executeBatch(new CurrencyConversionBatch(mode), DEFAULT_SCOPE);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (mode == MODE_IDS) {
            return Database.getQueryLocator([
                SELECT Id, Name, Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c,
                       Exchange_Rate__c, Currency_Update_Status__c, Last_Converted_Currency__c
                FROM Opportunity
                WHERE Id IN :recordIds AND Expected_Currency_Type__c != null
                ORDER BY Expected_Currency_Type__c
            ]);
        }
        if (mode == MODE_REFRESH) {
            return Database.getQueryLocator([
                SELECT Id, Name, Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c,
                       Exchange_Rate__c, Currency_Update_Status__c, Last_Converted_Currency__c
                FROM Opportunity
                WHERE Expected_Currency_Type__c != null
                ORDER BY Expected_Currency_Type__c
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Name, Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c,
                   Exchange_Rate__c, Currency_Update_Status__c, Last_Converted_Currency__c
            FROM Opportunity
            WHERE Expected_Currency_Type__c != null
              AND (Currency_Update_Status__c IN ('Pending', 'Failed') OR Currency_Update_Status__c = null)
            ORDER BY Expected_Currency_Type__c
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Opportunity> opps = (List<Opportunity>) scope;
        try {
            summary.add(CurrencyConversionService.processOpportunities(opps, ctx));
        } catch (Exception e) {
            summary.failed += opps.size();
            summary.errors.add(e.getMessage());
            CurrencyConversionService.markFailed(new Map<Id, Opportunity>(opps).keySet(),
                'Unexpected error while processing currency conversion: ' + e.getMessage());
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'CurrencyConversionBatch finished. mode=' + mode
            + ' success=' + summary.success + ' failed=' + summary.failed + ' skipped=' + summary.skipped
            + ' apiCalls=' + summary.apiCalls + ' dmlErrors=' + summary.dmlErrors);
    }

    @TestVisible
    private CurrencyConversionService.ProcessingSummary getSummary() {
        return summary;
    }
}
