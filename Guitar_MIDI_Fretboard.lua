-- Guitar MIDI Fretboard - REAPER ReaScript (Lua)
-- Native gfx interface; no extra extensions necessary.
-- Default: 7-string Drop G, low to high G1 D2 G2 C3 F3 A3 D4.

local name = 'Guitar MIDI Fretboard | Studio Edition - Precise Playback'
-- All tunings are listed HIGH string first (as shown top-to-bottom on the fretboard).
local presets = {
  {name='Drop F (7)',  notes={60,55,51,46,41,36,29}},
  {name='Drop F# (7)', notes={61,56,52,47,42,37,30}},
  {name='Drop G (7)',  notes={62,57,53,48,43,38,31}},
  {name='Drop G# (7)', notes={63,58,54,49,44,39,32}},
  {name='Drop A (7)',  notes={64,59,55,50,45,40,33}},
  {name='Drop A# (7)', notes={65,60,56,51,46,41,34}},
  {name='Drop B (7)',  notes={66,61,57,52,47,42,35}},
  {name='Drop C (7)',  notes={67,62,58,53,48,43,36}},
  {name='Drop C# (7)', notes={68,63,59,54,49,44,37}},
  {name='Drop D (7)',  notes={69,64,60,55,50,45,38}},
  {name='Standard E (6)', notes={64,59,55,50,45,40}},
  {name='Drop D (6)', notes={64,59,55,50,45,38}},
  {name='Drop C (6)', notes={62,57,53,48,43,36}},
  {name='Drop B (6)', notes={61,56,52,47,42,35}},
  {name='Drop A (6)', notes={59,54,50,45,40,33}},
  {name='Standard B (7)', notes={64,59,55,50,45,40,35}},
}
local preset_idx = 3
local tuning = {}
local labels = {}
local tuning_name = ''
local custom_tunings = {} -- custom settings retained while this script is running

local note_names = {'C','C#','D','D#','E','F','F#','G','G#','A','A#','B'}
local divisions = { { '1/2', 2 }, { '1/4', 1 }, { '1/8', .5 }, { '1/16', .25 }, { '1/32', .125 }, { '1/64', .0625 } }
local div_idx = 4
local velocity = 100
local frets = 15
local step_qn = divisions[div_idx][2]
local cursor_qn = nil
local last_take = nil
local status = 'Open a MIDI item in the MIDI Editor.'
local last_note = '--'
local mouse_was_down = false
local win_w, win_h = 1180, 920
local live_mode = false
local target_track = nil
local held_note = nil
local live_quantize = false
local playback_highlight = true
local playback_cache = {take=nil, refreshed=0, notes={}}
-- Instrument articulation profiles. Add future plugins here, e.g. Odin 2 / Odin 3.
-- Each key switch uses the true MIDI note number (C-2 = MIDI 0).
 -- Profiles are deliberately independent from fretboard tuning.
local instrument_profiles = {
  {
    name = 'Submission Audio - UmanskyBass',
    articulations = {
      {name='Finger Alternate', midi=0},
      {name='Finger Index', midi=1},
      {name='Finger Middle', midi=2},
      {name='Dead Note', midi=3},
      {name='Slap', midi=4},
      {name='Dead Slap', midi=5},
      {name='Pop', midi=6},
      {name='Dead Pop', midi=7},
      {name='Harmonic', midi=8},
      {name='Hammer/Pull', midi=9},
      {name='Tapping', midi=10},
      {name='Slide Trigger', midi=11},
      {name='Dead Dbl Thumb', midi=12},
      {name='Thumb', midi=13},
      {name='Dbl Thumb', midi=14},
      {name='Dbl Thumb Pop', midi=15},
      {name='Fret Hand Mute', midi=16}
    }
  },
  {
    name = 'Submission Audio - DjinnBass',
    articulations = {
      {name='Pick', midi=0},
      {name='Hammer On', midi=1},
      {name='Pull Off', midi=2},
      {name='Slide Down Slow', midi=3},
      {name='Slide Down Fast', midi=4},
      {name='Slide Up Slow', midi=5},
      {name='Slide Up Fast', midi=6},
      {name='Dead Mute', midi=7},
      {name='Harmonic Mute', midi=8},
    }
  }
}
local profile_idx = 1
local articulation_by_profile = {0,0}
local offset_by_profile = {0,0}
local articulation_idx = 0
local keyswitch_offset = 0
local function active_profile() return instrument_profiles[profile_idx] end
local function articulations() return active_profile().articulations end
local function keyswitch_pitch()
  local art = articulations()[articulation_idx]
  return art and (art.midi + keyswitch_offset) or nil
