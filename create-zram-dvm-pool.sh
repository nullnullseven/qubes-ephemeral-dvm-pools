#!/bin/bash

sudo tee /etc/systemd/system/zram-pool.service << 'EOF'
[Unit]
Description=ZRAM Ephemeral Pool
After=qubesd.service
Before=qubes-vm@sys-net.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zram-pool-create.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo tee /usr/local/bin/zram-pool-create.sh << 'EOF'
#!/bin/bash
set -euo pipefail

POOL_NAME="zram_pool"
ZRAM_SIZE="4G"
VG_NAME="zram_vg"

EXTRA_VMS=(
    #"whonix"
    #"sys-whonix"
)

ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")

if echo "$ROOT_DEV" | grep -qE "(overlay|/dev/zram0)"; then
    echo "[*] Detected amnesiac mode: $ROOT_DEV"
    echo "    Cleaning up old VMs..."

    for vm in $(qvm-ls --raw-list --running 2>/dev/null); do
        if qvm-volume list "$vm" 2>/dev/null | grep -q "${POOL_NAME}"; then
            echo "    -> Stopping: $vm"
            qvm-shutdown --wait --timeout 10 "$vm" 2>/dev/null || \
                qvm-kill "$vm" 2>/dev/null || true
        fi
    done

    for vm in $(qvm-ls --raw-list 2>/dev/null); do
        if qvm-volume list "$vm" 2>/dev/null | grep -q "${POOL_NAME}"; then
            echo "    -> Removing: $vm"
            qvm-remove --force "$vm" 2>/dev/null || true
        fi
    done

    qvm-pool remove "${POOL_NAME}" 2>/dev/null || true
    vgchange -an "${VG_NAME}" 2>/dev/null || true
    vgremove -f "${VG_NAME}" 2>/dev/null || true

    for dev in /dev/zram*; do
        [ -b "$dev" ] || continue
        zramctl --reset "$dev" 2>/dev/null || true
    done

    echo "[+] Cleanup completed."
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    echo "[!] Root privileges required"
    exit 1
fi

echo "[*] Creating zram device (${ZRAM_SIZE})..."
modprobe zram 2>/dev/null || true

ZRAM_DEV=""
for dev in /dev/zram*; do
    [ -b "$dev" ] || continue
    if ! zramctl "$dev" 2>/dev/null | grep -q "mounted\|active"; then
        ZRAM_DEV="$dev"
        break
    fi
done

if [ -z "$ZRAM_DEV" ]; then
    ZRAM_DEV=$(zramctl --find --size "$ZRAM_SIZE" --algorithm lz4)
else
    zramctl --reset "$ZRAM_DEV" 2>/dev/null || true
    ZRAM_DEV=$(zramctl --find --size "$ZRAM_SIZE" --algorithm lz4)
fi

echo "    Device: $ZRAM_DEV"

echo "[*] Removing VMs from pool ${POOL_NAME}..."
for vm in $(qvm-ls --raw-list --running 2>/dev/null); do
    if qvm-volume list "$vm" 2>/dev/null | grep -q "${POOL_NAME}"; then
        echo "    -> Stopping: $vm"
        qvm-shutdown --wait --timeout 30 "$vm" 2>/dev/null || {
            echo "    -> Force killing: $vm"
            qvm-kill "$vm" 2>/dev/null || true
        }
    fi
done

for vm in $(qvm-ls --raw-list 2>/dev/null); do
    if qvm-volume list "$vm" 2>/dev/null | grep -q "${POOL_NAME}"; then
        echo "    -> Removing: $vm"
        qvm-remove --force "$vm" 2>/dev/null || true
    fi
done

echo "[*] Cleaning up old infrastructure..."
qvm-pool remove "${POOL_NAME}" 2>/dev/null || true
vgchange -an "${VG_NAME}" 2>/dev/null || true
vgremove -f "${VG_NAME}" 2>/dev/null || true

