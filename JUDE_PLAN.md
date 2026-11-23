# Oatmeal: Jude's all-in-one plan (2026-11-22)

Goal: one app to manage. Oatmeal (Jude's fork) gets BetterVoice's features, a free Clicky-style "Guide",
Journaling and Task Recording. Nirvana Wheel stays its own app. Resonant Community stays as it is for now.
Every change also updates Oatmeal's in-app descriptions, onboarding and guides, not just the feature.

## Keys (Jude's layout)
| Key | Does |
|---|---|
| Right ⌥ **tap once** | Start dictation (long, hands-free). Tap right ⌥ again to stop and type it |
| Right ⌥ **press and hold** | Short dictation: stops and types when you let go |
| Right ⌥ **double tap** | Journal recording: transcribed like dictation, but saved in **Journaling** (not typed) |
| Left ⌥ **hold + circle things** | BetterVoice dictation with circle-to-screenshot: every circle you draw captures the screen; text + screenshots are pasted together |
| fn ⌘ | Screen recording (Oatmeal Capture, unchanged) |
| fn Space | Screenshot (unchanged) |
(Old Oatmeal double-tap "hands-free" is replaced by the single tap.)

## New sections in the app
- **Keys**: every shortcut and what it does, in one place.
- **Screenshots**: every circle screenshot from left-⌥ dictation, with date, open, reveal, delete.
- **Journaling**: double-tap recordings with transcript, play, copy, delete.
- **Guide**: the free Clicky. Ask out loud or type a question about what's on screen; it answers and
  points at things. Thinks with Claude Code on Jude's plan (`claude -p`, like Oatmeal's notes), listens with
  Oatmeal's on-device speech, talks back with the Mac's built-in voice. No API keys, no AssemblyAI,
  no ElevenLabs, no Cloudflare (Cloudflare only hid API keys in Clicky; there are none here).
- **Tasks** (own section, 2026-11-23): Start task button, list of task recordings for b-roll, and during working hours from Jude's calendar (a calendar or event title he picks, repeats
  however the calendar repeats), Oatmeal asks "Are you working?". Yes = record screen + face only
  (no call, nobody else), saved as a task recording.

## Order
1. Build current Oatmeal from source, signed with "BetterVoice Local Signing" so permissions stick.
2. New key layout (right ⌥ tap / hold / double tap) + Journaling.
3. Left ⌥ circle dictation + Screenshots section (port from BetterVoice).
4. Keys section; update onboarding, descriptions, README.
5. Task Recording from calendar working hours.
6. Guide (free Clicky).
7. Remove `../clicky` (Jude said yes) once Guide works.

## Notes
- BetterVoice source: `../better-voice` (circle detection, capture, paste flow).
- Clicky source for the Guide idea: `../clicky` (MIT).
- Oatmeal needs macOS 26 + Xcode 26 + XcodeGen.
