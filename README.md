<div align="center">

<img width="100%" alt="header" src="https://capsule-render.vercel.app/api?type=waving&height=210&text=Spider%20Miner%20Bot&fontAlign=50&fontAlignY=36&fontSize=56&desc=Mining%20Shift%20%7C%20Daily%20Rewards%20%7C%20Ad%20Rails&descAlign=50&descAlignY=58"/>

<img alt="typing" src="https://readme-typing-svg.demolab.com?font=Inter&size=18&duration=3000&pause=650&center=true&vCenter=true&width=900&lines=Mining+Shift+Claim+Automation;Daily+Check-in+%7C+Story+%7C+Bio+%7C+Home;Sponsored+Jobs+%7C+Ad+Network+Rails;Multi-Account+%7C+Sequential+Processing"/>

<p>
  <img alt="elixir" src="https://img.shields.io/badge/Elixir-1.14%2B-4B275F?logo=elixir&logoColor=white"/>
  <img alt="platform" src="https://img.shields.io/badge/Platform-Spider%20Miner%20Miniapp-111111"/>
  <img alt="multi-account" src="https://img.shields.io/badge/Multi--Account-Supported-111111"/>
  <img alt="proxy" src="https://img.shields.io/badge/Proxy-Supported-111111"/>
  <img alt="author" src="https://img.shields.io/badge/by-Yuurisandesu-111111"/>
</p>

<p>
  <b>Spider Miner Bot</b> is a full automation bot for the Spider Miner Telegram Miniapp.<br/>
  It runs the whole daily cycle for every account: the mining shift claim, the daily check-in, story, bio and home screen rewards, every job on the board, the sponsored jobs rail and the ad network rails - with proxy support and a live countdown between cycles.<br/>
  Built and distributed by <b>Yuurisandesu</b>.
</p>

