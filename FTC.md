# FTC: Java и Android на ученических Mac через Jamf

Add-on к существующему TLF-профилю. Требует Apple Silicon, рабочие CLT/Homebrew
с владельцем `admin`, а также `jq` из существующего TLF-профиля.
Не заменяет `brew_and_xcode.sh`, `jamf-software-tlf.sh` или ежедневный обновлятор.

## Файлы

- `Scripts/jamf-software-ftc.sh` — самостоятельный Bash-скрипт для Jamf School.
- `Brewfiles/ftc.Brewfile` — декларация пакетов; её копия встроена в скрипт.
- `tests/test-ftc-profile.sh` — локальные проверки без установки ПО.

Скрипт специально не загружает исполняемый код из текущего `main` этого
репозитория: для Jamf достаточно его полного текста. Изменяя Brewfile,
обновляйте встроенную копию; тест проверяет их совпадение.

## Что устанавливается и как обновляется

| Компонент | Установка | Обновление / фиксация |
|---|---|---|
| IntelliJ IDEA | Homebrew, `/Applications/IntelliJ IDEA.app` | Stable, существующий `jamf-daily-update.sh` |
| Android Studio | Homebrew, `/Applications/Android Studio.app` | Stable, существующий ежедневный обновлятор |
| Android Command-line Tools | Homebrew `android-commandlinetools` | Stable, существующий ежедневный обновлятор |
| Eclipse Temurin | ARM64 PKG, выбранный по метаданным Homebrew `temurin@21` | **Major 21 зафиксирован**, patch/build обновляются повторным запуском FTC-скрипта |
| Android SDK Platform | `sdkmanager`, в домашний каталог ученика | **API 30** |
| Android Build Tools | `sdkmanager` | **35.0.0** |
| Android NDK | `sdkmanager` | **21.3.6528147**, как в выбранном FTC-проекте |
| Android Platform-Tools | `sdkmanager` | Последний stable, обновляется при повторном root-запуске FTC-скрипта |
| FTC SDK | Официальный Git-репозиторий | **v12.0**, дополнительно проверяется SHA `e14c2aeb33e84d4ea21697beeea9ac49557be870` |
| Gradle / AGP | Из зафиксированного FTC-проекта | **Wrapper 9.1.0 / AGP 8.13.2**; глобальный Gradle не устанавливается |
| Код ученика | Современный компилятор, совместимый профиль | **Java 8**; проверяется `javac --release 8` |

`brew pin` не вызывается. JVM не переводится на новый major. Скрипт не делает
`sdkmanager --update`, не обновляет FTC SDK/AGP/Wrapper и не запускает `git pull`
в ученических проектах. Он не добавляет JUnit в Android-приложение: JUnit,
учебный testkit и модели остаются зависимостями конкретных учебных проектов.

Python, `/opt/edupy`, uv, Git, Chrome, Toolbox, системная политика Homebrew и
существующие замороженные Python-формулы не изменяются.

### Почему Temurin установлен не обычным `brew bundle`

Текущий `jamf-daily-update.sh` намеренно пропускает `.pkg`/custom installers и
использует `HOMEBREW_NO_SUDO=1`. Cask Temurin устанавливается именно через PKG.
Попытка обычного bundle потребовала бы дополнительной привилегии для `admin`
или запроса пароля; под видом автообновления ослаблять политику нельзя.

Новый скрипт:

1. Получает из `brew info --json=v2 --cask temurin@21` версию, ARM64 URL и SHA-256.
2. Проверяет URL официального репозитория Adoptium и major 21.
3. Загружает PKG в закрытый временный каталог root, сверяет SHA-256.
4. Проверяет подпись через `pkgutil` и допуск Gatekeeper через `spctl`.
5. Запускает штатный `/usr/sbin/installer` уже от root-процесса Jamf.

Homebrew при этом остаётся непривилегированным. `sudoers` не меняется.
Temurin **не регистрируется искусственно как установленный cask**;
его обновление принадлежит FTC-скрипту. Поэтому самостоятельный
`brew bundle check` без пропуска `temurin@21` не является проверкой всего профиля.
Сам скрипт задаёт `HOMEBREW_BUNDLE_CASK_SKIP=temurin@21`.

## Запуск в Jamf School

1. Добавить полный текст `Scripts/jamf-software-ftc.sh` как новый скрипт.
2. Запускать **от root**, после существующих bootstrap и TLF-профиля.
3. Сначала назначить одному тестовому ученическому M4. Ученик должен быть обычным
   пользователем, не администратором. Для первой установки нужны интернет и
   минимум 15 GB свободного места — это защитный порог, не точный размер установки.
