# Macky — plan de implementare MVP

> Asistent AI pentru macOS care stă lângă cursor, vede ecranul, te ascultă, îți răspunde cu voce
> și **arată cu cursorul** unde să apeși. Funcționalitate echivalentă cu HeyClicky, identitate proprie.

Surse: blueprint-ul intern „Asistent Mac cu voce și ecran” (29.09.2026), pagina publică heyclicky.com
(prin recenzii și listări), plus repo-ul open-source al primei versiuni Clicky (`farzaa/clicky`, licență MIT).

---

## 1. Ce face HeyClicky (reperul nostru)

| Funcție | Cum arată la ei | În MVP-ul Macky? |
|---|---|---|
| Push-to-talk global | Ții apăsat `Control + Option`, vorbești, eliberezi | **Da** |
| Vede ecranul | Screenshot la fiecare întrebare, toate monitoarele | **Da** |
| Răspuns vocal + text | Bulă de text lângă cursor + voce (TTS) | **Da** |
| Arată cu cursorul | Un cursor animat „zboară” spre butonul corect | **Da** — funcția-vedetă |
| Conversație continuă | Ține minte replicile anterioare din sesiune | **Da** (în memorie, per sesiune) |
| Dictare | Vorbești și textul apare în aplicația activă | **Da** (simplu, fără AI) |
| Desen pe ecran | Cerc / săgeată / highlight peste o zonă | Parțial: highlight dreptunghi |
| Mod Agent („clicky agent”) | Face sarcini: cercetare, Notes/Calendar, click-uri | **Nu** — v2 |
| Planuri Free / Pro / Max | 25 talk + 25 agent gratis; $20; $100 | Doar cote simple — billing în v2 |

Stack-ul lor cunoscut: SwiftUI + AppKit, ScreenCaptureKit, Claude (viziune + raționament),
AssemblyAI (speech-to-text streaming), ElevenLabs (text-to-speech), un proxy Cloudflare Worker
care ține cheile API. Aplicația stă doar în menu bar (fără icon în Dock).

---

## 2. Decizii de arhitectură

### 2.1 Aplicația Mac: Swift nativ (SwiftUI + AppKit)
Tot ce contează aici e nativ: ScreenCaptureKit, Accessibility (AX), ferestre overlay care nu fură
focusul, hotkey global prin `CGEvent` tap. Electron/Tauri ar cere oricum bridge nativ pentru toate astea.
- macOS minim: **14.2** (ScreenCaptureKit modern).
- Tip aplicație: menu bar only (`LSUIElement = true`).

### 2.2 Vocea: STT → Claude → TTS (varianta B din blueprint), nu Realtime API
Blueprint-ul propune ca variantă A OpenAI Realtime. Pentru MVP recomand varianta B, cea pe care o folosește
și Clicky, pentru că:
- interacțiunea e **push-to-talk** (turn-uri clare), deci avantajul Realtime (întreruperi naturale, VAD) contează puțin;
- fiecare turn are nevoie de **screenshot + viziune + coordonate de pointing**, adică exact ce face bine un apel Claude cu imagine;
- fiecare verigă se poate testa și înlocui separat.

Pipeline: `mic (AVAudioEngine) → STT streaming (websocket) → transcript final la eliberarea tastei
→ Claude (text + screenshot, streaming SSE) → TTS pe propoziții → redare audio + animație cursor`.

Pentru latență: TTS pornește pe **prima propoziție completă** din stream, nu după tot răspunsul.
Țintă: < 1,5 s de la eliberarea tastei până la primul sunet.

Furnizori (fiecare în spatele unui protocol Swift, ca să poată fi schimbat):
- STT: AssemblyAI streaming (principal), Apple Speech (fallback offline/gratuit).
- LLM: Claude — Sonnet ca implicit (viteză/cost), Opus opțional pentru întrebări grele.
- TTS: ElevenLabs Flash (principal), `AVSpeechSynthesizer` (fallback).

### 2.3 Backend: proxy subțire, fără chei în aplicație
Cheile API **nu ajung niciodată** în aplicația distribuită. Un Cloudflare Worker (TypeScript) cu rute:

| Rută | Upstream | Rol |
|---|---|---|
| `POST /v1/chat` | Anthropic Messages API | viziune + streaming, system prompt ținut pe server |
| `POST /v1/tts` | ElevenLabs | audio pentru un fragment de text |
| `POST /v1/stt-token` | AssemblyAI | token efemer (~8 min) pentru websocket |
| `POST /v1/auth/device` | — | înregistrare dispozitiv anonim, emite token |

