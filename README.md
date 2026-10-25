# Malligai Kadai

Malligai Kadai is a Windows-only grocery billing application. Phase 1 set up the
Flutter desktop app and local API. Phase 2 added Admin/Cashier authentication.
Phase 3 adds product management and cashier product lookup. Phase 4 adds the
cart and invoice creation. Phase 5 adds GST settings and calculations, tax
snapshots, and Cash/UPI/Card payments. Phase 6 adds local Windows thermal
receipt preview, printing, and reprinting. Phase 7 adds Admin dashboards,
sales reports, audit logs, and database backup/restore. Phase 9 adds separate
old/new stock batches and FIFO inventory deductions at checkout.

## Phase 8: Install the Windows application

Build `MalligaiKadai-Setup.exe` on a Windows x64 build machine with Flutter,
the verified Node.js 24.13.1 x64 runtime, Inno Setup 6, Visual Studio's C++
toolchain, and PostgreSQL 18:

```powershell
.\packaging\build-installer.ps1
```

The installer is a single distributable at `artifacts\MalligaiKadai-Setup.exe`.
It embeds the Flutter release app, production backend and dependencies, Node.js,
the Microsoft Visual C++ runtime DLLs, and the PostgreSQL 18 server runtime,
command-line backup tools, libraries, and server support files; it does not
bundle pgAdmin, development data, or the much larger standalone PostgreSQL
installer. A shop PC needs no separate PostgreSQL download or internet access.
The per-user installer does not require Administrator permission or install a
system-wide runtime. PostgreSQL files are staged from the build machine's
PostgreSQL 18 installation with the server and command-line third-party license
notices. The Microsoft-signed C++ runtime DLLs are app-local, so Windows does
not need a machine-wide VC++ runtime installation.

On first launch, Malligai Kadai initializes a PostgreSQL 18 cluster inside the
signed-in Windows user's profile, starts PostgreSQL as a local user process,
and creates a new `malligai_kadai` database and non-superuser `malligai_app`
role with cryptographically random credentials. PostgreSQL binds only to
`127.0.0.1`; the app chooses an available port from 55432–55462. The owner does
not enter database host, port, username, or password. Generated settings are
protected with the signed-in user's Windows DPAPI. Database credentials and
JWT/setup secrets are not hardcoded or written to logs.

Each Windows account has its own shop database. Admin and Cashier should use the
same Windows account on the same PC to access the same shop data. Separate
Windows accounts or PCs have separate data; this is not a multi-shop switcher
for multiple shops using the same Windows account. The previous machine-wide
PostgreSQL service and any data under `%ProgramData%\Malligai Kadai` are not
automatically changed or migrated by this per-user installer.

The shop database starts without sample products. The app applies pending
versioned migrations safely and creates the initial Admin account without
inserting demo data. The Admin password is sent only to the loopback API and
stored in PostgreSQL as a bcrypt hash. Admins can create Cashier accounts; the
application roles are Admin and Cashier.

Developers can explicitly seed a development or test database with 55 sample
grocery products, each with separate Old Stock and New Stock batches. Apply
migrations first, configure the backend database environment, then run this
from the `backend` directory:

```powershell
$env:ENABLE_DEMO_DATA = 'YES'
npm run db:seed-demo
Remove-Item Env:ENABLE_DEMO_DATA
```

The command refuses to run when `NODE_ENV=production`, requires the explicit
environment opt-in, and skips products already present. Never run it against a
client's production database. It does not overwrite products or invoices.

