#!/bin/bash

export PATH=/afs/bx.psu.edu/user/phalenor/code.d/afs-backup/bin:${PATH}

# assume setenv.sh is in AFSBACKUP/bin
SCRIPT_PATH="${BASH_SOURCE[0]}";
if [ -h "${SCRIPT_PATH}" ]; then
	while([ -h "${SCRIPT_PATH}" ])
	do 
		SCRIPT_PATH=`readlink "${SCRIPT_PATH}"`
	done
fi
pushd . > /dev/null
cd `dirname ${SCRIPT_PATH}` > /dev/null
SCRIPT_PATH=`pwd`;

popd  > /dev/null

export AFSBACKUP="`dirname $SCRIPT_PATH`"

$1