4. После проверки назначить группе FTC. Не назначать преподавательским Mac,
   где Homebrew принадлежит личному аккаунту преподавателя.
5. Тот же скрипт назначить **еженедельно вне занятий**, чтобы Temurin 21.x и
   SDK Platform-Tools тоже обновлялись. Существующий daily update оставляется
   без изменений; IDE и command-line tools он увидит автоматически.

Скрипт не создаёт отдельный root LaunchDaemon и не меняет расписание Jamf.
При активном экзаменационном сетевом ограничении или общем Homebrew-lock
он откладывает работу. Используется тот же lock, что в текущем обновляторе.
Параллельно два root-установщика пакеты не меняют.

Для тихой установки по умолчанию `ACCEPT_ANDROID_LICENSES=1`: школа разрешает
принятие лицензий Android SDK. При отсутствии такого разрешения поставьте `0`:
SDK-этап завершится ошибкой, а не будет обходить принятие лицензий.

Rosetta устанавливается только при отсутствии: старые Android native tools
могут её требовать. Эмулятор Android и образы виртуальных телефонов не ставятся.
Homebrew сам проверяет совместимость stable-версии IDE с установленной macOS;
скрипт не обходит минимальную версию ОС и не устанавливает EAP/Canary.

## Права и расположение

| Расположение | Кто пишет |
|---|---|
| `/opt/homebrew` | Только существующий владелец `admin`; права учеников не расширяются |
| Два IDE-приложения в `/Applications` | `admin`; ученики читают/запускают |
| `/Library/Java/JavaVirtualMachines/temurin-21.jdk` | Системный установщик, root |
| `/Library/Application Support/The Island/FTC` | root; общий неизменяемый шаблон и скрипты |
| `~/Library/Android/sdk` | Сам ученик |
| `~/.android`, `~/.gradle` | Сам ученик |
| `~/FTC/FtcRobotController-v12.0` | Сам ученик, включая `.git` |
| Настройки/плагины IDE в домашнем каталоге | Сам ученик |

Общего SDK с `chmod 777`, общих writable Gradle-кэшей и общего рабочего Git-tree нет.
Root не делает рекурсивный `chown` домашних каталогов и не запускает ученические
build-файлы или shell-профили. Личные настройки и проекты не удаляются.

Фоновый **пользовательский** LaunchAgent
`/Library/LaunchAgents/cy.theisland.ftc-user-setup.plist` подготавливает новые
учётные записи при первом входе. Он повторяет попытку раз в час, но после успешной
подготовки не запускает сеть/сборку, пока профиль не изменился или пакет не исчез.
Это не привилегированный сервис. Root-скрипт сразу подготавливает уже существующие
личные аккаунты; для этого их активный вход в GUI не требуется.

При обнаружении чужих root-owned SDK/кэшей скрипт сообщает ошибку: автоматически
забирать владельца произвольных существующих каталогов он не будет.
Существующая личная FTC-копия не обновляется, не reset-ится и не переписывается.

## Настройка рабочего окружения

В `.zprofile` и `.zshrc` добавляется одна идемпотентная строка, подключающая
общий root-owned `environment.sh`. Она задаёт:

- `JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home`;
- `ANDROID_HOME=$HOME/Library/Android/sdk`;
- `ANDROID_SDK_ROOT` с тем же значением для совместимости;
- Java 21 и личные platform-tools в `PATH`, не меняя Python.

Если shell-profile является symlink, он не изменяется; предупреждение даёт
путь к файлу окружения для ручного подключения. Новое окружение подхватит новый
терминал. При нестандартном `ZDOTDIR` также подключите файл явно.

В новой личной копии FTC записываются `local.properties` с SDK-путём и
`.gradle/config.properties` с `java.home`. В Android Studio нужно оставить
Gradle JDK = **GRADLE_LOCAL_JAVA_HOME**; если старые личные настройки IDE выбрали
другой JDK, выбрать Temurin 21. Настройки других проектов не переписываются.

В IntelliJ для начальных JVM-проектов выбрать Temurin 21 и language level 8;
эти значения должны быть и в самом учебном starter-проекте. Java 8 отдельно
ставить не нужно. Активация JetBrains через личный образовательный аккаунт
остаётся действием ученика; admin-права ей не нужны.

Toolbox сохраняется, но не должен параллельно управлять этой же общей IDEA.
Если `/Applications/IntelliJ IDEA.app` уже существует и не зарегистрирована
в Homebrew, установка остановится без её удаления. Личные копии в
`~/Applications` скрипт не трогает.