# Detach old loops on zram
for loopdev in $(losetup -a 2>/dev/null | grep "$ZRAM_DEV" | cut -d: -f1); do
    echo "    -> Detaching loop: $loopdev"
    losetup -d "$loopdev" 2>/dev/null || true
done

echo "[*] Creating loop on ${ZRAM_DEV}..."
LOOP_DEV=$(losetup -f --show "$ZRAM_DEV")
echo "    Loop: $LOOP_DEV"

echo "[*] Creating LVM on ${LOOP_DEV}..."
pvcreate -q "$LOOP_DEV"
vgcreate -q "${VG_NAME}" "$LOOP_DEV"
lvcreate -q -T -n "thin_pool" -l +100%FREE "${VG_NAME}"

echo "[*] Registering pool ${POOL_NAME}..."
if qvm-pool list 2>/dev/null | grep -q "^${POOL_NAME}"; then
    qvm-pool remove "${POOL_NAME}" 2>/dev/null || true
    sleep 1
fi

qvm-pool add "${POOL_NAME}" lvm_thin --option volume_group="${VG_NAME}" --option thin_pool=thin_pool 2>/dev/null || \
qvm-pool add "${POOL_NAME}" lvm_thin -o volume_group="${VG_NAME}",thin_pool=thin_pool

echo "    Pool created:"
qvm-pool info "${POOL_NAME}"

echo "[*] Cloning VMs into ephemeral pool..."

echo "    [DVM templates]"
qvm-ls --raw-list 2>/dev/null | while read -r vm; do
    [ -n "$vm" ] || continue

    is_dvm=$(qvm-prefs "$vm" template_for_dispvms 2>/dev/null || echo "False")
    [ "$is_dvm" = "True" ] || continue

    if qvm-volume list "$vm" 2>/dev/null | grep -q "${POOL_NAME}"; then
        continue
    fi

    clone_name="${vm}-ephemeral"

    if qvm-ls --raw-list 2>/dev/null | grep -q "^${clone_name}$"; then
        echo "    -> Removing old copy: ${clone_name}"
        qvm-kill "$clone_name" 2>/dev/null || true
        qvm-remove --force "$clone_name" 2>/dev/null || true
    fi

    echo "    -> Cloning: $vm -> ${clone_name}"

    if qvm-clone -P "${POOL_NAME}" "$vm" "$clone_name"; then
        qvm-prefs "$clone_name" template_for_dispvms True 2>/dev/null || true
        qvm-prefs "$clone_name" autostart False 2>/dev/null || true
        echo "    [+] OK"
    else
        echo "    [!] ERROR"
    fi
done

if [ ${#EXTRA_VMS[@]} -gt 0 ]; then
    echo "    [Extra VMs]"
    for vm in "${EXTRA_VMS[@]}"; do
        if ! qvm-ls --raw-list 2>/dev/null | grep -q "^${vm}$"; then
            echo "    [!] VM not found: $vm"
            continue
        fi

        if qvm-volume list "$vm" 2>/dev/null | grep -q "${POOL_NAME}"; then
            echo "    -> Skipping (already in zram): $vm"
            continue
        fi

        clone_name="${vm}-ephemeral"

        if qvm-ls --raw-list 2>/dev/null | grep -q "^${clone_name}$"; then
            echo "    -> Removing old copy: ${clone_name}"
            qvm-kill "$clone_name" 2>/dev/null || true
            qvm-remove --force "$clone_name" 2>/dev/null || true
        fi

        echo "    -> Cloning: $vm -> ${clone_name}"

        if qvm-clone -P "${POOL_NAME}" "$vm" "$clone_name"; then
            qvm-prefs "$clone_name" template_for_dispvms False 2>/dev/null || true
            qvm-prefs "$clone_name" autostart False 2>/dev/null || true
            echo "    [+] OK"
        else
            echo "    [!] ERROR"
        fi
    done
fi
EOF

sudo chmod +x /usr/local/bin/zram-pool-create.sh
sudo systemctl daemon-reload
sudo systemctl enable --now zram-pool.service
