# ADR-0019: Profil, E-Mail-Änderung und geführte Einrichtung

Status: akzeptiert als Umsetzungsentscheidung von Paket P1 (Lead-Auftrag 16.10.2026); Lead-Prüfung offen. Alles unten sind Annahmen des Pakets, soweit nicht aus ADR-0003/0005/0012/0016 abgeleitet.

## Kontext

Konten hatten Anzeigename und optionale E-Mail nur bei der Registrierung. Es gab keine Möglichkeit, den Namen zu ändern oder eine Adresse nachträglich zu verwalten, und keine geführte Ersteinrichtung (KONZEPT: „Geführtes Onboarding geplant“). Die Einrichtung soll nur bestehende Fachendpunkte nutzen und Vorschläge nie als Nutzerentscheidung ausgeben.

## Entscheidungen

1. **Endpunkte** (Vertrag v0.13.0, additiv, nicht an Module gebunden, nur normale Sitzungen, Recovery-Sitzungen erhalten 403): `GET/PATCH /me/profile`, `PUT/DELETE /me/profile/email`, `POST /me/profile/email/verify`, `PUT /me/onboarding`. Es gibt keine Konto-ID in Pfad oder Body; ein Konto kann nur sich selbst ansprechen.
2. **Anzeigename**: 1 bis 80 Zeichen nach dem Trimmen, sonst 400. Unbekannte Felder (insbesondere `handle`) werden ignoriert, der Handle ändert sich nie. Der Handle ist Wiederherstellungs-Kennung (ADR-0003).
3. **E-Mail-Änderung** nutzt den vorhandenen `MailSender` (SMTP), aber eine eigene Tabelle `email_change_requests` (höchstens eine je Konto, nur der Hash des Codes, 10 Minuten, 5 Versuche). Die Adresse (kleingeschrieben) wird erst nach Bestätigung in `accounts.email`/`email_verified_at` übernommen. Gründe für die getrennte Tabelle: `email_recovery` beschreibt die Wiederherstellungs-Methode (aktiv/inaktiv) und hat andere Semantik; das Profil soll die Adresse ändern können, ohne die Wiederherstellung still ein- oder auszuschalten. Beide Adressen sind unabhängig; die Oberfläche weist darauf hin.
4. **Ohne SMTP** (`mailAvailable=false`): `PUT`/`verify` antworten 501 `not_implemented`; die Adresse bleibt freiwillig und unbestätigt, `DELETE` und Namensänderung funktionieren. Die Oberfläche erklärt das.
5. **Frische Sitzung** (`AuthContext.fresh()`, 10 Minuten, sonst 403 `reauth_required`) für Anfordern, Bestätigen und Entfernen der Adresse; nicht für den Anzeigenamen (wie Sitzungs-Widerruf, geringes Risiko).
6. **Eindeutigkeit**: Eine bestätigte Adresse gehört höchstens einem Konto. Das Backend prüft beim Bestätigen innerhalb der durch `auth_lock` serialisierten Transaktion (ADR-0017: READ COMMITTED auf MariaDB) und antwortet sonst 409 `email_taken`; die Anforderung ist dann verbraucht. Es gibt bewusst keinen UNIQUE-Index auf `accounts.email`: Altdaten aus der Registrierung enthalten unbestätigte Adressen, die sich überschneiden dürfen. Preisgabe: Die Information „Adresse vergeben“ erhält nur, wer den an die Adresse gesendeten Code besitzt, also deren Inhaber; die Anforderung selbst antwortet immer 202.
7. **Rate-Limit**: `PUT`/`POST` unter `/me/profile/email` zählen im `AuthRateLimitMiddleware` wie die Recovery-E-Mail (60 je 5 Minuten je IP-Schlüssel, ADR-0018).
8. **Audit** (`account_audit`, ADR-0016): `profile.name_changed|email_changed|email_removed`, `onboarding.pending|completed|skipped`; nur opake IDs und feste Aktionsnamen, nie Namen, Adressen oder Codes. Die Kaskade (`AccountEraser`) räumt `email_change_requests` mit; der B1-Test auf Tabellen mit Konto-Bezug bleibt grün.
9. **Onboarding-Merker**: Spalten `accounts.onboarding_state` (`completed`|`skipped`, NULL = `pending`) und `onboarding_updated_at`. Die Migration setzt vorhandene Konten auf `skipped`: Wer das Konto schon nutzt, bekommt keine ungewollte Einrichtung angeboten, sie bleibt aus den Einstellungen erreichbar. Neue Konten sind `pending`. `GET /auth/session` liefert `account.onboardingState`; `PUT /me/onboarding` setzt den Zustand (auch zurück auf `pending`). Der Merker steuert nur die Oberfläche, nie Fachregeln.
10. **Die Einrichtung selbst ist reine PWA-Logik** auf bestehenden Endpunkten: `POST /work-models` (neue Version, Historie bleibt, ADR-0004), `PUT /vacation/settings`, `POST /vacation/snapshots`, `PUT /me/modules`. Vorbelegte Werte sind Vorschläge; gespeichert wird erst mit „Einrichtung abschließen“. Fachliche Regeln: Rundung standardmäßig an mit 15 Minuten (nur erster Beginn und letztes Ende), keine Pausen werden erfunden (leeres Pausenfenster ist der Standard), Urlaub 30 Tage bei 5-Tage-Woche und Region DE-ST als Vorschlag (ADR-0005), **kein anteiliger Anspruch im Eintrittsjahr** (ADR-0005); wer mitten im Jahr beginnt, trägt einen Stichtagsbestand ein (ersetzt die davor liegende Historie). Schritte für abgeschaltete Module (Planung: Urlaub; keine schaltbaren Module: Funktionen) entfallen.

## Alternativen

- Erzwungene Weiterleitung nach der Registrierung: verworfen, damit die Einrichtung ein Angebot bleibt (Banner auf der Startseite, Eintrag im Profil) und die Anmeldung nie blockiert.
- Adresse sofort übernehmen und später bestätigen: verworfen, weil sonst unbestätigte Fremdadressen im Konto stünden.
- UNIQUE-Index auf `accounts.email`: verworfen wegen Altdaten und NULL-/Groß-Kleinschreibungs-Unterschieden zwischen SQLite und MariaDB.
- Eigener Backend-Endpunkt für die gesamte Einrichtung (atomar): nicht nötig; die Schritte sind einzeln wiederholbar, die PWA merkt sich bereits Gespeichertes und zeigt es bei Teilfehlern an.

## Folgen und offene Punkte

- Die Einrichtung ist nicht atomar: Bei einem Fehler nach dem Anlegen des Arbeitsmodells bleibt dieses bestehen (Fehlermeldung nennt Gespeichertes, Wiederholung überspringt es).
- Die Adresse wird noch nirgends für Benachrichtigungen verwendet; sie ist Profildatum.
- E-Mail-Versand nur gegen einen Test-SMTP-Empfänger geprüft (kein TLS/Auth real, siehe STATUS).