The application starts the local PostgreSQL process and bundled API
automatically. PostgreSQL stays running between app launches so the next startup
does not pay the database shutdown/startup cost; it remains bound to
`127.0.0.1`, and its data remains in the Windows user profile. Windows stops the
per-user database process at sign-out or reboot. The API listens only on
`127.0.0.1`, preferring port `3000` and automatically selecting another
available loopback port if needed. It shuts down gracefully when the app closes.
Only one Malligai Kadai desktop window can run per Windows account. Startup keeps
the Flutter window responsive while it verifies an existing API before starting
PostgreSQL or the bundled API. It logs separate timings for PostgreSQL setup,
database connectivity, migrations, API launch/readiness, and shutdown. If
another program owns port 3000, Malligai Kadai leaves it running and starts its
API on another available loopback port.
Malligai Kadai never terminates an unrelated process. If a previous Malligai
Kadai API is still running, the app reuses it only after verifying its protected
identity, process ID, and database health. Closing the app stops only backend
and manager child processes started by that app, with bounded waits; PostgreSQL
continues running between app launches.
Connection diagnostics do not display database passwords or signing keys.
Startup failures also record safe lifecycle and API output details in
`%LOCALAPPDATA%\Malligai Kadai\backend-startup.log`.

Upgrades install over the existing per-user application folder and apply only
unapplied migrations. PostgreSQL data is stored outside the application
directory at `%LOCALAPPDATA%\Malligai Kadai\PostgreSQL\18\data`. Uninstall
removes the application files and shortcuts but leaves this user data intact.
Keep regular external backups.

The installer no longer downloads the PostgreSQL prerequisite during setup.
This removes the large, failure-prone second download; actual setup duration
depends on the target PC's storage and processor, so a 2–3 minute install cannot
be guaranteed on every machine. If local PostgreSQL setup fails, read
`%LOCALAPPDATA%\Malligai Kadai\database-setup.log`. The log includes the
PostgreSQL initialization diagnostics and excludes generated database
passwords and signing secrets. Restart the app to retry setup; Administrator
permission is not required.

The packaged app automatically chooses another loopback port if port 3000 is
already in use. It never ends an unrelated process. Administrator permission is
not required for startup retries.
For other API startup failures, check
`%LOCALAPPDATA%\Malligai Kadai\backend-startup.log` alongside
`database-setup.log`.

## Developer prerequisites

- Windows 11
- Flutter with Windows desktop support and Visual Studio's Windows desktop
  development workload (`flutter doctor -v`)
- Node.js and npm (only needed to build or run the development backend)
- PostgreSQL 18
- Windows Developer Mode enabled for Flutter Windows plugins that require
  symbolic links

## Manual PostgreSQL setup for development only

Development machines can use the safe provisioning script from the project
root after installing PostgreSQL 18:

```powershell
& ".\backend\scripts\setup-postgresql.ps1"
```

It discovers `psql.exe` from `PATH` or the installed `postgresql-x64-18`
service configuration. The default target is the local `malligai_kadai`
database and the dedicated `malligai_app` role. Enter the PostgreSQL
administrator role when prompted; `psql` asks for its password without echoing
it. The script never accepts a password on the command line or writes it to a
file. At the hidden `\password` prompt, set a unique, strong app-role password
(prefer a password manager-generated value of at least 24 characters), then
enter that same password in the app's first-run screen.

The script checks whether the target database and role already exist. If the
database exists, it asks for explicit `YES` before granting access and
transferring ownership of only the Malligai Kadai tables/sequences so future
versioned migrations can update them. Existing rows are not changed or removed.
If the database is absent, it asks for `CREATE` before creating an empty one.
If the role already exists, it asks before removing its direct role memberships,
restricting its login flags, rotating its password, and updating access. The app
role cannot create databases or roles and is not a superuser. The script does
not edit `listen_addresses` or enable remote access.

For development, enter the app role and password in the app's database
configuration screen or `backend\.env`. Do not use a PostgreSQL superuser as
the application runtime account. The packaged shop-owner installer does not
use this manual setup flow.

The setup script connects only to `127.0.0.1` by default and does not enable
remote access. A PostgreSQL server configured with `listen_addresses='*'` can
accept non-local connections if the firewall and `pg_hba.conf` permit them;
review those rules and restrict the listener to localhost when remote clients
are not required.

## Project structure

```text
MalligaiKadai/
  malligai_kadai/  Flutter Windows desktop app
  backend/         Express, TypeScript APIs, PostgreSQL migrations, tests, backup tools
  README.md
  packaging/      Inno Setup installer and Windows packaging script
```

## Configure PostgreSQL and JWT (development)

From the project root, create your private environment file:

