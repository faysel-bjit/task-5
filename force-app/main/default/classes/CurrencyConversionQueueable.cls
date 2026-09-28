/** Processes a small set (<= 200) of Opportunities asynchronously after a trigger event. */
public with sharing class CurrencyConversionQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> opportunityIds;

    public CurrencyConversionQueueable(List<Id> opportunityIds) {
        this.opportunityIds = opportunityIds;
    }

    public void execute(QueueableContext qc) {
        Set<Id> ids = new Set<Id>(opportunityIds);
        try {
            CurrencyConversionService.processOpportunityIds(ids, new CurrencyConversionService.ProcessingContext());
        } catch (Exception e) {
            CurrencyConversionService.markFailed(ids, 'Unexpected error while processing currency conversion: ' + e.getMessage());
        }
    }
}
