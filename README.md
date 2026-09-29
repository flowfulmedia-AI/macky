# Macky

Un asistent AI personal pentru macOS care stă lângă cursor. **Ții apăsat ⌃⌥ (Control + Option), întrebi cu voce
ceva despre ce e pe ecran, și Macky îți răspunde cu voce și îți arată cu cursorul unde să apeși.**

Inspirat de HeyClicky, construit pentru uz personal și fără costuri fixe:

| Parte | Cum e făcută | Cost |
|---|---|---|
| Transcrierea vocii tale | Whisper rulat local (WhisperKit) | gratuit, audio-ul nu pleacă de pe Mac |
| Creierul (vede ecranul, răspunde, arată) | orice model cu viziune de pe **OpenRouter** (Claude, Gemini, GPT, Qwen…) | din creditele tale OpenRouter |
| Vocea lui Macky | vocile macOS (ex. Ioana Enhanced) | gratuit |
| Semnarea aplicației | certificat creat local, fără cont Apple Developer | gratuit |
| Server | niciunul, aplicația vorbește direct cu OpenRouter | — |

## Ce știe să facă

- **Întreabă** (ține apăsat ⌃⌥): captură de ecran în momentul eliberării tastelor, răspuns în streaming, citit cu voce propoziție cu propoziție.
- **Arată**: cursorul Macky zboară spre butonul potrivit, iar Accessibility îl „lipește” de controlul real și îl evidențiază. Poate arăta și mai mulți pași la rând.
- **Încercuiește**: cât ții apăsat ⌃⌥, poți desena cu mouse-ul pe ecran ca să arăți la ce te referi („ce e asta?”).
- **Face în locul tău**: „apasă tu pe Export”, „caută pisici pe YouTube”. Macky dă click, scrie și apasă taste, câte un pas, verificând ecranul după fiecare. Implicit te întreabă înainte de fiecare acțiune.
- **Notch**: panoul coboară din notch când duci mouse-ul acolo; cât lucrează, Macky arată un indicator lângă notch.
- **Dictează** (ține apăsat ⌃⇧): transcrie local și lipește textul în orice aplicație. Nu folosește AI, deci nu costă nimic.
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
