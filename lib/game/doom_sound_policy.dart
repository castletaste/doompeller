/// Doom sound priorities: smaller numbers survive channel pressure first.
/// Values are compatibility data from id's published S_sfx sound definitions:
/// https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/sounds.c
int doomSoundPriority(String soundId) => switch (soundId.toUpperCase()) {
  'DSTELEPT' ||
  'DSPLDETH' ||
  'DSPDIEHI' ||
  'DSBRSDTH' ||
  'DSCYBDTH' ||
  'DSSPIDTH' => 32,
  'DSBAREXP' || 'DSTINK' || 'DSGETPOW' => 60,
  'DSRXPLOD' ||
  'DSFIRSHT' ||
  'DSFIRXPL' ||
  'DSSKLATK' ||
  'DSSGTATK' ||
  'DSCLAW' ||
  'DSPODTH1' ||
  'DSPODTH2' ||
  'DSPODTH3' ||
  'DSBGDTH1' ||
  'DSBGDTH2' ||
  'DSSGTDTH' ||
  'DSCACDTH' ||
  'DSSKLDTH' ||
  'DSHOOF' ||
  'DSMETAL' => 70,
  'DSSWTCHN' ||
  'DSSWTCHX' ||
  'DSSLOP' ||
  'DSITEMUP' ||
  'DSWPNUP' ||
  'DSNOWAY' => 78,
  'DSSPISIT' => 90,
  'DSCYBSIT' => 92,
  'DSBRSSIT' => 94,
  'DSPLPAIN' ||
  'DSDMPAIN' ||
  'DSPOPAIN' ||
  'DSVIPAIN' ||
  'DSMNPAIN' ||
  'DSPEPAIN' ||
  'DSOOF' => 96,
  'DSPOSIT1' ||
  'DSPOSIT2' ||
  'DSPOSIT3' ||
  'DSBGSIT1' ||
  'DSBGSIT2' ||
  'DSSGTSIT' ||
  'DSCACSIT' => 98,
  'DSPSTART' || 'DSPSTOP' || 'DSDOROPN' || 'DSDORCLS' => 100,
  'DSSAWIDL' => 118,
  'DSSTNMOV' => 119,
  'DSPOSACT' || 'DSBGACT' || 'DSDMACT' => 120,
  _ => 64,
};
