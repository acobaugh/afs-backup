#!/bin/bash

if [ -z "$1" ]; then
	echo "Usage: $0 <nodename>"
	exit 1
fi

if [ -d "hosts/$1" ]; then
	echo "hosts/$1 already exists, exiting."
	exit 1
fi

cp -R skel nodes/$1/
