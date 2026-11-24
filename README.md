# Zapret Ultimate

Self-tuning DPI-bypass for Windows built on [zapret](https://github.com/bol-van/zapret)
(`winws` + WinDivert). Instead of shipping one static `.bat`, it measures what your
ISP actually blocks, benchmarks 18 strategies, validates the winner with a real
YouTube download and a real Chrome/Edge page, then installs it as a Windows service
with a watchdog and a one-command rollback.

> **По-русски:** это сборка zapret, которая сама подбирает рабочую стратегию под
> вашего провайдера, проверяет её в реальном браузере и ставит службой. Полная
> инструкция — в [src/README.md](src/README.md).

## Download

Grab the latest ZIP from the [Releases](../../releases) page:

| Build | Size | Notes |
|---|---|---|
| `Zapret-Ultimate-Full.zip` | ~24 MB | includes `yt-dlp` for the YouTube speed test |
| `Zapret-Ultimate-Lite.zip` | ~1.6 MB | same program, no speed test |

Extract, run `Install.bat`, approve UAC. It copies itself to `C:\Zapret`, tunes for
2–3 minutes (YouTube/Discord are unavailable during that time), installs the service
and the 5-minute watchdog, and hardens the folder ACL.

## Features

* **Auto-tuning** — measures the baseline (what is blocked), benchmarks every
  profile, and validates the finalists with:
  * a real HTTPS download from `googlevideo.com` (≥ 2 Mbit/s required);
  * a real headless Chrome/Edge page load, because browsers use a different
    ClientHello (Kyber/GREASE) than Schannel/OpenSSL.
* **Rollback everywhere** — the previous service config is restored if tuning is
  interrupted, if installation fails, or if the final check is worse than before.
* **Watchdog** — every 5 minutes: checks the service and connectivity, restarts it,
  and switches to the runner-up profile if that does not help. A global lock keeps
  it away from a running tuning pass, and a lock whose owner process died no longer
  blocks it. Intervals live in `config/settings.json`.
* **QUIC toggle** — quic-off / quic-on for Brave/Chrome/Edge (HTTP/3 sometimes stalls where TCP works).
* **Diagnostics** — TLS 1.2/1.3 probes (a curl fallback is shown explicitly),
  per-video CDN node check (check-video),
  HTTP, YouTube throughput, "volume freeze" test against `googlevideo`,
  hosts-file check, folder ACL check, foreign-task check,
  IPv6/conflicts/DNS.
* **Self-update** — update downloads the release from GitHub over HTTPS,
  verifies that the new main script parses, backs up the current package and
  re-applies the profile; the watchdog checks once a week (utoUpdateDays).
* **Safe GGC blocking** — dead `googlevideo` nodes are blocked one by one; the
  check refuses to act when the whole network looks down and never blocks every
  node at once. A node that comes back to life is unblocked automatically
  (DoH resolution + direct-IP check).
* **No DNS or adapter changes**. `hosts` is modified only by `ggc-check`
  (blocks dead GGC nodes), `ggc-reset` (removes them) and `fix-hosts` (removes
  foreign YouTube entries); each change is backed up in `state\`.

## Usage

```bat
Zapret.bat            :: menu
Zapret.bat status
Zapret.bat test       :: availability + YouTube speed + browser check
Zapret.bat tune       :: full auto-tune (~3 min)
Zapret.bat quick      :: quick auto-tune (~2 min, 6 main profiles)
Zapret.bat apply fake-hfs-ts
Zapret.bat fix-hosts  :: remove foreign 0.0.0.0 googlevideo entries
Zapret.bat ggc-check  :: find and block dead GGC nodes
Zapret.bat ggc-reset  :: unblock all managed GGC entries
Zapret.bat playback   :: check 4 different videos (node-specific stalls)
Zapret.bat check-video <url> :: check a specific video and its CDN nodes
Zapret.bat update    :: update from GitHub
Zapret.bat update-check :: only check whether an update exists
Zapret.bat quic-off    :: disable HTTP/3 in Brave/Chrome/Edge
Zapret.bat quic-on     :: re-enable HTTP/3
Zapret.bat fix-acl    :: restrict write access to C:\Zapret
Zapret.bat disable-legacy :: disable foreign tasks that start zapret
Zapret.bat restore    :: restore the service that existed before installation
Zapret.bat uninstall
```

## Requirements

* Windows 10/11 x64, administrator rights.
* No other WinDivert-based tool running (GoodbyeDPI, ByeDPI, another zapret).
* Antivirus may flag `WinDivert` as RiskTool/PUA — false positive; exclude
  `C:\Zapret`.

## Honest limitations (late 2026)

Some videos are served **only** from GGC nodes whose IP ranges are blocked by
the provider. Zapret.bat playback checks four videos and says explicitly when
all nodes of a video are unreachable at the IP level: no DPI-bypass profile can
fix that, a VPN/transport tunnel is required.

Russian TSPU has moved from SNI-signature blocking to behavioural scoring and
TCP volume freezes (a connection passes ~8–32 KB and stalls without RST). Packet
desync cannot fix that. `Zapret.bat diagnose` detects this case and says so; for
YouTube you then need a transport-level workaround (AmneziaWG/WireGuard,
VLESS+REALITY+XHTTP, TG WS Proxy). Targeted IP bans are also out of scope.

## Security

* The folder is locked down by the installer: Administrators/SYSTEM write,
  Users read-only — the watchdog executes scripts from it as SYSTEM. The
  installer verifies the result and reports a failure loudly; `Zapret.bat diagnose`
  shows the current state and `Zapret.bat fix-acl` repairs it (e.g. after the
  folder was recreated by a manual copy).
* `update` validates the downloaded package (syntax check), keeps a backup in `state/update-backup-*` and applies the profile only after the copy succeeds.
* `restore` brings back the original service command line, start type and display
  name; `state/service-backup.json` keeps the backup.
* TCP timestamps are enabled only if they were disabled, and reverted on uninstall.

## Credits & license

Original code in this repository is MIT-licensed (see [LICENSE](LICENSE)).
Bundled third-party components are **not** part of this repository: release ZIPs
contain unmodified binaries from their upstream projects — see [NOTICE.md](NOTICE.md).
