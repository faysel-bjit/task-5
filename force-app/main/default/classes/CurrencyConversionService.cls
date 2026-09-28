/**
 * Core business logic: BDT -> expected currency conversion for Opportunities.
 *
 * Flow of processOpportunities():
 *   1. Validate + group Opportunities by target currency (no callouts yet).
 *   2. ONE callout per distinct currency (rates are cached in the ProcessingContext, so a
 *      Batch run re-uses them across chunks).  All callouts happen BEFORE any DML.
 *   3. Insert Exchange_Rate_History__c (one row per API call, success or failure).
 *   4. Update Opportunities.  Failures only set status/error - previously valid values are kept.
 *   5. Insert Opportunity_Currency_Update__c for every successful conversion.
 *
 * Opportunity.Amount is never written by this class.
 */
public with sharing class CurrencyConversionService {

    public static final String STATUS_PENDING = 'Pending';
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_FAILED  = 'Failed';

    private static final Pattern CURRENCY_CODE = Pattern.compile('^[A-Z]{3}$');
    private static final Integer TEXT_AREA_MAX = 32000;

    /** State shared by all chunks of one processing run (Batch keeps it via Database.Stateful). */
    public class ProcessingContext {
        public Map<String, ExchangeRateApiClient.RateResult> rates = new Map<String, ExchangeRateApiClient.RateResult>();
        public Map<String, Id> historyIds = new Map<String, Id>();
        public ExchangeRateApiClient.RateResult haltedBy;
        public Integer apiCalls = 0;
    }

    public class ProcessingSummary {
        public Integer success = 0;
        public Integer failed = 0;
        public Integer skipped = 0;
        public Integer apiCalls = 0;
        public Integer dmlErrors = 0;
        public List<String> errors = new List<String>();

        public void add(ProcessingSummary other) {
            success += other.success;
            failed += other.failed;
            skipped += other.skipped;
            apiCalls += other.apiCalls;
            dmlErrors += other.dmlErrors;
            for (String e : other.errors) {
                if (errors.size() < 20) { errors.add(e); }
            }
        }
    }

    public static ProcessingSummary processOpportunityIds(Set<Id> opportunityIds, ProcessingContext ctx) {
        List<Opportunity> opps = [
            SELECT Id, Name, Amount, Expected_Currency_Type__c, Expected_Currency_Amount__c,
                   Exchange_Rate__c, Currency_Update_Status__c, Last_Converted_Currency__c
            FROM Opportunity WHERE Id IN :opportunityIds
        ];
        return processOpportunities(opps, ctx);
    }

    public static ProcessingSummary processOpportunities(List<Opportunity> opportunities, ProcessingContext ctx) {
        ProcessingSummary summary = new ProcessingSummary();
        if (opportunities == null || opportunities.isEmpty()) { return summary; }
        if (ctx == null) { ctx = new ProcessingContext(); }
        String baseCurrency = ExchangeRateApiClient.BASE_CURRENCY;

        // ---- 1. validate + group (no callouts, no DML) ---------------------------------------
        Map<String, List<Opportunity>> oppsByCurrency = new Map<String, List<Opportunity>>();
        Map<Id, String> preFailures = new Map<Id, String>();

        for (Opportunity opp : opportunities) {
            String code = normalizeCode(opp.Expected_Currency_Type__c);
            if (code == null) {                       // blank type -> skip, nothing to convert
                summary.skipped++;
                continue;
            }
            if (!CURRENCY_CODE.matcher(code).matches()) {
                preFailures.put(opp.Id, 'Invalid currency code "' + code
                    + '". Expected a 3-letter ISO 4217 code such as USD, EUR or JPY.');
                continue;
            }
            if (opp.Amount == null) {
                preFailures.put(opp.Id, 'Opportunity Amount is blank, so there is nothing to convert.');
                continue;
            }
            if (!oppsByCurrency.containsKey(code)) { oppsByCurrency.put(code, new List<Opportunity>()); }
            oppsByCurrency.get(code).add(opp);
        }

        // ---- 2. one callout per distinct currency, all before any DML -------------------------
        Map<String, ExchangeRateApiClient.RateResult> uncached = new Map<String, ExchangeRateApiClient.RateResult>();
        List<ExchangeRateApiClient.RateResult> freshlyFetched = new List<ExchangeRateApiClient.RateResult>();

        for (String code : oppsByCurrency.keySet()) {
            if (ctx.rates.containsKey(code)) { continue; }          // already retrieved in this run
            if (ctx.haltedBy != null) {
                ctx.rates.put(code, ExchangeRateApiClient.notAttempted(baseCurrency, code, ctx.haltedBy.errorType,
                    'Not attempted - an earlier request in this run failed: ' + ctx.haltedBy.errorMessage));
            } else if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
                uncached.put(code, ExchangeRateApiClient.notAttempted(baseCurrency, code, 'callout-limit',
                    'Callout limit reached in this transaction (callout-limit). Reprocess to retry.'));
            } else {
                ExchangeRateApiClient.RateResult res = ExchangeRateApiClient.fetchRate(baseCurrency, code);
                ctx.apiCalls++;
                summary.apiCalls++;
                ctx.rates.put(code, res);
                freshlyFetched.add(res);
                if (res.isHaltingError()) { ctx.haltedBy = res; }
            }
        }

        // ---- 3. exchange-rate history (one row per API call) ----------------------------------
        if (!freshlyFetched.isEmpty()) {
            List<Exchange_Rate_History__c> histories = new List<Exchange_Rate_History__c>();
            for (ExchangeRateApiClient.RateResult res : freshlyFetched) { histories.add(toHistory(res)); }
            List<Database.SaveResult> hResults = Database.insert(histories, false);
            for (Integer i = 0; i < histories.size(); i++) {
                if (hResults[i].isSuccess()) {
                    ctx.historyIds.put(freshlyFetched[i].targetCurrency, histories[i].Id);
                } else {
                    recordDmlError(summary, 'Exchange_Rate_History__c', hResults[i]);
                }
            }
        }

        // ---- 4. build Opportunity updates + tracking rows -------------------------------------
        List<Opportunity> updates = new List<Opportunity>();
        Map<Id, Opportunity_Currency_Update__c> trackingByOppId = new Map<Id, Opportunity_Currency_Update__c>();
        Datetime now = Datetime.now();

        for (Opportunity opp : opportunities) {
            if (preFailures.containsKey(opp.Id)) {
                updates.add(failedUpdate(opp.Id, preFailures.get(opp.Id)));
                continue;
            }
            String code = normalizeCode(opp.Expected_Currency_Type__c);
            if (code == null) { continue; }

            ExchangeRateApiClient.RateResult res = ctx.rates.containsKey(code) ? ctx.rates.get(code) : uncached.get(code);
            if (res != null && res.success) {
                Decimal newAmount = (opp.Amount * res.rate).setScale(2, RoundingMode.HALF_UP);
                updates.add(new Opportunity(
                    Id = opp.Id,
                    Expected_Currency_Amount__c = newAmount,
                    Exchange_Rate__c = res.rate,
                    Currency_Last_Updated__c = now,
                    Currency_Update_Status__c = STATUS_SUCCESS,
                    Currency_Error_Message__c = null,
                    Last_Converted_Currency__c = code
                ));
                trackingByOppId.put(opp.Id, new Opportunity_Currency_Update__c(
                    Opportunity__c = opp.Id,
                    Opportunity_Amount_BDT__c = opp.Amount,
                    Expected_Currency_Type__c = code,
                    Previous_Currency_Type__c = opp.Last_Converted_Currency__c,
                    Exchange_Rate_Used__c = res.rate,
                    Previous_Expected_Amount__c = opp.Expected_Currency_Amount__c,
                    New_Expected_Amount__c = newAmount,
                    Updated_At__c = now,
                    Exchange_Rate_History__c = ctx.historyIds.get(code)
                ));
            } else {
                String message = baseCurrency + ' -> ' + code + ': '
                    + (res == null ? 'no exchange rate available.' : res.errorMessage);
                updates.add(failedUpdate(opp.Id, message));
            }
        }

        // ---- 5. DML: Opportunities first, then tracking for the ones that really updated -----
        if (!updates.isEmpty()) {
            List<Database.SaveResult> oResults = Database.update(updates, false);
            List<Opportunity_Currency_Update__c> trackingToInsert = new List<Opportunity_Currency_Update__c>();
            for (Integer i = 0; i < updates.size(); i++) {
                if (oResults[i].isSuccess()) {
                    if (updates[i].Currency_Update_Status__c == STATUS_SUCCESS) {
                        summary.success++;
                        trackingToInsert.add(trackingByOppId.get(updates[i].Id));
                    } else {
                        summary.failed++;
                    }
                } else {
                    recordDmlError(summary, 'Opportunity ' + updates[i].Id, oResults[i]);
                }
            }
            if (!trackingToInsert.isEmpty()) {
                List<Database.SaveResult> tResults = Database.insert(trackingToInsert, false);
                for (Database.SaveResult sr : tResults) {
                    if (!sr.isSuccess()) { recordDmlError(summary, 'Opportunity_Currency_Update__c', sr); }
                }
            }
        }
        return summary;
    }

    /**
     * Last-resort handler used by the async wrappers when an unexpected exception escapes.
     * Marks not-yet-successful Opportunities as Failed; never touches converted values.
     */
    public static void markFailed(Set<Id> opportunityIds, String message) {
        List<Opportunity> toUpdate = new List<Opportunity>();
        for (Opportunity o : [
            SELECT Id FROM Opportunity
            WHERE Id IN :opportunityIds AND (Currency_Update_Status__c != :STATUS_SUCCESS OR Currency_Update_Status__c = null)
        ]) {
            toUpdate.add(failedUpdate(o.Id, message));
        }
        if (!toUpdate.isEmpty()) { Database.update(toUpdate, false); }
    }

    // ------------------------------------------------------------------------------------------
    private static Opportunity failedUpdate(Id oppId, String message) {
        return new Opportunity(
            Id = oppId,
            Currency_Update_Status__c = STATUS_FAILED,
            Currency_Error_Message__c = truncate(message)
        );
    }

    private static Exchange_Rate_History__c toHistory(ExchangeRateApiClient.RateResult res) {
        return new Exchange_Rate_History__c(
            Base_Currency__c = res.baseCurrency,
            Target_Currency__c = res.targetCurrency,
            Exchange_Rate__c = res.success ? res.rate : null,
            Retrieved_At__c = res.retrievedAt,
            API_Status__c = res.success ? 'Success' : 'Failed',
            Error_Details__c = res.success ? null : truncate(res.errorMessage),
            Http_Status_Code__c = res.statusCode
        );
    }

    private static void recordDmlError(ProcessingSummary summary, String what, Database.SaveResult sr) {
        summary.dmlErrors++;
        if (summary.errors.size() < 20 && !sr.getErrors().isEmpty()) {
            summary.errors.add(what + ': ' + sr.getErrors()[0].getMessage());
        }
    }

    @TestVisible
    private static String normalizeCode(String raw) {
        return String.isBlank(raw) ? null : raw.trim().toUpperCase();
    }

    private static String truncate(String text) {
        if (text == null) { return null; }
        return text.length() > TEXT_AREA_MAX ? text.left(TEXT_AREA_MAX) : text;
    }
}
