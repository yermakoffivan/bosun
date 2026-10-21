# Troubleshooting

The commands below use `tmux -L bosun`, the tmux server Bosun runs on by default. If you've set `tmux_socket` in `config.toml` (or `BOSUN_TMUX_SOCKET`), use that name instead, and with `default` leave out `-L bosun` altogether.

## Sessions close as soon as they start

A new session shows up and is gone a moment later, and Bosun says "*name* closed as soon as it started". The shell in the new pane exited straight away, so tmux ended the session with it. Bosun doesn't end sessions itself unless you kill or dock them.

### tmux was updated while Bosun's server was running

This is the usual cause. A tmux server keeps running the version it started with, so after a package manager updates tmux, Bosun's server is still the old one and the new `tmux` may not be able to run sessions on it. Often it still can, but Bosun warns about the difference when it starts. To check by hand, compare:

```sh
tmux -V
tmux -L bosun display -p '#{version}'
```

If they differ, or the second one says `protocol version mismatch`, restart Bosun's server. Quit Bosun (the TUI and Bosun for Mac), then:

```sh
tmux -L bosun kill-server
```

This ends every session on Bosun's server, so finish anything running there first. Start Bosun again and it starts a new server on the current tmux. A restart of the Mac does the same.

### Check without Bosun

Create a session on Bosun's server the way Bosun does, and see whether it stays up:

```sh
tmux -L bosun new-session -d -s probe -c ~ -e BOSUN=1
sleep 1; tmux -L bosun list-sessions
tmux -L bosun show -g default-shell
tmux -L bosun show -g default-command
tmux -L bosun kill-session -t probe
```

If `probe` is missing from the list, the problem is in that tmux server or the shell it starts, not in Bosun: look at `default-shell` and `default-command`, and at your tmux config and plugins. To rule the config out, try a server of its own that skips it:

```sh
tmux -L bosun-probe -f /dev/null new-session -d -s probe
sleep 1; tmux -L bosun-probe list-sessions
tmux -L bosun-probe kill-server
```

If `probe` is there, Bosun is doing something your setup doesn't like: get a debug log (below) and open an issue.

## Getting a debug log

Bosun writes its log to stderr, so send it to a file, or it draws over the interface and is lost:

```sh
BOSUN_LOG=bosun=debug bosun 2>/tmp/bosun.log
```

Do whatever goes wrong, quit Bosun, and look in `/tmp/bosun.log`. `BOSUN_LOG=bosun=trace` logs more.

For Bosun for Mac, the log comes from its daemon, `bosun serve`. The daemon keeps running after the app quits, so quit the app, stop the daemon (`pkill -f "bosun serve"`), then start one yourself from a terminal that isn't inside tmux, and open the app, which uses a daemon that's already running instead of starting its own:

```sh
BOSUN_LOG=bosun=debug bosun serve 2>/tmp/bosun-serve.log
```

## Opening an issue

Issues go to https://github.com/yetidevworks/bosun/issues. It helps to include:

- your OS, your shell (`echo $SHELL`) and how you installed Bosun
- `bosun --version`, `tmux -V` and `tmux -L bosun display -p '#{version}'`
- the last version of Bosun that worked, if it used to
- a debug log of the problem
