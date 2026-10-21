# Bots de La TdG

Executa a GitHub Actions el codi del projecte **Correu** d'Apps Script (bot de premsa, defuncions,
resum i extres del panell de la redacció, Parlaments, subhastes i dades municipals), **tal com és**,
amb un adaptador que imita els serveis de Google (`gas/shim.js`). Així no gasta quota de Google.

- `run.js`: carrega els fitxers del projecte i fa el paper dels activadors (cada 30 minuts).
- `gas/shim.js`: UrlFetchApp, Utilities, XmlService, PropertiesService, CacheService, Sheets (còpia
  que en fa l'Apps Script), Drive i OCR (Tesseract)...
- El codi i l'estat són al repo privat `latdg/apps-script` (branca `estat-bots`).
- Traspàs i marxa enrere: `BotsGitHub.gs` al projecte Correu (`provarBotsAGitHub`,
  `passarBotsAGitHub`, `tornarBotsAAppsScript`).
