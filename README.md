# Macky

Un asistent AI personal pentru macOS care stă lângă cursor. **Ții apăsat ⌃⌥ (Control + Option), întrebi cu voce
ceva despre ce e pe ecran, și Macky îți răspunde cu voce și îți arată cu cursorul unde să apeși.**

Inspirat de HeyClicky, construit pentru uz personal și fără costuri fixe:

| Parte | Cum e făcută | Cost |
|---|---|---|
| Transcrierea vocii tale | Whisper rulat local (WhisperKit) | gratuit, audio-ul nu pleacă de pe Mac |
| Creierul (vede ecranul, răspunde, arată) | orice model cu viziune de pe **OpenRouter** (Claude, Gemini, GPT, Qwen…) | din creditele tale OpenRouter |
| Vocea lui Macky | voci neurale Microsoft Edge (Alina, Emil), cu vocile macOS ca rezervă | gratuit |
| Semnarea aplicației | certificat creat local, fără cont Apple Developer | gratuit |
| Server | niciunul, aplicația vorbește direct cu OpenRouter | — |

## Ce știe să facă

- **Întreabă** (ține apăsat ⌃⌥): captură de ecran în momentul eliberării tastelor, răspuns în streaming, citit cu voce propoziție cu propoziție.
- **Arată**: cursorul Macky zboară spre butonul potrivit, iar Accessibility îl „lipește” de controlul real și îl evidențiază. Poate arăta și mai mulți pași la rând.
- **Încercuiește**: cât ții apăsat ⌃⌥, mișcarea mouse-ului lasă o urmă pe ecran (fără click), ca să arăți la ce te referi („ce e asta?”). Urma dispare când eliberezi tastele.
- **Face în locul tău**: „apasă tu pe Export”, „caută pisici pe YouTube”. Macky dă click, scrie și apasă taste, câte un pas, verificând ecranul după fiecare. Implicit te întreabă înainte de fiecare acțiune.
- **Spotify**: „pune Numb de la Linkin Park”, „pornește Liked Songs”, „următoarea melodie”. Direct, fără model, cu verificarea a ce cântă.
- **Sistem**: „volumul la 40”, „mai tare”, „dark mode”, „blochează ecranul”. Instant.
- **Calendar, Reminders, Notes**: „ce am mâine?”, „pune-mi o întâlnire joi la 3”, „amintește-mi la 5 să sun la bancă”, „notează ideea asta”.
- **Ferestre**: „pune Chrome în stânga și Spotify în dreapta”.
- **Agent în fundal**: „Agent, caută cele mai bune 5 microfoane sub 500 de lei și fă-mi o comparație”. Lucrează cât faci altceva și salvează rezultatul în Documents/Macky.
- **Notch**: panoul coboară din notch când duci mouse-ul acolo; cât lucrează, Macky arată un indicator lângă notch.
- **Dictează** (ține apăsat ⌃⇧): transcrie local și lipește textul în orice aplicație. Nu folosește AI, deci nu costă nimic.
- **Memorie**: învață singur din conversații cine sunt clienții tăi, unde sunt fișierele, ce preferi și din greșeli (lecții). O dată pe zi își reorganizează memoria și îți scrie profilul. Totul se vede și se editează în fereastra Memorie.
- **Proceduri învățate (⚡)**: o cerere rezolvată la fel de două ori se repetă apoi instant, fără model și fără cost.
- **Istoric**: toate cererile, căutabile, cu ce a făcut Macky și cât a costat.
- **Conversație fără taste**: după un răspuns, Macky mai ascultă câteva secunde, ca să poți continua direct.
- **Asistent de scris**: selectează text în orice aplicație și spune „rescrie mai formal”, „tradu”, „corectează”. Folosește skill-urile tale din Claude (Setări → Skills).
- **Fișiere, Gmail, Google Drive**: „găsește contractul Nordic”, „ce mi-a scris Andrei ieri?”. Doar citire (Setări → Conexiuni).
- **Web**: răspunde cu informații actuale de pe internet.
- **Meetinguri Zoom → Drive**: fiecare meeting înregistrat în cloud e transcris, rezumat (decizii, acțiuni) și salvat ca Google Doc (Setări → Conexiuni → Zoom).
- **„Fă task din asta”**: din orice mail, pagină sau mesaj de pe ecran, Macky creează taskul (în Flowts sau Reminders) cu detaliile și linkul.
- **Aplicațiile tale (MCP)**: Macky se conectează la servere MCP (ex. Flowts) și poate citi și modifica direct taskuri, notițe etc. (Setări → Conexiuni).
- **Rutine**: „brief de dimineață”, „mod lucru”, la o frază sau la o oră fixă, editabile în Setări → Rutine.
- **Întrerupere**: o nouă apăsare oprește imediat răspunsul curent.
- **Conversație**: ține minte ultimele replici; doar întrebarea curentă trimite captura, ca să coste puțin.
- **Două modele**: „Rapid” și „Puternic”, comutabile din panou. Costul fiecărui răspuns se vede în panou.
- **Calibrare**: un ecran cu ținte numerotate care măsoară cât de precis arată fiecare model.
- **Confidențialitate**: captura se face doar când întrebi; managerii de parole sunt excluși implicit; cheia stă în Keychain.

## Instalare (o singură dată)

Ai nevoie de un Mac cu **macOS 14.2+** (ideal cu procesor Apple M1 sau mai nou), **Xcode** (gratuit din App Store)
și [Homebrew](https://brew.sh).

```bash
git clone https://github.com/flowfulmedia-AI/macky.git
cd macky
make setup   # instalează xcodegen și creează certificatul gratuit de semnare (îți cere parola Mac-ului)
make run     # compilează, instalează în ~/Applications și pornește Macky
```

Apoi urmează pașii din panoul Macky (iconița din bara de meniu): adaugă cheia OpenRouter și acordă cele 4 permisiuni.
Detalii și rezolvarea problemelor: [docs/SETUP.md](docs/SETUP.md).

## Structura proiectului

```
Macky/                     aplicația macOS (SwiftUI + AppKit)
  App/                     pornire și legarea componentelor
  Core/CompanionSession    mașina de stări: ascultă → transcrie → întreabă → vorbește → arată
  AI/                      client OpenRouter (streaming), lista de modele
  Voice/                   microfon, Whisper/Apple Speech, voce macOS
  Screen/                  ScreenCaptureKit, Accessibility
  Overlay/                 cursorul Macky, bula de răspuns, evidențierea
  Input/                   scurtături globale, dictare
  Settings/                setări, Keychain, calibrare
  UI/, Permissions/        panoul din bara de meniu, permisiuni
Packages/MackyCore/        logica independentă de platformă, cu teste unitare
project.yml                definiția proiectului Xcode (generat cu xcodegen)
docs/                      plan MVP și ghid de instalare
```

`make test-core` rulează testele unitare. CI-ul de pe GitHub rulează testele și compilează aplicația la fiecare push.