```powershell
Copy-Item backend\.env.example backend\.env
```

Edit `backend\.env` and set `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and
`DB_PASSWORD` to your own PostgreSQL connection details. Do not use example
placeholders as real credentials.

Generate a unique local JWT signing key:

```powershell
node -e "console.log(require('node:crypto').randomBytes(48).toString('hex'))"
```

Paste the output into `JWT_SECRET` in `backend\.env`. Keep this file private;
`.env` is ignored by Git. Never share the JWT secret or PostgreSQL password.
The API refuses to start without a JWT secret of at least 32 bytes.

Install backend packages and apply the versioned migrations:

```powershell
cd backend
npm install
npm run db:migrate
```

Migrations create `app_users`, `products`, and `schema_migrations` as needed,
inside a transaction. Each applied migration is recorded. They do not drop
tables or delete existing data. Product removal is a soft delete, so the row is
retained and excluded from active product searches. Back up your database
before applying schema changes.

For development, use the dedicated `malligai_app` role in `backend\.env` after
running the setup script. That file is ignored by Git; the installed desktop
application instead keeps its database password in Windows secure storage.

## Create the first Admin account (development)

From `backend`, run the interactive setup:

```powershell
npm run admin:create
```

Enter a username of 3–64 letters, numbers, dots, underscores, or hyphens. The
password prompt masks input; choose a unique password with at least 4
characters and no more than 72 UTF-8 bytes. Passwords are stored only as bcrypt
hashes. The setup refuses to create
another initial Admin if one already exists.

Start the local API in the `backend` folder:

```powershell
npm run dev
```

The API binds only to `127.0.0.1`, default port `3000`. A different port can be
set with `API_PORT` in `backend\.env`. On the installed app, the API starts
automatically and pending migrations are applied at startup. Check development
API health from another PowerShell window:

```powershell
Invoke-RestMethod http://127.0.0.1:3000/health
```

An Admin can provision a Cashier using the authenticated
`POST /admin/cashiers` endpoint. Send a JSON body with `username` and
`password` and an `Authorization: Bearer <token>` header from an Admin login.
The Cashier password must also contain at least 4 characters and no more than
72 UTF-8 bytes; it is bcrypt-hashed before storage. Never put real passwords in
source files or shared shell history.

To reset an Admin or Cashier password outside the app, keep Malligai Kadai
running, open PowerShell, and run:

```powershell
& "$env:LOCALAPPDATA\Programs\Malligai Kadai\backend\reset-password.cmd"
```

Enter an Admin username and password, then the username of the account to
reset and the new password twice. The new password must contain at least 4
characters and no more than 72 UTF-8 bytes. The command accepts only an Admin
login and resets either an Admin or Cashier account. If no Admin password is
available, contact support for account recovery.

## Run the Flutter Windows app

Enable Windows Developer Mode if Flutter reports that Windows symbolic links
are unavailable. In Windows Settings, open **System > For developers** and
enable **Developer Mode**, then reopen the terminal. (The Settings page can
also be opened with `start ms-settings:developers`.)

From the project root:

```powershell
cd malligai_kadai
flutter pub get
flutter run -d windows
```

In a developer build, start the backend separately as described above. The app
connects to `http://127.0.0.1:3000` by default and keeps the short-lived
JWT in Windows secure storage. To use a different local API URL, pass
`--dart-define=API_BASE_URL=http://127.0.0.1:3001` to `flutter run`.
Start the backend before signing in. Admin and Cashier accounts open separate
placeholder home screens; logging out clears the saved token.

## Manage products

Sign in to the app and open **View products**. Admins can search by product
name, SKU/barcode, or category and can add, edit, or remove products. Removing
a product archives it from the active list without deleting its database row.
Cashiers can search and view active products but do not see management actions;
the API also enforces this role restriction. Purchase prices are only returned
to Admins. Admins can save the product list as a genuine `.xlsx` workbook using
the Windows save dialog; the export includes product name, code, category, configured quantity and unit,
purchase price, selling price, opening stock quantity, and stock unit, and does
not change database data.

