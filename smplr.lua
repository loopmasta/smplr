-- smplr v0.3.0 by loopmasta
-- |...       |...     ||..      ||   |...
-- |||||:|:-----|||||||:---|||||||:----||||||:|||||||-
-- |'''       |'''     ||''      ||   |'''
--                   ---------
-- |.        |...     ||..      |...  |...
-- ||||||:|-----||||||----|||||||:----||||||-||||||-
-- |'        |'''     ||''      |'''  |'''

-- only for the transient analysis (lib/Engine_Smplr.sc); the sound is softcut
engine.name = "Smplr"

local START = 1             -- recording start in the buffers (s); room for pre-roll
local MAX_LENGTH_LIMIT = 300 -- upper end of the "max length" param (s);
                             -- a softcut buffer holds ~349 s
local FADE = 0.05            -- crossfade / level fade time (s)
local CANVAS_HOLD = 1        -- K2 held this long while stopped: an empty take instead (s)
local FPS = 30               -- screen and playhead updates
local MIN_LOOP = 0.05        -- shortest head loop (s)
local MAX_PITCH = 24         -- ± semitones (speed 1/4..4)
local RANDOM_LEVEL = {0.1, 0.6} -- volume range for K1 + K2, kept low against clipping
-- highpass on each head's output; at HP_OFF it's off (dry)
local HP_OFF, HP_MAX = 20, 4000 -- Hz
local HP_RQ = 1.4 -- 1/Q: Q 0.7, a plain 12 dB/oct slope (softcut's default rq 4 is very soft)

-- head mode: direction or muted, in the order K1 + K3 cycles through them
local REVERSE, FORWARD, MUTED = 1, 2, 3
-- what LOOP's E2 / E3 do to the selected head's loop: resize it (E2 its
-- start, E3 its end) or move it, the length kept (both); one setting for
-- all heads, toggled with a long K1 + K3
local RESIZE, MOVE = 1, 2
local LONG_PRESS = 0.5 -- K1 + K3 held this long in LOOP: resize <-> move (s)
local WINDOW_STEP = 0.005 -- start / end change per encoder step (fraction of the recording)

-- voices 1 (buffer 1, input L) and 2 (buffer 2, input R) make new recordings
local REC_VOICES = {1, 2}

-- 6 heads, H1..H6, each with a source: left / right is a MonoHead on
-- buffer 1 / 2 (one voice), both is a StereoHead (two voices), off isn't
-- shown and doesn't play (see build_heads); voices go to the heads in
-- number order. A source that needs more voices than softcut
-- has free is skipped: the param moves on in the turning direction to
-- the next source that fits. (off is last so saved PSETs from before it
-- existed stay valid.)
local LEFT, RIGHT, BOTH, OFF = 1, 2, 3, 4
local SOURCE_NAMES = {"left", "right", "both", "off"}
-- default layout: one StereoHead, the other slots off (a new recording
-- goes back to it)
local SOURCE_DEFAULTS = {BOTH, OFF, OFF, OFF, OFF, OFF}

-- per head defaults (every head setting goes back to its default after
-- each new recording): all forward, unchanged, so they sound like the
-- input; H1 over the whole recording, the others (once given a source)
-- on the middle and last third (H6 the first third)
local HEAD_DEFAULTS = {
  {start = 0,     stop = 1,     mode = FORWARD, pitch = 0, volume = 1, pan = 0},
  {start = 1 / 3, stop = 2 / 3, mode = FORWARD, pitch = 0, volume = 1, pan = 0},
  {start = 2 / 3, stop = 1,     mode = FORWARD, pitch = 0, volume = 1, pan = 0},
  {start = 1 / 3, stop = 2 / 3, mode = FORWARD, pitch = 0, volume = 1, pan = 0},
  {start = 2 / 3, stop = 1,     mode = FORWARD, pitch = 0, volume = 1, pan = 0},
  {start = 0,     stop = 1 / 3, mode = FORWARD, pitch = 0, volume = 1, pan = 0},
}
-- highpass defaults
local HP_DEFAULTS = {HP_OFF, HP_OFF, HP_OFF, HP_OFF, HP_OFF, HP_OFF}
local HEADS = #HEAD_DEFAULTS

-- modulator per head, with a target:
--   loop: moves the whole loop (start and end, the length stays) around
--     the window set with E2 / E3, inside the recording; amount is the
--     full swing as a fraction of the recording
--   head: the loop stays; the playhead jumps to where the modulator
--     points inside the loop; amount is the full swing as a fraction of
--     the loop
-- target off switches it off. saw rises through the cycle and jumps back;
-- random jumps to a new spot once per cycle.
local SINE, SAW, TRIANGLE, RANDOM = 1, 2, 3, 4
local MOD_SHAPES = {"sine", "saw", "triangle", "random"}
local MOD_OFF, MOD_LOOP, MOD_HEAD = 1, 2, 3
local MOD_TARGETS = {"off", "loop", "head"}
local MOD_AMOUNT = 0.25 -- default amount, used once the target isn't off
local MOD_SPEED_MIN, MOD_SPEED_MAX = 0.01, 10 -- Hz
local MOD_EVERY = 2 -- update the modulators every 2nd frame (15 Hz)

-- screen: two lanes, buffer 1 on top, buffer 2 below, full width and
-- height. The layout follows the heads (see layout()).
local GRAPH_X, GRAPH_W = 0, 128
local SCREEN_H = 64
local BAR_PITCH = 2 -- loop bars: 1 px bar, 1 px gap
local GRAPH_LEVEL = 6 -- waveform brightness
local RENDER_EVERY = 2 -- while the buffer is written, re-render every 2nd frame

local state = "empty" -- "empty" | "busy" | "recording" | "stopped" | "playing"
local length = 0      -- recording length (s)
local max_length = 20 -- read from params when a recording starts
local rec_start_time
local rec_clock       -- auto-stop at max_length

-- heads by number (h), nil while the source is off. Each: kind
-- ("stereo" / "mono"), buffer (mono), voices, and its loop window and
-- playhead in s from START; sign is the direction, 1 or -1 (a muted head
-- keeps the one it had)
local heads = {}
local order = {}      -- head numbers in E1 order, top to bottom as on screen
local voice_head = {} -- voice -> head number, for the phase poll
local sources = {}    -- accepted source per head, to skip what doesn't fit
local selected = 1    -- head number
local alt = false     -- K1 held
-- edit modes (K1 + E1). LOOP works directly (E2 start / move, E3 end),
-- free or from transient to transient (K1 + K3); the others are small
-- lists over the waveform: E2 picks a setting of the selected head, E3
-- changes it, and a popup shows its name and value
local LOOP = 1
local MODES = {
  {name = "LOOP"},
  {name = "SOUND", items = {{"pitch", "pitch"}, {"volume", "volume"}, {"pan", "pan"}, {"mode", "mode"}, {"hpf", "hp"}}},
  {name = "MOD", items = {{"target", "mod_target"}, {"shape", "mod_shape"}, {"speed", "mod_speed"}, {"amount", "mod_amount"}}},
  {name = "VIEW"}, -- direct too: E2 zoom, E3 scroll
}
local VIEW = 4
-- LOOP's E2 / E3: free (fine steps) or jumping between the transients
-- (one setting for all heads)
local FREE, TRANSIENT = 1, 2
local edit_mode = LOOP     -- smplr always starts in LOOP
local picked = {}          -- per list mode: the setting E2 picked
local POPUP_TIME = 2       -- s the mode name / setting popup stays after the last turn
local note, note_until = nil, 0
local punch           -- head number punching in (K2 held while playing), or nil
local canvas_clock    -- turns the recording into an empty take if K2 is still held
local loop_press_clock -- LOOP: K1 + K3 held; toggles resize / move once LONG_PRESS is up

local waveform = {}   -- one column per pixel, each {buffer 1, buffer 2} peak 0..1
local render_start, render_dur = 0, 0 -- the span (s, buffer time) the waveform covers
-- the visible part of the recording (VIEW mode zooms and scrolls it):
-- view_dur s from view_from s; the whole recording is 0, length
local view_from, view_dur = 0, 0
local view_changed = false   -- the view moved: render it on the next frame
local VIEW_MIN = 0.1         -- shortest visible span (s)
local ZOOM_STEP = 2 ^ (1 / 4) -- zoom per E2 step (4 steps double it)
local SCROLL_STEP = 1 / 32   -- scroll per E3 step, as a fraction of the view
local frame = 0
local redraw_metro

local voices_on = false -- play / rec flags of the head voices
local stop_clock        -- switches the voices off once playback has faded out

-- transients of the take (s from its start, ascending), found by the
-- engine after every new take and punch-in; LOOP in transient jumps
-- between them
local onsets = {}
local analysis = 0        -- number of the latest analysis; older answers are dropped
local analysing = false
local analyse_clock       -- a sensitivity change waits for the encoder to settle
local ONSET_EDGE = 0.02   -- transients closer to the take's start are dropped (s)
local SAMPLE_RATE = 48000 -- softcut's
-- sensitivity 0..100 % sets the Onsets threshold, 1 .. 0.05 on an
-- exponential scale; 40 % is 0.3: clear hits, not every grain
local SENSITIVITY_DEFAULT = 40
local THRESHOLD_MAX, THRESHOLD_MIN = 1, 0.05

-- saved state: the recording and its length and transients after each
-- take, the params (with the head sources) on exit
local AUDIO_DIR = _path.audio .. "smplr/"
local function audio_file() return AUDIO_DIR .. "loop.wav" end
local function take_file() return norns.state.data .. "take.lua" end
local function pset_file() return norns.state.data .. "last.pset" end
local function onsets_file(n) return "/tmp/smplr-onsets-" .. n .. ".txt" end

local stop_recording
local stop_punch

local function param_id(h, name)
  return "head" .. h .. "_" .. name
end

local function muted(h)
  return params:get(param_id(h, "mode")) == MUTED
end

local function loop_fade(len)
  return math.min(FADE, len / 4)
end

local function voices_needed(source)
  return source == BOTH and 2 or source == OFF and 0 or 1
end

-- a voice plays one buffer and records the matching input channel
local function route_voice(v, buffer)
  softcut.buffer(v, buffer)
  softcut.level_input_cut(1, v, buffer == 1 and 1 or 0)
  softcut.level_input_cut(2, v, buffer == 1 and 0 or 1)
end

-- heads from the source params, voices handed out in number order. The
-- E1 order is the screen order from top to bottom: StereoHeads, MonoHeads
-- on buffer 1, MonoHeads on buffer 2, each by number. A head keeps its
-- window, playhead and direction; if the selected head is gone, the
-- first one is selected.
local function build_heads()
  local old, v = heads, 1
  heads, order, voice_head = {}, {}, {}
  for h = 1, HEADS do
    local source = params:get(param_id(h, "source"))
    if source ~= OFF then
      local o = old[h] or {s = 0, e = 0, pos = 0, sign = 1, mod = 0, phase = 0}
      local hd = {s = o.s, e = o.e, pos = o.pos, sign = o.sign, mod = o.mod, phase = o.phase}
      if source == BOTH then
        hd.kind, hd.voices = "stereo", {v, v + 1}
        route_voice(v, 1)
        route_voice(v + 1, 2)
      else
        hd.kind, hd.buffer, hd.voices = "mono", source, {v}
        route_voice(v, source)
      end
      for _, vc in ipairs(hd.voices) do voice_head[vc] = h end
      v = v + voices_needed(source)
      heads[h] = hd
      table.insert(order, h)
    end
  end
  local function rank(h) return heads[h].kind == "stereo" and 0 or heads[h].buffer end
  table.sort(order, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    return a < b
  end)
  if not heads[selected] then selected = order[1] or 1 end
end

-- voices -------------------------------------------------------------------

-- rec stays on with play (at rec_level 0): softcut only advances a voice's
-- write position while it records, so a punch-in would otherwise land
-- where the voice last jumped, not where it plays
local function set_play(on)
  voices_on = on
  for _, hd in pairs(heads) do
    for _, v in ipairs(hd.voices) do
      softcut.play(v, on and 1 or 0)
      softcut.rec(v, on and 1 or 0)
    end
  end
end

local function set_rec_flags(voices, on)
  for _, v in ipairs(voices) do softcut.rec(v, on and 1 or 0) end
end

-- rec 1 / pre 0 replaces the buffer, rec 0 / pre 1 keeps it; both slew over FADE
local function set_rec_levels(voices, rec, pre)
  for _, v in ipairs(voices) do
    softcut.rec_level(v, rec)
    softcut.pre_level(v, pre)
  end
end

-- output levels, slewed over FADE
local function set_out(on)
  for h, hd in pairs(heads) do
    local level = (on and not muted(h)) and params:get(param_id(h, "volume")) or 0
    for _, v in ipairs(hd.voices) do softcut.level(v, level) end
  end
end

local function setup_voices()
  softcut.reset()
  softcut.buffer_clear()
  audio.level_cut(1)
  audio.level_adc_cut(1)
  audio.level_eng_cut(0)

  for v = 1, softcut.VOICE_COUNT do
    local left = v % 2 == 1
    softcut.enable(v, 1)
    softcut.buffer(v, left and 1 or 2)
    softcut.pan(v, left and -1 or 1)
    softcut.rate(v, 1)
    softcut.loop(v, 1) -- crossfaded looping
    softcut.loop_start(v, START)
    softcut.loop_end(v, START + max_length)
    softcut.position(v, START)
    softcut.fade_time(v, FADE)
    softcut.level_slew_time(v, FADE)
    softcut.recpre_slew_time(v, FADE)
    softcut.rate_slew_time(v, 0)
    softcut.level(v, 0)
    softcut.rec_level(v, 0)
    softcut.pre_level(v, 1)
    softcut.play(v, 0)
    softcut.rec(v, 0)
    -- no filtering: the default pre filter is a lowpass (rq 4, fc 16 kHz)
    -- that audibly darkens recordings
    softcut.pre_filter_dry(v, 1)
    softcut.pre_filter_lp(v, 0)
    softcut.pre_filter_hp(v, 0)
    softcut.pre_filter_bp(v, 0)
    softcut.pre_filter_br(v, 0)
    softcut.post_filter_dry(v, 1)
    softcut.post_filter_lp(v, 0)
    softcut.post_filter_hp(v, 0)
    softcut.post_filter_bp(v, 0)
    softcut.post_filter_br(v, 0)
    -- input L -> buffer 1 voices, input R -> buffer 2 voices
    softcut.level_input_cut(1, v, left and 1 or 0)
    softcut.level_input_cut(2, v, left and 0 or 1)
    softcut.phase_quant(v, 1 / FPS)
  end

  softcut.event_phase(function(v, pos)
    local h = voice_head[v]
    -- a head's playhead follows its first voice
    if h and heads[h].voices[1] == v then heads[h].pos = pos - START end
  end)
  softcut.poll_start_phase()
end

-- heads --------------------------------------------------------------------

-- loop window in s from START, inside the recording, at least MIN_LOOP long
local function head_window(h)
  local s = params:get(param_id(h, "start")) * length
  local e = params:get(param_id(h, "stop")) * length
  e = math.min(length, math.max(e, s + MIN_LOOP))
  return math.max(0, math.min(s, e - MIN_LOOP)), e
end

-- the window moved by the modulator (hd.mod, -1..1), kept inside the recording
local function mod_target(h)
  return params:get(param_id(h, "mod_target"))
end

-- the window, moved by the modulator (hd.mod, -1..1) if it targets the
-- loop, kept inside the recording
local function mod_window(h)
  local s, e = head_window(h)
  if mod_target(h) ~= MOD_LOOP then return s, e end
  local shift = heads[h].mod * params:get(param_id(h, "mod_amount")) * length / 2
  shift = util.clamp(shift, -s, length - e)
  return s + shift, e + shift
end

-- push a head's window and rate to its voices; only once there is a
-- recording, never while recording
local function apply_head(h)
  if (state ~= "stopped" and state ~= "playing") or not heads[h] then return end
  local hd = heads[h]
  hd.s, hd.e = mod_window(h)
  local mode = params:get(param_id(h, "mode"))
  if mode ~= MUTED then hd.sign = mode == FORWARD and 1 or -1 end
  local rate = hd.sign * 2 ^ (params:get(param_id(h, "pitch")) / 12)
  local out_of_window = hd.pos < hd.s or hd.pos > hd.e
  if out_of_window then hd.pos = rate > 0 and hd.s or hd.e end
  for _, v in ipairs(hd.voices) do
    softcut.loop_start(v, START + hd.s)
    softcut.loop_end(v, START + hd.e)
    softcut.fade_time(v, loop_fade(hd.e - hd.s))
    softcut.rate(v, rate)
    if out_of_window then softcut.position(v, START + hd.pos) end -- crossfades
  end
end

-- stereo pan: at 0 the head is full stereo; towards +1 its left voice
-- moves right until both are hard right (the same mirrored towards -1)
-- a MonoHead's voice is simply panned
local function apply_pan(h)
  local hd = heads[h]
  if not hd then return end
  local p = params:get(param_id(h, "pan"))
  if hd.kind == "mono" then
    softcut.pan(hd.voices[1], p)
  else
    softcut.pan(hd.voices[1], math.min(1, -1 + 2 * math.max(0, p)))
    softcut.pan(hd.voices[2], math.max(-1, 1 + 2 * math.min(0, p)))
  end
end

-- the post filter, so only what the head plays is filtered, not the recording
local function apply_hp(h)
  if not heads[h] then return end
  local fc = params:get(param_id(h, "hp"))
  local on = fc > HP_OFF
  for _, v in ipairs(heads[h].voices) do
    softcut.post_filter_fc(v, fc)
    softcut.post_filter_rq(v, HP_RQ)
    softcut.post_filter_hp(v, on and 1 or 0)
    softcut.post_filter_dry(v, on and 0 or 1)
  end
end

-- new heads from the source params, with their pan and highpass
local function rebuild_heads()
  build_heads()
  for h in pairs(heads) do
    apply_pan(h)
    apply_hp(h)
  end
end

local play
local reanalyse
local loading = false -- a PSET is being read; the heads are rebuilt once it's done

-- after a source change: fade out, hand out the voices again, carry on.
-- While recording (or during its fades) the voices stay as they are; the
-- recording rebuilds the heads when it's done.
local function relayout()
  if loading or state == "busy" or state == "recording" then return end
  if punch then stop_punch() end
  if not voices_on then
    rebuild_heads()
    for h in pairs(heads) do apply_head(h) end
    return
  end
  local prev = state
  state = "busy"
  if stop_clock then
    clock.cancel(stop_clock)
    stop_clock = nil
  end
  clock.run(function()
    set_out(false)
    clock.sleep(FADE)
    set_play(false)
    rebuild_heads()
    state = prev
    for h in pairs(heads) do apply_head(h) end
    if prev == "playing" then play() end
  end)
end

-- every setting of every head back to its default (source, window,
-- mode, pitch, volume, pan, hpf, modulator); max length and E2 stay.
-- The sources are taken as a whole, like a PSET read; the caller
-- rebuilds the heads.
local HEAD_PARAMS = {"source", "start", "stop", "mode", "pitch", "volume", "pan",
  "hp", "mod_target", "mod_shape", "mod_speed", "mod_amount"}
local function reset_heads()
  loading = true
  for h = 1, HEADS do
    for _, name in ipairs(HEAD_PARAMS) do
      params:lookup_param(param_id(h, name)):set_default()
    end
  end
  loading = false
  for _, hd in pairs(heads) do hd.mod, hd.phase = 0, 0 end
end

-- PARAMS: start and end are fractions of the recording, so they fit any length
local function setup_params()
  params:add_separator("smplr_settings", "SMPLR")
  params:add_control("max_length", "max length",
    controlspec.new(1, MAX_LENGTH_LIMIT, "lin", 1, max_length, "s", 1 / (MAX_LENGTH_LIMIT - 1)))
  -- info only: a range of 0..0 can't be changed; the formatter shows the length
  params:add_number("loop_length", "loop length", 0, 0, 0,
    function() return length > 0 and string.format("%.2f s", length) or "-" end)
  params:set_save("loop_length", false)
  params:add_option("loop_edit", "loop edit", {"resize", "move"}, RESIZE)
  params:add_option("loop_points", "loop points", {"free", "transient"}, FREE)
  -- how many transients are found: higher finds softer attacks too
  params:add_control("sensitivity", "sensitivity",
    controlspec.new(0, 100, "lin", 1, SENSITIVITY_DEFAULT, "%", 1 / 100))
  params:set_action("sensitivity", function() reanalyse() end)

  local function seconds(p) return string.format("%.2f s", p:get() * length) end
  for h, d in ipairs(HEAD_DEFAULTS) do
    local function id(name) return param_id(h, name) end
    params:add_group("head" .. h, "HEAD " .. h, 12)
    sources[h] = SOURCE_DEFAULTS[h]
    params:add_option(id("source"), "source", SOURCE_NAMES, SOURCE_DEFAULTS[h])
    params:set_action(id("source"), function(source)
      if loading then -- the whole layout is checked once the PSET is read
        sources[h] = source
        return
      end
      -- enough voices, and at least one head stays on (without a head
      -- there's nothing to select, play or edit)
      local function fits(src)
        local needed, on = 0, 0
        for i = 1, HEADS do
          local s = i == h and src or sources[i]
          needed = needed + voices_needed(s)
          if s ~= OFF then on = on + 1 end
        end
        return needed <= softcut.VOICE_COUNT and on > 0
      end
      -- doesn't fit: skip on in the turning direction to the next source
      -- that fits, or stay where it was if none does
      local dir = source > sources[h] and 1 or -1
      while source >= 1 and source <= #SOURCE_NAMES and not fits(source) do
        source = source + dir
      end
      if source < 1 or source > #SOURCE_NAMES then source = sources[h] end
      params:set(id("source"), source, true)
      if source == sources[h] then return end
      sources[h] = source
      relayout()
    end)
    params:add_control(id("start"), "start",
      controlspec.new(0, 1, "lin", 0, d.start, "", WINDOW_STEP), seconds)
    params:add_control(id("stop"), "end",
      controlspec.new(0, 1, "lin", 0, d.stop, "", WINDOW_STEP), seconds)
    params:add_option(id("mode"), "mode", {"reverse", "forward", "muted"}, d.mode)
    params:add_number(id("pitch"), "pitch", -MAX_PITCH, MAX_PITCH, d.pitch,
      function(p) return string.format("%+d st", p:get()) end)
    params:add_control(id("volume"), "volume",
      controlspec.new(0, 1, "lin", 0, d.volume, "", 0.01))
    params:add_control(id("pan"), "pan",
      controlspec.new(-1, 1, "lin", 0, d.pan, "", 0.01))
    params:add_control(id("hp"), "hpf",
      controlspec.new(HP_OFF, HP_MAX, "exp", 0, HP_DEFAULTS[h], "Hz"),
      function(p)
        local fc = p:get()
        return fc <= HP_OFF and "off" or string.format("%d Hz", math.floor(fc + 0.5))
      end)
    params:add_option(id("mod_target"), "mod target", MOD_TARGETS, MOD_OFF)
    params:add_option(id("mod_shape"), "mod shape", MOD_SHAPES, SINE)
    params:add_control(id("mod_speed"), "mod speed",
      controlspec.new(MOD_SPEED_MIN, MOD_SPEED_MAX, "exp", 0, 0.1, "Hz"),
      function(p) return string.format("%.2f Hz", p:get()) end)
    params:add_control(id("mod_amount"), "mod amount",
      controlspec.new(0, 1, "lin", 0, MOD_AMOUNT, "", 0.01),
      function(p) return string.format("%d %%", math.floor(p:get() * 100 + 0.5)) end)

    -- apply_head, apply_pan and apply_hp do nothing while the head is off
    for _, name in ipairs({"start", "stop", "pitch"}) do
      params:set_action(id(name), function() apply_head(h) end)
    end
    params:set_action(id("mode"), function()
      if punch == h and muted(h) then stop_punch() end -- muted heads don't record
      apply_head(h)
      if state == "playing" then set_out(true) end
    end)
    params:set_action(id("volume"), function()
      if state == "playing" then set_out(true) end
    end)
    params:set_action(id("pan"), function() apply_pan(h) end)
    -- with the target off or head, the loop goes back
    params:set_action(id("mod_amount"), function() apply_head(h) end)
    params:set_action(id("mod_target"), function() apply_head(h) end)
    params:set_action(id("hp"), function() apply_hp(h) end)
  end
end

-- waveform -----------------------------------------------------------------

local function clear_waveform()
  for i = 1, GRAPH_W do waveform[i] = {0, 0} end
end

-- GRAPH_W peaks per buffer over dur s of buffer time from start;
-- answered in event_render
local function render_span(start, dur)
  if dur <= 0 then return end
  render_start, render_dur = start, dur
  for ch = 1, 2 do softcut.render_buffer(ch, start, dur, GRAPH_W) end
end

-- the visible part of the recording
local function render_view() render_span(START + view_from, view_dur) end

-- the shortest and longest view of the current recording (s)
local function view_limits() return math.min(VIEW_MIN, length), length end

-- show dur s of the recording from `from` s (kept inside the recording).
-- Only marks the view: the metro renders it once per frame, so turning an
-- encoder fast doesn't send a burst of render requests (bursts can get lost)
local function set_view(from, dur)
  dur = util.clamp(dur, view_limits())
  view_from, view_dur = util.clamp(from, 0, length - dur), dur
  view_changed = true
end

local function reset_view() set_view(0, length) end

-- how far the view is zoomed in: 1 = the whole recording
local function zoom() return view_dur > 0 and length / view_dur or 1 end

-- scroll the view just far enough that time t (s) is visible
local function keep_visible(t)
  if t < view_from then
    set_view(t, view_dur)
  elseif t > view_from + view_dur then
    set_view(t - view_dur, view_dur)
  end
end

local function setup_render()
  clear_waveform()
  softcut.event_render(function(ch, start, sec_per_sample, samples)
    -- an answer to an older request over a different span: ignore it
    if math.abs(start - render_start) > 0.001
      or math.abs(sec_per_sample * #samples - render_dur) > 0.01 * render_dur then return end
    for i = 1, GRAPH_W do
      waveform[i][ch] = math.min(1, math.abs(samples[i] or 0))
    end
  end)
end

-- recording and playback ---------------------------------------------------

-- the take's length, and its transients once they're found for it (with
-- the sensitivity they were found with)
local function save_take_info(found)
  tab.save({length = length, onsets = found and onsets or nil,
    sensitivity = found and params:get("sensitivity") or nil}, take_file())
end

-- find the transients of loop.wav once it holds `seconds` s; the engine
-- answers in osc.event. Until then the old transients stay usable.
local function analyse(seconds)
  analysis = analysis + 1
  analysing = true
  local threshold = THRESHOLD_MAX * (THRESHOLD_MIN / THRESHOLD_MAX) ^ (params:get("sensitivity") / 100)
  engine.analyse(analysis, audio_file(), math.floor(seconds * SAMPLE_RATE), threshold,
    onsets_file(analysis))
end

-- a new sensitivity: analyse the take again, once the encoder rests
reanalyse = function()
  if loading or (state ~= "stopped" and state ~= "playing") then return end
  if analyse_clock then clock.cancel(analyse_clock) end
  analyse_clock = clock.run(function()
    clock.sleep(0.5)
    analyse_clock = nil
    analyse(0) -- loop.wav is complete
  end)
end

-- write the recording (plus the post-roll) and its length, then find its
-- transients. softcut writes the file in the background; the old one is
-- removed first, so the analysis can't read it.
local function save_take()
  util.make_dir(AUDIO_DIR)
  os.remove(audio_file())
  softcut.buffer_write_stereo(audio_file(), START, length + FADE)
  save_take_info(false)
  analyse(length + FADE)
end

-- a recording is in the buffers: every head at its loop start
local function loop_ready()
  state = "stopped"
  for h, hd in pairs(heads) do
    hd.pos = -1 -- outside the window: apply_head moves it to its start
    apply_head(h)
  end
end

-- the saved take, with its transients; they're found again if they're
-- missing or were found with another sensitivity
local function load_take()
  if state ~= "empty" then return end -- a recording was started meanwhile
  local take = tab.load(take_file())
  if not (take and take.length and util.file_exists(audio_file())) then return end
  softcut.buffer_read_stereo(audio_file(), 0, START, -1)
  length = take.length
  loop_ready()
  reset_view() -- rendered on the next frame, after the read (softcut does both in order)
  if take.onsets and take.sensitivity == params:get("sensitivity") then
    onsets = take.onsets
  else
    onsets = take.onsets or {}
    analyse(0)
  end
end

local function start_recording()
  state = "busy"
  clock.run(function()
    -- playback stopped less than FADE ago: let it fade out first
    if voices_on then
      set_out(false)
      clock.sleep(FADE)
      set_play(false)
    end
    clear_waveform()
    softcut.buffer_clear()
    max_length = params:get("max_length")
    for _, v in ipairs(REC_VOICES) do
      route_voice(v, v)
      softcut.rate(v, 1)
      softcut.loop_start(v, START)
      softcut.loop_end(v, START + max_length + 1) -- room for the post-roll
      -- jump without a crossfade: during one, the old position keeps
      -- recording. The voice is silent, so the jump isn't heard.
      softcut.fade_time(v, 0)
      softcut.position(v, START)
    end
    set_rec_flags(REC_VOICES, true)
    set_rec_levels(REC_VOICES, 1, 0)
    rec_start_time = util.time()
    state = "recording"
    rec_clock = clock.run(function()
      clock.sleep(max_length)
      rec_clock = nil
      stop_recording()
    end)
  end)
end

-- a take is in the buffers: default heads, ready to play, saved
local function finish_take()
  reset_heads()
  rebuild_heads() -- the default layout; recording also rerouted voices 1 and 2
  selected = order[1] or 1
  loop_ready()
  reset_view() -- a new recording shows all of it
  onsets = {}  -- until the new ones are found
  save_take()
end

stop_recording = function()
  if state ~= "recording" then return end
  if rec_clock then
    clock.cancel(rec_clock)
    rec_clock = nil
  end
  length = util.clamp(util.time() - rec_start_time, 0.1, max_length)
  state = "busy"
  clock.run(function()
    -- post-roll: the loop-end crossfade reads past the end
    clock.sleep(FADE)
    set_rec_levels(REC_VOICES, 0, 1)
    clock.sleep(FADE * 2)
    set_rec_flags(REC_VOICES, false)
    finish_take()
  end)
end

-- K2 held while stopped: an empty (silent) take of max length, a canvas
-- to punch into later. What was recorded since the press is thrown away.
local function make_canvas()
  if state ~= "recording" then return end
  if rec_clock then
    clock.cancel(rec_clock)
    rec_clock = nil
  end
  state = "busy"
  set_rec_levels(REC_VOICES, 0, 1)
  set_rec_flags(REC_VOICES, false)
  softcut.buffer_clear()
  length = max_length
  finish_take()
  note, note_until = string.format("empty %.0fs", length), util.time() + POPUP_TIME -- like show()
end

play = function()
  if stop_clock then
    clock.cancel(stop_clock)
    stop_clock = nil
  end
  for _, hd in pairs(heads) do
    hd.pos = hd.sign > 0 and hd.s or hd.e
    for _, v in ipairs(hd.voices) do softcut.position(v, START + hd.pos) end
  end
  set_play(true)
  set_out(true) -- fades in
  state = "playing"
end

local function stop()
  if punch then stop_punch() end
  set_out(false) -- fades out, then the voices stop
  state = "stopped"
  stop_clock = clock.run(function()
    clock.sleep(FADE)
    stop_clock = nil
    if state == "stopped" then set_play(false) end
  end)
end

-- punch-in: the selected head replaces what's at its playhead with the
-- input, inside its loop, at its pitch and direction
local function start_punch()
  punch = selected
  set_rec_levels(heads[punch].voices, 1, 0)
end

stop_punch = function()
  set_rec_levels(heads[punch].voices, 0, 1)
  punch = nil
  -- once the recording has faded out: final waveform, then save
  clock.run(function()
    clock.sleep(FADE * 2)
    -- a new recording started meanwhile: it renders and saves itself
    if state ~= "stopped" and state ~= "playing" then return end
    view_changed = true
    save_take()
  end)
end

-- advance every head's modulator by dt seconds and move its loop; only
-- while playing, so a stopped loop stays where it is
local function modulate(dt)
  if state ~= "playing" then return end
  for h, hd in pairs(heads) do
    if mod_target(h) ~= MOD_OFF then
      local phase = hd.phase + params:get(param_id(h, "mod_speed")) * dt
      local shape = params:get(param_id(h, "mod_shape"))
      if shape == RANDOM then
        if phase >= 1 then hd.mod = math.random() * 2 - 1 end
      elseif shape == SINE then
        hd.mod = math.sin(2 * math.pi * phase)
      elseif shape == SAW then
        hd.mod = 2 * ((phase + 0.5) % 1) - 1 -- 0 at the start, up to 1, jumps to -1
      else
        hd.mod = 1 - 4 * math.abs((phase + 0.25) % 1 - 0.5) -- 0 at the start, like the sine
      end
      hd.phase = phase % 1
      local target = mod_target(h)
      if target == MOD_LOOP then
        local s, e = mod_window(h)
        if s ~= hd.s or e ~= hd.e then
          hd.s, hd.e = s, e
          for _, v in ipairs(hd.voices) do
            softcut.loop_start(v, START + s)
            softcut.loop_end(v, START + e)
          end
        end
      else
        -- around the middle of the loop; only jumps when the spot changes
        -- (random: once per cycle, then it plays on from there)
        local amount = params:get(param_id(h, "mod_amount"))
        local pos = hd.s + (0.5 + hd.mod * amount / 2) * (hd.e - hd.s)
        if pos ~= hd.mod_pos then
          hd.mod_pos, hd.pos = pos, pos
          for _, v in ipairs(hd.voices) do softcut.position(v, START + pos) end
        end
      end
    end
  end
end

-- a short popup in the middle of the screen (mode name, setting and value)
local function show(text)
  note, note_until = text, util.time() + POPUP_TIME
end

-- a setting's value as the popup shows it
local function value_text(h, name)
  local id = param_id(h, name)
  if name == "pan" then
    local pan = math.floor(params:get(id) * 100 + 0.5)
    return pan == 0 and "C" or string.format("%s%d", pan < 0 and "L" or "R", math.abs(pan))
  end
  return params:string(id)
end

-- K1 + K2 / K1 + K3 per edit mode: K1 + K2 randomizes what the mode
-- edits, K1 + K3 toggles something in it; each shows the result

local HP_RANDOM_MAX = 1000 -- Hz; random hpf: off, or up to here (above it gets thin)
local zoomed_view = nil    -- the zoomed view before K1 + K3 zoomed out: {from, dur}

-- a random value between lo and hi on an exponential scale
local function exp_random(lo, hi) return lo * (hi / lo) ^ math.random() end

local function random_loop(h)
  local start = math.random() * 0.95 -- at least 5 % of the recording long
  params:set(param_id(h, "start"), start)
  params:set(param_id(h, "stop"), start + 0.05 + math.random() * (0.95 - start))
  show(string.format("loop %.1f-%.1f s", params:get(param_id(h, "start")) * length,
    params:get(param_id(h, "stop")) * length))
end

local function random_sound(h)
  params:set(param_id(h, "pitch"), math.random(-MAX_PITCH, MAX_PITCH))
  params:set(param_id(h, "volume"), RANDOM_LEVEL[1] + math.random() * (RANDOM_LEVEL[2] - RANDOM_LEVEL[1]))
  params:set(param_id(h, "pan"), math.random() * 2 - 1)
  params:set(param_id(h, "mode"), math.random() < 0.5 and FORWARD or REVERSE) -- never muted
  -- hpf: off a third of the time, else 20 Hz .. 1 kHz
  params:set(param_id(h, "hp"), math.random() < 1 / 3 and HP_OFF or exp_random(HP_OFF + 1, HP_RANDOM_MAX))
  show(string.format("P%s V%.2f %s %s hpf %s",
    value_text(h, "pitch"):gsub(" st", ""), params:get(param_id(h, "volume")),
    value_text(h, "pan"), params:get(param_id(h, "mode")) == FORWARD and ">" or "<",
    value_text(h, "hp"):gsub(" Hz", "")))
end

local function random_mod(h)
  params:set(param_id(h, "mod_target"), math.random(#MOD_TARGETS))
  params:set(param_id(h, "mod_shape"), math.random(#MOD_SHAPES))
  params:set(param_id(h, "mod_speed"), exp_random(MOD_SPEED_MIN, MOD_SPEED_MAX))
  params:set(param_id(h, "mod_amount"), math.random())
  show(string.format("%s %s %.2fHz %d%%",
    MOD_TARGETS[params:get(param_id(h, "mod_target"))],
    MOD_SHAPES[params:get(param_id(h, "mod_shape"))],
    params:get(param_id(h, "mod_speed")),
    math.floor(params:get(param_id(h, "mod_amount")) * 100 + 0.5)))
end

-- the view shows the head's loop (as drawn) with 10 % of it on each side
local function zoom_to_loop(h)
  local hd = heads[h]
  local margin = (hd.e - hd.s) * 0.1
  set_view(hd.s - margin, hd.e - hd.s + 2 * margin)
  show("zoom H" .. h)
end

local function transient() return params:get("loop_points") == TRANSIENT end

local function toggle_points()
  params:set("loop_points", transient() and FREE or TRANSIENT)
  show(transient() and "transient" or "free")
end

local function toggle_loop_edit()
  params:set("loop_edit", params:get("loop_edit") == MOVE and RESIZE or MOVE)
  show(params:get("loop_edit") == MOVE and "move" or "resize")
end

local function toggle_mode(h)
  local id = param_id(h, "mode")
  params:set(id, params:get(id) % 3 + 1) -- reverse > forward > muted
  show(value_text(h, "mode"))
end

-- the mod target in turn: off -> head -> loop -> off
local MOD_CYCLE = {[MOD_OFF] = MOD_HEAD, [MOD_HEAD] = MOD_LOOP, [MOD_LOOP] = MOD_OFF}
local function toggle_mod(h)
  local id = param_id(h, "mod_target")
  params:set(id, MOD_CYCLE[params:get(id)])
  show("mod " .. MOD_TARGETS[params:get(id)])
end

-- the whole recording <-> the last zoomed view
local function toggle_zoom()
  if view_dur < length then
    zoomed_view = {view_from, view_dur}
    reset_view()
    show("zoom off")
  elseif zoomed_view then
    set_view(zoomed_view[1], zoomed_view[2])
    show("zoom on")
  else
    show("zoom off")
  end
end

-- LOOP in transient: loop start and end jump between the transients; the
-- take's start and end count as jump points too

local POINT_EPS = 0.001  -- s; a point this close counts as the current one
local RANDOM_SLICES = 8 -- longest random loop, in slices

local function slice_points()
  local p = {0}
  for _, t in ipairs(onsets) do p[#p + 1] = t end
  p[#p + 1] = length
  return p
end

-- the next jump point after t (d > 0) or before it (d < 0), or nil
local function next_point(p, t, d)
  if d > 0 then
    for i = 1, #p do
      if p[i] > t + POINT_EPS then return p[i] end
    end
  else
    for i = #p, 1, -1 do
      if p[i] < t - POINT_EPS then return p[i] end
    end
  end
end

local function set_window(h, s, e)
  params:set(param_id(h, "start"), s / length)
  params:set(param_id(h, "stop"), e / length)
end

-- start and end stop at each other, as in LOOP
local function slice_start(h, d)
  local p = slice_points()
  local s = params:get(param_id(h, "start")) * length
  local e = params:get(param_id(h, "stop")) * length
  for _ = 1, math.abs(d) do
    local t = next_point(p, s, d)
    if not t or t > e - MIN_LOOP then break end
    s = t
  end
  params:set(param_id(h, "start"), s / length)
end

local function slice_end(h, d)
  local p = slice_points()
  local s = params:get(param_id(h, "start")) * length
  local e = params:get(param_id(h, "stop")) * length
  for _ = 1, math.abs(d) do
    local t = next_point(p, e, d)
    if not t or t < s + MIN_LOOP then break end
    e = t
  end
  params:set(param_id(h, "stop"), e / length)
end

local function nearest_point(p, t)
  local best = 1
  for i = 2, #p do
    if math.abs(p[i] - t) < math.abs(p[best] - t) then best = i end
  end
  return best
end

-- E2 in "move loop" mode: the loop jumps d transients and keeps the
-- number of slices it spans (start and end first snap to the nearest ones)
local function slice_move(h, d)
  local p = slice_points()
  local i = nearest_point(p, params:get(param_id(h, "start")) * length)
  local j = nearest_point(p, params:get(param_id(h, "stop")) * length)
  local k = math.max(1, j - i)
  i = util.clamp(i + d, 1, #p - k)
  -- move the leading edge first, so the window never shrinks in between
  if d > 0 then
    params:set(param_id(h, "stop"), p[i + k] / length)
    params:set(param_id(h, "start"), p[i] / length)
  else
    params:set(param_id(h, "start"), p[i] / length)
    params:set(param_id(h, "stop"), p[i + k] / length)
  end
end

-- from a random transient over 1 .. RANDOM_SLICES slices
local function random_slice(h)
  local p = slice_points()
  local i = math.random(1, #p - 1)
  local k = math.random(1, math.min(RANDOM_SLICES, #p - i))
  set_window(h, p[i], p[i + k])
  show(string.format("slice %.1f-%.1f s", p[i], p[i + k]))
end

local RANDOMIZE = {
  function(h) if transient() then random_slice(h) else random_loop(h) end end,
  random_sound, random_mod, zoom_to_loop}
local TOGGLE = {function() toggle_points() end, toggle_mode, toggle_mod, function() toggle_zoom() end}


-- norns callbacks ----------------------------------------------------------

-- a PSET sets the sources one after another, so a head could be skipped
-- for lack of voices that a later head frees. While reading, every source
-- is accepted; then the layout is checked as a whole (heads switched off
-- from the end if it doesn't fit) and the voices handed out once. This
-- wraps params:read (the PSET menu calls it too); cleanup restores it.
local function wrap_params_read()
  local read = params.read
  params.read = function(self, ...)
    loading = true
    read(self, ...)
    loading = false
    local needed = 0
    for h = 1, HEADS do needed = needed + voices_needed(sources[h]) end
    for h = HEADS, 1, -1 do
      if needed <= softcut.VOICE_COUNT then break end
      needed = needed - voices_needed(sources[h])
      sources[h] = OFF
      params:set(param_id(h, "source"), OFF, true)
    end
    -- a PSET with every head off: H1 plays both buffers, as after a recording
    local any = false
    for h = 1, HEADS do any = any or sources[h] ~= OFF end
    if not any then
      sources[1] = BOTH
      params:set(param_id(1, "source"), BOTH, true)
    end
    relayout()
  end
end

-- the engine's answer to analyse(): the transients, one per line in
-- `file` ("" if the analysis failed)
local function onsets_found(n, file)
  if n ~= analysis then return end -- an older analysis
  analysing = false
  if file == "" then
    if transient() then show("analysis failed") end
    return
  end
  local found = {}
  for line in io.lines(file) do
    local t = tonumber(line)
    if t and t > ONSET_EDGE and t < length - MIN_LOOP then found[#found + 1] = t end
  end
  os.remove(file)
  onsets = found
  save_take_info(true)
  if transient() then show(#onsets .. " transients") end
end

function init()
  osc.event = function(path, args)
    if path == "/smplr/onsets" then onsets_found(args[1], args[2]) end
  end
  setup_params()
  setup_voices()
  wrap_params_read()
  if util.file_exists(pset_file()) then params:read(pset_file()) end
  rebuild_heads()
  setup_render()
  -- every softcut command is a message to crone; read the recording once
  -- the startup burst is through, or the read request can get lost
  clock.run(function()
    clock.sleep(0.2)
    load_take()
  end)

  -- redraw() is looked up on each tick: norns swaps it out while the menu is open
  redraw_metro = metro.init(function()
    frame = frame + 1
    if frame % MOD_EVERY == 0 then modulate(MOD_EVERY / FPS) end
    if state == "recording" then
      if frame % RENDER_EVERY == 0 then render_span(START, max_length) end -- grows left to right
    elseif view_changed or (punch and frame % RENDER_EVERY == 0) then
      view_changed = false
      render_view()
    end
    redraw()
  end, 1 / FPS)
  redraw_metro:start()
end

-- E2 / E3 stop at the other end of the loop instead of pushing past it
local function keep_order(h, changed)
  local min = MIN_LOOP / length
  local s, e = params:get(param_id(h, "start")), params:get(param_id(h, "stop"))
  if e - s >= min then return end
  if changed == "start" then
    params:set(param_id(h, "start"), math.max(0, e - min))
  else
    params:set(param_id(h, "stop"), math.min(1, s + min))
  end
end

-- loop edit move: start and end move together, the length stays; the loop
-- stops at the recording's edges
local function move_loop(h, d)
  local s, e = params:get(param_id(h, "start")), params:get(param_id(h, "stop"))
  local shift = util.clamp(d * WINDOW_STEP / zoom(), -s, 1 - e)
  -- move the leading edge first, so the window never shrinks in between
  if shift > 0 then
    params:set(param_id(h, "stop"), e + shift)
    params:set(param_id(h, "start"), s + shift)
  else
    params:set(param_id(h, "start"), s + shift)
    params:set(param_id(h, "stop"), e + shift)
  end
end

local function editable()
  return (state == "stopped" or state == "playing") and heads[selected] ~= nil
end

function key(n, z)
  -- K1 only reaches the script while held (a short press opens the menu);
  -- pressing it closes a setting's popup, so the mode shows right away
  if n == 1 then
    alt = z == 1
    if alt then note_until = 0 end
    return
  end

  if n == 2 then
    if z == 0 then
      if canvas_clock then
        clock.cancel(canvas_clock)
        canvas_clock = nil
      end
      if punch then stop_punch() end
    elseif state == "recording" then
      stop_recording()
    elseif alt then -- never records
      if editable() then RANDOMIZE[edit_mode](selected) end
    elseif state == "playing" then
      if not muted(selected) then start_punch() end -- until K2 is released
    elseif state == "empty" or state == "stopped" then
      start_recording() -- right away; held for CANVAS_HOLD it becomes an empty take
      canvas_clock = clock.run(function()
        clock.sleep(CANVAS_HOLD)
        canvas_clock = nil
        make_canvas()
      end)
    end
  elseif n == 3 and z == 0 then
    -- LOOP: K1 + K3 released before LONG_PRESS is the short press
    if loop_press_clock then
      clock.cancel(loop_press_clock)
      loop_press_clock = nil
      if editable() then TOGGLE[LOOP](selected) end
    end
  elseif n == 3 and editable() then
    if alt and edit_mode == LOOP then
      -- short: free <-> transient (on release); long: resize <-> move
      loop_press_clock = clock.run(function()
        clock.sleep(LONG_PRESS)
        loop_press_clock = nil
        if editable() then toggle_loop_edit() end
      end)
    elseif alt then
      TOGGLE[edit_mode](selected)
    elseif state == "playing" then
      stop()
    else
      play()
    end
  end
end

function enc(n, d)
  -- K1 + E1: edit mode (always, also while recording or without heads)
  if n == 1 and alt then
    edit_mode = util.clamp(edit_mode + d, 1, #MODES)
    show(MODES[edit_mode].name)
    return
  end
  -- VIEW only needs a recording, not a head
  if edit_mode == VIEW and n > 1 then
    if state ~= "stopped" and state ~= "playing" then return end
    if n == 2 then
      -- zoom around the middle of the view; the length is clamped first,
      -- so at the zoom limits the middle stays where it is
      local dur = util.clamp(view_dur / ZOOM_STEP ^ d, view_limits())
      set_view(view_from + (view_dur - dur) / 2, dur)
    else
      set_view(view_from + d * SCROLL_STEP * view_dur, view_dur)
    end
    return
  end
  if not editable() then return end
  if n == 1 then
    -- step through the heads top to bottom as on screen
    local i = 1
    for k, h in ipairs(order) do
      if h == selected then i = k end
    end
    selected = order[util.clamp(i + d, 1, #order)]
  elseif edit_mode == LOOP then
    -- free: steps get finer the further the view is zoomed in (the same
    -- distance on screen); transient: from transient to transient. The
    -- view follows the edited point (moving: the edge that leads).
    local edge = n == 2 and "start" or "stop"
    if transient() and #onsets == 0 then show(analysing and "analysing..." or "no transients") end
    if params:get("loop_edit") == MOVE then
      if transient() then slice_move(selected, d) else move_loop(selected, d) end
      edge = d > 0 and "stop" or "start"
    elseif transient() then
      if n == 2 then slice_start(selected, d) else slice_end(selected, d) end
    else
      local id = param_id(selected, edge)
      params:set(id, params:get(id) + d * WINDOW_STEP / zoom())
      keep_order(selected, edge)
    end
    keep_visible(params:get(param_id(selected, edge)) * length)
  else
    -- list modes: E2 picks a setting, E3 changes it
    local items = MODES[edit_mode].items
    local i = picked[edit_mode] or 1
    if n == 2 then
      i = util.clamp(i + d, 1, #items)
      picked[edit_mode] = i
    else
      params:delta(param_id(selected, items[i][2]), d)
    end
    show(items[i][1] .. " " .. value_text(selected, items[i][2]))
  end
end

-- screen -------------------------------------------------------------------

-- from the top: one bar row per StereoHead, lane 1, one row per MonoHead
-- on buffer 1, lane 2, one row per MonoHead on buffer 2. The lanes share
-- the rest of the height. Returns the lane centers, the lanes' half
-- height (a full-scale peak spans 2 * half + 1 px) and each head's bar y.
local function layout()
  local count = {stereo = 0, [1] = 0, [2] = 0}
  for _, hd in pairs(heads) do
    local group = hd.kind == "stereo" and "stereo" or hd.buffer
    count[group] = count[group] + 1
  end
  local gap = count[1] == 0 and 2 or 1 -- between lane 1 and the next element
  local rows = (count.stereo + count[1] + count[2]) * BAR_PITCH
  local half = math.floor((SCREEN_H - rows - gap - 1 - 2) / 4)
  local span = 2 * half + 1
  local y = math.floor((SCREEN_H - rows - gap - 1 - 2 * span) / 2) -- spare px split above and below

  local bar_y = {}
  local function bars(group)
    for _, h in ipairs(order) do
      local hd = heads[h]
      if (hd.kind == "stereo" and "stereo" or hd.buffer) == group then
        bar_y[h] = y
        y = y + BAR_PITCH
      end
    end
  end
  bars("stereo")
  local center1 = y + half
  y = y + span + gap
  bars(1)
  local center2 = y + half
  y = y + span + 1
  bars(2)
  return {center1, center2}, half, bar_y
end

-- lane center line
local function draw_lane(center)
  screen.level(1)
  screen.move(GRAPH_X, center + 0.5)
  screen.line_rel(GRAPH_W, 0)
  screen.stroke()
end

-- each column a 1 px wide rect around the lane's center, |peak| x half the lane
local function draw_waveform(centers, half)
  for ch = 1, 2 do
    local center = centers[ch]
    draw_lane(center)
    screen.level(GRAPH_LEVEL)
    for i = 1, GRAPH_W do
      local hh = math.floor(waveform[i][ch] * half + 0.5)
      if hh > 0 then screen.rect(GRAPH_X + i - 1, center - hh, 1, hh * 2 + 1) end
    end
    screen.fill()
  end
end

-- x of time t (s) in the view; outside the screen when t isn't visible
local function time_x(t)
  return GRAPH_X + (t - view_from) / view_dur * (GRAPH_W - 1)
end

-- loop bars; the selected one bright
local function draw_loop_bars(bar_y)
  for h, hd in pairs(heads) do
    local x0, x1 = math.floor(time_x(hd.s)), math.floor(time_x(hd.e))
    if x1 >= GRAPH_X and x0 <= GRAPH_X + GRAPH_W - 1 then -- cut to the screen
      x0, x1 = math.max(x0, GRAPH_X), math.min(x1, GRAPH_X + GRAPH_W - 1)
      screen.level(h == selected and 15 or 4)
      screen.rect(x0, bar_y[h], math.max(1, x1 - x0 + 1), 1)
      screen.fill()
    end
  end
end

-- one line per head (none for muted heads), across both lanes for a
-- StereoHead, across its buffer's lane for a MonoHead; the selected one
-- bright and drawn last
local function draw_playhead(h, centers, half)
  if muted(h) then return end
  local hd = heads[h]
  local top = centers[hd.kind == "mono" and hd.buffer or 1] - half
  local bottom = centers[hd.kind == "mono" and hd.buffer or 2] + half + 1
  local px = math.floor(time_x(hd.pos)) + 0.5
  if px < GRAPH_X or px > GRAPH_X + GRAPH_W then return end -- scrolled out of view
  screen.level(h == selected and 15 or 4)
  screen.move(px, top)
  screen.line(px, bottom)
  screen.stroke()
end

-- loop points transient: a short bright tick on both lanes' center lines
-- per transient, in every mode (so they show while zooming too)
local function draw_onsets(centers)
  screen.level(15)
  for _, t in ipairs(onsets) do
    local x = math.floor(time_x(t))
    if x >= GRAPH_X and x < GRAPH_X + GRAPH_W then
      for ch = 1, 2 do screen.rect(x, centers[ch] - 2, 1, 5) end
    end
  end
  screen.fill()
end

local function draw_playheads(centers, half)
  for h in pairs(heads) do
    if h ~= selected then draw_playhead(h, centers, half) end
  end
  if heads[selected] then draw_playhead(selected, centers, half) end
end

-- text in a black box with a dim frame, over whatever is below;
-- x, y is the box's top left corner (nil: centered on the screen)
local function popup(text, x, y)
  local w = screen.text_extents(text) + 6
  local h = 11
  x = x or math.floor((GRAPH_W - w) / 2)
  y = y or math.floor((SCREEN_H - h) / 2)
  screen.level(0)
  screen.rect(x, y, w, h)
  screen.fill()
  screen.level(4)
  screen.rect(x + 0.5, y + 0.5, w - 1, h - 1)
  screen.stroke()
  screen.level(15)
  screen.move(x + 3, y + 8)
  screen.text(text)
end

function redraw()
  screen.clear()
  local centers, half, bar_y = layout()
  if state == "empty" then
    draw_lane(centers[1])
    draw_lane(centers[2])
  else
    draw_waveform(centers, half)
  end
  if state == "stopped" or state == "playing" then
    if transient() then draw_onsets(centers) end
    draw_loop_bars(bar_y)
  end
  if state == "playing" then draw_playheads(centers, half) end

  -- popups, centered: the time so far while recording; the mode name or
  -- the setting being changed, shortly after a turn; the mode while K1
  -- is held; how to start while there's no take yet
  if state == "recording" then
    popup(string.format("%.1fs", util.time() - rec_start_time))
  elseif util.time() < note_until then
    popup(note) -- mode name, or the setting being changed
  elseif alt then
    popup(MODES[edit_mode].name) -- K1 held: the current mode (K1 + E1 changes it)
  elseif state == "empty" then
    popup("press K2 to record")
  end
  screen.update()
end

function cleanup()
  params:write(pset_file())
  params.read = nil -- back to norns' own params:read
  if rec_clock then clock.cancel(rec_clock) end
  if analyse_clock then clock.cancel(analyse_clock) end
  if loop_press_clock then clock.cancel(loop_press_clock) end
  osc.event = nil
  softcut.poll_stop_phase()
  for v = 1, softcut.VOICE_COUNT do
    softcut.rec(v, 0)
    softcut.play(v, 0)
  end
end
