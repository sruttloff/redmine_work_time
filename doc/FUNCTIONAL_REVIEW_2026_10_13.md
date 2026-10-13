# WorkTime 0.4.4 – vertiefte Funktionsprüfung

Geprüft am 13.10.2026, Ausgangsstand `11b57f834c59d99daeac5d49e605cc6596348b68` / `v0.4.4`.

**Historischer Befundbericht:** Die nachstehenden Fehler beziehen sich auf Version 0.4.4. Sie wurden für **0.4.5** behoben und erneut geprüft; siehe [Code-Review und Freigabeprüfung 0.4.5](REVIEW_0_4_5.md). Der heute mitgelieferte Regressionslauf wurde entsprechend erweitert.

**Ergebnis: Die üblichen Arbeitsabläufe funktionieren. Für einen produktiven Einsatz bestehen jedoch wesentliche Berechtigungs- und Sicherheitsfehler sowie Fehler bei Sonderfällen.** Die erfolgreiche erste Kompatibilitätsprüfung mit 42 Checks deckte diese Fälle nicht ab.

## Umgebung und Vorgehen

- Redmine 6.1.2-stable, Rails 7.2.3, Ruby 3.3.7, MySQL 8.4.11.
- Lokale Docker-Entwicklungsumgebung mit den anderen installierten Plugins, einschließlich `redmine_contacts_helpdesk` und Redmine UX Toolkit.
- Tatsächliche Bedienung im integrierten Codex-Browser, deutsche Oberfläche, normale Mitarbeiter-, Verwaltungs- und Leserrolle.
- Zwei private Browser-Testprojekte, vier eigene Testkonten und fünf Testtickets. Keine vorhandenen Arbeitsdaten wurden für Schreibtests verwendet.
- Zusätzlich echte Rails-Integration-Requests einschließlich gültiger Anmeldung und CSRF-Token. Die negativen Berechtigungstests ändern nur eigene Testdatensätze innerhalb einer zurückgerollten Transaktion.
- Für die API-Prüfung wurde REST-API-Unterstützung nur innerhalb der Testtransaktion aktiviert und ein temporärer API-Schlüssel verwendet.
- Die Browser-Testdaten einschließlich Rollen, Notizen, Buchungen, Fortschreibungen, Sortierung und projektbezogenen Abrechnungseinstellungen wurden anschließend entfernt. Die Browser-Sitzung wurde abgemeldet.

## Im Browser erfolgreich geprüft

| Arbeitsablauf | Beobachtetes Ergebnis |
| --- | --- |
| Persönlicher Menüeintrag und Projekt-Menü | Zeiterfassung öffnet sich in beiden Kontexten. |
| Bestehende Buchung ändern | `1.25` Stunden auf `2:30` geändert; nach Speichern werden `2.50` Stunden angezeigt. |
| Kommentar speichern | Umlaute, Anführungszeichen und Semikolon bleiben nach dem Speichern erhalten. |
| Neue Buchung | Eingabe `90m` ergibt `1.50` Stunden; Aktivität wird gespeichert. |
| Buchung löschen | Leeres Stundenfeld entfernt die eigene Testbuchung; Summen werden aktualisiert. |
| Ungültige Stunden | `-1` wird mit „Stunden ist nicht gültig“ abgelehnt; der ungültige Datensatz wird nicht gespeichert. |
| Ticket per Nummer hinzufügen | AJAX fügt das ausgewählte sichtbare Ticket in die Tagestabelle ein. |
| Tagesnotiz | Mehrzeilige Notiz mit Umlauten und Aufzählung bleibt nach dem Speichern und nach Navigation erhalten. |
| Monatsnavigation | Wechsel Oktober → November → Oktober funktioniert. |
| Projektfilter | Auswahl des privaten Testprojekts funktioniert. |
| CSV herunterladen | Browser lädt `member_monthly.csv` herunter; normale Datensätze enthalten die erwarteten dezimalen Stunden. |
| Andere Mitarbeiter mit Verwaltungsrechten | Auswahl und Änderung einer Mitarbeiterbuchung auf `2.75` Stunden funktionieren. |
| Ticketfortschritt | AJAX-Dialog geöffnet, Fortschritt auf `50%` gesetzt und Anzeige anschließend bestätigt. |
| Ticketfortschreibung | `2.75` Stunden werden dem gewählten Sammelvorgang zugeordnet; Gesamtsumme bleibt `4.25` Stunden. |
| Abrechnungsbeginn | Tag `15` gespeichert; Berichtsperiode wird korrekt als `15.09.2026–14.10.2026` angezeigt. |
| Leserrolle | Andere Mitarbeiter können gelesen werden; Schaltflächen zum Speichern, zur Notizbearbeitung und zur Fortschrittsbearbeitung fehlen in dieser Ansicht. Die nachstehenden Serverfehler zeigen jedoch, dass ausgeblendete Bedienelemente keine ausreichende Berechtigungsprüfung sind. |

