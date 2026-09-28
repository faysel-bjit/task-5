/**
 * Trigger logic (kept out of the trigger for testability).
 *
 * BEFORE: normalises Expected Currency Type (trim + upper case) and stamps status = Pending when a
 *         conversion is needed (new record with a currency, currency changed, Amount changed, or a user
 *         manually sets the status back to Pending to reprocess).
 * AFTER : hands the Pending records to a Queueable (<= 200) or a Batch (> 200). Callouts are not
 *         allowed in triggers, hence the async hand-off.
 *
 * Auto-processing can be switched off (e.g. before a mass data load) with the custom metadata record
 * Currency_Conversion_Setting.Default -> Auto_Process_Enabled__c = false. Pending records are then
 * picked up by CurrencyConversionBatch('RETRY').
 */
public with sharing class OpportunityCurrencyTriggerHandler {

    @TestVisible private static Boolean autoProcessDisabledForTest = false;
    private static final Integer QUEUEABLE_MAX_IDS = 200;
    private static final String PENDING = CurrencyConversionService.STATUS_PENDING;

    public static void beforeInsert(List<Opportunity> newOpps) {
        for (Opportunity opp : newOpps) {
            opp.Expected_Currency_Type__c = normalize(opp.Expected_Currency_Type__c);
            if (opp.Expected_Currency_Type__c != null && String.isBlank(opp.Currency_Update_Status__c)) {
                opp.Currency_Update_Status__c = PENDING;
            }
        }
    }

    public static void beforeUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            opp.Expected_Currency_Type__c = normalize(opp.Expected_Currency_Type__c);
            if (opp.Expected_Currency_Type__c == null) { continue; }

            Boolean requeuedByUser = opp.Currency_Update_Status__c == PENDING && oldOpp.Currency_Update_Status__c != PENDING;
            if (currencyChanged(opp, oldOpp) || amountChanged(opp, oldOpp) || requeuedByUser) {
                opp.Currency_Update_Status__c = PENDING;
                opp.Currency_Error_Message__c = null;
            }
        }
    }

    public static void afterInsert(List<Opportunity> newOpps) {
        List<Id> ids = new List<Id>();
        for (Opportunity opp : newOpps) {
            if (opp.Currency_Update_Status__c == PENDING && opp.Expected_Currency_Type__c != null) { ids.add(opp.Id); }
        }
        dispatch(ids);
    }

    public static void afterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        List<Id> ids = new List<Id>();
        for (Opportunity opp : newOpps) {
            Opportunity oldOpp = oldMap.get(opp.Id);
            if (opp.Currency_Update_Status__c == PENDING && opp.Expected_Currency_Type__c != null
                && (oldOpp.Currency_Update_Status__c != PENDING || currencyChanged(opp, oldOpp) || amountChanged(opp, oldOpp))) {
                ids.add(opp.Id);
            }
        }
        dispatch(ids);
    }

    private static void dispatch(List<Id> ids) {
        if (ids.isEmpty() || !isAutoProcessEnabled()) { return; }
        // Not allowed / not useful to start more async work from these contexts;
        // the records stay Pending and are picked up by the RETRY batch.
        if (System.isBatch() || System.isQueueable() || System.isFuture()) { return; }

        try {
            if (ids.size() <= QUEUEABLE_MAX_IDS) {
                if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                    System.enqueueJob(new CurrencyConversionQueueable(ids));
                }
            } else {
                Database.executeBatch(new CurrencyConversionBatch(new Set<Id>(ids)), CurrencyConversionBatch.DEFAULT_SCOPE);
            }
        } catch (AsyncException e) {
            System.debug(LoggingLevel.WARN, 'Could not start currency conversion job; records stay Pending: ' + e.getMessage());
        }
    }

    private static Boolean isAutoProcessEnabled() {
        if (autoProcessDisabledForTest) { return false; }
        Currency_Conversion_Setting__mdt setting = Currency_Conversion_Setting__mdt.getInstance('Default');
        return setting == null || setting.Auto_Process_Enabled__c == true;
    }

    private static Boolean currencyChanged(Opportunity newOpp, Opportunity oldOpp) {
        return normalize(newOpp.Expected_Currency_Type__c) != normalize(oldOpp.Expected_Currency_Type__c);
    }

    private static Boolean amountChanged(Opportunity newOpp, Opportunity oldOpp) {
        return newOpp.Amount != oldOpp.Amount;
    }

    private static String normalize(String raw) {
        return String.isBlank(raw) ? null : raw.trim().toUpperCase();
    }
}
