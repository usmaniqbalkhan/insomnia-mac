# Insomnia for Intel Macs (macOS 12 and later)

Keeps this Mac running with the lid closed, so cloud sessions, downloads and
agents keep working. Built for an Intel MacBook on macOS 15, because none of
these five repos run there:

| Repo | What it is | Why not usable here |
|---|---|---|
| semaja2/insomniax | Original InsomniaX (2015) | Archived, needs an unsigned kernel extension; dead on macOS 11+ |
| AxonDragonScale/Insomnia | Swift menu bar timer | Only blocks *idle* sleep (like `caffeinate`); the lid still sleeps the Mac |
| mdblack98/Insomnia | USB keep-alive utility | Unrelated to Mac sleep |
| vorssaint/vorssaint-utils | Big menu bar toolkit with "Keep awake" | Apple Silicon only |
| krishhgg/Insomnia | Best design: timed lid-closed sessions with recovery | Apple Silicon + macOS 26 + Swift 6.2 only |

krishhgg/Insomnia and Vorssaint both work by flipping macOS's own
`pmset disablesleep` bit. This folder does the same thing natively, with the
same safety ideas (sudoers rule limited to two commands, a once-a-minute
recovery agent, a battery floor).

## Install

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/usmaniqbalkhan/insomnia-mac.git
cd insomnia-mac
./install.sh
```

The installer ends by printing one `sudo install ...` command. Run it once with
your Mac password, then `insomnia on` or click the eye in the menu bar.

## What gets installed

- `/usr/local/bin/insomnia`: the command line tool.
- `~/Applications/Insomnia.app`: eye icon in the menu bar (built from `MenuBar/main.swift`).
- `~/Library/LaunchAgents/com.usman.insomnia.backstop.plist`: runs `insomnia backstop` every minute.
- `~/Library/LaunchAgents/com.usman.insomnia.menubar.plist`: starts the menu bar app at login.
- `~/Library/LaunchAgents/com.usman.insomnia.netguard.plist`: the Wi-Fi guard.
- `~/Library/LaunchAgents/com.usman.insomnia.secure.plist`: the Secure Background Mode monitor (runs only while the mode is on).
- `~/Library/LaunchAgents/com.usman.insomnia.autoguard.plist`: the automatic guard.
- `/etc/sudoers.d/insomnia`: **you install this one with your password.** It lets your
  user run exactly `/usr/bin/pmset -a disablesleep 1` and `... 0` without a password.

## Use

```bash
insomnia on          # stay awake until you say otherwise
insomnia on 8h       # stay awake for 8 hours
insomnia off         # normal sleep again
insomnia status
```

Or click the eye in the menu bar.

## Lock on lid close

With sleep disabled, closing the lid no longer locks the screen by itself,
so anyone could open the lid and use the Mac. The menu bar app watches the
lid through IOKit and, when it closes, locks the screen the same way
Control-Command-Q does (processes keep running; opening the lid shows the
password screen). It is on by default; "Lock Screen When Lid Closes" in the
menu turns it off, for example while using an external display in clamshell
mode. "Lock Screen Now" (Command-L in the menu) tests it.

## Network guard

An awake Mac can still lose Wi-Fi: on an Intel MacBook the link sometimes
drops while the display is off and nothing is using it, and macOS can sit
unassociated for minutes before it rejoins. While a keep-awake session or Secure Background Mode is on, or while the
Claude app is working (it holds its own no-idle-sleep assertion then), the
`com.usman.insomnia.netguard` agent pings the router every 5 seconds (which
also keeps the link from idling). If nothing answers for 30 seconds it turns
Wi-Fi off and on, which forces a fresh join and DHCP lease; it retries every
minute, then every 5 minutes. Everything is written to
`~/Library/Logs/Insomnia/netguard.log`, and `insomnia status` shows the last
lines. It needs no password: `networksetup -setairportpower` works for an
admin user.

## Secure Background Mode

For leaving the Mac with the lid open while browser automation runs: the Mac
stays awake, the screen is locked, the display is off, and the jobs carry on.
You come back, type your password, and review what finished.

```bash
insomnia secure on            # keep awake, lock, display off (in that order)
insomnia secure on 3h         # the same, for 3 hours at most
insomnia secure on --hold     # stay on until `insomnia secure off`
insomnia secure status        # the six indicators, power state, jobs, session log
insomnia secure off           # release sleep prevention (never unlocks anything)

