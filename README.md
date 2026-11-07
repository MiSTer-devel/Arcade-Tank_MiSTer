# Tank for MiSTer FPGA

FPGA recreation of **Tank** (Kee Games / Atari, 1974), the two-player tank
battle in a maze with mines. The game has no CPU: it is two boards of TTL
logic, a 2 KB ROM holding the maze and the object shapes, and analogue
circuits for the engine, shot and explosion sounds.

The core recreates the boards, not the game. It was built from the Board I /
Board II schematics and the Kee Games operator and service manuals, with
MAME's Tank netlist as a cross-check. Where the netlist and the schematics
disagree, the core follows the schematics.

<img src="https://img.shields.io/badge/Quartus-17.0.2-blue" alt="Quartus 17.0.2"> <img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="GPL-3.0-or-later">

---

## Supported games

| MRA | MAME set | Cabinet |
|-----|----------|---------|
| `Tank.mra` | `tank` | Upright |
| `Tank II.mra` | `tankii` | Upright (same boards and ROM as Tank) |
| `_alternatives/_Tank/Tank Cocktail.mra` | `tank` | Cocktail table, picture turned 90 degrees on HDMI |

All three run on the same bitstream.

---

## Installing

1. Copy `releases/Arcade-Tank_<date>.rbf` to `/media/fat/_Arcade/cores/` and
   rename it `Tank_<date>.rbf`, as the MiSTer distribution does.
2. Copy `releases/Tank.mra` and `releases/Tank II.mra` to
   `/media/fat/_Arcade/`. For the cocktail table, also copy the
   `releases/_alternatives/_Tank` folder to `/media/fat/_Arcade/_alternatives/`.
3. Put the MAME ROM set `tank.zip` in `/media/fat/games/mame/`. `Tank II.mra`
   also accepts `tankii.zip`.

**No ROM data is in this repository.** The MRA files name the ROM (90-2006,
at K10) and give its checksum.

Keep only one `Tank_*.rbf` in `_Arcade/cores/`. An MRA finds its core by name
prefix, so an older dated file left there may load instead of the new one.

---

## Controls

Each player drives a tank with two levers, one per tread, as on the cabinet.
Both levers forward: speed up. Both back: slow down and stop. One forward and
one back: turn. A lever on its own does nothing, as on the real board.

