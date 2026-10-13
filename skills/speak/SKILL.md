---
name: speak
description: Control Claudio voice output for this session — toggle, set level (quiet/answers/narrate), switch the active session, pause, skip, or catch up to live
---
<!-- claudio-skill v1 -->
# Claudio voice control

Claudio is a menu bar app that reads Claude Code sessions aloud. This skill controls it for the current session.

## Usage
/speak                     Make this session the active (spoken) one
/speak on                  Same as above
/speak off                 Set this session to quiet (events only)
/speak quiet|answers|narrate   Set this session's level
/speak pause | resume | toggle
/speak skip                Skip the current sentence
/speak live                Abandon catch-up, jump to live
/speak status
/speak sessions

## Instructions
Run exactly one of the following shell commands based on the argument, then report its output in one line. Do not add commentary. `CLAUDIO` resolves to the bundled CLI; fall back to the symlink.

CLAUDIO="/Applications/Claudio.app/Contents/Helpers/claudio"; [ -x "$CLAUDIO" ] || CLAUDIO="claudio"

- no argument or `on`:     $CLAUDIO switch
- `off`:                   $CLAUDIO level quiet
- `quiet`/`answers`/`narrate`: $CLAUDIO level <arg>
- `pause`/`resume`/`toggle`/`skip`/`live`/`status`/`sessions`: $CLAUDIO <arg>

The CLI identifies this session from $CLAUDE_CODE_SESSION_ID automatically. If the command exits 1, tell the user "Claudio is not running" and stop.
