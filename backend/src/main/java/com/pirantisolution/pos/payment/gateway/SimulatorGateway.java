package com.pirantisolution.pos.payment.gateway;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Penyedia QRIS/e-wallet TIRUAN untuk profile local/test. Charge disimpan di memori; pembayaran
 * "dilakukan" lewat endpoint dev yang mengirim callback bertanda tangan ke aplikasi sendiri,
 * sehingga jalur callback produksi ikut teruji.
 */
public class SimulatorGateway implements PaymentGateway {

    public static final String PROVIDER = "SIMULATOR";

    private final CallbackSigner signer;
    private final ObjectMapper json;
    private final Map<String, GatewayStatus> charges = new ConcurrentHashMap<>();

    public SimulatorGateway(CallbackSigner signer, ObjectMapper json) {
        this.signer = signer;
        this.json = json;
    }

    @Override
    public String provider() {
        return PROVIDER;
    }

    @Override
    public boolean simulated() {
        return true;
    }

    @Override
    public Charge create(ChargeRequest request) {
        String externalId = "SIM-" + request.paymentId();
        charges.put(externalId, GatewayStatus.PENDING);
        // Bukan QRIS yang valid untuk dibayar; hanya isi untuk ditampilkan sebagai kode QR.
        String qr = "POS-SIMULATOR|" + request.methodCode() + "|" + request.amount().toPlainString() + "|" + externalId;
        return new Charge(externalId, qr);
    }

    @Override
    public GatewayStatus status(String externalTransactionId) {
        return charges.getOrDefault(externalTransactionId, GatewayStatus.PENDING);
    }

    @Override
    public void cancel(String externalTransactionId) {
        charges.computeIfPresent(externalTransactionId,
                (k, v) -> v == GatewayStatus.PENDING ? GatewayStatus.EXPIRED : v);
    }

    /** Dipakai endpoint dev: tandai hasil lalu kembalikan body + header callback bertanda tangan. */
    public SignedCallback simulate(String externalTransactionId, GatewayStatus result, BigDecimal amount) {
        charges.put(externalTransactionId, result);
        try {
            String body = json.writeValueAsString(Map.of(
                    "externalTransactionId", externalTransactionId,
                    "status", result.name(),
                    "amount", amount.toPlainString(),
                    "reference", "SIMREF-" + Math.abs(externalTransactionId.hashCode())));
            String ts = signer.now();
            return new SignedCallback(body, signer.sign(ts, body), ts);
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    public record SignedCallback(String body, String signature, String timestamp) {
    }

    @Override
    public CallbackEvent verifyCallback(String rawBody, String signature, String timestamp) {
        signer.verify(rawBody, signature, timestamp);
        try {
            JsonNode n = json.readTree(rawBody);
            return new CallbackEvent(
                    n.path("externalTransactionId").asText(null),
                    GatewayStatus.valueOf(n.path("status").asText("PENDING")),
                    new BigDecimal(n.path("amount").asText("0")),
                    n.path("reference").asText(null));
        } catch (Exception e) {
            throw new CallbackRejectedException("malformed callback body");
        }
    }
}
