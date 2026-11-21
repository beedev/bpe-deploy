# PromoEngine POC: install

This installs HTC's proof of concept of PromoEngine, a promotion engine for an outdoor retailer's web shops, on a Mac or a Linux server with Docker. It has an admin web where people create, approve and simulate promotions, a demo storefront that prices carts through the engine, and a sign-in service. The programs are public images on ghcr.io (GitHub's image registry). This repository holds only what is needed to run them: one install script, the file that starts them (`docker-compose.yml`) and the settings they read (`config/`). There is no source code here.

Everything in the demo is invented: the people, the promotions and the prices. Every password is made on your machine when you install, so no two installations share one.

## On your own computer (Mac or Linux)

You need Docker running (on a Mac, [Docker Desktop](https://www.docker.com/products/docker-desktop/)), about 6 GB of memory for it, and 4 GB of disk.

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/beedev/bpe-deploy/main/install.sh
bash install.sh
```

It installs into `~/bpe`, starts the stack and opens **http://localhost:8380/bpe**. The first run downloads about 2 GB and takes several minutes: after the programs start, a one-time job makes the demo data through the real workflow (sites, the catalog feed, campaigns and promotions that are created, submitted and approved by a second person). Use exactly that address, `localhost` and not `127.0.0.1`: the sign-in checks it. If port 8380 is taken, the script picks the next free one and tells you.

## On a server

People reach a server through its HTTPS web proxy (nginx, for example). The stack always lives under the paths `/bpe` (the admin web), `/bpe-shop` (the storefront), `/bpe-keycloak` (the sign-in) and `/bpe-api` (the services the admin web's pages call), so first make sure no other site on that host uses those paths. HTTPS is required: the sign-in cookie is sent only over HTTPS. Then, on the server:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/beedev/bpe-deploy/main/install.sh
bash install.sh https://idea.example.com/bpe
```

From that one address the script works out every setting the stack needs. The stack listens on one port of the server itself only (`127.0.0.1`, which nobody outside the server can reach); the script checks the port is free and picks another if it is not. At the end it prints the nginx lines to add, filled in with your host and port; it does not edit nginx itself. They are one `location` block that passes the four paths to that port, unchanged, with the headers the sign-in service needs to know it was reached over HTTPS.

## Upgrade, stop, start over

- **Upgrade:** run `bash install.sh` again (with the same address on a server). It downloads the latest settings and images and keeps the demo data and the passwords.
- **Stop:** `cd ~/bpe && docker compose down`. **Wipe the demo data too:** `docker compose down -v`. The next `bash install.sh` makes it again.
- **Another address:** run it with the new address. The sign-in service reads its allowed addresses only on its first start, so this starts the stack fresh and makes the demo data again.
- **A port is taken:** the script picks the next free one. To choose it yourself: `BPE_PORT=9380 bash install.sh`.

## Settings: the .env file

All settings live in one file, `~/bpe/.env`, which only you can read (mode 600). You usually change nothing.

**Written by the script.** Each run writes the addresses from the one you give it (`BPE_ORIGIN`, `BPE_URL`, `BPE_SHOP_URL`, `BPE_KEYCLOAK_URL`, `BPE_API_URL`) and the port (`BPE_PORT`). The first run also makes every secret the stack needs, each 24 random letters and digits: the database passwords, the sign-in service's admin password, the demo people's password and the sign-in clients' secrets. Later runs keep them. None of them is in this repository or in an image. `.env.example` lists every setting with what it is for.

**Yours to add.**

| To do this | Add to `.env` | When it takes effect |
|---|---|---|
| Let the assistant (Promo Copilot) answer from a live AI model instead of recorded answers | `OPENAI_API_KEY=<your key>` | Run `bash install.sh` again: it sees the key and switches the assistant to live |
| Run a fixed image version instead of the latest | `BPE_TAG=<version>`, or `BPE_TAG=<version> bash install.sh` | On the next `bash install.sh` |

Without a key the assistant answers from recorded replies. That costs nothing and gives the same answers every time. With a key, each answer costs money; the assistant's budgets per person and per day are built in and hold either way. Keep the key only in `.env`: it never leaves that file, and the app never shows it.

## Sign in

These are the demo people. Each has a role and a set of the retailer's sites.

| User | Role |
|---|---|
| `mortiz` | Merchandiser: creates campaigns and promotions (basspro.com, m.basspro.com, cabelas.com) |
| `dpatel` | Approver: reviews and approves what a merchandiser submits (the same sites) |
| `rgomez` | Site admin: promotion codes and the catalog feed (basspro.ca, mackspw.com) |
| `areed` | Super admin: every site and every screen |
| `au1` | Auditor: reads the audit trail and the decisions (basspro.com, cabelas.com) |

They all share one password, made for your installation only. Read it on the machine where you installed:

```bash
grep ^TEST_USER_PASSWORD= ~/bpe/.env | cut -d= -f2
```

The storefront, at `/bpe-shop`, needs no sign-in: it is the shop a customer sees, pricing carts through the engine.

## If something goes wrong

- **A part does not become healthy.** In `~/bpe`, `docker compose ps -a` shows which, and `docker compose logs <name>` shows why. The demo data job is called `seed`; it runs once and then stops, which is normal. Give the first start ten minutes.
- **The sign-in page loops or says the address is not valid.** You are on an address other than the one you installed with, or on plain `http://` on a server.
- **`seed` failed with "sign-in ... refused" after you wiped only part of the data.** Wipe everything and start again: `docker compose down -v`, then `bash install.sh` (with the same address on a server).

## Rehearse on this computer (for HTC)

To try new images before they are published: in HTC's repository, `scripts/build-push-images.sh --local` builds them for this computer's platform with the tag `local`, and `scripts/publish-deploy.sh --no-git <folder>` writes this repository's files into a folder. Then `BPE_HOME=<folder> NO_DOWNLOAD=1 NO_PULL=1 BPE_TAG=local bash <folder>/install.sh`.

These files are written from HTC's private repository by `scripts/publish-deploy.sh`; changes made here are overwritten.
