#!/usr/bin/env python3
"""Remove a [Peer] block from an AmneziaWG config, matched by the
`# <name>` comment that add-client.sh writes under [Peer].

Env: AWG_CLIENT (raw client name), AWG_CONF (path to awg0.conf).
Exit codes: 0 removed, 3 peer not found.
"""
import os
import re
import sys

client = re.escape(os.environ['AWG_CLIENT'])
conf = os.environ['AWG_CONF']

with open(conf) as f:
    text = f.read()

# Match: newline, [Peer], # <name>, then all following non-empty lines.
pattern = r'\n\[Peer\]\n# ' + client + r'\n(?:[^\n]+\n?)*'
if not re.search(pattern, text):
    sys.exit(3)

text = re.sub(pattern, '\n', text)
text = re.sub(r'\n{3,}', '\n\n', text).rstrip() + '\n'

with open(conf, 'w') as f:
    f.write(text)
