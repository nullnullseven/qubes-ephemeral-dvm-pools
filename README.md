Before running these scripts in dom0, ensure you have sufficient RAM and available disk space.

The scripts create systemd services to automatically create pools at Qubes OS startup, along with two files for creating and removing pools.

Create pools:

`sudo <name>-pool-create`

Remove pools:

`sudo <name>-pool-remove`

`autostart-zram-pool` - example script where all dvm or specified dvm are cloned into a new zram-pool, then the original dvm are hidden. the pool is recreated on each Qubes OS boot and removes previously created dvms. systemd is not used. If the original DVMs are not hidden in the app menu under the "Templates" section, update the app menu with this command: `pkill -f qubes-app-menu; sleep 0.5; setsid qubes-app-menu >/dev/null 2>&1 &`. Enter this command `qvm-features <dvm-name> internal ""` to make the original DVM reappear in the app menu and Qube Manager list