| Cabinet | MiSTer (player 1 = black tank, player 2 = white tank) |
|---------|--------|
| Right tread lever, forward / back | `R_FWD` / `R_REV` |
| Left tread lever, forward / back | `L_FWD` / `L_REV` |
| Fire button | `Fire` |
| Coin slot 1 / coin slot 2 | `Coin` / `Start` (player 1's controller) |

The d-pad is a single-hand shortcut with no cabinet counterpart: up speeds
up, down slows down, left and right turn.

The cabinet has no start button: a coin starts the game, as on the board.
With Coin Mode at 50c a game needs two coins, or one in each slot at once.

### OSD options

| Option | Effect |
|--------|--------|
| Aspect ratio | Original, Full Screen, or the two custom ratios from `MiSTer.ini` |
| Orientation | Original, or Flip (turns the HDMI picture 180 degrees) |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer (HDMI) |
| Maze | Original, or Alternate: the second maze in the ROM, selected on the board by jumper JU1 |
| Coin Mode | 25c (one coin a game) or 50c (two coins, longer game): the board's coin-mode switch |
| Monitor | Upright, Cocktail CW or Cocktail CCW (set by each MRA) |
| Master / Missile / Explosion Volume | Overall and per-sound volume |
| Cabinet Speaker | On: the sound through a model of the cabinet's small speakers. Off: the raw circuit output |
| Operator Adjust | The board's trimmers: white tank's missile range, play time, engine putt rate, engine volume. Option 0 is the factory setting |
| CRT Adjust (analog) | H-Size, H-Position and V-Shift for a 15 kHz CRT on the analog output. Leave it Off for HDMI |
| Reset | Restart the game |

The two tanks have their own speakers on the cabinet: the core plays the
black tank on the left channel and the white tank on the right.

Orientation, Scale and the cocktail rotation act on the HDMI picture only;
the analog output always carries the board's own raster. On HDMI the two
interlaced fields are woven into one 774 x 504 frame in the core's own
framebuffer, then shown as it is or turned, so the picture is steady at any
output resolution (the scaler's own weave needs at least 504 output lines).
CRT Adjust is for the analog output; it also reaches HDMI, where its V-Shift
makes the picture wrap.

---

## Accuracy notes

Everything runs from the board's 14.318181 MHz crystal, regenerated exactly
by the PLL. The parts below follow the schematics:

- **Raster.** 904 clocks a line and 521 half-lines a field: a true
  interlaced picture at 60.80 fields a second, alternate fields starting
  half a line apart. The board's V counter steps at the middle of each
  line, so in one of the two fields the picture moves down a row part-way
  along every line; the core keeps that. VSync keeps the board's half-line
  timing, so a CRT interlaces the fields as the original monitor did; DE
  spans whole lines and the field flag marks the field for MiSTer's scaler.
- **Video levels.** Four TTL outputs summed in a resistor network give five
  grey levels: a grey background; black for the black tank, its shells and
  the mines; white for the walls, the digits and the white tank and its
  shells; a darker black and a brighter white where the outputs overlap.
- **Motion.** Tanks and shells move by the board's "slipping counter": a
  position counter whose period is exactly one line while the object stands
  still, so the object stays put on the screen. On a frame where it moves,
  one cycle of the counter has a different length, which shifts the
  object by that many pixels.
- **Controls.** The tread levers decode as the board's NOR gates do; the
  speed and rotation counters behave as the board's 74193 and 7493 counters
  (checked against a gate-level model of them); rotation steps once every six
  fields, so a full turn takes about 3.2 s.
- **Timers.** Shell range and explosion lengths come from the one-shots'
  datasheet timing and the board's resistor and capacitor values, the play
  time from the 555 timer and its pot, and the score flash near the end of a
  game from the circuit that senses the timer's capacitor.
- **Sound.** Each tank's engine is the board's NE566 oscillator, 555 putt
  timer and MC3340 voltage-controlled attenuator; the shot and explosion
  sounds are filtered noise with the board's diode peak-hold envelopes.
- **Coins.** The 25c / 50c switch and both coin mechanisms as wired, with
  the coin pulse acting as start.

### Where MAME's netlist differs

MAME's Tank netlist was the cross-check throughout. Where it disagreed with
the schematics, the core follows the schematics; examples are the score
counter wiring, an output pin of the HD1 / HD2 flip-flops, and the pin map of
the 7492 counter that times rotation (MAME's library model swaps two of its
outputs). Most circuit timings that depend on analogue parts were measured
in MAME's netlist simulator, `nltool`, with the corrected netlist; the
DM9602 one-shots that time the shells use their datasheet timing instead, as
MAME's model of that chip simplifies it.

---

## Verification

This core was developed simulation-first, with AI assistance, under human
review. Each part was checked by simulation against the schematics and
against measurements of the corrected MAME netlist before it counted as done.
The test benches are kept with the development sources, not in this
repository.

| Part | Method |
|------|--------|
| Controls, collisions and scoring | The shipped logic compared with gate-level models built from the board's TTL parts |
| Motion | The "slipping counter" compared with a gate-level model of it: idle lock with no drift, all 32 headings |
| Analogue timings and levels | Measured in `nltool` on the corrected netlist with MAME's device models; datasheet timing for the DM9602 |
| Whole game | Coin, start, play and game over through the full core |
| HDMI framebuffer | Every framebuffer byte checked for upright and all three rotations while the DDR port stalls; the full core through the framebuffer on both mazes: each frame is the rotated weave of both fields, and a still picture stays identical frame to frame; at every scaler VBL the newest completed frame is shown, never one being written or an older one |
| CRT Adjust | Every DE line, sync edge and field flag checked against the native raster for each control, the half-line VSync included |
| Release | This repository, compiled on its own: byte-identical to the released bitstream |

Shipped build (Cyclone V 5CSEBA6U23I7): 10,320 ALMs (25 %), 79 RAM blocks
(14 %), 54 DSP blocks (48 %). Timing closes on every corner: worst setup
slack +0.645 ns, worst hold +0.250 ns.

---

## Building

You need Quartus Prime **17.0.2** (Lite or Standard), as for all MiSTer cores.

1. Open `Tank.qpf`, or run `quartus_sh --flow compile Tank` in this folder.
2. The bitstream is `output_files/Tank.rbf`. For a release, copy it to
   `releases/Arcade-Tank_YYYYMMDD.rbf`.

The framework writes the build date into the bitstream, so a build made on
another day differs from the release in those bytes only.

Add source files to `files.qip` by hand, not through the Quartus GUI: the GUI
writes them into `Tank.qsf` instead and the two lists drift apart.

---

## Repository layout

```text
Tank.qpf / .qsf / .sdc    Quartus project and timing constraints
Arcade-Tank.sv            MiSTer top level: menu, clocks, video and audio out
files.qip                 Source file list
rtl/                      The game boards (tank_core.sv is their top)
  game/                   Controls, tank and shell motion, shells, collisions
                          and scoring, the 9316 counter
  video/                  Sync, maze and score digits, mines, tanks, shells and
                          explosions; MiSTer output: CRT Adjust, the HDMI
                          framebuffer (weave, cocktail rotation, Flip)
  sound/                  Engine, shot and explosion circuits
  mem/                    The 2 KB ROM, loaded from the MRA
  pll.v, pll.qip          PLL
sys/                      MiSTer framework, unmodified
releases/                 Bitstream and MRA files
```

---

## Licensing

The combined work is **GPL-3.0-or-later** (see `LICENSE`). `NOTICE.md` lists
where each part came from.

| Component | License |
|-----------|---------|
| `Arcade-Tank.sv`, `rtl/` (the core's own files): RetroShrimp | GPL-2.0-or-later where marked; distributed here as part of the GPL-3.0-or-later work |
| `rtl/video/crt_adjust.sv`: Umberto Parisi (rmonic79) | GPL-3.0-or-later |
| `sys/`: MiSTer framework, Alexey Melnikov and contributors | GPL-2.0-or-later / GPL-3.0-or-later, as marked in each file |

---

## Credits

- **RetroShrimp**: the core.
- **Kee Games / Atari**: the original hardware and game.
- **The MAME team**: the Tank netlist (`nl_tank.cpp`) and the `netlist`
  library and `nltool` simulator, the cross-check for the whole core.
- **Alexey Melnikov (Sorgelig)** and the MiSTer-devel community: the MiSTer
  framework.
- **Umberto Parisi (rmonic79)**: CRT Adjust, from
  [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust).
