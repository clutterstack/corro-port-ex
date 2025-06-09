#!/usr/bin/env bash

# Wrapper script for Corrosion as suggested by Elixir Port docs
# in case of programs that don't close gracefully when stdin closes
# https://hexdocs.pm/elixir/Port.html#module-zombie-operating-system-processes
# Not sure if we need this for corrosion or not.

# Start the program in the background
exec "$@" &
pid1=$!

# Silence warnings from here on
exec >/dev/null 2>&1

# Read from stdin in the background and
# kill running program when stdin closes
exec 0<&0 $(
  while read; do :; done
  kill -KILL $pid1
) &
pid2=$!

# Clean up
wait $pid1
ret=$?
kill -KILL $pid2
exit $ret