Bei diesen normalen Browserabläufen wurden keine JavaScript-Fehler oder Warnungen in der erfassten Konsole beobachtet. Die Tabellen benötigen in der schmalen integrierten Browseransicht horizontales Scrollen. Mehrere deutsche Beschriftungen fallen noch auf Englisch zurück.

## Reproduzierte Fehler

Die P1-Befunde sollten vor dem nächsten produktiven Einsatz behoben werden. P2 kennzeichnet reproduzierbare Funktions- oder Robustheitsfehler.

| ID | Priorität | Befund und Nachweis | Ursache / betroffene Stelle |
| --- | --- | --- | --- |
| F1 | P1 | Ein normaler Mitarbeiter ohne Zugriff auf das zweite private Projekt kann dessen Zeitbuchung per übermittelter `time_entry`-ID ändern (`3.0` → `9.0`) und mit leerem Stundenwert löschen. Beide Requests liefern HTTP 200. | `hour_update`, `app/controllers/work_time_controller.rb:795`: Der geladene Datensatz wird weder auf ausgewählten Benutzer/Projekt noch auf `editable_by?` geprüft. `safe_attributes` ersetzt diese Prüfung nicht. |
| F2 | P1 | Ein Mitarbeiter kann mit einer fremden `user`-ID und `memo` eine Tagesnotiz des anderen Benutzers speichern, obwohl er dessen Zeit nicht bearbeiten darf. HTTP 200, Notiz tatsächlich angelegt. | `update_daily_memo`, Controller Zeile 927: Benutzer-ID wird direkt aus `params[:user]` übernommen; die zuvor auf den aktuellen Benutzer eingeschränkte Auswahl wird umgangen. |
| F3 | P1 | Ein Nicht-Administrator kann über `set_holiday` einen globalen Feiertag speichern. HTTP 200, Datensatz tatsächlich angelegt. | `set_holiday`, Controller Zeile 955: Administratorprüfung fehlt serverseitig; nur die Oberfläche blendet die Funktion aus. |
| F4 | P1 | Eine reine Leserrolle kann per POST `register_project_settings` den Abrechnungsbeginn ändern. HTTP 302, Einstellung tatsächlich geändert. | Controller Zeile 547 und Berechtigungsdefinition in `init.rb`: Die Aktion ist bereits der Leseberechtigung zugeordnet; `edit_work_time_total` wird beim Speichern nicht gesondert verlangt. |
| F5 | P1 | Die AJAX-Fortschreibungsanzeige liefert den Titel eines Zieltickets aus einem fremden privaten Projekt, obwohl der Mitarbeiter dieses Ticket nicht sehen darf. HTTP 200, Titel im Antworttext. | `ajax_relay`, Controller Zeile 391: Existenzprüfung des Ziels ohne Sichtbarkeitsprüfung. |
| F6 | P1 | Ein Ticketname mit harmlosem `<strong data-wtqa="markup">…</strong>` wird in der Fortschreibungsanzeige als echtes HTML ausgegeben. | Controller Zeile 392 und `app/views/work_time/ajax_relay.html.erb:9`: Ungefilterter Tickettext wird als `html_safe` markiert. Damit besteht ein Ansatz für gespeichertes XSS; ausführbarer JavaScript-Schadcode wurde nicht verwendet. |
| F7 | P2 | Ein Titel wie `QA "quoted", title` erzeugt eine ungültige CSV-Datei. Ruby `CSV.parse` meldet `CSV::MalformedCSVError` in Zeile 2. | `member_monthly_data`, Controller Zeile 74: CSV wird per Stringverkettung aufgebaut; innere Anführungszeichen werden nicht korrekt verdoppelt. Weitere Exportaktionen verwenden denselben Ansatz. |
| F8 | P2 | Die JSON-Berichts-API liefert mit gültigem API-Schlüssel HTTP 500, wenn Aufwand auf ein nicht sichtbares Zielticket fortgeschrieben wird. | `app/views/work_time/relay_total.api.rsb:19`: Unsichtbare Ziele werden als Sammel-ID `-1` geführt; für den fehlenden Datensatz werden trotzdem `iss.tracker` und `iss.subject` aufgerufen. |
| F9 | P2 | Abrechnungsbeginn `31`, Aufruf eines Berichts am 15. März 2026: HTTP 500. Der Code versucht einen Start am 31. Februar zu erzeugen. | `prepare_values`, Controller Zeile 600: `Date.new` erhält einen ungültigen Tag. Die Oberfläche erlaubt trotzdem 1–31. Dieser Fall war bereits als Einschränkung dokumentiert. |
| F10 | P2 | Eine nicht mehr vorhandene Zeitbuchungs-ID im Tagesformular und eine unbekannte Ticket-ID im Fortschrittsdialog führen jeweils zu HTTP 500. | Controller Zeile 795/796 und `app/views/work_time/ajax_done_ratio_input.html.erb:1`: Fehlende Datensätze werden dereferenziert. |

