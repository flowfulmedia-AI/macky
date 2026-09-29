# Instalare și configurare Macky

## 1. Ce îți trebuie

- macOS 14.2 sau mai nou. Un Mac cu Apple Silicon (M1 sau mai nou) e recomandat pentru transcrierea locală.
- **Xcode** din App Store (gratuit). După instalare, deschide-l o dată ca să termine configurarea.
- **Homebrew**: https://brew.sh
- O cheie **OpenRouter**: https://openrouter.ai/settings/keys

## 2. Compilare și instalare

```bash
make setup
make run
```

`make setup` face trei lucruri:
1. verifică Xcode;
2. instalează `xcodegen`, care generează proiectul Xcode din `project.yml`;
3. creează certificatul gratuit **„Macky Local Signing”** în Keychain. macOS îți cere parola: e normal,
   certificatul trebuie marcat ca de încredere pentru semnare.

`make run` compilează în modul Release, copiază aplicația în `~/Applications/Macky.app` și o pornește.
La prima compilare se descarcă WhisperKit, deci durează câteva minute.

> **De ce certificat?** macOS leagă permisiunile (microfon, ecran, accesibilitate) de semnătura aplicației.
> Cu o semnătură stabilă le acorzi o singură dată; fără ea ți le-ar cere din nou după fiecare build.

## 3. Prima pornire

Iconița Macky (o săgeată cu raze) apare în bara de meniu, sus-dreapta. Panoul se deschide singur cu o listă de pași:

1. **Cheia OpenRouter**: Setări → AI → lipește cheia → Salvează. Butonul „Verifică” îți arată creditele rămase.
2. **Microfon**: apare fereastra de sistem; apasă Allow.
3. **Înregistrare ecran**: se deschide System Settings → activează Macky. **Apoi apasă „Repornește”** în panou
   (macOS aplică permisiunea doar după repornire).
4. **Accesibilitate**: activează Macky în System Settings. E necesară pentru indicarea precisă și pentru dictare.
5. **Monitorizare tastatură (Input Monitoring)**: activează Macky. E necesară pentru scurtătura ⌃⌥.

La prima utilizare se descarcă modelul Whisper (~480 MB pentru „Small”). Panoul arată cât timp se pregătește.

## 4. Alegerea modelelor

Setări → AI → Modele. Lista conține doar modelele OpenRouter care văd imagini, cu prețul lor.
Macky alege singur, la prima pornire, cel mai nou Gemini Flash ca model „Rapid” și cel mai nou Claude Sonnet ca „Puternic”.

Ca să compari precizia cu care arată, deschide **Calibrare** din panou:
1. alege modelul;
2. apasă „Testează 5 ținte”;
3. citește eroarea medie în puncte. Sub ~15 e foarte bine, iar peste ~40 modelul ratează butoanele mici.

Dacă un model arată constant pe lângă, încearcă altă setare la **Setări → AI → Coordonate** (pixeli sau normalizat 0–1000).

## 5. Vocea

- Setări → Voce → **Model Whisper**: „Large v3 Turbo” înțelege cel mai bine româna; „Small” e mai rapid.
- Pentru o voce naturală a lui Macky: System Settings → Accessibility → Spoken Content → System Voice →
  Manage Voices → descarcă **Ioana (Enhanced)**, apoi alege-o în Setări → Voce.

## 6. Probleme frecvente

| Problemă | Rezolvare |
|---|---|
| ⌃⌥ nu face nimic | Verifică Input Monitoring în System Settings. Dacă tocmai l-ai activat, așteaptă 2 secunde sau repornește Macky. |
| „Macky nu are permisiunea Screen Recording” deși ai dat-o | Repornește Macky (butonul din panou sau `make run`). |
| Permisiunile se cer din nou după fiecare build | Certificatul lipsește: rulează `make setup`. Dacă persistă, scoate Macky din listele din System Settings și adaug-o din nou. |
| Cursorul arată puțin pe lângă | Acordă Accessibility (activează „lipirea” de butoane) și rulează Calibrarea pentru model. |
| „Cheia OpenRouter nu e validă” | Setări → AI → Verifică cheia. Generează una nouă pe openrouter.ai dacă e nevoie. |
| Compilarea eșuează | Vezi `build/xcodebuild.log` și trimite-mi primele erori. |

## 7. Lucru în Xcode

```bash
make open   # generează și deschide Macky.xcodeproj
```

Proiectul `.xcodeproj` nu se salvează în git; se regenerează din `project.yml`.