</div>

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the Bot](#running-the-bot)
- [Features](#features)
- [File Structure](#file-structure)
- [Disclaimer](#disclaimer)

---

## Requirements

- Elixir `1.14+` with Erlang/OTP `25+`
- Git

---

## Installation

### Install Elixir

Elixir runs on the Erlang virtual machine, so **Erlang/OTP is required** - Elixir cannot run without
it. Every package manager below installs Erlang/OTP for you as a dependency. The only path that needs
a separate Erlang step is the Windows manual installer (see below).

**Windows:**

*Option A - package manager (recommended, installs Erlang automatically):*

```cmd
winget install Elixir.Elixir
```

*Option B - manual installer (two installers, in this order):*

1. Download and run the **Erlang/OTP installer** from https://www.erlang.org/downloads
2. Run `erl -s halt` to check which OTP version you got
3. Download the **Elixir installer built for that exact OTP** from https://elixir-lang.org/install.html (`elixir-otp-<N>.exe`) and run it

Then open Command Prompt and verify:

```cmd
elixir --version
```

The output prints both versions, for example `Elixir 1.14.0 (compiled with Erlang/OTP 25)`.

**Linux (Ubuntu / Debian):**

```bash
sudo apt-get update
sudo apt-get install -y elixir
elixir --version
```

**macOS:**

```bash
brew install elixir
elixir --version
```

> If you do not have Homebrew, install it first from https://brew.sh

**Termux (Android):**

```bash
pkg update && pkg upgrade -y
pkg install elixir -y
elixir --version
```

> If the `elixir` package is not available in your Termux repository, install an Ubuntu environment first with `pkg install proot-distro`, then `proot-distro install ubuntu`, then `proot-distro login ubuntu` and run the Linux command above inside it.

---

### Clone and Install

**Clone the repository:**

```bash
git clone https://github.com/Yuurisan-N1/Spider-Miniapp.git
cd Spider-Miniapp
```

**Install dependencies:**

This bot uses only the Elixir standard library, so there is nothing to install. Erlang/OTP was already installed by the step above.

---

## Configuration

### 1. Accounts (data.txt)

Fill `data.txt` with the Telegram WebApp `initData` of each account, one per line:

```
user=%7B%22id%22...&hash=abc123
user=%7B%22id%22...&hash=def456
```

> `initData` can be obtained from the browser DevTools when opening the Spider Miner Miniapp on Telegram Web.

A line may optionally carry a wallet suffix after a `|` character (`initData|TON_ADDRESS`). It is not required: when the TON wallet is connected inside the app itself, the account mines right away and the suffix is simply ignored.

### 2. Proxy (proxy.txt)

Fill `proxy.txt` with proxies, one per line (optional, leave empty to run without proxy):

```
host:port
host:port:user:pass
http://user:pass@host:port
```

Proxies are assigned to accounts by index in round-robin order. Proxy credentials are masked in the log.

### 3. Bot Settings (config.json)

`sleep_seconds` controls how many seconds the bot waits between cycles. If `config.json` is missing, it is created automatically with a default of `3600` seconds.

```json
{
  "settings": {
    "sleep_seconds": 3600
  }
}
```

---

## Running the Bot

**Linux / macOS:**

```bash
elixir --erl "+Bd" bot.exs
```

**Windows:**

```cmd
elixir --erl "+Bc" bot.exs
```

Or just double click `run_pc.bat`, which runs the Windows command above.


---

## Features

### Account State
Every account is opened with the Telegram `initData` from `data.txt`. The bot registers a fresh device identity for the account, reads the account snapshot and logs the name together with the current SPID balance.

### Daily Rewards
The daily check-in, the story reward, the bio link reward and the home screen reward are each claimed once per day. The story and the home screen reward are only claimed when the server reports them as open, so a reward that is already collected is never requested twice.

### Job Board
Every job that is not finished is walked in order: the job is opened, the proof-of-activity timer is waited out with a live countdown, and the reward is claimed. A job that still needs a manual channel join is reported as such and skipped.

### Mining Shift
The mining shift is read before it is claimed. When a shift is still running the bot prints how much time is left and moves on - it never parks the cycle on a multi-hour countdown. Once the shift is finished the claim is sent and the real balance gain is logged. When the account has no TON wallet linked, the bot says so once and continues with the rest of the cycle.

### Sponsored Jobs
The sponsored jobs rail is drained up to the daily limit the server reports, and the rail counter is re-read after every claim. When the limit is already used up the bot reports it once and moves on.

### Ad Network Rails
Every ad network rail is started through the server, watched for its full timer with a live countdown, and completed. Both the per-network daily limit and the reported rail counter are respected.

### Crew Bonus
The crew summary is read for the account and the pending crew bonus is claimed when the server reports one.

### Multi Account
All accounts in `data.txt` are processed sequentially within every cycle. Each account is logged with its index, its name and its balance. The cycle number is tracked and logged at the start of each round.

### Proxy Support
Proxies are loaded from `proxy.txt` and assigned to accounts by position in round-robin order. Running without proxies is fully supported.

### Verified Rewards
A coin amount is only printed when a server counter confirms it. The balance is re-read after every claim, and a claim that credited nothing is reported as unconfirmed instead of being logged as a reward.

### Auto Countdown
Every wait inside the cycle displays a live `HH:MM:SS` countdown in place, and after all accounts complete a cycle the bot shows a countdown until the next cycle starts.

---

## File Structure

```text
Spider-Miniapp/
├── bot.exs         # Main bot, full daily cycle automation
├── config.json     # Sleep duration between cycles
├── data.txt        # Account initData, one per line
├── proxy.txt       # Proxy list, one per line (optional)
├── run_pc.bat      # Launcher for Windows
├── LICENSE         # License file
└── utils/
    ├── banner.ex   # Banner display on startup
    └── json.ex     # JSON encoder and decoder
```

---

## Disclaimer

This tool is built for educational and technical exploration purposes. Use it wisely and at your own responsibility.

---

<div align="center">
<img width="100%" alt="footer" src="https://capsule-render.vercel.app/api?type=waving&height=120&section=footer"/>
</div>
