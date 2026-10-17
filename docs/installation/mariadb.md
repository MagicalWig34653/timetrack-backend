# Eigene MariaDB vorbereiten

- **Wofür:** Datenbank und Benutzer mit minimalen Rechten, TLS und Paketgröße für eine vorhandene MariaDB.
- **Voraussetzungen:** Administratorzugang zum MariaDB-Server (empfohlen 12.x; getestet 12.3), Netzwerkzugriff von Server oder Swarm-Knoten.
- **Dauer:** etwa 10 Minuten. Mit der mitgelieferten Datenbank im [Compose-Profil `db`](compose.md) ist diese Seite nicht nötig.

Host, Benutzer, Datenbankname und IP-Bereich unten sind Platzhalter (`db.internal.example.test`, `192.0.2.%`); ersetze sie durch deine.

Erstellen Sie auf dem MariaDB-Server eine **eigene** Datenbank und einen **eigenen** Benutzer mit den nötigen Rechten nur für diese Datenbank.
Das Passwort erzeugt das Secret-Skript ([Swarm](swarm.md), Schritt „Secrets anlegen“; bei Compose `init-secrets.sh`); Sie tragen es dann einmal in die SQL-Anweisung ein.

## Starkes Passwort

Mindestens 32 zufällige Zeichen, keine Wörter. Die Secret-Skripte erzeugen eines (`openssl rand -base64 32`, ersetzt `+/` durch `-_`,
sodass es in SQL-Strings und Shells ohne Maskierung funktioniert). Bei selbst gewähltem Passwort: keine Anführungszeichen, Backslashes oder Zeilenumbrüche verwenden.

## SQL

Als Administrator auf dem MariaDB-Server (`mariadb -u root -p`):

```sql
CREATE DATABASE `timetrack` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Host '%' nur, wenn der Zugriff aus dem Swarm-Netz kommt und die Firewall des DB-Servers den Zugriff begrenzt.
-- Besser: die feste Quelladresse/ das Subnetz des Swarm-Knotens, z. B. 'timetrack'@'192.0.2.%'.
CREATE USER 'timetrack'@'192.0.2.%' IDENTIFIED BY '<PASSWORT-AUS-DER-DATEI>' REQUIRE SSL;

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES
  ON `timetrack`.* TO 'timetrack'@'192.0.2.%';
FLUSH PRIVILEGES;
```

Hinweise zu den Rechten (aus dem Code abgeleitet, nicht gegen den Produktionsserver geprüft):

- Die Migrationen erzeugen und ändern Tabellen (`CREATE`, `ALTER`, `INDEX`, `REFERENCES`) und konvertieren Zeichensätze (`ALTER TABLE ... CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin`).
  `DROP` kommt im Code nur in den Rückwärts-Migrationen (`migrate --revert`) vor; für reine Vorwärts-Updates ist es vermutlich entbehrlich (nicht geprüft), daher bewusst mitgegeben. Der Betrieb selbst braucht nur `SELECT/INSERT/UPDATE/DELETE`. Wer es strenger will, gibt
  `CREATE/ALTER/DROP/INDEX/REFERENCES` nur für den Zeitraum eines Updates frei (zusätzlicher Aufwand, optional).
- **Keine** globalen Rechte (`*.*`), kein `GRANT OPTION`, kein `SUPER`/`FILE`. Der Benutzer darf nur `timetrack.*`.
- Datenbankzeichensatz `utf8mb4`; die Server-Sortierung `utf8mb4_unicode_ci` entspricht der Entwicklungsumgebung. Einzelne Tabellen setzen `utf8mb4_bin` selbst.
- `max_allowed_packet` des Servers sollte mindestens **70 MiB** betragen, wenn Dateien in der Datenbank gespeichert werden (Speicherregel „Datenbank“; Uploads bis 64 MiB). Prüfen: `SHOW VARIABLES LIKE 'max_allowed_packet';`.
  Beispiel „alle Dateien in der Datenbank, höchstens 50 MiB“: im Admin-Bereich (Einstellungen → Dateispeicher) Speicherregel „alles → Datenbank“ (Voreinstellung) und „Größter erlaubter Upload“ = 50 MiB (`maxUploadBytes` = 52428800) setzen; dafür genügt `max_allowed_packet` ≥ 56 MiB, im Proxy `client_max_body_size` ≈ 52m. Weil die Dateien in MariaDB liegen, sehen alle Swarm-Replikate dieselben Dateien (kein verteilter Speicher nötig). Die Grenze ist eine Datenbankeinstellung (kein Umgebungswert); der feste Höchstwert der Software ist 64 MiB, die Voreinstellung 10 MiB.
- Einen **zweiten** Benutzer für Backups (nur lesen) legen Sie nach [Sichern und Wiederherstellen](backup.md) an.

## TLS zur Datenbank

Das Backend verwendet bei `DB_TLS=required` (Standard) TLS mit Prüfung des Serverzertifikats gegen die Zertifikatsablage des Images (Standard der verwendeten Bibliothek, `TLSConfiguration.makeClientConfiguration()`).
Folgen:

- `DB_HOST` muss **exakt dem Namen im Zertifikat** entsprechen (CN/SAN), nicht einer IP, wenn das Zertifikat nur Namen enthält.
- Ein Zertifikat einer **privaten CA** wird nicht akzeptiert, solange diese CA nicht im Image liegt. Das Projekt bietet dafür **keine** Konfiguration (kein `DB_TLS_CA_FILE`); siehe [Bekannte Lücken](../DEPLOYMENT.md). Möglichkeiten: öffentlich vertrauenswürdiges Zertifikat (z. B. Let's Encrypt für den DB-Namen), ein eigenes Image mit installierter CA, oder `DB_TLS=off` **nur** wenn die Verbindung ausschließlich über ein privates, vertrauenswürdiges Netz läuft (Docker-Overlay verschlüsselt nicht von sich aus; WireGuard/VLAN/dieselbe Maschine).
- Auf dem Server: `ssl_cert`, `ssl_key` (und ggf. `ssl_ca`) in der MariaDB-Konfiguration gesetzt; `REQUIRE SSL` am Benutzer erzwingt die Verschlüsselung.

Verbindung vorab testen (vom Swarm-Knoten, mit dem Image selbst ginge es auch, aber der Client genügt):

```sh
mariadb -h db.internal.example.test -u timetrack -p --ssl timetrack -e 'SELECT 1, @@version'
```