end
local function articulation_name()
  local art = articulations()[articulation_idx]
  return art and art.name or 'None'
end
local function select_profile(idx)
  if idx == profile_idx then return end
  articulation_by_profile[profile_idx] = articulation_idx
  offset_by_profile[profile_idx] = keyswitch_offset
  profile_idx = idx
  articulation_idx = articulation_by_profile[idx] or 0
  keyswitch_offset = offset_by_profile[idx] or 0
  status = 'VSTi profile: '..active_profile().name..'. Articulation: '..articulation_name()
end
-- Insert keyswitch FIRST, then pitched note. Keyswitch should precede the
-- instrument note by a few milliseconds where possible for reliable triggering.
local function insert_note_pair(take, start_time, end_time, pitch, vel, chosen_ks)
  local sp = reaper.MIDI_GetPPQPosFromProjTime(take,start_time)
  local ep = reaper.MIDI_GetPPQPosFromProjTime(take,end_time)
  if ep <= sp then return false end
  local ks = chosen_ks
  if ks and (ks < 0 or ks > 127) then return false end
  if ks then
    local item = reaper.GetMediaItemTake_Item(take)
    local item_start = reaper.GetMediaItemInfo_Value(item,'D_POSITION')
    local ks_start = math.max(item_start, start_time - 0.012)
    local ks_end = math.min(end_time, ks_start + 0.065)
    if ks_end <= ks_start then ks_end = end_time end
    local ksp = reaper.MIDI_GetPPQPosFromProjTime(take,ks_start)
    local kep = reaper.MIDI_GetPPQPosFromProjTime(take,ks_end)
    if kep <= ksp then kep = math.min(ep,ksp+1) end
    if kep > ksp then
      local ks_ok = reaper.MIDI_InsertNote(take,false,false,ksp,kep,0,ks,100,true)
      if not ks_ok then return false end
    end
  end
  return reaper.MIDI_InsertNote(take,false,false,sp,ep,0,pitch,vel,true)
end
local function note_name(pitch)
  return note_names[(pitch % 12) + 1] .. tostring(math.floor(pitch / 12) - 1)
end

local function transport_running()
  return (reaper.GetPlayState() & 1) ~= 0 or (reaper.GetPlayState() & 4) ~= 0
end
local function get_transport_position()
  if transport_running() then return reaper.GetPlayPosition() end
  return reaper.GetCursorPosition()
end
local function capture_target_track()
  local tr = reaper.GetSelectedTrack(0,0)
  if not tr then
    status = 'Select a target track in Arrange first, then click SET TARGET.'
    return
  end
  target_track = tr
  local _,nm = reaper.GetTrackName(tr)
  status = 'Live target: '..(nm or 'track')..' (keep this track NOT armed).'
end
local function track_name(tr)
  if not tr or not reaper.ValidatePtr2(0,tr,'MediaTrack*') then return '(none)' end
  local _,v = reaper.GetTrackName(tr)
  return v or '(unnamed)'
end
local function find_target_take(at_time)
  if not target_track or not reaper.ValidatePtr2(0,target_track,'MediaTrack*') then
    return nil,'Choose a target track using SET TARGET.'
  end
  if reaper.GetMediaTrackInfo_Value(target_track,'I_RECARM') > 0 then
    return nil,'Disarm the target track! Live mode edits MIDI item directly.'
  end
  local cnt = reaper.CountTrackMediaItems(target_track)
  for i=0,cnt-1 do
    local item = reaper.GetTrackMediaItem(target_track,i)
    local st = reaper.GetMediaItemInfo_Value(item,'D_POSITION')
    local en = st + reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
    if at_time >= st - 1e-7 and at_time < en - 1e-7 then
      local tk = reaper.GetActiveTake(item)
      if tk and reaper.TakeIsMIDI(tk) then return tk end
    end
  end
  return nil,'Create an EMPTY MIDI item on the target track over this time range.'