## Проверки, выполняемые на Mac установщиком

Для каждого ученика:

1. Проверка прав: shared Homebrew/JDK/шаблон/IDE не writable для ученика.
2. Установка SDK и проверка наличия `android.jar`, Build Tools, adb и NDK.
3. Компиляция небольшой программы с `--release 8` и запуск обычным пользователем.
4. По умолчанию `VERIFY_APK_BUILD=1`: сборка **чистой копии официального FTC SDK**
   от имени ученика, с `--no-daemon --max-workers=2`.
5. Затем `clean assembleDebug --offline`: проверка, что эта же чистая конфигурация
   собирается без сети после первой сборки. Проверяется наличие APK.

Кэш Gradle при этом прогревается лично у ученика. Его рабочая FTC-копия в эту
проверку не вовлекается. Чистая версия SDK строится снова при изменении профиля
или JDK; на каждом часовом запуске сборки нет.

Это проверка **базового FTC-проекта**, не обещание, что любой будущий учебный
проект с новыми зависимостями уже соберётся offline. Устройство не требуется;
загрузка на Control Hub и работа моторов ещё не проверяются.

Во время обновления JDK/SDK при обнаруженных Java-процессах скрипт откладывает
операцию: он не убивает IDE, Gradle daemon или ученические программы. Закройте
приложения/сборки и повторите; для штатных обновлений используйте время без работы
учеников. Поведение существующего daily update по закрытию IDE не изменяется.

## Логи и коды завершения

- Root: `/var/log/theisland-software-ftc.log`.
- Ученик: `~/Library/Logs/TheIsland/ftc-setup.log`.
- `0`: базовая установка и доступные пользовательские этапы выполнены.
  Если личных аккаунтов ещё нет, это явно записано; APK будет проверен при входе.
- `1`: ошибка установки, проверки или прав.
- `75`: временное откладывание из-за lock, экзамена или работающих Java-процессов.
  Для Jamf это не «уже установлено»: требуется следующий запуск.

Повторить пользовательский этап без sudo:

```bash
/bin/bash "/Library/Application Support/The Island/FTC/ftc-deploy.sh" --user-setup
```

Явно обновить разрешённые SDK-компоненты от ученика:

```bash
/bin/bash "/Library/Application Support/The Island/FTC/ftc-deploy.sh" --user-setup --refresh
```

Запуск системного этапа требует Jamf/root. Предоставление ученикам sudo не нужно.

## Статус проверки этой редакции

Локально выполнены `bash -n` и неразрушающие тесты из `tests/test-ftc-profile.sh`:
Brewfile, сравнение Java-релизов, передача stdin для лицензий, выполнение внешних
команд вместо shell-функций, разделение JSON/stdout/stderr, watchdog и timeout,
локальные SDK/JDK properties, разбор DS-аккаунтов и LaunchAgent XML.

Среда разработки этой редакции — Linux, не Mac. **Установка PKG/casks,
macOS-права, Jamf, sdkmanager, запуск LaunchAgent и реальная APK-сборка здесь не
исполнялись.** Проверки APK находятся в установщике и должны реально пройти
на пилотном M4 до массового назначения. ShellCheck здесь недоступен.

Пилот: первый запуск → успешная Java/APK/offline-проверка → второй запуск
без потери изменений ученика → daily update → вход второго стандартного
пользователя. Проверить, что оба пользователя могут редактировать только свои
SDK/проекты, а не shared-программы. Проверить сценарий без активного GUI-входа.

## Основания для выбранных версий

- [FTC v12.0: build.common.gradle](https://github.com/FIRST-Tech-Challenge/FtcRobotController/blob/v12.0/build.common.gradle)
- [FTC v12.0: Android Gradle Plugin](https://github.com/FIRST-Tech-Challenge/FtcRobotController/blob/v12.0/build.gradle)
- [FTC v12.0: Gradle Wrapper](https://github.com/FIRST-Tech-Challenge/FtcRobotController/blob/v12.0/gradle/wrapper/gradle-wrapper.properties)
- [Homebrew Temurin 21 cask](https://github.com/Homebrew/homebrew-cask/blob/main/Casks/t/temurin@21.rb)
- [Android sdkmanager: компоненты, SDK root и лицензии](https://developer.android.com/tools/sdkmanager)
- [AGP 8.13: Build Tools 35.0.0](https://developer.android.com/build/releases/agp-8-13-0-release-notes)

Проверены 12 ноября 2026. Скрипт получает текущие stable-версии приложений
и patch-релиз Java 21 при исполнении, не хранит устаревающий номер патча.
