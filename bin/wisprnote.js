// wisprnote.js: Wispr Flow's notetaker, read and stopped through its Meeting Recorder window (Accessibility).
//   osascript -l JavaScript bin/wisprnote.js state   prints "recording" (the window shows its "Stop listening" button),
//                                                    "idle" (window open, not recording) or "none" (no Meeting Recorder)
//   osascript -l JavaScript bin/wisprnote.js stop    presses "Stop listening"; prints "stopped", "idle" or "none"
//   osascript -l JavaScript bin/wisprnote.js close   closes the Meeting Recorder when it is not recording (v87, 2026-10-30);
//                                                    prints "closed", "recording" (left open) or "none"
// Why not the menu: Wispr's Notetaker menu keeps showing "Start Notetaker" while it records (2026-10-28), and
// System Events' "entire contents" comes back empty for this Electron window after it moves, so this walks the tree itself.
// Starting stays on the menu (director.sh wispr_start: Notetaker > Start Notetaker).
function run(argv) {
  var mode = argv[0] || 'state';
  var se = Application('System Events');
  var p;
  try { p = se.processes.byName('Wispr Flow'); p.name(); } catch (e) { return 'none'; }
  try { p.attributes.byName('AXManualAccessibility').value = true; } catch (e) {}   // Electron builds its tree on request
  var w;
  try { w = p.windows.byName('Meeting Recorder'); w.name(); } catch (e) { return 'none'; }
  if (mode === 'shut') {   // v88: close without reading the tree (the caller already knows it is not recording, from the mic list)
    try {
      var bs0 = w.buttons();
      for (var j0 = 0; j0 < bs0.length; j0++) {
        try { if (bs0[j0].subrole() === 'AXCloseButton') { bs0[j0].actions.byName('AXPress').perform(); return 'closed'; } } catch (x) {}
      }
    } catch (x) {}
    return 'idle';
  }
  var found = null;
  function walk(e, d) {
    if (found || d > 30) return;
    var kids;
    try { kids = e.uiElements(); } catch (x) { return; }
    for (var i = 0; i < kids.length && !found; i++) {
      var k = kids[i];
      try { if (k.role() === 'AXButton' && k.description() === 'Stop listening') { found = k; return; } } catch (x) {}
      walk(k, d + 1);
    }
  }
  walk(w, 0);
  if (mode === 'close') {
    if (found) return 'recording';
    try {
      var bs = w.buttons();
      for (var j = 0; j < bs.length; j++) {
        try { if (bs[j].subrole() === 'AXCloseButton') { bs[j].actions.byName('AXPress').perform(); return 'closed'; } } catch (x) {}
      }
    } catch (x) {}
    return 'idle';
  }
  if (mode === 'stop') {
    if (!found) return 'idle';
    found.actions.byName('AXPress').perform();
    return 'stopped';
  }
  return found ? 'recording' : 'idle';
}
