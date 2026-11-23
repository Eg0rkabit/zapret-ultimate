# Third-party components (NOTICE)

The source code in this repository is original and MIT-licensed. **Release ZIP
archives** built from it also contain unmodified third-party binaries and data.
They are redistributed as-is, without modification, and remain under the terms of
their respective projects:

| Component | Used for | Upstream |
|---|---|---|
| `winws.exe`, `cygwin1.dll`, fake payload `.bin` files, host/ipset lists | DPI desync engine | [bol-van/zapret](https://github.com/bol-van/zapret), taken from the [Flowseal/zapret-discord-youtube 1.10.4](https://github.com/Flowseal/zapret-discord-youtube/releases/tag/1.10.4) bundle |
| `WinDivert.dll`, `WinDivert64.sys` | packet interception driver | [basil00/WinDivert](https://github.com/basil00/WinDivert) |
| `yt-dlp.exe` (Full build only) | YouTube throughput test | [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense) |

`winws` identifies itself as zapret v72.9 (`c849e55ef0f1c244206f5a05ff7b1ab41a3824ee`).
Upstream repositories contain the corresponding sources and license terms; consult
them before redistributing further.

If you are a rights holder and believe something here should not be distributed,
open an issue and it will be removed.

## No warranty / acceptable use

The software is provided "as is", without warranty of any kind. You are
responsible for how you use it and for compliance with the laws of your
jurisdiction.