Products require a name, selling unit (`g`, `kg`, `ml`, `litre`, `packet`, or
`piece`), configured quantity, and selling price for that quantity. For example,
₹8 for 100 g is prorated when a cashier sells a different weight. Existing
products retain their previous per-unit pricing through a default configured
quantity of one. Product edits preserve existing code, category, and GST
values, and expose purchase price separately from selling price. GST is configured centrally in Admin
**GST settings**; product-level GST does not affect checkout. Admins can edit a
product's configured quantity and selling price in its row.
SKU/barcode uniqueness is case-insensitive. New products can also be saved
with an opening stock quantity and purchase price.

## Stock management

Admins open **Stocks** from the main navigation and use its **Old Stock** and
**New Stock** tabs. Old Stock shows the opening quantity still available,
opening purchase price, and total quantity. The Admin can update opening
quantity and price without erasing previously sold quantities. New Stock
records each purchase separately with its quantity, purchase price, and date;
the purchase batch remains visible after partial or full depletion.

The product's unit (`kg`, `g`, `litre`, `ml`, `packet`, or `piece`) is the stock
unit. Weight and volume quantities are stored in that unit, including
proportional sales such as 250 g from a product stocked in grams. The product
Excel export keeps its existing columns and appends opening/old stock quantity,
stock unit, and configured selling quantity. The bundled sample-catalogue
reader accepts the optional opening quantity and stock unit columns; no general
Excel import screen is added.

Migration `014_stock_batches.sql` safely records each existing product's
current stock as an opening batch and keeps existing invoices and inventory
movements. New purchases increase total stock without merging into opening
stock. Completed bills consume the oldest available batch first and write
batch-linked inventory movements in the same database transaction as the
invoice. Insufficient stock rejects checkout, and voiding a bill restores the
quantities to the batches consumed by that bill. Stock unit changes are blocked
after any batch has been recorded so historical quantities cannot silently
change meaning. Only Admins can view or manage stock and purchase costs.

## Billing and cart

Admins and Cashiers can open **New bill** from their home screen. Search active
products by name, SKU, or barcode, add them to the cart, enter the price for the
configured product quantity, then choose the amount being sold. The app
calculates proportional amounts for weight and volume; piece and packet
quantities are also supported to three decimal places. The UI
calculates each line total and the total amounts with and without GST. Choose
Cash, UPI, Card, or Split payment. Split allocations must be positive and add
up exactly to the server-calculated invoice total before a bill can be saved.

Saving a bill sends the item IDs, physical quantities, and configured-quantity
prices to
`POST /invoices`. The API validates each amount and calculates GST using the
saved shop settings. It checks available stock, consumes batches in FIFO order,
and writes the invoice, item snapshots, inventory movements, and remaining
quantities in one transaction. It writes the invoice and its item
snapshots in one transaction. Proportional unit prices, product names, SKUs, and
units are stored as invoice-time snapshots. Invoice numbers are allocated from a PostgreSQL
sequence, so concurrent checkouts receive unique sequential numbers. The app
uses a UUID idempotency key and reuses it when retrying an uncertain request;
the server returns the already-saved invoice rather than duplicating a sale.
Reusing an idempotency key for a different bill is rejected.
Sequence gaps may occur if a transaction rolls back; no invoice numbers are
reused.

### GST and payments

Migration `004_gst_payments.sql` is additive and preserves existing products
and invoices. It creates the shop GST settings row, adds invoice and item tax
snapshots, and creates invoice payment records. GST starts disabled. The
migration uses state code `00` as an unconfigured placeholder; it does not
guess the shop's state.

An Admin opens **GST settings** and must enter the shop's correct two-digit
state code before checkout. The Admin can enable/disable GST and select
GST-inclusive or GST-exclusive selling prices. With GST OFF, no tax is added.
For each sale, enter the two-digit sale state code: matching shop/sale states
use CGST and SGST, while a different state uses IGST. The shop-level GST rate
and ON/OFF setting control checkout; GST is not edited on each product. With
GST disabled, product prices are not taxed.

