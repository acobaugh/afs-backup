PREFIX ?= /usr/local
DIRS = bin etc etc/hosts var var/acl var/log var/tmp var/vldb

install:
	@for dir in ${DIRS} ; do \
		echo install -d -m 755 ${PREFIX}/$${dir}; \
	done
	cat afs-backup.pl | sed -e "s/_GITVERSION_/`git describe 2>/dev/null`/" > ${PREFIX}/bin/afs-backup.pl
	chmod +x ${PREFIX}/bin/afs-backup.pl
	install -m 755 dumpvldb.sh ${PREFIX}/bin/dumpvldb.sh
	install -m 644 default.cfg ${PREFIX}/etc/default.cfg
