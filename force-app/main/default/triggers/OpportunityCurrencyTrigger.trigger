trigger OpportunityCurrencyTrigger on Opportunity (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            OpportunityCurrencyTriggerHandler.beforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            OpportunityCurrencyTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
        }
    } else {
        if (Trigger.isInsert) {
            OpportunityCurrencyTriggerHandler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            OpportunityCurrencyTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}
