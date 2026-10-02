package com.pirantisolution.pos.terminal;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import com.pirantisolution.pos.terminal.TerminalDtos.CreateDeviceRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.CreateTerminalRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.DeviceView;
import com.pirantisolution.pos.terminal.TerminalDtos.TerminalView;
import com.pirantisolution.pos.terminal.TerminalDtos.UpdateDeviceRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.UpdateTerminalRequest;
import java.util.List;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class TerminalService {

    static final String PERM_MANAGE = "terminal.manage";

    private final TerminalRepository repo;
    private final AccessService access;
    private final AuditService audit;

    public TerminalService(TerminalRepository repo, AccessService access, AuditService audit) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
    }

    @Transactional(readOnly = true)
    public List<TerminalView> listTerminals(UUID outletId) {
        if (outletId != null) {
            access.requireOutletAccess(outletId);
        } else {
            access.currentUser();
        }
        return repo.findTerminals(outletId);
    }

    @Transactional(readOnly = true)
    public TerminalView getTerminal(UUID id) {
        access.currentUser();
        TerminalView t = repo.findTerminal(id).orElseThrow(() -> ApiException.notFound("Terminal"));
        access.requireOutletAccess(t.outletId());
        return t;
    }

    @Transactional
    public TerminalView createTerminal(CreateTerminalRequest req) {
        access.requireOutlet(PERM_MANAGE, req.outletId());
        CurrentUser cu = access.currentUser();
        validateDevices(req.outletId(), req.deviceId(), req.printerId(), req.cashDrawerId());
        UUID id = repo.insertTerminal(req, cu.userId());
        TerminalView created = repo.findTerminal(id).orElseThrow();
        audit.record(AuditEvent.of("TERMINAL_CREATED", "TERMINAL", id).outlet(req.outletId()).change(null, created));
        return created;
    }

    @Transactional
    public TerminalView updateTerminal(UUID id, UpdateTerminalRequest req) {
        access.currentUser();
        TerminalView before = repo.findTerminal(id).orElseThrow(() -> ApiException.notFound("Terminal"));
        access.requireOutlet(PERM_MANAGE, before.outletId());
        CurrentUser cu = access.currentUser();
        validateDevices(before.outletId(), req.deviceId(), req.printerId(), req.cashDrawerId());
        Guards.requireUpdated(repo.updateTerminal(id, req, cu.userId()));
        TerminalView after = repo.findTerminal(id).orElseThrow();
        String action = before.active() && !after.active() ? "TERMINAL_DEACTIVATED" : "TERMINAL_UPDATED";
        audit.record(AuditEvent.of(action, "TERMINAL", id).outlet(before.outletId()).change(before, after));
        return after;
    }

    @Transactional(readOnly = true)
    public List<DeviceView> listDevices(UUID outletId) {
        if (outletId != null) {
            access.requireOutletAccess(outletId);
        } else {
            access.currentUser();
        }
        return repo.findDevices(outletId);
    }

    @Transactional
    public DeviceView createDevice(CreateDeviceRequest req) {
        access.requireOutlet(PERM_MANAGE, req.outletId());
        CurrentUser cu = access.currentUser();
        DeviceView created = repo.insertDevice(req, cu.userId());
        audit.record(AuditEvent.of("DEVICE_CREATED", "DEVICE", created.id()).outlet(req.outletId()).change(null, created));
        return created;
    }

    @Transactional
    public DeviceView updateDevice(UUID id, UpdateDeviceRequest req) {
        access.currentUser();
        DeviceView before = repo.findDevice(id).orElseThrow(() -> ApiException.notFound("Device"));
        access.requireOutlet(PERM_MANAGE, before.outletId());
        if (before.active() && !req.active() && repo.deviceInUse(id)) {
            throw new ApiException(ErrorCode.INVALID_DEVICE,
                    "Device masih terpasang di terminal aktif; lepas dari terminal terlebih dahulu");
        }
        CurrentUser cu = access.currentUser();
        DeviceView after = Guards.requireUpdated(repo.updateDevice(id, req, cu.userId()));
        audit.record(AuditEvent.of("DEVICE_UPDATED", "DEVICE", id).outlet(before.outletId()).change(before, after));
        return after;
    }

    private void validateDevices(UUID outletId, UUID deviceId, UUID printerId, UUID drawerId) {
        checkDevice(outletId, deviceId, "BROWSER", "Device kasir");
        checkDevice(outletId, printerId, "PRINTER", "Printer");
        checkDevice(outletId, drawerId, "CASH_DRAWER", "Laci kas");
    }

    private void checkDevice(UUID outletId, UUID deviceId, String expectedType, String label) {
        if (deviceId == null) {
            return;
        }
        DeviceView d = repo.findDevice(deviceId)
                .orElseThrow(() -> new ApiException(ErrorCode.INVALID_DEVICE, label + " tidak ditemukan"));
        if (!d.outletId().equals(outletId)) {
            throw new ApiException(ErrorCode.INVALID_DEVICE, label + " berada di outlet lain");
        }
        if (!expectedType.equals(d.deviceType())) {
            throw new ApiException(ErrorCode.INVALID_DEVICE, label + " harus bertipe " + expectedType);
        }
        if (!d.active()) {
            throw new ApiException(ErrorCode.INVALID_DEVICE, label + " tidak aktif");
        }
    }
}
