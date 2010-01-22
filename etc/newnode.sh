#!/bin/bash

if [ -z "$1" ]; then
	echo "Usage: $0 <nodename>"
	exit 1
fi

if [ -d "nodes/$1" ]; then
	echo "nodes/$1 already exists, exiting."
	exit 1
fi

cp -R skel nodes/$1/
