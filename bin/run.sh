#!/bin/bash

if [ -z "$1" ]; then
	NODENAME="`hostname | cut -d. -f1`"
else
	NODENAME="$1"
fi

if [ -z "$AFSBACKUP" ]; then
	echo "AFSBACKUP is unset"
	exit 1
fi

$AFSBACKUP/bin/afs-backup.pl $NODENAME