## Automatisierte Ergebnisse und Wiederholung

```sh
bundle exec rake zeitwerk:check
bundle exec rails runner plugins/redmine_work_time/test/compatibility_smoke.rb
bundle exec rails runner plugins/redmine_work_time/test/workflow_audit.rb
```

- Zeitwerk: erfolgreich.
- Bisheriger Kompatibilitätslauf: **42/42 Checks erfolgreich**, erneut in dieser Sitzung ausgeführt.
- Neuer vertiefter Prüflauf: **1/13 erfolgreich, 12 fehlgeschlagen**. Die Fehler entsprechen F1–F10; F1 und F10 umfassen jeweils zwei Testfälle.

`workflow_audit.rb` ist ein eigenständig ausführbarer Reproduktionslauf. Er legt eigene private Projekte, Konten und Rollen an, sendet echte Requests und prüft die gespeicherten Daten. Alle Änderungen einschließlich Einstellungen und API-Schlüssel werden zurückgerollt; der Lauf endet bei offenen Befunden absichtlich mit Exit-Code 1. Für Änderungen an Ticketnamen zwischen Requests wird der Query-Cache geleert, damit tatsächlich die neuen Sonderzeichen geprüft werden.

## Einordnung

Der eingeschränkte Kompatibilitätstest bestätigt, dass das Plugin unter Redmine 6.1 geladen wird und zentrale Ansichten sowie einfache Exporte funktionieren. Er bestätigt keine ausreichende Trennung zwischen Benutzern und Projekten. Die vertiefte Prüfung zeigt, dass Version 0.4.4 diese Trennung an mehreren Schreib- und Lesepunkten nicht zuverlässig durchsetzt.

Empfohlene Reihenfolge: F1–F6 beheben, danach CSV/API und Datums-/Fehlerbehandlung korrigieren, beide Prüfläufe und die betroffenen Browserabläufe erneut ausführen und erst anschließend eine neue Patchversion veröffentlichen. Dieser Prüfauftrag ergänzt lokal den Bericht und den Reproduktionslauf; die Produktionslogik und der veröffentlichte Tag wurden nicht geändert.
