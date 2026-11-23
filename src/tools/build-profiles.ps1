# Builds profiles\library.json - a set of complete winws strategies.
# Every profile is a full argument list; {BIN} and {LISTS} are substituted at
# apply time. Keeping every strategy self-contained makes the active config
# readable and debuggable.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$profilesDir = Join-Path $root 'profiles'
if (-not (Test-Path $profilesDir)) { New-Item -ItemType Directory -Force -Path $profilesDir | Out-Null }

$excl = @(
    '--hostlist-exclude={LISTS}\list-exclude.txt',
    '--hostlist-exclude={LISTS}\list-exclude-user.txt',
    '--ipset-exclude={LISTS}\ipset-exclude.txt',
    '--ipset-exclude={LISTS}\ipset-exclude-user.txt'
)

# Fixed UDP part: QUIC, Discord voice, then generic UDP for ipset.
$udp = @(
    '--filter-udp=443',
    '--hostlist={LISTS}\list-general.txt',
    '--hostlist={LISTS}\list-general-user.txt',
    '--dpi-desync=fake',
    '--dpi-desync-repeats=6',
    '--dpi-desync-fake-quic={BIN}\quic_initial_www_google_com.bin',
    '--new',
    '--filter-udp=19294-19344,50000-50100',
    '--filter-l7=discord,stun',
    '--dpi-desync=fake',
    '--dpi-desync-fake-discord={BIN}\ACTIVE_DISCORD_UDP.bin',
    '--dpi-desync-fake-stun={BIN}\ACTIVE_DISCORD_UDP.bin',
    '--dpi-desync-repeats=6',
    '--new'
)

$discordTcp = @(
    '--filter-tcp=2053,2083,2087,2096,8443',
    '--hostlist-domains=discord.media',
    '--dpi-desync=fake,multisplit',
    '--dpi-desync-split-pos=1',
    '--dpi-desync-split-seqovl=681',
    '--dpi-desync-split-seqovl-pattern={BIN}\tls_clienthello_www_google_com.bin',
    '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
    '--dpi-desync-fooling=ts',
    '--dpi-desync-repeats=8',
    '--new'
)

$tail = @(
    '--filter-udp=443',
    '--ipset={LISTS}\ipset-all.txt'
) + $excl + @(
    '--dpi-desync=fake',
    '--dpi-desync-repeats=6',
    '--dpi-desync-fake-quic={BIN}\quic_initial_www_google_com.bin',
    '--new'
)

