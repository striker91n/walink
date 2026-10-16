# Device setup (iPhone 6 Plus, iOS 12.5.8, Amethyst)

This project targets a **jailbroken iPhone 6 Plus** running **iOS 12.5.8**, jailbroken with
[**Amethyst**](https://github.com/staturnzz/amethyst) (semi-untethered, iOS 12.0–13.7, Procursus
bootstrap). Do these once before the first `scripts/deploy.sh`.

## 1. Re-jailbreak after every reboot
Amethyst is **semi-untethered**: after a reboot the jailbreak is gone until you **re-open the
Amethyst app** on the device and let it re-apply. There is no DFU/computer step.

> If you installed Amethyst with a free Apple ID, the app expires after ~7 days and must be
> re-signed (AltStore/Sideloadly). Keep it working, or the device boots un-jailbroken.

## 2. Install OpenSSH
Amethyst ships **Sileo** and **Zebra**. Open one of them, search for **OpenSSH**, and install it.
`deploy.sh` talks to the device over SSH, so this is required.

Then, in a terminal on the device (NewTerm, or over SSH once it works), set a root password —
the Procursus default is `alpine`, which you should not keep:

```sh
passwd
```

## 3. Connect over USB
The device's SSH listens on **port 22** (this is Amethyst/Procursus, *not* checkra1n's port 44).
Forward a local port to it with `iproxy`:

```sh
iproxy 2222 22
```

In another shell, confirm you can log in:

```sh
ssh root@127.0.0.1 -p 2222      # password: whatever you set above
```

If you set a non-default password, tell `deploy.sh` about it:

```sh
DEVICE_SSH_PASS='yourpassword' ./scripts/deploy.sh
```

## 4. Fakesigned apps
Amethyst explicitly supports **fakesigned / AppSync** binaries, so the `ldid`-signed `.deb` this
project builds installs into `/Applications` and launches without an Apple developer certificate.
That is also why the app can request the **`dynamic-codesigning`** entitlement (needed for the JIT
V8 build).

## 5. What `deploy.sh` does
```sh
./scripts/deploy.sh
```
- `iproxy 2222:22`
- `scp` the newest `packages/*.deb` to `/var/mobile/`
- `dpkg -i` it (falls back to `apt-get -f install`)
- re-signs the embedded framework with `ldid -S`
- `uicache -p /Applications/Walink.app` and relaunches Walink

## Troubleshooting
- **`Connection refused` on 2222** — `iproxy` isn't running, or OpenSSH isn't installed/enabled.
- **`Permission denied`** — wrong password; pass `DEVICE_SSH_PASS=...`.
- **App installs but won't open** — the device lost its jailbreak after a reboot; re-open Amethyst.
- **`uicache` not found** — install `uikittools` from Sileo/Zebra.
