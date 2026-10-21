# uCore pve

Opinionated [uCore](https://projectucore.org/) (Fedora CoreOS) image variants tuned for
running as **guests on Proxmox VE**, driven by the **Proxmox Cloud-Init** agent.

The base OS already ships [Afterburn](https://github.com/coreos/afterburn), which has a native
`proxmoxve` provider that reads Proxmox's Cloud-Init config-drive. A stock uCore image is only
missing a few conveniences for a KVM/QEMU guest: the QEMU guest agent and `virtiofsd` for
`virtio-fs` shared folders. This repository layers exactly those on top of upstream uCore and
publishes ready-to-rebase OCI images to GitHub Container Registry.

## How Proxmox Cloud-Init works on uCore / Fedora CoreOS

Proxmox's "Cloud-Init" ISO is a **NoCloud config-drive**: an `iso9660` volume labeled `cidata`
holding `meta-data`, `user-data`, and `network-config`. Afterburn's `proxmoxve` provider reads it
and applies:

| Proxmox Cloud-Init field | Applied by | When |
| --- | --- | --- |
| **Hostname** | `afterburn-hostname.service` (initrd) -> writes `/etc/hostname` | first boot |
| **SSH keys** | `afterburn-sshkeys@core.service` (root FS) -> `authorized_keys` | every boot |
| **Networking** (static/DHCP/gateway/DNS) | `afterburn-network-kargs.service` (initrd) -> `rd.*` kargs | first boot |

> Note: this is **not** full cloud-init. Arbitrary `user-data`/cloud-config (`runcmd`, `packages`,
> `write_files`, etc.) is **ignored** - that's Ignition's job, not Afterburn's. Only hostname, SSH
> keys, and networking are honored.

### The required kernel argument

Afterburn selects its provider from the kernel command line:

```
ignition.platform.id=proxmoxve
```

All the units above are gated on `ConditionKernelCommandLine=ignition.platform.id=proxmoxve`.

**On CoreOS Proxmox qcow2 this is set by default** — a fresh clone already has it in `/proc/cmdline`, so you normally
don't need to do anything. Verify:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -i platform.id
```

Only if it's somehow missing (e.g. wrong base image) set it **inside the VM** before templating, so it
lands in the deployment's bootloader config and is inherited by every clone:

```bash
sudo rpm-ostree kargs --append-if-missing=ignition.platform.id=proxmoxve
sudo systemctl reboot
```

## What this image adds on top of uCore

| Change | Why |
| --- | --- |
| Installs & enables `qemu-guest-agent` | Lets Proxmox read the guest IP/hostname and do clean shutdown/reboot. |
| Installs `virtiofsd` | Enables `virtio-fs` shared directories between host and guest. |
| Enables `afterburn-sshkeys@core.service` | Applies SSH keys from the Cloud-Init user account every boot. |
| Adds & enables `apply-hostname.service` | Re-applies the Cloud-Init hostname **every boot**, so template clones get their own name. |

Networking needs no enablement here - it is handled by the initrd once
`ignition.platform.id=proxmoxve` is present.

### Why `apply-hostname.service` exists

The built-in `afterburn-hostname.service` runs only during Ignition's **first-boot** stage. A
Proxmox template has already completed first boot, so its clones inherit an "already provisioned"
disk and keep the template's hostname. This image ships a small oneshot unit that runs
`afterburn --cmdline --hostname=/etc/hostname` on **every** boot (gated to proxmoxve), then pushes
the value into the running kernel via `hostnamectl`. Afterburn is a no-op when the config-drive has
no hostname, so `/etc/hostname` is never blanked if cidata is absent.

## Images

Both images are built from the same [`Containerfile`](Containerfile) and pushed to GHCR:

| Image | Base | Purpose |
| --- | --- | --- |
| `ghcr.io/<owner>/ucore-pve/ucore-pve` | `ghcr.io/ublue-os/ucore:stable` | Full uCore with batteries included. |
| `ghcr.io/<owner>/ucore-pve/ucore-pve-minimal` | `ghcr.io/ublue-os/ucore-minimal:stable` | Minimal uCore base for smaller footprints. |

Each build is tagged with both `latest` and a `YYYYMMDD` date stamp.

## Usage

### Provisioning a VM in Proxmox

1. Create the VM from your template (`ignition.platform.id=proxmoxve` is already set on CoreOS Proxmox qcow2).
2. Add a **Cloud-Init** resource; set hostname, user + SSH keys, and network.
3. Ensure the Cloud-Init drive is attached (Proxmox does this automatically as a `cidata` ISO).
4. Boot. Hostname, keys, and network are applied by Afterburn; verify:

```bash
cat /etc/hostname
sudo journalctl -u afterburn-sshkeys@core
systemctl status qemu-guest-agent
```

### Rebasing an existing install

```bash
sudo rpm-ostree rebase \
  --experimental \
  ostree-unverified-registry:ghcr.io/ff05/ucore-pve/ucore-pve-minimal:latest
sudo systemctl reboot
```

### Building locally

```bash
podman build \
  --build-arg BASE_IMAGE=ghcr.io/ublue-os/ucore-minimal:stable \
  -t localhost/ucore-pve-minimal:latest .
```


## Notes & caveats

- **`ignition.platform.id=proxmoxve` is required but set by default on CoreOS Proxmox qcow2.** Verify with
  `cat /proc/cmdline`; only add it via `rpm-ostree kargs` if missing.
- **Hostname re-applies every boot** via `apply-hostname.service`, so template clones get their
  own name without resetting the Ignition first-boot marker. **Networking is still first-boot-only**
  (initrd kargs); to change a clone's IP, reset the first-boot marker or re-provision its Cloud-Init
  drive.