Plus: autentificare per dispozitiv, **cote lunare** (ex. 25 întrebări gratis) în Cloudflare KV/D1,
rate-limit, fără logare de imagini sau audio.

### 2.4 Pointing: coordonate din viziune, „lipite” de elemente reale prin Accessibility
Asta e diferențiatorul și partea cea mai delicată.
1. Capturăm fiecare monitor, redimensionăm la o latură maximă cunoscută și **păstrăm metadatele**:
   `display_id`, originea globală, bounds, scale factor (Retina), dimensiunea trimisă modelului.
2. Claude răspunde cu text vorbit + un **tool call structurat** `point_at({screen, x, y, label})`
   (mai robust decât taguri `[POINT:…]` parsate din text).
3. Transformare: pixel imagine → anulare redimensionare → punct în captură → punct global macOS → punct local overlay.
4. **Snap la element AX:** la punctul obținut interogăm `AXUIElementCopyElementAtPosition`; dacă găsim
   un buton/câmp/meniu, folosim centrul și bounds-urile lui reale (și desenăm highlight pe ele).
   Dacă aplicația nu expune AX, rămânem la coordonata din viziune.
5. Cursorul Macky zboară pe o curbă Bézier, stă lângă țintă, apoi dispare. Dacă fereastra s-a mutat
   sau a trecut prea mult timp, **ascundem** indicația în loc să o desenăm aproximativ.

### 2.5 Siguranță (din blueprint, nivelurile 0–1)
MVP-ul doar **observă și indică** — nu dă click, nu tastează în locul utilizatorului (cu excepția dictării cerute explicit).
- Permisiuni cerute contextual, cu explicație: Microfon, Screen Recording, Accessibility.
- Captură **doar la apăsarea hotkey-ului**, niciodată continuu; indicator vizibil când se capturează.
- Nu stocăm audio brut sau screenshot-uri; transcriptul sesiunii stă în memorie.
- Textul de pe ecran e tratat ca date, nu ca instrucțiuni (regulă în system prompt).

---

## 3. Structura repo-ului

```
macky/
├── mac-app/                 # proiect Xcode (SwiftUI + AppKit)
│   └── Macky/
│       ├── App/             # MackyApp, AppDelegate, MenuBarController
│       ├── Core/            # SessionManager (state machine), ConversationStore
│       ├── Voice/           # AudioCapture, STTProvider(+AssemblyAI, AppleSpeech), TTSProvider(+ElevenLabs, System)
│       ├── Screen/          # ScreenCaptureService, ScreenGeometry, AccessibilityInspector
│       ├── Overlay/         # OverlayPanel, CompanionCursorView, ResponseBubble, HighlightView
│       ├── Input/           # GlobalHotkeyMonitor (CGEvent tap), DictationTyper
│       ├── AI/              # MackyAPIClient (SSE), ToolCallParser
│       ├── Permissions/     # PermissionsManager + onboarding
│       └── UI/              # PanelView, Settings, DesignSystem
│   └── MackyTests/          # geometrie Retina/multi-monitor, parser, state machine
├── backend/                 # Cloudflare Worker (TypeScript, Hono)
│   ├── src/routes/          # chat, tts, stt-token, auth
│   ├── src/prompts/         # system prompt + definiția tool-ului point_at
│   └── test/
├── shared/contracts/        # schema JSON pentru tool calls și evenimente SSE
└── docs/
```

---

## 4. Etapele de construcție

Estimările sunt pentru un developer iOS/macOS cu experiență, orientative.

### Etapa 0 — Schelet (2–3 zile)
- Proiect Xcode menu bar-only, icon în status bar, panou flotant non-activating.
- Worker Cloudflare cu `/v1/chat` funcțional (text simplu), secrete configurate.
- **Criteriu:** aplicația pornește/se închide, trimite o întrebare text și primește răspuns în stream, fără nicio cheie API în binar.

### Etapa 1 — Voce (≈1 săptămână)
- Hotkey global `Control + Option` (CGEvent tap), configurabil ulterior.
- Captură microfon, STT streaming cu token efemer, waveform live.
- TTS pe propoziții, redare, buton Stop / apăsare nouă = întrerupe răspunsul curent.
- State machine: `idle → listening → thinking → speaking → idle` (+ `error`, `offline`).
- **Criteriu:** vorbești, auzi răspunsul în < 2 s, poți întrerupe fără răspuns dublat.