# Variants: applied to both the YouTube (list-google) and the general TCP rules.
$variants = @(
    @{
        id = 'fake-hfs-ts'; name = 'fake + hostfakesplit (ts)'
        desc = 'Классика 2025-2026: фейковый ClientHello с подменой хоста, fooling=ts, altorder=1.'
        args = @(
            '--dpi-desync=fake,hostfakesplit',
            '--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'fake-hfs-alt0'; name = 'fake + hostfakesplit (altorder=0)'
        desc = 'То же, но реальный хост уходит первым сегментом.'
        args = @(
            '--dpi-desync=fake,hostfakesplit',
            '--dpi-desync-hostfakesplit-mod=host=www.google.com',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'fake-hfs-rndsni'; name = 'fake + hostfakesplit (random SNI)'
        desc = 'Фейк со случайным SNI (rndsni) — обходит списки «известных» доменов.'
        args = @(
            '--dpi-desync=fake,hostfakesplit',
            '--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,rndsni,dupsid',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'fake-hfs-midhost'; name = 'fake + hostfakesplit (midhost)'
        desc = 'Дополнительный разрез внутри настоящего имени хоста (midsld).'
        args = @(
            '--dpi-desync=fake,hostfakesplit',
            '--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1',
            '--dpi-desync-hostfakesplit-midhost=midsld',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'fake-ms-seqovl'; name = 'fake + multisplit + seqovl'
        desc = 'Фейк + разрезание ClientHello с перекрытием последовательности (681).'
        args = @(
            '--dpi-desync=fake,multisplit',
            '--dpi-desync-split-pos=1',
            '--dpi-desync-split-seqovl=681',
            '--dpi-desync-split-seqovl-pattern={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,sni=www.google.com',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=8'
        )
    },
    @{
        id = 'fake-ms-4pda'; name = 'fake + multisplit (4pda fake)'
        desc = 'Фейк от 4pda + перекрытие 568; хорошо работает на части провайдеров.'
        args = @(
            '--dpi-desync=fake,multisplit',
            '--dpi-desync-split-pos=1',
            '--dpi-desync-split-seqovl=568',
            '--dpi-desync-split-seqovl-pattern={BIN}\tls_clienthello_4pda_to.bin',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_4pda_to.bin',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'fake-mdo-badseq'; name = 'fake + multidisorder (badseq)'
        desc = 'Стандарт апстрима: fake + multidisorder по 1,midsld с badseq.'
        args = @(
            '--dpi-desync=fake,multidisorder',
            '--dpi-desync-split-pos=1,midsld',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=badseq',
            '--dpi-desync-repeats=11'
        )
    },
    @{
        id = 'fake-mdo-md5sig'; name = 'fake + multidisorder (md5sig)'
        desc = 'То же, но fooling=md5sig — некоторые ТСПУ не отбрасывают такой фейк.'
        args = @(
            '--dpi-desync=fake,multidisorder',
            '--dpi-desync-split-pos=1,midsld',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=md5sig',
            '--dpi-desync-repeats=8'
        )
    },
    @{
        id = 'fake-only-ttl'; name = 'fake only (TTL=4)'
        desc = 'Без fooling, фейк умирает по TTL=4 — не требует TCP timestamps.'
        args = @(
            '--dpi-desync=fake',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-ttl=4',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'fake-only-badsum'; name = 'fake only (badsum)'
        desc = 'Фейк с битой контрольной суммой.'
        args = @(
            '--dpi-desync=fake',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=badsum',
            '--dpi-desync-repeats=8'
        )
    },
    @{
        id = 'fake-only-datanoack'; name = 'fake only (datanoack)'
        desc = 'Фейк без флага ACK.'
        args = @(
            '--dpi-desync=fake',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=datanoack',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'hostfakesplit-only'; name = 'hostfakesplit only'
        desc = 'Минимальное вмешательство: подменяется только имя хоста.'
        args = @(
            '--dpi-desync=hostfakesplit',
            '--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1',
            '--dpi-desync-fooling=ts'
        )
    },
    @{
        id = 'fakedsplit'; name = 'fakedsplit'
        desc = 'Разрезание с фейковым заполнителем (старый добрый split).'
        args = @(
            '--dpi-desync=fakedsplit',
            '--dpi-desync-split-pos=1',
            '--dpi-desync-fakedsplit-pattern={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'multisplit-plain'; name = 'multisplit (без фейка)'
        desc = 'Только дробление ClientHello по позициям 1,2,3 + seqovl 568.'
        args = @(
            '--dpi-desync=multisplit',
            '--dpi-desync-split-pos=1,2,3',
            '--dpi-desync-split-seqovl=568',
            '--dpi-desync-split-seqovl-pattern={BIN}\tls_clienthello_www_google_com.bin'
        )
    },
    @{
        id = 'syndata-mdo'; name = 'syndata + multidisorder'
        desc = 'Данные в SYN (0-я фаза) + обратный порядок сегментов.'
        args = @(
            '--dpi-desync=syndata,multidisorder',
            '--dpi-desync-split-pos=1,midsld'
        )
    },
    @{
        id = 'fake-hfs-dup'; name = 'fake + hostfakesplit + dup'
        desc = 'Дополнительно дублирует оригинальный пакет с badseq (обход реассемблинга).'
        args = @(
            '--dpi-desync=fake,hostfakesplit',
            '--dpi-desync-hostfakesplit-mod=host=www.google.com,altorder=1',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6',
            '--dup=1',
            '--dup-fooling=badseq',
            '--dup-cutoff=n6'
        )
    },
    @{
        id = 'fake-ipfrag'; name = 'fake + ipfrag2'
        desc = 'IP-фрагментация второго сегмента + фейк.'
        args = @(
            '--dpi-desync=fake,ipfrag2',
            '--dpi-desync-ipfrag-pos-tcp=32',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com',
            '--dpi-desync-repeats=6'
        )
    },
    @{
        id = 'fake-ms-midsld'; name = 'fake + multisplit (midsld)'
        desc = 'Разрез ровно по середине SLD (midsld) — устойчивее к реассемблингу.'
        args = @(
            '--dpi-desync=fake,multisplit',
            '--dpi-desync-split-pos=midsld',
            '--dpi-desync-fake-tls={BIN}\tls_clienthello_www_google_com.bin',
            '--dpi-desync-fake-tls-mod=rnd,sni=www.google.com',
            '--dpi-desync-fooling=ts',
            '--dpi-desync-repeats=6'
        )
    }
)

$profiles = New-Object System.Collections.ArrayList
foreach ($v in $variants) {
    $args = @(
        '--wf-tcp=80,443,2053,2083,2087,2096,8443',
        '--wf-udp=443,19294-19344,50000-50100'
    ) + $udp + $discordTcp

    # YouTube / Google TCP
    $args += @('--filter-tcp=443', '--hostlist={LISTS}\list-google.txt', '--ip-id=zero') + $excl + $v.args + @('--new')
    # General TCP (Discord, Cloudflare, everything in list-general)
    $args += @('--filter-tcp=80,443', '--hostlist={LISTS}\list-general.txt', '--hostlist={LISTS}\list-general-user.txt') + $excl + $v.args + @('--new')
    # Everything that is known to be blocked (ipset) over TCP
    $args += @('--filter-tcp=80,443,8443', '--ipset={LISTS}\ipset-all.txt') + $excl + $v.args + @('--new')
    $args += $tail

    [void]$profiles.Add([ordered]@{
        id     = $v.id
        name   = $v.name
        desc   = $v.desc
        engine = 'winws1'
        args   = $args
    })
}

$lib = [ordered]@{
    version  = 1
    builtAt  = (Get-Date).ToString('o')
    profiles = $profiles
}
$json = $lib | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $profilesDir 'library.json'), $json, (New-Object Text.UTF8Encoding($false)))
Write-Host ("Сгенерировано профилей: {0}" -f $profiles.Count)
