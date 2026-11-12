# Изолирана PostgreSQL тестова база

Тази процедура е само за локалния PostgreSQL 18 тестов клъстер на
`127.0.0.1:5433`, база `city6_test`. Работната база `city6:5432` не трябва да
се използва за миграции или тестове.

## Създаване на празен клъстер

1. Уверете се, че тестовият порт 5433 е свободен и че целевият път
   `%LOCALAPPDATA%\City6\postgresql\city6_test_5433` не съществува.
2. Уверете се, че защитеният файл
   `%LOCALAPPDATA%\City6\secrets\city6_test_runner.secret` съдържа
   credential за тестовата роля `city6_test_runner`.
3. От PowerShell в корена на Backend изпълнете:

   ```powershell
   pwsh -NoProfile -File .\tool\setup-isolated-city6-test.ps1 -ProvisionFresh
   ```

Скриптът отказва да използва съществуваща data directory или зает порт, не
изтрива клъстери и не презаписва архиви. Ако инициализацията се прекъсне,
оставете създадената директория непокътната и след проверка на свободен порт
използвайте ново уникално име чрез `-InstanceName`; скриптът няма да продължи
или да презапише частичната директория. Той инициализира PG18 с locale `C`,
loopback
listen, SCRAM удостоверяване, създава `city6_test`, прилага миграции 001–025
в единна транзакция и проверява системните каталози и schema signatures.
Локалният admin credential се генерира само ако липсва и се съхранява в
защитения City6 secrets каталог; стойността не се извежда. При грешка новата
директория се запазва за проверка и не се изтрива автоматично.

Успешното завършване създава уникален custom-format backup в
`%LOCALAPPDATA%\City6\backups`, проверява го с `pg_restore --list` и извежда
SHA-256. Архивът и новият клъстер остават извън Git.

## Изпълнение на PostgreSQL тест

Преди теста задайте credential само в текущата PowerShell сесия. Не въвеждайте
стойността директно в командния ред и не я записвайте в скрипт или файл:

```powershell
$secretPath = Join-Path $env:LOCALAPPDATA 'City6\secrets\city6_test_runner.secret'
$env:CITY6_TEST_DB_USER = 'city6_test_runner'
$env:CITY6_TEST_DB_PASSWORD = [IO.File]::ReadAllText($secretPath).Trim()
$env:CITY6_TEST_DB_PORT = '5433'
dart test test/postgres_district_waiting_board_dispatch_test.dart -r expanded
Remove-Item Env:CITY6_TEST_DB_PASSWORD, Env:CITY6_TEST_DB_USER, Env:CITY6_TEST_DB_PORT -ErrorAction SilentlyContinue
```

Интеграционният тест трябва да потвърди `current_database() = city6_test`,
`inet_server_port() = 5433` и текущата тестова роля, преди да създаде fixtures.
Ако тестът не изисква и не проверява `CITY6_TEST_DB_PORT=5433`, не го изпълнявайте
срещу този клъстер, докато helper-ът не бъде безопасно настроен за изолираната
среда. Някои по-стари PostgreSQL тестове съдържат твърдо зададен порт 5432; те
не са част от тази команда и никога не трябва да се пускат срещу работната
инстанция за целите на тестовата база.

## Контрол и спиране

Проверявайте слушащия PID и `postmaster.pid` спрямо
`%LOCALAPPDATA%\City6\postgresql\city6_test_5433\data` преди контролни
операции. Нормално спиране:

```powershell
& "$env:ProgramFiles\PostgreSQL\18\bin\pg_ctl.exe" stop `
  -D (Join-Path $env:LOCALAPPDATA 'City6\postgresql\city6_test_5433\data') `
  -m fast -w -t 60
```

Не спирайте PostgreSQL service на порт 5432 като част от тази процедура.