### Etapa 2 — Ecranul (≈1 săptămână)
- ScreenCaptureKit pe toate monitoarele la fiecare turn; imaginea monitorului cu cursorul primește prioritate.
- `ScreenGeometry` cu toate transformările de coordonate + **teste unitare** (Retina 2x, monitor secundar
  la stânga/deasupra, scale diferit pe monitoare).
- `AccessibilityInspector`: aplicația activă, fereastra activă, element la poziție.
- **Criteriu:** întrebi „ce e pe ecran?” în Chrome/Figma și răspunsul descrie corect ce vezi.

### Etapa 3 — Overlay și pointing (≈1,5 săptămâni) ⭐
- Panou transparent full-screen pe fiecare monitor, click-through, pe toate Spaces, nu fură focusul.
- Cursorul Macky (identitate vizuală proprie), bulă de răspuns, animație Bézier, highlight pe bounds AX.
- Tool `point_at` în backend + parser în app; suport pentru mai mulți pași („apasă aici, apoi aici”).
- Invalidare indicație la mutarea ferestrei / schimbarea monitorului / timeout.
- **Criteriu:** „unde export video în DaVinci/Figma?” → cursorul ajunge pe butonul corect, pe Retina și pe monitorul secundar.

### Etapa 4 — Dictare + polish (≈1 săptămână)
- Mod dictare (alt hotkey): transcriptul se inserează în câmpul activ (pasteboard + `Cmd+V` simulat, cu restaurarea clipboard-ului).
- Onboarding permisiuni pas cu pas, ecran de setări (hotkey, voce, model, pornire la login).
- Stări de eroare clare: fără internet, permisiune refuzată, cotă epuizată.

### Etapa 5 — Lansare beta (≈1 săptămână)
- Cote Free în backend (identitate dispozitiv), analytics minimale și anonime (PostHog, fără conținut).
- Semnare Developer ID, **notarizare Apple**, DMG, auto-update cu Sparkle.
- Landing page simplă + formular de feedback.

**Total MVP: aprox. 6–7 săptămâni** pentru un developer. Un demo intern (etapele 0–3) e posibil în ~4 săptămâni.

---

## 5. După MVP (v2+)
1. **Mod Agent**: joburi în fundal (cercetare, documente) cu coadă, progres, anulare, card de rezultat.
2. **Acțiuni pe ecran cu aprobare** (nivelul 2–3 din blueprint): click/tastare prin AX, confirmare înainte de fiecare pas, re-observare după acțiune.
3. **Integrări** OAuth (Calendar, Notes, Gmail, Drive) cu scope minim; read / draft / send separate.
4. **Memorie** persistentă, editabilă și ștergibilă; istoric conversații.
5. **Billing** (Stripe) cu planuri Free / Pro / Max, cont de utilizator.
6. Opțional: voce realtime (speech-to-speech) pentru conversații libere, fără push-to-talk.

---

## 6. Riscuri principale
| Risc | Atenuare |
|---|---|
| Precizia pointing-ului în aplicații fără AX (DaVinci, jocuri, canvas) | Snap AX unde se poate; crop + a doua trecere de viziune pe zona țintă; nu arătăm dacă încrederea e mică |
| Latență mare (3 servicii în lanț) | Streaming peste tot, TTS pe propoziții, conexiuni pre-încălzite, model rapid implicit |
| Cost per întrebare (imagine + TTS) | Screenshot redimensionat, cote, cache pentru system prompt |
| Permisiunile macOS (TCC) resetate la fiecare build nesemnat | Semnare consecventă de la început, un singur bundle ID |
| Confidențialitate | Captură doar la cerere, nimic stocat pe server, politică clară în onboarding |

---

## 7. Ce e nevoie de la tine înainte de cod
- Un **Mac** cu macOS 14.2+ și Xcode 16+ (aplicația nu se poate compila/testa în afara macOS).
- Cont **Apple Developer** ($99/an) pentru semnare și notarizare.
- Chei API: Anthropic, AssemblyAI, ElevenLabs; cont Cloudflare (gratuit e suficient la început).
- Decizie: pornim de la zero sau pornim de la codul open-source Clicky (MIT, permite reutilizarea cu păstrarea
  notei de copyright) și îl rescriem progresiv? Recomandarea mea: **de la zero, cu Clicky ca referință**:
  arhitectura de mai sus e mai curată (tool calls structurate, snap AX, geometrie testată), iar brandingul trebuie oricum să fie complet al nostru.
