# smplr

record a stereo take and play it back with up to six playheads.

![smplr](smplr.png)

smplr records the stereo input into softcut and plays it back with up to six heads. each head has its own loop, pitch, volume, pan, direction, highpass filter and modulator. hold K2 while playing to punch new material in at the selected head. the take and all settings are saved automatically and come back at the next start.

## requirements

- norns or a norns clone (tested on a shieldXL, Raspberry Pi 4, norns 2.9.4)
- stereo audio input

## documentation

### controls

| control | action |
|---|---|
| E1 | select head (top to bottom, as on screen) |
| K1 + E1 | edit mode: LOOP, SOUND, MOD, VIEW |
| K2 (stopped) | start / stop recording |
| K2 (stopped, hold 1 s) | empty take of `max length`, to punch into |
| K2 (playing, hold) | punch in at the selected head |
| K3 | play / stop |
| K1 + K2 | randomize (depends on the edit mode) |
| K1 + K3 | toggle (depends on the edit mode) |

### edit modes

| mode | E2 | E3 | K1 + K2 | K1 + K3 |
|---|---|---|---|---|
| LOOP | loop start (or move loop) | loop end | random loop | E2: start / move |
| SOUND | pick: pitch, volume, pan, mode, hpf | change | random sound | reverse / forward / muted |
| MOD | pick: target, shape, speed, amount | change | random modulator | target: off / head / loop |
| VIEW | zoom | scroll | zoom to the selected loop | zoom off / on |

hold K1 to see the current mode.

### heads

softcut has six voices. a head's `source` is `left` or `right` (one voice, plays buffer 1 or 2) or `both` (two voices, plays the stereo take). so six heads fit as 6 mono, 1 stereo + 4 mono, 2 stereo + 2 mono or 3 stereo. a new recording resets every head: only H1 is on, a stereo head over the whole take. turn on more heads in PARAMS > HEAD 2–6 > source.

on screen, stereo heads' loop bars sit above both waveforms, mono heads' bars below their buffer's waveform. the selected head's bar is bright.

### modulator

each head has a modulator (sine, saw, triangle or random, 0.01–10 Hz):

- **loop**: moves the whole loop window back and forth
- **head**: makes the playhead jump around inside the loop

### params

- **SMPLR**: `max length` (1–300 s, default 20 s), `loop length` (info), `E2` (loop start / move loop)
- **HEAD 1–6**: source, start, end, mode, pitch (±24 semitones), volume, pan, hpf (off, 20 Hz – 4 kHz), mod target, shape, speed, amount

### files

- `dust/audio/smplr/loop.wav`: the take
- `dust/data/smplr/last.pset`: the params, written on exit

## install

```
;install https://github.com/<user>/smplr
```

or copy `smplr.lua` to `dust/code/smplr/`.
