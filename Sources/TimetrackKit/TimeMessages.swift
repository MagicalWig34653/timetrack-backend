enum TimeMessages {
    static let german: [String: String] = [
        "bad_request": "Bitte prüfe deine Eingaben.",
        "unauthorized": "Bitte melde dich an oder prüfe dein Gerätetoken.",
        "forbidden": "Du hast keine Berechtigung für diese Aktion.",
        "not_found": "Der Eintrag wurde nicht gefunden.",
        "conflict": "Die Änderung steht im Konflikt mit vorhandenen Daten.",
        "csrf_invalid": "Bitte lade die Seite neu und versuche es erneut.",
        "recovery_session_restricted": "Bitte richte zuerst einen neuen Passkey ein.",
        "too_many_requests": "Zu viele Anfragen. Bitte versuche es später erneut.",
        "timer_already_running": "Es läuft bereits eine Zeiterfassung.",
        "no_running_timer": "Es läuft keine Zeiterfassung.",
        "segment_overlap": "Der Zeitraum überschneidet sich mit einem vorhandenen Abschnitt.",
        "stale_version": "Der Abschnitt wurde inzwischen geändert. Bitte lade ihn neu.",
        "model_overlap": "Der Gültigkeitszeitraum überschneidet sich mit einer vorhandenen Modellversion.",
        "suggestion_resolved": "Dieser Vorschlag wurde bereits bearbeitet.",
    ]
}
