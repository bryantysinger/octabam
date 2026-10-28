Fixes a click in the recorder loop. A FLEX voice playing its own recorder
buffer every bar now re-primes cleanly at tempos whose bar is not a whole
number of samples (82,687.5 at 128 BPM). Nothing on the panel.
