#!/bin/sh

file=$1

rm -f $file 
for vol in `vos listvldb -quiet | egrep "^[a-zA-Z0-0].*"`
do
	echo "===" >> $file
	vos exam -format $vol >> $file 2>&1
done