The API recalculates the invoice from current database prices and saved shop
settings; it does not trust totals from Flutter. Monetary
calculations use integer paise and round tax per invoice item. Invoice and item
rows preserve the applicable rates, price mode, states, tax breakdown, and
amounts at sale time, so later setting or product changes do not alter old
bills. Payment records are written with the invoice inside the same transaction.

After configuring the environment and starting PostgreSQL, apply pending
migrations from the `backend` folder:

```powershell
npm run db:migrate
```

Do not enable GST until the Admin has verified the shop state and inclusive or
exclusive price convention. The database integration tests use a randomly
named, isolated schema and remove only that test-created schema when finished;
they need permission to create schemas in the configured database.

## Thermal receipt printing

Receipt printing is performed only by the Windows desktop app through the
installed Windows printer driver. The app does not send printer commands to
the API and does not assume a printer supports direct USB, ESC/POS, or a
particular connection type. Install the printer with its manufacturer's
Windows driver first; USB, Bluetooth, network, and shared printers are usable
only if Windows has installed them and the driver exposes them.

An Admin opens **Receipt printer settings**, refreshes the Windows printer
list, selects the installed printer, chooses **58 mm** or **80 mm**, and saves.
The selected printer name, Windows identifier, and paper width are stored
locally on that PC, not in PostgreSQL. The driver's Windows Printing
Preferences must also have the matching roll width available; some drivers
scale or crop a custom PDF paper size differently.

After a successful save, **Print Invoice** sends the saved invoice directly to
the receipt-roll printer. **Saved invoices** lets Admins and Cashiers choose
**Print Again** to reprint the selected saved bill without creating another
invoice or changing its details. Admins can choose **Delete** after confirming;
this is an audited void, not a physical deletion. The invoice and payment
records remain available for audit, while voided invoices are excluded from
invoice history and sales/payment totals. Receipts use invoice-time item, price,
cashier, GST, payment, and total snapshots. Existing invoices made before payments were
recorded are labeled as having no recorded payment method. Discounts are not
part of the invoice total when unset; saved discounts are shown on the receipt
and are applied before GST where required by the configured price mode.

Use **Print test receipt** in printer settings to test layout and the Windows
print queue without creating a sale. A successful Windows print call confirms
that the driver accepted the job, not that the printer physically produced
paper. If a job fails or no paper comes out:

1. Confirm the printer is powered on, connected, online, and not paused.
2. Load the correct roll and clear any printer/Windows queue error.
3. In Windows **Settings > Bluetooth & devices > Printers & scanners**, verify
   the printer is installed and its **Printing preferences** select the right
   58 mm or 80 mm roll.
4. Refresh the printer list in the app and select the installed printer again.
5. If the printer reports paper-out or offline but Windows still marks it
   available, check its display and manufacturer's status utility. Windows
   drivers do not consistently expose paper sensors to apps.

The invoice history API (`GET /invoices` and `GET /invoices/:id`) is
authenticated. Admins can void an invoice through the protected
`DELETE /admin/invoices/:id` endpoint. Voiding retains the invoice and its
payments, writes an audit record, and excludes it from financial reports. No
printer-management endpoint is exposed.

## Build and test

Run backend commands from `backend`:

```powershell
npm run build
npm test
npm run test:db
npm run test:billing-db
npm run test:reports-db
npm run db:backup
npm run db:check
```

`npm run test:db` exercises CRUD against PostgreSQL with a uniquely named,
soft-deleted test product. It requires the `002_create_products.sql` migration
to be applied. `npm run db:check` needs valid PostgreSQL settings in
`backend\.env`.
The database tests use isolated, randomly named schemas and require schema
creation permission. Do not run concurrent restores while tests or normal
app operations are active.
`npm run db:migrate` applies pending migrations, and `npm run admin:create`
securely initializes the first Admin account.

## Dashboard and reports

After an Admin signs in, open **Dashboard and reports** for today's sales,
invoice count, and a payment summary grouped by Cash, UPI, Card, Split, and
unrecorded legacy invoices. **Sales reports** allow an inclusive start/end date
filter and show invoice, saved line-item, tax, and payment-method details.
Reports can be printed through the installed Windows print dialog or exported
to CSV with the Windows save-file dialog. CSV values are escaped and
spreadsheet-formula-like values are neutralized.