end
local function live_press(pitch)
  local start_time = get_transport_position()
  local take,err = find_target_take(start_time)
  if not take then status=err; return end
  if live_quantize then
    local qn = reaper.TimeMap2_timeToQN(0,start_time)
    start_time = reaper.TimeMap2_QNToTime(0,math.floor(qn/step_qn+0.5)*step_qn)
  end
  held_note = {take=take,pitch=pitch,start_time=start_time,ks=keyswitch_pitch(),art_name=articulation_name()}
  last_note=note_name(pitch)..' (MIDI '..pitch..')'
  status='Holding '..last_note..'; release mouse to write note.'
end
local function live_release()
  local n = held_note
  if not n then return end
  held_note = nil
  if not reaper.ValidatePtr2(0,n.take,'MediaItem_Take*') then
    status='Target take was removed.'; return
  end
  local en=get_transport_position()
  local st=n.start_time
  if en <= st or not transport_running() then
    en = reaper.TimeMap2_QNToTime(0,reaper.TimeMap2_timeToQN(0,st)+step_qn)
  end
  if live_quantize then
    local qn=reaper.TimeMap2_timeToQN(0,en)
    en=reaper.TimeMap2_QNToTime(0,math.floor(qn/step_qn+0.5)*step_qn)
  end
  local item=reaper.GetMediaItemTake_Item(n.take)
  local item_st=reaper.GetMediaItemInfo_Value(item,'D_POSITION')
  local item_en=item_st+reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
  en=math.min(en,item_en)
  if en <= st then
    en=math.min(item_en,reaper.TimeMap2_QNToTime(0,reaper.TimeMap2_timeToQN(0,st)+step_qn))
  end
  if en <= st then status='Note was too close to the end of the MIDI item.';return end
  reaper.Undo_BeginBlock()
  local ok=insert_note_pair(n.take,st,en,n.pitch,velocity,n.ks)
  if ok then
    reaper.MIDI_Sort(n.take)
    reaper.MIDI_RefreshEditors(n.take)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock('Live fretboard note '..note_name(n.pitch),-1)
    status='Live: '..note_name(n.pitch)..' + '..n.art_name..' on '..track_name(target_track)
  else
    reaper.Undo_EndBlock('Live fretboard failed insert',-1)
    status='MIDI_InsertNote failed.'
  end
end

local function set_tuning(notes, description)
  tuning, labels = {}, {}
  for i,p in ipairs(notes) do
    tuning[i] = p
    labels[i] = note_name(p)
  end
  tuning_name = description
  status = 'Tuning: '..description..' ('..#tuning..' strings).'
end

local function set_preset(idx)
  preset_idx = idx
  set_tuning(presets[idx].notes, presets[idx].name)
end

local function parse_note(input)
  local t = (input or ''):upper():gsub('%s+','')
  local num = tonumber(t)
  if num and num >= 0 and num <= 127 and num == math.floor(num) then return num end
  local letter,sharp,octave = t:match('^([A-G])([#B]?)(%-?%d+)$')
  if not letter then return nil end
  local offsets = {C=0,D=2,E=4,F=5,G=7,A=9,B=11}
  local pitch = (tonumber(octave)+1)*12 + offsets[letter]
  if sharp == '#' then pitch=pitch+1 elseif sharp == 'B' then pitch=pitch-1 end
  if pitch < 0 or pitch > 127 then return nil end
  return pitch
end

