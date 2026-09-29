# Macky — plan de implementare MVP (uz personal)

> Asistent AI pentru macOS care stă lângă cursor, vede ecranul, te ascultă, îți răspunde cu voce
> și **arată cu cursorul** unde să apeși. Funcționalitate echivalentă cu HeyClicky, pentru un singur utilizator.

**Constrângeri:**
- Aplicație **personală**: nu se vinde, nu se distribuie, rulează doar pe Mac-ul meu.
- **Fără costuri fixe**: fără abonamente, fără cont Apple Developer plătit, fără servere.
- Singurul cost variabil: **creditele OpenRouter existente**, consumate doar când pun o întrebare.

Surse: blueprint-ul intern „Asistent Mac cu voce și ecran” (29.09.2026), pagina publică heyclicky.com
(prin recenzii și listări), plus repo-ul open-source al primei versiuni Clicky (`farzaa/clicky`, licență MIT).

---

## 1. Ce face HeyClicky și ce preluăm

| Funcție | Cum arată la ei | În MVP-ul Macky? |
|---|---|---|
| Push-to-talk global | Ții apăsat `Control + Option`, vorbești, eliberezi | **Da** |
| Vede ecranul | Screenshot la fiecare întrebare, toate monitoarele | **Da** |
| Răspuns vocal + text | Bulă de text lângă cursor + voce | **Da** |
| Arată cu cursorul | Un cursor animat „zboară” spre butonul corect | **Da**, funcția-vedetă |
| Conversație continuă | Ține minte replicile anterioare din sesiune | **Da** (în memorie, per sesiune) |
| Dictare | Vorbești și textul apare în aplicația activă | **Da** (gratuit, local) |
| Desen pe ecran | Cerc / săgeată / highlight peste o zonă | Parțial: highlight dreptunghi |
| Mod Agent („clicky agent”) | Face sarcini: cercetare, Notes/Calendar, click-uri | **Nu**, v2 |
| Planuri Free / Pro / Max | Cote și abonamente | **Nu e cazul**: uz personal |

Stack-ul lor: SwiftUI + AppKit, ScreenCaptureKit, Claude, AssemblyAI (plătit), ElevenLabs (plătit),
proxy Cloudflare. **Noi înlocuim tot ce e plătit** cu echivalente locale, mai puțin modelul AI, care trece prin OpenRouter.

---

## 2. Decizii de arhitectură

### 2.1 Aplicația Mac: Swift nativ (SwiftUI + AppKit), fără backend
- Menu bar only (`LSUIElement = true`), macOS **14.2+**. Recomandat Apple Silicon (pentru transcrierea locală).
- **Fără server/proxy.** Proxy-ul exista la Clicky ca să ascundă cheile de utilizatori. Aici singurul
  utilizator ești tu, deci aplicația apelează direct OpenRouter. Cheia se introduce o dată în Setări și
  se păstrează în **Keychain**. Nu apare în cod, nu intră în repo.

### 2.2 Modelul AI: OpenRouter ca furnizor principal, cu abstracție de provider
OpenRouter expune un API compatibil OpenAI (`/api/v1/chat/completions`), cu streaming SSE,
imagini și tool calling, și dă acces la Claude, Gemini, GPT, Qwen etc. **din aceleași credite**.

```swift
protocol LLMProvider {
    func streamResponse(messages: [ChatMessage], screenshots: [CapturedScreen],
                        tools: [ToolDefinition]) -> AsyncThrowingStream<LLMEvent, Error>
}
// OpenRouterProvider  (implicit)
// AnthropicProvider   (opțional, dacă vreodată ai cheie Anthropic directă)
```

- **Modelul se alege din Setări** (listă luată din `GET /api/v1/models`, filtrată pe modele cu
  suport de imagine). Setări separate pentru „model rapid” (întrebări obișnuite) și „model puternic”
  (comutat din panou sau prin comandă vocală).
- Recomandare de pornire: un model Claude Sonnet prin OpenRouter pentru calitate + un model Gemini Flash
  pentru cost mic; le comparăm în Etapa 3 pe precizia pointing-ului. Se pot testa și modelele `:free`
  de pe OpenRouter (au limite stricte de rată, deci doar ca rezervă).
- **Controlul costului:** screenshot redimensionat (latura maximă ~1280 px), doar monitorul activ implicit,
  istoric de conversație scurtat la ultimele N replici, afișarea costului per răspuns
  (OpenRouter îl raportează în `usage`) și total pe sesiune în panou.

### 2.3 Vocea: totul local și gratuit
Pipeline: `mic (AVAudioEngine) → transcriere locală → model AI prin OpenRouter (text + screenshot, streaming)
→ voce locală, pe propoziții → redare + animație cursor`.

