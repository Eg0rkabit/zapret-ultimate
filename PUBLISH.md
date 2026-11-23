# Как выложить на GitHub

В репозиторий кладём **только исходники** (этот набор, ~250 КБ). Готовые ZIP с
бинарниками прикрепляем к **Releases**, а не коммитим в git.

## Вариант A — через сайт, без установки программ (2 минуты)

1. Откройте https://github.com/new
   * Repository name: `zapret-ultimate`
   * Public
   * **Не** добавляйте README/.gitignore/license — они уже есть.
   * Create repository.
2. На странице пустого репозитория: **uploading an existing file**.
3. Распакуйте `Zapret-Ultimate-Repo.zip` и перетащите в окно браузера
   **содержимое** папки `Zapret-Ultimate` (файлы `README.md`, `LICENSE`,
   `NOTICE.md`, `.gitignore`, `PUBLISH.md` и папку `src`).
4. Commit changes.
5. Слева **Releases → Create a new release**:
   * Tag: `v1.0.0`, Title: `Zapret Ultimate 1.0`
   * Прикрепите `Zapret-Ultimate-Full.zip` и `Zapret-Ultimate-Lite.zip`
     (кнопка «Attach binaries…»).
   * Publish release.

Готово — ссылку на репозиторий или на Release можно отправлять людям.

## Вариант B — через git в консоли

```bat
winget install Git.Git
cd путь\к\Zapret-Ultimate
git init
git add .
git commit -m "Zapret Ultimate 1.0"
git branch -M main
git remote add origin https://github.com/ВАШ_ЛОГИН/zapret-ultimate.git
git push -u origin main
```

Авторизация — через окно Git Credential Manager (вход в браузере).
ZIP-файлы в git не добавляйте: они в `.gitignore`, их место — в Releases.

## Вариант C — отдать доступ агенту

Если нужно, чтобы всё сделали за вас, нужен **fine-grained personal access token**
с правами:

* `Administration: Read and write` — чтобы создать репозиторий;
* `Contents: Read and write` — чтобы залить файлы и релиз.

Токен создаётся на https://github.com/settings/tokens?type=beta, срок лучше
поставить 7 дней. После публикации токен надо отозвать.

## Что не нужно коммитить

* `bin/` — бинарники zapret/WinDivert (они в Release ZIP, лицензии в NOTICE.md);
* `logs/`, `state/`, `config/active.conf`, `tools/yt-dlp.exe`, `*.zip`;
* бэкапы `state/hosts-backup-*.txt` — там данные вашей машины.

## Важно про кодировку

Скрипты .ps1 сохраняйте в **UTF-8 с BOM**. Windows PowerShell 5.1 на системах с кодовой страницей 1251 иначе читает их как ANSI, и установка падает с ошибками синтаксиса.