local function edit_custom(count)
  local initial = custom_tunings[count]
  if not initial then
    initial = {}
    for i=1,count do
      initial[i] = tuning[i] or (tuning[#tuning] - 5 * (i-#tuning))
      initial[i] = math.max(0, math.min(127,initial[i]))
    end
  end
  local defaults, captions = {}, {}
  for i=1,count do
    defaults[i] = note_name(initial[i])
    captions[i] = 'String '..i..' (high to low)'
  end
  local ok, result = reaper.GetUserInputs('CUSTOM TUNING - '..count..' strings', count, table.concat(captions,','), table.concat(defaults,','))
  if not ok then return end
  local entries = {}
  -- GetUserInputs returns comma-separated values. Accept C#4, Bb2, 60, etc.
  for part in (result..','):gmatch('(.-),') do entries[#entries+1] = part end
  if #entries ~= count then
    reaper.MB('Enter one pitch per string, from highest to lowest.','Invalid tuning',0)
    return
  end
  local notes={}
  for i=1,count do
    notes[i]=parse_note(entries[i])
    if not notes[i] then
      reaper.MB('Invalid pitch for string '..i..': '..entries[i]..'\nUse E4, F#2, Bb1 or a MIDI number 0-127.','Invalid tuning',0)
      return
    end
  end
  custom_tunings[count]=notes
  preset_idx = 0
  set_tuning(notes,'Custom ('..count..')')
end

local function tuning_menu()
  -- gfx.showmenu returns the 1-based index of a selectable item.
  -- Keep every entry selectable to make result mapping unambiguous.
  local entries, actions = {}, {}
  for i,p in ipairs(presets) do
    local j=i
    entries[#entries+1]=(preset_idx==i and '!' or '')..p.name
    actions[#actions+1]=function() set_preset(j) end
  end
  for _,count in ipairs({6,7,8}) do
    local n=count
    entries[#entries+1]='Custom '..count..' strings...'
    actions[#actions+1]=function() edit_custom(n) end
  end
  gfx.x,gfx.y=gfx.mouse_x,gfx.mouse_y
  local selection=gfx.showmenu(table.concat(entries,'|'))
  if selection>0 and actions[selection] then actions[selection]() end
end

local function instrument_menu()
  local entries = {}
  for i,prof in ipairs(instrument_profiles) do
    entries[#entries+1] = (i == profile_idx and '!' or '')..prof.name
  end
  gfx.x,gfx.y=gfx.mouse_x,gfx.mouse_y
  local selection = gfx.showmenu(table.concat(entries,'|'))
  if selection > 0 and instrument_profiles[selection] then select_profile(selection) end
end

set_preset(preset_idx)

local function rgb(r,g,b)
  gfx.set(r/255,g/255,b/255,1)
end
local function rect(x,y,w,h,r,g,b)
  rgb(r,g,b); gfx.rect(x,y,w,h,true)
end
local function txt(x,y,s,r,g,b)
  rgb(r or 225,g or 225,b or 225); gfx.x=x; gfx.y=y; gfx.drawstr(s)
end
local function inside(x,y,w,h,mx,my)
  return mx >= x and mx < x+w and my >= y and my < y+h
end

local function get_take()
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then return nil end
  local take = reaper.MIDIEditor_GetTake(editor)
  if not take or not reaper.ValidatePtr2(0,take,'MediaItem_Take*') or not reaper.TakeIsMIDI(take) then return nil end
  return take
end

-- Visual playback monitor. Read notes from the target track's MIDI item when
-- SET TARGET has been used; otherwise use the active MIDI Editor's take.
-- This is display-only: it never inserts or modifies MIDI events.
local function playback_take_at(pos)
  if target_track and reaper.ValidatePtr2(0,target_track,'MediaTrack*') then
    for i=0,reaper.CountTrackMediaItems(target_track)-1 do
      local item=reaper.GetTrackMediaItem(target_track,i)
      local st=reaper.GetMediaItemInfo_Value(item,'D_POSITION')
      local en=st+reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
      if pos>=st and pos<en then
        local tk=reaper.GetActiveTake(item)
        if tk and reaper.TakeIsMIDI(tk) then return tk end
      end
    end
    return nil -- avoid silently showing the wrong track
  end
  local tk=get_take()
  if tk then
    local item=reaper.GetMediaItemTake_Item(tk)
    local st=reaper.GetMediaItemInfo_Value(item,'D_POSITION')
    local en=st+reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
    if pos>=st and pos<en then return tk end
  end
  return nil
end
-- Returns exact fretboard cells instead of pitches. A MIDI pitch may be played
-- on several strings; highlighting all of them looks like a chord when only
-- one note is sounding. Prefer lower frets and distinct strings for chords.
local function active_playback_pitches()
  local cells={}
  if not playback_highlight or not transport_running() then return cells end
  local pos=reaper.GetPlayPosition()
  local tk=playback_take_at(pos)
  if not tk then return cells end
  local now=reaper.time_precise()
  if tk~=playback_cache.take or now-playback_cache.refreshed>0.18 then
    playback_cache.take=tk
    playback_cache.refreshed=now
    playback_cache.notes={}
    local _,n=reaper.MIDI_CountEvts(tk)
    for i=0,n-1 do
      local ok,_,muted,st,en,_,pitch=reaper.MIDI_GetNote(tk,i)
      -- Skip keyswitches and notes outside a plausible fretboard range.
      if ok and not muted and pitch>=0 and pitch<=127 then
        playback_cache.notes[#playback_cache.notes+1]={st,en,pitch}
      end
    end
  end
  local ppq=reaper.MIDI_GetPPQPosFromProjTime(tk,pos)
  local sounding={}
  for _,n in ipairs(playback_cache.notes) do
    -- Exact interval: adjacent non-overlapping notes never glow together.
    if n[1] <= ppq and ppq < n[2] then sounding[n[3]]=true end
  end
  local pitches={}
  for pitch in pairs(sounding) do pitches[#pitches+1]=pitch end
  table.sort(pitches)
  local used_strings={}
  for _,pitch in ipairs(pitches) do
    local candidates={}
    for string=1,#tuning do
      local fret=pitch-tuning[string]
      if fret>=0 and fret<=frets then
        candidates[#candidates+1]={string=string,fret=fret}
      end
    end
    table.sort(candidates,function(a,b)
      if a.fret~=b.fret then return a.fret<b.fret end
      return a.string>b.string
    end)
    local chosen=nil
    for _,c in ipairs(candidates) do
      if not used_strings[c.string] then chosen=c;break end
    end
    chosen=chosen or candidates[1]
    if chosen then
      cells[chosen.string..':'..chosen.fret]=true
      used_strings[chosen.string]=true
    end
  end
  return cells
end

local function sync_cursor()
  cursor_qn = reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition())
  status = 'Position synchronized with REAPER edit cursor.'
end

local function insert_pitch(pitch)
  local take = get_take()
  if not take then
    status = 'Open a MIDI item in the main MIDI Editor first.'
    return
  end
  if take ~= last_take then
    last_take = take
    sync_cursor()
  end
  if cursor_qn == nil then sync_cursor() end
  local item = reaper.GetMediaItemTake_Item(take)
  local item_start = reaper.GetMediaItemInfo_Value(item,'D_POSITION')
  local item_end = item_start + reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
  local start_time = reaper.TimeMap2_QNToTime(0,cursor_qn)
  local end_time = reaper.TimeMap2_QNToTime(0,cursor_qn + step_qn)
  if start_time < item_start - 1e-7 or start_time >= item_end - 1e-7 then
    status = 'Cursor is outside this MIDI item. Move cursor inside item, then Sync.'
    return
  end
  if end_time > item_end then end_time = item_end end
  if end_time <= start_time then
    status = 'No room to insert this note.'
    return
  end
  reaper.Undo_BeginBlock()
  local ok = insert_note_pair(take,start_time,end_time,pitch,velocity,keyswitch_pitch())
  if ok then
    reaper.MIDI_Sort(take)
    reaper.MIDI_RefreshEditors(take)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock('Insert guitar fretboard note: '..note_name(pitch),-1)
    cursor_qn = cursor_qn + step_qn
    reaper.SetEditCurPos(reaper.TimeMap2_QNToTime(0,cursor_qn),false,false)
    last_note = note_name(pitch)..' (MIDI '..pitch..')'
    status = 'Inserted '..last_note..' + '..articulation_name()
  else
    reaper.Undo_EndBlock('Guitar fretboard: no note inserted',-1)
    status = 'REAPER rejected MIDI_InsertNote.'
  end
end

-- Studio Edition UI (native REAPER gfx, no external dependencies)
local C = {
  bg={15,17,23}, surface={25,28,37}, panel={32,36,47},
  border={50,56,70}, hover={53,60,77}, white={241,244,250},
  muted={148,157,176}, faint={103,113,132}, accent={235,76,95},
  accentdim={93,42,55}, mint={79,210,171}, amber={248,189,91},
  fretdark={37,42,54}, fretmark={47,53,69}
}
local function color(c,a)
  gfx.set(c[1]/255,c[2]/255,c[3]/255,a or 1)
end
local function fill(x,y,w,h,c)
  if w<=0 or h<=0 then return end
  color(c); gfx.rect(x,y,w,h,1)
end
local function line(x,y,x2,y2,c)
  color(c); gfx.line(x,y,x2,y2)
end
local function text(x,y,value,c,font)
  gfx.setfont(1,'Arial',font or 14)
  color(c or C.white); gfx.x=x;gfx.y=y;gfx.drawstr(tostring(value))
end
local function center_text(x,y,w,h,value,c,font)
  gfx.setfont(1,'Arial',font or 14)
  local tw,th=gfx.measurestr(tostring(value))
  text(x+(w-tw)/2,y+(h-th)/2,value,c,font)
end
local function panel(x,y,w,h)
  fill(x,y,w,h,C.surface)
  color(C.border);gfx.rect(x,y,w,h,0)
end
local function action(x,y,w,h,label,active,mx,my,clicked,variant)
  local hovered=inside(x,y,w,h,mx,my)
  local bg=active and C.accentdim or (hovered and C.hover or C.panel)
  if variant=='primary' then bg=hovered and {249,96,112} or C.accent end
  if variant=='live' and active then bg={41,122,99} end
  fill(x,y,w,h,bg)
  color(active and C.accent or C.border);gfx.rect(x,y,w,h,0)
  center_text(x,y,w,h,label,(variant=='primary' or (variant=='live' and active)) and C.white or (active and C.white or C.muted),13)
  return clicked and hovered
end
local function heading(x,y,num,title,detail)
  text(x,y,num,C.accent,12)
  text(x+32,y-3,title,C.white,17)
  if detail then text(x+235,y,detail,C.faint,12) end
end
local function display_status(x,y,w)
  local ok = not (status:find('No ') or status:find('failed') or status:find('outside') or status:find('Disarm') or status:find('Choose ') or status:find('rejected'))
  fill(x,y,4,42,ok and C.mint or C.amber)
  fill(x+4,y,w-4,42,C.surface)
  text(x+16,y+5,'STATUS',C.faint,10)
  text(x+16,y+21,status,C.muted,12)
end
local scroll=0
local max_scroll=0
local prev_wheel=0
local function draw()
  local mx,my=gfx.mouse_x,gfx.mouse_y
  local down=(gfx.mouse_cap & 1) == 1
  local clicked=down and not mouse_was_down
  local released=not down and mouse_was_down
  mouse_was_down=down
  if released and held_note then live_release() end
  local w,h=gfx.w,gfx.h
  if w<930 then w=930 end
  local wheel=gfx.mouse_wheel
  if wheel ~= 0 then
    scroll=math.max(0,math.min(max_scroll,scroll-wheel/2))
    gfx.mouse_wheel=0
  end
  local left=24
  local width=w-48
  local yoff=104-scroll
  fill(0,0,gfx.w,gfx.h,C.bg)
  local sounding=active_playback_pitches()
  local take=get_take()
  if take and take~=last_take then last_take=take;sync_cursor() end
  -- TUNING PANEL
  local y=yoff
  panel(left,y,width,100)
  heading(left+20,y+13,'01','TUNING','PRESETS / CUSTOM 6-8 STRINGS')
  if action(left+20,y+49,355,36,tuning_name..'   v',false,mx,my,clicked) then tuning_menu() end
  local low={}
  for i=#tuning,1,-1 do low[#low+1]=labels[i] end
  text(left+391,y+53,#tuning..' strings   /   '..table.concat(low,'  -  '),C.muted,14)
  -- STEP PANEL
  y=y+113
  panel(left,y,width,98)
  heading(left+20,y+11,'02','MIDI STEP','NOTE LENGTH / VELOCITY / CURSOR')
  local bx=left+20
  for i,div in ipairs(divisions) do
    if action(bx,y+49,67,32,div[1],i==div_idx,mx,my,clicked) then
      div_idx=i;step_qn=divisions[i][2]
    end
    bx=bx+73
  end
  local right=left+width-19
  if action(right-365,y+49,89,32,'SYNC',false,mx,my,clicked) then sync_cursor() end
  if action(right-270,y+49,44,32,'<',false,mx,my,clicked) then
    if not cursor_qn then sync_cursor() end
    cursor_qn=cursor_qn-step_qn
    reaper.SetEditCurPos(reaper.TimeMap2_QNToTime(0,cursor_qn),false,false)
  end
  if action(right-221,y+49,44,32,'>',false,mx,my,clicked) then
    if not cursor_qn then sync_cursor() end
    cursor_qn=cursor_qn+step_qn
    reaper.SetEditCurPos(reaper.TimeMap2_QNToTime(0,cursor_qn),false,false)
  end
  text(right-168,y+29,'VELOCITY',C.faint,11)
  if action(right-168,y+49,34,32,'-',false,mx,my,clicked) then velocity=math.max(1,velocity-5) end
  center_text(right-130,y+49,47,32,velocity,C.white,14)
  if action(right-80,y+49,34,32,'+',false,mx,my,clicked) then velocity=math.min(127,velocity+5) end
  -- TARGET / LIVE PANEL
  y=y+111
  panel(left,y,width,77)
  if action(left+20,y+20,155,38,'SET TARGET',false,mx,my,clicked,'primary') then capture_target_track() end
  if action(left+184,y+20,133,38,live_mode and 'LIVE  ON' or 'STEP MODE',live_mode,mx,my,clicked,'live') then
    live_mode=not live_mode
    status=live_mode and 'LIVE: press and hold a fret during playback/recording.' or 'STEP: clicking inserts at cursor.'
  end
  if action(left+width-382,y+20,175,38,playback_highlight and 'FOLLOW MIDI  ON' or 'FOLLOW MIDI  OFF',playback_highlight,mx,my,clicked) then
    playback_highlight=not playback_highlight
  end
  if action(left+width-196,y+20,174,38,live_quantize and 'QUANTIZE  ON' or 'QUANTIZE  OFF',live_quantize,mx,my,clicked) then
    live_quantize=not live_quantize
  end
  text(left+335,y+10,'TARGET TRACK',C.faint,11)
  text(left+335,y+31,track_name(target_track),C.white,15)
  -- VST INSTRUMENT PANEL
  y=y+90
  panel(left,y,width,88)
  heading(left+20,y+12,'03','INSTRUMENT','KEYSWITCH PROFILE')
  if action(left+20,y+45,446,31,active_profile().name..'   v',false,mx,my,clicked) then instrument_menu() end
  text(left+482,y+53,'Profiles change keyswitches, not tuning.',C.muted,13)
  -- FRETBOARD
  y=y+102
  local fret_top=y+63
  local ch=39
  local fret_h=#tuning*ch
  local fret_panel_h=84+fret_h
  panel(left,y,width,fret_panel_h)
  heading(left+20,y+13,'04','FRETBOARD','CLICK TO INSERT / GREEN = MIDI PLAYBACK')
  local gl=left+81
  local playable=width-103
  local cw=playable/(frets+1)
  for f=0,frets do
    local xx=gl+f*cw
    center_text(xx,y+35,cw,23,f,C.faint,12)
  end
  for s=1,#tuning do
    local row_y=fret_top+(s-1)*ch
    text(left+21,row_y+10,labels[s],C.white,14)
    for f=0,frets do
      local xx=gl+f*cw
      local pitch=tuning[s]+f
      local hit=inside(xx+1,row_y+1,cw-2,ch-2,mx,my)
      local marked=(f==3 or f==5 or f==7 or f==9 or f==12 or f==15)
      local playing=sounding[s..':'..f]
      local bg=playing and {39,139,111} or (hit and C.accentdim or (f==0 and {58,64,79} or (marked and C.fretmark or C.fretdark)))
      fill(xx+1,row_y+1,cw-3,ch-3,bg)
      if playing then
        color(C.mint); gfx.rect(xx+1,row_y+1,cw-3,ch-3,0)
      end
      if f==0 then fill(xx+1,row_y+1,3,ch-3,C.accent) end
      center_text(xx,row_y+1,cw-2,ch-3,note_name(pitch),playing and C.white or (hit and C.white or C.muted),13)
      if clicked and hit then
        if live_mode then live_press(pitch) else insert_pitch(pitch) end
      end
    end
  end
  -- ARTICULATIONS PANEL
  y=y+fret_panel_h+14
  local art_list=articulations()
  local cols=3
  local rows=math.ceil((#art_list+1)/cols)
  local art_panel_h=132+rows*39
  panel(left,y,width,art_panel_h)
  heading(left+20,y+12,'05','ARTICULATIONS',active_profile().name)
  text(left+20,y+44,'SELECT ACTIVE KEYSWITCH',C.faint,11)
  local art_left=left+20
  local spacing=9
  local aw=(width-40-(cols-1)*spacing)/cols
  local ay=y+66
  for i=0,#art_list do
    local col=i%cols
    local row=math.floor(i/cols)
    local ax=art_left+col*(aw+spacing)
    local yy=ay+row*39
    local art=art_list[i]
    local label='NONE  /  no keyswitch'
    if art then
      local midi=art.midi+keyswitch_offset
      local pitch=(midi>=0 and midi<=127) and note_name(midi) or 'invalid'
      label=art.name..'  /  '..pitch
    end
    if action(ax,yy,aw,32,label,articulation_idx==i,mx,my,clicked) then
      articulation_idx=(i>0 and articulation_idx==i) and 0 or i
      status='Articulation: '..articulation_name()..' / MIDI '..tostring(keyswitch_pitch() or '-')
    end
  end
  local control_y=ay+rows*39+8
  text(left+20,control_y+7,'KEYSWITCH OFFSET    '..(keyswitch_offset>=0 and '+' or '')..keyswitch_offset,C.muted,12)
  if action(left+263,control_y,63,30,'-12',false,mx,my,clicked) then keyswitch_offset=math.max(-24,keyswitch_offset-12) end
  if action(left+334,control_y,63,30,'+12',false,mx,my,clicked) then keyswitch_offset=math.min(60,keyswitch_offset+12) end
  if action(left+405,control_y,72,30,'RESET',false,mx,my,clicked) then keyswitch_offset=0 end
  text(left+494,control_y+7,'Selected: '..articulation_name(),C.muted,12)
  -- FOOTER
  y=y+art_panel_h+12
  display_status(left,y,width)
  text(left+2,y+53,'LAST NOTE    '..last_note,C.muted,12)
  if live_mode then
    text(left+2,y+74,'LIVE: prepare an empty MIDI item on target; leave target disarmed; hold and release frets while playing.',C.mint,12)
  else
    text(left+2,y+74,'STEP: open a MIDI item in MIDI Editor; click frets to insert at the edit cursor.',C.mint,12)
  end
  max_scroll=math.max(0,y+108-(h-1))
  if scroll>max_scroll then scroll=max_scroll end
  -- Fixed title bar, rendered last so scrolled content stays beneath it.
  fill(0,0,gfx.w,90,C.bg)
  fill(0,88,gfx.w,2,C.border)
  fill(24,18,6,42,C.accent)
  text(42,17,'FRETBOARD',C.white,26)
  text(222,29,'STUDIO EDITION',C.accent,12)
  text(42,57,'GUITAR MIDI CONTROLLER  /  REAPER',C.faint,11)
  local mode_label=live_mode and 'LIVE MODE' or 'STEP MODE'
  local mode_col=live_mode and C.mint or C.muted
  text(gfx.w-166,20,mode_label,mode_col,14)
  text(gfx.w-166,47,tuning_name,C.muted,12)
  if max_scroll>0 then
    local usable=h-102
    local bar_h=math.max(35,usable*h/(h+max_scroll))
    local bar_y=92+(usable-bar_h)*scroll/max_scroll
    fill(gfx.w-6,bar_y,4,bar_h,C.faint)
  end
end

local function loop()
  local key=gfx.getchar()
  if key<0 or key==27 then
    if held_note then live_release() end
    return
  end
  draw()
  gfx.update()
  reaper.defer(loop)
end

gfx.init(name,win_w,win_h,0,160,100)
reaper.atexit(function() gfx.quit() end)
loop()
