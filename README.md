# Store Inventory & Ordering

A single web app that reads all of your vendor order forms (Excel and PDF), loads
them into a SQLite database, and gives you one searchable catalogue with a cart
that groups items by vendor and emails each vendor their own purchase order.

---

## How vendor names work

Everything under the `Order Forms/` folder is picked up automatically:

```
Order Forms/
├── Grain Market.xlsx              → vendor "Grain Market"
├── JMD.xlsx                       → vendor "JMD"
├── ONE STOP DISTRIBUTION.pdf      → vendor "ONE STOP DISTRIBUTION"
└── BALAJI WHOLESALE/              → vendor "BALAJI WHOLESALE"
    ├── BALAJI 1.pdf                 (both files merge into one vendor)
    └── BALAJI 2.pdf
```

* A file sitting **directly** in `Order Forms/` becomes a vendor named after the file.
* A file inside a **subfolder** takes the subfolder's name as its vendor — use this
  when one vendor sends you several catalogues.

Supported formats: `.xlsx`, `.xlsm`, `.xls`, `.csv`, `.tsv`, `.pdf`.

---

## Running it

### Docker (recommended for your VPS)

```bash
cp .env.example .env        # fill in SMTP details
docker compose up -d --build
```

Open `http://your-server:3000`.

The `Order Forms` folder is bind-mounted, so you can drop new vendor files onto
the server (scp, rsync, Samba, whatever you use) and hit **Refresh from files** in
the UI — no rebuild, no restart.

The database lives in the `inventory-data` volume so vendor email addresses,
order history and the cart survive upgrades.

### Without Docker

Requirements: Node 20+, Python 3.9+.

```bash
npm install
pip install -r ingest/requirements.txt
cp .env.example .env
node src/server.js
```

---

## Signing in

The app ships with one account:

| | |
|---|---|
| Username | `himalayanbazaar` |
| Password | `5103Magna` |

**Change this password before the app is reachable from the internet.** A warning
banner stays across the top until you do. Settings → *Account* → *Change password*.

The account, its password (hashed with scrypt) and its sessions all live in the
same SQLite database as everything else. Sessions last 14 days and are held in an
HttpOnly cookie; changing or resetting the password signs out every other device.

Repeated wrong passwords are throttled — 8 failures from the same address locks
that username out for 15 minutes.

### Forgotten password

*Forgot your password?* on the sign-in page takes a username **or** the email
address on the account, and emails a link that works once and expires after an
hour. Two things have to be set up first, or there's nowhere to send it:

1. Settings → *Account* → **Email for password resets**.
2. Settings → *Outgoing mail* — the same SMTP details used for vendor orders.

Also set **Public address of this app** in Settings if you run behind a reverse
proxy, so the emailed link points at your real domain rather than the internal
address. Without it the app guesses from the request.

The page gives the same answer whether or not the account exists, so it can't be
used to find out which usernames are real.

If you're ever locked out with no working email, reset the password from the
server itself:

```bash
docker compose exec inventory node -e "
  const a=require('/app/src/auth'), {db}=require('/app/src/db');
  const u=db.prepare('SELECT id FROM users LIMIT 1').get();
  a.setPassword(u.id,'a-new-password');
  console.log('done');"
```

### Adding more staff accounts

There's one account by design — this is a small internal tool. To add another:

```bash
docker compose exec inventory node -e "
  const a=require('/app/src/auth'), {db}=require('/app/src/db');
  db.prepare('INSERT INTO users (username,password_hash,email) VALUES (?,?,?)')
    .run('username', a.hashPassword('their-password'), 'them@yourstore.com');
  console.log('created');"
```

Everyone shares the same catalogue, cart and vendor list.

---

## Using it

**Search** — type any part of a product name, vendor name, or item code. Results
update as you type. Narrow further with the vendor and category dropdowns, or tick
*Hide unavailable* to drop items the vendor marked NA / out of stock.

**Cart** — set a quantity, press *Add*. The cart panel groups everything by vendor
and shows a running total wherever the order form included prices.

**Email an order** — open the cart, press *Email order* on a vendor's group. You get
a preview of exactly what will be sent, can add a note ("deliver Friday morning"),
and the items are cleared from the cart once the mail goes out. Every send is
recorded under **History**, including failures.

