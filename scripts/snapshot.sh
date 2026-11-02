#!/bin/zsh
# Opens Faders' popover and renders it to a PNG: scripts/snapshot.sh out.png
out="${1:a}"
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('com.krabduke.faders.snapshot', '$out', \$(), true)"
