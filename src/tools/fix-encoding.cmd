@echo off
rem Ensures every .ps1 in this package is stored as UTF-8 WITH BOM.
rem Windows PowerShell 5.1 reads BOM-less files using the system ANSI code page;
rem on a Russian Windows (CP1251) that turns Cyrillic into mojibake and the
rem scripts fail with "Unexpected token" parse errors. This script is pure ASCII
rem on purpose, so it can run even when the .ps1 files are broken.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Command "$root='%~dp0..'; Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object { try { $b=[IO.File]::ReadAllBytes($_.FullName); $has=($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191); if(-not $has){ $t=[Text.Encoding]::UTF8.GetString($b); [IO.File]::WriteAllText($_.FullName,$t,(New-Object Text.UTF8Encoding($true))) } } catch { } }"
exit /b 0