**Vendors** — save an email address (and optional CC) per vendor. These are stored
separately from the catalogue, so re-importing your files never wipes them.

**Refresh from files** — re-reads every file in `Order Forms/` and rebuilds the
catalogue. Items already in your cart are matched back up by name, size and code;
anything a vendor removed from their list is dropped from the cart. A full import
of ~12,000 products across 14 vendors takes about 90 seconds, mostly for the PDFs.

---

## Email setup

Settings → *Outgoing mail*. For Gmail:

| Field | Value |
|---|---|
| SMTP host | `smtp.gmail.com` |
| Port | `587` |
| Use TLS on connect | unticked |
| Username | your Gmail address |
| Password | a 16-character **App Password**, not your normal password |
| From address | `Your Store <you@gmail.com>` |

App Passwords live under Google Account → Security → 2-Step Verification → App
passwords. Press **Test connection** to confirm before sending a real order.

Any other SMTP provider works the same way (Zoho, Fastmail, SES, your host's mail
server). Port 465 providers need *Use TLS on connect* ticked.

---

## Putting it behind a domain with HTTPS

The app speaks plain HTTP on port 3000. Terminate TLS with a reverse proxy —
example nginx server block:

```nginx
server {
    server_name inventory.yourstore.com;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;   # imports can run a couple of minutes
    }
}
```

Then `certbot --nginx -d inventory.yourstore.com`.

Once you have a domain, set it as **Public address of this app** in Settings so
password-reset links point at it.

Session cookies are marked `Secure` automatically when the proxy forwards
`X-Forwarded-Proto: https`, which the block above does.

---

## How the parsing works

Order forms are laid out for humans, not machines: two or three product blocks
side by side across a page, category headings interrupting the rows, header rows
that start halfway down the sheet, and some files with no headers at all.

`ingest/extract.py` handles this generically rather than per vendor:

1. Every sheet (Excel) or page (PDF) is reduced to a grid of strings.
2. A header row is located if one exists — anywhere in the first 15 rows.
3. Each column is given a role (name / size / price / code / order) using the
   header *and* what the column actually contains, so a mislabelled or missing
   header still parses.
4. The grid is split into repeating left-to-right blocks, one per product-name
   column, so side-by-side layouts read correctly.
5. Rows that are headings rather than products become the category for the rows
   beneath them.

Because it's layout-driven, a new vendor file usually works with no code changes.
If one imports badly, check Settings → *Order forms folder* for its item count —
a suspiciously low number points at the file to look at.

`note` values the vendor wrote in their order column (`NA`, `Low stock`, `X`)
become the availability badges shown in search results.

---

## Layout

```
src/server.js        Express app + JSON API
src/db.js            SQLite schema, FTS5 index, catalogue swap
src/auth.js          password hashing, sessions, reset tokens, throttling
src/ingest.js        runs the Python extractor, writes results to SQLite
src/mailer.js        SMTP config + purchase-order and reset email templates
ingest/extract.py    Excel/PDF → structured product rows
public/              the single-page UI (no build step, no framework)
public/login.html    sign-in and forgot-password page
public/reset.html    choose-a-new-password page
data/inventory.db    SQLite database (created on first run)
```

### API

Everything except `/healthz` and the `/api/auth/*` endpoints below needs a session.

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/auth/login` · `/logout` | sign in and out |
| POST | `/api/auth/forgot` · `/reset` | request and use a reset link |
| POST | `/api/account/password` | change your own password |
| PUT | `/api/account` | change username / reset email |
| GET | `/api/search?q=&vendor=&category=` | search the catalogue |
| GET | `/api/vendors` | vendors with product counts and emails |
| PUT | `/api/vendors/:vendor` | save a vendor's email / CC |
| GET/POST/PATCH/DELETE | `/api/cart` | cart operations |
| GET | `/api/orders/preview?vendor=` | preview an order email |
| POST | `/api/orders/send` | send one vendor's order |
| POST | `/api/refresh` | re-import the Order Forms folder |
| GET | `/api/refresh/status` | import progress and per-file results |

---

## Backups

Everything worth keeping is in the `inventory-data` volume:

```bash
docker run --rm -v inventory-data:/d -v "$PWD:/out" alpine \
  tar czf /out/inventory-backup.tgz -C /d .
```

The catalogue itself can always be rebuilt from your files — the parts that can't
are your login, vendor email addresses and order history.