Report APIs are protected by Admin authorization. Sales date filters must be
valid `YYYY-MM-DD` dates, start must not be after end, and a report is limited
to a maximum 366-day span. Amounts are summed using PostgreSQL numeric values.
Date boundaries use the PostgreSQL session time zone; configure the PostgreSQL
server to the shop's local time zone so “today” agrees with the shop's
business day.

## Audit log

The API records successful logins, password changes, cashier creation,
product create/update/archive actions, invoice creation,
GST setting changes, and backup/restore success or failure. Audit events
include actor, action, time, and limited identifiers; passwords, JWTs, and
database secrets are never written to the audit log. Inventory movements are
Historical inventory movement records remain in older databases.
Admins can retrieve recent audit events from the authenticated
`GET /admin/audit` endpoint.

## Database backup and restore

The Admin home screen's **Database backup and restore** page runs PostgreSQL
custom-format `pg_dump` backups and lists files stored outside the project
folder at:

```text
%APPDATA%\Malligai Kadai\Backups
```

The backup includes the configured database contents: users, password hashes,
products, inventory movements, invoices, payments, settings, migrations, and
audit logs. Access to the backup folder is governed by the Windows account;
restrict access to that account and keep a second copy on separate secure
storage. The backup file contains sensitive business and account data.
Database passwords are passed to PostgreSQL tools through a temporary child
process environment, not command-line arguments or logs.

The backup service looks for PostgreSQL 18's `pg_dump.exe` and
`pg_restore.exe` in `C:\Program Files\PostgreSQL\18\bin` by default. If your
installation is elsewhere, set optional `PG_DUMP_PATH` and `PG_RESTORE_PATH`
values in the private `backend\.env`, for example:

```text
PG_DUMP_PATH=C:\Program Files\PostgreSQL\18\bin\pg_dump.exe
PG_RESTORE_PATH=C:\Program Files\PostgreSQL\18\bin\pg_restore.exe
```

Create backups from the Admin page, or run `npm run db:backup` from `backend`.
Restore replaces the current database with the selected complete backup. The
Admin UI requires typing `RESTORE <backup-file-name>` exactly and warns that
current users, products, invoices, payments, and settings will be replaced.
Before restoring, create a backup of the current database. Restore verifies
the PostgreSQL archive and applies it in a single database transaction; a
failed restore is rolled back where PostgreSQL supports transactional restore.
The API pauses its own requests while restore is running. Restart the backend
after a restore and sign in again if the restored user data differs.

For command-line restore, use a backup filename from the backup directory:

```powershell
npm run db:restore -- malligai-kadai_YYYYMMDD_HHMMSS_<id>.dump
```

The command prompts for the exact confirmation. Do not pass passwords as
arguments. Troubleshooting: verify `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
and `DB_PASSWORD`; check that PostgreSQL is running and the database user has
permission to dump and restore all application objects; install PostgreSQL 18
client tools or configure their full paths; and ensure the Windows profile has
write access and free space in `%APPDATA%\Malligai Kadai\Backups`. Backup and
restore actions/errors are added to the audit log.

Run Flutter checks from `malligai_kadai`:

```powershell
flutter analyze
flutter test
flutter build windows --debug
```

Build the release installer from the project root with
`.\packaging\build-installer.ps1`. To use non-default tool locations, pass
`-Flutter` and `-Node` with their full executable paths. The script runs Flutter
and TypeScript production builds, stages only compiled backend files and
production dependencies (never `backend\.env`), and invokes Inno Setup. The
shop PC needs PostgreSQL 18 and its client tools for database and
backup/restore features.

The Flutter tests include the dashboard, sales report, product amount/GST
calculation, password changes, and restore confirmation. Receipt tests also verify formatted 58 mm/80 mm output,
saved GST/payment snapshots, printable PDF generation, and read-only invoice
reprints. A successful software build or test does not verify a particular
physical printer; use the in-app test receipt with the actual Windows printer
and roll.
