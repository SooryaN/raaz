#!/bin/bash

LIQUID="$HOME/liquidhaskell/.cabal-sandbox/bin/liquid"
$LIQUID --version

$LIQUID $(find raaz-core raaz-implementation -name '*.hs' ! -name "Entropy.hs" | paste -sd " ")
exit $?
