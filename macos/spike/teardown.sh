#!/bin/bash
# Kills ONLY the throwaway -L bosun-spike tmux server.
tmux -L bosun-spike kill-server 2>/dev/null && echo "bosun-spike server killed" || echo "bosun-spike server not running"
