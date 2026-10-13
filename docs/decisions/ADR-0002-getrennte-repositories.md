# ADR-0002: Drei Repositories, Backend als Hauptrepo

Status: akzeptiert durch Nutzervorgaben am 13.10.2026.

Der frühere Monorepo-Vorschlag wird ersetzt. PWA und Backend erhalten eigene Repos unter
PhpstormProjects; die Apple-App ein Repo unter Xcode. Backend ist der Arbeitsmittelpunkt
und führt kanonisches Projektwissen sowie API-Verträge. Clients führen ihren lokalen Status.
PhpStorm/Noctule für Backend, PhpStorm für PWA und Xcode für Apple-Apps sind festgelegt.

Folgen: Aufträge und Übergaben müssen Repo-/Commitgrenzen benennen; API-Änderungen koordinieren.
Keine unabhängig editierbaren globalen Konzeptkopien. Sandboxrechte separat sicherstellen.
Zielpfade und ausstehende Einrichtung: ../REPOSITORIES.md.