| Verigă | Principal (gratuit) | Rezervă |
|---|---|---|
| Speech-to-text | **WhisperKit** (Whisper rulat local pe Apple Silicon, MIT, știe română) | Apple Speech (`SFSpeechRecognizer`) |
| Text-to-speech | **`AVSpeechSynthesizer`** cu o voce „Enhanced/Premium” descărcată gratuit din Setări macOS (ex. Ioana pentru română) | voci locale Piper (v2) |

- WhisperKit: model `small` sau `base` pentru viteză; se descarcă o singură dată (~250–500 MB).
- Push-to-talk înseamnă transcriere pe bucata înregistrată la eliberarea tastei, deci nu e nevoie de streaming STT.
- Vocea pornește pe **prima propoziție completă** din stream, nu după tot răspunsul.
- Țintă latență: < 2 s de la eliberarea tastei până la primul sunet.

### 2.4 Pointing: coordonate din viziune, „lipite” de elemente reale prin Accessibility
1. Capturăm monitorul (sau monitoarele), redimensionăm și **păstrăm metadatele**: `display_id`,
   originea globală, bounds, scale factor (Retina), dimensiunea trimisă modelului.
2. Modelul răspunde cu text vorbit + tool call `point_at({screen, x, y, label})`.
   **Fallback** pentru modelele fără tool calling: un tag `[[point:screen,x,y,label]]` la finalul textului,
   eliminat înainte de a fi citit cu voce.
3. **Adaptor de coordonate per familie de model**: unele răspund în pixeli ai imaginii, altele
   (ex. Gemini) în coordonate normalizate 0–1000. Adaptorul normalizează totul în pixeli ai imaginii.
4. Transformare: pixel imagine → anulare redimensionare → punct în captură → punct global macOS → punct local overlay.
5. **Snap la element AX:** `AXUIElementCopyElementAtPosition` la punctul obținut. Dacă găsim buton/câmp/meniu,
   folosim bounds-urile lui reale și desenăm highlight. Dacă nu, rămânem la coordonata din viziune.
6. Cursorul Macky zboară pe o curbă Bézier, stă lângă țintă, apoi dispare. Dacă fereastra s-a mutat,
   indicația se **ascunde**, nu se desenează aproximativ.
7. **Ecran de calibrare** în Setări: o grilă cu ținte numerotate. Întrebi „arată-mi ținta 7” și vezi
   imediat cât de precis e modelul ales.

### 2.5 Semnare fără cont Apple Developer plătit
- Build din Xcode cu **Apple ID gratuit (Personal Team)** sau „Sign to Run Locally”. Pentru uz pe propriul Mac,
  nu e nevoie de notarizare.
- Problemă cunoscută: permisiunile macOS (Screen Recording, Accessibility) sunt legate de semnătură, iar
  semnătura ad-hoc se schimbă la fiecare build, deci ți le-ar cere din nou.
  **Soluție:** un certificat self-signed de tip „Code Signing” creat o singură dată în Keychain Access și
  folosit constant, plus un bundle ID fix. Scriptul și pașii intră în `docs/SETUP.md`.

### 2.6 Siguranță și confidențialitate
MVP-ul doar **observă și indică**: nu dă click și nu tastează în locul tău (excepție: dictarea, cerută explicit).
- Captură **doar la apăsarea hotkey-ului**, niciodată continuu, cu indicator vizibil.
- Audio și transcriere rămân **local**. Pe internet pleacă doar textul întrebării + screenshot-ul, spre OpenRouter.
- Opțiune în Setări: aplicații excluse de la captură (ex. manager de parole, aplicația băncii).
  ScreenCaptureKit permite excluderea ferestrelor lor din imagine.
- Textul de pe ecran e tratat ca date, nu ca instrucțiuni (regulă în system prompt).

---

## 3. Structura repo-ului

```
macky/
├── Macky.xcodeproj
├── Macky/
│   ├── App/             # MackyApp, AppDelegate, MenuBarController
│   ├── Core/            # SessionManager (state machine), ConversationStore, CostTracker
│   ├── AI/              # LLMProvider, OpenRouterProvider, AnthropicProvider, SSEParser,
│   │                    # PointingInstructionParser, CoordinateAdapters, SystemPrompt
│   ├── Voice/           # AudioRecorder, SpeechToText(+WhisperKit, AppleSpeech), SpeechOutput
│   ├── Screen/          # ScreenCaptureService, ScreenGeometry, AccessibilityInspector
│   ├── Overlay/         # OverlayPanel, CompanionCursorView, ResponseBubble, HighlightView
│   ├── Input/           # GlobalHotkeyMonitor (CGEvent tap), DictationTyper
│   ├── Settings/        # SettingsView, KeychainStore, ModelPicker, CalibrationView
│   └── Permissions/     # PermissionsManager + onboarding
├── MackyTests/          # geometrie Retina/multi-monitor, parsere, adaptoare coordonate, state machine
└── docs/                # MVP-PLAN.md, SETUP.md
```

Dependențe externe (Swift Package Manager, toate gratuite): **WhisperKit**. Restul e framework Apple.