insomnia run --name veo -- node run.js prompts/a.txt 9301 9302   # run a command as a tracked job
insomnia watch 4321 "my script"                                   # track a process that is already running
insomnia jobs                 # running / completed / failed, with exit codes
insomnia lock                 # lock only
insomnia display-off          # lock, then display off
insomnia doctor               # hardware, macOS and Chrome compatibility check
insomnia panel                # open the control panel window
```

The menu bar eye has the same controls under **Secure Background Mode…**: the
indicators (Secure Mode, Screen Lock, Display, System Sleep Prevention, Chrome
Automation, Background Jobs, Power State), the buttons, the job list and the
session log.

### How it works

| Piece | Mechanism | Notes |
|---|---|---|
| Keep awake | a `caffeinate -i -m -s` assertion held by a monitor process | Released the moment the monitor exits. No password needed. |
| Lid-close protection | the `pmset disablesleep` session described above | Added when the sudoers rule is installed, so an accidental lid close does not sleep the Mac. Also turns the Wi-Fi guard on. |
| Lock | `SACLockScreenImmediate`, the call behind Control-Command-Q | The normal macOS password screen. Nothing here unlocks, bypasses or weakens it. |
| Display off | `pmset displaysleepnow` | Only after macOS confirms the lock. If the lock cannot be confirmed the display is left on and you are told why. |
| Jobs | `insomnia run` records pid, exit code and a log; `insomnia watch` tracks a pid | A process holding a connection to a Chrome `--remote-debugging-port` is adopted as a job automatically. |
| Monitor | a launchd agent that exists only while the mode is on | Restarted by launchd if it dies. Ends the mode 120 s after the last job finishes, at the timer, or at the battery floor. |

Nothing in this mode closes Chrome, signals a job, changes a macOS security
setting or puts the Mac to sleep.

### Automatic guard

`insomnia autoguard on` (the default) covers the case where nobody presses
anything. Every 20 s it looks for a script that drives Chrome over CDP
(Playwright `connectOverCDP`, Puppeteer `connect`, chromedriver). When one has
been there for two passes it starts the keep-awake half of the mode by itself:
sleep assertion, lid-close protection, Wi-Fi guard, job tracking. It never
locks the screen; lock whenever you like (Control-Command-Q, the lid, or
`insomnia secure on`). The mode ends on its own 120 s after the scripts finish.
`insomnia autoguard off` switches it off.

Automation that runs inside a Chrome extension leaves no trace outside the
browser and cannot be detected; use `insomnia secure on --hold` for that.

### Chrome behind the lock screen

Measured on a MacBookPro16,1 (Intel i9), macOS 15.7.9, Chrome 157, with
`tests/e2e-secure.sh`. Two headed Chrome windows were driven by Playwright
`connectOverCDP` (goto, frame fill, click, polling with evaluate, in-page
fetch downloads, screenshots, real network navigations), one started with the
plain flags a typical launcher uses, one with anti-throttling flags.

| | Display on | Locked, display off |
|---|---|---|
| Plain flags: cycles ok | 12 / 12 | 51 / 51 |
| Plain flags: median cycle | 1784 ms | 1773 ms |
| Anti-throttling flags: cycles ok | 11 / 11 | 53 / 53 |
| Anti-throttling flags: median cycle | 1785 ms | 1764 ms |
| Screenshots | all ok | all ok |
| Network navigations | 5 / 5 | 26 / 26 |

What follows from that:

- **A headed Chrome driven over CDP needs a running Chrome process and an
  awake Mac. It does not need a lit display or an unlocked session.** Pages
  stayed `visible`, `requestAnimationFrame` kept its rate, clicks and
  screenshots took the same time.
- The anti-throttling flags (`--disable-backgrounding-occluded-windows`,
  `--disable-renderer-backgrounding`, `--disable-background-timer-throttling`)
  made no measurable difference for a window that was frontmost in its own
  browser. They still matter for windows that are minimized or covered by
  other windows, so they are worth adding to a launcher.
- **Headless is not needed, and existing sessions are never switched to it.**
  Logged-in Google profiles (Gemini, Flow, Veo) rely on a headed browser.
- **What does stop working behind the lock:** anything that injects real
  keyboard or mouse events at the OS level (AppleScript `System Events`
  keystrokes, `cliclick`, pyautogui, screen-coordinate computer use). Those
  events go to the password screen. CDP input (`page.click`, `page.fill`) is
  delivered inside the browser and is unaffected.

### Tests

```bash
PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core tests/e2e-secure.sh   # locks the screen for ~4 minutes
tests/lock-check.sh                                                         # locks the screen for ~15 seconds
PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core tests/lid-closed-test.sh # start it, then close the lid for a few minutes
```

`e2e-secure.sh` covers: automation with the display on, turning the mode on
mid-run, automation with the display off, staying awake, input not exposing
the desktop, four concurrent jobs, auto-release, battery and thermal readings,
a failing job, a monitor killed with SIGKILL, and the hardware check.

### Lid closed

`tests/lid-closed-test.sh` with the keep-awake session on, lid closed for 414 s
on battery over a phone hotspot (same Mac, 2026-11-16):

| | Lid open | Lid closed |
|---|---|---|
| Plain flags: cycles ok | 12 / 12 | 151 / 151 |
| Anti-throttling flags: cycles ok | 12 / 12 | 150 / 150 |
| Median cycle (plain / anti-throttling) | 1814 / 1822 ms | 1776 / 1780 ms |
| Page visibility, rAF per cycle | visible, 99 | visible, 100 |
| Router and internet ping | ok | 63 / 63 samples |
| Wi-Fi link, IP address | active | active 63 / 63, unchanged |
| Sleep entries in the power log | 0 | 0 |
| Screen locked | no | 63 / 63 samples |

With the session on, a closed lid changes nothing for a headed Chrome driven
over CDP: same speed, pages stay `visible`, the network stays up, and the
screen is locked the whole time.

## Safety

- Keep the Mac on a desk or stand while the lid is closed, never in a bag.
- On battery, the session ends automatically at 10% (`INSOMNIA_BATTERY_FLOOR` changes it).
- A timed session ends on time even if the menu bar app is not running.
- `./uninstall.sh` removes everything and prints the one `sudo rm` for the sudoers file.
- Secure Background Mode is for a Mac on a desk with the lid open. Lid-close
  protection is a safety net, not an invitation to bag a running Mac.
- Check System Settings > Notifications > Show previews is "When Unlocked" (the
  macOS default), so notification text is hidden on the lock screen.

## License

MIT. See [LICENSE](LICENSE).
