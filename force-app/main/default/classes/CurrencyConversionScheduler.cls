/**
 * Optional scheduled reprocessing.
 *   System.schedule('Currency retry',   '0 0 * * * ?', new CurrencyConversionScheduler('RETRY'));   // hourly
 *   System.schedule('Currency refresh', '0 0 2 * * ?', new CurrencyConversionScheduler('REFRESH')); // nightly
 */
public with sharing class CurrencyConversionScheduler implements Schedulable {

    private String mode;

    public CurrencyConversionScheduler() {
        this(CurrencyConversionBatch.MODE_RETRY);
    }

    public CurrencyConversionScheduler(String mode) {
        this.mode = mode;
    }

    public void execute(SchedulableContext sc) {
        CurrencyConversionBatch.run(mode);
    }
}