---

## 4. Etapele de construcție

Estimări orientative pentru un developer cu experiență macOS.

### Etapa 0: Schelet (2 zile)
- Proiect Xcode menu bar-only, panou flotant non-activating, ecran de Setări cu cheia OpenRouter în Keychain.
- `OpenRouterProvider` cu streaming text; alegere model din listă.
- Semnare cu certificat self-signed stabil + `docs/SETUP.md`.
- **Criteriu:** scrii o întrebare în panou și primești răspunsul în stream; permisiunile rămân acordate între build-uri.

### Etapa 1: Voce (≈1 săptămână)
- Hotkey global `Control + Option` (CGEvent tap).
- Înregistrare microfon, transcriere WhisperKit, waveform live.
- Voce locală pe propoziții; o apăsare nouă sau butonul Stop întrerupe răspunsul curent.
- State machine: `idle → listening → transcribing → thinking → speaking → idle` (+ `error`).
- **Criteriu:** vorbești în română, auzi răspunsul în < 2–3 s, poți întrerupe fără răspuns dublat.

### Etapa 2: Ecranul (≈1 săptămână)
- ScreenCaptureKit la fiecare turn (monitorul cu cursorul; opțional toate), aplicații excluse.
- `ScreenGeometry` cu toate transformările + **teste unitare** (Retina 2x, monitor secundar la stânga/deasupra,
  scale diferit pe monitoare).
- `AccessibilityInspector`: aplicația activă, fereastra activă, element la poziție.
- Costul per răspuns afișat în panou.
- **Criteriu:** „ce e pe ecran?” în Chrome/Figma primește o descriere corectă.

### Etapa 3: Overlay și pointing (≈1,5 săptămâni) ⭐
- Panou transparent pe fiecare monitor, click-through, pe toate Spaces, nu fură focusul.
- Cursorul Macky, bulă de răspuns, animație Bézier, highlight pe bounds AX.
- Tool `point_at` + fallback cu tag + adaptoare de coordonate + suport pentru mai mulți pași.
- Ecranul de calibrare; comparăm 3–4 modele de pe OpenRouter pe precizie, viteză și cost.
- **Criteriu:** „unde export video?” în DaVinci/Figma: cursorul ajunge pe butonul corect,
  pe Retina și pe monitorul secundar.

### Etapa 4: Dictare și finisaje (≈3–4 zile)
- Mod dictare (alt hotkey): transcriptul WhisperKit se inserează în câmpul activ
  (pasteboard + `Cmd+V` simulat, cu restaurarea clipboard-ului). Fără AI, deci cost zero.
- Onboarding permisiuni, pornire la login, alegere voce și hotkey.

**Total MVP: aprox. 4–5 săptămâni** pentru un developer. Etapele 0–3 dau deja versiunea utilizabilă zilnic.

Am scos din planul inițial: backend-ul Cloudflare, conturile, cotele, analytics, notarizarea,
auto-update-ul și billing-ul. Nu au sens pentru uz personal.

---

## 5. După MVP (v2+)
1. **Mod Agent**: sarcini în fundal (cercetare, documente) cu progres și anulare.
2. **Acțiuni cu aprobare**: click/tastare prin AX, confirmare înainte de fiecare pas, verificare după.
3. **Integrări locale gratuite**: Calendar și Reminders prin EventKit, Notes prin AppleScript.
4. **Memorie** persistentă locală (SQLite), editabilă și ștergibilă.
5. Voci locale mai naturale (Piper), rutare automată între modelul rapid și cel puternic după tipul întrebării.

---

## 6. Riscuri principale
| Risc | Atenuare |
|---|---|
| Precizia pointing-ului variază mult între modele | Calibrare + comparație în Etapa 3; snap AX; nu arătăm dacă încrederea e mică |
| Consumul de credite OpenRouter | Imagine redimensionată, un singur monitor implicit, istoric scurtat, cost afișat per răspuns |
| Modele fără tool calling / cu alte convenții de coordonate | Fallback cu tag în text + adaptoare de coordonate testate |
| Vocea `AVSpeechSynthesizer` sună mai robotic decât ElevenLabs | Voci Premium gratuite din macOS; Piper local în v2 |
| Latența transcrierii locale pe Mac-uri mai vechi | Model Whisper mai mic; rezervă Apple Speech |
| Permisiunile resetate la fiecare build | Certificat self-signed stabil (secțiunea 2.5) |

---

## 7. Ce e nevoie înainte de cod
- Un **Mac** cu macOS 14.2+ (ideal Apple Silicon) și **Xcode** (gratuit din App Store).
- Un **Apple ID** oarecare (fără cont Developer plătit).
- **Cheia API OpenRouter** (se introduce în aplicație, nu în repo).
- Opțional: vocea „Ioana (Enhanced)” descărcată din System Settings → Accessibility → Spoken Content.
