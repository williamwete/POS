package com.pirantisolution.pos.payment.gateway;

/** Belum ada penyedia pembayaran: metode GATEWAY hanya bisa dipakai dengan konfirmasi manual. */
public class NoGateway implements PaymentGateway {

    @Override
    public String provider() {
        return "NONE";
    }

    @Override
    public boolean configured() {
        return false;
    }

    @Override
    public Charge create(ChargeRequest request) {
        throw new GatewayUnavailableException("No payment gateway configured", null);
    }

    @Override
    public GatewayStatus status(String externalTransactionId) {
        return GatewayStatus.PENDING;
    }

    @Override
    public void cancel(String externalTransactionId) {
        // tidak ada yang dibatalkan
    }

    @Override
    public CallbackEvent verifyCallback(String rawBody, String signature, String timestamp) {
        throw new CallbackRejectedException("No payment gateway configured");
    }
}
