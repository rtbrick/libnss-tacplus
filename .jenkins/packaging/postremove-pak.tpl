#!/bin/bash

set -ue;

# We always run a ldconfig , just in case the package installed any
# shared libraries which are now removed.
ldconfig;

# Add commands after this line.
