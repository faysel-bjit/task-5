/** Test double for ExchangeRate-API. No real callout is ever made in tests. */
@isTest
public class ExchangeRateApiMock implements HttpCalloutMock {

    public static Integer callCount = 0;
    public static List<String> endpoints = new List<String>();

    private Map<String, Decimal> rates;
    private Integer fixedStatus;
    private String fixedBody;
    private Boolean throwException = false;

    private ExchangeRateApiMock() {}

    /** Realistic-looking BDT rates. Any other currency answers with "unsupported-code". */
    public static Map<String, Decimal> defaultRates() {
        return new Map<String, Decimal>{
            'USD' => 0.0082, 'EUR' => 0.0070, 'JPY' => 1.25,
            'GBP' => 0.0061, 'AUD' => 0.0125, 'CAD' => 0.0112
        };
    }

    public static ExchangeRateApiMock withRates(Map<String, Decimal> rates) {
        ExchangeRateApiMock m = new ExchangeRateApiMock();
        m.rates = rates;
        return m;
    }

    public static ExchangeRateApiMock withResponse(Integer status, String body) {
        ExchangeRateApiMock m = new ExchangeRateApiMock();
        m.fixedStatus = status;
        m.fixedBody = body;
        return m;
    }

    public static ExchangeRateApiMock withApiError(String errorType) {
        return withResponse(200, '{"result":"error","error-type":"' + errorType + '"}');
    }

    public static ExchangeRateApiMock withNetworkFailure() {
        ExchangeRateApiMock m = new ExchangeRateApiMock();
        m.throwException = true;
        return m;
    }

    public HttpResponse respond(HttpRequest req) {
        callCount++;
        endpoints.add(req.getEndpoint());
        if (throwException) {
            throw new CalloutException('Simulated network failure');
        }
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        if (fixedStatus != null) {
            res.setStatusCode(fixedStatus);
            res.setBody(fixedBody);
            return res;
        }
        String target = req.getEndpoint().substringAfterLast('/');
        res.setStatusCode(200);
        if (rates != null && rates.containsKey(target)) {
            res.setBody('{"result":"success","base_code":"BDT","target_code":"' + target
                + '","conversion_rate":' + rates.get(target) + '}');
        } else {
            res.setBody('{"result":"error","error-type":"unsupported-code"}');
        }
        return res;
    }
}
